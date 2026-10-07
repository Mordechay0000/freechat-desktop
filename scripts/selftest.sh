#!/usr/bin/env bash
# Regression tests for the scripts themselves. No network: the "upstream" is a
# throwaway local repository.
#
# These exist because of one specific failure. bootstrap.sh used
# `git rev-parse --git-dir` to decide whether server/upstream was already a
# repository. rev-parse walks UP, so inside a FreeChat checkout it found
# FreeChat's own .git, skipped the init, then repointed FreeChat's origin at the
# upstream and checked that upstream out over the working tree. It destroyed a
# real deployment. The invariant below is cheap and would have caught it.
set -uo pipefail

# Cross-platform helpers (sha256, timeout, stat, OS detection). Linux, macOS and
# Windows-under-Git-Bash disagree on commands these scripts rely on, and a
# missing one is not a degraded result -- it is a script that stops.
# shellcheck source=lib/portable.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/portable.sh"


ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { printf '  \033[1;32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad() { printf '  \033[1;31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }

printf '\033[1mFreeChat script self-test\033[0m\n\n'

# Which components this checkout holds. The monorepo holds three; each split
# repository holds one, and this test ships to and runs in all four. It used to
# be hardwired to the server -- it wrote server/UPSTREAM, ran `bootstrap.sh
# server` and read the server's Go sources -- so in the android and desktop
# repositories it failed on every run, and nobody knew, because it had only ever
# been run in the monorepo.
COMPONENTS="$(sed -n 's/^TARGETS="\(.*\)"$/\1/p' "$ROOT/scripts/bootstrap.sh")"
if [[ -z "$COMPONENTS" ]]; then
  printf 'selftest: cannot read TARGETS from scripts/bootstrap.sh\n' >&2
  exit 1
fi
FIRST="${COMPONENTS%% *}"
has() { [[ " $COMPONENTS " == *" $1 "* ]]; }
# Which bash and which host, printed rather than assumed. macOS's /bin/bash is
# 3.2 (frozen by Apple at the last GPLv2 release), and `#!/usr/bin/env bash`
# lands on it unless Homebrew's bash is earlier on PATH -- so the version that
# ran these checks is part of what they prove.
printf '  components: %s\n  bash %s on %s\n\n' "$COMPONENTS" "$BASH_VERSION" "$(host_os)"

# --- no two paths collide on a case-insensitive filesystem ------------------
# macOS (APFS) and Windows (NTFS) ignore case by default, and Linux does not,
# so a collision is invisible where this project was developed. It was real:
# the pin file was named UPSTREAM and the checkout directory upstream/, the same
# path on a Mac. bootstrap then failed with a bare "mkdir: File exists", and
# removing "upstream" to clear it deleted the pin. Checked over the tracked
# files PLUS the paths the scripts create, because the collision was between
# one of each.
case_clash="$(
  { git -C "$ROOT" ls-files 2>/dev/null
    for c in $COMPONENTS; do printf '%s/upstream\n' "$c"; done
    printf 'out\nfreechat.env\n'
  } | awk '{ k = tolower($0); if (k in seen && seen[k] != $0) print seen[k] " <-> " $0; else seen[k] = $0 }'
)"
if [[ -z "$case_clash" ]]; then
  ok "no paths collide on case-insensitive filesystems (macOS, Windows)"
else
  bad "paths that are the SAME path on macOS/Windows: $case_clash"
fi

# --- nothing generated is tracked -------------------------------------------
# Python bytecode landed in two repositories because `git add -A` collected the
# __pycache__ that py_compile wrote while a script was being syntax-checked. A
# .pyc is not source, differs per interpreter version, and is noise in every
# later diff. .gitignore alone is not enough -- it does not stop a file that is
# already tracked -- so the tracked set is checked directly.
litter="$(git -C "$ROOT" ls-files 2>/dev/null | grep -E '(^|/)__pycache__/|\.pyc$|\.DS_Store$|(^|/)Thumbs\.db$|\.log$|\.orig$|\.rej$' || true)"
if [[ -z "$litter" ]]; then
  ok "no generated or editor files are tracked"
else
  bad "tracked files that should not be:$(printf ' %s' $litter)"
fi

# --- every pin is a full SHA ------------------------------------------------
# The desktop pin once read COMMIT=d5a262f. A shallow fetch by commit needs the
# full id, so no fresh machine could bootstrap the desktop client at all -- and
# the fake upstream below uses a full SHA, so the rest of this test could never
# notice. Checked against the real pin files, not the fake.
short_pins=""
for c in $COMPONENTS; do
  pin_commit="$(sed -n 's/^COMMIT=//p' "$ROOT/$c/upstream.pin" 2>/dev/null | tr -d '\r' | tail -1)"
  [[ "$pin_commit" =~ ^[0-9a-f]{40}$ ]] || short_pins="$short_pins $c=${pin_commit:-<missing>}"
done
if [[ -z "$short_pins" ]]; then
  ok "every upstream pin is a full 40-character SHA"
