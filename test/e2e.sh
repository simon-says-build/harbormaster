#!/bin/bash
# End-to-end test for harbormaster 0.7.0 resource-sweep changes.
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

# --- fabricate leaks ---
python3 -c '
import socket, time, os
if os.fork(): os._exit(0)
os.setsid()
s = socket.socket(); s.bind(("127.0.0.1", 15105)); s.listen()
time.sleep(600)' &
# A BYSTANDER on a pool port: nc is not node/java/python, so the sweep must
# report it and refuse to kill it (the ollama-on-11434 case).
nc -l 127.0.0.1 15107 >/dev/null 2>&1 &
BYSTANDER=$!
printf '#!/bin/sh\nsleep "$1"\n' > "$S/bin/functionsEmulatorRuntime"; chmod +x "$S/bin/functionsEmulatorRuntime"
python3 -c "
import os, sys
if os.fork(): os._exit(0)          # orphan the grandchild to pid 1
os.setsid()
os.execv('$S/bin/functionsEmulatorRuntime', ['$S/bin/functionsEmulatorRuntime', '600'])"
xcrun simctl create run-sweeptest "iPhone 16" com.apple.CoreSimulator.SimRuntime.iOS-18-2 >/dev/null 2>&1
for i in $(seq 1 30); do
  LPID=$(lsof -ti tcp:15105 -sTCP:LISTEN | head -1)
  OPID=$(pgrep -f "functionsEmulatorRuntime 600" | head -1)
  [ -z "$OPID" ] && OPID=$(pgrep -f "bin/functionsEmulatorRuntime" | head -1)
  SIMOK=$(xcrun simctl list devices 2>/dev/null | grep -c run-sweeptest)
  [ -n "$LPID" ] && [ -n "$OPID" ] && [ "$SIMOK" -ge 1 ] && break
  sleep 2
done
check "fake pool listener alive" test -n "$LPID"
check "fake orphan alive with ppid 1" bash -c "[ -n '$OPID' ] && [ \"\$(ps -o ppid= -p $OPID | tr -d ' ')\" = '1' ]"
check "fake sim exists" bash -c "xcrun simctl list devices | grep -q run-sweeptest"

# --- doctor: report without fixing, exit 1 ---
OUT=$("$HM" doctor 2>&1); RC=$?
echo "--- doctor output ---"; echo "$OUT"; echo "---"
check "doctor reports pool listener" bash -c "echo '$OUT' | grep -q 'port 15105'"
check "doctor reports bystander as such" bash -c "echo '$OUT' | grep 'port 15107' | grep -q 'bystander'"
check "doctor reports orphan runtime" bash -c "echo '$OUT' | grep -q \"orphan.*pid $OPID\""
check "doctor reports stray sim" bash -c "echo '$OUT' | grep -q 'run-sweeptest'"
check "doctor exits 1 when unfixed" test "$RC" = "1"
check "fakes survive report-only doctor" kill -0 "$LPID"

# --- doctor --fix evicts everything ---
"$HM" doctor --fix >/dev/null 2>&1
sleep 2
check "listener evicted by fix" not kill -0 "$LPID"
check "bystander survives fix" kill -0 "$BYSTANDER"
check "orphan evicted by fix" not kill -0 "$OPID"
check "stray sim deleted by fix" bash -c "! xcrun simctl list devices | grep -q run-sweeptest"

# --- regression 1: normal release must kill the DETACHED firestore JVM ---
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

kill "$OWNER" "$BYSTANDER" 2>/dev/null
curl -s -X POST localhost:5999/shutdown >/dev/null 2>&1
sleep 1; kill "$DPID" 2>/dev/null
echo "=== daemon log ==="
cat "$S/hm-test-daemon.log"
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" = 0 ]
