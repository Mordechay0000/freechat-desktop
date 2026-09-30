#!/usr/bin/env bash
# Build the FreeChat desktop client on Linux or macOS.
#
# A wrapper around upstream's own flow, not a replacement for it. Telegram
# Desktop is configured through Telegram/configure.sh (which runs configure.py ->
# cmake/run_cmake.py) and built differently per platform; driving cmake directly
# does not work, and an earlier version of this script did exactly that. The
# authority is desktop/upstream/docs/building-{linux,mac}.md.
#
# Verified, and how far: the macOS path was run end to end on 2026-09-30 on the
# machine this repository was developed on -- prepare (Qt 6.11.1: ~30 minutes,
# 26GB of build tree plus 8.3GB installed), configure, and a Release build that
# produced out/Release/FreeChat.app, universal x86_64+arm64, 1.6GB, ad-hoc
# signed. The Linux and Windows paths are still unrun: no docker image and no
# Visual Studio were involved. Treat a first failure there as a toolchain gap
# rather than a broken overlay, and send the error. The numbers are in
# docs/10-DESKTOP.md.
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
STAGE="${1:-build}"   # doctor | prepare | configure | build | all

# log, warn and die come from lib/portable.sh: every progress line carries the
# time, which is what makes a half-hour stage readable afterwards.

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
# unreadable failure to cmake instead. This is the cheap gate that runs on every
# stage; `prepare` and `doctor` additionally ask git whether the whole tree is
# complete, because "one file exists" is not the same as "36 submodules are
# checked out" -- an interrupted fetch can leave most of them empty.
if [[ ! -f "$UP/Telegram/lib_base/CMakeLists.txt" ]]; then
  die "submodules are not checked out, and the build needs them:
      ./scripts/bootstrap.sh desktop --with-submodules
      Expect tens of GB. If that command was interrupted, run it again: git
      continues and skips the submodules it already has."
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

# --- compatibility checks ---------------------------------------------------
#
# None of these is about the source tree, which either builds or does not. They
# are about the machine and the prepared state, because that is where the
# expensive failures come from: a half-installed Qt produced "Neither Qt6 nor
# Qt5 is found" with no mention of prepare; an Xcode upgrade silently made the
# deployment target unbuildable and the error arrived after half an hour of Qt;
# a submodule that was never checked out failed inside a missing header hours
# into a build. Each takes milliseconds -- no compiler is invoked -- so they run
# before the stage that could waste hours, and `doctor` prints them all at once.

mac_target=""   # the deployment target this build will use, resolved below

# `xcodebuild -version | head -1` dies of SIGPIPE under `set -o pipefail` -- the
# reader exits, xcodebuild is killed, the pipeline reports 141 -- and the line it
# feeds printed "Xcode 26.6" followed by a bogus "<none>". Read it all, then take
# the first line.
xcode_version() {
  local v
  v="$(xcodebuild -version 2>/dev/null || true)"
  printf '%s' "${v%%$'\n'*}"
}

# Resolve the macOS deployment target against the toolchain that is actually
# installed, and say so when the value in freechat.env cannot be built.
#
# The libraries (prepare.py, written by apply-overlay.sh) and the app (cmake,
# here) both take this value, and a mismatch between them is a link error -- so
# both call this same resolver rather than reading the key themselves.
resolve_mac_target() {
  local requested="${FREECHAT_MACOS_DEPLOYMENT_TARGET:-12.0}"
  local range min max def effective
  mac_target="$requested"
  [[ "$OS" == mac ]] || return 0

  if ! range="$(mac_sdk_deployment_target_range)"; then
    # No SDK plist: an older Xcode, an SDK packaged without SupportedTargets. The
    # value is used as-is and said to be unchecked, because quietly treating
    # "cannot check" as "fine" is how a wrong target reaches a linker.
    warn "cannot read the supported deployment targets from this SDK — using $requested unverified"
    return 0
  fi
  # shellcheck disable=SC2086  # a "min max default" triple, split on purpose.
  set -- $range
  min=$1; max=$2; def=${3:-$2}
  effective="$(mac_deployment_target_effective "$requested" "$min" "$max" "$def")"
  if [[ "$effective" != "$requested" ]]; then
    mac_deployment_target_note "$requested" "$effective" "$min" "$max" >&2
  fi
  mac_target="$effective"
}