else
  bad "pins a shallow fetch cannot resolve:$short_pins"
fi

# --- a fake upstream to fetch, so the test needs no network ------------------
fake="$TMP/fake-upstream"
git init -q "$fake"
echo "upstream marker" > "$fake/UPSTREAM_MARKER"
git -C "$fake" add -A
git -C "$fake" -c user.email=t@t -c user.name=t commit -q -m init
fake_sha="$(git -C "$fake" rev-parse HEAD)"

# --- a FreeChat checkout with the pin redirected at the fake ----------------
work="$TMP/freechat"
git clone -q --no-hardlinks "$ROOT" "$work"
# Test the scripts as they are ON DISK, not as last committed -- otherwise this
# silently checks an older version and passes while the working tree is broken.
cp -a "$ROOT/scripts/." "$work/scripts/"
origin_before="$(git -C "$work" remote get-url origin)"
# Every component's pin, not just the first: the argument tests below run
# bootstrap with no component, which fetches all of them, and a pin left pointing
# at GitHub would pull gigabytes into a unit test.
for c in $COMPONENTS; do
  cat > "$work/$c/upstream.pin" <<PIN
REPO=$fake
COMMIT=$fake_sha
BRANCH=master
PIN
done

( cd "$work" && ./scripts/bootstrap.sh "$FIRST" ) >"$TMP/out" 2>&1 || bad "bootstrap.sh exited non-zero"

# --- the invariant that matters --------------------------------------------
if [[ "$(git -C "$work" remote get-url origin)" == "$origin_before" ]]; then
  ok "bootstrap leaves the enclosing repo's origin alone"
else
  bad "bootstrap REWROTE the enclosing repo's origin -> $(git -C "$work" remote get-url origin)"
fi

if [[ -f "$work/UPSTREAM_MARKER" ]]; then
  bad "bootstrap checked the upstream out over the enclosing working tree"
else
  ok "bootstrap does not overwrite the enclosing working tree"
fi

for f in README.md scripts/apply-overlay.sh freechat.env.example; do
  [[ -f "$work/$f" ]] && ok "survived: $f" || bad "MISSING after bootstrap: $f"
done

if [[ -f "$work/$FIRST/upstream/UPSTREAM_MARKER" ]]; then
  ok "upstream landed in $FIRST/upstream"
else
  bad "upstream content not in $FIRST/upstream"
fi

gitdir="$(cd "$work/$FIRST/upstream" 2>/dev/null && git rev-parse --absolute-git-dir 2>/dev/null)"
# -ef, not ==: on macOS mktemp lives under /var/folders, a symlink to
# /private/var, so git's answer and this path are different strings for the
# same directory and a string compare failed on every Mac.
if [[ -n "$gitdir" && "$gitdir" -ef "$work/$FIRST/upstream/.git" ]]; then
  ok "$FIRST/upstream is its own repository"
else
  bad "$FIRST/upstream git dir is '$gitdir', expected its own .git"
fi

# --- idempotency -----------------------------------------------------------
if ( cd "$work" && ./scripts/bootstrap.sh "$FIRST" ) >"$TMP/out2" 2>&1 \
   && grep -q "already at" "$TMP/out2"; then
  ok "second bootstrap run is a no-op"
else
  bad "second bootstrap run did not detect the existing checkout"
fi

# Entered through a path spelled differently from the on-disk one. On a Mac,
# `cd /Users/me/desktop/...` works although the folder is Desktop, and git
# reports the on-disk spelling; the git-dir guard compared the two as strings
# and refused a correct checkout. A symlink produces the same mismatch on any
# system (and is itself real on macOS: /tmp is /private/tmp), so it stands in
# for the case-insensitive filesystem this machine does not have.
rm -rf "$work/$FIRST/upstream"
ln -s "$work" "$TMP/alias"
if ( cd "$TMP/alias" && ./scripts/bootstrap.sh "$FIRST" ) >"$TMP/out_alias" 2>&1; then
  ok "bootstrap works through a path spelled unlike the on-disk one"
else
  bad "bootstrap refused a path that differs only in spelling: $(tail -1 "$TMP/out_alias")"
fi

# Stale .git metadata in the upstream checkout: a .git that git does not
# recognise (an interrupted init, a half-deleted directory), so rev-parse walks
# up to THIS repository. bootstrap removes only that entry and re-initialises.
# Checked both ways: the fetch succeeds, and the enclosing repository is exactly
# as it was -- the property the first version of this script once violated.
rm -rf "$work/$FIRST/upstream"
mkdir -p "$work/$FIRST/upstream/.git"
outer_head="$(git -C "$work" rev-parse HEAD)"; outer_origin="$(git -C "$work" remote get-url origin)"
if ( cd "$work" && ./scripts/bootstrap.sh "$FIRST" ) >"$TMP/out_stale" 2>&1 \
   && [[ -f "$work/$FIRST/upstream/UPSTREAM_MARKER" ]] \
   && [[ "$(git -C "$work" rev-parse HEAD)" == "$outer_head" ]] \
   && [[ "$(git -C "$work" remote get-url origin)" == "$outer_origin" ]]; then
  ok "stale .git in the upstream is replaced; the enclosing repo is untouched"
