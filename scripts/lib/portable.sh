# Cross-platform helpers for the bash scripts in this project.
#
# Sourced, not run:
#   . "$ROOT/scripts/lib/portable.sh"
#
# FreeChat is developed and deployed on Linux, built on all three desktop
# operating systems, and the shared scripts have to run on each. The differences
# that actually bite are few but total -- a missing command is not a degraded
# result, it is a script that stops:
#
#   sha256sum   GNU coreutils. macOS ships `shasum -a 256` instead, with a
#               different name and different output spacing.
#   timeout     GNU coreutils. macOS ships nothing equivalent; Homebrew's
#               coreutils installs it as `gtimeout`.
#   stat -c     GNU. BSD/macOS spells the same thing `stat -f`.
#
# Windows is served through Git Bash (Git for Windows), which provides a real
# bash plus GNU coreutils, so these helpers resolve the GNU spelling there. It is
# not WSL and not cmd.exe: see require_bash_on_windows below.

# sha256_of  --  hash stdin, print the bare hex digest.
#
# Returns 1 with a message when neither tool exists, rather than printing an
# empty string that a caller would happily compare against another empty string
# and call equal. A fingerprint check that silently compares "" to "" passes
# always, which is the worst possible failure for a test.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -d' ' -f1
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 | sed 's/^.*= //'
  else
    printf 'sha256_of: no sha256sum, shasum or openssl on PATH\n' >&2
    return 1
  fi
}

# with_timeout <seconds> <command...>  --  run with a deadline where possible.
#
# Prints nothing extra on success. When no timeout implementation exists (a plain
# macOS without Homebrew coreutils), the command runs WITHOUT a deadline and a
# note goes to stderr, because the alternative -- skipping the command -- turns a
# probe into a silent no-op. A caller that must not run unbounded should check
# have_timeout first.
have_timeout() {
  command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1
}

with_timeout() {
  local secs=$1; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  else
    printf 'with_timeout: no timeout(1) on this system (macOS: brew install coreutils);\n' >&2
    printf '              running without a deadline: %s\n' "$1" >&2
    "$@"
  fi
}

# owner_of <path>  --  the owning user's name.
owner_of() {
  if stat -c '%U' "$1" >/dev/null 2>&1; then
    stat -c '%U' "$1"
  else
    stat -f '%Su' "$1"
  fi
}

# host_os  --  linux | mac | windows | unknown
#
# Git Bash reports MINGW64_NT-* / MSYS_NT-*, Cygwin reports CYGWIN_NT-*. WSL
# reports Linux, and that is correct: under WSL this IS Linux, with Linux paths
# and a Linux toolchain, which matters because a Windows Android SDK or Visual
# Studio install is not reachable from it in the way people expect.
host_os() {
  case "$(uname -s)" in
    Linux)                   printf 'linux' ;;
    Darwin)                  printf 'mac' ;;
    MINGW*|MSYS*|CYGWIN*)    printf 'windows' ;;
    *)                       printf 'unknown' ;;
  esac
}

# require_bash_on_windows <what>  --  explain the one Windows prerequisite.
#
# The project's shared scripts (bootstrap, apply-overlay, sync-upstream) are bash
# and there is no PowerShell equivalent of them, by choice: they are the same code
# on all three systems, and a second implementation would be a second set of bugs.
# On Windows they run under Git Bash, which every Telegram Desktop Windows build
# needs anyway. This function exists so that a user who somehow runs one of them
# outside bash gets a sentence telling them what to install instead of a syntax
# error from cmd.exe.
require_bash_on_windows() {
  if [[ -z "${BASH_VERSION:-}" ]]; then
    printf 'error: this script needs bash.\n' >&2
    printf '  Windows: install Git for Windows and run it from "Git Bash",\n' >&2
    printf '           not cmd.exe or PowerShell.\n' >&2
    exit 1
  fi
}

