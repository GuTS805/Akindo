#!/usr/bin/env bash
# Stream testnet MEZO into a RewardGauge over its period (7 days). Anyone can do this.
#
# Usage (PRIVATE_KEY in contracts/.env, key holding testnet MEZO from faucet.test.mezo.org):
#   bash script/fund-rewards.sh <gauge> <amount in MEZO, e.g. 500>
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

CAST="${CAST:-cast}"
command -v "$CAST" >/dev/null || CAST="$HOME/.foundry/bin/cast"
RPC="${RPC:-https://rpc.test.mezo.org}"
MEZO=0x7b7C000000000000000000000000000000000001

GAUGE="$1"
AMOUNT=$("$CAST" to-wei "$2")
FROM=$("$CAST" wallet address --private-key "$PRIVATE_KEY")

wait_receipt() {
  for _ in $(seq 1 40); do
    status=$("$CAST" receipt "$1" status --rpc-url "$RPC" 2>/dev/null || true)
    case "$status" in
      *1*) return 0 ;;
      *0*) echo "reverted: $1" >&2; exit 1 ;;
    esac
    sleep 3
  done
  echo "no receipt for $1" >&2
  exit 1
}

echo "MEZO balance: $("$CAST" call "$MEZO" "balanceOf(address)(uint256)" "$FROM" --rpc-url "$RPC")"
tx=$("$CAST" send "$MEZO" "approve(address,uint256)" "$GAUGE" "$AMOUNT" \
  --rpc-url "$RPC" --private-key "$PRIVATE_KEY" --async)
wait_receipt "$tx"
tx=$("$CAST" send "$GAUGE" "notifyRewardAmount(uint256)" "$AMOUNT" \
  --rpc-url "$RPC" --private-key "$PRIVATE_KEY" --async)
wait_receipt "$tx"
echo "funded: $tx"
echo "rewardRate $("$CAST" call "$GAUGE" "rewardRate()(uint256)" --rpc-url "$RPC") per second until $("$CAST" call "$GAUGE" "periodFinish()(uint256)" --rpc-url "$RPC")"
