# local-stack

Run many isolated copies of a multi-service app on one machine, without collisions.
Each task, whether a person validating a pull request or an AI agent testing a fix,
gets its own ports, its own git worktree and its own database copy. Nobody's
running stack gets killed by someone else's.

## The problem

Most apps assume one copy runs per machine. The API is on 8000, the web app on
3000, everything talks to one local database. That holds until two things happen
at once:

- You validate a colleague's branch while your own stack is running.
- Two or three AI agents each try to "start the app and check the fix".

Then the second copy finds 8000 taken. A start script "helpfully" kills whatever
holds the port. That was your dev server. The agents seed test data into the same
database and read each other's rows. Someone switches branches in your main
checkout to test a pull request and leaves it there.

## Before and after

| Before | After |
|---|---|
| Every copy wants the same default ports | Each task reserves a slot: a whole port set, one port per service |
| Start scripts kill whatever holds a port | Nothing here ever kills a process; `check` tells you whose a port is |
| Agents could take the developer's ports | Slot 0 (the default ports) is never handed out |
| One shared local database | One database per task, cloned from a template |
| Branch switches in the main checkout | One disposable worktree per task; main checkouts are read-only to the tools |
| "Who is running on 3010?" | `status` shows slot, name, owner, repo, branch and state |

What it changes for a team: parallel work becomes the normal case. People and
agents stop waiting for each other, and stop breaking each other's environments.

## Quick start

```bash
git clone <this repo> local-stack && cd local-stack
./local-stack.sh ports                       # see the slot layout from local-stack.conf
eval "$(./local-stack.sh reserve my-task)"   # claim the lowest free slot, export its ports
./local-stack.sh status                      # who holds what
./local-stack.sh release my-task             # give it back
```

Requirements: bash 4+, coreutils, git, and `ss` or `lsof` (without either, a bash
`/dev/tcp` probe is used). `flock` is used when present; otherwise a `mkdir` lock.
Tested on Linux.

## How it works

**Slots.** Every service has a base port. Slot `n` gives each service
`base + stride * n`. With the Acme HR example:

```
SLOT  api        web        payroll
0     8000       3000       9000        (developer, never handed out)
1     8010       3010       9010
2     8020       3020       9020
...
```

A slot is claimed as a whole, so a task never ends up with the API from one slot and
the web app from another. The layout is checked at start-up: if two services would
share a port in any slot, the config is rejected.

**The registry.** One TSV file per machine (default
`~/.local/state/local-stack/registry.tsv`) records each reservation: stack, name,
slot, ports, owner, holder pid, repo, branch, working directory and time. Every
read-modify-write happens under a lock and the file is replaced atomically. Ten
parallel `reserve` calls get ten different slots. Several apps can share one
registry; a slot is also skipped when any of its ports is held by another stack or
by a process that never registered.

**Slot 0 guard.** The default ports belong to the developer's own stack. `reserve`
starts at slot 1 and fails with exit code 3 when slots run out. It never falls back
to the defaults. `check` on a slot 0 port reports it as reserved even when nothing
is listening.

**Stale reservations.** Each reservation records a holder pid (the calling shell by
default, or `--holder <pid>`). `gc` drops a reservation only when all three are
true: the holder is gone, none of the slot's ports is listening, and the grace
window (default 30 minutes, so a slow first build is not reclaimed) has passed.
`gc` never signals a process. The test suite checks that, and checks that the
script contains no `kill` other than `kill -0`.

**Workbenches.** `wb.sh` keeps one bare object store per repo and adds one git
worktree per task, so a new task costs a checkout, not a clone. It reads from your
main checkouts and never writes to them. It refuses a workbench root inside any git
checkout, refuses any path that overlaps a protected checkout, and only removes
directories that are real worktrees.

## Commands

### local-stack.sh

| Command | What it does |
|---|---|
| `status` | Table of slots: name, owner, repo, branch, state (`active`, `starting`, `stale`, `free`) and ports. Slot 0 shows which default ports are up. |
| `reserve <name> [--owner who] [--holder pid]` | Claims the lowest free slot and prints `export` lines on stdout. Same name again returns the same slot. Exit 3 when full. |
| `release <name>` | Removes the reservation. Processes are left running. |
| `check <port>` | Exit 0 if free. Otherwise names the listener (pid, repo and branch from its working directory) and the reservation that owns the port. |
| `gc [--dry-run]` | Drops stale reservations as defined above. |
| `env <name> <role>` | Exports for one service: all port variables, `PORT` for this role, stack exports and the role's own exports. |
| `ports` | Prints the slot layout. |

Environment overrides: `LOCAL_STACK_CONF`, `LOCAL_STACK_REGISTRY`,
`LOCAL_STACK_OWNER`, `LOCAL_STACK_GRACE`, `LOCAL_STACK_PORT_TOOL` (`ss`, `lsof`,
`probe`), `LOCAL_STACK_LOCK` (`flock`, `mkdir`), `NO_COLOR`.

### wb.sh

