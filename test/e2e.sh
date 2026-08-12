#!/bin/bash
# End-to-end test for harbormaster's resource sweep and teardown.
# Isolated daemon: own port, own state dir, own DISJOINT pool (15100-15199) —
# never touches the real daemon on 4999 or its 11000-14999 pool.
# Needs: a firebase project for the acquire tests (FBPORTS_TEST_PROJECT,
# default ~/impulse/impulse-functions), Xcode simctl, java for the emulator.
set -u
HM="$(cd "$(dirname "$0")/.." && pwd)/harbormaster"
S="${TMPDIR:-/tmp}/harbormaster-e2e-$$"
mkdir -p "$S"
trap 'rm -rf "$S"' EXIT
export FBPORTS_PORT=5999
export FBPORTS_STATE_DIR="$S/hm-state"
export FBPORTS_POOL_BASE=15100
export FBPORTS_POOL_BLOCKS=5
export FBPORTS_REAP_INTERVAL=2
export FBPORTS_SWEEP_INTERVAL=99999
rm -rf "$FBPORTS_STATE_DIR"; mkdir -p "$FBPORTS_STATE_DIR" "$S/bin"
PASS=0; FAIL=0
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then echo "PASS: $name"; PASS=$((PASS+1)); else echo "FAIL: $name"; FAIL=$((FAIL+1)); fi; }
not() { ! "$@"; }

"$HM" serve > "$S/hm-test-daemon.log" 2>&1 &
DPID=$!
sleep 2
check "daemon up, version matches client" bash -c "curl -s localhost:5999/health | grep -qF \"$("$HM" version)\""

# --- fabricate leaks that are NOT harbormaster's ------------------------------
# None of these were spawned by the daemon, so under the authorship rule every
# one must be REPORTED and none may be killed — even the ones that look exactly
# like firebase-tools escapees. Only the run-*/alloc-* sim (harbormaster's own
# naming) is evictable.
python3 -c '
import socket, time, os
if os.fork(): os._exit(0)
os.setsid()
s = socket.socket(); s.bind(("127.0.0.1", 15105)); s.listen()
time.sleep(600)' &
nc -l 127.0.0.1 15107 >/dev/null 2>&1 &
BYSTANDER=$!
printf '#!/bin/sh\nsleep "$1"\n' > "$S/bin/functionsEmulatorRuntime"; chmod +x "$S/bin/functionsEmulatorRuntime"
python3 -c "
import os, sys
if os.fork(): os._exit(0)          # orphan the grandchild to pid 1
os.setsid()
os.execv('$S/bin/functionsEmulatorRuntime', ['$S/bin/functionsEmulatorRuntime', '600'])"
# Two run-* sims, both created OUT OF BAND (not by the test daemon). One gets
# its UDID injected into the daemon's authored-sims registry — "this daemon
# created it" — and must be evicted; the other stays unregistered and must
# survive: on a machine running a production broker next to this suite, that
# is not hypothetical (2026-08-12: the real 4999 daemon deleted this suite's
# name-matched fixtures mid-test).
SIM_THEIRS=$(xcrun simctl create run-sweeptest "iPhone 16" com.apple.CoreSimulator.SimRuntime.iOS-18-2 2>/dev/null)
SIM_OURS=$(xcrun simctl create run-authored "iPhone 16" com.apple.CoreSimulator.SimRuntime.iOS-18-2 2>/dev/null)
python3 -c "
import json, pathlib
p = pathlib.Path('$FBPORTS_STATE_DIR/authored-sims.json')
sims = set(json.loads(p.read_text())) if p.exists() else set()
sims.add('$SIM_OURS')
p.write_text(json.dumps(sorted(sims)))"
for i in $(seq 1 30); do
  LPID=$(lsof -ti tcp:15105 -sTCP:LISTEN | head -1)
  OPID=$(pgrep -f "functionsEmulatorRuntime 600" | head -1)
  [ -z "$OPID" ] && OPID=$(pgrep -f "bin/functionsEmulatorRuntime" | head -1)
  SIMOK=$(xcrun simctl list devices 2>/dev/null | grep -c "run-sweeptest\|run-authored")
  [ -n "$LPID" ] && [ -n "$OPID" ] && [ "$SIMOK" -ge 2 ] && break
  sleep 2
