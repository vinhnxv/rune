#!/usr/bin/env python3
"""
Build talisman-defaults.json from talisman.example.yml.

This is a build-time script — run it manually when the talisman schema changes.
Output is committed to the repo so the runtime resolver never needs PyYAML.

Usage:
    python3 plugins/rune/scripts/build-talisman-defaults.py

Requires: PyYAML (pip install pyyaml)
"""

import json
import os
import sys

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML is required. Install with: pip install pyyaml", file=sys.stderr)
    sys.exit(1)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PLUGIN_ROOT = os.path.dirname(SCRIPT_DIR)
EXAMPLE_FILE = os.path.join(PLUGIN_ROOT, "talisman.example.yml")
OUTPUT_FILE = os.path.join(SCRIPT_DIR, "talisman-defaults.json")
MAX_YAML_FILE_SIZE = 1_048_576  # 1 MB — prevents memory exhaustion on malformed input


def build_defaults():
    """Parse talisman.example.yml and extract all active (uncommented) defaults."""
    if not os.path.isfile(EXAMPLE_FILE):
        print(f"ERROR: {EXAMPLE_FILE} not found", file=sys.stderr)
        sys.exit(1)

    # Guard: file size limit to prevent pathological YAML (BACK-004)
    file_size = os.path.getsize(EXAMPLE_FILE)
    if file_size > MAX_YAML_FILE_SIZE:
        print(f"ERROR: {EXAMPLE_FILE} exceeds {MAX_YAML_FILE_SIZE} byte limit ({file_size} bytes)", file=sys.stderr)
        sys.exit(1)

    with open(EXAMPLE_FILE, encoding="utf-8-sig") as f:
        try:
            data = yaml.safe_load(f)
        except yaml.YAMLError as e:
            print(f"ERROR: Failed to parse {EXAMPLE_FILE}: {e}", file=sys.stderr)
            sys.exit(1)

    if data is None or not isinstance(data, dict):
        print("ERROR: talisman.example.yml is empty or not a mapping", file=sys.stderr)
        sys.exit(1)

    if isinstance(data, dict) and len(data) == 0:
        print(f"WARN: {EXAMPLE_FILE} has no configured keys — all defaults will be injected", file=sys.stderr)

    # Add schema version for shard resolver compatibility
    data["_schema_version"] = 1

    # Inject documented defaults for commented-out top-level keys.
    # These keys appear only as comments in the example file but have
    # well-documented default values that the resolver needs.
    _inject_commented_defaults(data)

    output = json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False)

    # QUAL-012 FIX: Atomic output write via temp file + os.replace to prevent
    # partial reads if the build script crashes mid-write
    tmp_file = OUTPUT_FILE + ".tmp"
    with open(tmp_file, "w", encoding="utf-8") as f:
        f.write(output)
        f.write("\n")
    os.replace(tmp_file, OUTPUT_FILE)

    print(f"OK: wrote {OUTPUT_FILE} ({len(output)} bytes, {len(data)} top-level keys)")


def _inject_commented_defaults(data):
    """
    Inject defaults for keys that are commented out in the example YAML.

    The example file documents these as comments with default values.
    We add them here so the shard resolver has a complete defaults registry.

    NOTE: This script generates defaults only. Runtime resolution order:
    user talisman.yml > project talisman.yml > these defaults.
    This script does NOT overwrite user config.
    """
    _inject_toplevel_defaults(data)
    _inject_goldmask_defaults(data)
    _inject_review_defaults(data)
    _inject_work_defaults(data)
    _inject_remaining_section_defaults(data)


def _inject_toplevel_defaults(data):
    """Inject simple top-level keys with scalar or small dict defaults."""
    if "cost_tier" not in data:
        data["cost_tier"] = "balanced"

    if "plan" not in data:
        data["plan"] = {
            "freshness": {
                "enabled": True,
                "warn_threshold": 0.7,
                "block_threshold": 0.4,
                "max_commit_distance": 100,
            },
            "verification_patterns": [],
        }

    if "debug" not in data:
        data["debug"] = {
            "max_investigators": 4,
            "timeout_ms": 420000,
            "model": "sonnet",
            "re_triage_rounds": 1,
            "echo_on_verdict": True,
        }

    if "stack_awareness" not in data:
        data["stack_awareness"] = {
            "enabled": True,
            "confidence_threshold": 0.6,
            "max_stack_ashes": 3,
            "override": None,
            "custom_rules": [],
        }

    _inject_toplevel_feature_defaults(data)


