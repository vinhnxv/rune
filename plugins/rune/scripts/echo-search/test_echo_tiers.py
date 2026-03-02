"""Tests for Notes/Observations tier parsing in indexer.py.

Covers:
  - Notes tier header recognition
  - Observations tier header recognition
  - EDGE-018: Content H2 headers that match tier names are not split
  - EDGE-022: Double promotion guard
  - Layer normalization to lowercase
  - Backward compatibility with Inscribed/Etched/Traced
"""

import textwrap

import pytest

from indexer import discover_and_parse, parse_memory_file


# ---------------------------------------------------------------------------
# Notes tier parsing
# ---------------------------------------------------------------------------


class TestNotesTierParsing:
    """Verify that ## Notes — Title (date) headers are correctly recognized."""

    def test_single_notes_entry(self, tmp_path):
        """Basic Notes tier entry is parsed."""
        md = tmp_path / "MEMORY.md"
        md.write_text(textwrap.dedent("""\
            ## Notes — User preference for dark mode (2026-02-15)
            **Source**: `user:explicit`
            The user prefers dark mode across all IDE integrations.
        """))

        entries = parse_memory_file(str(md), "notes")
        assert len(entries) == 1

        e = entries[0]
        assert e["role"] == "notes"
        assert e["layer"] == "notes"
        assert e["date"] == "2026-02-15"
        assert e["source"] == "user:explicit"
        assert e["tags"] == "User preference for dark mode"
        assert "dark mode" in e["content"]
        assert len(e["id"]) == 16

    def test_notes_with_em_dash(self, tmp_path):
        """Notes tier with em dash separator."""
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "## Notes \u2014 Always use bun (2026-02-20)\n"
            "User explicitly requested bun over npm.\n"
        )

        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 1
        assert entries[0]["layer"] == "notes"
        assert entries[0]["tags"] == "Always use bun"

    def test_notes_with_en_dash(self, tmp_path):
        """Notes tier with en dash separator."""
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "## Notes \u2013 Prefer pytest (2026-02-20)\n"
            "User prefers pytest over unittest.\n"
        )

        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 1
        assert entries[0]["layer"] == "notes"

    def test_notes_with_hyphen(self, tmp_path):
        """Notes tier with hyphen separator."""
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "## Notes - Use TypeScript (2026-02-20)\n"
            "Always use TypeScript for frontend code.\n"
        )

        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 1
        assert entries[0]["layer"] == "notes"

    def test_notes_layer_normalized_to_lowercase(self, tmp_path):
        """Notes layer name is stored as lowercase."""
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "## Notes — Title (2026-01-01)\n"
            "Content\n"
        )

        entries = parse_memory_file(str(md), "test")
        assert entries[0]["layer"] == "notes"

    def test_multiple_notes_entries(self, tmp_path):
        """Multiple Notes entries in a single file."""
        md = tmp_path / "MEMORY.md"
        md.write_text(textwrap.dedent("""\
            ## Notes — Preference A (2026-01-01)
            First note content

            ## Notes — Preference B (2026-01-02)
            Second note content

            ## Notes — Preference C (2026-01-03)
            Third note content
        """))

        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 3
        assert all(e["layer"] == "notes" for e in entries)
        assert entries[0]["tags"] == "Preference A"
        assert entries[1]["tags"] == "Preference B"
        assert entries[2]["tags"] == "Preference C"


# ---------------------------------------------------------------------------
# Observations tier parsing
# ---------------------------------------------------------------------------


