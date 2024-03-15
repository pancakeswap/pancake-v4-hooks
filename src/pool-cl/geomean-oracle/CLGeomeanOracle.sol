// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.19;

import {ICLPoolManager} from "@pancakeswap/v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {TickMath} from "@pancakeswap/v4-core/src/pool-cl/libraries/TickMath.sol";
import {CLPoolParametersHelper} from "@pancakeswap/v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {IPoolManager} from "@pancakeswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@pancakeswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@pancakeswap/v4-core/src/types/PoolKey.sol";
import {Hooks} from "@pancakeswap/v4-core/src/libraries/Hooks.sol";

import {CLBaseHook} from "../CLBaseHook.sol";
import {Oracle} from "./libraries/Oracle.sol";

/// @notice A hook that allows a CL pool to act as an oracle. Pools that use
/// this hook must have full range tick spacing and liquidity is always
/// permanently locked in these pools.
contract CLGeomeanOracle is CLBaseHook {
    using Oracle for Oracle.Observation[65535];
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;

    /// @notice Oracle pools do not have fees
    error OnlyOneOraclePoolAllowed();

    /// @notice Oracle positions must be full range
    error OraclePositionsMustBeFullRange();

    /// @notice Oracle pools must have liquidity locked
    error OraclePoolMustLockLiquidity();

    /// @member index The index of the last written observation for the pool
    /// @member cardinality The cardinality of the observations array for the pool
    /// @member cardinalityNext The cardinality target of the observations array for the pool, which will replace cardinality when enough observations are written
    struct ObservationState {
        uint16 index;
        uint16 cardinality;
        uint16 cardinalityNext;
    }

    /// @notice The list of observations for a given pool ID
    mapping(PoolId => Oracle.Observation[65535]) public observations;
    /// @notice The current observation array state for the given pool ID
    mapping(PoolId => ObservationState) public states;

    /// @notice Returns the observation for the given pool key and observation index
    function getObservation(PoolKey calldata key, uint256 index)
        external
        view
        returns (Oracle.Observation memory observation)
    {
        observation = observations[PoolId.wrap(keccak256(abi.encode(key)))][index];
    }

    /// @notice Returns the state for the given pool key
    function getState(PoolKey calldata key) external view returns (ObservationState memory state) {
        state = states[PoolId.wrap(keccak256(abi.encode(key)))];
    }

    /// @dev For mocking
    function _blockTimestamp() internal view virtual returns (uint32) {
        return uint32(block.timestamp);
    }

    constructor(ICLPoolManager poolManager) CLBaseHook(poolManager) {}

    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return _hooksRegistrationBitmapFrom(
            Permissions({
                beforeInitialize: true,
                afterInitialize: true,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                noOp: false
            })
        );
    }

    function beforeInitialize(address, PoolKey calldata key, uint160, bytes calldata)
        external
        view
        override
        poolManagerOnly
        returns (bytes4)
    {
        // This is to limit the fragmentation of pools using this oracle hook.
        // In other words, there may only be one pool per pair of tokens that use
        // this hook. The tick spacing is set to the maximum because we only allow
        // full range liquidity in this pool.
        if (key.fee != 0 || key.parameters.getTickSpacing() != poolManager.MAX_TICK_SPACING()) {
            revert OnlyOneOraclePoolAllowed();
        }
        return this.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24, bytes calldata)
        external
        override
        poolManagerOnly
        returns (bytes4)
    {
        PoolId id = key.toId();
        (states[id].cardinality, states[id].cardinalityNext) = observations[id].initialize(_blockTimestamp());
        return this.afterInitialize.selector;
    }

    /// @dev Called before any action that potentially modifies pool price or liquidity, such as swap or modify position
    function _updatePool(PoolKey calldata key) private {
        PoolId id = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(id);

        uint128 liquidity = poolManager.getLiquidity(id);

        (states[id].index, states[id].cardinality) = observations[id].write(
            states[id].index, _blockTimestamp(), tick, liquidity, states[id].cardinality, states[id].cardinalityNext
        );
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4) {
        int24 maxTickSpacing = poolManager.MAX_TICK_SPACING();
        if (
            params.tickLower != TickMath.minUsableTick(maxTickSpacing)
                || params.tickUpper != TickMath.maxUsableTick(maxTickSpacing)
        ) revert OraclePositionsMustBeFullRange();
        _updatePool(key);
        return this.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override poolManagerOnly returns (bytes4) {
        revert OraclePoolMustLockLiquidity();
    }

    function beforeSwap(address, PoolKey calldata key, ICLPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        poolManagerOnly
        returns (bytes4)
    {
        _updatePool(key);
        return this.beforeSwap.selector;
    }

    /// @notice Observe the given pool for the timestamps
    function observe(PoolKey calldata key, uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        PoolId id = key.toId();

        ObservationState memory state = states[id];

        (, int24 tick,,) = poolManager.getSlot0(id);

        uint128 liquidity = poolManager.getLiquidity(id);

        return observations[id].observe(_blockTimestamp(), secondsAgos, tick, state.index, liquidity, state.cardinality);
    }

    /// @notice Increase the cardinality target for the given pool
    function increaseCardinalityNext(PoolKey calldata key, uint16 cardinalityNext)
        external
        returns (uint16 cardinalityNextOld, uint16 cardinalityNextNew)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));

        ObservationState storage state = states[id];

        cardinalityNextOld = state.cardinalityNext;
        cardinalityNextNew = observations[id].grow(cardinalityNextOld, cardinalityNext);
        state.cardinalityNext = cardinalityNextNew;
    }
}
