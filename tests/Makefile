# Rune Arc Test Harness — Makefile
#
# Layer 1: Unit tests (free, fast, no API cost)
# Layer 2: E2E integration (triggers real claude CLI, costs API credits)
# Layer 3: Quality evaluation (analysis of generated code)
#
# Config isolation: E2E runs use CLAUDE_CONFIG_DIR=~/.claude-rune-test
# to redirect all Claude Code state (teams, tasks, memory). Never touches ~/.claude/.
# The harness sets this automatically. For manual testing:
#   CLAUDE_CONFIG_DIR=~/.claude-rune-test claude --dangerously-skip-permissions

.PHONY: help test unit lint typecheck check clean clean-config clean-memory e2e e2e-quick evaluate report setup kill-test-procs

CLAUDE_TEST_DIR := $(HOME)/.claude-rune-test

PYTHON     ?= python
PYTEST     ?= $(PYTHON) -m pytest
RUFF       ?= $(PYTHON) -m ruff
MYPY       ?= $(PYTHON) -m mypy
PLUGIN_DIR ?= $(shell dirname $(CURDIR))/plugins/rune
CHALLENGE  ?= challenge/plan.md
MODEL      ?=
MAX_TURNS  ?= 200
MAX_BUDGET ?= 15.0
TIMEOUT    ?= 3600

# ── Help ──────────────────────────────────────────────────────
help: ## Show this help
	@echo "Rune Arc Test Harness"
	@echo "====================="
	@echo ""
	@echo "Layer 1 — Unit Tests (free, fast):"
	@echo "  make test        Run all unit tests"
	@echo "  make unit        Alias for test"
	@echo "  make lint        Run ruff linter"
	@echo "  make typecheck   Run mypy type checks"
	@echo "  make check       Run test + lint + typecheck"
	@echo ""
	@echo "Layer 2 — E2E Integration (costs API credits):"
	@echo "  make e2e         Full E2E run (isolated config)"
	@echo "  make e2e-quick   E2E without forge phase"
	@echo "  make e2e-debug   E2E without config isolation"
	@echo ""
	@echo "Layer 3 — Evaluation:"
	@echo "  make evaluate    Evaluate existing workspace"
	@echo ""
	@echo "Utilities:"
	@echo "  make setup           Install test dependencies"
	@echo "  make clean           Remove caches and temp files"
	@echo "  make clean-memory    Clear memory/state only"
	@echo "  make clean-config    Wipe $(CLAUDE_TEST_DIR)/"
	@echo "  make kill-test-procs Kill orphaned claude test processes"
	@echo "  make report          Show latest report"
	@echo ""
	@echo "Variables:"
	@echo "  CHALLENGE=...    Challenge plan (default: challenge/plan.md)"
	@echo "  MODEL=...        Claude model override"
	@echo "  MAX_TURNS=...    Max CLI turns (default: 200)"
	@echo "  MAX_BUDGET=...   Max budget USD (default: 15.0)"
	@echo "  TIMEOUT=...      Timeout seconds (default: 3600)"
	@echo "  WORKSPACE=...    Workspace path (for evaluate)"
	@echo ""
	@echo "Config Isolation:"
	@echo "  The harness automatically sets CLAUDE_CONFIG_DIR to"
	@echo "  $(CLAUDE_TEST_DIR) for E2E runs."
	@echo "  For manual testing with isolation:"
	@echo "    CLAUDE_CONFIG_DIR=$(CLAUDE_TEST_DIR) claude -p '/rune:arc plan.md' --dangerously-skip-permissions"

# ── Layer 1: Unit Tests ──────────────────────────────────────
test: ## Run all unit tests
	$(PYTEST) test_checkpoint.py test_tome.py test_report.py test_hooks.py -v

unit: test ## Alias for test

lint: ## Run ruff linter on harness code
	$(RUFF) check helpers/ test_checkpoint.py test_tome.py test_report.py test_hooks.py run_harness.py conftest.py

typecheck: ## Run mypy type checks
	$(MYPY) helpers/ run_harness.py conftest.py --ignore-missing-imports --no-error-summary

check: test lint ## Run test + lint (full Layer 1 check)

