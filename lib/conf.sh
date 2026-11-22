# shellcheck shell=bash
# Reader for local-stack.conf, a small TOML subset:
#   [section] or [section.sub]
#   key = "string" | 123 | true | ["a", "b"]
#   # comments, blank lines
# Values land in CONF_FLAT as "section.key<TAB>value" lines. Arrays are stored with
# their items separated by the unit separator (\x1f).

CONF_FLAT=""
CONF_SECTIONS=""
CONF_US=$'\x1f'

conf_die() { printf 'config error: %s\n' "$*" >&2; exit 2; }

# Strip one quoted string from the front of $1; result in REPLY, rest in CONF_REST.
_conf_take_string() {
  local s=$1 out="" c i
  [[ ${s:0:1} == '"' ]] || return 1
  for ((i = 1; i < ${#s}; i++)); do
    c=${s:i:1}
    if [[ $c == '\' ]]; then
      i=$((i + 1)); out+=${s:i:1}
    elif [[ $c == '"' ]]; then
      REPLY=$out; CONF_REST=${s:i+1}; return 0
    else
      out+=$c
    fi
  done
  return 1
}

_conf_trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; REPLY=$s; }

conf_load() {
  local file=$1 section="" line n=0 key raw items item
  [[ -f $file ]] || conf_die "no config file at $file"
  CONF_FLAT=""; CONF_SECTIONS=""
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    _conf_trim "$line"; line=$REPLY
    [[ -z $line || ${line:0:1} == '#' ]] && continue
    if [[ $line =~ ^\[([A-Za-z0-9_.-]+)\]([[:space:]]*#.*)?$ ]]; then
      section=${BASH_REMATCH[1]}
      CONF_SECTIONS+="$section"$'\n'
      continue
    fi
    [[ $line =~ ^([A-Za-z0-9_-]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || conf_die "$file:$n: cannot parse: $line"
    key=${BASH_REMATCH[1]}; raw=${BASH_REMATCH[2]}
    if [[ ${raw:0:1} == '"' ]]; then
      _conf_take_string "$raw" || conf_die "$file:$n: unterminated string"
      item=$REPLY
    elif [[ ${raw:0:1} == '[' ]]; then
      raw=${raw:1}; items=""; local first=1
      while :; do
        _conf_trim "$raw"; raw=$REPLY
        [[ ${raw:0:1} == ']' ]] && break
        [[ -z $raw ]] && conf_die "$file:$n: arrays must close on the same line"
        _conf_take_string "$raw" || conf_die "$file:$n: array items must be quoted strings"
        if ((first)); then items=$REPLY; first=0; else items+="$CONF_US$REPLY"; fi
        _conf_trim "$CONF_REST"; raw=$REPLY
        [[ ${raw:0:1} == ',' ]] && raw=${raw:1}
      done
      item=$items
    else
      item=${raw%%[[:space:]#]*}
      [[ $item =~ ^(-?[0-9]+|true|false)$ ]] || conf_die "$file:$n: bare value '$item' (quote strings)"
    fi
    [[ $item == *$'\t'* || $item == *$'\n'* ]] && conf_die "$file:$n: tabs are not allowed in values"
    CONF_FLAT+="${section:+$section.}$key"$'\t'"$item"$'\n'
  done <"$file"
}

# conf_get <dotted.key> [default] -> stdout. Last definition wins.
conf_get() {
  local want=$1 k v found=0 val=""
  while IFS=$'\t' read -r k v; do
    [[ $k == "$want" ]] && { val=$v; found=1; }
  done <<<"$CONF_FLAT"
  if ((found)); then printf '%s' "$val"; else printf '%s' "${2-}"; fi
}

# conf_list <dotted.key> -> one array item per line.
conf_list() {
  local v; v=$(conf_get "$1")
  [[ -z $v ]] && return 0
  printf '%s\n' "${v//$CONF_US/$'\n'}"
}

# conf_subsections <prefix> -> names under [prefix.*] in file order.
conf_subsections() {
  local s
  while IFS= read -r s; do
    [[ $s == "$1".* ]] && printf '%s\n' "${s#"$1".}"
  done <<<"$CONF_SECTIONS"
}

# Expand a leading ~ and $HOME.
conf_path() {
  local p=$1
  [[ $p == "~" || $p == "~/"* ]] && p="$HOME${p:1}"
  p=${p//\$HOME/$HOME}
  printf '%s' "$p"
}

# Find the config: $LOCAL_STACK_CONF, ./local-stack.conf, then next to the script.
conf_locate() {
  local script_dir=$1
  if [[ -n ${LOCAL_STACK_CONF:-} ]]; then printf '%s' "$LOCAL_STACK_CONF"
  elif [[ -f ./local-stack.conf ]]; then printf '%s' "$PWD/local-stack.conf"
  else printf '%s' "$script_dir/local-stack.conf"
  fi
}

# render <template> name=value ... : replaces {name} with value.
render() {
  local out=$1 pair; shift
  for pair in "$@"; do
    out=${out//\{${pair%%=*}\}/${pair#*=}}
  done
  printf '%s' "$out"
}
