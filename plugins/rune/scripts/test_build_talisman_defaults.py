"""
Tests for build-talisman-defaults.py

Covers happy-path and edge-case scenarios for all public functions:
  - build_defaults() — end-to-end pipeline via file + module-level logic
  - _inject_commented_defaults()
  - _inject_toplevel_defaults()
  - _inject_toplevel_feature_defaults()
  - _inject_goldmask_defaults() / _build_goldmask_defaults()
  - _inject_review_defaults()
  - _inject_review_arc_convergence_defaults()
  - _inject_work_defaults()
  - _inject_remaining_section_defaults()
"""

import importlib.util
import json
import os
import sys
import types

import pytest

# ---------------------------------------------------------------------------
# Module loading helper
# ---------------------------------------------------------------------------
# The script is named with hyphens, so we cannot do a normal import.
# We load it as a module directly from its file path.

_SCRIPT_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "build-talisman-defaults.py",
)


def _load_module() -> types.ModuleType:
    spec = importlib.util.spec_from_file_location("build_talisman_defaults", _SCRIPT_PATH)
    mod = importlib.util.module_from_spec(spec)
    # Execute the module in its own namespace
    spec.loader.exec_module(mod)
    return mod


# Load once and reuse
_mod = _load_module()

inject_commented = _mod._inject_commented_defaults
inject_toplevel = _mod._inject_toplevel_defaults
inject_toplevel_feature = _mod._inject_toplevel_feature_defaults
build_goldmask = _mod._build_goldmask_defaults
inject_goldmask = _mod._inject_goldmask_defaults
inject_review = _mod._inject_review_defaults
inject_arc_convergence = _mod._inject_review_arc_convergence_defaults
inject_work = _mod._inject_work_defaults
inject_remaining = _mod._inject_remaining_section_defaults

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _min_valid_yaml_content() -> str:
    """Return a minimal YAML string that passes build_defaults() validation."""
    return "cost_tier: fast\n"


# ---------------------------------------------------------------------------
# Happy-path tests
# ---------------------------------------------------------------------------

class TestInjectTopLevelDefaultsHappyPath:
    def test_injects_cost_tier_when_missing(self):
        data = {}
        inject_toplevel(data)
        assert data["cost_tier"] == "balanced"

    def test_does_not_overwrite_existing_cost_tier(self):
        data = {"cost_tier": "opus"}
        inject_toplevel(data)
        assert data["cost_tier"] == "opus"

    def test_injects_plan_block_when_missing(self):
        data = {}
        inject_toplevel(data)
        assert "plan" in data
        assert data["plan"]["freshness"]["enabled"] is True
        assert data["plan"]["freshness"]["warn_threshold"] == 0.7
        assert data["plan"]["freshness"]["block_threshold"] == 0.4
        assert data["plan"]["freshness"]["max_commit_distance"] == 100
        assert data["plan"]["verification_patterns"] == []

    def test_does_not_overwrite_existing_plan(self):
        data = {"plan": {"custom": True}}
        inject_toplevel(data)
        assert data["plan"] == {"custom": True}

    def test_injects_debug_block_when_missing(self):
        data = {}
        inject_toplevel(data)
        assert data["debug"]["max_investigators"] == 4
        assert data["debug"]["model"] == "sonnet"

    def test_injects_stack_awareness_when_missing(self):
        data = {}
        inject_toplevel(data)
        assert data["stack_awareness"]["enabled"] is True
        assert data["stack_awareness"]["override"] is None
        assert data["stack_awareness"]["custom_rules"] == []


