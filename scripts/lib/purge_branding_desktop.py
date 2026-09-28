#!/usr/bin/env python3
"""Remove the upstream fork's identity from the Desktop checkout.

Usage: purge_branding_desktop.py <upstream-root> <brand-name> <blank-telegram-key:true|false>

The Android counterpart is scripts/lib/purge_branding.py; this is deliberately a
separate script rather than a shared one with a platform flag. The two trees
share nothing but the idea: different languages, different file layouts,
different build systems, different things to rename. One script with two rule
tables and two sets of file moves would be a single point of failure over two
codebases that never change together.

Same contract as the Android purge: run it AFTER the hooks (their anchors still
carry the old identifiers), and it exits non-zero if any occurrence survives
rather than reporting success over a half-finished rename.
"""
import os
import re
import shutil
import sys


def replacements(brand):
    lower = brand.lower()
    return [
        # Include paths and the namespace. Longest first.
        ("owpengram/owpengram_servers", f"{lower}/{lower}_servers"),
        ("boxes/owpengram_add_server_box", f"boxes/{lower}_add_server_box"),
        ("boxes/owpengram_connecting_box", f"boxes/{lower}_connecting_box"),
        ("boxes/owpengram_server_details_box", f"boxes/{lower}_server_details_box"),
        ("namespace Owpengram", f"namespace {brand}"),
        ("Owpengram::", f"{brand}::"),
        ("OwpengramServerSelection", f"{brand}ServerSelection"),
        ("readOwpengramServer", f"read{brand}Server"),
        ("writeOwpengramServer", f"write{brand}Server"),

        # On-disk state and asset names.
        ("owpengram_builtin_identity.json", f"{lower}_builtin_identity.json"),
        ("owpengram_servers.json", f"{lower}_servers.json"),
        ("owpengram_server_logos", f"{lower}_server_logos"),
        ("call_incoming_owpengram", f"call_incoming_{lower}"),
        ("msg_incoming_owpengram", f"msg_incoming_{lower}"),

        # Translation keys.
        ("lng_owpengram_", f"lng_{lower}_"),

        # Bundle / application identity.
        ("org.owpengram.desktop", f"org.{lower}.desktop"),

        # Deep-link scheme, with the separator so the four letters cannot be
        # rewritten inside an unrelated word.
        ("owpg://", f"{lower}://"),
        ('"owpg"', f'"{lower}"'),
        ("u\"owpg\"", f"u\"{lower}\""),

        # Display and remaining bare occurrences.
        ("OwpenGram", brand),
        ("Owpengram", brand),
        ("OWPENGRAM", brand.upper()),
        ("owpengram", lower),
    ]


TEXT_SUFFIXES = (".cpp", ".h", ".txt", ".qrc", ".rc", ".strings", ".style",
                 ".json", ".py", ".sh", ".cmake", ".md", ".xml", ".desktop",
                 ".plist", ".in")
SKIP_DIRS = {".git", "build", "out", "ThirdParty", "cmake-build-debug"}


def walk_sources(root):
    for base in ("Telegram/SourceFiles", "Telegram/Resources", "Telegram/cmake",
                 "Telegram/build", "lib"):
        top = os.path.join(root, base)
        if not os.path.isdir(top):
            continue
        for dirpath, dirnames, filenames in os.walk(top):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for name in filenames:
                if name.endswith(TEXT_SUFFIXES):
                    yield os.path.join(dirpath, name)
    for extra in ("Telegram/CMakeLists.txt",):
        path = os.path.join(root, extra)
        if os.path.isfile(path):
            yield path


