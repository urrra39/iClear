#!/bin/bash
# A private CI artifact, never a GitHub release. Tests/lint run in the enclosing job.
set -euo pipefail
cd "$(dirname "$0")/.."
export SIGN_IDENTITY=-
mkdir -p validation
sh scripts/build-release.sh 2>&1 | tee validation/build.log
VERSION=$(sed -n 's/^public let iclearVersion = "\(.*\)"/\1/p' Sources/ICSystem/Doctor.swift)
(cd dist && shasum -a 256 iClear-*.zip iclear-*-macos.tar.gz > SHA256SUMS.txt)
sh scripts/verify-release.sh dist "$VERSION" --no-mic 2>&1 | tee validation/verify.log
python3 - "$VERSION" <<'PY'
import json, os, subprocess, sys
def command(*args):
    return subprocess.check_output(args, text=True).strip()
record = {
    "version": sys.argv[1],
    "source_sha": command("git", "rev-parse", "HEAD"),
    "run_url": "https://github.com/" + os.environ.get("GITHUB_REPOSITORY", "urrra39/iClear") + "/actions/runs/" + os.environ.get("GITHUB_RUN_ID", "local"),
    "swift": command("swift", "--version"),
    "macos": command("sw_vers", "-productVersion"),
    "architectures": ["arm64", "x86_64"],
    "signature": "ad-hoc", "notarized": False,
    "scope": "CI candidate; quick selftest excludes microphone. No battery, personal-use or full lab qualification.",
}
with open("dist/provenance.json", "w") as f:
    json.dump(record, f, indent=2)
PY