# --- Python ----------------------------------------------------------------
# PY / py_run  --  invoke Python 3 by whatever name it has on this system.
#
# apply-overlay.sh calls Python 21 times and it is mandatory for every build on
# every system, so the name matters. On Linux and macOS it is `python3`. On
# Windows a python.org install provides `python.exe` and the `py.exe` launcher and
# NOT `python3`, so every one of those 21 calls failed there -- and
# build-desktop.ps1 checked for `python` while the bash script it hands you needs
# `python3`, so the two disagreed and the Windows path broke at its second step
# with "python3: command not found".
#
# Resolved by asking the interpreter its version rather than trusting its name: a
# `python` that is Python 2 is worse than no python, because it runs and then
# fails somewhere inside a script with a syntax error.
PY=""
resolve_python() {
  local c
  for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1 \
       && "$c" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' 2>/dev/null; then
      PY="$c"
      return 0
    fi
  done
  # The Windows launcher. Two words, which is why py_run expands $PY unquoted.
  if command -v py >/dev/null 2>&1 && py -3 -c 'import sys' >/dev/null 2>&1; then
    PY="py -3"
    return 0
  fi
  return 1
}

py_run() {
  if [[ -z "$PY" ]]; then
    printf '\033[1;31merror:\033[0m no Python 3 on PATH.\n' >&2
    printf '  Linux    install python3 from your package manager\n' >&2
    printf '  macOS    comes with the Xcode command line tools: xcode-select --install\n' >&2
    printf '  Windows  install Python 3 from python.org and tick "Add to PATH".\n' >&2
    printf '           `python3` does not exist there; this handles `python` and `py -3`.\n' >&2
    exit 1
  fi
  # PYTHONUNBUFFERED: Python block-buffers its stdout whenever it is not a
  # terminal, which is every invocation here. The messages then arrive in one
  # lump when the process exits -- the prepare stage's list of what it is about to
  # build, and the commands it is about to run, all printed AFTER the half hour
  # they describe. That is what "the output is swallowed" looks like from the
  # outside: it is not missing, it is late.
  #
  # Deliberately unquoted: $PY may be "py -3", which has to split into two words.
  # shellcheck disable=SC2086
  PYTHONUNBUFFERED=1 $PY "$@"
}

resolve_python || true

# --- progress output --------------------------------------------------------
#
# One definition for every script, for two reasons.
#
# The time: a prepare stage runs for half an hour and a build for longer, and
# "which step was it in when it stopped" is the first question anyone asks of a
# log they were not watching.
#
# And because the same three functions had been copied into four scripts and had
# started to drift -- only build-desktop.sh had a warn -- so a script added later
# would have invented a fifth format.
#
# Warnings go to stdout, errors to stderr, which is what the scripts already did:
# a build log written with `> log.txt` keeps the warnings, and a failure is still
# on the console even when stdout is redirected. The colours are ANSI escapes in
# the text itself, as they have always been here: a terminal shows them, and a
# redirected file keeps the bytes instead of losing the line.

# stamp  --  HH:MM:SS, or a placeholder if date cannot say.
stamp() {
  date +%H:%M:%S 2>/dev/null || printf '%s' '--:--:--'
}

log()  { printf '\033[1;34m==> [%s]\033[0m %s\n' "$(stamp)" "$*"; }
warn() { printf '\033[1;33m!\033[0m [%s] %s\n' "$(stamp)" "$*"; }
die()  { printf '\033[1;31merror:\033[0m [%s] %s\n' "$(stamp)" "$*" >&2; exit 1; }

# step <description> <command...>  --  say what is about to run, then run it.
#
# The long stages are given as one line naming the command, because "which
# command, exactly" is the question a log is kept for, and because the alternative
# -- discovering it afterwards in upstream's own output -- only works if that
# output arrived in order (see PYTHONUNBUFFERED above).
step() {
  local description=$1; shift
  log "$description"
  printf '    $ %s\n' "$*"
  "$@"
}

