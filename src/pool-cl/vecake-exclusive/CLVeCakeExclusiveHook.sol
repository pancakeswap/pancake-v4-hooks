// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.19;

import {PoolKey} from "@pancakeswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@pancakeswap/v4-core/src/types/PoolId.sol";
import {FeeLibrary} from "@pancakeswap/v4-core/src/libraries/FeeLibrary.sol";
import {ICLPoolManager} from "@pancakeswap/v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";

import {CLBaseHook} from "../CLBaseHook.sol";

interface IVeCake {
    function balanceOf(address account) external view returns (uint256 balance);
}

/// @notice VeCakeExclusiveHook is a hook that give only veCake holders the
/// exclusive access to trade a pool. To keep this simple, >=1 veCake will make
/// you a qualified holder
contract CLVeCakeExclusiveHook is CLBaseHook {
    using PoolIdLibrary for PoolKey;
    using FeeLibrary for uint24;

    IVeCake veCake;

    error NotVeCakeHolder();

    constructor(ICLPoolManager _poolManager, address _veCake) CLBaseHook(_poolManager) {
        veCake = IVeCake(_veCake);
    }

    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return _hooksRegistrationBitmapFrom(
            Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
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
    function beforeSwap(address, PoolKey calldata, ICLPoolManager.SwapParams calldata, bytes calldata)
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