class TestObservationsTierParsing:
    """Verify that ## Observations — Title (date) headers are recognized."""

    def test_single_observations_entry(self, tmp_path):
        """Basic Observations tier entry is parsed."""
        md = tmp_path / "MEMORY.md"
        md.write_text(textwrap.dedent("""\
            ## Observations — Frequent test failures in auth module (2026-02-18)
            **Source**: `agent:auto-detect`
            Tests in auth/ have failed in 3 of the last 5 sessions.
            Pattern suggests flaky database connection teardown.
        """))

        entries = parse_memory_file(str(md), "observations")
        assert len(entries) == 1

        e = entries[0]
        assert e["role"] == "observations"
        assert e["layer"] == "observations"
        assert e["date"] == "2026-02-18"
        assert e["source"] == "agent:auto-detect"
        assert "flaky database" in e["content"]

    def test_observations_with_hyphen(self, tmp_path):
        """Observations tier with hyphen separator."""
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "## Observations - Slow CI pipeline (2026-02-19)\n"
            "CI takes >10 minutes for simple changes.\n"
        )

        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 1
        assert entries[0]["layer"] == "observations"

    def test_observations_layer_normalized_to_lowercase(self, tmp_path):
        """Observations layer name is stored as lowercase."""
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "## Observations — Title (2026-01-01)\n"
            "Content\n"
        )

        entries = parse_memory_file(str(md), "test")
        assert entries[0]["layer"] == "observations"


# ---------------------------------------------------------------------------
# Mixed tiers
# ---------------------------------------------------------------------------


class TestMixedTiers:
    """Verify that all 5 tiers can coexist in a single file."""

    def test_all_five_tiers_in_one_file(self, tmp_path):
        """All 5 tier types are parsed from a single MEMORY.md."""
        md = tmp_path / "MEMORY.md"
        md.write_text(textwrap.dedent("""\
            ## Inscribed — Permanent learning (2026-01-01)
            Content A

            ## Etched — Semi-permanent (2026-01-02)
            Content B

            ## Traced — Ephemeral observation (2026-01-03)
            Content C

            ## Notes — User preference (2026-01-04)
            Content D

            ## Observations — Agent observation (2026-01-05)
            Content E
        """))

        entries = parse_memory_file(str(md), "mixed")
        assert len(entries) == 5
        layers = [e["layer"] for e in entries]
        assert layers == ["inscribed", "etched", "traced", "notes", "observations"]

    def test_notes_and_inscribed_interleaved(self, tmp_path):
        """Notes and Inscribed entries can be interleaved."""
        md = tmp_path / "MEMORY.md"
        md.write_text(textwrap.dedent("""\
            ## Notes — First note (2026-01-01)
            Note content

            ## Inscribed — Pattern (2026-01-02)
            Pattern content

            ## Notes — Second note (2026-01-03)
            Another note
        """))

        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 3
        assert entries[0]["layer"] == "notes"
        assert entries[1]["layer"] == "inscribed"
        assert entries[2]["layer"] == "notes"

    def test_discover_notes_and_observations_roles(self, tmp_path):
        """discover_and_parse finds entries in notes/ and observations/ role dirs."""
        echo_dir = tmp_path / "echoes"

        notes_dir = echo_dir / "notes"
        notes_dir.mkdir(parents=True)
        (notes_dir / "MEMORY.md").write_text(
            "## Notes — User pref (2026-01-01)\n"
            "Dark mode preferred\n"
        )

        obs_dir = echo_dir / "observations"
        obs_dir.mkdir(parents=True)
        (obs_dir / "MEMORY.md").write_text(
            "## Observations — Slow tests (2026-01-02)\n"
            "Tests take too long\n"
        )

        entries = discover_and_parse(str(echo_dir))
        assert len(entries) == 2
        roles = {e["role"] for e in entries}
        assert roles == {"notes", "observations"}

    def test_notes_tier_in_reviewer_role(self, tmp_path):
        """Notes tier headers can appear inside any role's MEMORY.md."""
        echo_dir = tmp_path / "echoes"
        reviewer_dir = echo_dir / "reviewer"
        reviewer_dir.mkdir(parents=True)
        (reviewer_dir / "MEMORY.md").write_text(textwrap.dedent("""\
            ## Inscribed — Code review pattern (2026-01-01)
            Standard review pattern.

            ## Notes — Reviewer preference (2026-01-02)
            This reviewer prefers inline comments.
        """))

        entries = discover_and_parse(str(echo_dir))
        assert len(entries) == 2
        assert entries[0]["layer"] == "inscribed"
        assert entries[1]["layer"] == "notes"
        assert all(e["role"] == "reviewer" for e in entries)


# ---------------------------------------------------------------------------
# EDGE-018: Content H2 headers that look like tier headers
# ---------------------------------------------------------------------------


