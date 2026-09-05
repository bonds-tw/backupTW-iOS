import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("report", HERE / "summarize-verification-runs.py")
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class ReportingTests(unittest.TestCase):
    def test_holder_send_is_not_a_verdict(self):
        self.assertEqual(report.report_records([
            {"matrixCell": "G4", "role": "holder", "succeeded": True}], "G4"), [])

    def test_duplicates_do_not_inflate_counts_and_conflicts_fail(self):
        with tempfile.TemporaryDirectory() as root:
            a, b = Path(root) / "a.json", Path(root) / "b.json"
            a.write_text(json.dumps([{"id": "one", "verificationMilliseconds": 12}]))
            b.write_text(a.read_text())
            self.assertEqual(len(report.load([a, b])), 1)
            b.write_text(json.dumps([{"id": "one", "verificationMilliseconds": 13}]))
            with self.assertRaises(ValueError):
                report.load([a, b])

    def test_failed_fast_refusal_does_not_improve_success_latency(self):
        records = [{"id": "pass", "matrixCell": "G4", "role": "verifier", "succeeded": True,
                    "verificationMilliseconds": 2000},
                   {"id": "fail", "matrixCell": "G4", "role": "verifier", "succeeded": False,
                    "verificationMilliseconds": 0}]
        with tempfile.TemporaryDirectory() as root:
            output = Path(root) / "report.md"
            report.write_markdown(output, records)
            self.assertIn("| G4 | 2 | 1 | 2.000 / 2.000 |", output.read_text())

    def test_invalid_numeric_types_are_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "a.json"
            for value in (-1, True, "100", 1.5):
                path.write_text(json.dumps([{"verificationMilliseconds": value}]))
                with self.assertRaises(ValueError):
                    report.load([path])

    def test_collector_discovers_two_devices_and_excludes_stale_failed_file(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            stub = root / "xcrun"
            stub.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
a=sys.argv
if 'list' in a:
    pathlib.Path(a[a.index('--json-output')+1]).write_text(json.dumps({'result':{'devices':[
        {'identifier':i,'hardwareProperties':{'reality':'physical'},'deviceProperties':{'ddiServicesAvailable':True}}
        for i in ('iphone','ipad')]}}))
else:
    device=a[a.index('--device')+1]
    with open(os.environ['TEST_CALLS'],'a') as f: f.write(device+'\\n')
    if device=='ipad': sys.exit(1)
    pathlib.Path(a[a.index('--destination')+1]).write_text(json.dumps([
        {'id':'fresh','matrixCell':'S2','role':'holder','succeeded':True}]))
''')
            stub.chmod(0o755)
            output = root / "output"
            (output / "ipad").mkdir(parents=True)
            (output / "ipad" / "verification-runs.json").write_text(json.dumps([
                {"id": "stale", "matrixCell": "S2", "role": "verifier", "succeeded": True}]))
            calls = root / "calls"
            result = subprocess.run(["zsh", str(HERE / "collect-verification-runs.sh"), str(output)],
                                    env={**os.environ, "PATH": str(root) + ":" + os.environ["PATH"],
                                         "TEST_CALLS": str(calls)}, capture_output=True, text=True)
            self.assertEqual(calls.read_text().splitlines(), ["iphone", "ipad"])
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("PARTIAL", result.stderr)
            self.assertNotIn("stale", (output / "verification-runs.csv").read_text())
            self.assertIn("| S2 | 0 | 0 |", (output / "verification-matrix.md").read_text())


if __name__ == "__main__":
    unittest.main()
