# harbormaster — design (v2: caller-owned sandboxes)

Status: **live on `main`.** Caller-owned sandboxes are the shipped model. Validated
end-to-end: acquire/exec boot + owner-death reap + PID-reuse guard, and concurrent
same-project suites coexist with isolated data *and* websocket ports (the 9150-collision
fix). Consumers (impulse + walk2gether CI/test lanes) run against it.

## The problem

One machine runs emulators for an open-ended set of Firebase projects — dev, CI, and
the agent-qa runner spinning up *customer* apps on demand. Two things kept biting:

1. **Port collisions.** Multiple processes booting `firebase emulators:start` on the
   same ports (a shared per-project port, or the default 8080/4400) fight and kill each
   other. `pkill` "fixes" it by nuking *everyone's* emulators — the exact antipattern a
   coordinator must eliminate.
2. **Data collisions.** Two processes sharing one project's emulator share its data —
   e.g. a `clearFirestoreData` in one wipes the other, or docs accumulate across test
   cases. Concurrent callers of "the impulse emulator" must NOT share an instance.

## The model: caller-owned sandboxes

There is **one primitive** — a caller asks for a sandbox and the daemon gives it a
private one, reclaimed when the caller exits:

```
acquire { cwd, owner_pid, owner_start, only? }  ->  { leaseId, ports, projectId }
```

- **Issuance is unique per caller, not per project.** Two processes that both "want an
  impulse emulator" get two independent suites (own block, own fresh data). No sharing,
  so no collision.
- **The lease is owned by the caller's process.** The daemon reaps the sandbox — kills
  the emulators, frees the block — when `owner_pid` dies. The caller's death *is* the
  release; there is nothing to remember to release, and never a reason to `pkill`.
- **No registry.** A "project" is just the `firebase.json` in `cwd`. `project_id` comes
  from `.firebaserc`. Ports come from a pool block. Nothing is hand-authored.
- **`firebase.json` is portless** — the daemon injects the block's ports into a temp
  config (`.firebase.brokered-*.json`, git-ignored). A bare `firebase emulators:start`
  is intentionally unsupported; everything goes through the daemon.
- **Discovery is the `acquire` response.** The owner gets its ports back and passes them
  to its app/tests via env (`acquire --env` prints `export FIREBASE_*_EMULATOR_PORT` +
  `GCLOUD_PROJECT`). There is no shared "project ports" lookup, because there is no
  shared instance.

## Three flavors

- **`acquire` — the daemon boots the suite.** For callers that just want a working
  backend (a test process, an interactive dev shell). Returns the ports.
- **`allocate` — the daemon reserves a block; the caller boots its own suite.** For the
  agent-qa run driver (`envs/_lib/backends/firebase-emulators.sh`), which has bespoke
  build/wipe/seed logic. Returns a base; the driver derives ports by the block offsets.
- **`allocate --spawn CMD` — the daemon RUNS the lease's process.** For long-lived
  dev-env processes (Metro for e2e) that must outlive the calling shell — in
  particular agent sessions, whose harness kills any process the agent backgrounds.
  The lease is ownerless (daemon-owned): liveness is the spawned pid (zombie-aware —
  the daemon `waitpid`s its own children, since a zombie passes `kill -0`), the TTL is
  the backstop, and `release <id>` is the off switch. Spawn output goes to the lease
  log in the state dir.

`acquire` and plain `allocate` carry an `owner_pid` and are reaped the same way;
`--spawn`/`--detach` leases default to no owner, because their *immediate* parent
exits within seconds of the call and would reap the lease with it.

That default proved too coarse. "Daemonised" decides who reaps the child; it does
not mean nobody is interested. `--owner auto` walks up from the CLI past the
transient shell/npm wrappers and records the first ancestor that outlives the
call — under an agent harness, the agent process — so the lease dies with that
session instead of lingering for its full multi-day TTL. It deliberately returns
*no* owner when the walk reaches a boundary like an editor or a login session,
rather than pretending a process that lives for days is a meaningful owner.

## Daemon version handover

Any copy of the CLI (a global install, a repo checkout, some project's
`node_modules`) may be the first to start the daemon, so the daemon on port 4999 can
be arbitrarily stale. `/health` reports the daemon version; `_ensure` in a NEWER
client POSTs `/shutdown` to an older daemon and starts its own copy. This is safe by
construction: leases live in the ledger on disk, and every leased process (suites,
spawns) runs in its own session via `start_new_session`, so the successor daemon
reloads the ledger and carries on — the handover tears nothing down. Older clients
never downgrade a newer daemon.

## Ownership & teardown (coordinated only — never `pkill`)

A lease is reclaimed when ANY of:

1. **Owner death** — `owner_pid` is gone. This is the primary, expected path.
2. **PID reuse guard** — "alive" means *same pid AND same start time* (`ps -o lstart`),
   so a recycled PID number doesn't keep a dead owner's sandbox alive.
3. **Working directory gone** — the lease's `cwd` no longer exists. A deleted
   worktree can never need its Metro again, and this is the one signal that is
   unambiguous for daemon-spawned leases. Only a *confirmed* absence counts: if
   the parent directory is missing too, that reads as an unmounted volume rather
   than a deleted project, and the lease is left alone.
4. **TTL** — a backstop for a caller that never dies (misconfigured / detached).
5. **Emulator liveness** — dead suite process → reaped immediately; ports down (with
   the process alive) only reap after a grace window of continuous downtime, for both
   daemon-booted suites and reserved (caller-booted) blocks. A single failed connect
   check on a loaded machine must never kill a healthy suite.