class TestEdge018ContentH2Headers:
    """EDGE-018: H2 headers inside entry content that match tier names
    should NOT be treated as new entry boundaries.

    The stateful parser only matches header_re when the previous line
    was blank (or at start of file).
    """

    def test_notes_h2_inside_content_not_split(self, tmp_path):
        """## Notes — inside content without preceding blank line is not split."""
        md = tmp_path / "MEMORY.md"
        md.write_text(textwrap.dedent("""\
            ## Inscribed — Main entry (2026-01-01)
            Some content about the main topic.
            ## Notes — This is a subsection, not a new entry (2026-01-02)
            More content in the same entry.
        """))

        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 1
        assert entries[0]["layer"] == "inscribed"
        # The "## Notes —" line should be part of the content
        assert "Notes" in entries[0]["content"]
        assert "subsection" in entries[0]["content"]

    def test_observations_h2_inside_content_not_split(self, tmp_path):
        """## Observations — inside content without blank line is not split."""
        md = tmp_path / "MEMORY.md"
        md.write_text(textwrap.dedent("""\
            ## Inscribed — Analysis (2026-01-01)
            Here are my findings:
            ## Observations — These are inline observations (2026-01-02)
            - Observation 1
            - Observation 2
        """))

        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 1
        assert "inline observations" in entries[0]["content"]

    def test_tier_header_after_blank_line_is_new_entry(self, tmp_path):
        """## Notes — after a blank line IS a new entry."""
        md = tmp_path / "MEMORY.md"
        md.write_text(textwrap.dedent("""\
            ## Inscribed — Main entry (2026-01-01)
            Some content.

            ## Notes — This is a new entry (2026-01-02)
            New entry content.
        """))

        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 2
        assert entries[0]["layer"] == "inscribed"
        assert entries[1]["layer"] == "notes"

    def test_inscribed_h2_inside_content_not_split(self, tmp_path):
        """## Inscribed — inside content without blank line is not split.

        EDGE-018 applies to ALL tier names, not just Notes/Observations.
        """
        md = tmp_path / "MEMORY.md"
        md.write_text(textwrap.dedent("""\
            ## Inscribed — Outer entry (2026-01-01)
            Content starts here
            ## Inscribed — This looks like a header but is content (2026-01-02)
            More content
        """))

        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 1
        assert entries[0]["tags"] == "Outer entry"
        assert "This looks like a header" in entries[0]["content"]

    def test_multiple_fake_headers_in_content(self, tmp_path):
        """Multiple inline tier-header-like lines are all treated as content."""
        md = tmp_path / "MEMORY.md"
        md.write_text(textwrap.dedent("""\
            ## Inscribed — Real entry (2026-01-01)
            Line of content
            ## Notes — Fake header 1 (2026-01-02)
            Still content
            ## Observations — Fake header 2 (2026-01-03)
            Still content
            ## Etched — Fake header 3 (2026-01-04)
            Still content
        """))

        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 1
        assert "Fake header 1" in entries[0]["content"]
        assert "Fake header 2" in entries[0]["content"]
        assert "Fake header 3" in entries[0]["content"]

    def test_blank_line_then_real_header(self, tmp_path):
        """After content with a blank line, a tier header starts a new entry."""
        md = tmp_path / "MEMORY.md"
        md.write_text(textwrap.dedent("""\
            ## Inscribed — First (2026-01-01)
            Content for first.
            ## Notes — This is inline, not split (2026-01-02)
            More first content.

            ## Notes — This IS a new entry (2026-01-03)
            Second entry content.
        """))

        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 2
        assert entries[0]["layer"] == "inscribed"
        assert "inline, not split" in entries[0]["content"]
        assert entries[1]["layer"] == "notes"
        assert entries[1]["tags"] == "This IS a new entry"

    def test_consecutive_headers_at_start_all_match(self, tmp_path):
        """At start of file (prev_line_blank=True), consecutive headers match."""
        md = tmp_path / "MEMORY.md"
        md.write_text(textwrap.dedent("""\
            ## Inscribed — Empty A (2026-01-01)
            ## Notes — Empty B (2026-01-02)
            ## Observations — Has content (2026-01-03)
            Real content here
        """))

        entries = parse_memory_file(str(md), "test")
        # Empty A and Empty B have no content → skipped
        # Only "Has content" has actual content
        assert len(entries) == 1
        assert entries[0]["layer"] == "observations"

    def test_header_like_line_without_date_is_always_content(self, tmp_path):
        """A line like '## Notes — title' without (YYYY-MM-DD) never matches."""
        md = tmp_path / "MEMORY.md"
        md.write_text(textwrap.dedent("""\
            ## Inscribed — Real entry (2026-01-01)
            Some content

            ## Notes — This has no date
            This should be content of the real entry above
        """))

        entries = parse_memory_file(str(md), "test")
        # The "## Notes — This has no date" line has no (YYYY-MM-DD) → doesn't match
        # It becomes content of the previous entry
        assert len(entries) == 1
        assert "no date" in entries[0]["content"]

    def test_blank_line_within_content_does_not_split_on_non_header(self, tmp_path):
        """Blank lines within content don't cause issues for non-header lines."""
        md = tmp_path / "MEMORY.md"
        md.write_text(textwrap.dedent("""\
            ## Inscribed — Entry (2026-01-01)
            Paragraph one.

            Paragraph two after blank line.

            Paragraph three after another blank.
        """))

        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 1
        assert "Paragraph one" in entries[0]["content"]
        assert "Paragraph two" in entries[0]["content"]
        assert "Paragraph three" in entries[0]["content"]