else
  bad "stale .git recovery: $(tail -1 "$TMP/out_stale")"
fi

# --with-submodules on a checkout that already exists. The "already at the
# pinned commit" early return skipped submodules entirely, so the second of
#   ./scripts/bootstrap.sh
#   ./scripts/bootstrap.sh --with-submodules
# fetched nothing and printed "done" -- while build-desktop.sh, finding them
# missing, told you to run exactly that. Needs a fake upstream WITH a
# submodule; file:// submodules are blocked by default since git 2.38, so this
# test (only) allows them.
if ! has server || [[ "$FIRST" != server ]]; then
  sub_src="$TMP/fake-sub"; with_sub="$TMP/fake-with-sub"
  git init -q "$sub_src" && echo sub > "$sub_src/SUB_MARKER"
  git -C "$sub_src" add -A && git -C "$sub_src" -c user.email=t@t -c user.name=t commit -q -m sub
  git clone -q "$fake" "$with_sub"
  git -C "$with_sub" -c protocol.file.allow=always submodule add -q "$sub_src" sub >/dev/null 2>&1
  git -C "$with_sub" -c user.email=t@t -c user.name=t commit -q -m "add submodule"
  printf 'REPO=%s\nCOMMIT=%s\nBRANCH=master\n' "$with_sub" "$(git -C "$with_sub" rev-parse HEAD)" \
    > "$work/$FIRST/upstream.pin"
  rm -rf "$work/$FIRST/upstream"
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
  ( cd "$work" && ./scripts/bootstrap.sh "$FIRST" ) >/dev/null 2>&1
  # Remove whatever the first run fetched, so only the second can provide it.
  git -C "$work/$FIRST/upstream" submodule deinit -q -f --all >/dev/null 2>&1
  ( cd "$work" && ./scripts/bootstrap.sh "$FIRST" --with-submodules ) >"$TMP/out_sub" 2>&1
  unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
  if [[ -f "$work/$FIRST/upstream/sub/SUB_MARKER" ]]; then
    ok "--with-submodules fetches submodules on an existing checkout"
  else
    bad "--with-submodules on an existing checkout fetched no submodules: $(tail -1 "$TMP/out_sub")"
  fi
  # Leave the pin as the later checks expect it.
  printf 'REPO=%s\nCOMMIT=%s\nBRANCH=master\n' "$fake" "$fake_sha" > "$work/$FIRST/upstream.pin"
  rm -rf "$work/$FIRST/upstream"
  ( cd "$work" && ./scripts/bootstrap.sh "$FIRST" ) >/dev/null 2>&1
fi

# --- arguments: any order, validated, never a silent no-op -----------------
# The real failure: `./scripts/bootstrap.sh --with-submodules`, exactly as the
# desktop README said to run it, read the flag as the component name, fetched
# nothing and printed "done". The next step then failed with "desktop upstream
# missing", pointing at a command that had just claimed success.
for c in $COMPONENTS; do rm -rf "$work/$c/upstream"; done
( cd "$work" && ./scripts/bootstrap.sh --with-submodules ) >"$TMP/out3" 2>&1
flag_rc=$?
flag_missing=""
for c in $COMPONENTS; do
  [[ -f "$work/$c/upstream/UPSTREAM_MARKER" ]] || flag_missing="$flag_missing $c"
done
if [[ "$flag_rc" == 0 && -z "$flag_missing" ]]; then
  ok "bootstrap.sh --with-submodules (flag first, no component) fetches everything"
else
  bad "bootstrap.sh --with-submodules: rc=$flag_rc, not fetched:${flag_missing:- (none)}"
fi

refused=1
for args in "bogus" "--bogus"; do
  # shellcheck disable=SC2086
  if ( cd "$work" && ./scripts/bootstrap.sh $args ) >/dev/null 2>&1; then
    refused=0; bad "bootstrap.sh accepted '$args'"
  fi
done
if ( cd "$work" && ./scripts/apply-overlay.sh bogus ) >/dev/null 2>&1; then
  refused=0; bad "apply-overlay.sh accepted 'bogus'"
fi
# In a split repository, the components it does NOT hold must be refused by
# name. Before, they matched no dispatch line and printed "done".
for c in server android desktop; do
  has "$c" && continue
  if ( cd "$work" && ./scripts/bootstrap.sh "$c" ) >/dev/null 2>&1; then
    refused=0; bad "bootstrap.sh accepted '$c', which this repository does not hold"
  fi
  if ( cd "$work" && ./scripts/apply-overlay.sh "$c" ) >/dev/null 2>&1; then
    refused=0; bad "apply-overlay.sh accepted '$c', which this repository does not hold"
  fi
done
[[ "$refused" == 1 ]] && ok "unknown arguments and absent components are refused, not ignored"