# The libraries and the app get the deployment target from two different places
# and two different runs of the resolver. If the toolchain changed in between
# they disagree, and the symptom is a link error inside a library, hours in. The
# value already written into prepare.py is what prepare will build with, so
# compare against that one.
check_prepare_target() {
  local prepare_py="$UP/Telegram/build/prepare/prepare.py"
  local written
  [[ "$OS" == mac ]] || return 0
  # Upstream not bootstrapped (or a path this hook no longer knows) is not this
  # check's business: report that it cannot be made and let the stage itself say
  # what is missing.
  [[ -f "$prepare_py" ]] || { warn "no prepare.py yet — skipping the deployment target check"; return 0; }
  written="$(sed -n "s/^ *'MACOSX_DEPLOYMENT_TARGET': '\([^']*\)'.*/\1/p;/^ *'MACOSX_DEPLOYMENT_TARGET': /q" \
              "$prepare_py")"
  [[ -n "$written" ]] || { warn "cannot read the deployment target out of prepare.py — skipping the check"; return 0; }
  [[ "$written" == "$mac_target" ]] && return 0
  die "the libraries and the app would be built for different macOS versions:
      prepare.py (libraries)  $written
      this build (app)        $mac_target
      That is a link error later, not a warning now. Make them agree:
      ./scripts/apply-overlay.sh desktop
      (which writes the resolved target into prepare.py), then re-run prepare."
}

# The check behind "Neither Qt6 nor Qt5 is found".
#
# cmake says that when find_package cannot see Qt, and it names the symptom
# rather than the cause: on macOS the app links a STATIC Qt that prepare.py
# installs under Libraries/local/Qt-<version>, so the message means that install
# is absent or half-written. It is absent far more often than it is broken:
# prepare.py's Qt stage begins with `rm -rf qt_<version>`, so a run that is
# interrupted -- disk full, Ctrl-C, a dropped network -- leaves no Qt at all, and
# its cache key (which records success) is never written.
require_prepared_qt() {
  local qt
  [[ "$OS" == mac ]] || return 0
  qt="$(prepared_qt_dir "$ROOT/desktop/Libraries")" && return 0
  die "the static Qt the app links against is not installed.
      cmake reports this as \"Neither Qt6 nor Qt5 is found\".
      prepare.py installs Qt under desktop/Libraries/local/Qt-<version>, and that
      directory is missing or half-written — usually because prepare was
      interrupted. Rebuild it:
        ./scripts/build-desktop.sh prepare       (about 30 minutes, ~35GB free)
      If prepare believes the stage is already done, force it:
        rm -f desktop/Libraries/cache_keys/qt_*
      A partial install does not count: check for lib/cmake/Qt6/Qt6Config.cmake."
}

# Ask git whether every submodule is really there, not merely that one file is.
check_submodules() {
  local action=$1 count
  if ! count="$(verify_submodules "$UP" "$action")"; then
    die "the upstream submodules are incomplete, and the build needs every one.
      ./scripts/bootstrap.sh desktop --with-submodules
      A second run resumes where the first stopped: git fetches what is missing
      and skips what is present."
  fi
  log "desktop: $count submodules verified"
}

# Homebrew, but only for what is missing. `brew install` of an installed formula
# is harmless in effect and expensive in practice: it drags brew's own updater
# along, which is minutes of output before anything is built.
install_brew_tools() {
  local missing=() t cmd
  for t in git automake libtool cmake wget pkg-config gnu-tar ninja nasm meson; do
    # The capability, not the formula name: Homebrew's pkg-config formula is
    # spelled pkgconf, and the command it installs is what the build needs.
    cmd="$t"
    [[ "$t" == "gnu-tar" ]] && cmd="gtar"
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$t")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log "installing missing build tools: ${missing[*]}"
    brew install "${missing[@]}"
  else
    log "build tools present (brew)"
  fi
}

# Disk, before rather than during. A build that runs out of space dies in the
# middle, and the stage's cache key is written only on success -- so the next run
# starts the same hours-long stage over. Measured here: prepare peaks around 35GB
# (26GB of Qt build tree plus an 8.3GB install), the app build about 10GB.
require_disk() {
  local need=$1 what=$2 have
  have="$(free_space_gb "$ROOT/desktop")"
  [[ -n "$have" ]] || return 0
  if (( have < need )); then
    warn "${have}GB free under desktop/, and $what has been measured at about ${need}GB here."
    warn "  Running out mid-build wastes the whole stage: its cache key is written only"
    warn "  on success. Free space first, or expect to start over."
  fi
}

# What the prepared libraries were built with. They are static: when the
# toolchain changes afterwards, the app links objects from a different compiler
# and a different SDK. That either fails while linking -- Qt referenced _dup3
# under the macOS 27 SDK, and _dup3 exists on no macOS the app targets -- or
# produces a binary nobody tested. Rebuilding ~30 libraries takes hours, so this
# is a warning with the reason attached, not a refusal.
toolchain_stamp_path() { printf '%s' "$ROOT/desktop/Libraries/.freechat-toolchain"; }

toolchain_id() {
  case "$OS" in
    mac)   printf '%s|%s|%s' \
             "$(xcode_version)" \
             "$(mac_sdk_path || printf 'no-sdk')" \
             "$mac_target" ;;
    linux) printf 'container|%s' \
             "$(docker image inspect --format '{{.Id}}' tdesktop:centos_env 2>/dev/null || printf 'no-image')" ;;
  esac
}