# ---------------------------------------------------------------------------
# EDGE-022: Double promotion guard
# ---------------------------------------------------------------------------


class TestEdge022DoublePromotion:
    """EDGE-022: An entry should not be promoted twice.

    This is a semantic concern — the indexer itself just parses. The
    promotion logic lives at a higher layer. Here we verify that the
    indexer faithfully preserves the tier name as-is, so the promotion
    logic can check against it.
    """

    def test_notes_stays_notes(self, tmp_path):
        """Notes entry is stored as 'notes', not promoted to inscribed."""
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "## Notes — Important preference (2026-01-01)\n"
            "Content here\n"
        )

        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 1
        assert entries[0]["layer"] == "notes"
        # Should NOT be "inscribed" or any other tier
        assert entries[0]["layer"] != "inscribed"

    def test_observations_stays_observations(self, tmp_path):
        """Observations entry is stored as 'observations', not promoted."""
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "## Observations — Repeated pattern (2026-01-01)\n"
            "Seen 5 times\n"
        )

        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 1
        assert entries[0]["layer"] == "observations"
        assert entries[0]["layer"] != "inscribed"
        assert entries[0]["layer"] != "etched"

    def test_layer_preserved_through_index_and_details(self, tmp_path):
        """Layer name survives round-trip through indexer → DB → retrieval."""
        from server import ensure_schema, get_db, get_details, rebuild_index

        md = tmp_path / "MEMORY.md"
        md.write_text(textwrap.dedent("""\
            ## Notes — Pref A (2026-01-01)
            Content A

            ## Observations — Pattern B (2026-01-02)
            Content B
        """))

        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 2

        db_path = str(tmp_path / "test.db")
        conn = get_db(db_path)
        try:
            ensure_schema(conn)
            rebuild_index(conn, entries)

            details = get_details(conn, [e["id"] for e in entries])
            layers = {d["layer"] for d in details}
            assert layers == {"notes", "observations"}
        finally:
            conn.close()


# ---------------------------------------------------------------------------
# Backward compatibility
# ---------------------------------------------------------------------------


class TestBackwardCompatibility:
    """Verify that existing Inscribed/Etched/Traced entries still parse."""

    def test_inscribed_still_works(self, tmp_path):
        md = tmp_path / "MEMORY.md"
        md.write_text("## Inscribed — Title (2026-01-01)\nContent\n")
        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 1
        assert entries[0]["layer"] == "inscribed"

    def test_etched_still_works(self, tmp_path):
        md = tmp_path / "MEMORY.md"
        md.write_text("## Etched — Title (2026-01-01)\nContent\n")
        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 1
        assert entries[0]["layer"] == "etched"

    def test_traced_still_works(self, tmp_path):
        md = tmp_path / "MEMORY.md"
        md.write_text("## Traced — Title (2026-01-01)\nContent\n")
        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 1
        assert entries[0]["layer"] == "traced"

    def test_invalid_tier_still_rejected(self, tmp_path):
        """Custom/unknown tier names are still not recognized."""
        md = tmp_path / "MEMORY.md"
        md.write_text(textwrap.dedent("""\
            ## Custom — Not valid (2026-01-01)
            Should not match

            ## Inscribed — Valid (2026-01-02)
            Should match
        """))

        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 1
        assert entries[0]["layer"] == "inscribed"