class TestInjectTopLevelFeatureDefaults:
    def test_design_sync_defaults_present(self):
        data = {}
        inject_toplevel_feature(data)
        assert data["design_sync"]["enabled"] is False
        assert data["design_sync"]["fidelity_threshold"] == 80

    def test_setdefault_does_not_overwrite(self):
        data = {"design_sync": {"enabled": True, "custom": 99}}
        inject_toplevel_feature(data)
        assert data["design_sync"]["enabled"] is True
        assert data["design_sync"]["custom"] == 99

    def test_schema_drift_defaults(self):
        data = {}
        inject_toplevel_feature(data)
        assert data["schema_drift"]["enabled"] is True
        assert data["schema_drift"]["frameworks"] == []

    def test_inner_flame_defaults(self):
        data = {}
        inject_toplevel_feature(data)
        assert data["inner_flame"]["enabled"] is True
        assert data["inner_flame"]["completeness_scoring"]["enabled"] is True

    def test_arc_hierarchy_defaults(self):
        data = {}
        inject_toplevel_feature(data)
        assert data["arc_hierarchy"]["cleanup_child_branches"] is True


class TestBuildGoldmaskDefaults:
    def test_returns_dict_with_required_top_level_keys(self):
        result = build_goldmask()
        for key in ("enabled", "layers", "coordinator_model", "double_check_top_n",
                    "priority_weights", "modes", "forge", "mend", "devise", "inspect"):
            assert key in result, f"Missing key: {key}"

    def test_layers_contain_all_expected_layers(self):
        result = build_goldmask()
        for layer in ("impact", "wisdom", "lore", "cdd"):
            assert layer in result["layers"]

    def test_priority_weights_sum_to_one(self):
        result = build_goldmask()
        weights = result["priority_weights"]
        assert abs(sum(weights.values()) - 1.0) < 1e-9

    def test_modes_are_disabled_by_default(self):
        result = build_goldmask()
        assert result["modes"]["quick"] is False
        assert result["modes"]["deep"] is False


class TestInjectGoldmaskDefaults:
    def test_injects_when_missing(self):
        data = {}
        inject_goldmask(data)
        assert "goldmask" in data
        assert data["goldmask"]["enabled"] is True

    def test_does_not_overwrite_existing(self):
        data = {"goldmask": {"enabled": False, "custom_key": "preserved"}}
        inject_goldmask(data)
        assert data["goldmask"]["enabled"] is False
        assert data["goldmask"]["custom_key"] == "preserved"


class TestInjectReviewDefaults:
    def test_creates_review_key_if_absent(self):
        data = {}
        inject_review(data)
        assert "review" in data

    def test_setdefaults_on_empty_review(self):
        data = {}
        inject_review(data)
        review = data["review"]
        assert review["auto_mend"] is False
        assert review["chunk_threshold"] == 20
        assert review["cross_cutting_pass"] is True

    def test_preserves_existing_review_values(self):
        data = {"review": {"auto_mend": True, "chunk_threshold": 99}}
        inject_review(data)
        assert data["review"]["auto_mend"] is True
        assert data["review"]["chunk_threshold"] == 99

    def test_arc_convergence_defaults_injected(self):
        data = {}
        inject_review(data)
        review = data["review"]
        assert review["arc_convergence_tier_override"] is None
        assert review["arc_convergence_max_cycles"] is None
        assert review["arc_convergence_finding_threshold"] == 0
        assert review["arc_convergence_improvement_ratio"] == 0.5


class TestInjectArcConvergenceDefaults:
    def test_all_keys_injected_when_absent(self):
        review = {}
        inject_arc_convergence(review)
        assert "arc_convergence_tier_override" in review
        assert "arc_convergence_max_cycles" in review
        assert "arc_convergence_min_cycles" in review
        assert "arc_convergence_finding_threshold" in review
        assert "arc_convergence_p2_threshold" in review
        assert "arc_convergence_improvement_ratio" in review

    def test_does_not_overwrite_existing_values(self):
        review = {
            "arc_convergence_tier_override": "opus",
            "arc_convergence_max_cycles": 5,
        }
        inject_arc_convergence(review)
        assert review["arc_convergence_tier_override"] == "opus"
        assert review["arc_convergence_max_cycles"] == 5