# --- hook.py: the anchor-inside-replacement case --------------------------
probe="$TMP/probe.txt"
printf 'a\n// marker\nb\n' > "$probe"
py_run "$ROOT/scripts/lib/hook.py" "$probe" '// marker' 'CALL();
// marker' >/dev/null 2>&1 || bad "hook.py failed to apply"
if py_run "$ROOT/scripts/lib/hook.py" "$probe" '// marker' 'CALL();
// marker' 2>&1 | grep -q "already hooked"; then
  ok "hook.py is idempotent when the replacement contains its anchor"
else
  bad "hook.py does not recognise its own applied state"
fi
if [[ "$(grep -c 'CALL();' "$probe")" == "1" ]]; then
  ok "hook.py applied exactly once"
else
  bad "hook.py applied $(grep -c 'CALL();' "$probe") times"
fi

# --- every script can find the libraries it sources ------------------------
# Each script sources lib/load_env.sh and lib/portable.sh near the top, so a
# missing library is not a subtle degradation: the script dies on line 20 with a
# "No such file" that names a path the reader did not write. The split
# repositories get their scripts copied file by file, so this is exactly the kind
# of thing that goes missing when a script is added.
missing_lib=""
for f in "$ROOT"/scripts/*.sh; do
  # Not this file. It names libraries only to test them, and only when they
  # exist (gen_server_env.py is checked in the server repository alone); the
  # two it actually sources would fail it on line 20, loudly, if missing.
  [[ "$(basename "$f")" == selftest.sh ]] && continue
  while read -r libref; do
    [[ -n "$libref" ]] || continue
    [[ -f "$ROOT/scripts/lib/$libref" ]] || missing_lib="$missing_lib $(basename "$f"):$libref"
  done < <(grep -oE 'lib/[a-z_]+\.(sh|py)' "$f" 2>/dev/null | sed 's|^lib/||' | sort -u)
done
if [[ -z "$missing_lib" ]]; then
  ok "every library a script sources exists"
else
  bad "missing libraries:$missing_lib"
fi

# And the split must carry them, or the standalone repositories are broken in the
# same way. Checked against the copy list rather than by running the split, which
# takes minutes.
if [[ -f "$ROOT/scripts/split-repos.sh" ]]; then
  split_libs_ok=1
  for lib in load_env.sh portable.sh hook.py; do
    grep -q "lib/$lib" "$ROOT/scripts/split-repos.sh" || { split_libs_ok=0; break; }
  done
  if [[ "$split_libs_ok" == 1 ]]; then
    ok "split-repos.sh ships every shared library"
  else
    bad "split-repos.sh does not copy lib/$lib — the split repositories will fail on it"
  fi
fi

# --- Windows: line endings and PowerShell encoding --------------------------
# Git for Windows defaults to core.autocrlf=true. Without .gitattributes pinning
# scripts to LF, a Windows clone gets CRLF and bash fails on line 1 of every
# script ("set: pipefail\r: invalid option name"). Checked through git itself --
# check-attr reports the rule that will actually apply at checkout.
if [[ -f "$ROOT/.gitattributes" ]] \
   && [[ "$(git -C "$ROOT" check-attr eol -- scripts/bootstrap.sh 2>/dev/null)" == *": eol: lf" ]] \
   && [[ "$(git -C "$ROOT" check-attr eol -- freechat.env.example 2>/dev/null)" == *": eol: lf" ]]; then
  ok ".gitattributes pins scripts and config to LF (Windows checkouts stay runnable)"
else
  bad ".gitattributes missing or not forcing LF on *.sh -- every script breaks on Windows"
fi

# Windows PowerShell 5.1 reads a UTF-8 file without a BOM as Windows-1252. An em
# dash is E2 80 94 in UTF-8, and 0x94 in 1252 is a right double quotation mark,
# which PowerShell accepts AS A QUOTE -- one typographic dash in a comment can
# end a string early and break the parse. Pure ASCII sidesteps encoding entirely.
nonascii=""
for f in "$ROOT"/scripts/*.ps1; do
  [[ -f "$f" ]] || continue
  # \r allowed: .gitattributes checks .ps1 out with CRLF on purpose.
  LC_ALL=C grep -q $'[^ -~\t\r]' "$f" && nonascii="$nonascii $(basename "$f")"
done
if [[ -z "$nonascii" ]]; then
  ok "PowerShell scripts are pure ASCII (safe under Windows PowerShell 5.1)"
else
  bad "non-ASCII in:$nonascii -- Windows PowerShell 5.1 may misparse it"
fi

# Parse every .ps1 with PowerShell's own parser when pwsh is available. Nothing
# else in this repository can check them: they run on Windows only, and for a
# long time build-desktop.ps1 had never been parsed by anything at all. Reported
# as NOT RUN rather than passed when pwsh is absent -- a skipped check must never
# read as a passing one.
if command -v pwsh >/dev/null 2>&1; then
  ps_errors="$(cd "$ROOT" && pwsh -NoProfile -NonInteractive -Command '
    $bad = @()
    foreach ($f in Get-ChildItem -Path scripts -Filter *.ps1) {
      $t = $null; $e = $null
      [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e)
      foreach ($x in $e) { $bad += "$($f.Name):$($x.Extent.StartLineNumber) $($x.Message)" }
    }
    $bad -join "; "' 2>&1)"
  if [[ -z "$ps_errors" ]]; then
    ok "PowerShell scripts parse with pwsh $(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null)"
  else
    bad "PowerShell parse errors: $ps_errors"
  fi
else
  printf '  \033[1;33m-\033[0m PowerShell parse NOT RUN (pwsh not installed)\n'
fi

# --- configuration files are parsed, never executed ------------------------
# This bug was fixed once and came back. `set -a; . file; set +a` runs the file
# as a shell script, so a value with a space in it is not a value:
#
#   FREECHAT_SERVER_DESCRIPTION=Private node
#
# means "set ...=Private for one command, then run the command node" -- a REPL
# waiting on stdin. server-up.sh hit it through freechat.vars; apply-overlay.sh
# hit it again later through the same line in brand.env, because the fix was
# applied to one script instead of to the idiom. Whether it hangs depends on what
# stdin happens to be, so it passes when tested with </dev/null and blocks in
# real use. Nothing but a check across all the scripts keeps it gone.
# Comment lines are skipped. server-up.sh names the idiom in a comment
# explaining why it is banned, which a naive grep flags -- and a check that
# cannot tell a warning from a violation gets ignored, which is worse than not
# having it.
sourcing=""
for f in "$ROOT"/scripts/*.sh; do
  [[ "$(basename "$f")" == selftest.sh ]] && continue
  if grep -vE '^[[:space:]]*#' "$f" | grep -q 'set -a;[[:space:]]*\.'; then
    sourcing="$sourcing $(basename "$f")"
  fi
done
if [[ -z "$sourcing" ]]; then
  ok "no script sources a configuration file"
else
  bad "these source a config file instead of parsing it:$sourcing"
fi

# And the parser must actually refuse the line rather than run it. A bare `node`
# in the file is the exact shape that hung: if this test ever hangs instead of
# failing, the parser has regressed into executing its input.
env_probe="$TMP/probe.env"
printf 'DESC=Private node\nQUOTED="two words"\nnode\n' > "$env_probe"
probe_out="$(with_timeout 10 bash -c '
  . "'"$ROOT"'/scripts/lib/load_env.sh"
  load_env_file "'"$env_probe"'" 2>/dev/null
  printf "%s|%s" "$DESC" "$QUOTED"' 2>/dev/null)"
probe_rc=$?
if [[ "$probe_rc" == 124 ]]; then
  bad "load_env.sh HUNG on a config file containing a bare command -- it is executing its input"
elif [[ "$probe_out" == "Private node|two words" ]]; then
  ok "load_env.sh keeps spaced values whole and does not run a stray command"
else
  bad "load_env.sh parsed wrongly: got '$probe_out' (rc=$probe_rc)"
fi

# The value rules, and layering, on the lines that actually broke. One vector,
# and in the server repository also checked against the Python reader of the
# same files, because four parsers of one format drifted apart once already:
#   KEY=9090 # port        inline comment -- was kept IN the value
#   KEY=  'a b'            quotes after spaces -- bash kept the quotes
#   KEY="x # y"            # inside quotes is data
#   KEY=http://h/#f        # with no space before it is data
# plus a freechat.env that names only the port, which used to wipe every other
# key because it replaced the example instead of layering over it.
lay="$TMP/layer"; mkdir -p "$lay"
printf 'FREECHAT_SERVER_IP=10.0.0.1\nFREECHAT_SERVER_PORT=8080\n' > "$lay/freechat.env.example"
printf "FREECHAT_SERVER_PORT=9090 # port\nA=  'a b'  \nB=\"x # y\"\nC=http://h/#f\n" > "$lay/freechat.env"
lay_out="$(bash -c '. "'"$ROOT"'/scripts/lib/load_env.sh"; load_freechat_env "'"$lay"'" 2>/dev/null
  printf "%s|%s|%s|%s|%s" "$FREECHAT_SERVER_IP" "$FREECHAT_SERVER_PORT" "$A" "$B" "$C"' 2>/dev/null)"
lay_want="10.0.0.1|9090|a b|x # y|http://h/#f"
if [[ "$lay_out" == "$lay_want" ]]; then
  ok "config values: inline comments, quotes and layering behave like bash"
else
  bad "config parsing: got '$lay_out', want '$lay_want'"
fi
if [[ -f "$ROOT/scripts/lib/gen_server_env.py" ]]; then
  py_lay="$(cd "$ROOT/scripts/lib" && py_run -c "
import gen_server_env as g
d = {}
for n in ('freechat.env.example', 'freechat.env'):
    d.update(g.read_env('$lay/' + n))
print('|'.join(d.get(k, '') for k in ('FREECHAT_SERVER_IP', 'FREECHAT_SERVER_PORT', 'A', 'B', 'C')))" 2>&1)"
  if [[ "$py_lay" == "$lay_want" ]]; then
    ok "the Python reader agrees with load_env.sh on the same files"
  else
    bad "gen_server_env.py disagrees with load_env.sh: got '$py_lay', want '$lay_want'"
  fi
fi

if has server; then
# --- the discovery path has one definition ---------------------------------
# Added after the real thing happened: the Go constant was renamed to
# /freechat/server-info while deploy-check.sh, server-up.sh and
# install-service.sh kept the old literal. All three then probed a 404 and
# reported a hard failure against a server that was answering correctly --
# deploy-check said "GET ... failed" and install-service said "active but does
# not serve server-info", both pointing at a bug that did not exist. A literal
# duplicated across four files will go stale; the only fix that holds is for
# nobody but the constant to spell it.
const_path="$(sed -n 's/^const FreeChatServerInfoPath = "\(.*\)"$/\1/p' \
              "$ROOT/server/overlay/internal/mtprotoedge/freechat_server_info.go")"
if [[ -n "$const_path" ]]; then
  ok "FreeChatServerInfoPath reads as $const_path"
else
  bad "cannot parse FreeChatServerInfoPath -- every probe script depends on this"
fi

# Each probe script must DERIVE the path from the constant, and no line in it may
# contain a quoted URL ending in a hardcoded .../server-info.
#
# The first version of this check grepped the curl lines for "server-info" and
# demanded INFO_PATH nearby. That can never match: once the URL is built from a
# variable the word is not on the line at all, so the check flagged all three
# fixed scripts and would have flagged a broken one identically. A test whose
# pass and fail look the same measures nothing -- the same mistake as measuring
# a remote port from a network that blocks it.
derives=0; literals=""
for s in deploy-check.sh server-up.sh install-service.sh; do
  f="$ROOT/scripts/$s"
  grep -q 'FreeChatServerInfoPath = ' "$f" && derives=$((derives+1))
  # A hardcoded probe URL: a slash-delimited path literal immediately followed
  # by "/server-info" inside quotes. The := fallbacks are on their own lines and
  # are not URLs, so they do not match.
  grep -qE '"[^"]*http[^"]*/[a-z]+/server-info' "$f" && literals="$literals $s"