# --- macOS toolchain --------------------------------------------------------
#
# Two places set the macOS deployment target -- prepare.py for the ~30 libraries
# it builds, and CMAKE_OSX_DEPLOYMENT_TARGET for the app -- and when the installed
# Xcode stops supporting that value it refuses to build:
#
#   error: The macOS deployment target 'MACOSX_DEPLOYMENT_TARGET' is set to
#   12.0, but the range of supported deployment target versions is 12.0 to
#   27.0.99   (Xcode 27 beta; Xcode 26.6 accepts 10.13 to 26.5.99)
#
# The floor moves: this machine lost 12.0 and gained 10.13 in a single day when
# Xcode 27 beta was replaced by 26.6. So the supported range is read from the
# SDK's own SDKSettings.plist -- the file Xcode itself reads -- and the decision
# is a pure function, so scripts/selftest.sh can drive it with a fabricated range
# instead of needing an Xcode to test against.
#
# These live in portable.sh rather than in a lib/ file of their own on purpose.
# The split repositories copy scripts/lib file by file (scripts/split-repos.sh in
# the monorepo), so a new file that nobody added to that list makes every desktop
# script die at its source line, in a repository whose scripts are otherwise fine.
# One file fewer to remember in two places.

# version_cmp <a> <b>  --  print -1, 0 or 1.
#
# Missing components are 0, so "12.0" == "12" and "26.5.99" > "26.5". Only the
# first four components are looked at, which is more than macOS versions have.
# Deliberately not `sort -V`: BSD sort does not have it.
version_cmp() {
  local -a a b
  local i x y
  # Split on '.' by reading them as arrays with IFS set for the read only, which
  # leaves the caller's IFS alone. A string compare would order 9.0 above 12.0.
  IFS=. read -r -a a <<< "$1"
  IFS=. read -r -a b <<< "$2"
  for i in 0 1 2 3; do
    x="${a[i]:-0}"; y="${b[i]:-0}"
    # Anything that is not a digit is dropped, so a value read from a config file
    # with a stray space cannot compare as unequal to its own spelling.
    x="${x//[!0-9]/}"; y="${y//[!0-9]/}"
    : "${x:=0}"; : "${y:=0}"
    [ "$x" -gt "$y" ] && { printf '1'; return 0; }
    [ "$x" -lt "$y" ] && { printf '%s' -1; return 0; }
  done
  printf '0'
}

# mac_sdk_path  --  print the SDK Xcode will use; nothing on other systems.
mac_sdk_path() {
  command -v xcrun >/dev/null 2>&1 || return 1
  xcrun --show-sdk-path 2>/dev/null
}

# mac_sdk_deployment_target_range [sdk]  --  print "<min> <max> <default>".
#
# From SDKSettings.plist, which is where Xcode gets the range it enforces.
# Returns non-zero when it cannot be read -- not macOS, no plutil, an SDK without
# SupportedTargets -- and callers must treat that as "cannot check", not "fine".
mac_sdk_deployment_target_range() {
  local sdk=${1:-}
  local plist min max def
  [ -n "$sdk" ] || sdk="$(mac_sdk_path)" || true
  [ -n "$sdk" ] || return 1
  plist="$sdk/SDKSettings.plist"
  [ -f "$plist" ] || return 1
  command -v plutil >/dev/null 2>&1 || return 1
  min="$(plutil -extract SupportedTargets.macosx.MinimumDeploymentTarget raw -o - "$plist" 2>/dev/null || true)"
  max="$(plutil -extract SupportedTargets.macosx.MaximumDeploymentTarget raw -o - "$plist" 2>/dev/null || true)"
  def="$(plutil -extract SupportedTargets.macosx.DefaultDeploymentTarget raw -o - "$plist" 2>/dev/null || true)"
  [ -n "$min" ] && [ -n "$max" ] || return 1
  printf '%s %s %s\n' "$min" "$max" "${def:-$max}"
}

# mac_deployment_target_effective <requested> <min> <max> [<default>]  --  print
# the value to build with.
#
# Pure: no messages and no toolchain, so the self-test drives it with a
# fabricated range. Clamped rather than rejected, because the alternatives are a
# documented nearby value and no build at all: below the SDK's floor Xcode
# refuses to build, and above its ceiling there is no SDK for the newer system.
# Clamping up drops support for older macOS, which is not a decision to take
# quietly -- the caller prints mac_deployment_target_note, and both callers
# resolve the same way, so the libraries and the app cannot disagree.
mac_deployment_target_effective() {
  local want=$1 min=$2 max=$3 def=${4:-$3}
  if [ -n "$min" ] && [ "$(version_cmp "$want" "$min")" = "-1" ]; then
    printf '%s' "$min"
    return 0
  fi
  if [ -n "$max" ] && [ "$(version_cmp "$want" "$max")" = "1" ]; then
    # Above the ceiling. The SDK's default is its own version (26.5 for the 26.5
    # SDK) -- what an unset deployment target means anyway -- and max is that
    # version's ".99" spelling, which Xcode allows but which reads oddly in the
    # binary's LC_BUILD_VERSION.
    [ "$(version_cmp "$def" "$max")" = "1" ] && def=$max
    printf '%s' "$def"
    return 0
  fi
  printf '%s' "$want"
}

