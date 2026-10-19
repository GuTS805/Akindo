#!/usr/bin/env bash
# Deploy BtcLpVault to Mezo testnet.
#
# Uses `forge create` rather than `forge script`: a script runs the constructor in a local EVM
# first, and the constructor calls the BTC precompile, which only exists on Mezo nodes.
# Mezo's node also returns the creation receipt in a shape forge does not recognise, so forge
# may print "contract was not deployed" even when it was: check the explorer link below.
#
# Usage: set PRIVATE_KEY (and optionally FEE_RECIPIENT) in contracts/.env, then
#   bash script/deploy-testnet.sh
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

FORGE="${FORGE:-forge}"
command -v "$FORGE" >/dev/null || FORGE="$HOME/.foundry/bin/forge"
CAST="$(dirname "$(command -v "$FORGE")")/cast"
RPC="${RPC:-https://rpc.test.mezo.org}"

DEPLOYER=$("$CAST" wallet address --private-key "$PRIVATE_KEY")
FEE_RECIPIENT="${FEE_RECIPIENT:-$DEPLOYER}"

# Must match script/Addresses.sol (MezoTestnet.config)
CONFIG="(\
0x7b7C000000000000000000000000000000000000,\
0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503,\
0xCdF7028ceAB81fA0C6971208e83fa7872994beE5,\
0xE47c80e8c23f6B4A1aE41c34837a0599D5D16bb0,\
0x86bCF0841622a5dAC14A313a15f96A95421b9366,\
0x4e4cBA3779d56386ED43631b4dCD6d8EacEcBCF6,\
0x722E4D24FD6Ff8b0AC679450F3D91294607268fA,\
0x9a1ff7FE3a0F69959A3fBa1F1e5ee18e1A9CD7E9,\
0xd16A5Df82120ED8D626a1a15232bFcE2366d6AA9,\
0xeF07B6852f4F877fB3BBD90b8f358Fb3E07D0Cc3,\
$FEE_RECIPIENT,\
3000000000000000000,2500000000000000000,3500000000000000000,600,1000,1000000000000000)"

echo "deployer $DEPLOYER"
"$FORGE" create src/BtcLpVault.sol:BtcLpVault \
  --rpc-url "$RPC" --private-key "$PRIVATE_KEY" --broadcast \
  --constructor-args "$CONFIG" || true
echo "check: https://explorer.test.mezo.org/address/$DEPLOYER"
