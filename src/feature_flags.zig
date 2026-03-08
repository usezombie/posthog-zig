//! Feature flag evaluation via PostHog /decide/?v=3 with in-memory TTL cache.
//!
//! Cache is per distinct_id, bounded to max_entries with simple eviction.
//! TTL defaults to 60s. After expiry, next call fetches fresh flags from PostHog.

const std = @import("std");
const transport = @import("transport.zig");

const log = std.log.scoped(.posthog);

pub const FlagCache = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(Entry),
    mutex: std.Thread.Mutex,
    ttl_ms: u64,
    max_entries: usize,

    const Entry = struct {
        // Parsed JSON response — arena owns all string memory
        parsed: std.json.Parsed(std.json.Value),
        fetched_at_ms: i64,
        distinct_id: []u8, // allocator-owned copy (used as map key)
    };

    pub fn init(allocator: std.mem.Allocator, ttl_ms: u64, max_entries: usize) FlagCache {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(Entry).init(allocator),
            .mutex = .{},
            .ttl_ms = ttl_ms,
            .max_entries = max_entries,
        };
    }

    pub fn deinit(self: *FlagCache) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.parsed.deinit();
            self.allocator.free(kv.value_ptr.distinct_id);
        }
        self.entries.deinit();
    }

    /// Store the raw /decide/ JSON response for a distinct_id.
    pub fn put(self: *FlagCache, distinct_id: []const u8, json_response: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json_response, .{});
        errdefer parsed.deinit();

        const id_copy = try self.allocator.dupe(u8, distinct_id);
        errdefer self.allocator.free(id_copy);

        const entry = Entry{
            .parsed = parsed,
            .fetched_at_ms = std.time.milliTimestamp(),
            .distinct_id = id_copy,
        };

        self.mutex.lock();
        defer self.mutex.unlock();

        // Evict one entry if at capacity.
        // Copy key and entry before remove — remove uses the key to find the slot,
        // so key memory must still be valid when remove() is called.
        if (self.entries.count() >= self.max_entries) {
            var it = self.entries.iterator();
            if (it.next()) |kv| {
                const evict_key = kv.key_ptr.*;
                const evict_entry = kv.value_ptr.*;
                _ = self.entries.remove(evict_key); // remove first, key still valid
                evict_entry.parsed.deinit();
                self.allocator.free(evict_entry.distinct_id); // free after remove
            }
        }

        // Remove existing entry for this distinct_id if present
        if (self.entries.fetchRemove(distinct_id)) |old| {
            old.value.parsed.deinit();
            self.allocator.free(old.value.distinct_id);
        }

        try self.entries.put(id_copy, entry);
    }

    /// Returns true if the flag is enabled for this distinct_id.
    /// Returns null if not cached or TTL expired (caller should fetch).
    pub fn isEnabled(self: *FlagCache, distinct_id: []const u8, flag_key: []const u8) ?bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const entry = self.entries.getPtr(distinct_id) orelse return null;
        if (self.isExpiredLocked(entry)) return null;

        const flags = getFlagsObject(entry) orelse return null;
        const val = flags.get(flag_key) orelse return null;
        return switch (val) {
            .bool => |b| b,
            .string => |s| s.len > 0,
            else => false,
        };
    }

    /// Returns the raw payload string for a flag (caller owns returned slice).
    /// Returns null if not cached, expired, or no payload for this flag.
    pub fn getPayload(self: *FlagCache, allocator: std.mem.Allocator, distinct_id: []const u8, flag_key: []const u8) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const entry = self.entries.getPtr(distinct_id) orelse return null;
        if (self.isExpiredLocked(entry)) return null;

        const payloads = getPayloadsObject(entry) orelse return null;
        const val = payloads.get(flag_key) orelse return null;
        return switch (val) {
            .string => |s| allocator.dupe(u8, s) catch null,
            else => null,
        };
    }

    fn isExpiredLocked(self: *const FlagCache, entry: *const Entry) bool {
        const age = std.time.milliTimestamp() - entry.fetched_at_ms;
        return age >= @as(i64, @intCast(self.ttl_ms));
    }

    fn getFlagsObject(entry: *const Entry) ?std.json.ObjectMap {
        if (entry.parsed.value != .object) return null;
        const flags = entry.parsed.value.object.get("featureFlags") orelse return null;
        return if (flags == .object) flags.object else null;
    }

    fn getPayloadsObject(entry: *const Entry) ?std.json.ObjectMap {
        if (entry.parsed.value != .object) return null;
        const payloads = entry.parsed.value.object.get("featureFlagPayloads") orelse return null;
        return if (payloads == .object) payloads.object else null;
    }
};