Teardown frees the lease's **resources**, not just the process the daemon spawned —
because the spawned process's group is provably not enough. v2 shipped assuming
"`killpg` reaps the JVM children"; it doesn't: firebase-tools spawns its downloadable
emulators and functions workers with `detached: true`, i.e. **their own process
groups**, which `killpg` on the suite's group can structurally never reach. That
false assumption leaked 51 Firestore JVMs and 284 functions workers on one machine
before it was caught (2026-07-29). Teardown in v0.7 is therefore layered:

1. `killpg` the recorded group (TERM → wait on **group** emptiness, not parent
   death → KILL), guarded against PID reuse by the spawn-time start time.
2. **Tree sweep** (v0.9): while a lease's root lives, its detached children
   still report it as `ppid` — setsid changes the group, not the parent — so
   the reaper tick records the observed descendant tree as `(pid, start-time)`
   pairs in the ledger. Teardown kills the recorded tree, start re-checked at
   kill time. This is what catches the non-listening functions workers that
   the group kill structurally misses and the port sweep can't see.
3. **Port sweep**: anything still LISTENing on any port of the lease's block is
   killed (TERM → KILL). The block *is* the lease — this catches detached JVMs,
   the caller's own Metro on the leased port, and anything else that squatted.
4. Verify the block's ports are actually free, and log every action taken —
   a teardown that leaves a listener behind says so instead of pretending.

Beyond per-lease teardown, the daemon reconciles **both directions**: the ledger
against the world (as before), and the world against the ledger — at startup and
every `FBPORTS_SWEEP_INTERVAL` (300s) it looks for listeners on pool ports no
lease covers, firebase-tools runtimes re-parented to pid 1 (the
detached-children signature: `functionsEmulatorRuntime`,
`cloud-firestore-emulator*.jar`, …), and `run-*`/`alloc-*` simulators with no
lease. `harbormaster doctor [--fix]` runs the same sweep on demand.

Finding and killing are separate verdicts (v0.9). Everything above is worth
*reporting*, but the sweep evicts only what it can positively attribute to
itself: a pid in a recorded lease tree (start-time re-checked), a cmdline
naming the `.firebase.brokered-*` config only harbormaster writes, or a sim
whose UDID is in the daemon's own `authored-sims.json` (written at create,
kept separate from the ledger so a lost ledger orphans leases, not
attribution). "Looks like it might have come from us" is not attribution —
v0.8's lease-shaped heuristic killed a resident ollama whose default port sat
inside the pool, and `run-*` name-matching had two daemons on one machine
deleting each other's simulators. Unattributed findings are reported by
`doctor` and never signalled; the daemon owns lifecycle end-to-end, callers
use `acquire`/`release`, never `pkill`.

The ledger itself is written atomically (temp + rename) and a corrupt ledger is
quarantined loudly instead of silently zeroed — with the world sweep adopting
whatever a lost ledger orphaned. Suites are registered in the ledger at spawn
time (state `booting`), not after the readiness wait, so a daemon crash mid-boot
can no longer strand a running suite outside the ledger.

## Owning PID is the caller, not the CLI

`harbormaster acquire` is ephemeral — it exits the moment it has the response. So the
CLI defaults `owner_pid` to **its parent** (`os.getppid()` — the calling shell or test
runner), or the caller passes `--owner PID` explicitly (`$$` in a shell, `process.pid`
in node). The sandbox lives as long as that owner does.

## API

```
POST /acquire   {cwd, owner_pid, owner_start, only?, ttl?}  -> {leaseId, ports, projectId}
POST /allocate  {owner_pid, owner_start, ttl?, label?}      -> {leaseId, base}
POST /release   {leaseId}                                   -> {released}
POST /heartbeat {leaseId, ttl?}                             -> {ok}          # extend TTL
GET  /status                                               -> {leases:[...]}
GET  /health
POST /shutdown
POST /doctor    {fix?}                                      -> {findings, fixed, leases}
```

CLI: `acquire` / `up` (alias) / `down` (release your lease) / `release <id>` / `status`
/ `leases` / `allocate` / `serve`. Pool: blocks of 20 ports from 11000–14999, offsets
`auth=+0 firestore=+1 functions=+2 storage=+3 ui=+4 hub=+5 logging=+6 pubsub=+7
eventarc=+8 database=+9` (kept in sync with the run driver's derivation).

## What changes from v1

- Drop the registry (`~/.config/harbormaster.json`) and `list`/`apply`/`check`.
- Drop sticky-per-project (`up`/`ports` as a shared instance). Everything is a
  caller-owned lease.
- `firebase.json` everywhere is portless (already done for agent-qa/impulse/walk2gether/
  tuturno on their branches).
- Consumers (`app.config`, scrub scripts, CLAUDE.md tables) stop hard-coding ports and
  instead `eval "$(harbormaster acquire --cwd . --env)"` (owner = their process).

## Open items before this goes live

- Validate `acquire` boots + owner-death reap + PID-reuse guard on a quiet machine.
- ~~Confirm `killpg` reaps JVM children (fix the v1 leak if not).~~ Confirmed NOT
  reaped (detached groups); fixed in v0.7 by the port sweep + world sweep, with
  regression coverage in `test/e2e.sh` (release-path and crash-path both assert
  the detached firestore JVM dies and the ports free).
- Migrate the agent-qa run driver to pass `owner_pid` to `/allocate`.
- Migrate the app.config / scrub-script / CLAUDE.md consumers to `acquire --env`.
