#!/usr/bin/env bash
# Deploy the v3 vault on Mezo testnet: the v2 contract, staked in Mezo's live BTC/MUSD gauge.
#
# The BTC/MUSD pool has two gauges on testnet. Earlier vaults used the one on the older Voter,
# which has not been paid since 13 Nov 2025. v3 stakes in the gauge on the Voter Mezo distributes
# MEZO through each epoch, and its IncentiveRouter posts fees on that gauge's incentive contract,
# where MEZO is whitelisted, so the fee flywheel runs live on testnet.
#
# Usage (PRIVATE_KEY in contracts/.env):  bash script/deploy-v3-testnet.sh
# Then seed it (~0.1 BTC opens the trove):  cast send <vault> "deposit(uint256)" 0 --value 0.1ether ...
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

FORGE="${FORGE:-forge}"
command -v "$FORGE" >/dev/null || FORGE="$HOME/.foundry/bin/forge"
CAST="$(dirname "$(command -v "$FORGE")")/cast"
RPC="${RPC:-https://rpc.test.mezo.org}"
RPC2="${RPC2:-https://mezo-testnet.drpc.org}"

MEZO=0x7B7c000000000000000000000000000000000001
GAUGE=0x72D88B0795373437E86792DEd8362D66dC43Cd2c      # MezoTestnet.GAUGE
INCENTIVES=0x75b6B35Fc78826A0B7E1f9c08bb7d84bd70D0ee1 # MezoTestnet.GAUGE_INCENTIVES
INCENTIVE_BPS="${INCENTIVE_BPS:-5000}"
DEPOSIT_CAP="${DEPOSIT_CAP:-2000000000000000000}" # 2 BTC

DEPLOYER=$("$CAST" wallet address --private-key "$PRIVATE_KEY")
# Testnet RPC backends sometimes report a stale nonce; take the highest of two.
N1=$("$CAST" nonce "$DEPLOYER" --rpc-url "$RPC" 2>/dev/null || echo 0)
N2=$("$CAST" nonce "$DEPLOYER" --rpc-url "$RPC2" 2>/dev/null || echo 0)
NONCE=$(( N1 > N2 ? N1 : N2 ))
ROUTER=$("$CAST" compute-address "$DEPLOYER" --nonce "$NONCE" | awk '{print $NF}')
VAULT=$("$CAST" compute-address "$DEPLOYER" --nonce $((NONCE + 1)) | awk '{print $NF}')

wait_for_code() {
  for _ in $(seq 1 60); do
    [ "$("$CAST" code "$1" --rpc-url "$RPC" 2>/dev/null)" != "0x" ] && [ -n "$("$CAST" code "$1" --rpc-url "$RPC" 2>/dev/null)" ] && return 0
    sleep 3
  done
  echo "no code at $1 after 3 minutes" >&2
  exit 1
}

echo "deployer $DEPLOYER (nonce $NONCE)"
echo "router   $ROUTER"
"$FORGE" create src/IncentiveRouter.sol:IncentiveRouter \
  --rpc-url "$RPC" --private-key "$PRIVATE_KEY" --broadcast --nonce "$NONCE" \
  --constructor-args "$MEZO" "$INCENTIVES" "$DEPLOYER" "$INCENTIVE_BPS" || true
wait_for_code "$ROUTER"

echo "vault    $VAULT"
GAUGE="$GAUGE" FEE_RECIPIENT="$ROUTER" DEPOSIT_CAP="$DEPOSIT_CAP" bash script/deploy-testnet.sh
wait_for_code "$VAULT"

echo
echo "IncentiveRouter $ROUTER"
echo "BtcLpVault v3   $VAULT"
echo "https://explorer.test.mezo.org/address/$VAULT"
