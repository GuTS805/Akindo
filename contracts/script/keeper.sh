#!/usr/bin/env bash
# Keeper for the BtcLpVault deployments on Mezo testnet. Anyone can run it; the vaults have no
# privileged keeper. For every vault in deployments/testnet.json it:
#   - calls rebalance() when needsRebalance() is true and a dry run succeeds
#   - calls harvest() when the gauge holds at least HARVEST_MIN reward tokens for the vault
#     (default 5; deposits, withdrawals and claims harvest on their own anyway)
#   - tops up a RewardGauge with the keeper's testnet MEZO when its stream has under
#     TOPUP_BELOW seconds left (default 3 days), at most TOPUP_MAX MEZO (default 100)
#   - calls push() on a vault's IncentiveRouter fee recipient when it holds fees
# Without KEEPER_PRIVATE_KEY it only reports state. FORCE_HARVEST=1 harvests even with nothing earned.
# A dry run that reverts (e.g. the pool is outside the oracle band) is a skip, not a failure. A sent
# transaction that reverts or never confirms fails the run after every vault has been processed.
set -euo pipefail
cd "$(dirname "$0")/.."

RPC="${RPC:-https://rpc.test.mezo.org}"
ERR="$(mktemp)"
CAST="${CAST:-cast}"
command -v "$CAST" >/dev/null || CAST="$HOME/.foundry/bin/cast"
MEZO=0x7b7C000000000000000000000000000000000001
TOPUP_BELOW="${TOPUP_BELOW:-259200}"
TOPUP_MAX="${TOPUP_MAX:-100}"
HARVEST_MIN="${HARVEST_MIN:-5}"
VAULTS="${VAULTS:-$(grep -oE '"BtcLpVault": *"0x[0-9a-fA-F]{40}"' deployments/testnet.json | grep -oE '0x[0-9a-fA-F]{40}')}"

first() { awk '{print $1}'; }

# One backend behind rpc.test.mezo.org has run days behind and answers "latest" with old state.
# Reads are pinned to the highest block from several samples, minus a margin; that backend then
# rejects the block, so each read is retried a few times.
BLOCK=0
for _ in 1 2 3 4 5; do
  b="$("$CAST" block-number -r "$RPC" 2>/dev/null || echo 0)"
  [[ "$b" =~ ^[0-9]+$ ]] && [ "$b" -gt "$BLOCK" ] && BLOCK="$b"
done
[ "$BLOCK" -gt 3 ] || { echo "cannot read the block number from $RPC"; exit 1; }
BLOCK=$((BLOCK - 3))
rd() {
  local out
  for _ in 1 2 3 4 5; do
    if out="$("$CAST" call "$@" -b "$BLOCK" -r "$RPC" 2>"$ERR")"; then echo "$out"; return 0; fi
    grep -qiE "must be less than or equal|header not found|unknown block" "$ERR" || break
  done
  return 1
}

KEEPER=""
if [ -n "${KEEPER_PRIVATE_KEY:-}" ]; then
  KEEPER="$("$CAST" wallet address --private-key "$KEEPER_PRIVATE_KEY")"
  echo "keeper $KEEPER: $("$CAST" balance "$KEEPER" --ether -r "$RPC") BTC," \
    "$("$CAST" from-wei "$(rd "$MEZO" "balanceOf(address)(uint256)" "$KEEPER" | first)") MEZO"
else
  echo "KEEPER_PRIVATE_KEY not set: read-only run"
  [ -n "${GITHUB_ACTIONS:-}" ] && echo "::warning::KEEPER_PRIVATE_KEY is not set; the keeper only reported state"
fi

# Mezo's RPC can return a null receipt for a while after inclusion; poll it ourselves.
wait_receipt() {
  local hash="$1" body
  for _ in $(seq 1 60); do
    body="$(curl -s --max-time 15 -X POST "$RPC" -H 'content-type: application/json' \
      -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getTransactionReceipt\",\"params\":[\"$hash\"]}")"
    if echo "$body" | grep -q '"status":"0x1"'; then echo "  confirmed $hash"; return 0; fi
    if echo "$body" | grep -q '"status":"0x0"'; then echo "  reverted $hash"; return 1; fi
    sleep 3
  done
  echo "  no receipt after 3 minutes: $hash"
  return 1
}

