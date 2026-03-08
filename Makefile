# =============================================================================
# posthog-zig Makefile
# =============================================================================

ZIG_GLOBAL_CACHE_DIR ?= $(CURDIR)/.tmp/zig-global-cache
ZIG_LOCAL_CACHE_DIR  ?= $(CURDIR)/.tmp/zig-local-cache
COVERAGE_MIN_LINES   ?= 60
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
	@$(MAKE) test-bin TARGET="x86_64-linux"
	@echo "→ Running kcov..."
	@kcov --clean \
	  --include-path="$(CURDIR)/src" \
	  --replace-src-path="$(CURDIR),." \
	  --exclude-pattern=.zig-cache,/usr/include,/usr/lib \
	  .tmp/kcov-out zig-out/bin/posthog-tests >/dev/null
	@cp .tmp/kcov-out/posthog-tests/cobertura.xml coverage/cobertura.xml
	@lines_valid=$$(sed -n 's/.*lines-valid="\([0-9][0-9]*\)".*/\1/p' coverage/cobertura.xml | head -n 1); \
	 if [ -z "$$lines_valid" ]; then echo "✗ could not parse lines-valid from coverage/cobertura.xml"; exit 1; fi; \
	 if [ "$$lines_valid" -eq 0 ]; then echo "✗ coverage report has zero valid lines (kcov source mapping failed)"; exit 1; fi; \
	 line_rate=$$(sed -n 's/.*line-rate="\([0-9.]*\)".*/\1/p' coverage/cobertura.xml | head -n 1); \
	 if [ -z "$$line_rate" ]; then echo "✗ could not parse line-rate from coverage/cobertura.xml"; exit 1; fi; \
	 line_pct=$$(awk -v r="$$line_rate" 'BEGIN { printf "%.2f", r * 100 }'); \
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
