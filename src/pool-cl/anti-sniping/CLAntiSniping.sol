// SPDX-License-Identifier: UNLICENSED
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {CLBaseHook} from "../CLBaseHook.sol";
import {IPoolManager} from "pancake-v4-core/src/interfaces/IPoolManager.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {Tick} from "pancake-v4-core/src/pool-cl/libraries/Tick.sol";
import {Hooks} from "pancake-v4-core/src/libraries/Hooks.sol";
import {CLPosition} from "pancake-v4-core/src/pool-cl/libraries/CLPosition.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "pancake-v4-core/src/types/BeforeSwapDelta.sol";
import {FullMath} from "pancake-v4-core/src/pool-cl/libraries/FullMath.sol";
import {FixedPoint128} from "pancake-v4-core/src/pool-cl/libraries/FixedPoint128.sol";
import {SafeCast} from "pancake-v4-core/src/libraries/SafeCast.sol";

/// @title AntiSnipingHook
/// @notice A PancakeSwap V4 hook that prevents MEV sniping attacks by enforcing time locks on positions and redistributing fees accrued in the initial block to legitimate liquidity providers.
/// @dev Positions are time-locked, and fees accrued in the first block after position creation are redistributed.
contract CLAntiSniping is CLBaseHook {
    using PoolIdLibrary for PoolKey;
    using SafeCast for *;

    /// @notice Maps a pool ID and position key to the block number when the position was created.
    mapping(PoolId => mapping(bytes32 => uint256)) public positionCreationBlock;

    /// @notice The duration (in blocks) for which a position must remain locked before it can be removed.
    uint128 public positionLockDuration;

    /// @notice The maximum number of positions that can be created in the same block per pool to prevent excessive gas usage.
    uint128 public sameBlockPositionsLimit;

    mapping(PoolId => uint256) lastProcessedBlockNumber;

    mapping(PoolId => bytes32[]) positionsCreatedInLastBlock;

    struct LiquidityParams {
        int24 tickLower;
        int24 tickUpper;
        bytes32 salt;
        address sender;
    }
    mapping(bytes32 => LiquidityParams) positionKeyToLiquidityParams;

    /// @notice Maps a pool ID and position key to the fees accrued in the first block.
    mapping(PoolId => mapping(bytes32 => uint256)) public firstBlockFeesToken0;
    mapping(PoolId => mapping(bytes32 => uint256)) public firstBlockFeesToken1;

    /// @notice Error thrown when a position is still locked and cannot be removed.
    error PositionLocked();

    /// @notice Error thrown when attempting to modify an existing position.
    /// @dev Positions cannot be modified after creation to prevent edge cases.
    error PositionAlreadyExists();

    /// @notice Error thrown when attempting to partially withdraw from a position.
    error PositionPartiallyWithdrawn();

    /// @notice Error thrown when too many positions are opened in the same block.
    /// @dev Limits the number of positions per block to prevent excessive gas consumption.
    error TooManyPositionsInSameBlock();

    constructor(ICLPoolManager poolManager, uint128 _positionLockDuration, uint128 _sameBlockPositionsLimit)
        CLBaseHook(poolManager)
    {
        positionLockDuration = _positionLockDuration;
        sameBlockPositionsLimit = _sameBlockPositionsLimit;
    }

    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return _hooksRegistrationBitmapFrom(
            Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: true,
                afterAddLiquidity: true,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: true,
                afterDonate: false,
                beforeSwapReturnsDelta: false,
                afterSwapReturnsDelta: false,
                afterAddLiquidiyReturnsDelta: false,
                afterRemoveLiquidiyReturnsDelta: true
            })
        );
    }

    /// @notice Collects fee information for positions created in the last processed block.
    /// @dev This is called in all of the before hooks (except init) and can also be called manually.
    /// @param poolId The identifier of the pool.
    function collectLastBlockInfo(PoolId poolId) public {
        if (block.number <= lastProcessedBlockNumber[poolId]) {
            return;
        }
        lastProcessedBlockNumber[poolId] = block.number;
        for (uint256 i = 0; i < positionsCreatedInLastBlock[poolId].length; i++) {
            bytes32 positionKey = positionsCreatedInLastBlock[poolId][i];
            LiquidityParams memory params = positionKeyToLiquidityParams[positionKey];
            CLPosition.Info memory info = poolManager.getPosition(poolId, params.sender, params.tickLower, params.tickUpper, params.salt);
            (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = _getFeeGrowthInside(poolId, params.sender, params.tickLower, params.tickUpper, params.salt);
            firstBlockFeesToken0[poolId][positionKey] =
                                FullMath.mulDiv(feeGrowthInside0X128 - info.feeGrowthInside0LastX128, info.liquidity, FixedPoint128.Q128);
            firstBlockFeesToken1[poolId][positionKey] =
                                FullMath.mulDiv(feeGrowthInside1X128 - info.feeGrowthInside1LastX128, info.liquidity, FixedPoint128.Q128);
        }
        delete positionsCreatedInLastBlock[poolId];
    }

    /// @notice Handles logic after removing liquidity, redistributing first-block fees if applicable.
    /// @dev Donates first-block accrued fees to the pool if liquidity remains; otherwise, returns them to the sender.
    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        bytes32 positionKey = CLPosition.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);

        BalanceDelta hookDelta;
        if (poolManager.getLiquidity(poolId) != 0) {
            hookDelta = toBalanceDelta(
                firstBlockFeesToken0[poolId][positionKey].toInt128(),
                firstBlockFeesToken1[poolId][positionKey].toInt128()
            );
            poolManager.donate(
                key, firstBlockFeesToken0[poolId][positionKey], firstBlockFeesToken1[poolId][positionKey], new bytes(0)
            );
        } else {
            // If the pool is empty, the fees are not donated and are returned to the sender
            hookDelta = BalanceDeltaLibrary.ZERO_DELTA;
        }
        return (this.afterRemoveLiquidity.selector, hookDelta);
    }

    /// @notice Handles logic before adding liquidity, enforcing position creation constraints.
    /// @dev Records position creation block and ensures the position doesn't already exist or exceed the same block limit.
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external override returns (bytes4) {
        PoolId poolId = key.toId();
        collectLastBlockInfo(poolId);
        bytes32 positionKey = CLPosition.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);
        LiquidityParams storage liqParams = positionKeyToLiquidityParams[positionKey];
        liqParams.sender = sender;
        liqParams.tickLower = params.tickLower;
        liqParams.tickUpper = params.tickUpper;
        liqParams.salt = params.salt;
        positionKeyToLiquidityParams[positionKey] = liqParams;
        if (positionCreationBlock[poolId][positionKey] != 0) revert PositionAlreadyExists();
        if (positionsCreatedInLastBlock[poolId].length >= sameBlockPositionsLimit) revert TooManyPositionsInSameBlock();
        positionCreationBlock[poolId][positionKey] = block.number;
        positionsCreatedInLastBlock[poolId].push(positionKey);
        return (this.beforeAddLiquidity.selector);
    }

    /// @notice Handles logic before removing liquidity, enforcing position lock duration and full withdrawal.
    /// @dev Checks that the position lock duration has passed and disallows partial withdrawals.
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external override returns (bytes4) {
        PoolId poolId = key.toId();
        collectLastBlockInfo(poolId);
        bytes32 positionKey = CLPosition.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);
        if (block.number - positionCreationBlock[poolId][positionKey] < positionLockDuration) revert PositionLocked();
        CLPosition.Info memory info = poolManager.getPosition(poolId, sender, params.tickLower, params.tickUpper, params.salt);
        if (int128(info.liquidity) + params.liquidityDelta != 0) revert PositionPartiallyWithdrawn();
        return (this.beforeRemoveLiquidity.selector);
    }

    /// @notice Handles logic before a swap occurs.
    /// @dev Collects fee information for positions created in the last processed block.
    function beforeSwap(address, PoolKey calldata key, ICLPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        collectLastBlockInfo(poolId);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Handles logic before a donation occurs.
    /// @dev Collects fee information for positions created in the last processed block.
    function beforeDonate(address, PoolKey calldata key, uint256, uint256, bytes calldata)
        external
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        collectLastBlockInfo(poolId);
        return (this.beforeDonate.selector);
    }

    function _getFeeGrowthInside(
        PoolId poolId,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) internal view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        (, int24 tickCurrent,,) = poolManager.getSlot0(poolId);
        Tick.Info memory lower = poolManager.getPoolTickInfo(poolId, tickLower);
        Tick.Info memory upper = poolManager.getPoolTickInfo(poolId, tickUpper);

        (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128) = poolManager.getFeeGrowthGlobals(poolId);

        // calculate fee growth below
        uint256 feeGrowthBelow0X128;
        uint256 feeGrowthBelow1X128;

        unchecked {
            if (tickCurrent >= tickLower) {
                feeGrowthBelow0X128 = lower.feeGrowthOutside0X128;
                feeGrowthBelow1X128 = lower.feeGrowthOutside1X128;
            } else {
                feeGrowthBelow0X128 = feeGrowthGlobal0X128 - lower.feeGrowthOutside0X128;
                feeGrowthBelow1X128 = feeGrowthGlobal1X128 - lower.feeGrowthOutside1X128;
            }

            // calculate fee growth above
            uint256 feeGrowthAbove0X128;
            uint256 feeGrowthAbove1X128;
            if (tickCurrent < tickUpper) {
                feeGrowthAbove0X128 = upper.feeGrowthOutside0X128;
                feeGrowthAbove1X128 = upper.feeGrowthOutside1X128;
            } else {
                feeGrowthAbove0X128 = feeGrowthGlobal0X128 - upper.feeGrowthOutside0X128;
                feeGrowthAbove1X128 = feeGrowthGlobal1X128 - upper.feeGrowthOutside1X128;
            }

            feeGrowthInside0X128 = feeGrowthGlobal0X128 - feeGrowthBelow0X128 - feeGrowthAbove0X128;
            feeGrowthInside1X128 = feeGrowthGlobal1X128 - feeGrowthBelow1X128 - feeGrowthAbove1X128;
        }
    }
}