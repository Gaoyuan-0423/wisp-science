"""Offline regressions for helpers loaded into Wisp's persistent __main__."""

import builtins
import copy
import inspect
import io
import json
import sys
import tempfile
import traceback
import types
import unittest
import urllib.error
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import Mock, patch


SKILLS = Path(__file__).resolve().parents[1] / "skills"


def load_sidecar(name):
    namespace = {"__name__": "__main__"}
    source = (SKILLS / name / "runtime.py").read_text(encoding="utf-8")
    # Match render_skill's compile filename and the worker's shared namespace.
    exec(compile(source, "runtime.py", "exec"), namespace)
    return namespace


def json_response(value):
    return io.BytesIO(json.dumps(value).encode("utf-8"))


class PaperNarrativeTests(unittest.TestCase):
    def test_brief_and_review_preserve_each_claim_path_pair(self):
        helpers = load_sidecar("paper-narrative")
        figures = [
            {"key": "Figure 1", "claim": "First claim",
             "composite_path": 'figures/实验 "A".png'},
            {"key": "Figure 2", "caption": "Caption fallback",
             "composite_path": r"C:\Study files\figures\panel-b.png"},
            {"key": "Figure 3", "claim": "No supplied image"},
            {"key": "Figure 4", "claim": "Explicitly absent", "composite_path": None},
        ]
        before = copy.deepcopy(figures)
        brief = {"pitch": "A pitch", "vision": "A vision", "figures": figures}
        prompts = [
            helpers["paper_brief_task"]("An abstract", figures),
            helpers["narrative_review_task"](brief, ["deck/page-1.png"]),
        ]
        for prompt in prompts:
            with self.subTest(prompt=prompt[:30]):
                # Decode the actual data sent to the reviewing Agent, not the
                # helper's internal intermediate representation.
                start = prompt.index("```json\n") + len("```json\n")
                rows, _ = json.JSONDecoder().raw_decode(prompt[start:])
                by_key = {row["key"]: row for row in rows}
                for figure in figures[:2]:
                    row = by_key[figure["key"]]
                    self.assertEqual(row["composite_path"], figure["composite_path"])
                    self.assertEqual(row["claim"], figure.get("claim", figure.get("caption")))
                self.assertNotIn("composite_path", by_key["Figure 3"])
                self.assertIsNone(by_key["Figure 4"]["composite_path"])
        self.assertEqual(figures, before)


