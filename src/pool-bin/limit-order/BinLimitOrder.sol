// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.19;

import {IBinPoolManager} from "@pancakeswap/v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {
    HOOKS_BEFORE_INITIALIZE_OFFSET,
    HOOKS_AFTER_INITIALIZE_OFFSET,
    HOOKS_BEFORE_MINT_OFFSET,
    HOOKS_AFTER_MINT_OFFSET,
    HOOKS_BEFORE_BURN_OFFSET,
    HOOKS_AFTER_BURN_OFFSET,
    HOOKS_BEFORE_SWAP_OFFSET,
    HOOKS_AFTER_SWAP_OFFSET,
    HOOKS_BEFORE_DONATE_OFFSET,
    HOOKS_AFTER_DONATE_OFFSET
} from "@pancakeswap/v4-core/src/pool-bin/interfaces/IBinHooks.sol";
import {FullMath} from "@pancakeswap/v4-core/src/pool-cl/libraries/FullMath.sol";
import {SafeCast} from "@pancakeswap/v4-core/src/libraries/SafeCast.sol";
import {BinPoolParametersHelper} from "@pancakeswap/v4-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {IPoolManager} from "@pancakeswap/v4-core/src/interfaces/IPoolManager.sol";
import {IVault} from "@pancakeswap/v4-core/src/interfaces/IVault.sol";
import {PoolId, PoolIdLibrary} from "@pancakeswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@pancakeswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@pancakeswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@pancakeswap/v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "@pancakeswap/v4-core/src/libraries/Hooks.sol";
import {BinPoolManager} from "@pancakeswap/v4-core/src/pool-bin/BinPoolManager.sol";
import {LiquidityConfigurations} from "@pancakeswap/v4-core/src/pool-bin/libraries/math/LiquidityConfigurations.sol";
import {PackedUint128Math} from "@pancakeswap/v4-core/src/pool-bin/libraries/math/PackedUint128Math.sol";
import {BinPool} from "@pancakeswap/v4-core/src/pool-bin/libraries/BinPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BinBaseHook} from "../BinBaseHook.sol";

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