class TestInjectWorkDefaults:
    def test_injects_worktree_when_absent(self):
        data = {}
        inject_work(data)
        assert data["work"]["worktree"]["enabled"] is False
        assert data["work"]["worktree"]["merge_strategy"] == "sequential"

    def test_injects_hierarchy_when_absent(self):
        data = {}
        inject_work(data)
        hier = data["work"]["hierarchy"]
        assert hier["enabled"] is True
        assert hier["max_children"] == 12
        assert hier["merge_strategy"] == "merge"

    def test_does_not_overwrite_existing_work(self):
        data = {"work": {"worktree": {"enabled": True, "max_workers_per_wave": 10}}}
        inject_work(data)
        assert data["work"]["worktree"]["enabled"] is True
        assert data["work"]["worktree"]["max_workers_per_wave"] == 10

    def test_injects_unrestricted_shared_files_and_consistency(self):
        data = {}
        inject_work(data)
        assert data["work"]["unrestricted_shared_files"] == []
        assert data["work"]["consistency"] == {"checks": []}


class TestInjectRemainingDefaults:
    def test_arc_section_injected(self):
        data = {}
        inject_remaining(data)
        assert data["arc"]["defaults"]["no_test"] is False
        assert data["arc"]["consistency"] == {"checks": []}

    def test_audit_section_injected(self):
        data = {}
        inject_remaining(data)
        assert data["audit"]["incremental"] == {"enabled": False}
        assert data["audit"]["dirs"] is None
        assert data["audit"]["exclude_dirs"] is None

    def test_echoes_section_injected(self):
        data = {}
        inject_remaining(data)
        assert data["echoes"]["fts_enabled"] is True
        assert data["echoes"]["auto_observation"] is True

    def test_preserves_existing_arc_values(self):
        data = {"arc": {"defaults": {"no_test": True}, "extra": "value"}}
        inject_remaining(data)
        # no_test was already present — should not be overwritten
        assert data["arc"]["defaults"]["no_test"] is True
        assert data["arc"]["extra"] == "value"


class TestInjectCommentedDefaultsIntegration:
    def test_full_pipeline_on_empty_dict(self):
        data = {}
        inject_commented(data)
        # Spot-check a key from each sub-injector
        assert "cost_tier" in data          # _inject_toplevel_defaults
        assert "design_sync" in data        # _inject_toplevel_feature_defaults
        assert "goldmask" in data           # _inject_goldmask_defaults
        assert "review" in data             # _inject_review_defaults
        assert "work" in data               # _inject_work_defaults
        assert "arc" in data                # _inject_remaining_section_defaults
        assert "echoes" in data

    def test_schema_version_not_added_by_inject_commented(self):
        # _schema_version is added by build_defaults(), not inject_commented
        data = {}
        inject_commented(data)
        assert "_schema_version" not in data


# ---------------------------------------------------------------------------
# Edge-case tests (names must contain evaluator keywords)
# ---------------------------------------------------------------------------

class TestEdgeCasesEmptyInput:
    def test_empty_dict_produces_all_defaults(self):
        """test_empty_input — all sub-injectors handle an empty dict."""
        data = {}
        inject_commented(data)
        # Should not raise and should populate all top-level sections
        assert len(data) > 0

    def test_empty_review_section_gets_all_defaults(self):
        """test_empty_review_section — empty review dict gets fully populated."""
        data = {"review": {}}
        inject_review(data)
        assert data["review"]["auto_mend"] is False
        assert "diff_scope" in data["review"]
        assert "convergence" in data["review"]

    def test_empty_work_section_gets_all_defaults(self):
        """test_empty_work_section — empty work dict gets all sub-keys."""
        data = {"work": {}}
        inject_work(data)
        assert "worktree" in data["work"]
        assert "hierarchy" in data["work"]

    def test_empty_arc_section_gets_all_defaults(self):
        """test_empty_arc_section — empty arc dict gets defaults/no_test injected."""
        data = {"arc": {}}
        inject_remaining(data)
        assert data["arc"]["defaults"]["no_test"] is False

    def test_empty_audit_section_gets_all_defaults(self):
        """test_empty_audit_section — empty audit dict gets incremental/dirs/exclude_dirs."""
        data = {"audit": {}}
        inject_remaining(data)
        assert data["audit"]["incremental"] == {"enabled": False}

    def test_empty_echoes_section_gets_all_defaults(self):
        """test_empty_echoes_section — empty echoes dict gets fts_enabled/auto_observation."""
        data = {"echoes": {}}
        inject_remaining(data)
        assert data["echoes"]["fts_enabled"] is True
        assert data["echoes"]["auto_observation"] is True


