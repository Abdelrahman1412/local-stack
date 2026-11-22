#!/usr/bin/env bash
# wb.sh: disposable workbenches. One shared bare object store per repo, one git
# worktree per task, one database copy per task. Your everyday checkouts are only
# ever read from; no command writes to them, switches their branch or touches
# their files.
#
#   wb.sh init <checkout> [<repo-name>]    create or refresh the shared store for a repo
#   wb.sh add <repo-name> <task> [<ref>]   new worktree for a task (+ database copy)
#        --no-db                           skip the database copy
#   wb.sh db <task>                        create the task's database copy
#   wb.sh rm <repo-name> <task> [--drop-db] remove the worktree (and drop the database)
#   wb.sh path <repo-name> <task>          print the worktree path
#   wb.sh list                             stores and task worktrees
#
# Layout under workbench.root:
#   stores/<repo-name>.git     bare clone, shared by every task of that repo
#   trees/<task>/<repo-name>   the worktree for one task
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/conf.sh
. "$SCRIPT_DIR/lib/conf.sh"

die() { printf 'error: %s\n' "$*" >&2; exit "${2:-1}"; }
say() { printf '%s\n' "$*" >&2; }

CONF_FILE=$(conf_locate "$SCRIPT_DIR")
conf_load "$CONF_FILE"
STACK=$(conf_get stack.name default)
ROOT=$(conf_path "${WB_ROOT:-$(conf_get workbench.root "~/.local/share/local-stack/$STACK")}")
DEFAULT_REF=$(conf_get workbench.default_ref origin/main)
BRANCH_PREFIX=$(conf_get workbench.branch_prefix wb/)
STORES="$ROOT/stores"
TREES="$ROOT/trees"

abspath() { realpath -m -- "$1"; }