done
if [[ "$derives" == 3 ]]; then
  ok "all three probe scripts derive the path from FreeChatServerInfoPath"
else
  bad "only $derives/3 probe scripts derive the path from the constant"
fi
if [[ -z "$literals" ]]; then
  ok "no probe script hardcodes a server-info URL"
else
  bad "hardcoded server-info URL in:$literals"
fi
fi

# The old fork's path must survive in exactly three places: the purge rule that
# rewrites it, the prose explaining what owpengram-server shipped, and this file,
# which needs the literal as its own search pattern.
stale="$(grep -rln "/owpengram/server-info" "$ROOT/scripts" "$ROOT/docs" \
         "$ROOT/server/overlay" "$ROOT/android/overlay" "$ROOT/desktop/overlay" 2>/dev/null \
         | grep -vE 'purge_branding\.py$|00-WHY-NOT-TEAMGRAM\.md$|selftest\.sh$' || true)"
if [[ -z "$stale" ]]; then
  ok "the old fork's discovery path survives only where it must"
else
  bad "stale fork path in:$(printf ' %s' $stale)"
fi

# --- macOS deployment target: resolved, not trusted -------------------------
# The expensive failure this covers: Xcode refuses to build for a system its SDK
# does not support -- "the range of supported deployment target versions is 12.0
# to 27.0.99" -- and it says so only after prepare has spent half an hour on Qt.
# Which values are supported is a property of the installed SDK and it MOVES:
# this machine lost 12.0 and gained 10.13 in one day, when Xcode 27 beta was
# replaced by 26.6. So the value from freechat.env is resolved against the SDK's
# own SDKSettings.plist. The decision is a pure function, which is why it can be
# tested here with fabricated ranges -- on Linux and Windows too, with no Xcode.
vc="$(version_cmp 12.0 12) $(version_cmp 26.5.99 26.5) $(version_cmp 9.0 12.0) $(version_cmp 12.0 12.0.0)"
if [[ "$vc" == "0 1 -1 0" ]]; then
  ok "version_cmp compares components as numbers (12.0 == 12, 9.0 < 12.0)"
