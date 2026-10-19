#!/usr/bin/env bash
# Keeper for BtcLpVault on Mezo testnet. Anyone can run it; the vault has no privileged keeper.
#   - calls rebalance() when needsRebalance() is true and a dry run succeeds
#   - calls harvest() when the gauge holds rewards for the vault
# Without KEEPER_PRIVATE_KEY it only reports state. FORCE_HARVEST=1 harvests even with nothing earned.
set -euo pipefail
cd "$(dirname "$0")/.."

RPC="${RPC:-https://rpc.test.mezo.org}"
CAST="${CAST:-cast}"
command -v "$CAST" >/dev/null || CAST="$HOME/.foundry/bin/cast"
VAULT="${VAULT:-$(grep -oE '"BtcLpVault": *"0x[0-9a-fA-F]{40}"' deployments/testnet.json | grep -oE '0x[0-9a-fA-F]{40}')}"
GAUGE="$("$CAST" call "$VAULT" "gauge()(address)" -r "$RPC")"

first() { awk '{print $1}'; }

needs="$("$CAST" call "$VAULT" "needsRebalance()(bool)" -r "$RPC")"
cr="$("$CAST" call "$VAULT" "currentCR()(uint256)" -r "$RPC" | first)"
earned="$("$CAST" call "$GAUGE" "earned(address)(uint256)" "$VAULT" -r "$RPC" | first)"
echo "vault $VAULT"
echo "needsRebalance=$needs currentCR=$cr gaugeEarned=$earned"

if [ -z "${KEEPER_PRIVATE_KEY:-}" ]; then
  echo "KEEPER_PRIVATE_KEY not set: read-only run"
  exit 0
fi
KEEPER="$("$CAST" wallet address --private-key "$KEEPER_PRIVATE_KEY")"
echo "keeper $KEEPER balance $("$CAST" balance "$KEEPER" --ether -r "$RPC")"

# Mezo's RPC can return a null receipt for a while after inclusion; poll it ourselves.
wait_receipt() {
  local hash="$1" body
  for _ in $(seq 1 60); do
    body="$(curl -s -X POST "$RPC" -H 'content-type: application/json' \
      -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getTransactionReceipt\",\"params\":[\"$hash\"]}")"
    if echo "$body" | grep -q '"status":"0x1"'; then echo "  confirmed $hash"; return 0; fi
    if echo "$body" | grep -q '"status":"0x0"'; then echo "  reverted $hash"; return 1; fi
    sleep 3
  done
  echo "  no receipt after 3 minutes: $hash"
  return 1
}

call() {
  local sig="$1"
  if ! "$CAST" call "$VAULT" "$sig" --from "$KEEPER" -r "$RPC" >/dev/null 2>"$RUNNER_TEMP_DIR/err"; then
    echo "  $sig dry run reverted, skipping: $(grep -oE '[A-Za-z]+\(\)|execution reverted.*' "$RUNNER_TEMP_DIR/err" | head -1)"
    return 0
  fi
  local hash
  hash="$("$CAST" send "$VAULT" "$sig" --async --gas-limit 3000000 --private-key "$KEEPER_PRIVATE_KEY" -r "$RPC")"
  echo "  sent $sig $hash"
  wait_receipt "$hash"
}

RUNNER_TEMP_DIR="$(mktemp -d)"
if [ "$needs" = "true" ]; then
  echo "rebalance:"
  call "rebalance()"
fi
if [ "$earned" != "0" ] || [ -n "${FORCE_HARVEST:-}" ]; then
  echo "harvest:"
  call "harvest()"
fi
echo "done"
