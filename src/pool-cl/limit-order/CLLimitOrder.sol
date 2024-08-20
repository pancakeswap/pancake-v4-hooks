// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.19;

import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {FullMath} from "pancake-v4-core/src/pool-cl/libraries/FullMath.sol";
import {SafeCast} from "pancake-v4-core/src/libraries/SafeCast.sol";
import {CLPoolParametersHelper} from "pancake-v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {IPoolManager} from "pancake-v4-core/src/interfaces/IPoolManager.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "pancake-v4-core/src/libraries/Hooks.sol";
import {CLPoolManager} from "pancake-v4-core/src/pool-cl/CLPoolManager.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC1155Receiver} from "openzeppelin-contracts/contracts/token/ERC1155/IERC1155Receiver.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {CLBaseHook} from "../CLBaseHook.sol";

type Epoch is uint232;

library EpochLibrary {
    function equals(Epoch a, Epoch b) internal pure returns (bool) {
        return Epoch.unwrap(a) == Epoch.unwrap(b);
    }

    function unsafeIncrement(Epoch a) internal pure returns (Epoch) {
        unchecked {
            return Epoch.wrap(Epoch.unwrap(a) + 1);
        }
    }
}

/// @notice A hook enabling limit orders on a CL pool. Users can place a limit
/// order by calling place(), cancel it by calling kill(), and withdraw it by
/// calling withdraw() when it's filled.
contract CLLimitOrder is CLBaseHook {
    using EpochLibrary for Epoch;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using CLPoolParametersHelper for bytes32;
    using SafeERC20 for IERC20;

    /// @notice Place/Kill/Withdraw zero liquidity
    error ZeroLiquidity();

    /// @notice The limit order price is in range
    error InRange();

    /// @notice The limit order direction is wrong
    error CrossedRange();

    /// @notice The limit order is already filled
    error Filled();

    /// @notice The limit order has not yet been filled
    error NotFilled();

    event Place(
        address indexed owner, Epoch indexed epoch, PoolKey key, int24 tickLower, bool zeroForOne, uint128 liquidity
    );

    event Fill(Epoch indexed epoch, PoolKey key, int24 tickLower, bool zeroForOne);

    event Kill(
        address indexed owner, Epoch indexed epoch, PoolKey key, int24 tickLower, bool zeroForOne, uint128 liquidity
    );

    event Withdraw(address indexed owner, Epoch indexed epoch, uint128 liquidity);

    bytes internal constant ZERO_BYTES = bytes("");

    Epoch private constant EPOCH_DEFAULT = Epoch.wrap(0);

    mapping(PoolId => int24) public tickLowerLasts;
    Epoch public epochNext = Epoch.wrap(1);

    /// @member filled Whether the epoch has been filled
    /// @member currency0 currency0 of the PoolKey
    /// @member currency1 currency1 of the PoolKey
    /// @member token0Total Total amount of token0 filled
    /// @member token1Total Total amount of token1 filled
    /// @member liquidityTotal Total liquidity placed
    /// @member liquidity The liquidity placed by the user
    struct EpochInfo {
        bool filled;
        Currency currency0;
        Currency currency1;
        uint256 token0Total;
        uint256 token1Total;
        uint128 liquidityTotal;
        mapping(address => uint128) liquidity;
    }

    mapping(bytes32 => Epoch) public epochs;
    mapping(Epoch => EpochInfo) public epochInfos;

    constructor(ICLPoolManager poolManager) CLBaseHook(poolManager) {}

    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return _hooksRegistrationBitmapFrom(
            Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnsDelta: false,
                afterSwapReturnsDelta: false,
                afterAddLiquidiyReturnsDelta: false,
                afterRemoveLiquidiyReturnsDelta: false
            })
        );
    }

    function getTickLowerLast(PoolId poolId) public view returns (int24) {
        return tickLowerLasts[poolId];
    }

    function setTickLowerLast(PoolId poolId, int24 tickLower) private {
        tickLowerLasts[poolId] = tickLower;
    }

    function getEpoch(PoolKey memory key, int24 tickLower, bool zeroForOne) public view returns (Epoch) {
        return epochs[keccak256(abi.encode(key, tickLower, zeroForOne))];
    }

    function setEpoch(PoolKey memory key, int24 tickLower, bool zeroForOne, Epoch epoch) private {
        epochs[keccak256(abi.encode(key, tickLower, zeroForOne))] = epoch;
    }

    function getEpochLiquidity(Epoch epoch, address owner) external view returns (uint256) {
        return epochInfos[epoch].liquidity[owner];
    }

    function getTick(PoolId poolId) private view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(poolId);
    }

    function getTickLower(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--; // round towards negative infinity
        return compressed * tickSpacing;
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick, bytes calldata)
        external
        override
        poolManagerOnly
        returns (bytes4)
    {
        setTickLowerLast(key.toId(), getTickLower(tick, key.parameters.getTickSpacing()));
        return this.afterInitialize.selector;
    }

    /// @dev After a swap, fill all limit orders whose prices have been crossed
    function afterSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4, int128) {
        int24 tickSpacing = key.parameters.getTickSpacing();
        (int24 tickLower, int24 lower, int24 upper) = _getCrossedTicks(key.toId(), tickSpacing);
        if (lower > upper) return (this.afterSwap.selector, 0);

        // note that a zeroForOne swap means that the pool is actually gaining token0, so limit
        // order fills are the opposite of swap fills, hence the inversion below
        bool zeroForOne = !params.zeroForOne;
        for (; lower <= upper; lower += tickSpacing) {
            _fillEpoch(key, lower, zeroForOne);
        }

        setTickLowerLast(key.toId(), tickLower);
        return (this.afterSwap.selector, 0);
    }

    function _fillEpoch(PoolKey calldata key, int24 lower, bool zeroForOne) internal {
        Epoch epoch = getEpoch(key, lower, zeroForOne);
        if (!epoch.equals(EPOCH_DEFAULT)) {
            EpochInfo storage epochInfo = epochInfos[epoch];

            epochInfo.filled = true;

            (BalanceDelta delta,) = poolManager.modifyLiquidity(
                key,
                ICLPoolManager.ModifyLiquidityParams({
                    tickLower: lower,
                    tickUpper: lower + key.parameters.getTickSpacing(),
                    liquidityDelta: -int256(uint256(epochInfo.liquidityTotal)),
                    salt: bytes32(0)
                }),
                ZERO_BYTES
            );

            uint256 amount0;
            uint256 amount1;
            if (delta.amount0() > 0) {
                vault.mint(address(this), key.currency0, amount0 = uint128(delta.amount0()));
            }
            if (delta.amount1() > 0) {
                vault.mint(address(this), key.currency1, amount1 = uint128(delta.amount1()));
            }

            unchecked {
                epochInfo.token0Total += amount0;
                epochInfo.token1Total += amount1;
            }

            setEpoch(key, lower, zeroForOne, EPOCH_DEFAULT);

            emit Fill(epoch, key, lower, zeroForOne);
        }
    }

    function _getCrossedTicks(PoolId poolId, int24 tickSpacing)
        internal
        view
        returns (int24 tickLower, int24 lower, int24 upper)
    {
        tickLower = getTickLower(getTick(poolId), tickSpacing);
        int24 tickLowerLast = getTickLowerLast(poolId);

        if (tickLower < tickLowerLast) {
            lower = tickLower + tickSpacing;
            upper = tickLowerLast;
        } else {
            lower = tickLowerLast;
            upper = tickLower - tickSpacing;
        }
    }

    /// @notice Place a limit order
    /// @param key The pool key
    /// @param tickLower The lower tick of the limit order
    /// @param zeroForOne The direction of the limit order
    /// @param liquidity The amount of liquidity to place
    function place(PoolKey calldata key, int24 tickLower, bool zeroForOne, uint128 liquidity)
        external
        onlyValidPools(key.hooks)
    {
        if (liquidity == 0) revert ZeroLiquidity();

        vault.lock(
            abi.encodeCall(this.lockAcquiredPlace, (key, tickLower, zeroForOne, int256(uint256(liquidity)), msg.sender))
        );

        EpochInfo storage epochInfo;
        Epoch epoch = getEpoch(key, tickLower, zeroForOne);
        if (epoch.equals(EPOCH_DEFAULT)) {
            unchecked {
                setEpoch(key, tickLower, zeroForOne, epoch = epochNext);
                // since epoch was just assigned the current value of epochNext,
                // this is equivalent to epochNext++, which is what's intended,
                // and it saves an SLOAD
                epochNext = epoch.unsafeIncrement();
            }
            epochInfo = epochInfos[epoch];
            epochInfo.currency0 = key.currency0;
            epochInfo.currency1 = key.currency1;
        } else {
            epochInfo = epochInfos[epoch];
        }

        unchecked {
            epochInfo.liquidityTotal += liquidity;
            epochInfo.liquidity[msg.sender] += liquidity;
        }

        emit Place(msg.sender, epoch, key, tickLower, zeroForOne, liquidity);
    }

    function lockAcquiredPlace(
        PoolKey calldata key,
        int24 tickLower,
        bool zeroForOne,
        int256 liquidityDelta,
        address owner
    ) external selfOnly {
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickLower + key.parameters.getTickSpacing(),
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        if (delta.amount0() < 0) {
            if (delta.amount1() != 0) revert InRange();
            if (!zeroForOne) revert CrossedRange();
            vault.sync(key.currency0);
            IERC20(Currency.unwrap(key.currency0)).safeTransferFrom(
                owner, address(vault), uint256(uint128(-delta.amount0()))
            );
            vault.settle(key.currency0);
        } else {
            if (delta.amount0() != 0) revert InRange();
            if (zeroForOne) revert CrossedRange();
            vault.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1)).safeTransferFrom(
                owner, address(vault), uint256(uint128(-delta.amount1()))
            );
            vault.settle(key.currency1);
        }
    }

    /// @notice Cancel a limit order
    /// @param key The pool key
    /// @param tickLower The lower tick of the limit order
    /// @param zeroForOne The direction of the limit order
    /// @param to The address of the recipient
    /// @return amount0 The amount of token0 withdrawn
    /// @return amount1 The amount of token1 withdrawn
    function kill(PoolKey calldata key, int24 tickLower, bool zeroForOne, address to)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        Epoch epoch = getEpoch(key, tickLower, zeroForOne);
        EpochInfo storage epochInfo = epochInfos[epoch];

        if (epochInfo.filled) revert Filled();

        uint128 liquidity = epochInfo.liquidity[msg.sender];
        if (liquidity == 0) revert ZeroLiquidity();
        delete epochInfo.liquidity[msg.sender];
        uint128 liquidityTotal = epochInfo.liquidityTotal;
        epochInfo.liquidityTotal = liquidityTotal - liquidity;

        uint256 amount0Fee;
        uint256 amount1Fee;
        (amount0, amount1, amount0Fee, amount1Fee) = abi.decode(
            vault.lock(
                abi.encodeCall(
                    this.lockAcquiredKill,
                    (key, tickLower, -int256(uint256(liquidity)), to, liquidity == liquidityTotal)
                )
            ),
            (uint256, uint256, uint256, uint256)
        );

        unchecked {
            epochInfo.token0Total += amount0Fee;
            epochInfo.token1Total += amount1Fee;
        }

        emit Kill(msg.sender, epoch, key, tickLower, zeroForOne, liquidity);
    }

    function lockAcquiredKill(
        PoolKey calldata key,
        int24 tickLower,
        int256 liquidityDelta,
        address to,
        bool removingAllLiquidity
    ) external selfOnly returns (uint256 amount0, uint256 amount1, uint128 amount0Fee, uint128 amount1Fee) {
        int24 tickUpper = tickLower + key.parameters.getTickSpacing();

        // because `modifyLiquidity` includes not just principal value but also fees, we cannot allocate
        // the proceeds pro-rata. if we were to do so, users who have been in a limit order that's partially filled
        // could be unfairly diluted by a user sychronously placing then killing a limit order to skim off fees.
        // to prevent this, we allocate all fee revenue to remaining limit order placers, unless this is the last order.
        if (!removingAllLiquidity) {
            (BalanceDelta deltaFee,) = poolManager.modifyLiquidity(
                key,
                ICLPoolManager.ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: 0,
                    salt: bytes32(0)
                }),
                ZERO_BYTES
            );

            if (deltaFee.amount0() > 0) {
                vault.mint(address(this), key.currency0, amount0Fee = uint128(deltaFee.amount0()));
            }
            if (deltaFee.amount1() > 0) {
                vault.mint(address(this), key.currency1, amount1Fee = uint128(deltaFee.amount1()));
            }
        }

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        if (delta.amount0() > 0) {
            vault.take(key.currency0, to, amount0 = uint128(delta.amount0()));
        }
        if (delta.amount1() > 0) {
            vault.take(key.currency1, to, amount1 = uint128(delta.amount1()));
        }
    }

    /// @notice Withdraw a filled limit order
    /// @param epoch The epoch of the limit order
    /// @param to The address of the recipient
    /// @return amount0 The amount of token0 withdrawn
    /// @return amount1 The amount of token1 withdrawn
    function withdraw(Epoch epoch, address to) external returns (uint256 amount0, uint256 amount1) {
        EpochInfo storage epochInfo = epochInfos[epoch];

        if (!epochInfo.filled) revert NotFilled();

        uint128 liquidity = epochInfo.liquidity[msg.sender];
        if (liquidity == 0) revert ZeroLiquidity();
        delete epochInfo.liquidity[msg.sender];

        uint256 token0Total = epochInfo.token0Total;
        uint256 token1Total = epochInfo.token1Total;
        uint128 liquidityTotal = epochInfo.liquidityTotal;

        amount0 = FullMath.mulDiv(token0Total, liquidity, liquidityTotal);
        amount1 = FullMath.mulDiv(token1Total, liquidity, liquidityTotal);

        epochInfo.token0Total = token0Total - amount0;
        epochInfo.token1Total = token1Total - amount1;
        epochInfo.liquidityTotal = liquidityTotal - liquidity;

        vault.lock(
            abi.encodeCall(this.lockAcquiredWithdraw, (epochInfo.currency0, epochInfo.currency1, amount0, amount1, to))
        );

        emit Withdraw(msg.sender, epoch, liquidity);
    }

    function lockAcquiredWithdraw(
        Currency currency0,
        Currency currency1,
        uint256 token0Amount,
        uint256 token1Amount,
        address to
    ) external selfOnly {
        if (token0Amount > 0) {
            vault.burn(address(this), currency0, token0Amount);
            vault.take(currency0, to, token0Amount);
        }
        if (token1Amount > 0) {
            vault.burn(address(this), currency1, token1Amount);
            vault.take(currency1, to, token1Amount);
        }
    }
}
