// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {PoolKey} from "@pancakeswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@pancakeswap/v4-core/src/types/PoolId.sol";
import {FeeLibrary} from "@pancakeswap/v4-core/src/libraries/FeeLibrary.sol";
import {IBinPoolManager} from "@pancakeswap/v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";

import {BinBaseHook} from "../BinBaseHook.sol";

interface IVeCake {
    function balanceOf(address account) external view returns (uint256 balance);
}

/// @notice VeCakeExclusiveHook is a hook that give only veCake holders the
/// exclusive access to trade a pool. To keep this simple, >=1 veCake will make
/// you a qualified holder
contract BinVeCakeExclusiveHook is BinBaseHook {
    using PoolIdLibrary for PoolKey;
    using FeeLibrary for uint24;

    IVeCake veCake;

    error NotVeCakeHolder();

    constructor(IBinPoolManager _poolManager, address _veCake) BinBaseHook(_poolManager) {
        veCake = IVeCake(_veCake);
    }

    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return _hooksRegistrationBitmapFrom(
            Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeMint: false,
                afterMint: false,
                beforeBurn: false,
                afterBurn: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                noOp: false
            })
        );
    }

    /// @dev Using tx.origin is a workaround for now. Do NOT use this in
    /// production
    function beforeSwap(address, PoolKey calldata, bool, uint128, bytes calldata)
        external
        override
        poolManagerOnly
        returns (bytes4)
    {
        if (veCake.balanceOf(tx.origin) < 1 ether) {
            revert NotVeCakeHolder();
        }
        return this.beforeSwap.selector;
    }
}