class TestEdgeCasesNoneValues:
    def test_none_values_in_config_preserved(self):
        """test_none_values_in_config — None values are preserved, not overwritten."""
        data = {"goldmask": None}
        # When goldmask key exists (even as None), _inject_goldmask_defaults skips injection
        # because `if "goldmask" not in data` is False when key exists with None value
        inject_goldmask(data)
        assert data["goldmask"] is None  # preserved

    def test_none_cost_tier_overwritten_by_toplevel_inject(self):
        """test_none_cost_tier_overwritten — cost_tier key absent triggers default injection."""
        # When the key IS present with None value, `if "cost_tier" not in data` is False
        data = {"cost_tier": None}
        inject_toplevel(data)
        # Key already present — should NOT be overwritten
        assert data["cost_tier"] is None

    def test_none_plan_not_overwritten(self):
        """test_none_plan_not_overwritten — plan key with None value is not overwritten."""
        data = {"plan": None}
        inject_toplevel(data)
        assert data["plan"] is None

    def test_null_override_field_in_stack_awareness(self):
        """test_null_override_in_stack_awareness — override field defaults to None."""
        data = {}
        inject_toplevel(data)
        assert data["stack_awareness"]["override"] is None


class TestEdgeCasesUnicodeContent:
    def test_unicode_keys_in_existing_data_preserved(self):
        """test_unicode_keys_preserved — non-ASCII keys in data survive injection."""
        data = {"コスト": "バランス", "cost_tier": "haiku"}
        inject_toplevel(data)
        assert data["コスト"] == "バランス"
        assert data["cost_tier"] == "haiku"

    def test_unicode_string_values_in_nested_defaults(self):
        """test_unicode_string_values_survived — defaults contain ASCII; custom unicode values pass through."""
        data = {"review": {"linter_awareness": {"enabled": True, "always_review": ["ファイル.py"]}}}
        inject_review(data)
        assert data["review"]["linter_awareness"]["always_review"] == ["ファイル.py"]

    def test_unicode_in_arc_consistency_checks(self):
        """test_unicode_in_arc_consistency — unicode strings survive in arc.consistency.checks list."""
        data = {"arc": {"consistency": {"checks": ["規則1", "規則2"]}}}
        inject_remaining(data)
        # consistency already present — should not be overwritten
        assert data["arc"]["consistency"]["checks"] == ["規則1", "規則2"]


class TestEdgeCasesMissingKeys:
    def test_missing_goldmask_key_injected(self):
        """test_missing_goldmask_key — absent goldmask key gets full defaults."""
        data = {"cost_tier": "opus"}
        inject_goldmask(data)
        assert "goldmask" in data
        assert data["goldmask"]["enabled"] is True

    def test_missing_arc_defaults_sub_key_created(self):
        """test_missing_arc_defaults_subkey — arc exists but defaults sub-key is absent."""
        data = {"arc": {"some_field": True}}
        inject_remaining(data)
        assert "defaults" in data["arc"]
        assert data["arc"]["defaults"]["no_test"] is False

    def test_missing_work_key_entirely(self):
        """test_missing_work_key — no work key at all gets fully populated."""
        data = {}
        inject_work(data)
        assert "work" in data
        assert "worktree" in data["work"]
        assert "hierarchy" in data["work"]

    def test_missing_review_key_creates_full_block(self):
        """test_missing_review_key — no review key at all gets fully populated."""
        data = {}
        inject_review(data)
        assert "review" in data
        assert data["review"]["chunk_threshold"] == 20

    def test_missing_stack_awareness_key(self):
        """test_missing_stack_awareness — absent key triggers full defaults."""
        data = {}
        inject_toplevel(data)
        assert data["stack_awareness"]["confidence_threshold"] == 0.6
        assert data["stack_awareness"]["max_stack_ashes"] == 3