# mac_deployment_target_note <requested> <effective> <min> <max>  --  the why.
#
# Called wherever the target is resolved, so apply-overlay (which writes it into
# prepare.py for the libraries) and build-desktop (which passes it to cmake for
# the app) explain a version change in the same words.
mac_deployment_target_note() {
  local want=$1 got=$2 min=$3 max=$4
  [ "$want" = "$got" ] && return 0
  printf 'the macOS deployment target %s is not one this Xcode can build for.\n' "$want"
  printf '  supported range here: %s to %s\n' "$min" "$max"
  printf '  building with %s instead.\n' "$got"
  if [ "$(version_cmp "$got" "$want")" = "1" ]; then
    printf '  That drops support for macOS older than %s: this SDK has no lower\n' "$got"
    printf '  floor, so no build can keep %s.\n' "$want"
  else
    printf '  No SDK here can target anything newer than %s; upgrade Xcode for that.\n' "$max"
  fi
  printf '  To choose a different value: FREECHAT_MACOS_DEPLOYMENT_TARGET in freechat.env\n'
}

# mac_require_xcode  --  full Xcode, or an explanation and a non-zero return.
#
# Full Xcode and not the command line tools: prepare builds Qt with xcodebuild,
# and the app links against the SDK's static libraries. `xcodebuild -version` is
# the test because it is the capability that matters -- on a CLT-only machine the
# command exists and exits non-zero with "requires Xcode".
#
# Deliberately does NOT run `sudo xcode-select -s`, which is what upstream's own
# flow does: it needs a password, so in any unattended run (CI, an agent, a
# terminal without a tty) it either hangs or fails, and a build that begins by
# asking for a password is one that cannot be automated at all. The command is
# printed instead; running it twice is harmless.
mac_require_xcode() {
  local dev
  xcodebuild -version >/dev/null 2>&1 && return 0
  dev="$(xcode-select -p 2>/dev/null || true)"
  printf 'error: full Xcode is required, not just the command line tools.\n' >&2
  printf '  xcode-select currently points at: %s\n' "${dev:-<nothing>}" >&2
  printf '  Install Xcode, then select it:\n' >&2
  printf '    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer\n' >&2
  printf '  Run that yourself: this script never calls sudo, and that is on purpose --\n' >&2
  printf '  it needs a password, which turns an unattended run into a hang.\n' >&2
  return 1
}

# --- git tree completeness --------------------------------------------------

# _submodule_problems <repo>  --  one line per submodule that is not fully there.
_submodule_problems() {
  local repo=$1
  local line state rest path head_file
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # `git submodule status` output: <state><40-char sha> <path> (<describe>).
    state="${line:0:1}"
    rest="${line:42}"
    path="${rest%% (*}"
    case "$state" in
      -) printf 'not checked out: %s\n' "$path"; continue ;;
      +) printf 'commit differs from the pin: %s\n' "$path"; continue ;;
      U) printf 'unresolved merge: %s\n' "$path"; continue ;;
    esac
    # Initialized. status trusts the directory, so ask the worktree: a submodule
    # whose contents were deleted still reports as present, and the build then
    # fails hours later inside a header nobody deleted on purpose.
    # `git ls-files | head -1` instead of `sed -n 1p` would be killed by SIGPIPE
    # under `set -o pipefail` in the callers, and an empty answer here reads as
    # "this submodule has no files".
    head_file="$(git -C "$repo/$path" ls-files 2>/dev/null | sed -n 1p)"
    if [ -z "$head_file" ]; then
      printf 'no tracked files: %s\n' "$path"
    elif [ ! -e "$repo/$path/$head_file" ]; then
      printf 'files missing (e.g. %s): %s\n' "$head_file" "$path"
    fi
  done < <(git -C "$repo" submodule status --recursive 2>/dev/null)
}

