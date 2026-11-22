#!/usr/bin/env bash
# local-stack.sh: hand out whole port sets ("slots") so many copies of one app can
# run side by side on a single machine.
#
#   local-stack.sh status                  who holds which slot (repo, branch, owner)
#   local-stack.sh reserve <name> [opts]   claim the lowest free slot, print exports
#   local-stack.sh release <name>          give the slot back (processes are left alone)
#   local-stack.sh check <port>            is this port free, and if not, whose is it
#   local-stack.sh gc [--dry-run]          drop reservations whose holder is gone
#   local-stack.sh env <name> <role>       print the exports for one service
#   local-stack.sh ports                   print the slot layout from the config
#
# reserve options:
#   --owner <who>    default: $LOCAL_STACK_OWNER, else $USER
#   --holder <pid>   process whose life keeps the slot (default: the calling shell)
#
# Slot 0 is the developer's own stack on the default ports. It is never handed out.
# Nothing in this script ever stops or kills a process.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/conf.sh
. "$SCRIPT_DIR/lib/conf.sh"

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  B=$'\033[1m' D=$'\033[2m' R=$'\033[31m' G=$'\033[32m' Y=$'\033[33m' N=$'\033[0m'
else
  B="" D="" R="" G="" Y="" N=""
fi

die() { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit "${2:-1}"; }

# ── configuration ────────────────────────────────────────────────────────────
CONF_FILE=$(conf_locate "$SCRIPT_DIR")
conf_load "$CONF_FILE"

STACK=$(conf_get stack.name default)
SLOTS=$(conf_get stack.slots 4)
STRIDE=$(conf_get stack.stride 10)
GRACE=${LOCAL_STACK_GRACE:-$(conf_get stack.grace_seconds 1800)}
REGISTRY=$(conf_path "${LOCAL_STACK_REGISTRY:-$(conf_get stack.registry "~/.local/state/local-stack/registry.tsv")}")
LOCK_TIMEOUT=${LOCAL_STACK_LOCK_TIMEOUT:-30}

