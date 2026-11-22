#!/usr/bin/env bash
# Behaviour tests for wb.sh.
set -u
# shellcheck source=helpers.sh
. "$(dirname "$0")/helpers.sh"

make_checkout() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
  echo "work in progress" >"$dir/notes.txt"   # uncommitted change that must survive
}

fingerprint() {   # branch, HEAD, worktree status and branch list of a checkout
  git -C "$1" symbolic-ref HEAD; git -C "$1" rev-parse HEAD
  git -C "$1" status --porcelain; git -C "$1" branch --list
}

test_start "init and add leave the main checkout untouched"
setup_sandbox 4
src="$SANDBOX/checkouts/acme-api"
make_checkout "$src"
before=$(fingerprint "$src")
"$WB" init "$src" >/dev/null 2>&1; rc=$?
assert_status "$rc" 0 "init succeeds"
[[ -f $SANDBOX/wb/stores/acme-api.git/HEAD ]] && ok "bare store created" || fail "no bare store"
tree=$("$WB" add acme-api payslip-fix 2>/dev/null); rc=$?
assert_status "$rc" 0 "add succeeds"
assert_eq "$tree" "$SANDBOX/wb/trees/payslip-fix/acme-api" "worktree path"
assert_eq "$(git -C "$tree" symbolic-ref --short HEAD)" "wb/payslip-fix" "task branch checked out"
assert_eq "$(fingerprint "$src")" "$before" "main checkout unchanged"
assert_contains "$(cat "$SANDBOX/db.log")" "clone tpl_db test_payslip_fix" "database clone template ran with the task's db"
teardown_sandbox

test_start "two tasks share one object store"
setup_sandbox 4
src="$SANDBOX/checkouts/acme-web"
make_checkout "$src"
"$WB" init "$src" >/dev/null 2>&1
t1=$("$WB" add acme-web one --no-db 2>/dev/null)
t2=$("$WB" add acme-web two --no-db 2>/dev/null)
assert_eq "$(git -C "$t1" rev-parse --git-common-dir)" "$(git -C "$t2" rev-parse --git-common-dir)" "same common dir"
[[ ! -e $SANDBOX/db.log ]] && ok "--no-db skips the clone" || fail "--no-db still cloned"
"$WB" add acme-web one --no-db >/dev/null 2>&1; rc=$?
assert_status "$rc" 1 "adding the same task twice fails"
teardown_sandbox

test_start "rm removes the worktree and drops the database"
setup_sandbox 4
src="$SANDBOX/checkouts/acme-api"
make_checkout "$src"
"$WB" init "$src" >/dev/null 2>&1
tree=$("$WB" add acme-api cleanup 2>/dev/null)
"$WB" rm acme-api cleanup --drop-db >/dev/null 2>&1; rc=$?
assert_status "$rc" 0 "rm succeeds"
[[ ! -e $tree ]] && ok "worktree gone" || fail "worktree still there"
assert_contains "$(cat "$SANDBOX/db.log")" "drop test_cleanup" "drop template ran"
[[ -f $src/notes.txt ]] && ok "main checkout files intact" || fail "main checkout lost files"
teardown_sandbox

test_start "refuses to work inside a main checkout"
setup_sandbox 4
src="$SANDBOX/checkouts/protected-repo"
make_checkout "$src"
before=$(fingerprint "$src")
sed -i.bak "s|^root = .*|root = \"$src/.wb\"|" "$LOCAL_STACK_CONF"
out=$("$WB" init "$src" 2>&1); rc=$?
assert_status "$rc" 4 "workbench root inside a protected checkout is refused"
assert_contains "$out" "refusing" "explains why"
[[ ! -e $src/.wb ]] && ok "nothing created inside the checkout" || fail "created files in the checkout"
assert_eq "$(fingerprint "$src")" "$before" "checkout unchanged"
teardown_sandbox

test_start "refuses a root nested in any git checkout, even unlisted"
setup_sandbox 4
other="$SANDBOX/checkouts/unlisted"
make_checkout "$other"
sed -i.bak "s|^root = .*|root = \"$other/sub/wb\"|" "$LOCAL_STACK_CONF"
"$WB" init "$other" >/dev/null 2>&1; rc=$?
assert_status "$rc" 4 "refused"
teardown_sandbox

test_start "rm refuses a path that is not a worktree"
setup_sandbox 4
src="$SANDBOX/checkouts/acme-api"
make_checkout "$src"
"$WB" init "$src" >/dev/null 2>&1
mkdir -p "$SANDBOX/wb/trees/fake/acme-api" && echo keep >"$SANDBOX/wb/trees/fake/acme-api/file"
"$WB" rm acme-api fake >/dev/null 2>&1; rc=$?
assert_status "$rc" 4 "refused"
[[ -f $SANDBOX/wb/trees/fake/acme-api/file ]] && ok "files kept" || fail "deleted a non-worktree"
teardown_sandbox

summary
