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
  # Deliberately unquoted: $PY may be "py -3", which has to split into two words.
  # shellcheck disable=SC2086
  $PY "$@"
}

resolve_python || true
