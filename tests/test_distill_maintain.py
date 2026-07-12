"""Unit tests for distill-maintain.py — validate(), parse_block(), render()."""
import sys, os, logging
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import importlib
dm = importlib.import_module("distill-maintain")
validate = dm.validate
parse_block = dm.parse_block
render = dm.render
BEGIN = dm.BEGIN
END = dm.END


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _pb(slug="my-slug", when=None, steps=None, **kw):
    return {"slug": slug, "when": when or ["trigger"], "steps": steps or ["do it"], **kw}


SAMPLE_MD = f"""\
# Header

{BEGIN}
### bq-cost-spike
**When:** BigQuery cost spike; daily cost anomaly
**Steps:**
1. Check billing dashboard
2. Identify expensive queries

**Example:** Cost doubled overnight

### spanner-slow
**When:** Spanner latency high
**Steps:**
1. Run EXPLAIN
2. Check indexes

{END}

# Footer
"""


# ---------------------------------------------------------------------------
# validate()
# ---------------------------------------------------------------------------

class TestValidate:
    def _original(self, n=3):
        return [_pb(slug=f"slug-{i}") for i in range(n)]

    def test_valid_passes(self):
        original = self._original(2)
        cleaned = [_pb("my-slug", ["when-a"], ["step-1", "step-2"])]
        assert validate(cleaned, original) is None

    def test_not_a_list(self):
        assert validate("oops", self._original()) == "not a list"
        assert validate(None, self._original()) == "not a list"
        assert validate({"a": 1}, self._original()) == "not a list"

    def test_empty_list(self):
        assert validate([], self._original()) == "empty output"

    def test_too_aggressive(self):
        original = self._original(10)
        cleaned = [_pb()]  # only 1 out of 10 → below threshold (5)
        err = validate(cleaned, original)
        assert err is not None and "too aggressive" in err

    def test_too_aggressive_threshold_boundary(self):
        original = self._original(4)  # threshold = max(1, 4//2) = 2
        # exactly at threshold → should pass
        assert validate([_pb("a"), _pb("b")], original) is None
        # one below → rejected
        assert validate([_pb("a")], original) is not None

    def test_entry_not_dict(self):
        assert validate(["not-a-dict"], self._original(1)) == "entry is not dict"

    def test_missing_slug(self):
        pb = {"when": ["t"], "steps": ["s"]}
        err = validate([pb], self._original(1))
        assert err == "missing slug"

    def test_missing_when(self):
        pb = {"slug": "ok", "steps": ["s"]}
        err = validate([pb], self._original(1))
        assert err == "missing when"

    def test_missing_steps(self):
        pb = {"slug": "ok", "when": ["t"]}
        err = validate([pb], self._original(1))
        assert err == "missing steps"

    def test_bad_when_empty_list(self):
        pb = {"slug": "ok", "when": [], "steps": ["s"]}
        err = validate([pb], self._original(1))
        assert err == "bad when in ok"

    def test_bad_when_not_list(self):
        pb = {"slug": "ok", "when": "string-not-list", "steps": ["s"]}
        err = validate([pb], self._original(1))
        assert err == "bad when in ok"

    def test_bad_steps_empty_list(self):
        pb = {"slug": "ok", "when": ["t"], "steps": []}
        err = validate([pb], self._original(1))
        assert err == "bad steps in ok"

    def test_bad_slug_uppercase(self):
        pb = _pb(slug="Bad-Slug")
        err = validate([pb], self._original(1))
        assert err is not None and "bad slug" in err

    def test_bad_slug_spaces(self):
        pb = _pb(slug="has space")
        err = validate([pb], self._original(1))
        assert err is not None and "bad slug" in err

    def test_valid_slug_with_numbers(self):
        pb = _pb(slug="bq-cost-2024")
        assert validate([pb], self._original(1)) is None

    def test_optional_example_ignored(self):
        pb = _pb(example="some example text")
        assert validate([pb], self._original(1)) is None

    def test_logging_not_a_list(self, caplog):
        with caplog.at_level(logging.WARNING, logger="distill-maintain"):
            validate("bad", self._original())
        assert any("expected list" in r.message for r in caplog.records)

    def test_logging_empty(self, caplog):
        with caplog.at_level(logging.WARNING, logger="distill-maintain"):
            validate([], self._original(3))
        assert any("empty list" in r.message for r in caplog.records)

    def test_logging_too_aggressive(self, caplog):
        with caplog.at_level(logging.WARNING, logger="distill-maintain"):
            validate([_pb()], self._original(10))
        assert any("too aggressive" in r.message for r in caplog.records)

    def test_logging_missing_key(self, caplog):
        pb = {"slug": "ok", "when": ["t"]}  # missing steps
        with caplog.at_level(logging.WARNING, logger="distill-maintain"):
            validate([pb], self._original(1))
        assert any("missing required key" in r.message for r in caplog.records)

    def test_logging_bad_slug(self, caplog):
        pb = _pb(slug="BadSlug")
        with caplog.at_level(logging.WARNING, logger="distill-maintain"):
            validate([pb], self._original(1))
        assert any("kebab-case" in r.message for r in caplog.records)

    def test_logging_debug_on_success(self, caplog):
        with caplog.at_level(logging.DEBUG, logger="distill-maintain"):
            validate([_pb()], self._original(1))
        assert any("passed" in r.message for r in caplog.records)


