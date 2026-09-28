#!/usr/bin/env python3
"""Idempotent, verified single-line hook editor for FreeChat's overlay.

Usage: hook.py <file> <anchor> <replacement>

Guarantees, in this order, because a silently half-applied overlay is far worse
than a loud failure:
  * already applied (replacement present, anchor gone) -> exit 0, no write
  * anchor absent and replacement absent               -> exit 1, upstream moved
  * anchor present more than once                      -> exit 1, ambiguous
Exactly one occurrence is replaced.
"""
import sys


def main() -> int:
    if len(sys.argv) != 4:
        print(f"usage: {sys.argv[0]} <file> <anchor> <replacement>", file=sys.stderr)
        return 2
    path, anchor, replacement = sys.argv[1], sys.argv[2], sys.argv[3]

    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        print(f"hook: cannot read {path}: {exc}", file=sys.stderr)
        return 1

    if replacement in text:
        # A replacement that keeps the anchor (inserting a call above an
        # upstream comment, say) leaves the anchor present after a successful
        # run, so bare containment cannot tell "already applied" from
        # "ambiguous". Count only the anchors that are NOT accounted for by the
        # replacements already in the file.
        accounted = text.count(replacement) * replacement.count(anchor)
        if text.count(anchor) > accounted:
            print(f"hook: {path}: the replacement is present and the anchor "
                  "also occurs outside it; resolve by hand", file=sys.stderr)
            return 1
        print(f"  = already hooked: {path}")
        return 0

    count = text.count(anchor)
    if count == 0:
        print(f"hook: {path}: anchor not found -- upstream moved.\n"
              f"      anchor: {anchor}\n"
              "      See docs/07-UPSTREAM-SYNC.md.", file=sys.stderr)
        return 1
    if count > 1:
        print(f"hook: {path}: anchor found {count} times, expected 1; "
              "the anchor is no longer specific enough", file=sys.stderr)
        return 1

    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text.replace(anchor, replacement, 1))
    print(f"  + hooked: {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
