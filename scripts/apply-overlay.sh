#!/usr/bin/env bash
# Pour FreeChat's overlay onto the pinned upstream checkouts.
#
#   ./scripts/apply-overlay.sh [all|<component>]
#
# Idempotent: safe to re-run after a bootstrap, an upstream bump, or a partial
# failure. Every change is either a new file (no merge cost) or a single-line
# hook applied through scripts/lib/hook.py, which refuses to guess.
set -euo pipefail

# Cross-platform helpers (sha256, timeout, stat, OS detection). Linux, macOS and
# Windows-under-Git-Bash disagree on commands these scripts rely on, and a
# missing one is not a degraded result -- it is a script that stops.
# shellcheck source=lib/portable.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/portable.sh"


ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Safe KEY=VALUE loading. Sourcing a config file executes it; see the header of
# scripts/lib/load_env.sh for the hang that caused.
# shellcheck source=lib/load_env.sh
. "$ROOT/scripts/lib/load_env.sh"

HOOK="$ROOT/scripts/lib/hook.py"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# The components this repository holds. A split repository holds one.
TARGETS="desktop"

# Validated, not taken on trust. `ONLY="\${1:-all}"` accepted anything: a typo
# or a stray flag matched no component, applied nothing, and still printed
# "done" -- the same silent no-op that made bootstrap.sh report success after
# fetching nothing.
ONLY=all
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      printf 'usage: ./scripts/apply-overlay.sh [all|%s]\n' "${TARGETS// /|}"; exit 0 ;;
    -*) die "unknown option: $arg (usage: ./scripts/apply-overlay.sh [all|${TARGETS// /|}])" ;;
    *)
      if [[ "$arg" == all || " $TARGETS " == *" $arg "* ]]; then
        ONLY="$arg"
      else
        die "unknown component: $arg (this repository has: $TARGETS)"
      fi ;;
  esac
done
wants() { [[ "$ONLY" == all || "$ONLY" == "$1" ]]; }