# ---------------------------------------------------------------------------
# parse_block()
# ---------------------------------------------------------------------------

class TestParseBlock:
    def test_parses_two_entries(self):
        start, end, pbs = parse_block(SAMPLE_MD)
        assert pbs is not None
        assert len(pbs) == 2

    def test_slug_extraction(self):
        _, _, pbs = parse_block(SAMPLE_MD)
        slugs = {p["slug"] for p in pbs}
        assert slugs == {"bq-cost-spike", "spanner-slow"}

    def test_when_split_by_semicolon(self):
        _, _, pbs = parse_block(SAMPLE_MD)
        bq = next(p for p in pbs if p["slug"] == "bq-cost-spike")
        assert bq["when"] == ["BigQuery cost spike", "daily cost anomaly"]

    def test_steps_extracted(self):
        _, _, pbs = parse_block(SAMPLE_MD)
        bq = next(p for p in pbs if p["slug"] == "bq-cost-spike")
        assert bq["steps"] == ["Check billing dashboard", "Identify expensive queries"]

    def test_example_optional(self):
        _, _, pbs = parse_block(SAMPLE_MD)
        bq = next(p for p in pbs if p["slug"] == "bq-cost-spike")
        spanner = next(p for p in pbs if p["slug"] == "spanner-slow")
        assert bq["example"] == "Cost doubled overnight"
        assert spanner["example"] == ""

    def test_no_block_returns_none(self):
        start, end, pbs = parse_block("# No markers here")
        assert pbs is None
        assert start is None
        assert end is None

    def test_positions_are_inside_markers(self):
        start, end, pbs = parse_block(SAMPLE_MD)
        inner = SAMPLE_MD[start:end]
        assert "bq-cost-spike" in inner
        assert BEGIN not in inner
        assert END not in inner


# ---------------------------------------------------------------------------
# render()
# ---------------------------------------------------------------------------

class TestRender:
    def test_render_round_trip(self):
        pbs = [
            {"slug": "abc", "when": ["trigger-a", "trigger-b"], "steps": ["step 1", "step 2"], "example": ""},
            {"slug": "xyz", "when": ["trigger-x"], "steps": ["step x"], "example": "an example"},
        ]
        out = render(pbs)
        assert "### abc" in out
        assert "### xyz" in out
        assert "**When:** trigger-a; trigger-b" in out
        assert "**Example:** an example" in out

    def test_render_sorted_by_slug(self):
        pbs = [_pb("zzz"), _pb("aaa"), _pb("mmm")]
        out = render(pbs)
        assert out.index("### aaa") < out.index("### mmm") < out.index("### zzz")

    def test_render_no_example_skips_field(self):
        pb = {"slug": "abc", "when": ["t"], "steps": ["s"], "example": ""}
        out = render([pb])
        assert "**Example:**" not in out

    def test_render_steps_numbered(self):
        pb = {"slug": "abc", "when": ["t"], "steps": ["first", "second", "third"]}
        out = render([pb])
        assert "1. first" in out
        assert "2. second" in out
        assert "3. third" in out