done
check "fake pool listener alive" test -n "$LPID"
check "fake orphan alive with ppid 1" bash -c "[ -n '$OPID' ] && [ \"\$(ps -o ppid= -p $OPID | tr -d ' ')\" = '1' ]"
check "both fake sims exist" bash -c "[ \"\$(xcrun simctl list devices | grep -c 'run-sweeptest\|run-authored')\" -ge 2 ]"

# --- doctor: everything reported, exit 1 --------------------------------------
OUT=$("$HM" doctor 2>&1); RC=$?
echo "--- doctor output ---"; echo "$OUT"; echo "---"
check "doctor reports pool listener" bash -c "echo '$OUT' | grep -q 'port 15105'"
check "doctor reports nc bystander" bash -c "echo '$OUT' | grep 'port 15107' | grep -q 'not provably ours'"
check "doctor reports orphan runtime" bash -c "echo '$OUT' | grep -q \"orphan.*pid $OPID\""
check "doctor marks orphan unattributed" bash -c "echo '$OUT' | grep \"pid $OPID\" | grep -q 'not provably ours'"
# simctl's JSON listing can lag a fresh create by a beat; retry the report-only
# doctor rather than assert on the first read (production cadence is 300s).
SIMOUT="$OUT"
for i in 1 2 3; do
  echo "$SIMOUT" | grep -q run-authored && echo "$SIMOUT" | grep -q run-sweeptest && break
  sleep 1; SIMOUT=$("$HM" doctor 2>&1)
done
check "doctor reports authored stray sim" bash -c "echo '$SIMOUT' | grep -q 'run-authored'"
check "doctor marks foreign sim unattributed" bash -c "echo '$SIMOUT' | grep 'run-sweeptest' | grep -q 'not provably ours'"
check "doctor exits 1 when unfixed" test "$RC" = "1"

# --- doctor --fix: only what harbormaster authored dies -----------------------
"$HM" doctor --fix >/dev/null 2>&1
sleep 2
check "unattributed listener survives fix" kill -0 "$LPID"
check "nc bystander survives fix" kill -0 "$BYSTANDER"
check "unattributed orphan survives fix (signature is not authorship)" kill -0 "$OPID"
check "authored stray sim deleted by fix" bash -c "! xcrun simctl list devices | grep -q run-authored"
check "foreign sim survives fix" bash -c "xcrun simctl list devices | grep -q run-sweeptest"
check "deleted sim removed from registry" bash -c "! grep -q '$SIM_OURS' '$FBPORTS_STATE_DIR/authored-sims.json'"
xcrun simctl delete "$SIM_THEIRS" >/dev/null 2>&1
kill "$LPID" "$OPID" "$BYSTANDER" 2>/dev/null