/// @notice A hook enabling limit orders on a Bin pool. Users can place a limit
/// order by calling place(), cancel it by calling kill(), and withdraw it by
/// calling withdraw() when it's filled.
contract BinLimitOrder is BinBaseHook {
    using EpochLibrary for Epoch;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BinPoolParametersHelper for bytes32;
    using PackedUint128Math for uint128;
    using SafeERC20 for IERC20;

    /// @notice Place zero token amount
    error ZeroAmount();

    /// @notice Kill/Withdraw zero liquidity
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
        address indexed owner, Epoch indexed epoch, PoolKey key, uint24 binId, bool swapForY, uint256 liquidity
    );

    event Fill(Epoch indexed epoch, PoolKey key, uint24 binId, bool swapForY);

    event Kill(address indexed owner, Epoch indexed epoch, PoolKey key, uint24 binId, bool swapForY, uint256 liquidity);

    event Withdraw(address indexed owner, Epoch indexed epoch, uint256 liquidity);

    bytes internal constant ZERO_BYTES = bytes("");

    Epoch private constant EPOCH_DEFAULT = Epoch.wrap(0);

    mapping(PoolId => uint24) public activeIdLasts;
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
        uint256 liquidityTotal;
        mapping(address => uint256) liquidity;
    }

    mapping(bytes32 => Epoch) public epochs;
    mapping(Epoch => EpochInfo) public epochInfos;

    constructor(IBinPoolManager poolManager) BinBaseHook(poolManager) {}

    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return _hooksRegistrationBitmapFrom(
            Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeMint: false,
                afterMint: false,
                beforeBurn: false,
                afterBurn: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterMintReturnDelta: false,
                afterBurnReturnDelta: false
            })
        );
    }

    function getActiveIdLast(PoolId poolId) public view returns (uint24) {
        return activeIdLasts[poolId];
    }

    function setActiveIdLast(PoolId poolId, uint24 activeId) private {
        activeIdLasts[poolId] = activeId;
    }

    function getEpoch(PoolKey memory key, uint24 binId, bool swapForY) public view returns (Epoch) {
        return epochs[keccak256(abi.encode(key, binId, swapForY))];
    }

    function setEpoch(PoolKey memory key, uint24 binId, bool swapForY, Epoch epoch) private {
        epochs[keccak256(abi.encode(key, binId, swapForY))] = epoch;
    }

    function getEpochLiquidity(Epoch epoch, address owner) external view returns (uint256) {
        return epochInfos[epoch].liquidity[owner];
    }

    function afterInitialize(address sender, PoolKey calldata key, uint24 activeId, bytes calldata hookData)
        external
        override
        poolManagerOnly
        returns (bytes4)
    {
        setActiveIdLast(key.toId(), activeId);
        return this.afterInitialize.selector;
    }

    /// @dev After a swap, fill all limit orders whose prices have been crossed
    function afterSwap(
        address sender,
        PoolKey calldata key,
        bool swapForY,
        int128 amountSpecified,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override returns (bytes4, int128) {
        (uint24 activeId, uint24 lower, uint24 upper) = _getCrossedBins(key.toId());
        if (lower > upper) return (this.afterSwap.selector, 0);

        // note that a swapForY swap means that the pool is actually gaining token0, so limit
        // order fills are the opposite of swap fills, hence the inversion below
        for (; lower <= upper; ++lower) {
            _fillEpoch(key, lower, !swapForY);
        }

        setActiveIdLast(key.toId(), activeId);
        return (this.afterSwap.selector, 0);
    }

    function _fillEpoch(PoolKey calldata key, uint24 binId, bool swapForY) internal {
        Epoch epoch = getEpoch(key, binId, swapForY);
        if (!epoch.equals(EPOCH_DEFAULT)) {
            EpochInfo storage epochInfo = epochInfos[epoch];

            epochInfo.filled = true;

            uint256[] memory ids = new uint256[](1);
            ids[0] = binId;
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = uint256(epochInfo.liquidityTotal);
            BalanceDelta delta = poolManager.burn(
                key, IBinPoolManager.BurnParams({ids: ids, amountsToBurn: amounts, salt: bytes32(0)}), ZERO_BYTES
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

            setEpoch(key, binId, swapForY, EPOCH_DEFAULT);

            emit Fill(epoch, key, binId, swapForY);
        }
    }

    function _getCrossedBins(PoolId poolId) internal view returns (uint24 activeId, uint24 lower, uint24 upper) {
        (activeId,,) = poolManager.getSlot0(poolId);
        uint24 activeIdLast = getActiveIdLast(poolId);

        if (activeId < activeIdLast) {
            lower = activeId + 1;
            upper = activeIdLast;
        } else {
            lower = activeIdLast;
            upper = activeId - 1;
        }
    }

    /// @notice Place a limit order
    /// @param key The pool key
    /// @param binId The bin ID of the limit order
    /// @param swapForY The direction of the limit order
    /// @param amount The amount of token to place
    function place(PoolKey calldata key, uint24 binId, bool swapForY, uint128 amount)
        external
        onlyValidPools(key.hooks)
    {
        if (amount == 0) revert ZeroAmount();

        (uint256 liquidity) = abi.decode(
            vault.lock(abi.encodeCall(this.lockAcquiredPlace, (key, binId, swapForY, amount, msg.sender))), (uint256)
        );

        EpochInfo storage epochInfo;
        Epoch epoch = getEpoch(key, binId, swapForY);
        if (epoch.equals(EPOCH_DEFAULT)) {
            unchecked {
                setEpoch(key, binId, swapForY, epoch = epochNext);
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

        emit Place(msg.sender, epoch, key, binId, swapForY, liquidity);
    }

    function lockAcquiredPlace(PoolKey calldata key, uint24 binId, bool swapForY, uint128 amount, address owner)
        external
        selfOnly
        returns (uint256 liquidity)
    {
        (uint24 activeId,,) = poolManager.getSlot0(key.toId());
        if (binId == activeId) revert InRange();
        if (swapForY && binId < activeId) revert CrossedRange();
        if (!swapForY && binId > activeId) revert CrossedRange();

        uint64 distributionX;
        uint64 distributionY;
        bytes32 amountIn;
        if (swapForY) {
            distributionX = 1e18;
            distributionY = 0;
            amountIn = amount.encode(0);
        } else {
            distributionX = 0;
            distributionY = 1e18;
            amountIn = uint128(0).encode(amount);
        }
        bytes32[] memory liquidityConfigs = new bytes32[](1);
        liquidityConfigs[0] = LiquidityConfigurations.encodeParams(distributionX, distributionY, binId);

        (BalanceDelta delta, BinPool.MintArrays memory mintArray) = poolManager.mint(
            key,
            IBinPoolManager.MintParams({liquidityConfigs: liquidityConfigs, amountIn: amountIn, salt: bytes32(0)}),
            ZERO_BYTES
        );

        liquidity = mintArray.liquidityMinted[0];

        if (delta.amount0() < 0) {
            vault.sync(key.currency0);
            IERC20(Currency.unwrap(key.currency0)).safeTransferFrom(
                owner, address(vault), uint256(uint128(-delta.amount0()))
            );
            vault.settle(key.currency0);
        } else {
            vault.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1)).safeTransferFrom(
                owner, address(vault), uint256(uint128(-delta.amount1()))
            );
            vault.settle(key.currency1);
        }
    }

    /// @notice Cancel a limit order
    /// @param key The pool key
    /// @param binId The bin ID of the limit order
    /// @param swapForY The direction of the limit order
    /// @param to The address of the recipient
    /// @return amount0 The amount of token0 withdrawn
    /// @return amount1 The amount of token1 withdrawn
    function kill(PoolKey calldata key, uint24 binId, bool swapForY, address to)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        Epoch epoch = getEpoch(key, binId, swapForY);
        EpochInfo storage epochInfo = epochInfos[epoch];

        if (epochInfo.filled) revert Filled();

        uint256 liquidity = epochInfo.liquidity[msg.sender];
        if (liquidity == 0) revert ZeroLiquidity();
        delete epochInfo.liquidity[msg.sender];
        uint256 liquidityTotal = epochInfo.liquidityTotal;
        epochInfo.liquidityTotal = liquidityTotal - liquidity;

        uint256 amount0Fee;
        uint256 amount1Fee;
        (amount0, amount1, amount0Fee, amount1Fee) = abi.decode(
            vault.lock(abi.encodeCall(this.lockAcquiredKill, (key, binId, liquidity, to, liquidity == liquidityTotal))),
            (uint256, uint256, uint256, uint256)
        );

        unchecked {
            epochInfo.token0Total += amount0Fee;
            epochInfo.token1Total += amount1Fee;
        }

        emit Kill(msg.sender, epoch, key, binId, swapForY, liquidity);
    }

    function lockAcquiredKill(
        PoolKey calldata key,
        uint24 binId,
        uint256 liquidityDelta,
        address to,
        bool removingAllLiquidity
    ) external selfOnly returns (uint256 amount0, uint256 amount1, uint128 amount0Fee, uint128 amount1Fee) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = binId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = liquidityDelta;
        BalanceDelta delta = poolManager.burn(
            key, IBinPoolManager.BurnParams({ids: ids, amountsToBurn: amounts, salt: bytes32(0)}), ZERO_BYTES
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

        uint256 liquidity = epochInfo.liquidity[msg.sender];
        if (liquidity == 0) revert ZeroLiquidity();
        delete epochInfo.liquidity[msg.sender];

        uint256 token0Total = epochInfo.token0Total;
        uint256 token1Total = epochInfo.token1Total;
        uint256 liquidityTotal = epochInfo.liquidityTotal;

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