def move_paths(root, brand, report):
    lower = brand.lower()

    # The servers module moves into the directory the overlay already uses, so
    # its header and the overlay's sit together.
    src_dir = os.path.join(root, "Telegram/SourceFiles/owpengram")
    dst_dir = os.path.join(root, "Telegram/SourceFiles", lower)
    if os.path.isdir(src_dir):
        os.makedirs(dst_dir, exist_ok=True)
        for name in sorted(os.listdir(src_dir)):
            new = name.replace("owpengram", lower)
            os.replace(os.path.join(src_dir, name), os.path.join(dst_dir, new))
            report.append(f"    moved {name} -> {lower}/{new}")
        try:
            os.rmdir(src_dir)
        except OSError:
            pass

    for rel_dir in ("Telegram/SourceFiles/boxes", "Telegram/Resources/sounds"):
        d = os.path.join(root, rel_dir)
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            if "owpengram" in name.lower():
                new = re.sub("owpengram", lower, name, flags=re.I)
                os.replace(os.path.join(d, name), os.path.join(d, new))
                report.append(f"    renamed {name} -> {new}")

    # Resources/OwpenGram holds the fork's icons and platform metadata.
    src = os.path.join(root, "Telegram/Resources/OwpenGram")
    dst = os.path.join(root, "Telegram/Resources", brand)
    if os.path.isdir(src):
        if not os.path.exists(dst):
            os.replace(src, dst)
            report.append(f"    renamed Resources/OwpenGram -> Resources/{brand}")
        else:
            # Destination already holds a previous run's rename. Skipping would
            # leave BOTH directories in the tree, which is what the leftover
            # check is for; merge instead so the result is the same either way.
            for dirpath, _, filenames in os.walk(src):
                rel = os.path.relpath(dirpath, src)
                target_dir = os.path.join(dst, rel) if rel != "." else dst
                os.makedirs(target_dir, exist_ok=True)
                for name in filenames:
                    os.replace(os.path.join(dirpath, name),
                               os.path.join(target_dir, name))
            shutil.rmtree(src, ignore_errors=True)
            report.append(f"    merged Resources/OwpenGram into Resources/{brand}")


def blank_literal(text, name):
    """Empty a Qt string-literal constant, keeping the declaration.

    Matches both the u"..."_q form and a backslash-continued multi-line PEM.
    The declaration has to stay: it is referenced, and removing it would not
    compile. Emptying it removes the bytes from the binary, which is the goal.
    """
    pat = re.compile(
        r'(const\s+auto\s+' + re.escape(name) + r'\s*=\s*)'
        r'u?"(?:[^"\\]|\\.|\\\n)*"(?:_q)?\s*;',
        re.S)
    return pat.subn(lambda m: m.group(1) + 'u""_q;', text, count=1)


def main():
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    root, brand = sys.argv[1], sys.argv[2]
    blank_tg = sys.argv[3].lower() in {"1", "true", "yes"}
    report = []

    move_paths(root, brand, report)

    rules = replacements(brand)
    files_changed = total = 0
    for path in walk_sources(root):
        try:
            original = open(path, encoding="utf-8").read()
        except (OSError, UnicodeDecodeError):
            continue
        text = original
        for old, new in rules:
            if old in text:
                total += text.count(old)
                text = text.replace(old, new)
        if text != original:
            open(path, "w", encoding="utf-8").write(text)
            files_changed += 1

    lower = brand.lower()
    servers = os.path.join(root, "Telegram/SourceFiles", lower,
                           f"{lower}_servers.cpp")
    if os.path.isfile(servers):
        text = open(servers, encoding="utf-8").read()
        text, n = blank_literal(text, "kOfficialRsaPublicKey")
        if n:
            report.append("    blanked kOfficialRsaPublicKey (upstream node's key)")
        text, n = blank_literal(text, "kOfficialDefaultHost")
        if n:
            report.append("    blanked kOfficialDefaultHost (upstream node's IP)")
        if blank_tg:
            for name in ("kTelegramRsaPublicKey", "kTelegramPublicKey"):
                text, n = blank_literal(text, name)
                if n:
                    report.append(f"    blanked {name} (entry disabled in this build)")
        open(servers, "w", encoding="utf-8").write(text)

    print(f"  + purged upstream branding: {total} occurrences in {files_changed} files")
    for line in report:
        print(line)

    leftovers = []
    for path in walk_sources(root):
        try:
            text = open(path, encoding="utf-8").read()
        except (OSError, UnicodeDecodeError):
            continue
        if re.search(r"owpengram", text, re.I):
            leftovers.append(os.path.relpath(path, root))
    stragglers = [p for p in
                  (os.path.relpath(os.path.join(dp, f), root)
                   for dp, _, fs in os.walk(os.path.join(root, "Telegram"))
                   for f in fs)
                  if "owpengram" in p.lower()]
    if leftovers or stragglers:
        if leftovers:
            print("purge: text occurrences remain in:\n      "
                  + "\n      ".join(leftovers[:10]), file=sys.stderr)
        if stragglers:
            print("purge: paths still named for the fork:\n      "
                  + "\n      ".join(stragglers[:10]), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
