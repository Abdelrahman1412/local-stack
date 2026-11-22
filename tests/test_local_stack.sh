#!/usr/bin/env bash
# Behaviour tests for local-stack.sh.
set -u
# shellcheck source=helpers.sh
. "$(dirname "$0")/helpers.sh"
HAVE_PY=0; command -v python3 >/dev/null 2>&1 && HAVE_PY=1

dead_pid() { true & local p=$!; wait "$p"; echo "$p"; }

# ── concurrency ──────────────────────────────────────────────────────────────
for mode in flock mkdir; do
  if [[ $mode == flock ]] && ! command -v flock >/dev/null 2>&1; then continue; fi
  test_start "10 parallel reserves never collide ($mode lock)"
  setup_sandbox 12
  export LOCAL_STACK_LOCK=$mode
  for i in $(seq 1 10); do "$LS" reserve "task-$i" --holder $$ >/dev/null 2>&1 & done
  wait
  assert_eq "$(tail -n +2 "$LOCAL_STACK_REGISTRY" | wc -l | tr -d ' ')" 10 "10 rows"
  assert_eq "$(held_slots)" "1 2 3 4 5 6 7 8 9 10 " "slots 1-10, each once"
  assert_eq "$(tail -n +2 "$LOCAL_STACK_REGISTRY" | cut -f4 | tr ',' '\n' | sort | uniq -d)" "" "no port appears twice"
  unset LOCAL_STACK_LOCK
  teardown_sandbox
done

test_start "parallel reserves beyond capacity fail cleanly"
setup_sandbox 5
pids=()
for i in $(seq 1 10); do "$LS" reserve "over-$i" --holder $$ >/dev/null 2>&1 & pids+=($!); done
okc=0 full=0
for p in "${pids[@]}"; do wait "$p"; rc=$?; ((rc == 0)) && okc=$((okc + 1)); ((rc == 3)) && full=$((full + 1)); done
assert_eq "$okc/$full" "5/5" "5 got a slot, 5 were told none is free"
assert_eq "$(held_slots)" "1 2 3 4 5 " "slots 1-5, each once"
teardown_sandbox

# ── slot 0 guard ─────────────────────────────────────────────────────────────
test_start "slot 0 is never handed out"
setup_sandbox 2
out=$("$LS" reserve first --holder $$ 2>/dev/null)
assert_contains "$out" "export LOCAL_STACK_SLOT=1" "first reservation gets slot 1"
assert_contains "$out" "export API_PORT=41010" "not the default port 41000"
"$LS" reserve second --holder $$ >/dev/null 2>&1
"$LS" reserve third --holder $$ >/dev/null 2>&1; rc=$?
assert_status "$rc" 3 "full stack refuses instead of falling back to slot 0"
assert_not_contains "$(held_slots)" "0 " "registry never holds slot 0"
out=$("$LS" check 41000); rc=$?
assert_status "$rc" 1 "check on a slot 0 port is not 'free'"
assert_contains "$out" "developer's own stack" "check explains the slot 0 guard"
teardown_sandbox

# ── release and reuse ────────────────────────────────────────────────────────
test_start "release then reserve reuses the slot"
setup_sandbox 6
for n in a b c; do "$LS" reserve "$n" --holder $$ >/dev/null 2>&1; done
"$LS" release b >/dev/null
assert_eq "$(held_slots)" "1 3 " "slot 2 is free after release"
out=$("$LS" reserve d --holder $$ 2>/dev/null)
assert_contains "$out" "LOCAL_STACK_SLOT=2" "next reserve takes the lowest free slot"
"$LS" release nope >/dev/null 2>&1; rc=$?
assert_status "$rc" 1 "releasing an unknown name fails"
teardown_sandbox

test_start "reserving the same name twice is idempotent"
setup_sandbox 6
"$LS" reserve same --holder $$ >/dev/null 2>&1
out=$("$LS" reserve same --holder $$ 2>/dev/null)
assert_contains "$out" "LOCAL_STACK_SLOT=1" "same slot"
assert_eq "$(held_slots)" "1 " "one row"
teardown_sandbox

# ── check ────────────────────────────────────────────────────────────────────
test_start "check reports the owner"
setup_sandbox 6
"$LS" reserve payroll-fix --owner agent-7 --holder $$ >/dev/null 2>&1
out=$("$LS" check 42010); rc=$?
assert_status "$rc" 1 "a reserved port is not free"
assert_contains "$out" "reserved by payroll-fix" "names the reservation"
assert_contains "$out" "owner agent-7" "names the owner"
assert_contains "$out" "web, slot 1" "names the service and slot"
out=$("$LS" check 41050); rc=$?
assert_status "$rc" 0 "an unreserved, idle port is free"
assert_contains "$out" "is free" "says free"
if ((HAVE_PY)); then
  lp=$(start_listener 41010)
  out=$("$LS" check 41010); rc=$?
  assert_status "$rc" 1 "a listening port is in use"
  assert_contains "$out" "IN USE" "says in use"
  assert_contains "$out" "reserved by payroll-fix" "and whose reservation it is"
  kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