else
  bad "version_cmp: got '$vc', want '0 1 -1 0'"
fi

keep="$(mac_deployment_target_effective 12.0 12.0 27.0.99 27.0)"
up="$(mac_deployment_target_effective 10.13 12.0 27.0.99 27.0)"
down="$(mac_deployment_target_effective 30.0 12.0 27.0.99 27.0)"
if [[ "$keep" == "12.0" && "$up" == "12.0" && "$down" == "27.0" ]]; then
  ok "a target inside the SDK's range is kept; outside it, clamped to the range"
else
  bad "target resolution: in-range=$keep below-min=$up above-max=$down (want 12.0 12.0 27.0)"
fi

# The clamp is a version change in the shipped binary, so it must be explained
# rather than silent -- and a value that is fine must produce no noise at all.
note="$(mac_deployment_target_note 10.13 12.0 12.0 27.0.99 2>&1)"
quiet="$(mac_deployment_target_note 12.0 12.0 12.0 27.0.99 2>&1)"
if [[ "$note" == *"supported range here: 12.0 to 27.0.99"* && "$note" == *"building with 12.0 instead"* \
      && "$note" == *"drops support for macOS older than 12.0"* && -z "$quiet" ]]; then
  ok "an adapted target is explained, an unadapted one says nothing"