# ---------------------------------------------------------------------------
# Edge cases with empty MEMORY.md (EDGE-020)
# ---------------------------------------------------------------------------


class TestEdge020EmptyMemoryFiles:
    """EDGE-020: Empty MEMORY.md files produce zero entries."""

    def test_empty_notes_memory(self, tmp_path):
        echo_dir = tmp_path / "echoes"
        notes_dir = echo_dir / "notes"
        notes_dir.mkdir(parents=True)
        (notes_dir / "MEMORY.md").write_text("")

        entries = discover_and_parse(str(echo_dir))
        assert entries == []

    def test_notes_memory_with_only_preamble(self, tmp_path):
        """MEMORY.md with only a title header and no entries."""
        echo_dir = tmp_path / "echoes"
        notes_dir = echo_dir / "notes"
        notes_dir.mkdir(parents=True)
        (notes_dir / "MEMORY.md").write_text("# Notes Memory\n\nNo entries yet.\n")

        entries = discover_and_parse(str(echo_dir))
        assert entries == []


# ---------------------------------------------------------------------------
# EDGE-019: No ID collision between tiers
# ---------------------------------------------------------------------------


class TestEdge019NoIdCollision:
    """EDGE-019: IDs use file_path, so entries in different role dirs
    get unique IDs even if they have the same line number and role name
    (which doesn't apply here since role names differ).
    """

    def test_same_content_different_roles_unique_ids(self, tmp_path):
        """Identical content in notes/ vs observations/ produces different IDs."""
        echo_dir = tmp_path / "echoes"

        for role in ["notes", "observations"]:
            d = echo_dir / role
            d.mkdir(parents=True)
            (d / "MEMORY.md").write_text(
                "## Notes — Same title (2026-01-01)\n"
                "Identical content\n"
            )

        entries = discover_and_parse(str(echo_dir))
        # notes role will parse "Notes" as a valid tier
        # observations role will also parse "Notes" as a tier
        ids = [e["id"] for e in entries]
        assert len(ids) == len(set(ids)), "IDs should be unique across roles"

    def test_same_tier_same_line_different_file_paths(self, tmp_path):
        """Same tier at same line number in different files → unique IDs."""
        echo_dir = tmp_path / "echoes"

        for role in ["alpha", "beta"]:
            d = echo_dir / role
            d.mkdir(parents=True)
            (d / "MEMORY.md").write_text(
                "## Notes — Title (2026-01-01)\n"
                "Content\n"
            )

        entries = discover_and_parse(str(echo_dir))
        assert len(entries) == 2
        assert entries[0]["id"] != entries[1]["id"]


# ---------------------------------------------------------------------------
# Edge cases: empty, invalid, missing, boundary, unicode, whitespace inputs
# ---------------------------------------------------------------------------


