#!/usr/bin/env python3
# Usage: release-notes.py <tag> [<file>]. Finds the tag's section of CHANGELOG.md, "## [1.0.0-build.3]" for v1.0.0-build.3,
# and fails if there is none. Given a file, writes the section there: the notes of the tag's GitHub Release.

import re
import sys

# The next section's heading, or the links at the foot.
SECTION_END = re.compile(r"## \[|\[[^\]]+\]: ")


def section(changelog, version):
    lines, found = [], False
    for line in changelog.splitlines():
        if found:
            if SECTION_END.match(line):
                break
            lines.append(line)
        elif line.startswith(f"## [{version}]"):
            found = True
    return "\n".join(lines).strip()


def main():
    tag = sys.argv[1]
    version = tag.removeprefix("v")
    with open("CHANGELOG.md", encoding="utf-8") as changelog:
        notes = section(changelog.read(), version)
    if not notes:
        print(f"::error file=CHANGELOG.md::CHANGELOG.md has no section for {tag}. "
              f"Add \"## [{version}] - <date>\" with what changed, and tag that commit.", flush=True)
        return 1
    if len(sys.argv) > 2:
        with open(sys.argv[2], "w", encoding="utf-8") as notes_file:
            notes_file.write(notes + "\n")
    print(f"{tag}: {len(notes.splitlines())} lines of notes.", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