else
  bad "deployment target note: '$note' / quiet='$quiet'"
fi

# The SDK range comes from SDKSettings.plist, read with plutil -- the same file
# Xcode reads. Checked against a synthetic one, so the test does not depend on
# which Xcode is installed, and against the real SDK when there is one.
if [[ "$(host_os)" == mac ]] && command -v plutil >/dev/null 2>&1; then
  fake_sdk="$TMP/fake-sdk"; mkdir -p "$fake_sdk"
  cat > "$fake_sdk/SDKSettings.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>SupportedTargets</key><dict><key>macosx</key><dict>
    <key>MinimumDeploymentTarget</key><string>13.0</string>
    <key>MaximumDeploymentTarget</key><string>29.9.99</string>
    <key>DefaultDeploymentTarget</key><string>29.0</string>
  </dict></dict>
</dict></plist>
PLIST
  fake_range="$(mac_sdk_deployment_target_range "$fake_sdk")"
  if [[ "$fake_range" == "13.0 29.9.99 29.0" ]]; then
    ok "the SDK's supported target range is read from SDKSettings.plist"
  else
    bad "plist read: got '$fake_range', want '13.0 29.9.99 29.0'"
  fi

  # And the installed SDK: the rule, not a version. Whatever this Xcode supports,
  # the resolved default has to land inside the range it reports -- that is the
  # property the build depends on.
  if real_range="$(mac_sdk_deployment_target_range)"; then
    # shellcheck disable=SC2086
    set -- $real_range
    got="$(mac_deployment_target_effective 12.0 "$1" "$2" "${3:-$2}")"
    if [[ "$(version_cmp "$got" "$1")" != "-1" && "$(version_cmp "$got" "$2")" != "1" ]]; then
      ok "the installed SDK ($real_range) resolves the default target 12.0 to $got, inside it"
    else
      bad "resolved target $got is outside the installed SDK's range $1 to $2"
    fi
  else
    printf '  \033[1;33m-\033[0m installed SDK range NOT READ (no SDK plist on this machine)\n'
  fi
else
  printf '  \033[1;33m-\033[0m SDK plist checks NOT RUN (not macOS, or no plutil)\n'
fi

# --- prepared state: a half-installed Qt is not usable ----------------------
# The exact state that produced "Neither Qt6 nor Qt5 is found" with no mention
# of prepare: Libraries/local/Qt-6.11.1 present, holding one stray library and no
# cmake config. Identified by what the build needs -- a Qt6 cmake config -- not by
# the version in the directory name, which comes from upstream's qt_version.py.
libs="$TMP/libs"; mkdir -p "$libs/local/Qt-6.11.1/lib/cmake/Qt6"
touch "$libs/local/Qt-6.11.1/lib/cmake/Qt6/Qt6Config.cmake"
if [[ "$(prepared_qt_dir "$libs")" == "$libs/local/Qt-6.11.1" ]]; then
  ok "prepared_qt_dir finds a complete Qt install"
else
  bad "prepared_qt_dir missed a complete Qt install"
fi
rm "$libs/local/Qt-6.11.1/lib/cmake/Qt6/Qt6Config.cmake"
if prepared_qt_dir "$libs" >/dev/null 2>&1; then
  bad "prepared_qt_dir accepted a half-installed Qt (no Qt6Config.cmake)"
else
  ok "prepared_qt_dir rejects a half-installed Qt"
fi
if [[ -z "$(prepared_qt_dir "$TMP")" ]]; then
  ok "prepared_qt_dir finds nothing where nothing is prepared"
else
  bad "prepared_qt_dir invented a Qt install"
fi

# free_space_gb: the check that warns before a stage runs out of disk mid-way.
free_gb="$(free_space_gb "$TMP")"
if [[ "$free_gb" =~ ^[0-9]+$ ]] && (( free_gb > 0 )); then
  ok "free_space_gb reads the free space (${free_gb}GB)"
else
  bad "free_space_gb returned '$free_gb'"
fi