| Command | What it does |
|---|---|
| `init <checkout> [<repo-name>]` | Creates or refreshes `stores/<repo-name>.git`, a bare clone sharing objects with the checkout. Fetches from the checkout's `origin`. |
| `add <repo-name> <task> [<ref>] [--no-db]` | Adds `trees/<task>/<repo-name>` on branch `wb/<task>` and runs the database clone command. Prints the path. |
| `db <task>` | Runs the database clone command on its own. |
| `rm <repo-name> <task> [--drop-db]` | Removes the worktree (the branch stays in the store) and optionally drops the database. |
| `list` / `path <repo-name> <task>` | Shows stores and worktrees / prints one path. |

A full task, end to end:

```bash
./wb.sh init ~/code/acme-api
cd "$(./wb.sh add acme-api fix-payslip-rounding origin/main)"
~/local-stack/local-stack.sh reserve fix-payslip-rounding --holder $$ >/dev/null
eval "$(~/local-stack/local-stack.sh env fix-payslip-rounding api)"
# ... start the API on $PORT against $DATABASE_URL, run the checks ...
~/local-stack/local-stack.sh release fix-payslip-rounding
~/local-stack/wb.sh rm acme-api fix-payslip-rounding --drop-db
```

## Configuration reference

`local-stack.conf` is a small TOML subset: `[sections]`, `key = "string"`, numbers,
`true`/`false`, and one-line lists of strings. It is looked up at
`$LOCAL_STACK_CONF`, then `./local-stack.conf`, then next to the script. The shipped
file is a worked example for a fictional company, Acme HR, with three services.

| Key | Default | Meaning |
|---|---|---|
| `stack.name` | `default` | Registry key. Lets several apps share one registry. |
| `stack.slots` | `4` | Slots handed out (1..n). Slot 0 is always the developer's. |
| `stack.stride` | `10` | Port step between slots. |
| `stack.grace_seconds` | `1800` | A reservation is never stale before this age. |
| `stack.registry` | `~/.local/state/local-stack/registry.tsv` | Machine-wide registry file. |
| `stack.exports` | none | `KEY=value` lines exported for every role. |
| `service.<name>.port` | required | Base port (slot 0). |
| `service.<name>.stride` | `stack.stride` | Per-service step, if one service needs a different spacing. |
| `service.<name>.port_var` | `<NAME>_PORT` | Variable that carries this service's port. |
| `service.<name>.exports` | none | Extra `KEY=value` lines for `env <name> <role>`. |
| `database.template` | none | Database to copy for each task. |
| `database.name` | `<stack>_{name}` | Per-task database name. Non-alphanumerics become `_`. |
| `database.clone` | none | Command to create the copy, e.g. `createdb -T {template} {db}`. |
| `database.drop` | none | Command to drop it, e.g. `dropdb --if-exists {db}`. |
| `workbench.root` | `~/.local/share/local-stack/<stack>` | Holds `stores/` and `trees/`. Must be outside every git checkout. |
| `workbench.default_ref` | `origin/main` | What a new task branches from. |
| `workbench.branch_prefix` | `wb/` | Prefix for task branches. |
| `workbench.protected` | none | Your everyday checkouts. Store sources are protected automatically. |

Placeholders in exports and database commands: `{name}`, `{slot}`, `{stack}`,
`{db}`, `{template}`, `{port.<service>}`. Reservation and task names are limited to
letters, digits, `.`, `_` and `-`, so they are safe to substitute into commands.

The database commands are plain shell, so any engine works: `createdb -T`, a
`pg_dump | psql` pipe, `cp` of a SQLite file, or a container snapshot.

## Tests

```bash
tests/run.sh
```

Plain bash, no framework. The suite covers:

- 10 parallel `reserve` calls get 10 different slots, under both the `flock` and
  the `mkdir` lock, with no port appearing twice;
- over capacity, the extra calls fail with exit 3 and nothing is double-booked;
- slot 0 is never handed out, even when every other slot is taken;
- release then reserve reuses the freed slot (lowest first);
- `check` names the reservation, owner, service and slot, and the listener;
- `gc` drops only stale reservations, keeps ones whose ports are still served, and
  leaves every process running;
- `wb.sh` leaves the main checkout's branch, HEAD, status and branches unchanged,
  shares one object store across tasks, and refuses to work inside a checkout.

CI runs shellcheck and the suite once for each port-detection tool (`ss`, `lsof`,
and the `/dev/tcp` probe), then a demo with the shipped config.

## How it was used in practice

At an HR and payroll SaaS in the Gulf, the product ran as a backend, a gateway and
a web app over one local database. Feature validation moved to AI agents and to
engineers checking each other's branches, often several at once on one laptop.

Before, those runs collided. Two copies fought over the default ports. A start
script killed the process holding a port, and more than once that was a developer's
own dev server in the middle of their work. Agents seeded scenarios into the same
database and then failed on each other's data, which looked like product bugs.
Reviewers switched branches in their main checkouts to test a pull request and
left them on someone else's branch.

After, every task got a slot, a worktree and a database copy. The developer's own
stack kept the default ports, because no tool would hand them out. Up to four full
stacks ran side by side on one laptop. When a port looked busy, `check` named the
branch and the owner instead of anyone guessing. `gc` cleaned up after agents that
had exited, without stopping anything. The rule that tools never kill a process
they did not start became something the tooling enforced, not something people had
to remember.

## License

MIT. See [LICENSE](LICENSE).
