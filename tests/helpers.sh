# shellcheck shell=bash
# Tiny assertion helpers for the plain-bash test suite.
# shellcheck disable=SC2034  # LS and WB are used by the test files
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LS="$REPO_DIR/local-stack.sh"
WB="$REPO_DIR/wb.sh"
PASS=0 FAIL=0 CURRENT=""

setup_sandbox() {
  SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/local-stack-test.XXXXXX")
  export LOCAL_STACK_REGISTRY="$SANDBOX/registry.tsv"
  export LOCAL_STACK_CONF="$SANDBOX/test.conf"
  export LOCAL_STACK_GRACE=0
  export LOCAL_STACK_OWNER=tester
  export NO_COLOR=1
  # High, rarely used ports so the suite does not trip over anything real.
  write_conf "${1:-12}"
}

write_conf() {
  cat >"$LOCAL_STACK_CONF" <<CONF
[stack]
name = "test-stack"
slots = $1
stride = 10
exports = ["DB_NAME={db}"]

[database]
template = "tpl_db"
name = "test_{name}"
clone = "echo clone {template} {db} >> $SANDBOX/db.log"
drop = "echo drop {db} >> $SANDBOX/db.log"

[service.api]
port = 41000
port_var = "API_PORT"
exports = ["WEB_URL=http://localhost:{port.web}"]

[service.web]
port = 42000
port_var = "WEB_PORT"

[service.jobs]
port = 43000
port_var = "JOBS_PORT"

[workbench]
root = "$SANDBOX/wb"
default_ref = "origin/main"
protected = ["$SANDBOX/checkouts/protected-repo"]
CONF
}

teardown_sandbox() { [[ -n ${SANDBOX:-} && -d $SANDBOX ]] && rm -rf "$SANDBOX"; }

test_start() { CURRENT=$1; }
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$CURRENT${1:+: $1}"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s: %s\n' "$CURRENT" "$*"; }

assert_eq() { if [[ $1 == "$2" ]]; then ok "${3:-}"; else fail "${3:-} expected [$2] got [$1]"; fi; }
assert_contains() { if [[ $1 == *"$2"* ]]; then ok "${3:-}"; else fail "${3:-} expected to contain [$2] in [$1]"; fi; }
assert_not_contains() { if [[ $1 != *"$2"* ]]; then ok "${3:-}"; else fail "${3:-} did not expect [$2] in [$1]"; fi; }
assert_status() { if [[ $1 == "$2" ]]; then ok "${3:-}"; else fail "${3:-} expected exit $2, got $1"; fi; }

# Slot numbers held by test-stack, sorted.
held_slots() { tail -n +2 "$LOCAL_STACK_REGISTRY" | cut -f3 | sort -n | tr '\n' ' '; }

# Start a TCP listener on a port; prints its pid. Needs python3.
start_listener() {
  python3 -c 'import socket,sys,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(); time.sleep(600)' "$1" >/dev/null 2>&1 &
  local pid=$! _
  for _ in $(seq 1 50); do (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && break; sleep 0.1; done
  echo "$pid"
}

summary() {
  printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
  ((FAIL == 0))
}
