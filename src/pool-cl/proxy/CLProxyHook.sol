// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.26;

import {
    ICLHooks,
    HOOKS_BEFORE_INITIALIZE_OFFSET,
    HOOKS_AFTER_INITIALIZE_OFFSET,
    HOOKS_BEFORE_ADD_LIQUIDITY_OFFSET,
    HOOKS_AFTER_ADD_LIQUIDITY_OFFSET,
    HOOKS_BEFORE_REMOVE_LIQUIDITY_OFFSET,
    HOOKS_AFTER_REMOVE_LIQUIDITY_OFFSET,
    HOOKS_BEFORE_SWAP_OFFSET,
    HOOKS_AFTER_SWAP_OFFSET,
    HOOKS_BEFORE_DONATE_OFFSET,
    HOOKS_AFTER_DONATE_OFFSET,
    HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET,
    HOOKS_AFTER_SWAP_RETURNS_DELTA_OFFSET,
    HOOKS_AFTER_ADD_LIQUIDIY_RETURNS_DELTA_OFFSET,
    HOOKS_AFTER_REMOVE_LIQUIDIY_RETURNS_DELTA_OFFSET
} from "@pancakeswap/v4-core/src/pool-cl/interfaces/ICLHooks.sol";
import {ICLPoolManager} from "@pancakeswap/v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@pancakeswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@pancakeswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolKey} from "@pancakeswap/v4-core/src/types/PoolKey.sol";
import {Hooks} from "@pancakeswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@pancakeswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {CLHooks} from "@pancakeswap/v4-core/src/pool-cl/libraries/CLHooks.sol";

import {CLBaseHook} from "../CLBaseHook.sol";