# _submodule_restore_deleted <repo>  --  put back files missing from submodules.
#
# `git submodule update` compares COMMITS, not worktrees: for a submodule already
# at the recorded commit it does nothing at all. That is exactly the state after
# someone deletes files to free space -- the accident that emptied this project's
# Qt tree -- and the build then fails on a header nobody removed on purpose.
#
# Only files git reports as deleted are restored. `git checkout -- .` would also
# throw away real modifications, and there ARE real modifications inside
# submodules here: the overlay edits Telegram/SourceFiles, which lives in one.
_submodule_restore_deleted() {
  local repo=$1
  git -C "$repo" submodule foreach --quiet --recursive '
    deleted="$(git ls-files --deleted)"
    if [ -n "$deleted" ]; then
      printf "  restoring files deleted from submodule %s\n" "$sm_path" >&2
      printf "%s\n" "$deleted" | while IFS= read -r f; do
        [ -n "$f" ] && git checkout -- "$f"
      done
    fi
  ' || true
}

# verify_submodules <repo> [repair]  --  print the submodule count, or fail.
#
# `git submodule update` is idempotent -- it fetches what is missing and skips
# what is already there -- so running it again IS the repair for an interrupted
# download. What it does not do is say whether the tree ended up complete, and
# the failure mode is quiet: a clone killed halfway leaves a directory that
# exists and is empty, and the build fails hours later with a missing header.
# `git submodule status` is git's own answer (see _submodule_problems).
#
# With `repair` the update runs once when problems are found and the tree is
# re-checked; without it the tree is only reported on. Problems go to stderr, the
# number of submodules verified to stdout, and a non-zero return means the build
# should not start.
verify_submodules() {
  local repo=$1
  local action=${2:-check}
  local probs total
  [ -d "$repo" ] || return 0
  probs="$(_submodule_problems "$repo")"
  if [ -n "$probs" ] && [ "$action" = "repair" ]; then
    printf '  submodules are incomplete:\n%s' "$probs" >&2
    printf '  running git submodule update --init --recursive (git skips what is present)\n' >&2
    git -C "$repo" submodule update --init --recursive --depth 1 >&2 \
      || {
        printf '  git submodule update failed. A dropped network is the usual cause;\n' >&2
        printf '  re-run the same command, which resumes rather than restarting.\n' >&2
        return 1
      }
    # update() only handles submodules that are missing or at the wrong commit;
    # this handles the ones that are simply incomplete on disk.
    _submodule_restore_deleted "$repo"
    probs="$(_submodule_problems "$repo")"
  fi
  if [ -n "$probs" ]; then
    printf '  submodules are still incomplete after the check:\n%s' "$probs" >&2
    printf '  Repair: git -C %s submodule update --init --recursive\n' "$repo" >&2
    return 1
  fi
  total="$(git -C "$repo" submodule status --recursive 2>/dev/null | grep -c . || true)"
  printf '%s' "$total"
}

# --- prepared state ---------------------------------------------------------

# prepared_qt_dir <libraries-dir>  --  print the Qt install prepare.py built.
#
# The directory name carries upstream's Qt version (Qt-6.11.1), which comes from
# upstream's Telegram/build/qt_version.py and changes when upstream bumps it. So
# the check is for the thing the build needs -- a Qt6 cmake config inside a Qt-*
# directory -- rather than for a name this script would have to keep in sync.
prepared_qt_dir() {
  local libs=$1
  local d
  for d in "$libs"/local/Qt-*; do
    [ -d "$d" ] || continue
    [ -f "$d/lib/cmake/Qt6/Qt6Config.cmake" ] && { printf '%s' "$d"; return 0; }
  done
  return 1
}

# free_space_gb <path>  --  free space in whole GB, or nothing when unknown.
#
# POSIX df -Pk, because macOS, Linux and Git Bash agree on that one and not on
# the layout of the human-readable -h output.
free_space_gb() {
  df -Pk "$1" 2>/dev/null | awk 'NR==2 { printf "%d", $4 / 1048576 }'
}
