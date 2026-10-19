import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("validate_checkout", Path(__file__).resolve().parents[2] / "scripts/validate-checkout.py")
checkout = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checkout)


class CheckoutValidationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.evidence = self.repo / "build"
        self.git("init", "-q")
        self.git("config", "core.autocrlf", "false")
        self.write_lock(checkout.SWIFT_LOCK)
        (self.repo / ".gitignore").write_text("build/\n")
        (self.repo / "source.swift").write_text("original\n")
        self.git("add", ".")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture")

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, text=True, stderr=subprocess.STDOUT)

    def write_lock(self, value):
        (self.repo / "Package.resolved").write_text(json.dumps(value, indent=2) + "\n")

    def check(self):
        return checkout.verify(self.repo, self.evidence)

    def test_clean_checkout(self):
        self.assertEqual(self.check()["checkout"], "clean")

    def test_exact_xcode_expansion_keeps_diff_and_resolved_record(self):
        self.write_lock(checkout.XCODE_LOCK)
        self.assertIn("accepted exact Xcode", self.check()["checkout"])
        self.assertIn("ios-navigation-sdk", (self.evidence / "checkout.diff").read_text())
        self.assertEqual(json.loads((self.evidence / "Xcode-Package.resolved").read_text()), checkout.XCODE_LOCK)
        self.assertEqual(self.git("status", "--porcelain"), " M Package.resolved\n")

    def test_source_change_is_rejected(self):
        self.write_lock(checkout.XCODE_LOCK)
        (self.repo / "source.swift").write_text("changed\n")
        with self.assertRaises(ValueError):
            self.check()

    def test_untracked_source_is_rejected(self):
        (self.repo / "new.swift").write_text("new\n")
        with self.assertRaises(ValueError):
            self.check()

    def test_staged_expansion_is_rejected(self):
        self.write_lock(checkout.XCODE_LOCK)
        self.git("add", "Package.resolved")
        with self.assertRaises(ValueError):
            self.check()

    def test_changed_revisions_versions_locations_or_schema_are_rejected(self):
        for index in range(3):
            for field in ("revision", "version"):
                with self.subTest(index=index, field=field):
                    lock = copy.deepcopy(checkout.XCODE_LOCK)
                    lock["pins"][index]["state"][field] = "changed"
                    self.write_lock(lock)
                    with self.assertRaises(ValueError):
                        self.check()
        for alter in (lambda x: x["pins"][0].update(location="https://example.invalid/sdk"),
                      lambda x: x["pins"].append(copy.deepcopy(x["pins"][0])),
                      lambda x: x["pins"].pop(), lambda x: x.update(version=3)):
            lock = copy.deepcopy(checkout.XCODE_LOCK)
            alter(lock)
            self.write_lock(lock)
            with self.assertRaises(ValueError):
                self.check()

    def test_altered_committed_baseline_is_rejected(self):
        lock = copy.deepcopy(checkout.SWIFT_LOCK)
        lock["pins"][0]["state"]["version"] = "0.9.19"
        self.write_lock(lock)
        self.git("add", "Package.resolved")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "altered baseline")
        self.write_lock(checkout.XCODE_LOCK)
        with self.assertRaises(ValueError):
            self.check()