# reset_upstream <upstream-dir> <checkout-paths...> -- <clean-paths...>
#
# Restores the pinned tree and deletes everything a previous run added, so every
# apply starts from the same state. Not a nicety: the purge renames the
# identifiers the hooks anchor on, and an overlay file this repo no longer ships
# would otherwise keep being compiled forever.
#
# Both halves are scoped to SOURCE paths, never the whole tree. Build output
# (TMessagesProj/.cxx, */build, out/) and things that cannot be recreated
# (local.properties, TMessagesProj/config/release.keystore, server .env, the
# server's data/ with its RSA key and blobs) all live outside them. A blanket
# `git clean -fd` here would cost 3.7GB of native objects and a 40-minute
# rebuild, or the server's identity key.
reset_upstream() {
  local up=$1; shift
  [[ -d "$up/.git" ]] || return 0

  local checkout=() clean=() seen_sep=0 arg
  for arg in "$@"; do
    if [[ "$arg" == -- ]]; then seen_sep=1; continue; fi
    if [[ "$seen_sep" == 0 ]]; then checkout+=("$arg"); else clean+=("$arg"); fi
  done

  # Pass only paths that exist: git fails the whole invocation on an unknown
  # pathspec, which would silently skip the reset entirely.
  local present=() p
  for p in "${checkout[@]}"; do [[ -e "$up/$p" ]] && present+=("$p"); done
  [[ ${#present[@]} -gt 0 ]] && git -C "$up" checkout --force -q -- "${present[@]}" 2>/dev/null || true

  present=()
  for p in "${clean[@]}"; do [[ -e "$up/$p" ]] && present+=("$p"); done
  [[ ${#present[@]} -gt 0 ]] && git -C "$up" clean -fdq -- "${present[@]}" 2>/dev/null || true
}

# copy_overlay <overlay-root> <upstream-root>
# Mirrors the overlay tree in, excluding nothing: paths are chosen to collide
# with no upstream file, so a clobber means the overlay needs renaming.
copy_overlay() {
  local src=$1 dst=$2 rel
  [[ -d "$src" ]] || return 0
  while IFS= read -r -d '' file; do
    rel="${file#"$src"/}"
    # The overlay root's README documents the overlay itself; it is not a file
    # to pour into the upstream tree.
    [[ "$rel" == "README.md" ]] && continue
    mkdir -p "$dst/$(dirname "$rel")"
    cp "$file" "$dst/$rel"
    printf '  + %s\n' "$rel"
  done < <(find "$src" -type f -print0)
}

# Load freechat.env and map it onto the BRAND_* names the platform functions use.
#
# One file, FREECHAT_* names, identical across the three repositories, so a value
# that means the same thing in two of them is spelled the same in both and a
# single shared env can drive all three. It replaces android/branding/brand.env
# and desktop/branding/brand.env, which held the same information twice.
#
# The address is DERIVED here rather than configured, in the form each platform
# requires, and that is the point of the change rather than a side effect:
#
#   android  a numeric IP, because the native transport uses inet_pton and does
#            not resolve names -- given a hostname it closes the socket before
#            connect() and logs nothing in a release build
#   desktop  the domain, because Qt's connectToHost resolves names itself, so a
#            changed server address needs no rebuild there at all
#
# Held as two hand-written strings they could disagree, and a wrong one produced
# a login that spun forever with no socket and nothing in the server log.
load_branding() {
  local platform=$1

  # Parsed, never sourced. `. "$env_file"` would RUN the file: the line
  # FREECHAT_SERVER_DESCRIPTION=Private node then means "run the command node",
  # which with node installed is a REPL waiting on stdin -- this script hung on
  # it for 13 minutes with no output. Whether it hangs depends on what stdin
  # happens to be, so it passes when tested and blocks in real use.
  load_freechat_env "$ROOT" || die "$platform: cannot read the FreeChat configuration"
  log "$platform: config <- $FREECHAT_ENV_SOURCES"

  : "${FREECHAT_SERVER_PORT:?FREECHAT_SERVER_PORT is not set in $FREECHAT_ENV_SOURCES}"
  : "${FREECHAT_SERVER_IP:?FREECHAT_SERVER_IP is not set in $FREECHAT_ENV_SOURCES}"

  BRAND_NAME="${FREECHAT_APP_NAME:?FREECHAT_APP_NAME missing}"
  BRAND_PACKAGE="${FREECHAT_ANDROID_PACKAGE:-}"
  BRAND_SERVER_DOMAIN="${FREECHAT_SERVER_DOMAIN:-}"
  BRAND_SERVER_DC="${FREECHAT_SERVER_DC:-2}"
  BRAND_SERVER_DESCRIPTION="${FREECHAT_SERVER_DESCRIPTION:-}"
  BRAND_INCLUDE_TELEGRAM="${FREECHAT_INCLUDE_TELEGRAM:-false}"
  # Not configurable any more. The upstream fork's own nodes are gone from both
  # clients, and a switch to put them back is a switch to reintroduce the bug
  # where the client holds a session on someone else's server.
  BRAND_INCLUDE_OWPENGRAM=false
  BRAND_AUTO_JOIN="${FREECHAT_AUTO_JOIN:-true}"
  BRAND_API_ID="${FREECHAT_API_ID:-}"
  BRAND_API_HASH="${FREECHAT_API_HASH:-}"

  case "$platform" in
    android)
      BRAND_SERVER_ADDRESS="$FREECHAT_SERVER_IP:$FREECHAT_SERVER_PORT"
      BRAND_SERVER_RSA_PUB="${FREECHAT_SERVER_RSA_PUB:+android/$FREECHAT_SERVER_RSA_PUB}"
      ;;
    desktop)
      # The domain when there is one, the IP otherwise -- Qt accepts either.
      BRAND_SERVER_ADDRESS="${FREECHAT_SERVER_DOMAIN:-$FREECHAT_SERVER_IP}:$FREECHAT_SERVER_PORT"
      BRAND_SERVER_RSA_PUB="${FREECHAT_SERVER_RSA_PUB:-}"
      ;;
  esac

  if [[ -n "$BRAND_SERVER_RSA_PUB" ]]; then
    local key="$ROOT/$BRAND_SERVER_RSA_PUB"
    [[ "$platform" == desktop ]] && key="$ROOT/desktop/$BRAND_SERVER_RSA_PUB"
    # Fail loudly. A missing key is not a degraded build: with the picker gone
    # there is no runtime path to supply one, so the client cannot handshake at
    # all. The published desktop repository shipped in exactly that state,
    # because its branding pointed at ../android/branding/server-rsa.pub, a path
    # that exists only when both platforms live under one tree.
    [[ -f "$key" ]] || die "$platform: FREECHAT_SERVER_RSA_PUB points at $BRAND_SERVER_RSA_PUB,
      which does not exist ($key).
      Each repository carries its own copy of the node's public key. Fetch it:
        curl -s http://\$FREECHAT_SERVER_DOMAIN:\$FREECHAT_SERVER_PORT/freechat/server-info \\
          | jq -r .rsa_public_key_pem > $BRAND_SERVER_RSA_PUB"
  fi
}

apply_desktop() {
  local up="$ROOT/desktop/upstream"
  [[ -d "$up/Telegram/SourceFiles" ]] || die "desktop upstream missing — run ./scripts/bootstrap.sh desktop"

  # Same reason as android: the purge renames the identifiers the hooks anchor
  # on, so a second run needs a clean tree. Tracked paths only -- never a blanket
  # clean, which would take the third-party build output with it.
  # checkout alone is not enough: the purge RENAMES tracked files, so restoring
  # them leaves the renamed copies behind untracked and both names end up in the
  # tree -- which the purge's own leftover check then fails on, correctly.
  log "desktop: resetting upstream to the pinned tree"
  # lib/ too: the purge renames lib/xdg/*, so each run has to start from the
  # fork's own names or a rename could be left half-applied by a changed fork.
  reset_upstream "$up" Telegram lib -- Telegram/SourceFiles Telegram/Resources lib

  log "desktop: overlay files"
  copy_overlay "$ROOT/desktop/overlay" "$up"

  load_branding desktop
  log "desktop: branding -> $BRAND_NAME @ $BRAND_SERVER_ADDRESS"

  # macOS deployment target for the libraries prepare/mac.sh builds. The app's
  # own target is passed to cmake by build-desktop.sh; both resolve it the same
  # way so they cannot disagree, which would be a link error. prepare.py is inside
  # the reset scope, so each run patches the pristine 10.13 -- a changed value in
  # freechat.env takes effect on the next apply.
  #
  # Within the SDK's supported range, not on trust: Xcode refuses to build for a
  # system its SDK does not list, and it says so only after prepare has spent half
  # an hour on Qt. The range comes from the SDK's own SDKSettings.plist via
  # scripts/lib/portable.sh, and the value is adapted (with the reason printed) so
  # the build continues instead of stopping.
  local mac_min requested range min max def
  requested="${FREECHAT_MACOS_DEPLOYMENT_TARGET:-12.0}"
  [[ "$requested" =~ ^[0-9]+(\.[0-9]+)*$ ]] \
    || die "FREECHAT_MACOS_DEPLOYMENT_TARGET='$requested' is not a version like 12.0"
  mac_min="$requested"
  if [[ "$(host_os)" == mac ]] && range="$(mac_sdk_deployment_target_range)"; then
    # shellcheck disable=SC2086  # a "min max default" triple, split on purpose.
    set -- $range
    min=$1; max=$2; def=${3:-$2}
    mac_min="$(mac_deployment_target_effective "$requested" "$min" "$max" "$def")"
    mac_deployment_target_note "$requested" "$mac_min" "$min" "$max" >&2
  fi
  py_run - "$up/Telegram/build/prepare/prepare.py" "$mac_min" <<'PYMAC' \
    || die "could not set the macOS deployment target in prepare.py"
import sys
path, want = sys.argv[1], sys.argv[2]
t = open(path, encoding="utf-8").read()
pairs = [("'MACOSX_DEPLOYMENT_TARGET': '10.13'", f"'MACOSX_DEPLOYMENT_TARGET': '{want}'"),
         ("'-mmacosx-version-min=10.13'", f"'-mmacosx-version-min={want}'")]
for old, new in pairs:
    if t.count(old) != 1:
        sys.exit(f"prepare.py: expected exactly one {old!r} -- upstream changed; update this hook")
    t = t.replace(old, new)
open(path, "w", encoding="utf-8").write(t)
PYMAC
  if [[ "$mac_min" == "$requested" ]]; then
    log "desktop: macOS deployment target -> $mac_min"
  else
    log "desktop: macOS deployment target -> $mac_min (adapted; freechat.env asks for $requested)"
  fi

  # The environment variable is not enough for breakpad: its .xcodeproj files
  # set MACOSX_DEPLOYMENT_TARGET=10.13 themselves, and Xcode rejects that ("the
  # range of supported deployment target versions is 12.0 to ..."). A build
  # setting on the xcodebuild command line overrides the project's.
  local xcb
  for xcb in \
    'xcodebuild -project processor.xcodeproj -target minidump_stackwalk -configuration Release build' \
    'xcodebuild -project Breakpad.xcodeproj -target Breakpad -configuration Debug build' \
    'xcodebuild -project Breakpad.xcodeproj -target Breakpad -configuration Release build' \
    'xcodebuild -project dump_syms.xcodeproj -target dump_syms -configuration Release build'; do
    py_run "$HOOK" "$up/Telegram/build/prepare/prepare.py" \
      "    $xcb
" "    $xcb MACOSX_DEPLOYMENT_TARGET=\$MACOSX_DEPLOYMENT_TARGET
"
  done
  # Qt enables dup3() when the SDK declares it, and the macOS 27 SDK does -- but
  # dup3 does not exist on any macOS the app targets. The result was a
  # libQt6Core.a that references _dup3: it fails to link against an older SDK
  # ("Undefined symbols: _dup3") and would fail to load on older macOS. Qt falls
  # back to dup2 + fcntl, which is what every macOS before 27 uses anyway.
  py_run "$HOOK" "$up/Telegram/build/prepare/prepare.py" \
    '        -no-feature-futimens \
' '        -no-feature-futimens \
        -no-feature-dup3 \
'
  # prepare.py exports CMAKE_GENERATOR=Ninja on macOS, but Qt's
  # -debug-and-release build is Ninja Multi-Config. CMake 4.x hands the
  # environment's generator to try_compile's test projects, which then fail
  # ("This should not have happened ... Failed to configure test project build
  # system", or "x86 intrinsics support missing"), and Qt's configure stops.
  py_run "$HOOK" "$up/Telegram/build/prepare/prepare.py" \
    'mac:
    ./configure -prefix "$USED_PREFIX/Qt-$QT" \
' 'mac:
    export CMAKE_GENERATOR="Ninja Multi-Config"
    ./configure -prefix "$USED_PREFIX/Qt-$QT" \
'
  # libheif builds its gdk-pixbuf loader whenever it finds gdk-pixbuf, and on a
  # Mac with Homebrew it does -- an arm64-only copy, so the universal
  # (x86_64;arm64) link fails with "symbol(s) not found for architecture
  # x86_64". The loader is never used by the app.
  py_run "$HOOK" "$up/Telegram/build/prepare/prepare.py" \
    '        -D WITH_EXAMPLES=OFF
    cmake --build . --config MinSizeRel' \
    '        -D WITH_EXAMPLES=OFF \\
        -D WITH_GDK_PIXBUF=OFF
    cmake --build . --config MinSizeRel'

  local header="$up/Telegram/SourceFiles/freechat/freechat_builtin.h"
  py_run - "$header" "$BRAND_NAME" "${BRAND_SERVER_DESCRIPTION:-}" \
    "$BRAND_SERVER_ADDRESS" "${BRAND_SERVER_DC:-2}" \
    "${BRAND_AUTO_JOIN:-true}" "${BRAND_INCLUDE_TELEGRAM:-false}" \
    "${BRAND_INCLUDE_OWPENGRAM:-false}" \
    "${BRAND_SERVER_RSA_PUB:+$ROOT/desktop/$BRAND_SERVER_RSA_PUB}" <<'PY7'
import os, re, sys

(path, name, desc, addr, dc, auto, inc_tg, inc_up, keypath) = (sys.argv + [""])[1:10]
text = open(path, encoding="utf-8").read()
truthy = {"1", "true", "yes", "on"}


def put(const, value):
    global text
    pat = r'(inline constexpr auto ' + const + r' = )[^;]*(;)'
    new, n = re.subn(pat, lambda m: m.group(1) + value + m.group(2), text, count=1)
    if n != 1:
        sys.exit(f"branding: {const} not found in {path}")
    text = new


# A hostname is fine here: Qt's connectToHost resolves it. Only the port has to
# be split off, and it has to be a number.
if ":" not in addr:
    sys.exit(f"branding: BRAND_SERVER_ADDRESS {addr!r} must be host:port")
host, _, port = addr.rpartition(":")
if not port.isdigit():
    sys.exit(f"branding: port {port!r} in BRAND_SERVER_ADDRESS is not a number")

put("kServerHost", f'"{host}"')
put("kServerPort", port)
put("kServerName", f'"{name}"')
put("kServerDescription", f'"{desc}"')
put("kServerDc", str(int(dc)))
put("kServerId", f'"{name.lower()}"')
put("kAutoJoin", "true" if auto.strip().lower() in truthy else "false")
put("kIncludeTelegram", "true" if inc_tg.strip().lower() in truthy else "false")
put("kIncludeUpstreamPublic", "true" if inc_up.strip().lower() in truthy else "false")

pem = ""
if keypath and os.path.isfile(keypath):
    raw = open(keypath, encoding="utf-8").read().strip()
    if "BEGIN RSA PUBLIC KEY" not in raw:
        sys.exit(f"branding: {keypath} is not a PKCS#1 'RSA PUBLIC KEY' PEM block")
    pem = raw.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + "\\n"
put("kServerRsaPublicKey", f'"{pem}"')

open(path, "w", encoding="utf-8").write(text)
print(f"  + built-in server {name} @ {host}:{port} dc={dc} "
      f"rsa={'embedded' if pem else 'none'}")
print(f"  + auto-join={auto} keep telegram={inc_tg} upstream={inc_up}")
PY7

  log "desktop: hooks"
  # Filter the compiled-in entries out of the picker's list.
  py_run "$HOOK" "$up/Telegram/SourceFiles/owpengram/owpengram_servers.cpp" \
    '#include "owpengram/owpengram_servers.h"' \
    '#include "owpengram/owpengram_servers.h"

#include "freechat/freechat_builtin.h"'
  py_run "$HOOK" "$up/Telegram/SourceFiles/owpengram/owpengram_servers.cpp" \
    '	for (const auto &custom : ReadCustomServers()) {
		result.push_back(custom);
	}
	return result;' \
    '	for (const auto &custom : ReadCustomServers()) {
		result.push_back(custom);
	}
	return FreeChatBuiltin::AdjustServerList(std::move(result));'

  # Bypass the picker. Inserted INSIDE ServerSelectWidget so it can call that
  # class's private proceedJoin() -- the same path clicking a server takes, so
  # ApplyServerToAccount, the ConnectingBox with its Cancel, the connection wait
  # and the hand-off to the next step all stay upstream's tested code.
  py_run "$HOOK" "$up/Telegram/SourceFiles/intro/intro_server_select.cpp" \
    '#include "intro/intro_server_select.h"' \
    '#include "intro/intro_server_select.h"

#include "freechat/freechat_builtin.h"'
  py_run "$HOOK" "$up/Telegram/SourceFiles/intro/intro_server_select.cpp" \
    'void ServerSelectWidget::activate() {
	Step::activate();' \
    'void ServerSelectWidget::activate() {
	Step::activate();
	if (const auto freechatAutoJoin = FreeChatBuiltin::AutoJoinServer()) {
		proceedJoin(*freechatAutoJoin);
		return;
	}'

  log "desktop: purging upstream branding"
  py_run "$ROOT/scripts/lib/purge_branding_desktop.py" "$up" "$BRAND_NAME" \
    "$([[ "${BRAND_INCLUDE_TELEGRAM:-false}" =~ ^(1|true|yes|on)$ ]] && echo false || echo true)" \
    || die "desktop branding purge failed — see the paths above"

  # Every file the build will look for must exist NOW. The purge rewrites names
  # in CMakeLists.txt and the .qrc files; if a reference and its file ever
  # disagree, the build fails -- but only after prepare has spent hours on Qt
  # and FFmpeg, and in a message about rcc that says nothing about this script.
  # That happened: telegram.qrc named lib/xdg/org.freechat.desktop.desktop while
  # the file still carried the fork's name. Checked here, it costs a second.
  log "desktop: checking every file the build references exists"
  py_run - "$up" <<'PYREF' || die "the tree references files that do not exist (listed above)"
import os, re, sys, glob
up = sys.argv[1]
missing = []
# .qrc entries are relative to the .qrc file.
for q in glob.glob(os.path.join(up, "Telegram/Resources/**/*.qrc"), recursive=True):
    base = os.path.dirname(q)
    for f in re.findall(r"<file[^>]*>([^<]+)</file>", open(q, encoding="utf-8").read()):
        if not os.path.exists(os.path.normpath(os.path.join(base, f.strip()))):
            missing.append(f"{os.path.relpath(q, up)}: {f.strip()}")
# configure_file() inputs are relative to Telegram/.
cm = os.path.join(up, "Telegram/CMakeLists.txt")
for f in re.findall(r'configure_file\(\s*"([^"$]+)"', open(cm, encoding="utf-8").read()):
    if not os.path.exists(os.path.normpath(os.path.join(up, "Telegram", f))):
        missing.append(f"Telegram/CMakeLists.txt configure_file: {f}")
for m in missing:
    print("  MISSING " + m, file=sys.stderr)
sys.exit(1 if missing else 0)
PYREF

  log "desktop: overlay applied"
}

applied=0
if wants desktop; then
  apply_desktop
  applied=$((applied + 1))
fi
(( applied > 0 )) || die "nothing was applied for '$ONLY' (this repository has: $TARGETS)"
log "done"
