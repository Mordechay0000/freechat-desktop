#!/usr/bin/env bash
# Fetch each upstream at its pinned commit into <component>/upstream
# (gitignored).
#
#   ./scripts/bootstrap.sh [all|<component>] [--with-submodules]
#
# Arguments are accepted in any order.
#
# Deliberately not git submodules: a shallow submodule cannot be pinned to an
# arbitrary SHA, and a full one costs ~1.3GB of history nobody reads. GitHub
# serves uploadpack.allowReachableSHA1InWant, so `fetch --depth 1 <sha>` gets
# exactly the pinned tree and nothing else.
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

# log, warn and die come from lib/portable.sh, so that every script's progress
# lines carry the time and look the same. Nothing to define here.

# The components this repository holds. A split repository holds one.
TARGETS="desktop"

usage() {
  cat <<EOF
usage: ./scripts/bootstrap.sh [all|${TARGETS// /|}] [--with-submodules]

  Fetches each upstream at its pinned commit. Arguments may come in any order.

  --with-submodules   also fetch the desktop client's submodules -- needed to
                      BUILD it (tens of GB), not to apply the overlay.
EOF
}

# Parsed by content, not by position.
ONLY=all
WITH_SUBMODULES=no

for arg in "$@"; do
  case "$arg" in
    --with-submodules)
      WITH_SUBMODULES=yes
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      usage >&2
      die "unknown option: $arg"
      ;;
    *)
      if [[ "$arg" == all || " $TARGETS " == *" $arg "* ]]; then
        ONLY="$arg"
      else
        usage >&2
        die "unknown component: $arg (this repository has: $TARGETS)"
      fi
      ;;
  esac
done

wants() {
  [[ "$ONLY" == all || "$ONLY" == "$1" ]]
}

# Submodules are opt-in and enormous, and git's own update IS the repair: it
# fetches what is missing and skips what is already there, so an interrupted run
# is continued by running the same command again. What it does not report is
# whether the tree ended up complete -- a clone killed halfway leaves a directory
# that exists and is empty, and the build then fails hours later, inside a header
# nobody deleted on purpose -- so this asks git afterwards (verify_submodules in
# scripts/lib/portable.sh) and refuses to report success for a tree that is only
# part there.
fetch_submodules() {
  local name=$1 dest=$2 count
  log "$name: submodules (this is the slow part)"
  git -C "$dest" submodule update --init --recursive --depth 1 \
    || die "$name: submodule update failed.
      Re-run this script: git resumes and skips the submodules it already has."
  if ! count="$(verify_submodules "$dest" check)"; then
    die "$name: the submodules listed above are not fully checked out.
      Re-run this script to continue -- git only fetches what is missing. If the
      same one keeps failing:
        git -C $dest submodule update --init --recursive"
  fi
  log "$name: $count submodules verified"
}

fetched=0