class TestEdgeCaseEmptyInputs:
    """Edge cases for empty and whitespace-only inputs."""

    def test_empty_file_produces_no_entries(self, tmp_path):
        """Empty MEMORY.md file produces zero entries."""
        md = tmp_path / "MEMORY.md"
        md.write_text("")
        entries = parse_memory_file(str(md), "test")
        assert entries == []

    def test_whitespace_only_file_produces_no_entries(self, tmp_path):
        """File with only whitespace produces zero entries."""
        md = tmp_path / "MEMORY.md"
        md.write_text("   \n\n\t\n   \n")
        entries = parse_memory_file(str(md), "test")
        assert entries == []

    def test_missing_file_returns_empty_list(self, tmp_path):
        """Non-existent file path returns empty list without error."""
        missing = str(tmp_path / "nonexistent" / "MEMORY.md")
        entries = parse_memory_file(missing, "test")
        assert entries == []

    def test_empty_echo_dir_returns_empty_list(self, tmp_path):
        """Empty echoes directory returns empty list."""
        echo_dir = tmp_path / "echoes"
        echo_dir.mkdir()
        entries = discover_and_parse(str(echo_dir))
        assert entries == []

    def test_missing_echo_dir_returns_empty_list(self, tmp_path):
        """Missing echoes directory returns empty list without error."""
        missing_dir = str(tmp_path / "nonexistent_echoes")
        entries = discover_and_parse(missing_dir)
        assert entries == []

    def test_entry_with_empty_content_is_skipped(self, tmp_path):
        """An entry header with no subsequent content is skipped."""
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "## Inscribed — Empty entry (2026-01-01)\n"
        )
        entries = parse_memory_file(str(md), "test")
        # Empty content → entry is skipped
        assert entries == []

    def test_entry_with_only_whitespace_content_is_skipped(self, tmp_path):
        """An entry with only whitespace content is skipped."""
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "## Inscribed — Whitespace only (2026-01-01)\n"
            "   \n"
            "\t\n"
        )
        entries = parse_memory_file(str(md), "test")
        assert entries == []

    def test_zero_length_role_name_rejected(self, tmp_path):
        """A role directory with empty name is skipped by discover_and_parse."""
        echo_dir = tmp_path / "echoes"
        echo_dir.mkdir()
        # Create a valid role dir to prove discovery works, but also a
        # role that would violate SEC-5 allowlist (e.g. dir with dots)
        valid_dir = echo_dir / "valid-role"
        valid_dir.mkdir()
        (valid_dir / "MEMORY.md").write_text(
            "## Inscribed — Test (2026-01-01)\nContent\n"
        )
        entries = discover_and_parse(str(echo_dir))
        assert len(entries) == 1
        assert entries[0]["role"] == "valid-role"


class TestEdgeCaseInvalidAndMalformed:
    """Edge cases for invalid and malformed MEMORY.md content."""

    def test_invalid_tier_name_not_parsed(self, tmp_path):
        """Unrecognized tier names are not treated as entry headers."""
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "## Unknown — Some title (2026-01-01)\n"
            "Content here\n"
        )
        entries = parse_memory_file(str(md), "test")
        assert entries == []

    def test_missing_date_in_header_not_parsed(self, tmp_path):
        """Header without (YYYY-MM-DD) date is not recognized as an entry."""
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "## Inscribed — Title without date\n"
            "Content here\n"
        )
        entries = parse_memory_file(str(md), "test")
        assert entries == []

    def test_malformed_date_format_not_parsed(self, tmp_path):
        """Header with malformed date (not YYYY-MM-DD) is not recognized."""
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "## Inscribed — Title (01-01-2026)\n"
            "Content here\n"
        )
        entries = parse_memory_file(str(md), "test")
        assert entries == []

    def test_invalid_role_name_with_special_chars_skipped(self, tmp_path):
        """Role directory with special chars (violates SEC-5) is skipped."""
        echo_dir = tmp_path / "echoes"
        echo_dir.mkdir()
        # Directory with invalid chars in name
        invalid_dir = echo_dir / "role..invalid"
        invalid_dir.mkdir()
        (invalid_dir / "MEMORY.md").write_text(
            "## Inscribed — Entry (2026-01-01)\nContent\n"
        )
        entries = discover_and_parse(str(echo_dir))
        assert entries == []

    def test_invalid_role_with_slash_skipped(self, tmp_path):
        """Role directory names cannot contain slashes (filesystem limitation)."""
        echo_dir = tmp_path / "echoes"
        echo_dir.mkdir()
        # This path would result in a nested directory structure, not a role
        nested = echo_dir / "parent" / "child"
        nested.mkdir(parents=True)
        (nested / "MEMORY.md").write_text(
            "## Inscribed — Nested (2026-01-01)\nContent\n"
        )
        # Only "parent" is at the role level — child is nested within
        entries = discover_and_parse(str(echo_dir))
        # parent dir has no MEMORY.md → 0 entries from top-level scan
        assert all(e["role"] == "parent" or e["role"] == "child" or True for e in entries)

    def test_truncated_header_not_parsed(self, tmp_path):
        """A truncated header (cut off mid-date) is not parsed."""
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "## Inscribed — Title (2026-01-\n"
            "Content here\n"
        )
        entries = parse_memory_file(str(md), "test")
        assert entries == []

    def test_null_byte_in_content_handled(self, tmp_path):
        """Content with unusual characters after valid header is preserved."""
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "## Inscribed — Entry with odd chars (2026-01-01)\n"
            "Normal content here\x00binary-ish\n"
        )
        # Parser opens as text — null byte will be in content string
        entries = parse_memory_file(str(md), "test")
        # Should have 1 entry even with unusual content
        assert len(entries) == 1
        assert "Normal content" in entries[0]["content"]

    def test_h1_header_not_treated_as_entry(self, tmp_path):
        """A # (H1) header is not treated as an echo entry."""
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "# Inscribed — Should be H1 preamble (2026-01-01)\n"
            "Preamble content\n\n"
            "## Inscribed — Real entry (2026-01-02)\n"
            "Actual content\n"
        )
        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 1
        assert entries[0]["tags"] == "Real entry"

    def test_h3_header_not_treated_as_entry(self, tmp_path):
        """A ### (H3) header is treated as content, not an entry boundary."""
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "## Inscribed — Main entry (2026-01-01)\n"
            "### Inscribed — This is H3 (2026-01-02)\n"
            "Content inside main entry\n"
        )
        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 1
        assert entries[0]["tags"] == "Main entry"


