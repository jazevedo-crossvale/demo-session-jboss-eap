#!/usr/bin/env bash
# Failover test: session must survive both EAP pods restarting.
#
# Test criteria:
#   1. GET /session-demo/session  → Session ID = X, counter = 1
#   2. GET again (same cookies)   → Session ID = X, counter = 2
#   3. Kill BOTH EAP nodes
#   4. Restart BOTH EAP nodes
#   5. GET again (same cookies)   → Session ID MUST still be X, counter >= 2
#
# Prerequisites:
#   source env.sh  (sets WILDFLY_HOME, JAVA_HOME)
#   standalone.xml / standalone-node2 must already have HotRod CLI config applied.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WILDFLY_HOME="${WILDFLY_HOME:-/home/jazevedo/Downloads/wildfly-31.0.1.Final}"
WAR_SRC="$SCRIPT_DIR/session-demo/target/session-demo.war"
DEPLOY1="$WILDFLY_HOME/standalone/deployments/session-demo.war"
DEPLOY2="$WILDFLY_HOME/standalone-node2/deployments/session-demo.war"
LOG1="$SCRIPT_DIR/node1.log"
LOG2="$SCRIPT_DIR/node2.log"
COOKIES="$(mktemp /tmp/failover-test-XXXX.txt)"
NODE1_PID=""
NODE2_PID=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RESET='\033[0m'

fail() { echo -e "${RED}FAIL: $*${RESET}" >&2; exit 1; }
info() { echo -e "${YELLOW}==> $*${RESET}"; }
pass() { echo -e "${GREEN}PASS: $*${RESET}"; }

cleanup() {
    info "Cleaning up..."
    [[ -n "$NODE1_PID" ]] && kill "$NODE1_PID" 2>/dev/null || true
    [[ -n "$NODE2_PID" ]] && kill "$NODE2_PID" 2>/dev/null || true
    rm -f "$COOKIES"
    docker stop infinispan-server 2>/dev/null || true
}
trap cleanup EXIT

# ── Step 0: Validate environment ─────────────────────────────────────────────
[[ -f "$WILDFLY_HOME/bin/standalone.sh" ]] || fail "WILDFLY_HOME not found: $WILDFLY_HOME"
[[ -f "$WAR_SRC" ]]                        || fail "WAR not found. Run: cd session-demo && mvn clean package"
[[ -d "$WILDFLY_HOME/standalone-node2" ]]  || fail "standalone-node2 dir missing. Run: cp -r \$WILDFLY_HOME/standalone \$WILDFLY_HOME/standalone-node2"

# Verify HotRod config was applied to both nodes
grep -q "remote-sm" "$WILDFLY_HOME/standalone/configuration/standalone.xml"    || fail "HotRod not configured in node1 standalone.xml"
grep -q "remote-sm" "$WILDFLY_HOME/standalone-node2/configuration/standalone.xml" || fail "HotRod not configured in node2 standalone.xml"
info "HotRod config present in both nodes ✓"

# ── Step 1: Start Infinispan ──────────────────────────────────────────────────
info "Starting Infinispan Server..."
docker start infinispan-server 2>/dev/null || \
    docker run -d --name infinispan-server \
        -p 11222:11222 \
        -e USER=admin -e PASS=changeme \
        -e JAVA_OPTIONS="-Dinfinispan.deserialization.allowlist.regexps=org.wildfly.*,org.jboss.*,com.example.*,java.*" \
        -v "$SCRIPT_DIR/version2-external/infinispan/infinispan.xml:/opt/infinispan/server/conf/infinispan.xml:ro" \
        quay.io/infinispan/server:15.0

echo -n "   Waiting for Infinispan"
for i in $(seq 1 30); do
    if curl -sf --digest -u admin:changeme http://localhost:11222/rest/v2/cache-managers/default/health > /dev/null 2>&1; then
        echo " ready ✓"; break
    fi
    echo -n "."; sleep 3
    [[ $i -eq 30 ]] && fail "Infinispan didn't start in 90s"
done

# ── Step 2: Deploy WAR ────────────────────────────────────────────────────────
info "Deploying WAR to both nodes..."
cp "$WAR_SRC" "$DEPLOY1"
cp "$WAR_SRC" "$DEPLOY2"