fetch_pinned() {
  local name=$1
  local dest=$2
  local pin=$3
  local submodules=$4

  # shellcheck disable=SC1090
  load_env_file "$pin" || die "cannot read $pin"

  [[ -n "${REPO:-}" && -n "${COMMIT:-}" ]] \
    || die "$pin is missing REPO or COMMIT"

  # A full SHA is required because a shallow fetch by commit needs the complete
  # 40-character id.
  [[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "$pin: COMMIT=$COMMIT is not a full 40-character SHA.
      A shallow fetch cannot resolve an abbreviated commit on the remote.
      Write the full id (git rev-parse <short>), or bump with
      ./scripts/sync-upstream.sh, which always writes it in full."

  # The checkout path must be a directory or absent.
  if [[ -e "$dest" && ! -d "$dest" ]]; then
    die "$dest exists and is not a directory, so the upstream cannot be checked out there.
      On macOS and Windows file names are case-insensitive by default: a file
      called ${dest##*/} in any capitalisation occupies this path. Move it aside."
  fi

  mkdir -p "$dest"

  # Ensure that $dest is an independent Git repository.
  #
  # IMPORTANT:
  # On macOS, paths can differ only in capitalization:
  #
  #   /Users/mor/Desktop/...
  #   /Users/mor/desktop/...
  #
  # They refer to the same filesystem object. Therefore we must NOT compare
  # Git paths as strings. `-ef` compares the actual filesystem objects.
  if [[ -e "$dest/.git" ]]; then
    local existing_gitdir expected_gitdir root_gitdir

    existing_gitdir="$(git -C "$dest" rev-parse --absolute-git-dir 2>/dev/null || true)"
    expected_gitdir="$(cd "$dest" && pwd)/.git"
    root_gitdir="$(git -C "$ROOT" rev-parse --absolute-git-dir 2>/dev/null || true)"

    # The Git directory belongs to $dest if both paths identify the same
    # filesystem object, even when their capitalization differs.
    if [[ -d "$existing_gitdir" && -d "$expected_gitdir" ]] &&
       [[ "$existing_gitdir" -ef "$expected_gitdir" ]]; then
      :
    elif [[ -n "$existing_gitdir" && -n "$root_gitdir" ]] &&
         [[ -d "$existing_gitdir" && -d "$root_gitdir" ]] &&
         [[ "$existing_gitdir" -ef "$root_gitdir" ]]; then

      # Git resolved to the enclosing FreeChat repository. This is the stale
      # metadata case. Remove only the incorrect .git entry from the upstream
      # checkout and create a real independent repository.
      log "$name: removing stale Git metadata from $dest"
      rm -rf "$dest/.git"
      git -C "$dest" init -q
    else
      die "$dest is not its own git repository
      (git dir resolved to '${existing_gitdir:-none}').
      Refusing to remove unexpected Git metadata."
    fi
  else
    git -C "$dest" init -q
  fi

  # Final safety check. Again use filesystem identity rather than string
  # comparison so macOS case-insensitive paths work correctly.
  local gitdir expected_gitdir_final
  gitdir="$(git -C "$dest" rev-parse --absolute-git-dir 2>/dev/null)" \
    || die "$dest is not a valid git repository"

  expected_gitdir_final="$(cd "$dest" && pwd)/.git"

  [[ -d "$gitdir" && -d "$expected_gitdir_final" ]] &&
  [[ "$gitdir" -ef "$expected_gitdir_final" ]] \
    || die "$dest is not its own git repository (git dir resolved to '$gitdir').
      Refusing to run: this would rewrite the enclosing repository."

  git -C "$dest" remote get-url origin >/dev/null 2>&1 \
    && git -C "$dest" remote set-url origin "$REPO" \
    || git -C "$dest" remote add origin "$REPO"

  # If the requested commit is already checked out, avoid another fetch --
  # but NOT the submodules. Being at the pinned commit says nothing about them,
  # and returning here unconditionally made `--with-submodules` on an existing
  # checkout fetch none of the desktop client's 36 submodules and print "done",
  # while build-desktop.sh told you to run exactly that. `submodule update` is a
  # no-op when they are already present.
  if [[ "$(git -C "$dest" rev-parse HEAD 2>/dev/null || true)" == "$COMMIT" ]]; then
    log "$name already at ${COMMIT:0:12}"
    if [[ "$submodules" == "yes" ]]; then
      fetch_submodules "$name" "$dest"
    fi
    return
  fi

  # Retry: a cold 1.3GB fetch over a flaky link is the normal failure here.
  local try
  local delay=2

  for try in 1 2 3 4 5; do
    if git -C "$dest" fetch --depth 1 --no-tags origin "$COMMIT"; then
      break
    fi

    [[ $try -eq 5 ]] && die "$name: fetch failed after 5 attempts"

    log "$name: fetch attempt $try failed; retrying in ${delay}s"
    sleep "$delay"
    delay=$(( delay * 2 ))
  done

  git -C "$dest" checkout -q --force FETCH_HEAD

  if [[ "$submodules" == "yes" ]]; then
    fetch_submodules "$name" "$dest"
  fi

  log "$name: at $(git -C "$dest" rev-parse --short HEAD)"
}

# Desktop submodules are opt-in: the 36 of them plus
# Telegram/build/prepare/*.sh are tens of GB, and the overlay only needs
# the source tree. Pass --with-submodules when you are actually going to build.
if wants desktop; then
  fetch_pinned \
    "desktop" \
    "$ROOT/desktop/upstream" \
    "$ROOT/desktop/upstream.pin" \
    "$WITH_SUBMODULES"

  fetched=$((fetched + 1))
fi

# Doing nothing is never success.
(( fetched > 0 )) || die "nothing was fetched for '$ONLY' (this repository has: $TARGETS)"

log "done. next: ./scripts/apply-overlay.sh"

