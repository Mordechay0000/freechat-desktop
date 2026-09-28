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
      # Strip one matched pair of surrounding quotes, then trailing whitespace on
      # an unquoted value. A quoted value keeps its spaces exactly.
      if [[ "$value" == \"*\" && ${#value} -ge 2 ]]; then
        value="${value:1:${#value}-2}"
      elif [[ "$value" == \'*\' && ${#value} -ge 2 ]]; then
        value="${value:1:${#value}-2}"
      else
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