def _inject_toplevel_feature_defaults(data):
    """Inject feature-flag top-level keys (design_sync, deploy, schema, etc.)."""
    # Source of truth: design-sync/SKILL.md "## Talisman Configuration" section. Keep in sync.
    data.setdefault("design_sync", {
        "enabled": False, "max_extraction_workers": 2,
        "max_implementation_workers": 3, "max_iteration_workers": 2,
        "max_iterations": 5, "iterate_enabled": False,
        "fidelity_threshold": 80, "token_snap_distance": 20,
        "figma_cache_ttl": 1800,
        "multi_url": True, "max_urls": 10,
        "max_total_components": 40,
        "state_detection_threshold": 0.75,
        "state_detection_ambiguous": 0.50,
        "relationship_confirmation": True,
        "max_extraction_timeout": 900000,
        "verification_gate": {
            "enabled": True, "warn_threshold": 20, "block_threshold": 40,
        },
        "trust_hierarchy": {
            "enabled": True, "low_confidence_threshold": 0.60,
        },
        "backend_impact": {
            "enabled": True, "auto_scope": "frontend-only",
        },
    })
    data.setdefault("deployment_verification", {
        "enabled": False, "auto_run_on_migrations": False,
        "output_dir": "tmp/deploy/", "monitoring_stack": None,
    })
    data.setdefault("schema_drift", {
        "enabled": True, "frameworks": [],
        "strict_mode": False, "ignore_paths": [],
    })
    data.setdefault("inner_flame", {
        "enabled": True, "block_on_fail": False,
        "confidence_floor": 60,
        "completeness_scoring": {
            "enabled": True, "threshold": 0.7,
            "research_threshold": 0.5,
        },
    })
    data.setdefault("question_relay", {
        "max_questions_per_worker": 3, "timeout_seconds": 120,
    })
    data.setdefault("arc_hierarchy", {"cleanup_child_branches": True})


def _inject_goldmask_defaults(data):
    """Inject goldmask defaults — large nested structure with layers config."""
    if "goldmask" not in data:
        defaults = _build_goldmask_defaults()
        _validate_goldmask_defaults(defaults)
        data["goldmask"] = defaults


def _validate_goldmask_defaults(goldmask):
    """Validate goldmask defaults structure integrity."""
    required_keys = {"enabled", "layers", "coordinator_model", "priority_weights"}
    missing = required_keys - set(goldmask.keys())
    if missing:
        print(f"WARN: goldmask defaults missing required keys: {missing}", file=sys.stderr)

    weights = goldmask.get("priority_weights", {})
    if weights:
        total = sum(weights.values())
        if abs(total - 1.0) > 0.01:
            print(f"WARN: goldmask priority_weights sum to {total:.4f}, expected ~1.0", file=sys.stderr)


def _build_goldmask_defaults():
    """Build the full goldmask default config dict."""
    return {
        "enabled": True,
        "layers": {
            "impact": {"enabled": True, "tracer_model": "haiku",
                       "max_tracers": 5, "tracer_timeout": 120000},
            "wisdom": {"enabled": True, "model": "sonnet",
                       "max_blame_files": 50, "max_findings_to_investigate": 20,
                       "intent_classification": True, "caution_threshold": 0.7},
            "lore": {"enabled": True, "model": "haiku",
                     "lookback_days": 180, "churn_threshold": 10,
                     "co_change_min_support": 3, "ownership_concentration_warn": 0.8},
            "cdd": {"enabled": True, "noisy_or_threshold": 0.6,
                    "swarm_detection": True, "swarm_lookback_commits": 50},
        },
        "coordinator_model": "sonnet",
        "double_check_top_n": 5,
        "priority_weights": {"impact": 0.4, "wisdom": 0.35, "lore": 0.25},
        "modes": {"quick": False, "deep": False},
        "forge": {"enabled": True},
        "mend": {"enabled": True, "inject_context": True, "quick_check": True},
        "devise": {"enabled": True, "depth": "basic"},
        "inspect": {"enabled": True, "wisdom_passthrough": True},
    }


