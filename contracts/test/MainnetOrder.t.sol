// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MockBTC, MockToken} from "./mocks/Mocks.sol";
import {BtcLpVaultTest} from "./BtcLpVault.t.sol";
import {CapacityTest} from "./Capacity.t.sol";
import {RecoveryModeTest} from "./RecoveryMode.t.sol";
import {SandwichTest} from "./Sandwich.t.sol";

/// @notice The pool sorts its tokens by address, so the vault reads reserves in either order.
///         On Mezo testnet MUSD (0x1189…) sorts before BTC; on mainnet BTC (0x7b7C…) sorts
///         before MUSD (0xdD46…). The other suites run in testnet order; these rerun them with
///         the mock tokens at the mainnet addresses, so BTC is the pool's token0.
abstract contract MainnetOrder {
    address internal constant MAINNET_BTC = 0x7b7C000000000000000000000000000000000000;
    address internal constant MAINNET_MUSD = 0xdD468A1DDc392dcdbEf6db6e34E89AA338F9F186;
}

contract BtcLpVaultMainnetOrderTest is BtcLpVaultTest, MainnetOrder {
    function _deployTokens() internal override {
        deployCodeTo("Mocks.sol:MockBTC", MAINNET_BTC);
        deployCodeTo("Mocks.sol:MockToken", abi.encode("Mezo USD", "MUSD"), MAINNET_MUSD);
        btc = MockBTC(MAINNET_BTC);
        musd = MockToken(MAINNET_MUSD);
    }

    function test_btcIsToken0() public view {
        assertEq(pool.token0(), address(btc));
    }
}

contract CapacityMainnetOrderTest is CapacityTest, MainnetOrder {
    function _deployTokens() internal override {
        deployCodeTo("Mocks.sol:MockBTC", MAINNET_BTC);
        deployCodeTo("Mocks.sol:MockToken", abi.encode("Mezo USD", "MUSD"), MAINNET_MUSD);
        btc = MockBTC(MAINNET_BTC);
        musd = MockToken(MAINNET_MUSD);
    }
}

contract RecoveryModeMainnetOrderTest is RecoveryModeTest, MainnetOrder {
    function _deployTokens() internal override {
        deployCodeTo("Mocks.sol:MockBTC", MAINNET_BTC);
        deployCodeTo("Mocks.sol:MockToken", abi.encode("Mezo USD", "MUSD"), MAINNET_MUSD);
        btc = MockBTC(MAINNET_BTC);
        musd = MockToken(MAINNET_MUSD);
    }
}

contract SandwichMainnetOrderTest is SandwichTest, MainnetOrder {
    function _deployTokens() internal override {
        deployCodeTo("Mocks.sol:MockBTC", MAINNET_BTC);
        deployCodeTo("Mocks.sol:MockToken", abi.encode("Mezo USD", "MUSD"), MAINNET_MUSD);
        btc = MockBTC(MAINNET_BTC);
        musd = MockToken(MAINNET_MUSD);
    }
}