# ── Step 3: Start both EAP nodes ─────────────────────────────────────────────
info "Starting EAP node1 (HTTP :8080, mgmt :9990)..."
ISPN_HOST=localhost nohup "$WILDFLY_HOME/bin/standalone.sh" \
    -c standalone.xml \
    -Djboss.node.name=eap-node1 \
    -Djboss.socket.binding.port-offset=0 \
    -b 0.0.0.0 \
    > "$LOG1" 2>&1 &
NODE1_PID=$!

info "Starting EAP node2 (HTTP :8180, mgmt :10090)..."
ISPN_HOST=localhost nohup "$WILDFLY_HOME/bin/standalone.sh" \
    -c standalone.xml \
    -Djboss.node.name=eap-node2 \
    -Djboss.socket.binding.port-offset=100 \
    -Djboss.server.base.dir="$WILDFLY_HOME/standalone-node2" \
    -b 0.0.0.0 \
    > "$LOG2" 2>&1 &
NODE2_PID=$!

echo -n "   Waiting for node1"
for i in $(seq 1 40); do
    if curl -sf http://localhost:8080/session-demo/session > /dev/null 2>&1; then
        echo " ready ✓"; break
    fi
    echo -n "."; sleep 3
    [[ $i -eq 40 ]] && fail "EAP node1 didn't start. Check $LOG1"
done

echo -n "   Waiting for node2"
for i in $(seq 1 40); do
    if curl -sf http://localhost:8180/session-demo/session > /dev/null 2>&1; then
        echo " ready ✓"; break
    fi
    echo -n "."; sleep 3
    [[ $i -eq 40 ]] && fail "EAP node2 didn't start. Check $LOG2"
done

# ── Step 4: Run the failover test ─────────────────────────────────────────────
echo ""
info "═══════════════════════════════════════════"
info " RUNNING FAILOVER TEST"
info "═══════════════════════════════════════════"