# --- authored escapee: the recorded tree must catch what killpg cannot --------
# The daemon spawns the lease root; the root fathers a child that setsids into
# its own session (exactly how firebase-tools' functions workers escape), and
# it never listens on a port. Group kill can't reach it, port sweep can't see
# it. Only the tree recorded by the reaper tick can — this is the mechanism
# that ends the two-workers-leaked-per-run era.
# A wrapper script, not a copied binary: macOS AMFI kills platform binaries
# copied out of place, and a copied /bin/sleep dies on exec.
printf '#!/bin/sh\nsleep "$1"\n' > "$S/bin/authored-escapee"; chmod +x "$S/bin/authored-escapee"
cat > "$S/bin/spawnroot.sh" << EOF
#!/bin/sh
exec python3 -c "
import subprocess, time
subprocess.Popen(['$S/bin/authored-escapee', '600'], start_new_session=True)
time.sleep(300)
"
EOF
chmod +x "$S/bin/spawnroot.sh"
sleep 600 & OWNER2=$!
"$HM" allocate --owner $OWNER2 --ttl 120 --spawn "$S/bin/spawnroot.sh" >/dev/null 2>&1
sleep 7                              # >= 2 reaper ticks so the tree is recorded
ESC=$(pgrep -f "bin/authored-escapee 600" | head -1)
check "escapee alive, leader of its own group (killpg-proof)" bash -c "[ -n '$ESC' ] && [ \"\$(ps -o pgid= -p $ESC | tr -d ' ')\" = '$ESC' ]"
check "escapee recorded in lease tree" bash -c "grep -q '\"$ESC\"' '$FBPORTS_STATE_DIR/ledger.json'"
kill -9 "$OWNER2"
sleep 8
check "lease reaped after owner death" python3 -c "import json,sys; sys.exit(0 if not json.load(open('$FBPORTS_STATE_DIR/ledger.json'))['leases'] else 1)"
check "authored escapee killed via recorded tree" not kill -0 "$ESC"

# --- regression 1: normal release must kill the DETACHED firestore JVM --------
sleep 600 & OWNER=$!
eval "$("$HM" acquire --cwd "${FBPORTS_TEST_PROJECT:-$HOME/impulse/impulse-functions}" --only firestore --owner $OWNER --env 2>/dev/null)"
FSPORT=${FIRESTORE_EMULATOR_HOST##*:}
JAVA=$(lsof -ti tcp:"$FSPORT" -sTCP:LISTEN | head -1)
NODEPID=$(python3 -c "import json; print(list(json.load(open('$FBPORTS_STATE_DIR/ledger.json'))['leases'].values())[0]['pid'])")
LID=$(python3 -c "import json; print(list(json.load(open('$FBPORTS_STATE_DIR/ledger.json'))['leases'])[0])")
check "suite acquired, java on leased port" test -n "$JAVA"
check "java IS detached from suite group" bash -c "[ \"\$(ps -o pgid= -p $JAVA | tr -d ' ')\" != \"\$(ps -o pgid= -p $NODEPID | tr -d ' ')\" ]"
"$HM" release "$LID" >/dev/null 2>&1
sleep 2
check "release kills detached java (the v1 leak)" not kill -0 "$JAVA"
check "release frees firestore port" bash -c "! lsof -ti tcp:$FSPORT -sTCP:LISTEN | grep -q ."

# --- regression 2: parent SIGKILL (crash) — reaper must still clean the JVM ---
eval "$("$HM" acquire --cwd "${FBPORTS_TEST_PROJECT:-$HOME/impulse/impulse-functions}" --only firestore --owner $OWNER --env 2>/dev/null)"
FSPORT2=${FIRESTORE_EMULATOR_HOST##*:}
JAVA2=$(lsof -ti tcp:"$FSPORT2" -sTCP:LISTEN | head -1)
NODE2=$(python3 -c "import json; print(list(json.load(open('$FBPORTS_STATE_DIR/ledger.json'))['leases'].values())[0]['pid'])")
kill -9 "$NODE2"
sleep 8
check "lease reaped after parent SIGKILL" python3 -c "import json,sys; sys.exit(0 if not json.load(open('$FBPORTS_STATE_DIR/ledger.json'))['leases'] else 1)"
check "orphaned java killed by port sweep" not kill -0 "$JAVA2"
check "port freed after crash reap" bash -c "! lsof -ti tcp:$FSPORT2 -sTCP:LISTEN | grep -q ."

kill "$OWNER" 2>/dev/null
curl -s -X POST localhost:5999/shutdown >/dev/null 2>&1
sleep 1; kill "$DPID" 2>/dev/null
echo "=== daemon log ==="
cat "$S/hm-test-daemon.log"
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" = 0 ]