class OpenAlexFailureTests(unittest.TestCase):
    def setUp(self):
        self.helpers = load_sidecar("literature-review")
        sleep_patch = patch("time.sleep")
        url_patch = patch("urllib.request.urlopen")
        env_patch = patch.dict("os.environ", {"OPENALEX_API_KEY": "fixture-secret"})
        for patcher in (sleep_patch, url_patch, env_patch):
            self.addCleanup(patcher.stop)
        self.sleep = sleep_patch.start()
        self.open_url = url_patch.start()
        env_patch.start()

    def test_search_distinguishes_empty_and_populated_success(self):
        self.open_url.return_value = json_response({"results": []})
        self.assertEqual(self.helpers["search_openalex"]("fixture"), [])
        self.open_url.return_value = json_response({"results": [{
            "doi": "https://doi.org/10.1234/example",
            "title": "A study", "publication_year": 2025,
            "cited_by_count": 3,
            "primary_location": {"source": {"display_name": "A journal"}},
            "open_access": {"oa_url": "https://example.org/article"},
        }]})
        self.assertEqual(self.helpers["search_openalex"]("fixture"), [{
            "doi": "10.1234/example", "title": "A study", "year": 2025,
            "cited_by": 3, "venue": "A journal", "oa_url": "https://example.org/article",
        }])

    def test_search_surfaces_http_and_connection_failures_without_secrets(self):
        url = "https://api.openalex.org/works?api_key=fixture-secret"
        failures = [
            (urllib.error.HTTPError(url, status, url, None, None), f"HTTP {status}")
            for status in (401, 404, 429, 500)
        ] + [(TimeoutError(url), "connection"), (urllib.error.URLError(url), "connection")]
        for failure, message in failures:
            with self.subTest(message=message):
                self.open_url.reset_mock()
                self.sleep.reset_mock()
                self.open_url.side_effect = failure
                try:
                    self.helpers["search_openalex"]("fixture")
                except RuntimeError as exc:
                    self.assertIn(message, str(exc))
                    rendered = "".join(traceback.format_exception(type(exc), exc, exc.__traceback__))
                    self.assertNotIn("fixture-secret", rendered)
                else:
                    self.fail("failed retrieval was reported as successful")
                self.assertEqual(self.open_url.call_count, 2 if message == "HTTP 429" else 1)

    def test_search_retries_rate_limit_once_then_accepts_success(self):
        error = urllib.error.HTTPError("https://api.openalex.org/works", 429, "limited", None, None)
        self.open_url.side_effect = [error, json_response({"results": []})]
        self.assertEqual(self.helpers["search_openalex"]("fixture"), [])
        self.assertEqual(self.open_url.call_count, 2)
        self.sleep.assert_called_once_with(2)

    def test_search_rejects_malformed_json_and_results(self):
        responses = [b"not JSON", b"\xff"] + [
            json.dumps(value).encode("utf-8")
            for value in (None, [], {}, {"error": "failed"},
                          {"results": None}, {"results": {}}, {"results": [None]})
        ]
        for body in responses:
            with self.subTest(body=body):
                self.open_url.return_value = io.BytesIO(body)
                with self.assertRaises(RuntimeError):
                    self.helpers["search_openalex"]("fixture")

    def test_citation_graph_requires_success_in_both_directions(self):
        identity = {"id": "https://openalex.org/W123"}
        for failed_call in range(3):
            with self.subTest(failed_call=failed_call):
                responses = [json_response(identity), json_response({"results": []}),
                             json_response({"results": []})]
                responses[failed_call] = TimeoutError("fixture network failure")
                self.open_url.side_effect = responses
                with self.assertRaises(RuntimeError):
                    self.helpers["expand_citations"]("10.1234/example")
        self.open_url.side_effect = [json_response(identity), json_response({"results": []}),
                                     json_response({"results": []})]
        self.assertEqual(self.helpers["expand_citations"]("10.1234/example"), {
            "references": [], "cited_by": [],
        })

    def test_citation_graph_rejects_missing_identity_and_malformed_lists(self):
        for identity in (None, {}, {"id": None}, {"id": ""}):
            with self.subTest(identity=identity):
                self.open_url.return_value = json_response(identity)
                with self.assertRaises(RuntimeError):
                    self.helpers["expand_citations"]("10.1234/example")
        for failed_call in (1, 2):
            responses = [json_response({"id": "https://openalex.org/W123"}),
                         json_response({"results": []}), json_response({"results": []})]
            responses[failed_call] = json_response({"error": "failed"})
            self.open_url.side_effect = responses
            with self.assertRaises(RuntimeError):
                self.helpers["expand_citations"]("10.1234/example")

    def test_crossref_failure_keeps_doi_verification_unverified(self):
        self.open_url.side_effect = TimeoutError("fixture network failure")
        # Crossref's tolerant fallback must still reach the DOI registry.
        with patch.dict(self.helpers, {"_head_status": Mock(return_value=None)}):
            result = self.helpers["verify_dois"](["10.1234/example"])
            self.assertIsNone(result["10.1234/example"]["ok"])
            self.helpers["_head_status"].assert_called_once()