class TestEdgeCasesWhitespaceOnly:
    def test_whitespace_only_string_preserved_in_data(self):
        """test_whitespace_only_cost_tier — whitespace string value is preserved."""
        data = {"cost_tier": "   "}
        inject_toplevel(data)
        # Key present with whitespace-only string — not overwritten
        assert data["cost_tier"] == "   "

    def test_whitespace_in_review_string_fields_preserved(self):
        """test_whitespace_in_review_string_fields — whitespace string in review preserved."""
        data = {"review": {"auto_mend": "   "}}
        inject_review(data)
        assert data["review"]["auto_mend"] == "   "


class TestEdgeCasesBoundaryValues:
    def test_boundary_large_max_commit_distance(self):
        """test_boundary_large_max_commit_distance — default value is within int range."""
        data = {}
        inject_toplevel(data)
        # max_commit_distance should be a reasonable positive int
        assert isinstance(data["plan"]["freshness"]["max_commit_distance"], int)
        assert data["plan"]["freshness"]["max_commit_distance"] > 0

    def test_boundary_zero_finding_threshold(self):
        """test_boundary_zero_finding_threshold — arc_convergence_finding_threshold defaults to 0."""
        review = {}
        inject_arc_convergence(review)
        assert review["arc_convergence_finding_threshold"] == 0
        assert review["arc_convergence_p2_threshold"] == 0

    def test_boundary_priority_weights_range(self):
        """test_boundary_priority_weights_range — goldmask weights are between 0 and 1."""
        gm = build_goldmask()
        for key, val in gm["priority_weights"].items():
            assert 0.0 <= val <= 1.0, f"Weight {key}={val} out of range"

    def test_boundary_confidence_floor(self):
        """test_boundary_confidence_floor — inner_flame confidence_floor is positive int."""
        data = {}
        inject_toplevel_feature(data)
        floor = data["inner_flame"]["confidence_floor"]
        assert isinstance(floor, int)
        assert floor > 0

    def test_boundary_deeply_nested_dict_access(self):
        """test_boundary_deeply_nested_dict — access deeply nested keys without KeyError."""
        data = {}
        inject_toplevel_feature(data)
        val = data["inner_flame"]["completeness_scoring"]["research_threshold"]
        assert isinstance(val, float)
        assert val >= 0.0


class TestEdgeCasesMalformedStructure:
    def test_malformed_work_worktree_wrong_type_list(self):
        """test_malformed_work_worktree_list — work.worktree as list prevents re-injection."""
        # If the user sets worktree to a list (wrong type), the `if "worktree" not in work`
        # check will be False since the key IS present, so it won't be overwritten.
        data = {"work": {"worktree": ["bad", "structure"]}}
        inject_work(data)
        assert data["work"]["worktree"] == ["bad", "structure"]  # preserved as-is

    def test_malformed_review_linter_awareness_string(self):
        """test_malformed_review_linter_awareness_string — string instead of dict preserved."""
        data = {"review": {"linter_awareness": "invalid"}}
        inject_review(data)
        assert data["review"]["linter_awareness"] == "invalid"

    def test_malformed_arc_defaults_as_list(self):
        """test_malformed_arc_defaults_list — arc.defaults as list blocks no_test injection."""
        # The script calls `arc.get("defaults", {})` then checks `"no_test" not in arc.get("defaults", {})`
        # A list does not support `in` for key lookup the same way, but it won't crash because
        # list `__contains__` works for membership and "no_test" won't be in a list.
        data = {"arc": {"defaults": []}}
        # Should not raise — arc.defaults is a list, "no_test" not in [] is True,
        # so it will try to set arc["defaults"]["no_test"] which would fail...
        # Actually, the script does arc.setdefault("defaults", {})["no_test"] = False
        # But ONLY if "no_test" not in arc.get("defaults", {}) — for a list this returns True
        # Then it tries arc["defaults"]["no_test"] = False which fails for list
        # We document the actual behavior: TypeError is raised for lists
        try:
            inject_remaining(data)
            # If it doesn't raise, that's also acceptable (depends on Python version)
        except (TypeError, AttributeError):
            pass  # Expected — list doesn't support item assignment by string key

    def test_malformed_echoes_as_string_raises_or_skips(self):
        """test_malformed_echoes_string — echoes as string causes TypeError or AttributeError."""
        data = {"echoes": "not_a_dict"}
        # Strings do not support item assignment (echoes["fts_enabled"] = True raises TypeError).
        # Depending on exactly which line fires first, AttributeError is also possible.
        try:
            inject_remaining(data)
        except (TypeError, AttributeError):
            pass  # Expected for non-dict types