valid() { [[ $2 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] || die "$1 must be letters, digits, . _ - : '$2'"; }

# Every main checkout we know of: the configured list plus each store's source.
protected_paths() {
  local p store
  while IFS= read -r p; do [[ -n $p ]] && abspath "$(conf_path "$p")"; done < <(conf_list workbench.protected)
  for store in "$STORES"/*.git; do
    [[ -d $store ]] || continue
    p=$(git --git-dir="$store" config --get wb.source 2>/dev/null) && [[ -n $p ]] && printf '%s\n' "$p"
  done
}

# Refuse any path that is, contains, or sits inside a protected checkout.
guard_path() {
  local target p
  target=$(abspath "$1")
  while IFS= read -r p; do
    [[ -z $p ]] && continue
    if [[ $target == "$p" || $target == "$p"/* || $p == "$target"/* ]]; then
      die "refusing to touch $target: it overlaps the main checkout $p" 4
    fi
  done < <(protected_paths)
  # A real checkout keeps .git as a directory; worktrees have a .git file.
  if [[ -d $target/.git ]]; then die "refusing to touch $target: it is a main checkout" 4; fi
}

guard_root() {
  local d
  guard_path "$ROOT"
  d=$(abspath "$ROOT")
  while [[ $d != / ]]; do
    [[ -d $d/.git ]] && die "workbench.root $ROOT is inside the checkout $d; put it outside any repo" 4
    d=$(dirname "$d")
  done
}

store_of() { printf '%s/%s.git' "$STORES" "$1"; }
tree_of() { printf '%s/%s/%s' "$TREES" "$2" "$1"; }

db_vars() {
  local task=$1 db
  db=$(render "$(conf_get database.name "${STACK}_{name}")" "name=$task" "stack=$STACK")
  db=${db//[^A-Za-z0-9_]/_}
  DBV=("name=$task" "stack=$STACK" "db=$db" "template=$(conf_get database.template)")
}

run_template() {
  local key=$1 task=$2 tpl cmd
  tpl=$(conf_get "database.$key")
  [[ -z $tpl ]] && { say "database.$key is not set; skipping"; return 0; }
  db_vars "$task"
  cmd=$(render "$tpl" "${DBV[@]}")
  say "+ $cmd"
  bash -c "$cmd" || die "database.$key failed for $task"
}

cmd_init() {
  local src=${1:?usage: init <checkout> [<repo-name>]} name store url
  src=$(abspath "$src")
  git -C "$src" rev-parse --git-dir >/dev/null 2>&1 || die "$src is not a git checkout"
  src=$(git -C "$src" rev-parse --show-toplevel)
  name=${2:-$(basename "$src")}
  valid repo-name "$name"
  guard_root
  store=$(store_of "$name")
  [[ $store == "$src" || $store == "$src"/* ]] && die "the store would land inside $src" 4
  mkdir -p "$STORES" "$TREES"
  if [[ ! -d $store ]]; then
    # Read-only on the source: a local bare clone shares its objects by hard link.
    git clone --quiet --bare --local "$src" "$store" || die "clone failed"
    git --git-dir="$store" config wb.source "$src"
    url=$(git -C "$src" remote get-url origin 2>/dev/null || true)
    git --git-dir="$store" remote set-url origin "${url:-$src}"
    git --git-dir="$store" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
    say "created $store"
  fi
  git --git-dir="$store" fetch --quiet --prune origin || say "warning: fetch from origin failed; using what the store has"
  say "$name: $(git --git-dir="$store" for-each-ref refs/remotes/origin | wc -l | tr -d ' ') remote refs"
}

cmd_add() {
  local db=1 args=() a
  for a in "$@"; do [[ $a == --no-db ]] && db=0 || args+=("$a"); done
  set -- "${args[@]}"
  local name=${1:?usage: add <repo-name> <task> [<ref>]} task=${2:?usage: add <repo-name> <task> [<ref>]} ref=${3:-$DEFAULT_REF}
  valid repo-name "$name"; valid task "$task"
  guard_root
  local store tree branch
  store=$(store_of "$name"); tree=$(tree_of "$name" "$task")
  [[ -d $store ]] || die "no store for $name; run: $(basename "$0") init <checkout> $name"
  guard_path "$tree"
  [[ -e $tree ]] && die "$tree already exists"
  git --git-dir="$store" rev-parse --verify --quiet "$ref^{commit}" >/dev/null \
    || ref=$(git --git-dir="$store" rev-parse --verify --quiet "HEAD^{commit}") \
    || die "ref $3 not found in $store"
  branch="$BRANCH_PREFIX$task"
  mkdir -p "$(dirname "$tree")"
  if git --git-dir="$store" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
    git --git-dir="$store" worktree add --quiet "$tree" "$branch" || die "worktree add failed"
  else
    git --git-dir="$store" worktree add --quiet -b "$branch" "$tree" "$ref" || die "worktree add failed"
  fi
  say "worktree: $tree (branch $branch)"
  ((db)) && run_template clone "$task"
  say "next: cd $tree && eval \"\$($SCRIPT_DIR/local-stack.sh reserve $task)\""
  printf '%s\n' "$tree"
}

cmd_db() { local task=${1:?usage: db <task>}; valid task "$task"; run_template clone "$task"; }

cmd_rm() {
  local drop=0 args=() a
  for a in "$@"; do [[ $a == --drop-db ]] && drop=1 || args+=("$a"); done
  set -- "${args[@]}"
  local name=${1:?usage: rm <repo-name> <task>} task=${2:?usage: rm <repo-name> <task>}
  valid repo-name "$name"; valid task "$task"
  local store tree
  store=$(store_of "$name"); tree=$(tree_of "$name" "$task")
  guard_path "$tree"
  [[ -d $store ]] || die "no store for $name"
  if [[ -e $tree ]]; then
    [[ -f $tree/.git ]] || die "$tree is not a worktree; not removing it" 4
    git --git-dir="$store" worktree remove --force "$tree" || die "worktree remove failed"
    rmdir "$TREES/$task" 2>/dev/null || true
    say "removed $tree (branch $BRANCH_PREFIX$task kept in the store)"
  else
    git --git-dir="$store" worktree prune
    say "no worktree at $tree"
  fi
  ((drop)) && run_template drop "$task"
  return 0
}

cmd_list() {
  local store
  for store in "$STORES"/*.git; do
    [[ -d $store ]] || { echo "no stores under $STORES"; return 0; }
    printf '%s  (source: %s)\n' "$(basename "$store" .git)" "$(git --git-dir="$store" config --get wb.source)"
    git --git-dir="$store" worktree list | tail -n +2 | sed 's/^/  /'
  done
}

case ${1:-help} in
  init) shift; cmd_init "$@" ;;
  add)  shift; cmd_add "$@" ;;
  db)   shift; cmd_db "$@" ;;
  rm)   shift; cmd_rm "$@" ;;
  path) shift; tree_of "${1:?repo-name}" "${2:?task}"; echo ;;
  list) cmd_list ;;
  -h|--help|help) sed -n '2,/^set -uo/{/^set -uo/d;s/^# \{0,1\}//;p;}' "$0" ;;
  *) die "unknown command '$1' (try --help)" ;;
esac