/// @notice A proxy hook for combining multiple hooks
contract CLProxyHook is CLBaseHook {
    using Hooks for bytes32;
    using LPFeeLibrary for uint24;

    ICLHooks[] public hooks;

    uint16 private _hooksRegistrationBitmap;

    constructor(ICLPoolManager poolManager, ICLHooks[] memory hooks_) CLBaseHook(poolManager) {
        hooks = hooks_;

        uint16 hooksRegistrationBitmap;
        for (uint256 i = 0; i < hooks_.length; ++i) {
            hooksRegistrationBitmap |= hooks[i].getHooksRegistrationBitmap();
        }
        _validatePermissionsConflict(hooksRegistrationBitmap);
        _hooksRegistrationBitmap = hooksRegistrationBitmap;
    }

    function getHooksRegistrationBitmap() external view override returns (uint16) {
        return _hooksRegistrationBitmap;
    }

    /// @notice Validate hook permission, eg. if before_swap_return_delta is set, before_swap_delta must be set
    function _validatePermissionsConflict(uint16 hooksRegistrationBitmap) internal pure {
        bytes32 parameters = bytes32(uint256(hooksRegistrationBitmap));
        if (
            parameters.hasOffsetEnabled(HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET)
                && !parameters.hasOffsetEnabled(HOOKS_BEFORE_SWAP_OFFSET)
        ) {
            revert Hooks.HookPermissionsValidationError();
        }

        if (
            parameters.hasOffsetEnabled(HOOKS_AFTER_SWAP_RETURNS_DELTA_OFFSET)
                && !parameters.hasOffsetEnabled(HOOKS_AFTER_SWAP_OFFSET)
        ) {
            revert Hooks.HookPermissionsValidationError();
        }

        if (
            parameters.hasOffsetEnabled(HOOKS_AFTER_ADD_LIQUIDIY_RETURNS_DELTA_OFFSET)
                && !parameters.hasOffsetEnabled(HOOKS_AFTER_ADD_LIQUIDITY_OFFSET)
        ) {
            revert Hooks.HookPermissionsValidationError();
        }

        if (
            parameters.hasOffsetEnabled(HOOKS_AFTER_REMOVE_LIQUIDIY_RETURNS_DELTA_OFFSET)
                && !parameters.hasOffsetEnabled(HOOKS_AFTER_REMOVE_LIQUIDITY_OFFSET)
        ) {
            revert Hooks.HookPermissionsValidationError();
        }
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, bytes calldata hookData)
        external
        override
        returns (bytes4)
    {
        bytes32 parameters = bytes32(uint256(_hooksRegistrationBitmap));
        if (!parameters.hasOffsetEnabled(HOOKS_BEFORE_INITIALIZE_OFFSET)) {
            revert HookNotImplemented();
        }

        for (uint256 i = 0; i < hooks.length; ++i) {
            ICLHooks hook = hooks[i];
            bytes32 hookParameters = bytes32(uint256(hook.getHooksRegistrationBitmap()));

            if (!hookParameters.hasOffsetEnabled(HOOKS_BEFORE_INITIALIZE_OFFSET)) {
                continue;
            }

            if (hook.beforeInitialize(sender, key, sqrtPriceX96, hookData) != ICLHooks.beforeInitialize.selector) {
                revert Hooks.InvalidHookResponse();
            }
        }

        return this.beforeInitialize.selector;
    }

    function afterInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick,
        bytes calldata hookData
    ) external override returns (bytes4) {
        bytes32 parameters = bytes32(uint256(_hooksRegistrationBitmap));
        if (!parameters.hasOffsetEnabled(HOOKS_AFTER_INITIALIZE_OFFSET)) {
            revert HookNotImplemented();
        }

        for (uint256 i = 0; i < hooks.length; ++i) {
            ICLHooks hook = hooks[i];
            bytes32 hookParameters = bytes32(uint256(hook.getHooksRegistrationBitmap()));

            if (!hookParameters.hasOffsetEnabled(HOOKS_AFTER_INITIALIZE_OFFSET)) {
                continue;
            }

            if (hook.afterInitialize(sender, key, sqrtPriceX96, tick, hookData) != ICLHooks.afterInitialize.selector) {
                revert Hooks.InvalidHookResponse();
            }
        }

        return this.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4) {
        bytes32 parameters = bytes32(uint256(_hooksRegistrationBitmap));
        if (!parameters.hasOffsetEnabled(HOOKS_BEFORE_ADD_LIQUIDITY_OFFSET)) {
            revert HookNotImplemented();
        }

        for (uint256 i = 0; i < hooks.length; ++i) {
            ICLHooks hook = hooks[i];
            bytes32 hookParameters = bytes32(uint256(hook.getHooksRegistrationBitmap()));

            if (!hookParameters.hasOffsetEnabled(HOOKS_BEFORE_ADD_LIQUIDITY_OFFSET)) {
                continue;
            }

            if (hook.beforeAddLiquidity(sender, key, params, hookData) != ICLHooks.beforeAddLiquidity.selector) {
                revert Hooks.InvalidHookResponse();
            }
        }

        return this.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override returns (bytes4, BalanceDelta) {
        bytes32 parameters = bytes32(uint256(_hooksRegistrationBitmap));
        if (!parameters.hasOffsetEnabled(HOOKS_AFTER_ADD_LIQUIDITY_OFFSET)) {
            revert HookNotImplemented();
        }

        BalanceDelta hookDelta = BalanceDeltaLibrary.ZERO_DELTA;
        for (uint256 i = 0; i < hooks.length; ++i) {
            ICLHooks hook = hooks[i];
            bytes32 hookParameters = bytes32(uint256(hook.getHooksRegistrationBitmap()));

            if (!hookParameters.hasOffsetEnabled(HOOKS_AFTER_ADD_LIQUIDITY_OFFSET)) {
                continue;
            }

            (bytes4 s, BalanceDelta d) = hook.afterAddLiquidity(sender, key, params, delta, hookData);
            if (s != ICLHooks.afterAddLiquidity.selector) {
                revert Hooks.InvalidHookResponse();
            }

            if (
                hookParameters.hasOffsetEnabled(HOOKS_AFTER_ADD_LIQUIDIY_RETURNS_DELTA_OFFSET)
                    && d != BalanceDeltaLibrary.ZERO_DELTA
            ) {
                delta = delta - d;
                hookDelta = hookDelta + d;
            }
        }

        return (this.afterAddLiquidity.selector, hookDelta);
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4) {
        bytes32 parameters = bytes32(uint256(_hooksRegistrationBitmap));
        if (!parameters.hasOffsetEnabled(HOOKS_BEFORE_REMOVE_LIQUIDITY_OFFSET)) {
            revert HookNotImplemented();
        }

        for (uint256 i = 0; i < hooks.length; ++i) {
            ICLHooks hook = hooks[i];
            bytes32 hookParameters = bytes32(uint256(hook.getHooksRegistrationBitmap()));

            if (!hookParameters.hasOffsetEnabled(HOOKS_BEFORE_REMOVE_LIQUIDITY_OFFSET)) {
                continue;
            }

            if (hook.beforeRemoveLiquidity(sender, key, params, hookData) != ICLHooks.beforeRemoveLiquidity.selector) {
                revert Hooks.InvalidHookResponse();
            }
        }

        return this.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override returns (bytes4, BalanceDelta) {
        bytes32 parameters = bytes32(uint256(_hooksRegistrationBitmap));
        if (!parameters.hasOffsetEnabled(HOOKS_AFTER_REMOVE_LIQUIDITY_OFFSET)) {
            revert HookNotImplemented();
        }

        BalanceDelta hookDelta = BalanceDeltaLibrary.ZERO_DELTA;
        for (uint256 i = 0; i < hooks.length; ++i) {
            ICLHooks hook = hooks[i];
            bytes32 hookParameters = bytes32(uint256(hook.getHooksRegistrationBitmap()));

            if (!hookParameters.hasOffsetEnabled(HOOKS_AFTER_REMOVE_LIQUIDITY_OFFSET)) {
                continue;
            }

            (bytes4 s, BalanceDelta d) = hook.afterRemoveLiquidity(sender, key, params, delta, hookData);
            if (s != ICLHooks.afterRemoveLiquidity.selector) {
                revert Hooks.InvalidHookResponse();
            }

            if (
                hookParameters.hasOffsetEnabled(HOOKS_AFTER_REMOVE_LIQUIDIY_RETURNS_DELTA_OFFSET)
                    && d != BalanceDeltaLibrary.ZERO_DELTA
            ) {
                delta = delta - d;
                hookDelta = hookDelta + d;
            }
        }

        return (this.afterRemoveLiquidity.selector, hookDelta);
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        bytes32 parameters = bytes32(uint256(_hooksRegistrationBitmap));
        if (!parameters.hasOffsetEnabled(HOOKS_BEFORE_SWAP_OFFSET)) {
            revert HookNotImplemented();
        }

        BeforeSwapDelta beforeSwapDelta = BeforeSwapDeltaLibrary.ZERO_DELTA;
        uint24 lpFeeOverride;
        for (uint256 i = 0; i < hooks.length; ++i) {
            ICLHooks hook = hooks[i];
            bytes32 hookParameters = bytes32(uint256(hook.getHooksRegistrationBitmap()));

            if (!hookParameters.hasOffsetEnabled(HOOKS_BEFORE_SWAP_OFFSET)) {
                continue;
            }

            (bytes4 s, BeforeSwapDelta d, uint24 f) = hook.beforeSwap(sender, key, params, hookData);
            if (s != ICLHooks.beforeSwap.selector) {
                revert Hooks.InvalidHookResponse();
            }

            if (key.fee.isDynamicLPFee()) {
                lpFeeOverride += f;
            }

            // if (hookParameters.hasOffsetEnabled(HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET)) {
            //     beforeSwapDelta += d;
            // }
        }

        return (this.beforeSwap.selector, beforeSwapDelta, lpFeeOverride);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override returns (bytes4, int128) {
        bytes32 parameters = bytes32(uint256(_hooksRegistrationBitmap));
        if (!parameters.hasOffsetEnabled(HOOKS_AFTER_SWAP_OFFSET)) {
            revert HookNotImplemented();
        }

        int128 hookDeltaUnspecified;
        for (uint256 i = 0; i < hooks.length; ++i) {
            ICLHooks hook = hooks[i];
            bytes32 hookParameters = bytes32(uint256(hook.getHooksRegistrationBitmap()));

            if (!hookParameters.hasOffsetEnabled(HOOKS_AFTER_SWAP_OFFSET)) {
                continue;
            }

            (bytes4 s, int128 d) = hook.afterSwap(sender, key, params, delta, hookData);
            if (s != ICLHooks.afterSwap.selector) {
                revert Hooks.InvalidHookResponse();
            }

            if (hookParameters.hasOffsetEnabled(HOOKS_AFTER_SWAP_RETURNS_DELTA_OFFSET)) {
                hookDeltaUnspecified += d;
            }
        }

        return (this.afterSwap.selector, hookDeltaUnspecified);
    }

    function beforeDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) external override returns (bytes4) {
        bytes32 parameters = bytes32(uint256(_hooksRegistrationBitmap));
        if (!parameters.hasOffsetEnabled(HOOKS_BEFORE_DONATE_OFFSET)) {
            revert HookNotImplemented();
        }

        for (uint256 i = 0; i < hooks.length; ++i) {
            ICLHooks hook = hooks[i];
            bytes32 hookParameters = bytes32(uint256(hook.getHooksRegistrationBitmap()));

            if (!hookParameters.hasOffsetEnabled(HOOKS_BEFORE_DONATE_OFFSET)) {
                continue;
            }

            if (hook.beforeDonate(sender, key, amount0, amount1, hookData) != ICLHooks.beforeDonate.selector) {
                revert Hooks.InvalidHookResponse();
            }
        }

        return this.beforeDonate.selector;
    }

    function afterDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) external override returns (bytes4) {
        bytes32 parameters = bytes32(uint256(_hooksRegistrationBitmap));
        if (!parameters.hasOffsetEnabled(HOOKS_AFTER_DONATE_OFFSET)) {
            revert HookNotImplemented();
        }

        for (uint256 i = 0; i < hooks.length; ++i) {
            ICLHooks hook = hooks[i];
            bytes32 hookParameters = bytes32(uint256(hook.getHooksRegistrationBitmap()));

            if (!hookParameters.hasOffsetEnabled(HOOKS_AFTER_DONATE_OFFSET)) {
                continue;
            }

            if (hook.afterDonate(sender, key, amount0, amount1, hookData) != ICLHooks.afterDonate.selector) {
                revert Hooks.InvalidHookResponse();
            }
        }

        return this.afterDonate.selector;
    }
}