# --- submodules: a half-downloaded one is detected, and repaired -------------
# "git submodule update" is idempotent and skips what is present, so running it
# again is the repair. What it never reports is whether the result is complete --
# an interrupted clone leaves a directory that exists and is EMPTY, and the build
# fails hours later inside a missing header. Both halves are planted here the way
# they happen: files deleted from an initialized submodule, and the whole
# submodule directory gone.
sub_remote="$TMP/sub-remote"; sub_self="$TMP/sub-self"
mkdir -p "$sub_remote/src"
echo "sub content" > "$sub_remote/SUB_FILE"
echo "// header" > "$sub_remote/src/sub.h"
git init -q "$sub_remote"
git -C "$sub_remote" add -A
git -C "$sub_remote" -c user.email=t@t -c user.name=t commit -q -m sub
git init -q "$sub_self"
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
git -C "$sub_self" -c protocol.file.allow=always submodule add -q "$sub_remote" sub >/dev/null 2>&1
git -C "$sub_self" -c user.email=t@t -c user.name=t commit -q -m "add submodule"
git -C "$sub_self" submodule update --init --recursive >/dev/null 2>&1
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

if [[ "$(verify_submodules "$sub_self" check)" == "1" ]]; then
  ok "a complete submodule tree verifies, and says how many"
else
  bad "verify_submodules miscounted a complete tree"
fi
plain="$TMP/plain"; git init -q "$plain"
if [[ "$(verify_submodules "$plain" check)" == "0" ]]; then
  ok "a repository without submodules verifies as zero"
else
  bad "verify_submodules mishandled a repository with no submodules"
fi

# Initialized, metadata intact, contents deleted: git status calls this fine.
rm -rf "$sub_self/sub/SUB_FILE" "$sub_self/sub/src"
if verify_submodules "$sub_self" check >/dev/null 2>&1; then
  bad "a submodule with deleted files passed verification"
else
  ok "a submodule whose files were deleted is reported, not passed"
fi
if verify_submodules "$sub_self" repair >/dev/null 2>&1 && [[ -f "$sub_self/sub/src/sub.h" ]]; then
  ok "repair restores a submodule whose files were deleted"
else
  bad "repair did not restore the submodule's files"
fi

# The whole directory gone: git reports it as not initialized, and one run of
# update fetches it back (which is what re-running bootstrap does).
rm -rf "$sub_self/sub"
git -C "$sub_self" submodule deinit -q -f --all >/dev/null 2>&1
if verify_submodules "$sub_self" check >/dev/null 2>&1; then
  bad "a missing submodule passed verification"
else
  ok "a missing submodule is reported"
fi
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
if verify_submodules "$sub_self" repair >/dev/null 2>&1 && [[ -f "$sub_self/sub/SUB_FILE" ]]; then
  ok "repair fetches a submodule that is not checked out at all"
else
  bad "repair did not fetch the missing submodule"
fi
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

# --- idempotency of apply-overlay, per bootstrapped platform ---------------
# The rule this enforces: a second run must leave the tree exactly as the first
# did. Asserted by fingerprinting the applied tree -- tracked modifications and
# the full untracked file list -- before and after a re-apply. A stale overlay
# file, a double-applied hook or a half-reverted purge all change that
# fingerprint; none of them is visible by reading the script.
fingerprint() {
  local up=$1
  { git -C "$up" status --porcelain -- . | sort
    git -C "$up" ls-files --others --exclude-standard | sort
  } 2>/dev/null | sha256_of
}

for platform in server android desktop; do
  up="$ROOT/$platform/upstream"
  [[ -d "$up/.git" ]] || continue
  if ! "$ROOT/scripts/apply-overlay.sh" "$platform" >/dev/null 2>&1; then
    bad "apply-overlay.sh $platform failed"
    continue
  fi
  before="$(fingerprint "$up")"
  if ! "$ROOT/scripts/apply-overlay.sh" "$platform" >/dev/null 2>&1; then
    bad "apply-overlay.sh $platform failed on the second run"
    continue
  fi
  after="$(fingerprint "$up")"
  if [[ "$before" == "$after" ]]; then
    ok "apply-overlay.sh $platform is idempotent"
  else
    bad "apply-overlay.sh $platform changed the tree on a second run"
  fi

  # A stable fingerprint alone does NOT prove the reset works: hooks that
  # re-detect their own output and a copy that overwrites in place both give the
  # same tree twice while leaving anything a PREVIOUS version of the overlay
  # created sitting there forever. That is the case that matters, so plant a
  # leftover and require the next apply to remove it. A dotfile, so the server's
  # gofmt check cannot trip over it.
  case "$platform" in
    server)  sentinel="$up/internal/.freechat-stale-sentinel" ;;
    android) sentinel="$up/TMessagesProj/src/.freechat-stale-sentinel" ;;
    desktop) sentinel="$up/Telegram/SourceFiles/.freechat-stale-sentinel" ;;
  esac
  printf 'left over by an earlier overlay version\n' > "$sentinel"
  "$ROOT/scripts/apply-overlay.sh" "$platform" >/dev/null 2>&1 || true
  if [[ -e "$sentinel" ]]; then
    bad "apply-overlay.sh $platform left a stale file behind: ${sentinel#$up/}"
    rm -f "$sentinel"
  else
    ok "apply-overlay.sh $platform removes what earlier runs left"
  fi
done

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