write_toolchain_stamp() {
  mkdir -p "$(dirname "$(toolchain_stamp_path)")"
  toolchain_id > "$(toolchain_stamp_path)"
}

check_toolchain_stamp() {
  local path current recorded
  path="$(toolchain_stamp_path)"
  [[ -f "$path" ]] || return 0
  current="$(toolchain_id)"
  recorded="$(cat "$path" 2>/dev/null || true)"
  [[ "$current" == "$recorded" ]] && return 0
  warn "the prepared libraries were built with a different toolchain:"
  warn "  built with  $recorded"
  warn "  now         $current"
  warn "  If the build fails with \"Undefined symbols\" naming a function the current"
  warn "  SDK does not have, the libraries must be rebuilt: ./scripts/build-desktop.sh prepare"
}

do_prepare() {
  case "$OS" in
    linux)
      command -v docker >/dev/null || die "docker is required for the Linux build. See docs/building-linux.md"
      command -v poetry >/dev/null || warn "upstream's linux.sh expects poetry (https://python-poetry.org)"
      check_submodules repair
      # PYTHONUNBUFFERED: prepare.py block-buffers its narration when stdout is
      # not a terminal, so the list of stages and the commands they run would all
      # appear after the half hour they describe. See lib/portable.sh.
      PYTHONUNBUFFERED=1 step "linux: preparing the third-party libraries (hours, tens of GB)" \
        "$UP/Telegram/build/prepare/linux.sh"
      write_toolchain_stamp
      ;;
    mac)
      # Xcode first: everything below assumes a working toolchain, and this is
      # the check that explains itself instead of failing inside Qt's configure.
      mac_require_xcode || exit 1
      resolve_mac_target
      check_prepare_target
      log "macOS deployment target: $mac_target"
      command -v brew >/dev/null || die "Homebrew is required. See docs/building-mac.md"
      install_brew_tools
      check_submodules repair
      # Qt is 35GB of the prepare peak, so the warning is about it: when Qt is
      # already installed the stage has nothing large left to do, and a re-run
      # would get a warning about space it is not going to use.
      if ! prepared_qt_dir "$ROOT/desktop/Libraries" >/dev/null 2>&1; then
        require_disk 35 "prepare (Qt, FFmpeg, OpenSSL)"
      fi

      # prepare.py asks (r)ebuild/(a)ll/(s)kip/(p)rint/(q)uit before re-running a
      # stage whose key changed, and its getch() needs a controlling terminal:
      # with none it dies with "termios.error: (19, 'Operation not supported by
      # device')" and the stage is lost. Nobody is there to answer, so answer for
      # them; an interactive run keeps the prompt.
      local prep_args=()
      if [[ ! -t 0 ]]; then
        log "stdin is not a terminal — running prepare.py with 'silent' (no prompts)"
        prep_args=(silent)
      fi
      PYTHONUNBUFFERED=1 step "mac: preparing the third-party libraries (hours, tens of GB)" \
        "$UP/Telegram/build/prepare/mac.sh" ${prep_args[@]+"${prep_args[@]}"}
      write_toolchain_stamp
      ;;
  esac
}

do_configure() {
  resolve_mac_target
  check_prepare_target
  check_toolchain_stamp
  require_prepared_qt

  # Reconfigure from scratch when the previous out/ was made for a different
  # source tree, different credentials or a different macOS target: cmake caches
  # all of them, and a stale cache aborts with a message about itself rather than
  # reconfiguring.
  local stamp="$UP/out/.freechat-configure-stamp"
  local want="$UP|$API_ID|$OS|$mac_target"
  if [[ -d "$UP/out" && "$(cat "$stamp" 2>/dev/null)" != "$want" ]]; then
    log "previous configuration does not match — discarding $UP/out"
    rm -rf "$UP/out"
  fi

  # Upstream's cmake sets 10.13 as a CACHE entry, which a -D on the command line
  # overrides without touching the submodule.
  local mac_args=()
  if [[ "$OS" == mac ]]; then
    mac_args=(-D CMAKE_OSX_DEPLOYMENT_TARGET="$mac_target")
  fi
  # The command is printed so a log says what ran, with the API hash elided: it is
  # a value from freechat.env rather than a secret (gramsrv does not validate it),
  # but a log is pasted into bug reports and there is no reason to copy it there.
  log "$OS: configuring"
  printf '    $ ./configure.sh -D TDESKTOP_API_ID=%s -D TDESKTOP_API_HASH=<hash>%s\n' \
    "$API_ID" "${mac_args[*]-}"
  ( cd "$UP/Telegram" && PYTHONUNBUFFERED=1 ./configure.sh \
      -D TDESKTOP_API_ID="$API_ID" \
      -D TDESKTOP_API_HASH="$API_HASH" \
      ${mac_args[@]+"${mac_args[@]}"} )
  mkdir -p "$UP/out" && printf '%s\n' "$want" > "$stamp"
}

