#!/usr/bin/env bash
# Move an upstream pin forward and report honestly whether the overlay survived.
#
# Usage: sync-upstream.sh server|android|desktop [<commit-ish>]
#
# It does NOT silently fix a broken hook. If an anchor moved, apply-overlay.sh
# fails loudly and you read docs/07-UPSTREAM-SYNC.md. That is the design: a
# guessed hook against MTProto plumbing is worse than a failed build.
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

# The components this repository holds. A split repository holds one, and then
# the component argument may be omitted.
TARGETS="desktop"
USAGE="usage: sync-upstream.sh ${TARGETS// /|} [commit-ish]"

WHICH="${1:-}"
if [[ -z "$WHICH" ]]; then
  if [[ "$TARGETS" != *" "* ]]; then
    WHICH="$TARGETS"
  else
    echo "$USAGE" >&2; exit 2
  fi
fi
if [[ " $TARGETS " != *" $WHICH "* ]]; then
  echo "unknown component: $WHICH (this repository has: $TARGETS)" >&2
  echo "$USAGE" >&2
  exit 2
fi
TARGET="${2:-}"
PIN="$ROOT/$WHICH/upstream.pin"
DEST="$ROOT/$WHICH/upstream"

# log, warn and die come from lib/portable.sh, so every script's progress lines
# carry the time and look the same.

# shellcheck disable=SC1090
load_env_file "$PIN" || die "cannot read $PIN"
OLD="$COMMIT"

[[ -d "$DEST/.git" ]] || die "$DEST not bootstrapped"
log "current pin: ${OLD:0:12}"

REF="${TARGET:-$BRANCH}"
log "fetching $REF from $REPO"
git -C "$DEST" fetch --depth 1 --no-tags origin "$REF"
NEW="$(git -C "$DEST" rev-parse FETCH_HEAD)"

if [[ "$NEW" == "$OLD" ]]; then
  log "already current — nothing to do"
  exit 0
fi
log "new commit: ${NEW:0:12}"

git -C "$DEST" checkout -q --force FETCH_HEAD
# android needs its submodules to build; desktop's are tens of GB and the
# overlay does not need them, so they stay out unless you fetch them yourself.
# `|| true` is not decoration: under `set -e` an AND-list whose test fails is
# exempt only because the test is not the list's last command, and relying on
# that subtlety in a script that gates upstream bumps is not worth the doubt.
if [[ "$WHICH" == android ]]; then
  git -C "$DEST" submodule update --init --recursive --depth 1
fi

log "re-applying overlay onto the new tree"
if ! "$ROOT/scripts/apply-overlay.sh" "$WHICH"; then
  cat >&2 <<EOF

  The overlay does not apply to ${NEW:0:12}. The pin in $PIN is UNCHANGED, so
  your build still works: re-run ./scripts/bootstrap.sh $WHICH to go back.
  Fix the anchor, then re-run this script. docs/07-UPSTREAM-SYNC.md.
EOF
  exit 1
fi

if [[ "$WHICH" == server ]]; then
  log "build + overlay tests"
  ( cd "$DEST" && go build -o /dev/null ./cmd/telesrv \
      && go test ./internal/app/help/ ./internal/mtprotoedge/ -count=1 ) \
    || die "new upstream builds or tests broken; pin left at ${OLD:0:12}"
fi

log "updating the pin"
py_run - "$PIN" "$NEW" <<'PY'
import re, sys
path, new = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
text = re.sub(r"^COMMIT=.*$", f"COMMIT={new}", text, count=1, flags=re.M)
open(path, "w", encoding="utf-8").write(text)
PY
log "pinned to ${NEW:0:12} — commit $PIN"
