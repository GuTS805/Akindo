#!/usr/bin/env bash
# Deploy the v2 vault on Mezo testnet: an IncentiveRouter as its fee recipient and a BtcLpVault
# staked in the existing RewardGauge (shared with the v1 rewards vault), with a deposit cap.
#
# v2 changes: shares are minted from the NAV change (a deposit pays its own MUSD borrowing fee),
# a deposit cap, and an isolated deployment step so a failed deployment never blocks a deposit.
#
# The router posts half of each fee on the BTC/MUSD gauge's incentive contract. Mezo's testnet
# Voter does not whitelist MEZO there, so on testnet every push takes the router's fallback and
# sends the whole fee to the treasury; on mainnet MEZO is whitelisted.
#
# Usage (PRIVATE_KEY in contracts/.env):  bash script/deploy-v2-testnet.sh
# Then seed it (~0.1 BTC opens the trove):  cast send <vault> "deposit(uint256)" 0 --value 0.1ether ...
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

FORGE="${FORGE:-forge}"
command -v "$FORGE" >/dev/null || FORGE="$HOME/.foundry/bin/forge"
CAST="$(dirname "$(command -v "$FORGE")")/cast"
RPC="${RPC:-https://rpc.test.mezo.org}"

MEZO=0x7b7C000000000000000000000000000000000001
REWARD_GAUGE=0x204ef88B33e5d35De7b52F8c1FFa58cf89d4f45b
INCENTIVES=0xD57eEA1BD19c483cEa19cc498575D21F512d4735 # Voter.gaugeToBribe(official BTC/MUSD gauge)
INCENTIVE_BPS="${INCENTIVE_BPS:-5000}"
DEPOSIT_CAP="${DEPOSIT_CAP:-2000000000000000000}" # 2 BTC

DEPLOYER=$("$CAST" wallet address --private-key "$PRIVATE_KEY")
NONCE=$("$CAST" nonce "$DEPLOYER" --rpc-url "$RPC")
ROUTER=$("$CAST" compute-address "$DEPLOYER" --nonce "$NONCE" | awk '{print $NF}')
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
echo "router   $ROUTER"
"$FORGE" create src/IncentiveRouter.sol:IncentiveRouter \
  --rpc-url "$RPC" --private-key "$PRIVATE_KEY" --broadcast \
  --constructor-args "$MEZO" "$INCENTIVES" "$DEPLOYER" "$INCENTIVE_BPS" || true
wait_for_code "$ROUTER"

echo "vault    $VAULT"
GAUGE="$REWARD_GAUGE" FEE_RECIPIENT="$ROUTER" DEPOSIT_CAP="$DEPOSIT_CAP" bash script/deploy-testnet.sh
wait_for_code "$VAULT"

echo
echo "IncentiveRouter $ROUTER"
echo "BtcLpVault v2   $VAULT"
echo "https://explorer.test.mezo.org/address/$VAULT"
