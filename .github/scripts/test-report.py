#!/usr/bin/env python3
# Usage: test-report.py <folder>. Turns its *.xcresult and *.log files into annotations and a step summary.
# A step keeps 10 annotations per level and the runner cuts each at 4096 characters, so lines are folded.

import json
import os
import re
import subprocess
import sys
from pathlib import Path

LIMIT = 4000
SLOWEST = 10
AUDIT_ANNOTATIONS = 7
TEST_CASE = re.compile(r"Test Case '-\[(?:\w+\.)?(\w+) (\w+)\]' (started|passed|failed|skipped)(?: \(([\d.]+) seconds\))?")
BUILD_DONE = re.compile(r"\*\* (?:TEST )?BUILD (SUCCEEDED|FAILED) \*\*")

summary = []


def escape(text):
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def annotate(level, title, lines):
    title = escape(title).replace(":", "%3A").replace(",", "%2C")
    print(f"::{level} title={title}::{escape(chr(10).join(lines))}", flush=True)


def fold(lines):
    chunk, size = [], 0
    for line in lines:
        line = line[:LIMIT]
        if chunk and size + len(line) + 1 > LIMIT:
            yield chunk
            chunk, size = [], 0
        chunk.append(line)
        size += len(line) + 1
    if chunk:
        yield chunk


def seconds(value):
    if value < 10:
        return f"{value:.2f} s"
    return f"{value:.1f} s" if value < 600 else f"{value / 60:.1f} min"


def xcresult(what, bundle):
    try:
        result = subprocess.run(
            ["xcrun", "xcresulttool", "get", "test-results", what, "--path", str(bundle), "--compact"],
            capture_output=True, text=True, timeout=600, check=True)
        return json.loads(result.stdout)
    except (subprocess.SubprocessError, OSError, ValueError) as error:
        print(f"Couldn't read the {what} of {bundle.name}: {error}", file=sys.stderr)
        return None


def cases(nodes):
    for node in nodes:
        if node.get("nodeType") == "Test Case":
            yield node
        else:
            yield from cases(node.get("children", []))


def descendants(node):
    for child in node.get("children", []):
        yield child
        yield from descendants(child)


def report_slowest(name, overview, timed):
    rows = [f"{seconds(taken)}  {test}" for test, taken in timed[:SLOWEST]]
    annotate("notice", f"Slowest tests ({name})", [overview + "."] + rows)
    summary.append(f"### {name}\n\n{overview}.\n\n| Time | Test |\n|---:|---|")
    summary.extend(f"| {seconds(taken)} | `{test}` |" for test, taken in timed[:SLOWEST])


def report_bundle(bundle):
    name = bundle.stem
    tests = xcresult("tests", bundle)
    if tests is None:
        return False
    found = list(cases(tests.get("testNodes", [])))
    if not found:
        return True
    label = lambda case: case.get("nodeIdentifier") or case.get("name", "?")
    timed = sorted(((label(case), case["durationInSeconds"]) for case in found if "durationInSeconds" in case),
                   key=lambda item: -item[1])
    overview = f"{len(found)} tests, {seconds(sum(taken for _, taken in timed))} in the tests themselves"
    info = xcresult("summary", bundle) or {}
    if info.get("startTime") and info.get("finishTime"):
        overview += f", {seconds(info['finishTime'] - info['startTime'])} from start to finish"
    report_slowest(name, overview, timed)

    failed, retried = [], []
    for case in found:
        messages = [node.get("name", "") for node in descendants(case) if node.get("nodeType") == "Failure Message"]
        if case.get("result") == "Failed":
            failed.append(f"{label(case)}: {messages[0][:300] if messages else 'failed'}")
        elif messages:
            retried.append(f"{label(case)}: {messages[0][:300]}")
    for title, level, lines in (("Failed tests", "error", failed), ("Passed on a retry", "warning", retried)):
        if lines:
            annotate(level, f"{title} ({name}, {len(lines)})", next(fold(lines)))
            summary.append(f"\n**{title}**\n")
            summary.extend(f"- `{line}`" for line in lines[:200])
    summary.append("")
    return True