mapfile -t SERVICES < <(conf_subsections service)
((${#SERVICES[@]})) || die "no [service.*] sections in $CONF_FILE" 2
[[ $SLOTS =~ ^[0-9]+$ && $SLOTS -ge 1 ]] || die "stack.slots must be a positive integer" 2
[[ $STACK =~ ^[A-Za-z0-9._-]+$ ]] || die "stack.name may only use letters, digits, . _ -" 2

svc_base()   { conf_get "service.$1.port"; }
svc_stride() { conf_get "service.$1.stride" "$STRIDE"; }
svc_port()   { echo $(( $(svc_base "$1") + $(svc_stride "$1") * $2 )); }
svc_var()    { conf_get "service.$1.port_var" "$(tr '[:lower:]-' '[:upper:]_' <<<"$1")_PORT"; }

# "api:8010,web:3010"
slot_ports() {
  local s out=""
  for s in "${SERVICES[@]}"; do out+="${out:+,}$s:$(svc_port "$s" "$1")"; done
  printf '%s' "$out"
}

validate_layout() {
  local s slot p seen=" "
  for s in "${SERVICES[@]}"; do
    [[ $(svc_base "$s") =~ ^[0-9]+$ ]] || die "service.$s.port must be a number" 2
    for ((slot = 0; slot <= SLOTS; slot++)); do
      p=$(svc_port "$s" "$slot")
      ((p > 0 && p < 65536)) || die "service $s slot $slot gives port $p, outside 1-65535" 2
      [[ $seen == *" $p "* ]] && die "port $p is used twice in the slot layout; widen the stride or move a base port" 2
      seen+="$p "
    done
  done
}
validate_layout

# ── registry and lock ────────────────────────────────────────────────────────
# Columns: stack name slot ports owner holder repo branch cwd claimed_at
HEADER=$'stack\tname\tslot\tports\towner\tholder\trepo\tbranch\tcwd\tclaimed_at'
mkdir -p "$(dirname "$REGISTRY")" || die "cannot create $(dirname "$REGISTRY")"

LOCK_MODE=${LOCAL_STACK_LOCK:-auto}
if [[ $LOCK_MODE == auto ]]; then
  if command -v flock >/dev/null 2>&1; then LOCK_MODE="flock"; else LOCK_MODE="mkdir"; fi
fi
LOCK_DIR="$REGISTRY.lockdir"

lock() {
  if [[ $LOCK_MODE == flock ]]; then
    exec 9>>"$REGISTRY.lock"
    flock -w "$LOCK_TIMEOUT" 9 || die "registry lock busy for ${LOCK_TIMEOUT}s"
  else
    local waited=0 holder
    until mkdir "$LOCK_DIR" 2>/dev/null; do
      holder=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
      # A lock left by a process that no longer exists is safe to break.
      if [[ -n $holder ]] && ! pid_alive "$holder"; then
        rm -rf "$LOCK_DIR"; continue
      fi
      sleep 0.05; waited=$((waited + 1))
      ((waited > LOCK_TIMEOUT * 20)) && die "registry lock busy for ${LOCK_TIMEOUT}s ($LOCK_DIR)"
    done
    echo $$ >"$LOCK_DIR/pid"
    trap 'rm -rf "$LOCK_DIR"' EXIT
  fi
  [[ -s $REGISTRY ]] || printf '%s\n' "$HEADER" >"$REGISTRY"
}

unlock() {
  if [[ $LOCK_MODE == flock ]]; then exec 9>&-; else rm -rf "$LOCK_DIR"; trap - EXIT; fi
}

# Replace the registry with stdin, atomically.
registry_write() {
  local tmp
  tmp=$(mktemp "$REGISTRY.XXXXXX") || die "cannot write next to $REGISTRY"
  cat >"$tmp" && mv "$tmp" "$REGISTRY"
}

rows() { [[ -s $REGISTRY ]] && tail -n +2 "$REGISTRY"; return 0; }
my_rows() { rows | awk -F'\t' -v s="$STACK" '$1 == s'; }
row_for_name() { my_rows | awk -F'\t' -v n="$1" '$2 == n' | head -1; }
row_for_slot() { my_rows | awk -F'\t' -v n="$1" '$3 == n' | head -1; }

# Which registry row (any stack) claims this port? Prints the row.
row_for_port() {
  rows | awk -F'\t' -v p="$1" '{ n = split($4, a, ","); for (i = 1; i <= n; i++) { split(a[i], kv, ":"); if (kv[2] == p) { print; exit } } }'
}

# ── processes and ports ──────────────────────────────────────────────────────
pid_alive() {
  [[ $1 =~ ^[0-9]+$ ]] || return 1
  kill -0 "$1" 2>/dev/null && return 0
  [[ -d /proc/$1 ]]   # owned by another user: kill -0 fails, but it exists
}

PORT_TOOL=${LOCAL_STACK_PORT_TOOL:-auto}
if [[ $PORT_TOOL == auto ]]; then
  if command -v ss >/dev/null 2>&1; then PORT_TOOL=ss
  elif command -v lsof >/dev/null 2>&1; then PORT_TOOL=lsof
  else PORT_TOOL=probe
  fi
fi

# port_listening <port>: exit 0 if something listens. Prints the pid when visible.
port_listening() {
  local p=$1 out pid
  case $PORT_TOOL in
    ss)
      out=$(ss -Hltnp "sport = :$p" 2>/dev/null) || out=""
      [[ -z $out ]] && return 1
      pid=$(sed -n 's/.*pid=\([0-9]*\).*/\1/p' <<<"$out" | head -1)
      printf '%s' "$pid"; return 0 ;;
    lsof)
      pid=$(lsof -nP -ti "tcp:$p" -sTCP:LISTEN 2>/dev/null | head -1)
      [[ -n $pid ]] && { printf '%s' "$pid"; return 0; }
      # lsof cannot see sockets of other users without root; probe as well.
      (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null ;;
    probe)
      (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null ;;
    *) die "LOCAL_STACK_PORT_TOOL must be ss, lsof or probe" 2 ;;
  esac
}

pid_cwd() {
  local d
  d=$(readlink "/proc/$1/cwd" 2>/dev/null) && { printf '%s' "$d"; return; }
  command -v lsof >/dev/null 2>&1 && lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1
}

# "repo<TAB>branch" for a directory, "-" when not inside a git checkout.
dir_repo_branch() {
  local top br
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || { printf -- '-\t-'; return; }
  br=$(git -C "$1" symbolic-ref --short -q HEAD 2>/dev/null || git -C "$1" rev-parse --short HEAD 2>/dev/null)
  printf '%s\t%s' "$(basename "$top")" "${br:--}"
}

pid_label() {
  local cwd rb
  [[ -z $1 ]] && { printf 'a process this user cannot inspect'; return; }
  cwd=$(pid_cwd "$1")
  [[ -z $cwd ]] && { printf 'pid %s' "$1"; return; }
  rb=$(dir_repo_branch "$cwd")
  if [[ $rb == $'-\t-' ]]; then printf 'pid %s in %s' "$1" "$cwd"
  else printf 'pid %s, %s @ %s' "$1" "${rb%%$'\t'*}" "${rb#*$'\t'}"
  fi
}

# Exit 0 if any port of the "svc:port,..." list is listening.
any_listening() {
  local pair
  IFS=, read -ra pairs <<<"$1"
  for pair in "${pairs[@]}"; do port_listening "${pair#*:}" >/dev/null && return 0; done
  return 1
}

# ── exports ──────────────────────────────────────────────────────────────────
render_vars() {
  local name=$1 slot=$2 s db
  db=$(render "$(conf_get database.name "${STACK}_{name}")" "name=$name" "slot=$slot" "stack=$STACK")
  db=${db//[^A-Za-z0-9_]/_}
  RVARS=("name=$name" "slot=$slot" "stack=$STACK" "db=$db" "template=$(conf_get database.template)")
  for s in "${SERVICES[@]}"; do RVARS+=("port.$s=$(svc_port "$s" "$slot")"); done
}

quote() { printf '%q' "$1"; }

emit_export() {
  local line=$1 key val
  [[ $line == *=* ]] || die "export '$line' must look like KEY=value" 2
  key=${line%%=*}; val=$(render "${line#*=}" "${RVARS[@]}")
  printf 'export %s=%s\n' "$key" "$(quote "$val")"
}

common_exports() {
  local name=$1 slot=$2 s line
  render_vars "$name" "$slot"
  printf 'export LOCAL_STACK_NAME=%s\n' "$(quote "$name")"
  printf 'export LOCAL_STACK_SLOT=%s\n' "$slot"
  for s in "${SERVICES[@]}"; do printf 'export %s=%s\n' "$(svc_var "$s")" "$(svc_port "$s" "$slot")"; done
  while IFS= read -r line; do [[ -n $line ]] && emit_export "$line"; done < <(conf_list stack.exports)
}

# ── commands ─────────────────────────────────────────────────────────────────
valid_name() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] || die "name must be letters, digits, . _ - (max 63 chars): '$1'"; }

