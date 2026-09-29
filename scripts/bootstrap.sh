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

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

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

# Parsed by content, not by position. The previous `ONLY="\${1:-all}"` read
# the FIRST argument as the target, so
#
#     ./scripts/bootstrap.sh --with-submodules
#
# -- which the README itself told you to run -- set the target to
# "--with-submodules", matched no component, fetched nothing and printed
# "done". A command that does nothing and reports success is the most
# expensive kind of failure: the next step fails somewhere else, naming
# something else.
ONLY=all
WITH_SUBMODULES=no
for arg in "$@"; do
  case "$arg" in
    --with-submodules) WITH_SUBMODULES=yes ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; die "unknown option: $arg" ;;
    *)
      if [[ "$arg" == all || " $TARGETS " == *" $arg "* ]]; then
        ONLY="$arg"
      else
        usage >&2
        die "unknown component: $arg (this repository has: $TARGETS)"
      fi ;;
  esac
done

wants() { [[ "$ONLY" == all || "$ONLY" == "$1" ]]; }
fetched=0

fetch_pinned() {
  local name=$1 dest=$2 pin=$3 submodules=$4
  # shellcheck disable=SC1090
  load_env_file "$pin" || die "cannot read $pin"
  [[ -n "${REPO:-}" && -n "${COMMIT:-}" ]] || die "$pin is missing REPO or COMMIT"
  # A full SHA, or the fetch below cannot work at all: a shallow fetch by commit
  # needs the complete 40-character id, because the remote will not resolve an
  # abbreviation. The desktop pin was once written as "d5a262f", and every fresh
  # machine then failed five times over ~30 seconds with "couldn't find remote
  # ref d5a262f" -- a message that points at the network, not at the pin.
  # scripts/sync-upstream.sh always writes the full id; this catches a hand edit.
  [[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "$pin: COMMIT=$COMMIT is not a full 40-character SHA.
      A shallow fetch cannot resolve an abbreviated commit on the remote.
      Write the full id (git rev-parse <short>), or bump with
      ./scripts/sync-upstream.sh, which always writes it in full."

  if [[ -d "$dest/.git" ]] && [[ "$(git -C "$dest" rev-parse HEAD 2>/dev/null)" == "$COMMIT" ]]; then
    log "$name already at ${COMMIT:0:12} — skipping"
    return
  fi

  log "$name: fetching ${COMMIT:0:12} from $REPO"
  # The checkout path must be a directory or absent. This was once a real
  # collision: the pin file was named UPSTREAM and the checkout upstream/, which
  # on a case-insensitive filesystem -- the default on macOS (APFS) and Windows
  # (NTFS) -- are the same path. mkdir then failed with a bare "File exists",
  # and deleting "upstream" to clear it deleted the pin. The pin is now
  # upstream.pin; this names the problem if anything else ever sits there.
  if [[ -e "$dest" && ! -d "$dest" ]]; then
    die "$dest exists and is not a directory, so the upstream cannot be checked out there.
      On macOS and Windows file names are case-insensitive by default: a file
      called ${dest##*/} in any capitalisation occupies this path. Move it aside."
  fi
  mkdir -p "$dest"

  # Test for $dest/.git directly, NOT `git rev-parse --git-dir`: rev-parse walks
  # UP the tree, so inside this repo it finds FreeChat's own .git, reports
  # success, and skips the init. Every `git -C "$dest"` below would then act on
  # the FreeChat repository -- repointing its origin at the upstream and
  # checking that upstream out over the working tree, destroying it. That is not
  # hypothetical; it happened.
  [[ -d "$dest/.git" ]] || git -C "$dest" init -q

  # Belt and braces for the same class of mistake: refuse to continue unless the
  # git directory we are about to write to really is $dest's own.
  local gitdir
  gitdir="$(cd "$dest" && git rev-parse --absolute-git-dir 2>/dev/null)" || true
  # Compared as FILES (-ef: same device and inode), never as strings. A string
  # compare broke on a Mac: entered as /Users/mor/desktop/..., git answered with
  # the on-disk spelling /Users/mor/Desktop/... -- the same directory on a
  # case-insensitive filesystem, a different string -- and this refused a
  # perfectly good checkout. Symlinked paths differ the same way (/tmp is
  # /private/tmp on macOS). The protection is unchanged: if rev-parse walked up
  # to an enclosing repository, its .git is a different file and this refuses.
  [[ -n "$gitdir" && "$gitdir" -ef "$dest/.git" ]] \
    || die "$dest is not its own git repository (git dir resolved to '${gitdir:-none}').
      Refusing to run: this would rewrite the enclosing repository."

  git -C "$dest" remote get-url origin >/dev/null 2>&1 \
    && git -C "$dest" remote set-url origin "$REPO" \
    || git -C "$dest" remote add origin "$REPO"

  # Retry: a cold 1.3GB fetch over a flaky link is the normal failure here.
  local try delay=2
  for try in 1 2 3 4 5; do
    if git -C "$dest" fetch --depth 1 --no-tags origin "$COMMIT"; then break; fi
    [[ $try -eq 5 ]] && die "$name: fetch failed after 5 attempts"
    log "$name: fetch attempt $try failed; retrying in ${delay}s"
    sleep "$delay"; delay=$(( delay * 2 ))
  done

  git -C "$dest" checkout -q --force FETCH_HEAD
  if [[ "$submodules" == "yes" ]]; then
    log "$name: submodules (this is the slow part)"
    git -C "$dest" submodule update --init --recursive --depth 1
  fi
  log "$name: at $(git -C "$dest" rev-parse --short HEAD)"
}

# Desktop submodules are opt-in: the 36 of them plus
# Telegram/build/prepare/*.sh are tens of GB, and the overlay only needs the
# source tree. Pass --with-submodules when you are actually going to build.
if wants desktop; then
  fetch_pinned "desktop" "$ROOT/desktop/upstream" "$ROOT/desktop/upstream.pin" "$WITH_SUBMODULES"
  fetched=$((fetched + 1))
fi

# Belt and braces for the bug described at the argument parser: whatever the
# arguments were, doing nothing is never success.
(( fetched > 0 )) || die "nothing was fetched for '$ONLY' (this repository has: $TARGETS)"

log "done. next: ./scripts/apply-overlay.sh"
