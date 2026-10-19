#!/usr/bin/env python3
"""Reject build-time source changes except the reviewed Xcode SDK lock expansion."""
import json
from pathlib import Path
import subprocess
import sys


def pin(identity, location, revision, version):
    return {"identity": identity, "kind": "remoteSourceControl", "location": location,
            "state": {"revision": revision, "version": version}}


SWIFT_LOCK = {"pins": [pin("zipfoundation", "https://github.com/weichsel/ZIPFoundation.git",
                          "22787ffb59de99e5dc1fbfe80b19c97a904ad48d", "0.9.20")], "version": 2}
XCODE_LOCK = {"pins": [
    pin("ios-maps-sdk", "https://github.com/googlemaps/ios-maps-sdk",
        "bb35529d3660739497b35d5de53dc7e6c5942198", "11.1.0"),
    pin("ios-navigation-sdk", "https://github.com/googlemaps/ios-navigation-sdk",
        "2964b585f8a58843d1f1260934af2e1f38a45f6c", "11.1.0"),
    *SWIFT_LOCK["pins"],
], "version": 2}


def verify(repo, evidence):
    def git(*args):
        return subprocess.check_output(["git", *args], cwd=repo, text=True)

    evidence.mkdir(parents=True, exist_ok=True)
    status = git("status", "--porcelain", "--untracked-files=all")
    (evidence / "checkout-status.txt").write_text(status, encoding="utf-8")
    (evidence / "checkout.diff").write_text(git("diff", "HEAD", "--"), encoding="utf-8")
    if not status:
        result = "clean"
    elif status == " M Package.resolved\n":
        original = json.loads(git("show", "HEAD:Package.resolved"))
        resolved = (repo / "Package.resolved").read_text(encoding="utf-8")
        (evidence / "Xcode-Package.resolved").write_text(resolved, encoding="utf-8")
        if original != SWIFT_LOCK or json.loads(resolved) != XCODE_LOCK:
            raise ValueError("Package.resolved differs from the exact reviewed Xcode SDK expansion")
        result = "accepted exact Xcode Google SDK 11.1.0 lock expansion; source unchanged"
    else:
        raise ValueError("Checkout changed outside the reviewed Xcode lock expansion:\n" + status)
    report = {"commit": git("rev-parse", "HEAD").strip(), "checkout": result}
    (evidence / "checkout-validation.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: python3 scripts/validate-checkout.py IGNORED_EVIDENCE_DIRECTORY")
    try:
        print(json.dumps(verify(Path.cwd(), Path(sys.argv[1]).resolve()), indent=2))
    except (ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