# ── Layer 2: E2E Integration ─────────────────────────────────
e2e: kill-test-procs ## Full E2E run with isolated config
	@$(PYTHON) run_harness.py \
		--challenge $(CHALLENGE) \
		--plugin-dir $(PLUGIN_DIR) \
		--max-turns $(MAX_TURNS) \
		--max-budget $(MAX_BUDGET) \
		--timeout $(TIMEOUT) \
		--keep-workspace \
		$(if $(MODEL),--model $(MODEL),); \
	rc=$$?; $(MAKE) --no-print-directory kill-test-procs; exit $$rc

e2e-quick: kill-test-procs ## E2E without forge phase (faster, cheaper)
	@$(PYTHON) run_harness.py \
		--challenge $(CHALLENGE) \
		--plugin-dir $(PLUGIN_DIR) \
		--max-turns $(MAX_TURNS) \
		--max-budget $(MAX_BUDGET) \
		--timeout $(TIMEOUT) \
		--no-forge \
		--keep-workspace \
		$(if $(MODEL),--model $(MODEL),); \
	rc=$$?; $(MAKE) --no-print-directory kill-test-procs; exit $$rc

e2e-debug: kill-test-procs ## E2E without config isolation (DEBUG ONLY — uses default claude config)
	@$(PYTHON) run_harness.py \
		--challenge $(CHALLENGE) \
		--plugin-dir $(PLUGIN_DIR) \
		--max-turns $(MAX_TURNS) \
		--timeout $(TIMEOUT) \
		--no-isolate \
		--keep-workspace \
		$(if $(MODEL),--model $(MODEL),); \
	rc=$$?; $(MAKE) --no-print-directory kill-test-procs; exit $$rc

# ── Layer 3: Evaluation ──────────────────────────────────────
evaluate: ## Evaluate existing workspace (WORKSPACE= required)
ifndef WORKSPACE
	$(error WORKSPACE is required. Usage: make evaluate WORKSPACE=/path/to/workspace)
endif
	$(PYTHON) run_harness.py --evaluate-only --workspace $(WORKSPACE)

# ── Utilities ─────────────────────────────────────────────────
setup: ## Install test dependencies
	$(PYTHON) -m pip install -e ".[eval]"

clean: ## Remove caches and temp files
	rm -rf __pycache__ helpers/__pycache__ .pytest_cache .mypy_cache .ruff_cache
	rm -rf reports/

clean-config: clean-memory ## Clear all state from isolated config dir
	@echo "Done. To fully remove: rm -rf $(CLAUDE_TEST_DIR)"

clean-memory: ## Clear memory/state from isolated config dir
	@echo "Clearing memory from $(CLAUDE_TEST_DIR)..."
	@for d in agent-memory cache debug plans projects shell-snapshots tasks teams todos; do \
		rm -rf "$(CLAUDE_TEST_DIR)/$$d"/* 2>/dev/null; \
	done
	@rm -f "$(CLAUDE_TEST_DIR)/history.jsonl" "$(CLAUDE_TEST_DIR)"/.claude.json.backup.* 2>/dev/null
	@echo "Memory cleared."

kill-test-procs: ## Kill orphaned claude processes from test runs
	@echo "Scanning for orphaned test processes (RUNE_TEST_HARNESS=1)..."
	@pids=$$(ps axeww 2>/dev/null | grep '[R]UNE_TEST_HARNESS=1' | awk '{print $$1}' | sort -un); \
	if [ -z "$$pids" ]; then \
		echo "  No orphaned test processes found."; \
	else \
		echo "  Found PIDs: $$pids"; \
		for p in $$pids; do \
			ps -p "$$p" -o pid=,command= -ww 2>/dev/null | cut -c1-120; \
		done; \
		echo "  Sending SIGTERM..."; \
		kill -TERM $$pids 2>/dev/null || true; \
		sleep 3; \
		alive=""; \
		for p in $$pids; do \
			kill -0 "$$p" 2>/dev/null && alive="$$alive $$p"; \
		done; \
		if [ -n "$$alive" ]; then \
			echo "  Still alive:$$alive — sending SIGKILL..."; \
			kill -KILL $$alive 2>/dev/null || true; \
		fi; \
		echo "  Done."; \
	fi

report: ## Show the latest generated report
	@latest=$$(ls -t reports/report-*.md 2>/dev/null | head -1); \
	if [ -n "$$latest" ]; then \
		echo "Latest report: $$latest"; \
		echo ""; \
		cat "$$latest"; \
	else \
		echo "No reports found. Run 'make e2e' first."; \
	fi
