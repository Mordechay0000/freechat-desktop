#!/usr/bin/env bash
# Build the FreeChat desktop client on Linux or macOS.
#
# A wrapper around upstream's own flow, not a replacement for it. Telegram
# Desktop is configured through Telegram/configure.sh (which runs configure.py ->
# cmake/run_cmake.py) and built differently per platform; driving cmake directly
# does not work, and an earlier version of this script did exactly that. The
# authority is desktop/upstream/docs/building-{linux,mac}.md.
#
# NOT VERIFIED END TO END. prepare/{linux,mac}.sh compiles Qt, FFmpeg, OpenSSL and
# ~30 more libraries: tens of GB and hours. The environment that produced this
# repository had 11GB free, so the overlay is verified by reading the sources and
# this script by reading upstream's documentation. Treat a first failure as a
# toolchain gap on your machine, not a broken overlay, and send the error.
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

UP="$ROOT/desktop/upstream"
STAGE="${1:-build}"   # prepare | configure | build | all

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

case "$(uname -s)" in
  Linux)  OS=linux ;;
  Darwin) OS=mac ;;
  *) die "this script covers Linux and macOS. On Windows use scripts/build-desktop.ps1." ;;
esac

[[ -d "$UP/Telegram/SourceFiles" ]] || die "desktop upstream missing — ./scripts/bootstrap.sh desktop"
[[ -f "$UP/Telegram/SourceFiles/freechat/freechat_builtin.h" ]] \
  || die "overlay not applied — ./scripts/apply-overlay.sh desktop"
grep -q FreeChatBuiltin "$UP/Telegram/SourceFiles/intro/intro_server_select.cpp" \
  || die "the auto-join hook is missing — ./scripts/apply-overlay.sh desktop"

# Submodule directories exist but are EMPTY until checked out, so test for a file
# inside one. Testing the directory made this guard skip silently and handed an
# unreadable failure to cmake instead.
if [[ ! -f "$UP/Telegram/lib_base/CMakeLists.txt" ]]; then
  die "submodules are not checked out, and the build needs them:
      ./scripts/bootstrap.sh desktop --with-submodules
      Expect tens of GB."
fi

# shellcheck disable=SC1091
load_freechat_env "$ROOT" || die "cannot read the FreeChat configuration"
BRAND_ENV="$FREECHAT_ENV_SOURCES"

# Both are required by configure, and gramsrv does not validate either --
# internal/rpc/auth.go:874 says so outright: there is no application registry, the
# values are only remembered. So the defaults in freechat.env are fine for a
# self-hosted node and registering at my.telegram.org is not needed.
API_ID="${FREECHAT_API_ID:?FREECHAT_API_ID is not set in $BRAND_ENV}"
API_HASH="${FREECHAT_API_HASH:?FREECHAT_API_HASH is not set in $BRAND_ENV}"

do_prepare() {
  log "$OS: preparing third-party libraries (hours, tens of GB)"
  case "$OS" in
    linux)
      command -v docker >/dev/null || die "docker is required for the Linux build. See docs/building-linux.md"
      command -v poetry >/dev/null || warn "upstream's linux.sh expects poetry (https://python-poetry.org)"
      "$UP/Telegram/build/prepare/linux.sh"
      ;;
    mac)
      command -v brew >/dev/null || die "Homebrew is required. See docs/building-mac.md"
      log "installing build dependencies"
      brew install git automake libtool cmake wget pkg-config gnu-tar ninja nasm meson
      [[ -d /Applications/Xcode.app ]] \
        || die "Xcode is required (not just the command line tools). See docs/building-mac.md"
      sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
      "$UP/Telegram/build/prepare/mac.sh"
      ;;
  esac
}

do_configure() {
  # Reconfigure from scratch when the previous out/ was made for a different
  # source tree or different credentials: cmake caches both, and a stale cache
  # aborts with a message about itself rather than reconfiguring.
  local stamp="$UP/out/.freechat-configure-stamp"
  local want="$UP|$API_ID|$OS"
  if [[ -d "$UP/out" && "$(cat "$stamp" 2>/dev/null)" != "$want" ]]; then
    log "previous configuration does not match — discarding $UP/out"
    rm -rf "$UP/out"
  fi

  log "$OS: configuring"
  ( cd "$UP/Telegram" && ./configure.sh \
      -D TDESKTOP_API_ID="$API_ID" \
      -D TDESKTOP_API_HASH="$API_HASH" )
  mkdir -p "$UP/out" && printf '%s\n' "$want" > "$stamp"
}

do_build() {
  case "$OS" in
    linux)
      # Upstream builds Linux inside its own container; the host toolchain is
      # not what it targets.
      log "linux: building in the tdesktop:centos_env container"
      docker image inspect tdesktop:centos_env >/dev/null 2>&1 \
        || die "the tdesktop:centos_env image is missing — run: $0 prepare"
      docker run --rm -it \
        -u "$(id -u)" \
        -v "$UP:/usr/src/tdesktop" \
        tdesktop:centos_env \
        /usr/src/tdesktop/Telegram/build/docker/centos_env/build.sh \
        -D TDESKTOP_API_ID="$API_ID" \
        -D TDESKTOP_API_HASH="$API_HASH"
      log "result under $UP/out"
      ;;
    mac)
      [[ -d "$UP/out" ]] || die "not configured yet — run: $0 configure"
      log "mac: building"
      # cmake --build drives whatever generator configure.sh chose, so this works
      # whether that was Xcode or ninja, and needs no Xcode GUI step.
      cmake --build "$UP/out" --config Release --parallel "$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
      log "result under $UP/out — or open $UP/out/Telegram.xcodeproj in Xcode"
      ;;
  esac
}

case "$STAGE" in
  prepare)   do_prepare ;;
  configure) do_configure ;;
  build)     do_build ;;
  all)       do_prepare; do_configure; do_build ;;
  *) die "unknown stage '$STAGE' (prepare | configure | build | all)" ;;
esac

log "done"