cmd_reserve() {
  local name="" owner=${LOCAL_STACK_OWNER:-${USER:-unknown}} holder=$PPID
  while (($#)); do
    case $1 in
      --owner) owner=${2:?--owner needs a value}; shift 2 ;;
      --holder) holder=${2:?--holder needs a pid}; shift 2 ;;
      -*) die "unknown option $1" ;;
      *) [[ -n $name ]] && die "one name only"; name=$1; shift ;;
    esac
  done
  [[ -n $name ]] || die "usage: reserve <name> [--owner who] [--holder pid]"
  valid_name "$name"
  [[ $holder =~ ^[0-9]+$ ]] || die "--holder must be a pid"
  owner=${owner//[$'\t\n']/ }

  local rb repo branch slot ports existing busy=""
  rb=$(dir_repo_branch "$PWD"); repo=${rb%%$'\t'*}; branch=${rb#*$'\t'}

  lock
  existing=$(row_for_name "$name")
  if [[ -n $existing ]]; then
    slot=$(cut -f3 <<<"$existing")
    unlock
    printf '%s# %s already holds slot %s%s\n' "$D" "$name" "$slot" "$N" >&2
    common_exports "$name" "$slot"
    return 0
  fi
  for ((slot = 1; slot <= SLOTS; slot++)); do
    [[ -n $(row_for_slot "$slot") ]] && continue
    ports=$(slot_ports "$slot")
    local pair taken=0
    IFS=, read -ra pairs <<<"$ports"
    for pair in "${pairs[@]}"; do
      # Another stack in the shared registry, or an unregistered process, has it.
      if [[ -n $(row_for_port "${pair#*:}") ]] || port_listening "${pair#*:}" >/dev/null; then
        taken=1; busy+=" ${pair#*:}"; break
      fi
    done
    ((taken)) && continue
    { cat "$REGISTRY"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$STACK" "$name" "$slot" "$ports" "$owner" "$holder" "$repo" "$branch" "$PWD" "$(date +%s)"
    } | registry_write
    unlock
    printf '%sReserved slot %s for %s%s (%s)\n' "$G" "$slot" "$name" "$N" "${ports//,/ }" >&2
    common_exports "$name" "$slot"
    printf '%s# role-specific exports: %s env %s <%s>%s\n' "$D" "$(basename "$0")" "$name" "$(IFS='|'; echo "${SERVICES[*]}")" "$N" >&2
    return 0
  done
  unlock
  die "no free slot for $STACK (slots 1-$SLOTS taken${busy:+; ports in use outside the registry:$busy}). Run '$(basename "$0") gc' or release one." 3
}

cmd_release() {
  local name=${1:?usage: release <name>}
  lock
  if [[ -z $(row_for_name "$name") ]]; then unlock; die "$name holds no slot in $STACK"; fi
  { printf '%s\n' "$HEADER"
    rows | awk -F'\t' -v s="$STACK" -v n="$name" '!($1 == s && $2 == n)'
  } | registry_write
  unlock
  printf '%sReleased %s.%s Processes it started are still running; stop them yourself.\n' "$G" "$name" "$N"
}

cmd_env() {
  local name=${1:?usage: env <name> <role>} role=${2:?usage: env <name> <role>} row slot s ok=0 line
  for s in "${SERVICES[@]}"; do [[ $s == "$role" ]] && ok=1; done
  ((ok)) || die "unknown role '$role'; roles: ${SERVICES[*]}"
  row=$(row_for_name "$name")
  [[ -n $row ]] || die "$name holds no slot; run: $(basename "$0") reserve $name"
  slot=$(cut -f3 <<<"$row")
  common_exports "$name" "$slot"
  printf 'export PORT=%s\n' "$(svc_port "$role" "$slot")"
  while IFS= read -r line; do [[ -n $line ]] && emit_export "$line"; done < <(conf_list "service.$role.exports")
}

# slot_state <row> -> active | starting | stale
row_state() {
  local holder ports claimed
  holder=$(cut -f6 <<<"$1"); ports=$(cut -f4 <<<"$1"); claimed=$(cut -f10 <<<"$1")
  if pid_alive "$holder" || any_listening "$ports"; then echo active
  elif (($(date +%s) - claimed < GRACE)); then echo starting
  else echo stale
  fi
}

cmd_status() {
  local fmt='%-5s %-18s %-14s %-18s %-24s %-9s %s\n' row s p pid listening=""
  printf "$B$fmt$N" SLOT NAME OWNER REPO BRANCH STATE PORTS
  for s in "${SERVICES[@]}"; do
    p=$(svc_port "$s" 0)
    if pid=$(port_listening "$p"); then listening+=" $s:$p(up)"; else listening+=" $s:$p"; fi
  done
  printf "$D$fmt$N" 0 "(developer)" "-" "-" "-" "reserved" "${listening# }"
  for ((slot = 1; slot <= SLOTS; slot++)); do
    row=$(row_for_slot "$slot")
    if [[ -z $row ]]; then printf "$D$fmt$N" "$slot" "-" "-" "-" "-" "free" "$(slot_ports "$slot" | tr , ' ')"; continue; fi
    local st color=""
    st=$(row_state "$row")
    [[ $st == stale ]] && color=$Y
    IFS=$'\t' read -r _ name _ ports owner _ repo branch _ _ <<<"$row"
    printf "$color$fmt$N" "$slot" "$name" "$owner" "$repo" "$branch" "$st" "${ports//,/ }"
  done
  local others
  others=$(rows | awk -F'\t' -v s="$STACK" '$1 != s {print $1}' | sort | uniq -c | awk '{printf "%s%s (%s)", sep, $2, $1; sep=", "}')
  [[ -n $others ]] && printf '\n%sOther stacks in this registry: %s%s\n' "$D" "$others" "$N"
  printf '%sregistry: %s%s\n' "$D" "$REGISTRY" "$N"
}

cmd_check() {
  local port=${1:?usage: check <port>} s slot base st row pid owner_desc="" in_layout=""
  [[ $port =~ ^[0-9]+$ ]] || die "port must be a number"
  for s in "${SERVICES[@]}"; do
    base=$(svc_base "$s"); st=$(svc_stride "$s")
    if ((port >= base && (port - base) % st == 0 && (port - base) / st <= SLOTS)); then
      slot=$(((port - base) / st)); in_layout="$s, slot $slot"
    fi
  done
  row=$(row_for_port "$port")
  [[ -n $row ]] && owner_desc="reserved by $(cut -f2 <<<"$row") (owner $(cut -f5 <<<"$row"), $(cut -f7 <<<"$row") @ $(cut -f8 <<<"$row")${in_layout:+, $in_layout})"
  if pid=$(port_listening "$port"); then
    printf '%s:%s is IN USE%s by %s%s\n' "$R" "$port" "$N" "$(pid_label "$pid")" "${owner_desc:+; $owner_desc}"
    [[ ${slot:-} == 0 ]] && printf "  This is the developer's own stack. Leave it alone.\n"
    printf '  Never stop a listener you did not start.\n'
    return 1
  fi
  if [[ ${slot:-} == 0 ]]; then
    printf "%s:%s is not listening, but it is reserved for the developer's own stack (%s).%s\n" "$Y" "$port" "$in_layout" "$N"
    return 1
  fi
  if [[ -n $owner_desc ]]; then
    printf '%s:%s is not listening, but %s.%s\n' "$Y" "$port" "$owner_desc" "$N"
    return 1
  fi
  printf '%s:%s is free%s\n' "$G" "$port" "$N"
}

cmd_gc() {
  local dry=0 row st name kept="" dropped=0 now
  [[ ${1:-} == --dry-run ]] && dry=1
  lock
  now=$(date +%s)
  while IFS= read -r row; do
    [[ -z $row ]] && continue
    st=$(row_state "$row")
    name=$(cut -f2 <<<"$row")
    if [[ $st == stale ]]; then
      printf '  drop %s (slot %s, holder pid %s gone, nothing listening, claimed %ss ago)\n' \
        "$name" "$(cut -f3 <<<"$row")" "$(cut -f6 <<<"$row")" "$((now - $(cut -f10 <<<"$row")))"
      dropped=$((dropped + 1))
    else
      kept+="$row"$'\n'
    fi
  done < <(my_rows)
  if ((!dry)); then
    { printf '%s\n' "$HEADER"
      rows | awk -F'\t' -v s="$STACK" '$1 != s'
      printf '%s' "$kept"
    } | registry_write
  fi
  unlock
  printf '%sgc%s: %s stale reservation(s) %s. No process was signalled.\n' "$G" "$N" "$dropped" "$( ((dry)) && echo found || echo dropped)"
}

cmd_ports() {
  local s slot
  printf '%-5s' SLOT; for s in "${SERVICES[@]}"; do printf ' %-10s' "$s"; done; echo
  for ((slot = 0; slot <= SLOTS; slot++)); do
    printf '%-5s' "$slot"; for s in "${SERVICES[@]}"; do printf ' %-10s' "$(svc_port "$s" "$slot")"; done
    ((slot == 0)) && printf '  (developer, never handed out)'
    echo
  done
}

case ${1:-status} in
  status)  cmd_status ;;
  reserve) shift; cmd_reserve "$@" ;;
  release) shift; cmd_release "$@" ;;
  check)   shift; cmd_check "$@" ;;
  gc)      shift; cmd_gc "$@" ;;
  env)     shift; cmd_env "$@" ;;
  ports)   cmd_ports ;;
  -h|--help|help) sed -n '2,/^set -uo/{/^set -uo/d;s/^# \{0,1\}//;p;}' "$0" ;;
  *) die "unknown command '$1' (try --help)" ;;
esac