/// Fetch feature flags for a distinct_id, store in cache, return the cache.
/// Caller holds the cache; this updates it in place.
pub fn fetchAndCache(
    cache: *FlagCache,
    allocator: std.mem.Allocator,
    host: []const u8,
    api_key: []const u8,
    distinct_id: []const u8,
) !void {
    const body = try transport.postDecide(allocator, host, api_key, distinct_id);
    defer allocator.free(body);
    try cache.put(distinct_id, body);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const sample_decide_response =
    \\{"featureFlags":{"flag-a":true,"flag-b":"variant-1","flag-off":false},"featureFlagPayloads":{"flag-b":"{\"key\":\"value\"}"}}
;

test "feature flags: isEnabled returns correct values from cache" {
    var cache = FlagCache.init(std.testing.allocator, 60_000, 100);
    defer cache.deinit();

    try cache.put("user_123", sample_decide_response);

    try std.testing.expect(cache.isEnabled("user_123", "flag-a").?);
    try std.testing.expect(cache.isEnabled("user_123", "flag-b").?); // non-empty string = enabled
    try std.testing.expect(!cache.isEnabled("user_123", "flag-off").?);
}

test "feature flags: isEnabled returns null for unknown distinct_id" {
    var cache = FlagCache.init(std.testing.allocator, 60_000, 100);
    defer cache.deinit();

    try std.testing.expectEqual(@as(?bool, null), cache.isEnabled("nobody", "flag-a"));
}

test "feature flags: isEnabled returns null for unknown flag key" {
    var cache = FlagCache.init(std.testing.allocator, 60_000, 100);
    defer cache.deinit();

    try cache.put("user_123", sample_decide_response);
    try std.testing.expectEqual(@as(?bool, null), cache.isEnabled("user_123", "nonexistent"));
}

test "feature flags: getPayload returns payload string" {
    var cache = FlagCache.init(std.testing.allocator, 60_000, 100);
    defer cache.deinit();

    try cache.put("user_123", sample_decide_response);
    const payload = cache.getPayload(std.testing.allocator, "user_123", "flag-b");
    defer if (payload) |p| std.testing.allocator.free(p);

    try std.testing.expect(payload != null);
    try std.testing.expectEqualStrings("{\"key\":\"value\"}", payload.?);
}

test "feature flags: TTL expiry returns null" {
    var cache = FlagCache.init(std.testing.allocator, 0, 100); // 0ms TTL = always expired
    defer cache.deinit();

    try cache.put("user_123", sample_decide_response);
    // Immediately expired
    try std.testing.expectEqual(@as(?bool, null), cache.isEnabled("user_123", "flag-a"));
}

test "feature flags: max_entries eviction" {
    var cache = FlagCache.init(std.testing.allocator, 60_000, 2);
    defer cache.deinit();

    try cache.put("user_1", sample_decide_response);
    try cache.put("user_2", sample_decide_response);
    try cache.put("user_3", sample_decide_response); // should evict user_1

    try std.testing.expectEqual(@as(usize, 2), cache.entries.count());
}

test "feature flags: re-put same distinct_id replaces entry" {
    var cache = FlagCache.init(std.testing.allocator, 60_000, 100);
    defer cache.deinit();

    try cache.put("user_1", sample_decide_response);
    try cache.put("user_1", "{\"featureFlags\":{\"flag-a\":false},\"featureFlagPayloads\":{}}");

    try std.testing.expect(!cache.isEnabled("user_1", "flag-a").?);
    try std.testing.expectEqual(@as(usize, 1), cache.entries.count());
}