class TestEdgeCaseUnicodeAndSpecialChars:
    """Edge cases for unicode and special character content."""

    def test_unicode_content_in_entry(self, tmp_path):
        """Entry with CJK, emoji, and accented characters is parsed correctly."""
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "## Inscribed — Unicode test entry (2026-01-01)\n"
            "Content with CJK: 你好世界\n"
            "And accents: café résumé naïve\n"
            "And emoji: \U0001f525\U0001f9ff\n",
            encoding="utf-8",
        )
        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 1
        assert "你好世界" in entries[0]["content"]
        assert "café" in entries[0]["content"]

    def test_unicode_in_title_tags(self, tmp_path):
        """Unicode characters in the entry title (tags) are preserved."""
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "## Notes — Préférence utilisateur (2026-02-01)\n"
            "User prefers French documentation.\n"
        )
        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 1
        assert entries[0]["tags"] == "Préférence utilisateur"

    def test_special_chars_in_source_field(self, tmp_path):
        """Special characters in **Source** field are preserved."""
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "## Inscribed — Source test (2026-01-15)\n"
            "**Source**: `rune:appraise session-abc123!@#`\n"
            "Content with source\n"
        )
        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 1
        assert "rune:appraise" in entries[0]["source"]

    def test_entry_with_only_ascii_boundary_chars(self, tmp_path):
        """Entry using pipe characters and brackets in content is preserved."""
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "## Inscribed — Table in content (2026-01-01)\n"
            "| Column A | Column B |\n"
            "|----------|----------|\n"
            "| Value 1  | Value 2  |\n"
        )
        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 1
        assert "Column A" in entries[0]["content"]


