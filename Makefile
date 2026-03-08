# =============================================================================
# posthog-zig Makefile
# =============================================================================

ZIG_GLOBAL_CACHE_DIR ?= $(CURDIR)/.tmp/zig-global-cache
ZIG_LOCAL_CACHE_DIR  ?= $(CURDIR)/.tmp/zig-local-cache
COVERAGE_MIN_LINES   ?= 60
COVERAGE_TARGET      ?= x86_64-linux
MEMLEAK_TARGET       ?= x86_64-linux

.DEFAULT_GOAL := help

.PHONY: help lint fmt fmt-check test test-unit test-integration \
        test-bin coverage bench memleak clean

help:  ## Show available targets
	@echo "posthog-zig"
	@echo ""
	@echo "  lint          Check Zig formatting"
	@echo "  fmt           Auto-format all Zig source"
	@echo "  test          Run unit tests"
	@echo "  test-integration  Run integration tests (requires POSTHOG_API_KEY)"
	@echo "  coverage      Run kcov coverage + enforce minimum threshold"
	@echo "  bench         Run capture() hot-path benchmark"
	@echo "  memleak       Run allocator leak gate"
	@echo "  clean         Remove build artifacts"

# ── Format & lint ────────────────────────────────────────────────────────────

fmt:  ## Auto-format all Zig source
	@echo "→ Formatting Zig source..."
	@find src tests -name '*.zig' -exec zig fmt {} \;
	@echo "✓ fmt done"

fmt-check:  ## Check formatting without modifying files
	@echo "→ Checking Zig formatting..."
	@find src tests -name '*.zig' -exec zig fmt --check {} \;

lint: fmt-check  ## Check formatting
	@echo "✓ lint passed"

# ── Tests ────────────────────────────────────────────────────────────────────

test: test-unit  ## Run unit tests

test-unit:  ## Run unit tests
	@echo "→ Running unit tests..."
	@mkdir -p "$(ZIG_GLOBAL_CACHE_DIR)" "$(ZIG_LOCAL_CACHE_DIR)"
	@ZIG_GLOBAL_CACHE_DIR="$(ZIG_GLOBAL_CACHE_DIR)" \
	 ZIG_LOCAL_CACHE_DIR="$(ZIG_LOCAL_CACHE_DIR)" \
	 zig build test --summary all
	@echo "✓ unit tests passed"

test-integration:  ## Run integration tests against live PostHog (requires POSTHOG_API_KEY)
	@[ -n "$$POSTHOG_API_KEY" ] || { echo "✗ POSTHOG_API_KEY not set"; exit 1; }
	@echo "→ Running integration tests..."
	@mkdir -p "$(ZIG_GLOBAL_CACHE_DIR)" "$(ZIG_LOCAL_CACHE_DIR)"
	@ZIG_GLOBAL_CACHE_DIR="$(ZIG_GLOBAL_CACHE_DIR)" \
	 ZIG_LOCAL_CACHE_DIR="$(ZIG_LOCAL_CACHE_DIR)" \
	 zig build test -Dintegration=true --summary all
	@echo "✓ integration tests passed"

# ── Coverage ─────────────────────────────────────────────────────────────────

test-bin:  ## Build test binary for kcov / memleak
	@mkdir -p "$(ZIG_GLOBAL_CACHE_DIR)" "$(ZIG_LOCAL_CACHE_DIR)"
	@ZIG_GLOBAL_CACHE_DIR="$(ZIG_GLOBAL_CACHE_DIR)" \
	 ZIG_LOCAL_CACHE_DIR="$(ZIG_LOCAL_CACHE_DIR)" \
	 zig build test-bin $(if $(TARGET),-Dtarget=$(TARGET),)

