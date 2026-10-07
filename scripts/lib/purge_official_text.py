#!/usr/bin/env python3
"""Rewrite the official product's name out of the strings a client ships.

    purge_official_text.py <android|desktop> <upstream-root> <brand-name> <public-url>

The rule is the SERVER's own (internal/branding/branding.go: UserVisibleText), so a
string looks the same whether it came from the client's built-in resources or from
the langpack the server serves:

  * hosts of the official site and t.me           -> the public URL / host
  * the product name, in the scripts the server
    knows (Latin, Cyrillic, Arabic, Persian,
    Korean, Hebrew)                               -> the brand name
  * dotted/underscored identifiers are left alone (they are not copy)

Only VALUES are touched. A resource key such as `TelegramFaq` is an identifier the
code looks up; renaming it would break the lookup and show nobody anything.

Why this exists: an audit counted 184 (Android) and 262 (desktop) user-visible
built-in strings that still said "Telegram" -- "Subscribe to Telegram Premium" in
an app whose Premium is not Telegram's. The existing purges removed the upstream
FORK's identity, deliberately, and left Telegram's alone.

Limits, so nobody assumes more than was done: a transliteration the pattern does not
list is not caught; text inside images and in Java/C++ string literals (as opposed to
resource files) is not touched; links that pointed at the official site now point at
the public URL, which has to serve something at those paths or they 404.

Idempotent: a second run finds nothing. Exits non-zero if the files it is responsible
for still contain the name afterwards.
"""
import os
import re
import sys
from urllib.parse import urlparse

BRAND_RE = re.compile(r"telegram|телеграм[\w]*|تيليجرام|تلگرام|텔레그램|טלגרם", re.I)
HTTP_HOST_RE = re.compile(r"https?://(?:[a-z0-9-]+\.)*telegram\.(?:org|me|com|dog)", re.I)
BARE_HOST_RE = re.compile(r"(?:(?:[a-z0-9-]+\.)*telegram\.(?:org|me|com|dog)|\bt\.me)([^a-z0-9]|$)", re.I)
TECHNICAL_ID_RE = re.compile(r"^[A-Za-z0-9-]+(?:[._][A-Za-z0-9-]+)+$")


def make_rewriter(brand, public_url):
    base = public_url.rstrip("/")
    p = urlparse(base)
    if p.scheme not in ("http", "https") or not p.netloc:
        sys.exit(f"purge_official_text: {public_url!r} is not an http(s) origin")
    host = p.netloc

    def rewrite(value):
        if not value or TECHNICAL_ID_RE.match(value.strip()):
            return value
        value = HTTP_HOST_RE.sub(base, value)
        value = BARE_HOST_RE.sub(lambda m: host + m.group(1), value)
        return BRAND_RE.sub(brand, value)
    return rewrite


def android_files(root):
    res = os.path.join(root, "TMessagesProj", "src", "main", "res")
    for d in sorted(os.listdir(res)):
        if d == "values" or d.startswith("values-"):
            for f in ("strings.xml", "strings_ext.xml", "plurals.xml", "arrays.xml"):
                p = os.path.join(res, d, f)
                if os.path.isfile(p):
                    yield p


def desktop_files(root):
    d = os.path.join(root, "Telegram", "Resources", "langs")
    if os.path.isdir(d):
        for f in sorted(os.listdir(d)):
            full = os.path.join(d, f)
            if f.endswith(".strings"):
                yield full
            elif f.endswith(".lproj") and os.path.isdir(full):
                # macOS: the permission prompts ("<app> would like to use the camera")
                for g in sorted(os.listdir(full)):
                    if g.endswith(".strings"):
                        yield os.path.join(full, g)


TEXT_NODE = re.compile(r">([^<]+)<")
LANG_LINE = re.compile(r'^(\s*"[^"]+"\s*=\s*")((?:[^"\\]|\\.)*)(";.*)$')


def process_android(text, rewrite):
    # Element text only: between a tag's '>' and the next '<'. Attribute values
    # (name="TelegramFaq") are never in that position.
    return TEXT_NODE.sub(lambda m: ">" + rewrite(m.group(1)) + "<", text)


def process_desktop(text, rewrite):
    out = []
    for line in text.split("\n"):
        m = LANG_LINE.match(line)
        out.append(m.group(1) + rewrite(m.group(2)) + m.group(3) if m else line)
    return "\n".join(out)


def remaining(path, platform):
    """Occurrences of the name left in VALUES (comments and keys excluded)."""
    text = open(path, encoding="utf-8").read()
    n = 0
    if platform == "android":
        for m in TEXT_NODE.finditer(text):
            if BRAND_RE.search(m.group(1)) or HTTP_HOST_RE.search(m.group(1)):
                n += 1
    else:
        for line in text.split("\n"):
            m = LANG_LINE.match(line)
            if m and (BRAND_RE.search(m.group(2)) or HTTP_HOST_RE.search(m.group(2))):
                n += 1
    return n


def main():
    if len(sys.argv) != 5 or sys.argv[1] not in ("android", "desktop"):
        print(__doc__, file=sys.stderr)
        return 2
    platform, root, brand, public_url = sys.argv[1:]
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 ._-]{0,30}", brand):
        sys.exit(f"purge_official_text: brand {brand!r} has characters that are unsafe inside a string resource")
    rewrite = make_rewriter(brand, public_url)
    files = list((android_files if platform == "android" else desktop_files)(root))
    if not files:
        sys.exit(f"purge_official_text: no string resource files found under {root} -- did upstream move them?")
    process = process_android if platform == "android" else process_desktop
    changed = 0
    for p in files:
        old = open(p, encoding="utf-8", newline="").read()
        new = process(old, rewrite)
        if new != old:
            open(p, "w", encoding="utf-8", newline="").write(new)
            changed += 1
    left = {p: remaining(p, platform) for p in files}
    left = {os.path.relpath(p, root): n for p, n in left.items() if n}
    print(f"  + rewrote the official name in {changed} of {len(files)} string files")
    if left:
        print("purge_official_text: the name is still in values of: " + ", ".join(f"{k} ({n})" for k, n in left.items()),
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
