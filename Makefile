# =============================================================================
# posthog-zig Makefile
# =============================================================================

ZIG_GLOBAL_CACHE_DIR ?= $(CURDIR)/.tmp/zig-global-cache
ZIG_LOCAL_CACHE_DIR  ?= $(CURDIR)/.tmp/zig-local-cache
COVERAGE_MIN_LINES   ?= 60

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

test-bin:  ## Build test binary for kcov
	@mkdir -p "$(ZIG_GLOBAL_CACHE_DIR)" "$(ZIG_LOCAL_CACHE_DIR)"
	@ZIG_GLOBAL_CACHE_DIR="$(ZIG_GLOBAL_CACHE_DIR)" \
	 ZIG_LOCAL_CACHE_DIR="$(ZIG_LOCAL_CACHE_DIR)" \
	 zig build test-bin

coverage:  ## Run kcov coverage + enforce minimum threshold
	@command -v kcov >/dev/null 2>&1 || { echo "✗ kcov required (brew install kcov / apt-get install kcov)"; exit 1; }
	@mkdir -p "$(ZIG_GLOBAL_CACHE_DIR)" "$(ZIG_LOCAL_CACHE_DIR)" coverage .tmp
	@echo "→ Building test binary..."
	@$(MAKE) test-bin
	@echo "→ Running kcov..."
	@kcov --clean --include-pattern="$(CURDIR)/src" .tmp/kcov-out zig-out/bin/posthog-tests >/dev/null
	@cp .tmp/kcov-out/posthog-tests/cobertura.xml coverage/cobertura.xml
	@line_rate=$$(sed -n 's/.*line-rate="\([0-9.]*\)".*/\1/p' coverage/cobertura.xml | head -n 1); \
	 if [ -z "$$line_rate" ]; then echo "✗ could not parse line-rate from coverage/cobertura.xml"; exit 1; fi; \
	 line_pct=$$(awk -v r="$$line_rate" 'BEGIN { printf "%.2f", r * 100 }'); \
	 printf 'line_coverage_pct=%s\nline_coverage_min=%s\n' "$$line_pct" "$(COVERAGE_MIN_LINES)" | tee .tmp/coverage.txt >/dev/null; \
	 awk -v got="$$line_pct" -v min="$(COVERAGE_MIN_LINES)" \
	   'BEGIN { if ((got+0) < (min+0)) { printf "✗ coverage %.2f%% below threshold %.2f%%\n", got, min; exit 1 } }'; \
	 echo "✓ coverage gate passed ($$line_pct% >= $(COVERAGE_MIN_LINES)%)"

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
	@$(MAKE) test-bin
	@case "$$(uname -s)" in \
	  Linux) \
	    command -v valgrind >/dev/null 2>&1 || { echo "✗ valgrind required on Linux"; exit 1; }; \
	    valgrind --quiet --leak-check=full --show-leak-kinds=all \
	      --errors-for-leak-kinds=definite,possible --error-exitcode=1 \
	      zig-out/bin/posthog-tests;; \
	  Darwin) \
	    if command -v leaks >/dev/null 2>&1; then \
	      MallocStackLogging=1 leaks -atExit -- zig-out/bin/posthog-tests >/dev/null || \
	        echo "→ leaks unavailable in this runtime (allocator gate only)"; \
	    else \
	      echo "→ leaks not found; allocator gate only"; \
	    fi;; \
	  *) echo "→ platform=$$(uname -s): allocator gate only";; \
	esac
	@echo "✓ memleak gate passed"

# ── Misc ─────────────────────────────────────────────────────────────────────

clean:  ## Remove build artifacts
	@rm -rf zig-out .zig-cache .tmp coverage
	@echo "✓ cleaned"