FAILS=0
fail() {
  FAILS=$((FAILS + 1))
  [ -n "${GITHUB_ACTIONS:-}" ] && echo "::error::$1"
  return 0
}
# send <to> <sig> [args...]: dry run first, then send and wait.
send() {
  local to="$1" sig="$2"
  shift 2
  if ! rd "$to" "$sig" "$@" --from "$KEEPER" >/dev/null; then
    echo "  $sig dry run reverted, skipping: $(grep -oE '[A-Za-z]+\(\)|execution reverted.*' "$ERR" | head -1)"
    [ -n "${GITHUB_ACTIONS:-}" ] && echo "::warning::$to $sig dry run reverted"
    return 0
  fi
  local hash="" try
  # The lagging backend can also report a stale nonce or balance, so a refused send is retried.
  for try in 1 2 3 4; do
    hash="$("$CAST" send "$to" "$sig" "$@" --async --gas-limit 3000000 --private-key "$KEEPER_PRIVATE_KEY" -r "$RPC" 2>&1)" || true
    [[ "$hash" =~ ^0x[0-9a-fA-F]{64}$ ]] && break
    sleep 3
  done
  if ! [[ "$hash" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
    echo "  $sig could not be sent: $(echo "$hash" | tail -1 | cut -c1-200)"
    return 1
  fi
  echo "  sent $sig $hash"
  wait_receipt "$hash"
}

topup() {
  local gauge="$1" finish now left bal amount max
  finish="$(rd "$gauge" "periodFinish()(uint256)" | first)"
  now="$(date +%s)"
  left=$(( finish > now ? finish - now : 0 ))
  echo "  reward stream: ${left}s left"
  [ "$left" -ge "$TOPUP_BELOW" ] && return 0
  bal="$(rd "$MEZO" "balanceOf(address)(uint256)" "$KEEPER" | first)"
  amount="$("$CAST" from-wei "$bal" | cut -d. -f1)" # whole MEZO
  [ "$amount" -gt "$TOPUP_MAX" ] && amount="$TOPUP_MAX"
  if [ "$amount" -lt 1 ]; then
    echo "  top-up skipped: keeper holds under 1 MEZO (faucet: https://faucet.test.mezo.org)"
    return 0
  fi
  amount="$("$CAST" to-wei "$amount")"
  echo "top-up $gauge with $("$CAST" from-wei "$amount") MEZO:"
  send "$MEZO" "approve(address,uint256)" "$gauge" "$amount" || { fail "approve for $gauge failed"; return 0; }
  send "$gauge" "notifyRewardAmount(uint256)" "$amount" || fail "top-up of $gauge failed"
}

for VAULT in $VAULTS; do
  GAUGE="$(rd "$VAULT" "gauge()(address)")" || { fail "could not read $VAULT"; continue; }
  needs="$(rd "$VAULT" "needsRebalance()(bool)")"
  cr="$(rd "$VAULT" "currentCR()(uint256)" | first)"
  earned="$(rd "$GAUGE" "earned(address)(uint256)" "$VAULT" | first)"
  echo
  echo "vault $VAULT (gauge $GAUGE)"
  echo "  needsRebalance=$needs currentCR=$cr gaugeEarned=$earned"
  [ -z "$KEEPER" ] && continue

  if [ "$needs" = "true" ]; then
    echo "rebalance:"
    send "$VAULT" "rebalance()" || fail "rebalance of $VAULT failed"
  fi
  [[ "$earned" =~ ^[0-9]+$ ]] || { fail "could not read earned() for $VAULT"; continue; }
  if [ "$("$CAST" from-wei "$earned" | cut -d. -f1)" -ge "$HARVEST_MIN" ] || [ -n "${FORCE_HARVEST:-}" ]; then
    echo "harvest:"
    send "$VAULT" "harvest()" || fail "harvest of $VAULT failed"
  fi
  # Only a RewardGauge has duration() and open funding; Mezo's gauges are funded by its Voter.
  if rd "$GAUGE" "duration()(uint256)" >/dev/null 2>&1; then
    topup "$GAUGE"
  fi
  # A vault whose fee recipient is an IncentiveRouter: post the fees it holds.
  FEE="$(rd "$VAULT" "feeRecipient()(address)" || true)"
  if [ -n "$FEE" ] && rd "$FEE" "incentiveBps()(uint256)" >/dev/null 2>&1; then
    held="$(rd "$MEZO" "balanceOf(address)(uint256)" "$FEE" | first)"
    if [[ "$held" =~ ^[0-9]+$ ]] && [ "$held" != "0" ]; then
      echo "push fees from router $FEE ($("$CAST" from-wei "$held") MEZO):"
      send "$FEE" "push()" || fail "push of $FEE failed"
    fi
  fi
done
if [ "$FAILS" -gt 0 ]; then
  echo "done with $FAILS failure(s)"
  exit 1
fi
echo "done"