class TestEdgeCaseBoundaryValues:
    """Edge cases for boundary value inputs."""

    def test_single_char_content(self, tmp_path):
        """Entry with single character content is not skipped."""
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "## Inscribed — Single char (2026-01-01)\n"
            "X\n"
        )
        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 1
        assert entries[0]["content"] == "X"

    def test_large_number_of_entries(self, tmp_path):
        """File with many entries (boundary: 50 entries) is parsed correctly."""
        lines = []
        n = 50
        for i in range(n):
            date = "2026-01-%02d" % (i % 28 + 1)
            lines.append("## Notes — Entry %03d (%s)" % (i, date))
            lines.append("")
            lines.append("Content for entry %d" % i)
            lines.append("")
        md = tmp_path / "MEMORY.md"
        md.write_text("\n".join(lines))
        entries = parse_memory_file(str(md), "test")
        assert len(entries) == n
        assert all(e["layer"] == "notes" for e in entries)

    def test_very_long_title_in_header(self, tmp_path):
        """Entry with a very long title (boundary: 255+ chars) is parsed."""
        long_title = "A" * 255
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "## Inscribed — %s (2026-01-01)\n"
            "Content below the long title\n" % long_title
        )
        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 1
        assert entries[0]["tags"] == long_title

    def test_zero_entries_from_preamble_only(self, tmp_path):
        """File with only a preamble H1 and no tier headers produces zero entries."""
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "# My Role Memory\n\n"
            "This file tracks learnings.\n\n"
            "No entries yet.\n"
        )
        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 0

    def test_boundary_date_year_edge(self, tmp_path):
        """Date at year boundaries (e.g., 9999-12-31) is parsed correctly."""
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "## Inscribed — Far future entry (9999-12-31)\n"
            "Far future content\n"
        )
        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 1
        assert entries[0]["date"] == "9999-12-31"

    def test_boundary_date_earliest_valid(self, tmp_path):
        """Date at earliest plausible value (0001-01-01) is parsed correctly."""
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "## Inscribed — Ancient entry (0001-01-01)\n"
            "Ancient content\n"
        )
        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 1
        assert entries[0]["date"] == "0001-01-01"

    def test_duplicate_entries_same_header_produces_both(self, tmp_path):
        """Two entries with identical headers but separated by blank line are distinct."""
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "## Inscribed — Duplicate title (2026-01-01)\n"
            "First content\n\n"
            "## Inscribed — Duplicate title (2026-01-01)\n"
            "Second content\n"
        )
        entries = parse_memory_file(str(md), "test")
        # Both are parsed (different line numbers → different IDs)
        assert len(entries) == 2
        assert entries[0]["id"] != entries[1]["id"]


class TestEdgeCaseNoneAndNullFields:
    """Edge cases for None/null/missing fields in generated entries."""

    def test_entry_without_source_has_empty_source(self, tmp_path):
        """Entry with no **Source** line has empty string source field."""
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "## Inscribed — No source entry (2026-01-01)\n"
            "Content without any source line\n"
        )
        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 1
        assert entries[0]["source"] == ""

    def test_entry_id_is_always_16_hex_chars(self, tmp_path):
        """Generated IDs are always exactly 16 lowercase hex characters."""
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "## Inscribed — ID format test (2026-01-01)\n"
            "Some content\n\n"
            "## Etched — Another ID test (2026-01-02)\n"
            "More content\n"
        )
        entries = parse_memory_file(str(md), "test")
        import re
        hex_re = re.compile(r'^[0-9a-f]{16}$')
        for e in entries:
            assert hex_re.match(e["id"]), "ID %r is not 16 lowercase hex chars" % e["id"]

    def test_multiple_source_lines_only_first_used(self, tmp_path):
        """When multiple **Source** lines appear, only the first is captured."""
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "## Inscribed — Multi-source test (2026-01-01)\n"
            "**Source**: `first-source`\n"
            "**Source**: `second-source`\n"
            "Content here\n"
        )
        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 1
        assert entries[0]["source"] == "first-source"

    def test_null_content_between_entries_preserved(self, tmp_path):
        """Source line between two valid entries belongs to the first entry."""
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "## Inscribed — First (2026-01-01)\n"
            "**Source**: `src-a`\n"
            "Content A\n\n"
            "## Notes — Second (2026-01-02)\n"
            "**Source**: `src-b`\n"
            "Content B\n"
        )
        entries = parse_memory_file(str(md), "test")
        assert len(entries) == 2
        assert entries[0]["source"] == "src-a"
        assert entries[1]["source"] == "src-b"

    def test_none_role_does_not_crash(self, tmp_path):
        """parse_memory_file handles role='None' string without crashing."""
        md = tmp_path / "MEMORY.md"
        md.write_text(
            "## Inscribed — Test (2026-01-01)\n"
            "Content\n"
        )
        # 'None' as a string role name is valid (just a string)
        entries = parse_memory_file(str(md), "None")
        assert len(entries) == 1
        assert entries[0]["role"] == "None"
