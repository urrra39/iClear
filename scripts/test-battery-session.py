import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("battery_session", Path(__file__).with_name("battery-session.py"))
session = importlib.util.module_from_spec(spec)
spec.loader.exec_module(session)


class EvidenceTests(unittest.TestCase):
    def test_invalid_pairs_never_count(self):
        for text in ("", "pair 1 running: drain 2.0 W", "INVALID", "INCONCLUSIVE",
                     "pair 1 running: drain -1.0 W\npair 1 stopped: drain 2.0 W"):
            with self.assertRaises(ValueError):
                session.parse_pair(text)

    def test_pair_parser(self):
        self.assertEqual(session.parse_pair("pair 1 running: drain 2.125 W\npair 1 stopped: drain 2.1 W"),
                         {"running": 2.125, "stopped": 2.1})

    def test_missing_pairs_cannot_pass(self):
        state = {"results": [{"status": "invalid"}, {"status": "running"}]}
        self.assertEqual(session.summary(state)["status"], "INCONCLUSIVE")
        state["results"] += [{"status": "valid", "watts": {"running": 1, "stopped": 2}}] * 5
        self.assertEqual(session.summary(state)["status"], "INCONCLUSIVE")

    def test_upper_interval_decides_threshold(self):
        def results(diffs):
            return {"results": [{"status": "valid", "watts": {"running": 2 + d, "stopped": 2}} for d in diffs]}
        self.assertEqual(session.summary(results([0.1] * 6))["status"], "PASS")
        self.assertEqual(session.summary(results([0.21] * 6))["status"], "FAIL")
        # A low mean alone cannot pass a wide confidence interval.
        self.assertEqual(session.summary(results([-1, 1, -1, 1, -1, 1]))["status"], "FAIL")

    def test_atomic_checkpoint_roundtrip(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.json"
            session.save(path, {"results": [{"status": "running"}]})
            session.save(path, {"results": [{"status": "invalid", "reason": "interrupted"}]})
            self.assertEqual(session.json.loads(path.read_text())["results"][0]["status"], "invalid")
            self.assertFalse(path.with_suffix(".tmp").exists())


unittest.main()