fi
teardown_sandbox

# ── gc ───────────────────────────────────────────────────────────────────────
test_start "gc drops stale reservations and never kills processes"
setup_sandbox 6
sleep 300 & holder=$!
"$LS" reserve alive --holder "$holder" >/dev/null 2>&1
"$LS" reserve gone --holder "$(dead_pid)" >/dev/null 2>&1
lp=""
if ((HAVE_PY)); then
  "$LS" reserve serving --holder "$(dead_pid)" >/dev/null 2>&1   # slot 3
  lp=$(start_listener 41030)
fi
out=$("$LS" gc)
assert_contains "$out" "drop gone" "dead holder, nothing listening: dropped"
assert_not_contains "$out" "drop alive" "live holder: kept"
assert_contains "$(cut -f2 "$LOCAL_STACK_REGISTRY")" "alive" "live holder still registered"
assert_not_contains "$(cut -f2 "$LOCAL_STACK_REGISTRY")" "gone" "stale row removed"
if kill -0 "$holder" 2>/dev/null; then ok "holder process still running"; else fail "gc killed the holder"; fi
if [[ -n $lp ]]; then
  assert_not_contains "$out" "drop serving" "dead holder but ports still served: kept"
  if kill -0 "$lp" 2>/dev/null; then ok "listener still running"; else fail "gc killed a listener"; fi
  kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
fi
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
teardown_sandbox

test_start "gc respects the grace window and --dry-run"
setup_sandbox 6
"$LS" reserve young --holder "$(dead_pid)" >/dev/null 2>&1
out=$(LOCAL_STACK_GRACE=3600 "$LS" gc)
assert_not_contains "$out" "drop young" "fresh reservation survives inside the grace window"
out=$("$LS" gc --dry-run)
assert_contains "$out" "drop young" "dry run reports it"
assert_contains "$(cut -f2 "$LOCAL_STACK_REGISTRY")" "young" "dry run keeps it"
teardown_sandbox

test_start "the script cannot signal processes"
hits=$(grep -nE '\b(pkill|killall)\b|\bkill +(-[0-9A-Z]+ +)?[^-]' "$LS" | grep -v 'kill -0' || true)
assert_eq "$hits" "" "only 'kill -0' (an existence check) appears"

# ── reserve avoids busy ports, env, config ───────────────────────────────────
if ((HAVE_PY)); then
  test_start "reserve skips a slot whose port is taken outside the registry"
  setup_sandbox 6
  lp=$(start_listener 42010)
  out=$("$LS" reserve skip --holder $$ 2>/dev/null)
  assert_contains "$out" "LOCAL_STACK_SLOT=2" "slot 1 skipped"
  kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
  teardown_sandbox
fi

test_start "env prints role exports"
setup_sandbox 6
"$LS" reserve envtest --holder $$ >/dev/null 2>&1
out=$("$LS" env envtest api)
assert_contains "$out" "export PORT=41010" "PORT is the role's own port"
assert_contains "$out" "export WEB_URL=http://localhost:42010" "role exports resolve peer ports"
assert_contains "$out" "export DB_NAME=test_envtest" "per-task database name"
"$LS" env envtest nosuch >/dev/null 2>&1; rc=$?
assert_status "$rc" 1 "unknown role fails"
"$LS" env unknown api >/dev/null 2>&1; rc=$?
assert_status "$rc" 1 "unreserved name fails"
teardown_sandbox

test_start "status shows repo, branch and owner"
setup_sandbox 6
mkdir -p "$SANDBOX/repo" && git -C "$SANDBOX/repo" init -q -b feature/payslips
out=$(cd "$SANDBOX/repo" && "$LS" reserve st --owner dana --holder $$ 2>/dev/null; "$LS" status)
assert_contains "$out" "dana" "owner"
assert_contains "$out" "repo" "repo"
assert_contains "$out" "feature/payslips" "branch"
assert_contains "$out" "(developer)" "slot 0 row"
teardown_sandbox

test_start "overlapping slot layout is rejected"
setup_sandbox 6
sed -i.bak 's/port = 42000/port = 41030/' "$LOCAL_STACK_CONF"
out=$("$LS" ports 2>&1); rc=$?
assert_status "$rc" 2 "config error"
assert_contains "$out" "used twice" "explains the overlap"
teardown_sandbox

summary
