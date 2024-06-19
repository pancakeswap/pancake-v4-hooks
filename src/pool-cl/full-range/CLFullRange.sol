// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.19;

import {ICLPoolManager} from "@pancakeswap/v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {TickMath} from "@pancakeswap/v4-core/src/pool-cl/libraries/TickMath.sol";
import {TickBitmap} from "@pancakeswap/v4-core/src/pool-cl/libraries/TickBitmap.sol";
import {SqrtPriceMath} from "@pancakeswap/v4-core/src/pool-cl/libraries/SqrtPriceMath.sol";
import {FixedPoint96} from "@pancakeswap/v4-core/src/pool-cl/libraries/FixedPoint96.sol";
import {CLPoolParametersHelper} from "@pancakeswap/v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {IPoolManager} from "@pancakeswap/v4-core/src/interfaces/IPoolManager.sol";
import {IVault} from "@pancakeswap/v4-core/src/interfaces/IVault.sol";
import {PoolId, PoolIdLibrary} from "@pancakeswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@pancakeswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@pancakeswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@pancakeswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolKey} from "@pancakeswap/v4-core/src/types/PoolKey.sol";
import {Hooks} from "@pancakeswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@pancakeswap/v4-core/src/libraries/SafeCast.sol";
import {FullMath} from "@pancakeswap/v4-core/src/pool-cl/libraries/FullMath.sol";
import {CLPoolManager} from "@pancakeswap/v4-core/src/pool-cl/CLPoolManager.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CLBaseHook} from "../CLBaseHook.sol";
import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {PancakeV4ERC20} from "./libraries/PancakeV4ERC20.sol";

