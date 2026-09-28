# Load a KEY=VALUE configuration file into the environment, WITHOUT executing it.
#
# Meant to be sourced by the scripts in this directory's parent:
#   . "$ROOT/scripts/lib/load_env.sh"
#   load_env_file "$ROOT/freechat.env"
#
# This exists because `set -a; . file; set +a` -- the obvious idiom, and what
# every script here used -- runs the file as a shell script. A value containing
# a space is then not a value at all:
#
#   FREECHAT_SERVER_DESCRIPTION=Private node
#
# bash reads that as "set FREECHAT_SERVER_DESCRIPTION=Private for one command,
# then run the command `node`". With node installed, that is a REPL waiting on
# stdin, and the script hangs forever with no output and no error. It happened
# twice in this project: once in server-up.sh, where a stray word in
# freechat.vars launched exactly that, and again in apply-overlay.sh after the
# first fix, because the idiom was copied rather than the lesson. The second time
# cost 13 minutes of a script appearing to work.
#
# Quoting the values would hide this particular case and leave the mechanism in
# place: a config file that is executed can always run something. Parsing is the
# fix, so there is one parser and no sourcing site left.
#
# Accepts:  KEY=value, KEY="value", KEY='value', blank lines, # comments,
#           leading whitespace, CRLF line endings.
# Ignores:  anything else, reported on stderr rather than run.

load_env_file() {
  local file=$1 line key value lineno=0 ignored=0
  if [[ ! -f "$file" ]]; then
    printf 'load_env_file: %s does not exist\n' "$file" >&2
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"                 # CRLF: a trailing CR ends up inside the
                                         # value and breaks numeric comparisons
                                         # in ways that read as a wrong value.
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "${line#"${line%%[![:space:]]*}"}" == \#* ]] && continue

    if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      # Whitespace off BOTH ends before looking for quotes, so KEY=  'a b'  is
      # quoted. Trimming only the left kept the quotes inside the value while the
      # Python and PowerShell readers of the same file dropped them -- the four
      # parsers disagreed on one line until they were tested side by side.
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
      # A matched pair of quotes: the inside, verbatim -- spaces and # included.
      # Otherwise: drop an inline comment (whitespace then #), then trailing
      # whitespace. That is what bash did when these files were sourced, and
      # people write `KEY=8080 # my port`. Parsing kept the comment IN the value
      # (FREECHAT_SERVER_PORT became "8080 # my port" and the client's address
      # "ip:8080 # my port") until this was added. A # with no whitespace before
      # it is part of the value, as in bash: http://host/#frag stays whole.
      if [[ "$value" == \"*\" && ${#value} -ge 2 ]]; then
        value="${value:1:${#value}-2}"
      elif [[ "$value" == \'*\' && ${#value} -ge 2 ]]; then
        value="${value:1:${#value}-2}"
      else
        value="${value%%[[:space:]]#*}"
        value="${value%"${value##*[![:space:]]}"}"
      fi
      # export, not eval: the value is data and never re-parsed as shell.
      export "$key=$value"
    else
      ignored=$((ignored + 1))
      printf 'load_env_file: %s:%d is not KEY=VALUE, ignored: %s\n' \
             "$file" "$lineno" "$line" >&2
    fi
  done < "$file"

  return 0
}

# load_freechat_env <root>  --  freechat.env.example first, freechat.env over it.
#
# Layered, not either/or. Previously freechat.env REPLACED the example, so the
# natural thing -- a freechat.env holding only what you changed, say just the
# port -- lost every other key and failed with "FREECHAT_SERVER_IP missing".
# Now the example supplies every default and freechat.env overrides what it
# names; a complete copy of the example still works exactly as before.
#
# Sets FREECHAT_ENV_SOURCES to what was read, for the caller's log line.
load_freechat_env() {
  local root=$1
  FREECHAT_ENV_SOURCES=""
  if [[ -f "$root/freechat.env.example" ]]; then
    load_env_file "$root/freechat.env.example" || return 1
    FREECHAT_ENV_SOURCES="freechat.env.example"
  fi
  if [[ -f "$root/freechat.env" ]]; then
    load_env_file "$root/freechat.env" || return 1
    FREECHAT_ENV_SOURCES="${FREECHAT_ENV_SOURCES:+$FREECHAT_ENV_SOURCES + }freechat.env"
  fi
  if [[ -z "$FREECHAT_ENV_SOURCES" ]]; then
    printf 'load_freechat_env: no freechat.env or freechat.env.example in %s\n' "$root" >&2
    return 1
  fi
}