class FigureStyleLoadingTests(unittest.TestCase):
    def test_repl_loading_does_not_require_matplotlib_or_run_checks(self):
        original_import = builtins.__import__

        def no_matplotlib(name, *args, **kwargs):
            if name == "matplotlib" or name.startswith("matplotlib."):
                raise ModuleNotFoundError("matplotlib deliberately unavailable")
            return original_import(name, *args, **kwargs)

        output = io.StringIO()
        with patch("builtins.__import__", no_matplotlib), redirect_stdout(output):
            helpers = load_sidecar("figure-style")
        self.assertTrue(callable(helpers["apply_figure_style"]))
        self.assertTrue(callable(helpers["figure_style_self_check"]))
        self.assertEqual(output.getvalue(), "")

    def test_loading_preserves_style_and_explicit_self_check_applies_defaults(self):
        matplotlib = types.ModuleType("matplotlib")
        matplotlib.rcParams = {"font.size": 17, "backend": "existing-backend"}
        matplotlib.use = Mock()
        before = dict(matplotlib.rcParams)
        with patch.dict(sys.modules, {"matplotlib": matplotlib}):
            helpers = load_sidecar("figure-style")
            self.assertEqual(matplotlib.rcParams, before)
            matplotlib.use.assert_not_called()
            # Font discovery is covered independently of this load contract;
            # keep the explicit self-check test independent of installed fonts.
            with patch.dict(helpers, {"_find_cjk_font": lambda: None,
                                      "_register_conda_fonts": lambda: None}):
                result = helpers["figure_style_self_check"]()
            self.assertEqual(matplotlib.rcParams["font.size"], 8)
            self.assertIn("DejaVu Sans", result["font.sans-serif"])
            self.assertFalse(matplotlib.rcParams["axes.unicode_minus"])
            self.assertEqual(matplotlib.rcParams["backend"], "existing-backend")
            matplotlib.use.assert_not_called()


class SavePanelCropsTests(unittest.TestCase):
    """QA crops are inspection debris: they stay out of the output tree and
    one pass never accumulates on the last."""

    def setUp(self):
        self.helpers = load_sidecar("figure-style")
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.figure = Path(self.temp.name) / "figures" / "figure.png"
        self.figure.parent.mkdir()
        self.figure.write_bytes(b"png")
        self.out_dir = Path(self.temp.name) / ".cache" / "figure-style"

    def save(self, boxes):
        # Pillow is not a test dependency; a stub records what would be cropped.
        saved = {}

        class FakeImage:
            def __enter__(inner):
                return inner

            def __exit__(inner, *exc):
                return False

            def crop(inner, box):
                return types.SimpleNamespace(
                    save=lambda path: saved.__setitem__(path, box))

        pil = types.ModuleType("PIL")
        pil.Image = types.SimpleNamespace(open=lambda path: FakeImage())
        with patch.dict(sys.modules, {"PIL": pil, "PIL.Image": pil.Image}):
            paths = self.helpers["save_panel_crops"](
                str(self.figure), boxes, out_dir=str(self.out_dir))
        return paths, saved

    def test_crops_land_in_scratch_not_beside_the_figure(self):
        paths, saved = self.save({"a": (0, 0, 5, 5), "b": (5, 0, 10, 5)})
        self.assertEqual(set(paths), {"a", "b"})
        self.assertEqual(saved[paths["a"]], (0, 0, 5, 5))
        for path in paths.values():
            self.assertEqual(Path(path).parent, self.out_dir)
        self.assertEqual([p.name for p in self.figure.parent.iterdir()],
                         ["figure.png"])
        # The default is what the skill's QA snippet relies on: scratch, not
        # a folder inside the figures directory.
        default = inspect.signature(
            self.helpers["save_panel_crops"]).parameters["out_dir"].default
        self.assertEqual(default, ".cache/figure-style")

    def test_each_pass_replaces_the_previous_crops(self):
        self.out_dir.mkdir(parents=True)
        stale = self.out_dir / "z.png"
        stale.write_bytes(b"old")
        paths, _ = self.save({"a": (0, 0, 5, 5)})
        self.assertFalse(stale.exists())
        self.assertEqual(list(paths), ["a"])


if __name__ == "__main__":
    unittest.main()