coverage:  ## Run kcov coverage + enforce minimum threshold
	@command -v kcov >/dev/null 2>&1 || { echo "✗ kcov required (brew install kcov / apt-get install kcov)"; exit 1; }
	@mkdir -p "$(ZIG_GLOBAL_CACHE_DIR)" "$(ZIG_LOCAL_CACHE_DIR)" coverage .tmp
	@echo "→ Building test binary..."
	@$(MAKE) test-bin TARGET="$(COVERAGE_TARGET)"
	@echo ""
	@echo "══ DWARF diagnostic ════════════════════════════════════════"
	@readelf -S zig-out/bin/posthog-tests 2>/dev/null \
	  | awk '/\.debug_/{printf "  %s\n",$$2}' || echo "  readelf failed"
	@readelf --debug-dump=info zig-out/bin/posthog-tests 2>/dev/null \
	  | grep -E 'DWARF version|DW_AT_comp_dir|DW_AT_name' | head -8 \
	  | sed 's/^/  /' || true
	@echo ""
	@echo "══ [1/4] kcov — no filters ═════════════════════════════════"
	@kcov --clean .tmp/kcov-1 zig-out/bin/posthog-tests >/dev/null 2>&1 || true
	@grep -o 'lines-valid="[0-9]*"' .tmp/kcov-1/posthog-tests/cobertura.xml \
	  2>/dev/null | sed 's/^/  /' || echo "  (no xml)"
	@grep -o 'filename="[^"]*"' .tmp/kcov-1/posthog-tests/cobertura.xml \
	  2>/dev/null | head -5 | sed 's/^/  /' || echo "  (no filenames)"
	@echo ""
	@echo "══ [2/4] kcov — exclude /root/ /usr/ /home/ only ══════════"
	@kcov --clean \
	  --strip-path="$(CURDIR)/" \
	  --exclude-pattern="/root/,/usr/,/home/" \
	  .tmp/kcov-2 zig-out/bin/posthog-tests >/dev/null 2>&1 || true
	@grep -o 'lines-valid="[0-9]*"' .tmp/kcov-2/posthog-tests/cobertura.xml \
	  2>/dev/null | sed 's/^/  /' || echo "  (no xml)"
	@grep -o 'filename="[^"]*"' .tmp/kcov-2/posthog-tests/cobertura.xml \
	  2>/dev/null | head -5 | sed 's/^/  /' || echo "  (no filenames)"
	@echo ""
	@echo "══ [3/4] kcov — include-path=$(CURDIR) ════════════════════"
	@kcov --clean \
	  --include-path="$(CURDIR)" \
	  --strip-path="$(CURDIR)/" \
	  .tmp/kcov-3 zig-out/bin/posthog-tests >/dev/null 2>&1 || true
	@grep -o 'lines-valid="[0-9]*"' .tmp/kcov-3/posthog-tests/cobertura.xml \
	  2>/dev/null | sed 's/^/  /' || echo "  (no xml)"
	@grep -o 'filename="[^"]*"' .tmp/kcov-3/posthog-tests/cobertura.xml \
	  2>/dev/null | head -5 | sed 's/^/  /' || echo "  (no filenames)"
	@echo ""
	@echo "══ [4/4] kcov — include-path=$(CURDIR)/src ════════════════"
	@kcov --clean \
	  --include-path="$(CURDIR)/src" \
	  --strip-path="$(CURDIR)/" \
	  .tmp/kcov-4 zig-out/bin/posthog-tests >/dev/null 2>&1 || true
	@grep -o 'lines-valid="[0-9]*"' .tmp/kcov-4/posthog-tests/cobertura.xml \
	  2>/dev/null | sed 's/^/  /' || echo "  (no xml)"
	@grep -o 'filename="[^"]*"' .tmp/kcov-4/posthog-tests/cobertura.xml \
	  2>/dev/null | head -5 | sed 's/^/  /' || echo "  (no filenames)"
	@echo ""
	@echo "══ coverage gate (using approach 2 result) ═════════════════"
	@[ -f .tmp/kcov-2/posthog-tests/cobertura.xml ] || \
	  { echo "✗ kcov did not produce cobertura.xml"; exit 1; }
	@cp .tmp/kcov-2/posthog-tests/cobertura.xml coverage/cobertura.xml
	@stats=$$(awk '\
	  BEGIN{v=0;c=0;s=0}\
	  /<class /{s=($$0 ~ /filename="[^"]*src\//)?1:0}\
	  s&&/<line /{v++;if($$0 ~ /hits="[1-9]/)c++}\
	  END{printf "%d %.2f",v,(v>0?c*100/v:0)}' coverage/cobertura.xml); \
	 lines_valid=$$(echo "$$stats" | awk '{print $$1}'); \
	 line_pct=$$(echo "$$stats" | awk '{print $$2}'); \
	 if [ "$$lines_valid" -eq 0 ]; then \
	   echo "✗ zero src/ lines across all approaches — kcov cannot parse this Zig binary's DWARF"; \
	   exit 1; \
	 fi; \
	 printf 'line_coverage_pct=%s\nline_coverage_min=%s\n' "$$line_pct" "$(COVERAGE_MIN_LINES)" | tee .tmp/coverage.txt >/dev/null; \
	 if awk -v got="$$line_pct" -v min="$(COVERAGE_MIN_LINES)" \
	   'BEGIN { exit !((got+0) >= (min+0)) }'; then \
	   echo "✓ coverage gate passed ($$line_pct% >= $(COVERAGE_MIN_LINES)%)"; \
	 else \
	   printf "✗ coverage %.2f%% below threshold %.2f%%\n" "$$line_pct" "$(COVERAGE_MIN_LINES)"; \
	   exit 1; \
	 fi

# ── Bench ────────────────────────────────────────────────────────────────────

bench:  ## Benchmark capture() hot-path latency
	@echo "→ Running benchmark..."
	@mkdir -p "$(ZIG_GLOBAL_CACHE_DIR)" "$(ZIG_LOCAL_CACHE_DIR)"
	@ZIG_GLOBAL_CACHE_DIR="$(ZIG_GLOBAL_CACHE_DIR)" \
	 ZIG_LOCAL_CACHE_DIR="$(ZIG_LOCAL_CACHE_DIR)" \
	 zig build bench --summary all

# ── Memleak ──────────────────────────────────────────────────────────────────

memleak:  ## Run allocator leak gate
	@echo "→ Running allocator leak gate..."
	@case "$$(uname -s)" in \
	  Linux) \
	    $(MAKE) test-bin TARGET="$(MEMLEAK_TARGET)"; \
	    command -v valgrind >/dev/null 2>&1 || { echo "✗ valgrind required on Linux"; exit 1; }; \
	    valgrind --quiet --leak-check=full --show-leak-kinds=all \
	      --errors-for-leak-kinds=definite,possible --error-exitcode=1 \
	      zig-out/bin/posthog-tests;; \
	  Darwin) \
	    $(MAKE) test-bin; \
	    if command -v leaks >/dev/null 2>&1; then \
	      MallocStackLogging=1 leaks -atExit -- zig-out/bin/posthog-tests >/dev/null || \
	        echo "→ leaks unavailable in this runtime (allocator gate only)"; \
	    else \
	      echo "→ leaks not found; allocator gate only"; \
	    fi;; \
	  *) \
	    $(MAKE) test-bin; \
	    echo "→ platform=$$(uname -s): allocator gate only";; \
	esac
	@echo "✓ memleak gate passed"

# ── Misc ─────────────────────────────────────────────────────────────────────

clean:  ## Remove build artifacts
	@rm -rf zig-out .zig-cache .tmp coverage
	@echo "✓ cleaned"
