// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {Hooks} from "@pancakeswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@pancakeswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@pancakeswap/v4-core/src/interfaces/IHooks.sol";
import {IBinPoolManager} from "@pancakeswap/v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {BinPoolManager} from "@pancakeswap/v4-core/src/pool-bin/BinPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@pancakeswap/v4-core/src/types/PoolId.sol";
import {FeeLibrary} from "@pancakeswap/v4-core/src/libraries/FeeLibrary.sol";
import {SortTokens} from "@pancakeswap/v4-core/test/helpers/SortTokens.sol";
import {PoolKey} from "@pancakeswap/v4-core/src/types/PoolKey.sol";
import {Vault} from "@pancakeswap/v4-core/src/Vault.sol";
import {IVault} from "@pancakeswap/v4-core/src/interfaces/IVault.sol";

contract Deployers {
    using FeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;

    bytes constant ZERO_BYTES = new bytes(0);

    function deployToken(string memory name, string memory symbol, uint256 totalSupply)
        internal
        returns (MockERC20 token)
    {
        token = new MockERC20(name, symbol, 18);
        token.mint(address(this), totalSupply);
    }

    function createPool(
        IBinPoolManager manager,
        MockERC20 token0,
        MockERC20 token1,
        IHooks hooks,
        uint24 fee,
        uint24 activeId
    ) private returns (PoolKey memory key, PoolId id) {
        (key, id) = createPool(manager, token0, token1, hooks, fee, activeId, ZERO_BYTES);
    }

    function createPool(
        IBinPoolManager manager,
        MockERC20 token0,
        MockERC20 token1,
        IHooks hooks,
        uint24 fee,
        uint24 activeId,
        bytes memory initData
    ) private returns (PoolKey memory key, PoolId id) {
        (Currency currency0, Currency currency1) = SortTokens.sort(token0, token1);
        key = PoolKey(
            currency0,
            currency1,
            hooks,
            manager,
            fee,
            fee.isDynamicFee()
                ? bytes32(uint256((60 << 16) | 0x00ff))
                : bytes32(uint256(((fee / 100 * 2) << 16) | 0x00ff))
        );
        id = key.toId();
        manager.initialize(key, activeId, initData);
    }

    function createFreshManager() internal returns (IVault vault, BinPoolManager manager) {
        vault = new Vault();
        manager = new BinPoolManager(vault, 500000);
        vault.registerPoolManager(address(manager));
    }
}
