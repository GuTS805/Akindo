#!/usr/bin/env bash
# Deploy the testnet "rewards" setup: a RewardGauge on the BTC/MUSD pool paying testnet MEZO,
# and a second BtcLpVault staked in it. The official testnet gauge has no emissions, so this
# is the vault where harvest and claim actually pay out.
#
# Addresses are computed from the deployer nonce up front, because Mezo returns creation
# receipts in a shape forge does not recognise (see deploy-testnet.sh).
#
# Usage (PRIVATE_KEY in contracts/.env):
#   bash script/deploy-rewards-testnet.sh
# Then seed it (needs ~0.1 BTC to open the trove) and fund it with testnet MEZO:
#   cast send <vault> "deposit(uint256)" 0 --value 0.1ether ...
#   bash script/fund-rewards.sh <gauge> <amount in MEZO>
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

FORGE="${FORGE:-forge}"
command -v "$FORGE" >/dev/null || FORGE="$HOME/.foundry/bin/forge"
CAST="$(dirname "$(command -v "$FORGE")")/cast"
RPC="${RPC:-https://rpc.test.mezo.org}"

POOL=0xd16A5Df82120ED8D626a1a15232bFcE2366d6AA9
MEZO=0x7b7C000000000000000000000000000000000001
DURATION="${DURATION:-604800}" # 7 days

DEPLOYER=$("$CAST" wallet address --private-key "$PRIVATE_KEY")
NONCE=$("$CAST" nonce "$DEPLOYER" --rpc-url "$RPC")
GAUGE=$("$CAST" compute-address "$DEPLOYER" --nonce "$NONCE" | awk '{print $NF}')
VAULT=$("$CAST" compute-address "$DEPLOYER" --nonce $((NONCE + 1)) | awk '{print $NF}')

wait_for_code() {
  for _ in $(seq 1 60); do
    [ "$("$CAST" code "$1" --rpc-url "$RPC")" != "0x" ] && return 0
    sleep 3
  done
  echo "no code at $1 after 3 minutes" >&2
  exit 1
}

echo "deployer $DEPLOYER (nonce $NONCE)"
echo "gauge    $GAUGE"
"$FORGE" create src/RewardGauge.sol:RewardGauge \
  --rpc-url "$RPC" --private-key "$PRIVATE_KEY" --broadcast \
  --constructor-args "$POOL" "$MEZO" "$DURATION" || true
wait_for_code "$GAUGE"

echo "vault    $VAULT"
GAUGE="$GAUGE" bash script/deploy-testnet.sh
wait_for_code "$VAULT"

echo
echo "RewardGauge $GAUGE"
echo "BtcLpVault  $VAULT"
echo "https://explorer.test.mezo.org/address/$VAULT"