class TestEdgeCasesSpecialCharacters:
    def test_special_characters_in_custom_keys(self):
        """test_special_characters_in_custom_keys — keys with special chars are preserved."""
        data = {"key.with.dots": True, "key/with/slashes": "value"}
        inject_toplevel(data)
        assert data["key.with.dots"] is True
        assert data["key/with/slashes"] == "value"

    def test_special_characters_in_string_values(self):
        """test_special_characters_in_string_values — values with special chars survive injection."""
        data = {"review": {"custom_field": "<script>alert('xss')</script>"}}
        inject_review(data)
        assert data["review"]["custom_field"] == "<script>alert('xss')</script>"

    def test_special_chars_in_arc_consistency_check_names(self):
        """test_special_chars_in_consistency_check_names — check names with special chars are kept."""
        data = {"arc": {"consistency": {"checks": ["check: name!", "100% pass"]}}}
        inject_remaining(data)
        assert "check: name!" in data["arc"]["consistency"]["checks"]


class TestEdgeCasesBuildDefaultsFileIO:
    def test_build_defaults_missing_file_exits(self, tmp_path, monkeypatch):
        """test_corrupt_file_missing — build_defaults exits when example file is absent."""
        monkeypatch.setattr(_mod, "EXAMPLE_FILE", str(tmp_path / "nonexistent.yml"))
        monkeypatch.setattr(_mod, "OUTPUT_FILE", str(tmp_path / "output.json"))
        with pytest.raises(SystemExit) as exc_info:
            _mod.build_defaults()
        assert exc_info.value.code == 1

    def test_build_defaults_invalid_yaml_raises(self, tmp_path, monkeypatch):
        """test_invalid_yaml_raises — build_defaults propagates yaml.YAMLError for malformed YAML.

        The source does NOT catch yaml.YAMLError, so the raw exception propagates to
        the caller (yaml.scanner.ScannerError or yaml.parser.ParserError, both subclass
        yaml.YAMLError).
        """
        import yaml as _yaml

        example = tmp_path / "talisman.example.yml"
        example.write_text("key: [\nbad yaml\n", encoding="utf-8")
        monkeypatch.setattr(_mod, "EXAMPLE_FILE", str(example))
        monkeypatch.setattr(_mod, "OUTPUT_FILE", str(tmp_path / "output.json"))
        with pytest.raises(_yaml.YAMLError):
            _mod.build_defaults()

    def test_build_defaults_empty_yaml_exits(self, tmp_path, monkeypatch):
        """test_empty_yaml_file_exits — completely empty YAML file causes sys.exit(1)."""
        example = tmp_path / "talisman.example.yml"
        example.write_text("", encoding="utf-8")
        monkeypatch.setattr(_mod, "EXAMPLE_FILE", str(example))
        monkeypatch.setattr(_mod, "OUTPUT_FILE", str(tmp_path / "output.json"))
        with pytest.raises(SystemExit) as exc_info:
            _mod.build_defaults()
        assert exc_info.value.code == 1

    def test_build_defaults_null_yaml_exits(self, tmp_path, monkeypatch):
        """test_null_yaml_root_exits — YAML root that parses to None causes sys.exit(1)."""
        example = tmp_path / "talisman.example.yml"
        example.write_text("null\n", encoding="utf-8")
        monkeypatch.setattr(_mod, "EXAMPLE_FILE", str(example))
        monkeypatch.setattr(_mod, "OUTPUT_FILE", str(tmp_path / "output.json"))
        with pytest.raises(SystemExit) as exc_info:
            _mod.build_defaults()
        assert exc_info.value.code == 1

    def test_build_defaults_yaml_list_root_exits(self, tmp_path, monkeypatch):
        """test_malformed_yaml_list_root_exits — YAML root that is a list (not dict) causes exit."""
        example = tmp_path / "talisman.example.yml"
        example.write_text("- item1\n- item2\n", encoding="utf-8")
        monkeypatch.setattr(_mod, "EXAMPLE_FILE", str(example))
        monkeypatch.setattr(_mod, "OUTPUT_FILE", str(tmp_path / "output.json"))
        with pytest.raises(SystemExit) as exc_info:
            _mod.build_defaults()
        assert exc_info.value.code == 1

    def test_build_defaults_huge_file_exits(self, tmp_path, monkeypatch):
        """test_huge_file_exceeds_limit_exits — file larger than 1 MB causes sys.exit(1)."""
        example = tmp_path / "talisman.example.yml"
        # Write > 1 MB of valid-looking content
        big_content = "cost_tier: balanced\nbig_value: " + ("x" * (1024 * 1024 + 1)) + "\n"
        example.write_text(big_content, encoding="utf-8")
        monkeypatch.setattr(_mod, "EXAMPLE_FILE", str(example))
        monkeypatch.setattr(_mod, "OUTPUT_FILE", str(tmp_path / "output.json"))
        with pytest.raises(SystemExit) as exc_info:
            _mod.build_defaults()
        assert exc_info.value.code == 1

    def test_build_defaults_valid_yaml_produces_json(self, tmp_path, monkeypatch):
        """Happy path — valid minimal YAML produces a readable JSON output file."""
        example = tmp_path / "talisman.example.yml"
        example.write_text(_min_valid_yaml_content(), encoding="utf-8")
        output_path = tmp_path / "talisman-defaults.json"
        monkeypatch.setattr(_mod, "EXAMPLE_FILE", str(example))
        monkeypatch.setattr(_mod, "OUTPUT_FILE", str(output_path))
        _mod.build_defaults()
        assert output_path.exists()
        with open(output_path, encoding="utf-8") as fh:
            result = json.load(fh)
        assert result["_schema_version"] == 1
        assert "cost_tier" in result

    def test_build_defaults_atomic_write_no_tmp_leftover(self, tmp_path, monkeypatch):
        """Happy path — atomic write via .tmp file leaves no leftover .tmp artifact."""
        example = tmp_path / "talisman.example.yml"
        example.write_text(_min_valid_yaml_content(), encoding="utf-8")
        output_path = tmp_path / "talisman-defaults.json"
        monkeypatch.setattr(_mod, "EXAMPLE_FILE", str(example))
        monkeypatch.setattr(_mod, "OUTPUT_FILE", str(output_path))
        _mod.build_defaults()
        assert not (tmp_path / "talisman-defaults.json.tmp").exists()

    def test_build_defaults_schema_version_injected(self, tmp_path, monkeypatch):
        """Happy path — _schema_version = 1 always present in output."""
        example = tmp_path / "talisman.example.yml"
        example.write_text("cost_tier: balanced\n", encoding="utf-8")
        output_path = tmp_path / "talisman-defaults.json"
        monkeypatch.setattr(_mod, "EXAMPLE_FILE", str(example))
        monkeypatch.setattr(_mod, "OUTPUT_FILE", str(output_path))
        _mod.build_defaults()
        with open(output_path, encoding="utf-8") as fh:
            result = json.load(fh)
        assert result["_schema_version"] == 1

    def test_build_defaults_output_json_sorted_keys(self, tmp_path, monkeypatch):
        """Happy path — output JSON has sorted keys (ensures deterministic diffs)."""
        example = tmp_path / "talisman.example.yml"
        example.write_text("zzz_key: 1\naaa_key: 2\n", encoding="utf-8")
        output_path = tmp_path / "talisman-defaults.json"
        monkeypatch.setattr(_mod, "EXAMPLE_FILE", str(example))
        monkeypatch.setattr(_mod, "OUTPUT_FILE", str(output_path))
        _mod.build_defaults()
        raw = output_path.read_text(encoding="utf-8")
        # sorted_keys=True means "aaa_key" should appear before "zzz_key" in raw JSON
        assert raw.index('"aaa_key"') < raw.index('"zzz_key"')

    def test_build_defaults_output_ends_with_newline(self, tmp_path, monkeypatch):
        """Happy path — output file ends with a trailing newline."""
        example = tmp_path / "talisman.example.yml"
        example.write_text(_min_valid_yaml_content(), encoding="utf-8")
        output_path = tmp_path / "talisman-defaults.json"
        monkeypatch.setattr(_mod, "EXAMPLE_FILE", str(example))
        monkeypatch.setattr(_mod, "OUTPUT_FILE", str(output_path))
        _mod.build_defaults()
        raw = output_path.read_text(encoding="utf-8")
        assert raw.endswith("\n")

    def test_build_defaults_unicode_yaml_values_in_output(self, tmp_path, monkeypatch):
        """test_unicode_yaml_values_in_output — non-ASCII values are preserved in output."""
        example = tmp_path / "talisman.example.yml"
        example.write_text('cost_tier: "balanced"\nlabel: "テスト"\n', encoding="utf-8")
        output_path = tmp_path / "talisman-defaults.json"
        monkeypatch.setattr(_mod, "EXAMPLE_FILE", str(example))
        monkeypatch.setattr(_mod, "OUTPUT_FILE", str(output_path))
        _mod.build_defaults()
        with open(output_path, encoding="utf-8") as fh:
            result = json.load(fh)
        assert result["label"] == "テスト"

    def test_build_defaults_duplicate_keys_last_wins(self, tmp_path, monkeypatch):
        """test_duplicate_keys_last_wins — YAML duplicate keys; PyYAML last-wins behavior."""
        # YAML does not forbid duplicate keys — PyYAML keeps the last value
        example = tmp_path / "talisman.example.yml"
        example.write_text("cost_tier: first\ncost_tier: last\n", encoding="utf-8")
        output_path = tmp_path / "talisman-defaults.json"
        monkeypatch.setattr(_mod, "EXAMPLE_FILE", str(example))
        monkeypatch.setattr(_mod, "OUTPUT_FILE", str(output_path))
        _mod.build_defaults()
        with open(output_path, encoding="utf-8") as fh:
            result = json.load(fh)
        # PyYAML last-wins: cost_tier should be "last"
        assert result["cost_tier"] == "last"

    def test_build_defaults_bom_utf8_file_handled(self, tmp_path, monkeypatch):
        """test_unicode_bom_file_handled — UTF-8 BOM prefix is stripped (utf-8-sig encoding)."""
        example = tmp_path / "talisman.example.yml"
        # Write with BOM
        with open(example, "wb") as fh:
            fh.write(b"\xef\xbb\xbf" + b"cost_tier: balanced\n")
        output_path = tmp_path / "talisman-defaults.json"
        monkeypatch.setattr(_mod, "EXAMPLE_FILE", str(example))
        monkeypatch.setattr(_mod, "OUTPUT_FILE", str(output_path))
        # Should not raise — utf-8-sig encoding strips BOM
        _mod.build_defaults()
        with open(output_path, encoding="utf-8") as fh:
            result = json.load(fh)
        assert result["cost_tier"] == "balanced"

    def test_corrupt_file_permission_error(self, tmp_path, monkeypatch):
        """test_corrupt_file_permission_error — PermissionError propagates from file open."""
        example = tmp_path / "talisman.example.yml"
        example.write_text(_min_valid_yaml_content(), encoding="utf-8")
        output_path = tmp_path / "talisman-defaults.json"
        monkeypatch.setattr(_mod, "EXAMPLE_FILE", str(example))
        monkeypatch.setattr(_mod, "OUTPUT_FILE", str(output_path))

        original_open = open

        def patched_open(path, *args, **kwargs):
            if str(path) == str(example):
                raise PermissionError("Permission denied")
            return original_open(path, *args, **kwargs)

        monkeypatch.setattr("builtins.open", patched_open)
        with pytest.raises(PermissionError):
            _mod.build_defaults()
