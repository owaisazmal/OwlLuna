#!/usr/bin/env python3
# Usage: run-tests.py <name> [--beautify] --select "<-only-testing and -skip-testing flags>" [-- <more xcodebuild flags>]
# Runs the selection on $SIMULATOR_UDID from $XCTESTRUN. A run that fails has its failed tests run once more in a fresh
# test runner on a rebooted simulator, and fails the step only if they fail again. Leaves <name>-1 and <name>-2 in $RUNNER_TEMP.

import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

TEST_CASE = re.compile(r"Test Case '-\[(\w+)\.(\w+) (\w+)\]' (started|passed|failed|skipped)")
# Past this many, something other than a slow runner is wrong, and the whole selection is run again.
MOST = 40
HERE = Path(__file__).resolve().parent


def run(name, attempt, selection, options, beautify):
    temp = Path(os.environ["RUNNER_TEMP"])
    log = temp / f"{name}-{attempt}.log"
    command = ["xcodebuild", "test-without-building",
               "-xctestrun", os.environ["XCTESTRUN"],
               "-destination", f"platform=iOS Simulator,id={os.environ['SIMULATOR_UDID']}",
               *selection, "-parallel-testing-enabled", "NO", *options,
               "-resultBundlePath", str(temp / f"{name}-{attempt}.xcresult")]
    pipeline = f"{shlex.join(command)} 2>&1 | tee {shlex.quote(str(log))}"
    if beautify:
        pipeline += " | xcbeautify --renderer github-actions"
    done = subprocess.run(["bash", "-o", "pipefail", "-c", pipeline], stdin=subprocess.DEVNULL)
    return done.returncode == 0, log


def failed_tests(log):
    # The last word on each test: one that passed on xcodebuild's own retry has passed, one cut short has not.
    last = {}
    with open(log, errors="replace") as lines:
        for line in lines:
            if match := TEST_CASE.search(line):
                target, suite, test, state = match.groups()
                last[f"{target}/{suite}/{test}"] = state
    return [test for test, state in last.items() if state in ("started", "failed")]


def reboot():
    udid = os.environ["SIMULATOR_UDID"]
    subprocess.run(["xcrun", "simctl", "shutdown", udid])
    subprocess.run(["xcrun", "simctl", "boot", udid], check=True)
    subprocess.run(["bash", str(HERE / "wait-for-simulator.sh"), "120"], check=True)
    if appearance := os.environ.get("APPEARANCE"):
        subprocess.run(["xcrun", "simctl", "ui", udid, "appearance", appearance], check=True)


def main():
    arguments, options = sys.argv[1:], []
    if "--" in arguments:
        cut = arguments.index("--")
        arguments, options = arguments[:cut], arguments[cut + 1:]
    name, beautify = arguments[0], "--beautify" in arguments
    selection = shlex.split(arguments[arguments.index("--select") + 1])

    passed, log = run(name, 1, selection, options, beautify)
    if passed:
        return 0
    failed = failed_tests(log)
    some = 0 < len(failed) <= MOST
    again = [f"-only-testing:{test}" for test in failed] if some else selection
    what = ", ".join(test.split("/", 1)[1] for test in failed) if some else "the whole selection"
    print(f"::warning title={name} run again::The first run failed, so these run once more in a fresh test runner "
          f"on a rebooted simulator%3A {what}", flush=True)
    reboot()
    passed, _ = run(name, 2, again, options, beautify)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