def _inject_review_defaults(data):
    """Inject review sub-key defaults for commented-out config."""
    review = data.get("review", {})
    review.setdefault("auto_mend", False)
    review.setdefault("chunk_threshold", 20)
    review.setdefault("chunk_target_size", 15)
    review.setdefault("max_chunks", 5)
    review.setdefault("cross_cutting_pass", True)
    review.setdefault("diff_scope", {
        "enabled": True, "expansion": 8,
        "tag_pre_existing": True, "fix_pre_existing_p1": True,
    })
    review.setdefault("convergence", {
        "smart_scoring": True, "convergence_threshold": 0.7,
    })
    review.setdefault("enforcement_asymmetry", {
        "enabled": True, "security_always_strict": True,
        "new_file_threshold": 0.30, "high_risk_import_count": 5,
    })
    review.setdefault("context_intelligence", {
        "enabled": True, "scope_warning_threshold": 1000,
        "fetch_linked_issues": True, "max_pr_body_chars": 3000,
    })
    review.setdefault("linter_awareness", {"enabled": True, "always_review": []})
    _inject_review_arc_convergence_defaults(review)
    data["review"] = review


def _inject_review_arc_convergence_defaults(review):
    """Inject arc convergence defaults under the review namespace."""
    if "arc_convergence_tier_override" not in review:
        review["arc_convergence_tier_override"] = None
    if "arc_convergence_max_cycles" not in review:
        review["arc_convergence_max_cycles"] = None
    if "arc_convergence_min_cycles" not in review:
        review["arc_convergence_min_cycles"] = None
    if "arc_convergence_finding_threshold" not in review:
        review["arc_convergence_finding_threshold"] = 0
    if "arc_convergence_p2_threshold" not in review:
        review["arc_convergence_p2_threshold"] = 0
    if "arc_convergence_improvement_ratio" not in review:
        review["arc_convergence_improvement_ratio"] = 0.5


def _inject_work_defaults(data):
    """Inject work sub-key defaults for commented-out config."""
    work = data.get("work", {})
    if "worktree" not in work:
        work["worktree"] = {
            "enabled": False,
            "max_workers_per_wave": 3,
            "merge_strategy": "sequential",
            "auto_cleanup": True,
            "conflict_resolution": "escalate",
        }
    if "hierarchy" not in work:
        work["hierarchy"] = {
            "enabled": True,
            "max_children": 12,
            "max_backtracks": 1,
            "missing_prerequisite": "pause",
            "conflict_resolution": "pause",
            "integration_failure": "pause",
            "sync_main_before_pr": True,
            "cleanup_child_branches": True,
            "require_all_children": True,
            "test_timeout_ms": 300000,
            "merge_strategy": "merge",
        }
    if "unrestricted_shared_files" not in work:
        work["unrestricted_shared_files"] = []
    if "consistency" not in work:
        work["consistency"] = {"checks": []}
    data["work"] = work


def _inject_remaining_section_defaults(data):
    """Inject arc, audit, and echoes sub-key defaults."""
    arc = data.get("arc", {})
    if "no_test" not in arc.get("defaults", {}):
        arc.setdefault("defaults", {})["no_test"] = False
    if "consistency" not in arc:
        arc["consistency"] = {"checks": []}
    data["arc"] = arc

    audit = data.get("audit", {})
    if "incremental" not in audit:
        audit["incremental"] = {"enabled": False}
    if "dirs" not in audit:
        audit["dirs"] = None
    if "exclude_dirs" not in audit:
        audit["exclude_dirs"] = None
    data["audit"] = audit

    echoes = data.get("echoes", {})
    if "fts_enabled" not in echoes:
        echoes["fts_enabled"] = True
    if "auto_observation" not in echoes:
        echoes["auto_observation"] = True
    data["echoes"] = echoes


if __name__ == "__main__":
    build_defaults()