/// @notice A hook that makes a CL pool allow only full range liquidity, which
/// essentialy makes it a v2 pool.
contract CLFullRange is CLBaseHook {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using SafeCast for uint128;
    using CLPoolParametersHelper for bytes32;

    /// @notice Interact with a non-initialized pool
    error PoolNotInitialized();

    /// @notice The tick spacing is not the default, which is 60
    error TickSpacingNotDefault();

    /// @notice The liquidity doesn't meet the minimum
    error LiquidityDoesntMeetMinimum();

    /// @notice The sender is not the hook
    error SenderMustBeHook();

    /// @notice The deadline has passed
    error ExpiredPastDeadline();

    /// @notice The slippage is too high
    error TooMuchSlippage();

    bytes internal constant ZERO_BYTES = bytes("");

    /// @dev Min tick for full range with tick spacing of 60
    int24 internal constant MIN_TICK = -887220;
    /// @dev Max tick for full range with tick spacing of 60
    int24 internal constant MAX_TICK = -MIN_TICK;

    /// @dev The minimum amount of liquidity that must be locked in the pool
    uint16 internal constant MINIMUM_LIQUIDITY = 1000;

    struct CallbackData {
        address sender;
        PoolKey key;
        ICLPoolManager.ModifyLiquidityParams params;
    }

    /// @member hasAccruedFees Whether the pool has accrued fees
    /// @member liquidityToken The address of the liquidity token
    struct PoolInfo {
        bool hasAccruedFees;
        address liquidityToken;
    }

    /// @member currency0 currency0 of PoolKey
    /// @member currency1 currency1 of PoolKey
    /// @member fee fee of PoolKey
    /// @member parameters parameters of PoolKey
    /// @member amount0Desired The desired amount of token0 to add
    /// @member amount1Desired The desired amount of token1 to add
    /// @member amount0Min The minimum amount of token0 must be added
    /// @member amount1Min The minimum amount of token1 must be added
    /// @member to The address of recipient
    /// @member deadline The deadline to add liquidity
    struct AddLiquidityParams {
        Currency currency0;
        Currency currency1;
        uint24 fee;
        bytes32 parameters;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address to;
        uint256 deadline;
    }

    /// @member currency0 currency0 of PoolKey
    /// @member currency1 currency1 of PoolKey
    /// @member fee fee of PoolKey
    /// @member parameters parameters of PoolKey
    /// @member liquidity The amount of liquidity tokens to remove
    /// @member deadline The deadline to remove liquidity
    struct RemoveLiquidityParams {
        Currency currency0;
        Currency currency1;
        uint24 fee;
        bytes32 parameters;
        uint256 liquidity;
        uint256 deadline;
    }

    mapping(PoolId => PoolInfo) public poolInfo;

    constructor(ICLPoolManager poolManager) CLBaseHook(poolManager) {}

    modifier ensure(uint256 deadline) {
        if (deadline < block.timestamp) revert ExpiredPastDeadline();
        _;
    }

    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return _hooksRegistrationBitmapFrom(
            Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnsDelta: false,
                afterSwapReturnsDelta: false,
                afterAddLiquidiyReturnsDelta: false,
                afterRemoveLiquidiyReturnsDelta: false
            })
        );
    }

    /// @notice Add full range liquidity to the pool
    /// @param params AddLiquidityParams
    /// @return liquidity The amount of liquidity tokens minted
    function addLiquidity(AddLiquidityParams calldata params)
        external
        ensure(params.deadline)
        returns (uint128 liquidity)
    {
        PoolKey memory key = PoolKey({
            currency0: params.currency0,
            currency1: params.currency1,
            hooks: this,
            poolManager: poolManager,
            fee: params.fee,
            parameters: params.parameters
        });
        PoolId poolId = key.toId();

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        PoolInfo storage pool = poolInfo[poolId];

        uint128 poolLiquidity = poolManager.getLiquidity(poolId);

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(MIN_TICK),
            TickMath.getSqrtRatioAtTick(MAX_TICK),
            params.amount0Desired,
            params.amount1Desired
        );

        if (poolLiquidity == 0 && liquidity <= MINIMUM_LIQUIDITY) {
            revert LiquidityDoesntMeetMinimum();
        }
        BalanceDelta addedDelta = _modifyPosition(
            key,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: liquidity.toInt256(),
                salt: bytes32(0)
            })
        );

        if (poolLiquidity == 0) {
            // permanently lock the first MINIMUM_LIQUIDITY tokens
            liquidity -= MINIMUM_LIQUIDITY;
            PancakeV4ERC20(pool.liquidityToken).mint(address(0), MINIMUM_LIQUIDITY);
        }

        PancakeV4ERC20(pool.liquidityToken).mint(params.to, liquidity);

        if (uint128(addedDelta.amount0()) < params.amount0Min || uint128(addedDelta.amount1()) < params.amount1Min) {
            revert TooMuchSlippage();
        }
    }

    /// @notice Remove full range liquidity from the pool
    /// @param params RemoveLiquidityParams
    /// @return delta BalanceDelta
    function removeLiquidity(RemoveLiquidityParams calldata params)
        public
        virtual
        ensure(params.deadline)
        returns (BalanceDelta delta)
    {
        PoolKey memory key = PoolKey({
            currency0: params.currency0,
            currency1: params.currency1,
            hooks: this,
            poolManager: poolManager,
            fee: params.fee,
            parameters: params.parameters
        });
        PoolId poolId = key.toId();

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        PancakeV4ERC20 liquidityToken = PancakeV4ERC20(poolInfo[poolId].liquidityToken);

        delta = _modifyPosition(
            key,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: -(params.liquidity.toInt256()),
                salt: bytes32(0)
            })
        );

        liquidityToken.burn(msg.sender, params.liquidity);
    }

    /// @dev Deploy a new liquidity token for the pool and initialize the
    /// PoolInfo
    function beforeInitialize(address, PoolKey calldata key, uint160, bytes calldata)
        external
        override
        poolManagerOnly
        returns (bytes4)
    {
        if (key.parameters.getTickSpacing() != 60) revert TickSpacingNotDefault();

        PoolId poolId = key.toId();

        string memory tokenSymbol = string(
            abi.encodePacked(
                "PancakeV4",
                "-",
                IERC20Metadata(Currency.unwrap(key.currency0)).symbol(),
                "-",
                IERC20Metadata(Currency.unwrap(key.currency1)).symbol(),
                "-",
                Strings.toString(uint256(key.fee))
            )
        );
        address poolToken = address(new PancakeV4ERC20(tokenSymbol, tokenSymbol));

        poolInfo[poolId] = PoolInfo({hasAccruedFees: false, liquidityToken: poolToken});

        return this.beforeInitialize.selector;
    }

    /// @dev Users can only add liquidity through this hook
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override poolManagerOnly returns (bytes4) {
        if (sender != address(this)) revert SenderMustBeHook();

        return this.beforeAddLiquidity.selector;
    }

    /// @dev Users can only add liquidity through this hook
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override poolManagerOnly returns (bytes4) {
        if (sender != address(this)) revert SenderMustBeHook();

        return this.beforeRemoveLiquidity.selector;
    }

    /// @dev Assume that the pool must have fee
    function beforeSwap(address, PoolKey calldata key, ICLPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        poolManagerOnly
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();

        if (!poolInfo[poolId].hasAccruedFees) {
            PoolInfo storage pool = poolInfo[poolId];
            pool.hasAccruedFees = true;
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _modifyPosition(PoolKey memory key, ICLPoolManager.ModifyLiquidityParams memory params)
        internal
        returns (BalanceDelta delta)
    {
        delta = abi.decode(vault.lock(abi.encode(CallbackData(msg.sender, key, params))), (BalanceDelta));
    }

    function _settleDeltas(address sender, PoolKey memory key, BalanceDelta delta) internal {
        _settleDelta(sender, key.currency0, uint128(delta.amount0()));
        _settleDelta(sender, key.currency1, uint128(delta.amount1()));
    }

    function _settleDelta(address sender, Currency currency, uint128 amount) internal {
        if (currency.isNative()) {
            vault.settle{value: amount}(currency);
        } else {
            if (sender == address(this)) {
                currency.transfer(address(vault), amount);
            } else {
                IERC20(Currency.unwrap(currency)).transferFrom(sender, address(vault), amount);
            }
            vault.settle(currency);
        }
    }

    function _takeDeltas(address sender, PoolKey memory key, BalanceDelta delta) internal {
        vault.take(key.currency0, sender, uint256(uint128(-delta.amount0())));
        vault.take(key.currency1, sender, uint256(uint128(-delta.amount1())));
    }

    /// @dev Rebalance first to ensure fair liquidity token amount distribution
    function _addLiquidity(PoolKey memory key, ICLPoolManager.ModifyLiquidityParams memory params)
        internal
        returns (BalanceDelta delta)
    {
        PoolId poolId = key.toId();
        PoolInfo storage pool = poolInfo[poolId];

        if (pool.hasAccruedFees) {
            _rebalance(key);
        }

        (delta,) = poolManager.modifyLiquidity(key, params, ZERO_BYTES);
        pool.hasAccruedFees = false;
    }

    /// @dev Rebalance first to ensure fair liquidity token amount distribution.
    /// Also when removing liquidity, the input liquidityDelta is acutally the
    /// liquidity token delta
    function _removeLiquidity(PoolKey memory key, ICLPoolManager.ModifyLiquidityParams memory params)
        internal
        returns (BalanceDelta delta)
    {
        PoolId poolId = key.toId();
        PoolInfo storage pool = poolInfo[poolId];

        if (pool.hasAccruedFees) {
            _rebalance(key);
        }

        uint256 liquidityToRemove = FullMath.mulDiv(
            uint256(-params.liquidityDelta),
            poolManager.getLiquidity(poolId),
            PancakeV4ERC20(pool.liquidityToken).totalSupply()
        );

        params.liquidityDelta = -(liquidityToRemove.toInt256());
        (delta,) = poolManager.modifyLiquidity(key, params, ZERO_BYTES);
        pool.hasAccruedFees = false;
    }

    function lockAcquired(bytes calldata rawData) external override vaultOnly returns (bytes memory) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta delta;

        if (data.params.liquidityDelta < 0) {
            delta = _removeLiquidity(data.key, data.params);
            _takeDeltas(data.sender, data.key, delta);
        } else {
            delta = _addLiquidity(data.key, data.params);
            _settleDeltas(data.sender, data.key, delta);
        }
        return abi.encode(delta);
    }

    /// @dev Rebalance the pool to fit the current price
    function _rebalance(PoolKey memory key) public {
        PoolId poolId = key.toId();
        (BalanceDelta balanceDelta,) = poolManager.modifyLiquidity(
            key,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: -(poolManager.getLiquidity(poolId).toInt256()),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        uint160 newSqrtPriceX96 = (
            FixedPointMathLib.sqrt(
                FullMath.mulDiv(uint128(-balanceDelta.amount1()), FixedPoint96.Q96, uint128(-balanceDelta.amount0()))
            ) * FixedPointMathLib.sqrt(FixedPoint96.Q96)
        ).toUint160();

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        poolManager.swap(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: newSqrtPriceX96 < sqrtPriceX96,
                amountSpecified: type(int256).max,
                sqrtPriceLimitX96: newSqrtPriceX96
            }),
            ZERO_BYTES
        );

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            newSqrtPriceX96,
            TickMath.getSqrtRatioAtTick(MIN_TICK),
            TickMath.getSqrtRatioAtTick(MAX_TICK),
            uint256(uint128(-balanceDelta.amount0())),
            uint256(uint128(-balanceDelta.amount1()))
        );

        (BalanceDelta balanceDeltaAfter,) = poolManager.modifyLiquidity(
            key,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: liquidity.toInt256(),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        // Donate any "dust" from the sqrtRatio change as fees
        uint128 donateAmount0 = uint128(-balanceDelta.amount0() - balanceDeltaAfter.amount0());
        uint128 donateAmount1 = uint128(-balanceDelta.amount1() - balanceDeltaAfter.amount1());

        poolManager.donate(key, donateAmount0, donateAmount1, ZERO_BYTES);
    }
}
