#!/usr/bin/env python3
"""Replace a historical doc with a short, path-preserving index.

Usage: archive-historical-doc.py <rev> <path>... (run from the repo root)

The full text is read from `git show <rev>:<path>`. The index keeps the
frontmatter and title, repeats every heading at its level and order (so every
`path#fragment` link still resolves) and links each one to the same section
of the immutable GitHub blob at <rev>. Test: scripts/test-archive-historical-doc.sh
"""
import re
import subprocess
import sys

REPO_URL = "https://github.com/aiur-team/aiur/blob"
TICKET = "U8-P25-T01"


def slug(heading, seen):
    """GitHub's anchor rule: lowercase, drop punctuation, spaces to '-', dedupe with -1, -2."""
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", heading)  # links render as their text
    text = re.sub(r"<[^>]+>", "", text).lower()
    base = re.sub(r"[^\w\- ]", "", text).replace(" ", "-")
    n = seen.get(base, 0)
    seen[base] = n + 1
    return base if n == 0 else f"{base}-{n}"


def split_frontmatter(lines):
    if lines and lines[0].rstrip() == "---":
        for i, line in enumerate(lines[1:], 1):
            if line.rstrip() == "---":
                return lines[1:i], lines[i + 1 :]
    return [], lines


def build_index(sha, path, text):
    front, body = split_frontmatter(text.splitlines())
    if any(line.startswith("archived:") for line in front):
        raise SystemExit(f"{path}@{sha} is already an index (has archived:); use the pre-archive SHA")
    url = f"{REPO_URL}/{sha}/{path}"
    out = ["---", *front, f"archived: {sha} ({TICKET})", "---", ""]
    seen, fence, first = {}, None, True
    for line in body:
        marker = re.match(r"\s{0,3}(`{3,}|~{3,})", line)
        if marker:
            if fence is None:
                fence = marker.group(1)[0]
            elif marker.group(1)[0] == fence:
                fence = None
            continue
        m = None if fence else re.match(r"(#{1,6})\s+(.*?)(\s+#+)?\s*$", line)
        if not m:
            continue
        link = slug(m.group(2), seen)
        out += [line.rstrip(), ""]
        if first:
            out += [f"> Historical record. Full text: {url}", ""]
            first = False
        else:
            out += [f"[Section text at {sha[:9]}]({url}#{link})", ""]
    if first:
        raise SystemExit(f"{path}@{sha} has no headings")
    return "\n".join(out)


def main(argv):
    if len(argv) < 3:
        raise SystemExit(__doc__)
    sha = subprocess.check_output(["git", "rev-parse", argv[1]], text=True).strip()
    for path in argv[2:]:
        text = subprocess.check_output(["git", "show", f"{sha}:{path}"], text=True)
        with open(path, "w") as f:
            f.write(build_index(sha, path, text) + "\n")


if __name__ == "__main__":
    main(sys.argv)
