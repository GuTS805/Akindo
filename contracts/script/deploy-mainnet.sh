#!/usr/bin/env bash
# Deploy the IncentiveRouter and BtcLpVault on Mezo MAINNET (chain 31612). NOT RUN YET: the vault has no
# owner and no pause, so it is meant to go live only after an audit and with a deposit cap.
#
# Guards: refuses to run without CONFIRM_MAINNET=audited-and-capped and a non-zero DEPOSIT_CAP.
# DRY_RUN=1 only prints the configuration and checks the live addresses (no key needed).
#
# Usage (PRIVATE_KEY in contracts/.env):
#   DRY_RUN=1 bash script/deploy-mainnet.sh
#   CONFIRM_MAINNET=audited-and-capped DEPOSIT_CAP=500000000000000000 TREASURY=0x... bash script/deploy-mainnet.sh
# Env: INCENTIVE_BPS (default 5000: half of each fee becomes a gauge incentive, the rest goes to TREASURY),
#      BAND (default 200 = 2%; Sandwich.t.sol checks 2%, 6% and 10%), RPC.
set -euo pipefail
cd "$(dirname "$0")/.."

FORGE="${FORGE:-forge}"
command -v "$FORGE" >/dev/null || FORGE="$HOME/.foundry/bin/forge"
CAST="$(dirname "$(command -v "$FORGE")")/cast"
RPC="${RPC:-https://rpc-http.mezo.boar.network}"

# Must match script/Addresses.sol (MezoMainnet)
MEZO=0x7B7c000000000000000000000000000000000001
BTC=0x7b7C000000000000000000000000000000000000
MUSD=0xdD468A1DDc392dcdbEf6db6e34E89AA338F9F186
BORROWER_OPERATIONS=0x44b1bac67dDA612a41a58AAf779143B181dEe031
TROVE_MANAGER=0x94AfB503dBca74aC3E4929BACEeDfCe19B93c193
PRICE_FEED=0xc5aC5A8892230E0A3e1c473881A2de7353fFcA88
HINT_HELPERS=0xD267b3bE2514375A075fd03C3D9CBa6b95317DC3
SORTED_TROVES=0x8C5DB4C62BF29c1C4564390d10c20a47E0b2749f
ROUTER=0x16A76d3cd3C1e3CE843C6680d6B37E9116b5C706
POOL=0x52e604c44417233b6CcEDDDc0d640A405Caacefb
GAUGE=0x8Be20a5fF57E381025aE5E3A121B697269569AaF
GAUGE_INCENTIVES=0x94A9A494872BF7231D8378d0Aef7d32BA552E305
INCENTIVE_BPS="${INCENTIVE_BPS:-5000}"
BAND="${BAND:-200}"
DEPOSIT_CAP="${DEPOSIT_CAP:-0}"

chain="$("$CAST" chain-id --rpc-url "$RPC")"
[ "$chain" = "31612" ] || { echo "RPC is chain $chain, expected 31612 (Mezo mainnet)" >&2; exit 1; }
for a in "$POOL" "$GAUGE" "$ROUTER" "$PRICE_FEED" "$GAUGE_INCENTIVES"; do
  [ "$("$CAST" code "$a" --rpc-url "$RPC")" != "0x" ] || { echo "no code at $a" >&2; exit 1; }
done
[ "$("$CAST" call "$GAUGE" "stakingToken()(address)" --rpc-url "$RPC" | tr 'A-F' 'a-f')" = "$(echo "$POOL" | tr 'A-F' 'a-f')" ] \
  || { echo "gauge does not stake the pool" >&2; exit 1; }
echo "mainnet addresses check out (pool, gauge, router, oracle, incentives); band ${BAND} bps, cap ${DEPOSIT_CAP} wei"

if [ -n "${DRY_RUN:-}" ]; then
  echo "dry run: nothing deployed"
  exit 0
fi
[ "${CONFIRM_MAINNET:-}" = "audited-and-capped" ] || { echo "set CONFIRM_MAINNET=audited-and-capped to deploy" >&2; exit 1; }
[ "$DEPOSIT_CAP" != "0" ] || { echo "DEPOSIT_CAP must be non-zero on mainnet" >&2; exit 1; }
[ -n "${TREASURY:-}" ] || { echo "set TREASURY to the address that receives the non-incentive half of the fee" >&2; exit 1; }
set -a; . ./.env; set +a
DEPLOYER=$("$CAST" wallet address --private-key "$PRIVATE_KEY")

NONCE=$("$CAST" nonce "$DEPLOYER" --rpc-url "$RPC")
ROUTER_ADDR=$("$CAST" compute-address "$DEPLOYER" --nonce "$NONCE" | awk '{print $NF}')
VAULT_ADDR=$("$CAST" compute-address "$DEPLOYER" --nonce $((NONCE + 1)) | awk '{print $NF}')

wait_for_code() {
  for _ in $(seq 1 60); do
    c="$("$CAST" code "$1" --rpc-url "$RPC" 2>/dev/null || true)"
    [ -n "$c" ] && [ "$c" != "0x" ] && return 0
    sleep 3
  done
  echo "no code at $1 after 3 minutes" >&2
  exit 1
}

echo "deployer $DEPLOYER (nonce $NONCE)"
"$FORGE" create src/IncentiveRouter.sol:IncentiveRouter \
  --rpc-url "$RPC" --private-key "$PRIVATE_KEY" --broadcast --nonce "$NONCE" \
  --constructor-args "$MEZO" "$GAUGE_INCENTIVES" "$TREASURY" "$INCENTIVE_BPS" || true
wait_for_code "$ROUTER_ADDR"

CONFIG="($BTC,$MUSD,$BORROWER_OPERATIONS,$TROVE_MANAGER,$PRICE_FEED,$HINT_HELPERS,$SORTED_TROVES,$ROUTER,$POOL,$GAUGE,$ROUTER_ADDR,\
3000000000000000000,2500000000000000000,3500000000000000000,$BAND,1000,1000000000000000,$DEPOSIT_CAP)"
"$FORGE" create src/BtcLpVault.sol:BtcLpVault \
  --rpc-url "$RPC" --private-key "$PRIVATE_KEY" --broadcast --nonce $((NONCE + 1)) \
  --constructor-args "$CONFIG" || true
wait_for_code "$VAULT_ADDR"

echo
echo "IncentiveRouter $ROUTER_ADDR"
echo "BtcLpVault      $VAULT_ADDR"
echo "Verify both on the Mezo mainnet explorer, then seed nothing: deposits wait idle until they can open a trove."
