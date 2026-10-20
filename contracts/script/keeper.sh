#!/usr/bin/env bash
# Keeper for the BtcLpVault deployments on Mezo testnet. Anyone can run it; the vaults have no
# privileged keeper. For every vault in deployments/testnet.json it:
#   - calls rebalance() when needsRebalance() is true and a dry run succeeds
#   - calls harvest() when the gauge holds rewards for the vault
#   - tops up a RewardGauge with the keeper's testnet MEZO when its stream has under
#     TOPUP_BELOW seconds left (default 3 days), at most TOPUP_MAX MEZO (default 100)
# Without KEEPER_PRIVATE_KEY it only reports state. FORCE_HARVEST=1 harvests even with nothing earned.
set -euo pipefail
cd "$(dirname "$0")/.."

RPC="${RPC:-https://rpc.test.mezo.org}"
CAST="${CAST:-cast}"
command -v "$CAST" >/dev/null || CAST="$HOME/.foundry/bin/cast"
MEZO=0x7b7C000000000000000000000000000000000001
TOPUP_BELOW="${TOPUP_BELOW:-259200}"
TOPUP_MAX="${TOPUP_MAX:-100}"
VAULTS="${VAULTS:-$(grep -oE '"BtcLpVault": *"0x[0-9a-fA-F]{40}"' deployments/testnet.json | grep -oE '0x[0-9a-fA-F]{40}')}"

first() { awk '{print $1}'; }

KEEPER=""
if [ -n "${KEEPER_PRIVATE_KEY:-}" ]; then
  KEEPER="$("$CAST" wallet address --private-key "$KEEPER_PRIVATE_KEY")"
  echo "keeper $KEEPER: $("$CAST" balance "$KEEPER" --ether -r "$RPC") BTC," \
    "$("$CAST" from-wei "$("$CAST" call "$MEZO" "balanceOf(address)(uint256)" "$KEEPER" -r "$RPC" | first)") MEZO"
else
  echo "KEEPER_PRIVATE_KEY not set: read-only run"
fi

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

ERR="$(mktemp)"
# send <to> <sig> [args...]: dry run first, then send and wait.
send() {
  local to="$1" sig="$2"
  shift 2
  if ! "$CAST" call "$to" "$sig" "$@" --from "$KEEPER" -r "$RPC" >/dev/null 2>"$ERR"; then
    echo "  $sig dry run reverted, skipping: $(grep -oE '[A-Za-z]+\(\)|execution reverted.*' "$ERR" | head -1)"
    return 0
  fi
  local hash
  hash="$("$CAST" send "$to" "$sig" "$@" --async --gas-limit 3000000 --private-key "$KEEPER_PRIVATE_KEY" -r "$RPC")"
  echo "  sent $sig $hash"
  wait_receipt "$hash"
}

topup() {
  local gauge="$1" finish now left bal amount max
  finish="$("$CAST" call "$gauge" "periodFinish()(uint256)" -r "$RPC" | first)"
  now="$(date +%s)"
  left=$(( finish > now ? finish - now : 0 ))
  echo "  reward stream: ${left}s left"
  [ "$left" -ge "$TOPUP_BELOW" ] && return 0
  bal="$("$CAST" call "$MEZO" "balanceOf(address)(uint256)" "$KEEPER" -r "$RPC" | first)"
  amount="$("$CAST" from-wei "$bal" | cut -d. -f1)" # whole MEZO
  [ "$amount" -gt "$TOPUP_MAX" ] && amount="$TOPUP_MAX"
  if [ "$amount" -lt 1 ]; then
    echo "  top-up skipped: keeper holds under 1 MEZO (faucet: https://faucet.test.mezo.org)"
    return 0
  fi
  amount="$("$CAST" to-wei "$amount")"
  echo "top-up $gauge with $("$CAST" from-wei "$amount") MEZO:"
  send "$MEZO" "approve(address,uint256)" "$gauge" "$amount"
  send "$gauge" "notifyRewardAmount(uint256)" "$amount"
}

for VAULT in $VAULTS; do
  GAUGE="$("$CAST" call "$VAULT" "gauge()(address)" -r "$RPC")"
  needs="$("$CAST" call "$VAULT" "needsRebalance()(bool)" -r "$RPC")"
  cr="$("$CAST" call "$VAULT" "currentCR()(uint256)" -r "$RPC" | first)"
  earned="$("$CAST" call "$GAUGE" "earned(address)(uint256)" "$VAULT" -r "$RPC" | first)"
  echo
  echo "vault $VAULT (gauge $GAUGE)"
  echo "  needsRebalance=$needs currentCR=$cr gaugeEarned=$earned"
  [ -z "$KEEPER" ] && continue

  if [ "$needs" = "true" ]; then
    echo "rebalance:"
    send "$VAULT" "rebalance()"
  fi
  if [ "$earned" != "0" ] || [ -n "${FORCE_HARVEST:-}" ]; then
    echo "harvest:"
    send "$VAULT" "harvest()"
  fi
  # Only a RewardGauge has duration() and open funding; the official gauge is funded by Mezo's Voter.
  if "$CAST" call "$GAUGE" "duration()(uint256)" -r "$RPC" >/dev/null 2>&1; then
    topup "$GAUGE"
  fi
done
echo "done"
