// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {BtcLpVault} from "../src/BtcLpVault.sol";
import {MezoTestnet} from "./Addresses.sol";

/// @notice forge script script/Deploy.s.sol --rpc-url mezo_testnet --broadcast
///         Reads PRIVATE_KEY and optional FEE_RECIPIENT (defaults to the deployer) from env.
contract Deploy is Script {
    function run() external returns (BtcLpVault vault) {
        require(block.chainid == MezoTestnet.CHAIN_ID, "not Mezo testnet");
        uint256 key = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(key);
        address feeRecipient = vm.envOr("FEE_RECIPIENT", deployer);

        vm.startBroadcast(key);
        vault = new BtcLpVault(MezoTestnet.config(feeRecipient));
        vm.stopBroadcast();

        console2.log("BtcLpVault", address(vault));
        console2.log("feeRecipient", feeRecipient);
    }
}
