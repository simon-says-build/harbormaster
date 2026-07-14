# firebase-ports

Coordinate Firebase emulator ports across many projects on one machine — a small
registry + an idempotent `up`/`down`/`status` CLI + an on-demand broker that hands
out port **blocks** from a pool and owns the emulator lifecycle.

If you run several Firebase projects locally (dev, tests, CI, agents) you've hit
this: emulators fight over ports, `firebase emulators:start` collides with another
one already up, and a stray `pkill -f emulators:start` nukes *everyone's*. This tool
makes emulator startup **coordinated and idempotent** so that stops happening.

## Install

It's a single Python 3 script (stdlib only) — put it on your `PATH`:

```bash
curl -o ~/.local/bin/firebase-ports https://raw.githubusercontent.com/<you>/firebase-ports/main/firebase-ports
chmod +x ~/.local/bin/firebase-ports
```

Requires `python3` and the `firebase` CLI.

## The registry

`~/.config/firebase-ports.json` maps each project to a fixed port allocation. See
[`firebase-ports.example.json`](firebase-ports.example.json). Per-project fields:

| field | meaning |
|---|---|
| `path` | project root (used to auto-detect the project from your cwd) |
| `firestore`/`auth`/`storage`/`functions`/`pubsub`/`ui` | the emulator ports |
| `cwd` | dir to launch `firebase emulators:start` in (default: `path`) — the one with `firebase.json` |
| `project_id` | passed as `--project` (default: read from `.firebaserc`) |
| `only` | services for `--only` (default: everything in `firebase.json`) |
| `config` | alternate config file, e.g. `firebase.e2e.json`, for an isolated second instance |

Tip: pin each project's emulator `hub`/`logging` ports (in its `firebase.json`) to a
private lane, so multiple projects' suites can run at once without colliding on the
default 4400/4500.

## Commands

### Direct lifecycle (simple, per-project)

```bash
firebase-ports up [project] [--fresh|--json|--env]   # ensure up: reuse if healthy, else boot + wait until ready
firebase-ports down [project]                          # stop what THIS tool started (never touches others)
firebase-ports status [project]                        # health-checked view of what's up
```

`up` is idempotent and safe to run before every test run. It refuses to boot if the
ports are held by an *unmanaged* process (rather than double-booting). `--env` prints
`export FIREBASE_<SVC>_EMULATOR_PORT=` (and `GCLOUD_PROJECT`) lines for `eval`.

### Registry maintenance

```bash
firebase-ports list             # all allocations
firebase-ports apply [project]  # write the ports into the project's firebase.json
firebase-ports check [project]  # scan for hard-coded ports that don't match the registry
```

### Broker — on-demand allocation for *any* project

For concurrency (parallel test runs, CI, agents) a fixed per-project port doesn't
work — you might run the same project's suite several times at once, each needing its
own isolated data. The broker allocates **port blocks from a pool** on demand and owns
their lifecycle.

```bash
firebase-ports serve            # the localhost:4999 daemon (auto-starts on first acquire)

firebase-ports acquire [project]                       # SHARED lease: stable ports (seeded from the registry), reused
firebase-ports acquire --isolated --cwd DIR --only …   # ISOLATED lease: a fresh block + fresh data, TTL-reaped
firebase-ports release <leaseId>                       # tear down / release
firebase-ports ports <project>                         # discover a shared project's ports + project id
firebase-ports leases                                  # active leases
firebase-ports allocate [--ttl N]                      # reserve a free block WITHOUT booting (for callers that boot their own suite)
```

- **Shared** leases are sticky — a project keeps stable, discoverable ports (great for
  dev; new projects auto-get a free block on first use, remembered thereafter).
- **Isolated** leases are ephemeral — a fresh block + clean data per call, reclaimed by
  TTL *and* by liveness (once the run's ports have been up and then stay down, the block
  is returned automatically — crash/kill/reboot-safe).
- **`allocate`** is reserve-only: coordinated, verified-free block reservation for a
  caller (e.g. a CI/agent runner) that generates its own emulator config and boots it.
- Consumers **discover** ports and the project id (`acquire` response / `ports`) instead
  of hard-coding them.

## Gotcha: `singleProjectMode` + project ids

With `singleProjectMode`, the Firestore emulator funnels **writes** from any project id
into one datastore — but project-scoped admin endpoints (`clearFirestoreData`,
import/export, rules) still key off the id in the request. So a client using a different
project id than the emulator booted as will *write fine but fail to clear* (silent
no-op). Keep the id consistent: the emulator's `--project`, every client's `projectId`,
and any `clearFirestoreData({projectId})` must match. `firebase-ports ports <project>`
tells you the id the emulator actually booted as.

## License

MIT — see [LICENSE](LICENSE).