def report_logs(logs, readable):
    audits, seen = [], set()
    for log in logs:
        test, running, bundle, times, timing = "", None, None, {}, None
        with open(log, errors="replace") as lines:
            for line in lines:
                if bundle == "":
                    bundle = Path(line.strip()).stem
                elif line.startswith("Writing result bundle at path:"):
                    bundle = ""
                elif match := TEST_CASE.search(line):
                    suite, test, state, taken = match.groups()
                    running = f"{suite}/{test}()" if state == "started" else None
                    if taken:
                        times[f"{suite}/{test}()"] = times.get(f"{suite}/{test}()", 0) + float(taken)
                elif (start := line.find("AUDIT FAIL ")) >= 0:
                    entry = (test or "(no test)", line[start + len("AUDIT FAIL "):].strip())
                    if entry not in seen:
                        seen.add(entry)
                        audits.append(entry)
                elif line.startswith("Build Timing Summary"):
                    timing = []
                elif timing is not None and (match := BUILD_DONE.search(line)):
                    report_timing(log.stem, timing, match.group(1).lower())
                    timing = None
                elif timing is not None and " | " in line:
                    timing.append(line.strip())
        # A run that was stopped leaves a bundle xcresulttool can't read, so the log stands in for it.
        if bundle and bundle not in readable and (times or running):
            timed = sorted(times.items(), key=lambda item: -item[1])
            overview = f"{len(times)} tests finished in {log.name}; {bundle}.xcresult couldn't be read"
            report_slowest(bundle, overview, timed)
            if running:
                annotate("error", f"Unfinished test ({bundle})", [f"{running} started and never finished."])
                summary.append(f"\n**Unfinished:** `{running}`\n")
    if audits:
        report_audits(audits)


def report_timing(name, rows, outcome):
    taken = lambda row: float((re.findall(r"([\d.]+) seconds", row) or ["0"])[-1])
    rows = sorted(rows, key=lambda row: -taken(row))
    title = f"Build timing ({name}, {outcome})"
    annotate("notice", title, rows[:12])
    summary.append(f"### {title}\n\n```\n" + "\n".join(rows) + "\n```\n")


def report_audits(audits):
    chunks, lines, size, count, test = [], [], 0, 0, None
    for name, text in audits:
        entry = "  " + text[:LIMIT - 200]
        if lines and size + len(name) + len(entry) + 2 > LIMIT - 100:
            chunks.append((lines, count))
            lines, size, count, test = [], 0, 0, None
        if name != test:
            lines.append(name)
            size += len(name) + 1
            test = name
        lines.append(entry)
        size += len(entry) + 1
        count += 1
    chunks.append((lines, count))
    first, total = 1, len(audits)
    for index, (lines, count) in enumerate(chunks[:AUDIT_ANNOTATIONS]):
        last = first + count - 1
        if index == AUDIT_ANNOTATIONS - 1 and last < total:
            lines.append(f"... and {total - last} more in the step summary")
        annotate("warning", f"Audit failures {first}-{last} of {total}", lines)
        first = last + 1
    grouped, test = [], None
    for name, text in audits[:2000]:
        if name != test:
            grouped.append(name)
            test = name
        grouped.append("  " + text)
    summary.append(f"### Audit failures ({total})\n\n```\n" + "\n".join(grouped) + "\n```\n")


def main():
    folder = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    readable = {bundle.stem for bundle in sorted(folder.glob("*.xcresult")) if report_bundle(bundle)}
    report_logs(sorted(folder.glob("*.log")), readable)
    if summary:
        text = "\n".join(summary) + "\n"
        path = os.environ.get("GITHUB_STEP_SUMMARY")
        if path:
            with open(path, "a") as out:
                out.write(text[:1_000_000])
        else:
            print(text)


if __name__ == "__main__":
    main()