do_build() {
  resolve_mac_target
  check_toolchain_stamp
  require_prepared_qt
  case "$OS" in
    linux)
      # Upstream builds Linux inside its own container; the host toolchain is
      # not what it targets.
      docker image inspect tdesktop:centos_env >/dev/null 2>&1 \
        || die "the tdesktop:centos_env image is missing — run: $0 prepare"
      step "linux: building in the tdesktop:centos_env container" \
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
      require_disk 12 "the app build"
      # cmake --build drives whatever generator configure.sh chose, so this works
      # whether that was Xcode or ninja, and needs no Xcode GUI step.
      step "mac: building" \
        cmake --build "$UP/out" --config Release --parallel "$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
      log "result under $UP/out — or open $UP/out/Telegram.xcodeproj in Xcode"
      ;;
  esac
}

# Everything the stages check, in one place, changing nothing. Read-only on
# purpose: a script that "fixes" things is a script nobody runs to find out what
# is wrong. Exit status is 1 when something must be dealt with before a build,
# so `./scripts/build-desktop.sh doctor && ./scripts/build-desktop.sh all` means
# something.
do_doctor() {
  local blockers=0 qt keys
  printf 'FreeChat desktop — preparation and toolchain\n\n'
  printf '  host           %s\n' "$OS"
  printf '  upstream       %s\n' "$UP"
  printf '  configuration  %s\n' "$BRAND_ENV"
  printf '  disk free      %sGB under desktop/\n' "$(free_space_gb "$ROOT/desktop" || printf 'unknown')"

  if [[ "$OS" == mac ]]; then
    printf '  xcode          %s\n' "$(xcode_version)"
    printf '  sdk            %s\n' "$(mac_sdk_path || printf '<none>')"
    printf '  target range   %s (oldest, newest, default)\n' "$(mac_sdk_deployment_target_range || printf 'unknown')"
    resolve_mac_target
    printf '  target in use  %s (from freechat.env: %s)\n' \
      "$mac_target" "${FREECHAT_MACOS_DEPLOYMENT_TARGET:-<unset, default 12.0>}"
  fi

  printf '\n'
  if qt="$(prepared_qt_dir "$ROOT/desktop/Libraries")"; then
    printf '  prepared Qt    %s\n' "${qt#"$ROOT/"}"
    if [[ ! -f "$qt/lib/cmake/Qt6/Qt6Config.cmake" ]]; then
      printf '                 ^ no Qt6 cmake config: a partial install\n'
      blockers=$((blockers + 1))
    fi
  else
    printf '  prepared Qt    missing — nothing has been prepared yet, or prepare was\n'
    printf '                 interrupted: ./scripts/build-desktop.sh prepare (~35GB)\n'
  fi
  local keys=0 k
  for k in "$ROOT/desktop/Libraries/cache_keys"/*; do
    if [ -e "$k" ]; then keys=$((keys + 1)); fi
  done
  printf '  prepare keys   %s stages recorded under desktop/Libraries/cache_keys\n' "$keys"
  # verify_submodules, not check_submodules: doctor reports, it does not die on
  # the first problem -- the point is to see everything at once.
  local sub_count
  if sub_count="$(verify_submodules "$UP" check)"; then
    printf '  submodules     %s checked out and complete\n' "$sub_count"
  else
    blockers=$((blockers + 1))
  fi
  if [[ -e "$(toolchain_stamp_path)" ]]; then
    printf '  toolchain      %s\n' "$(cat "$(toolchain_stamp_path)" 2>/dev/null)"
    check_toolchain_stamp
  fi
  if [[ -d "$UP/out" ]]; then
    printf '  build output   %s (configure stamp: %s)\n' \
      "$UP/out" "$(cat "$UP/out/.freechat-configure-stamp" 2>/dev/null || printf 'none')"
  else
    printf '  build output   not configured yet — ./scripts/build-desktop.sh configure\n'
  fi

  printf '\n'
  if (( blockers > 0 )); then
    printf '  %d problem(s) above must be dealt with before a build.\n' "$blockers"
    return 1
  fi
  printf '  nothing blocking. next: ./scripts/build-desktop.sh all\n'
}

case "$STAGE" in
  doctor)    do_doctor ;;
  prepare)   do_prepare ;;
  configure) do_configure ;;
  build)     do_build ;;
  all)       do_prepare; do_configure; do_build ;;
  *) die "unknown stage '$STAGE' (doctor | prepare | configure | build | all)" ;;
esac

log "done"
