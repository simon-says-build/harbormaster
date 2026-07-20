# firebase-ports

A localhost daemon that hands each **caller** its own isolated Firebase emulator
sandbox — a pool-assigned port block plus fresh data — and reclaims it when the
caller's process exits.

If you run several Firebase projects locally (dev, tests, CI, agents) you know the
pain: emulators fight over ports, a bare `firebase emulators:start` collides with
another suite, and `pkill` "fixes" it by nuking *everyone's* emulators. firebase-ports
removes the collision entirely — two callers that both want "an impulse emulator" get
two independent suites (own ports, own data), so they never step on each other.

```
$ eval "$(firebase-ports acquire --cwd ./my-app --only auth,firestore --env)"
$ echo $FIRESTORE_EMULATOR_HOST
127.0.0.1:11001
# ...run your tests against the suite...
# it's torn down automatically when this shell exits
```

## Requirements

- **Python 3.8+** — the daemon is a single Python script (`#!/usr/bin/env python3`).
  npm just ships and links the executable; it must be able to find `python3` on PATH.
- **firebase-tools** (`firebase`) on PATH — it boots the actual emulators.
- macOS or Linux.

## Install

```bash
npm install -g firebase-ports        # global CLI
# or add it to a project so it ships with your app/agent:
npm install firebase-ports           # → node_modules/.bin/firebase-ports
```

## Usage

The daemon auto-starts on the first command. `firebase.json` ports are **optional** —
the daemon injects (and overrides) a pool block into a temp config per lease, so you
never hand-assign a port.

```bash
# Boot a private suite for the project in DIR, owned by the calling shell,
# reaped when it exits. --env prints exports to eval into your shell:
eval "$(firebase-ports acquire --cwd ./my-app --only auth,firestore,functions --env)"
#   → FIRESTORE_EMULATOR_HOST, FIREBASE_AUTH_EMULATOR_HOST, EMULATOR_<SVC>_PORT,
#     GCLOUD_PROJECT (from .firebaserc)

# Run a command inside a fresh suite that tears down after (great for CI):
firebase-ports exec --cwd ./my-app --only auth,firestore "npm test"

# Reserve a block WITHOUT booting — for a caller that starts its own suite:
firebase-ports allocate --json          # → { "leaseId": "...", "base": 11000 }

# Have the DAEMON run a long-lived process (Metro, a dev server) as the lease:
# daemon-owned, so it survives the calling shell / agent session. Liveness is the
# spawned pid (+ TTL backstop); stop it with `release`. CMD sees METRO_PORT,
# DETOX_UDID/DETOX_SIM_NAME (with --sim), FBPORTS_BLOCK_BASE, FBPORTS_LEASE_ID.
eval "$(firebase-ports allocate --sim --ttl 604800 \
        --spawn 'exec npx expo start --port "$METRO_PORT"' --cwd ./my-app --env)"
firebase-ports release "$FBPORTS_LEASE_ID"   # tears down Metro + the sim

firebase-ports status                    # everything the daemon has out
firebase-ports down --cwd ./my-app       # release this shell's lease early
```

`--json` on `acquire`/`allocate` returns the ports/base as JSON for scripting.

Version skew is self-healing: the daemon reports its version on `/health`, and a
newer client replaces an older daemon in place (leases persist in the ledger;
every leased process runs in its own session, so nothing is torn down by the
handover). A stale `node_modules` copy can no longer pin the machine to an old
daemon.

## How it works

- **Caller-owned.** One primitive: `acquire {cwd, owner_pid} → {ports, projectId}`.
  Issuance is unique per *caller*, not per project — so concurrent callers of the
  same project get independent suites.
- **Reaped on exit.** The daemon kills the suite (the whole process group, so the JVM
  children die too) when `owner_pid` dies. The caller's death *is* the release —
  nothing to remember, and never a reason to `pkill`. A TTL and emulator-liveness are
  backstops.
- **Pool ports.** Blocks of 20 from 11000–14999; each firestore suite also gets a
  private websocket port, so concurrent suites never collide on the default 9150.
- **No registry, no shared instances.** A "project" is just the `firebase.json` in
  `cwd`; the project id comes from `.firebaserc`.

See [DESIGN.md](./DESIGN.md) for the full architecture.

## License

MIT — see [LICENSE](./LICENSE).