echo ""
echo "[1] Creating session on node1 (port 8080)..."
RESP1=$(curl -s -c "$COOKIES" http://localhost:8080/session-demo/session)
echo "$RESP1"
SESSION_ID=$(echo "$RESP1" | grep "Session ID" | awk -F': ' '{print $2}' | tr -d '[:space:]')
COUNTER1=$(echo "$RESP1" | grep "Counter" | awk -F': ' '{print $2}' | tr -d '[:space:]')

[[ -n "$SESSION_ID" ]] || fail "Could not parse Session ID from response"
[[ "$COUNTER1" == "1" ]] || fail "Expected counter=1, got: $COUNTER1"
echo "   --> Session ID: $SESSION_ID  Counter: $COUNTER1"

echo ""
echo "[2] Second request (same node, counter must increment)..."
RESP2=$(curl -s -b "$COOKIES" -c "$COOKIES" http://localhost:8080/session-demo/session)
echo "$RESP2"
COUNTER2=$(echo "$RESP2" | grep "Counter" | awk -F': ' '{print $2}' | tr -d '[:space:]')
SESSION_ID2=$(echo "$RESP2" | grep "Session ID" | awk -F': ' '{print $2}' | tr -d '[:space:]')

[[ "$SESSION_ID2" == "$SESSION_ID" ]] || fail "Session ID changed between requests! Got: $SESSION_ID2 (expected: $SESSION_ID)"
[[ "$COUNTER2" == "2" ]] || fail "Expected counter=2, got: $COUNTER2"
echo "   --> Session ID: $SESSION_ID2  Counter: $COUNTER2 ✓"

echo ""
echo "[3] Cross-node check: request to node2 (port 8180)..."
RESP_NODE2=$(curl -s -b "$COOKIES" -c "$COOKIES" http://localhost:8180/session-demo/session)
echo "$RESP_NODE2"
SESSION_ID_N2=$(echo "$RESP_NODE2" | grep "Session ID" | awk -F': ' '{print $2}' | tr -d '[:space:]')
COUNTER_N2=$(echo "$RESP_NODE2"   | grep "Counter"    | awk -F': ' '{print $2}' | tr -d '[:space:]')

[[ "$SESSION_ID_N2" == "$SESSION_ID" ]] || fail "Session ID mismatch on node2! Got: $SESSION_ID_N2 (expected: $SESSION_ID)"
echo "   --> Cross-node session works. Counter: $COUNTER_N2 ✓"

echo ""
echo "[4] KILLING both EAP pods..."
NODE1_OLD_PID=$NODE1_PID
NODE2_OLD_PID=$NODE2_PID
NODE1_PID=""
NODE2_PID=""

# Kill the WildFly process trees (pkill by parent PID to catch Java child)
kill "$NODE1_OLD_PID" 2>/dev/null || true
kill "$NODE2_OLD_PID" 2>/dev/null || true

# Give processes time to begin shutdown, then force-kill any survivors
sleep 5
kill -9 "$NODE1_OLD_PID" 2>/dev/null || true
kill -9 "$NODE2_OLD_PID" 2>/dev/null || true

# Also kill any lingering Java processes that standalone.sh may have exec'd
pkill -f "Djboss.node.name=eap-node1" 2>/dev/null || true
pkill -f "Djboss.node.name=eap-node2" 2>/dev/null || true

# Make sure ports are free
echo -n "   Waiting for ports to free"
for i in $(seq 1 20); do
    N1_UP=0; N2_UP=0
    curl -sf http://localhost:8080/session-demo/session > /dev/null 2>&1 && N1_UP=1 || true
    curl -sf http://localhost:8180/session-demo/session > /dev/null 2>&1 && N2_UP=1 || true
    if [[ $N1_UP -eq 0 && $N2_UP -eq 0 ]]; then
        echo " ✓"; break
    fi
    echo -n "."; sleep 2
done
echo "   Both EAP pods stopped."

echo ""
echo "[5] RESTARTING both EAP pods..."
ISPN_HOST=localhost nohup "$WILDFLY_HOME/bin/standalone.sh" \
    -c standalone.xml \
    -Djboss.node.name=eap-node1 \
    -Djboss.socket.binding.port-offset=0 \
    -b 0.0.0.0 \
    > "$LOG1" 2>&1 &
NODE1_PID=$!

ISPN_HOST=localhost nohup "$WILDFLY_HOME/bin/standalone.sh" \
    -c standalone.xml \
    -Djboss.node.name=eap-node2 \
    -Djboss.socket.binding.port-offset=100 \
    -Djboss.server.base.dir="$WILDFLY_HOME/standalone-node2" \
    -b 0.0.0.0 \
    > "$LOG2" 2>&1 &
NODE2_PID=$!

echo -n "   Waiting for node1 to come back"
for i in $(seq 1 40); do
    if curl -sf http://localhost:8080/session-demo/session > /dev/null 2>&1; then
        echo " ready ✓"; break
    fi
    echo -n "."; sleep 3
    [[ $i -eq 40 ]] && fail "EAP node1 failed to restart. Check $LOG1"
done

echo -n "   Waiting for node2 to come back"
for i in $(seq 1 40); do
    if curl -sf http://localhost:8180/session-demo/session > /dev/null 2>&1; then
        echo " ready ✓"; break
    fi
    echo -n "."; sleep 3
    [[ $i -eq 40 ]] && fail "EAP node2 failed to restart. Check $LOG2"
done

echo ""
echo "[6] POST-RESTART: Verifying session survived..."
RESP3=$(curl -s -b "$COOKIES" -c "$COOKIES" http://localhost:8080/session-demo/session)
echo "$RESP3"
SESSION_ID_POST=$(echo "$RESP3" | grep "Session ID" | awk -F': ' '{print $2}' | tr -d '[:space:]')
COUNTER_POST=$(echo "$RESP3"   | grep "Counter"    | awk -F': ' '{print $2}' | tr -d '[:space:]')

# ── Step 5: Results ────────────────────────────────────────────────────────────
echo ""
info "═══════════════════════════════════════════"
info " RESULTS"
info "═══════════════════════════════════════════"
echo ""
echo "  Pre-restart  Session ID : $SESSION_ID"
echo "  Post-restart Session ID : $SESSION_ID_POST"
echo "  Pre-restart  Counter    : $COUNTER2"
echo "  Post-restart Counter    : $COUNTER_POST"
echo ""

if [[ "$SESSION_ID_POST" == "$SESSION_ID" ]] && [[ "${COUNTER_POST:-0}" -ge 2 ]]; then
    pass "Session survived full cluster restart!"
    pass "ID preserved: $SESSION_ID"
    pass "Counter: $COUNTER_POST (>= 2)"
    echo ""
    echo "  HotRod external session externalization is working correctly."
else
    if [[ "$SESSION_ID_POST" != "$SESSION_ID" ]]; then
        fail "Session ID changed after restart! Before=$SESSION_ID After=$SESSION_ID_POST"
    else
        fail "Counter reset to $COUNTER_POST after restart (expected >= 2). Sessions may not be persisting."
    fi
fi
