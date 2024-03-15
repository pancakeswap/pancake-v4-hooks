// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";

import {ICLPoolManager} from "@pancakeswap/v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "@pancakeswap/v4-core/src/interfaces/IVault.sol";
import {CLPoolManager} from "@pancakeswap/v4-core/src/pool-cl/CLPoolManager.sol";
import {Vault} from "@pancakeswap/v4-core/src/Vault.sol";
import {Currency, CurrencyLibrary} from "@pancakeswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@pancakeswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@pancakeswap/v4-core/src/types/PoolId.sol";
import {FeeLibrary} from "@pancakeswap/v4-core/src/libraries/FeeLibrary.sol";
import {CLPoolParametersHelper} from "@pancakeswap/v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "@pancakeswap/v4-core/src/pool-cl/libraries/TickMath.sol";
import {SortTokens} from "@pancakeswap/v4-core/test/helpers/SortTokens.sol";
import {Deployers} from "@pancakeswap/v4-core/test/pool-cl/helpers/Deployers.sol";
import {ICLSwapRouterBase} from "@pancakeswap/v4-periphery/src/pool-cl/interfaces/ICLSwapRouterBase.sol";
import {CLSwapRouter} from "@pancakeswap/v4-periphery/src/pool-cl/CLSwapRouter.sol";
import {NonfungiblePositionManager} from "@pancakeswap/v4-periphery/src/pool-cl/NonfungiblePositionManager.sol";
import {INonfungiblePositionManager} from
    "@pancakeswap/v4-periphery/src/pool-cl/interfaces/INonfungiblePositionManager.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {CLFullRange} from "../../src/pool-cl/full-range/CLFullRange.sol";
import {PancakeV4ERC20} from "../../src/pool-cl/full-range/libraries/PancakeV4ERC20.sol";

contract CLFullRangeHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using FeeLibrary for uint24;
    using CLPoolParametersHelper for bytes32;
    using CurrencyLibrary for Currency;

    /// @dev Min tick for full range with tick spacing of 60
    int24 internal constant MIN_TICK = -887220;
    /// @dev Max tick for full range with tick spacing of 60
    int24 internal constant MAX_TICK = -MIN_TICK;

    uint16 constant LOCKED_LIQUIDITY = 1000;
    uint256 constant MAX_DEADLINE = 12329839823;
    uint256 constant MAX_TICK_LIQUIDITY = 11505069308564788430434325881101412;
    uint8 constant DUST = 30;

    IVault vault;
    ICLPoolManager poolManager;
    NonfungiblePositionManager nfp;
    CLSwapRouter swapRouter;

    CLFullRange fullRange;

    MockERC20 token0;
    MockERC20 token1;
    MockERC20 token2;

    PoolKey key;
    PoolId id;

    PoolKey key2;
    PoolId id2;

    PoolKey keyWithLiq;
    PoolId idWithLiq;

    function setUp() public {
        (vault, poolManager) = createFreshManager();
        fullRange = new CLFullRange(poolManager);

        nfp = new NonfungiblePositionManager(vault, poolManager, address(0), address(0));
        swapRouter = new CLSwapRouter(vault, poolManager, address(0));

        MockERC20[] memory tokens = deployTokens(3, 2 ** 128);
        token0 = tokens[0];
        token1 = tokens[1];
        token2 = tokens[2];

        {
            (Currency currency0, Currency currency1) = SortTokens.sort(token0, token1);
            key = PoolKey({
                currency0: currency0,
                currency1: currency1,
                hooks: fullRange,
                poolManager: poolManager,
                fee: 3000,
                parameters: bytes32(uint256(fullRange.getHooksRegistrationBitmap())).setTickSpacing(60)
            });
            id = key.toId();
        }

        {
            (Currency currency0, Currency currency1) = SortTokens.sort(token1, token2);
            key2 = PoolKey({
                currency0: currency0,
                currency1: currency1,
                hooks: fullRange,
                poolManager: poolManager,
                fee: 3000,
                parameters: bytes32(uint256(fullRange.getHooksRegistrationBitmap())).setTickSpacing(60)
            });
            id2 = key2.toId();
        }

        {
            (Currency currency0, Currency currency1) = SortTokens.sort(token0, token2);
            keyWithLiq = PoolKey({
                currency0: currency0,
                currency1: currency1,
                hooks: fullRange,
                poolManager: poolManager,
                fee: 3000,
                parameters: bytes32(uint256(fullRange.getHooksRegistrationBitmap())).setTickSpacing(60)
            });
            idWithLiq = keyWithLiq.toId();
        }

        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        token2.approve(address(fullRange), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token2.approve(address(swapRouter), type(uint256).max);

        poolManager.initialize(keyWithLiq, SQRT_RATIO_1_1, ZERO_BYTES);

        fullRange.addLiquidity(
            CLFullRange.AddLiquidityParams({
                currency0: keyWithLiq.currency0,
                currency1: keyWithLiq.currency1,
                fee: keyWithLiq.fee,
                parameters: keyWithLiq.parameters,
                amount0Desired: 100 ether,
                amount1Desired: 100 ether,
                amount0Min: 0,
                amount1Min: 0,
                to: address(this),
                deadline: MAX_DEADLINE
            })
        );
    }

    function test_RevertIfWrongTickSpacing() public {
        PoolKey memory wrongKey = PoolKey({
            currency0: key.currency0,
            currency1: key.currency1,
            hooks: fullRange,
            poolManager: poolManager,
            fee: 3000,
            parameters: bytes32(uint256(fullRange.getHooksRegistrationBitmap())).setTickSpacing(61)
        });

        vm.expectRevert(CLFullRange.TickSpacingNotDefault.selector);
        poolManager.initialize(wrongKey, SQRT_RATIO_1_1, ZERO_BYTES);
    }

    function test_RevertIfNoPool() public {
        vm.expectRevert(CLFullRange.PoolNotInitialized.selector);
        fullRange.addLiquidity(
            CLFullRange.AddLiquidityParams({
                currency0: key.currency0,
                currency1: key.currency1,
                fee: key.fee,
                parameters: key.parameters,
                amount0Desired: 10 ether,
                amount1Desired: 10 ether,
                amount0Min: 0,
                amount1Min: 0,
                to: address(this),
                deadline: MAX_DEADLINE
            })
        );

        vm.expectRevert(CLFullRange.PoolNotInitialized.selector);
        fullRange.removeLiquidity(
            CLFullRange.RemoveLiquidityParams({
                currency0: key.currency0,
                currency1: key.currency1,
                fee: key.fee,
                parameters: key.parameters,
                liquidity: 1e18,
                deadline: MAX_DEADLINE
            })
        );
    }

    function test_RevertIfTooMuchSlippage() public {
        poolManager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        fullRange.addLiquidity(
            CLFullRange.AddLiquidityParams({
                currency0: key.currency0,
                currency1: key.currency1,
                fee: key.fee,
                parameters: key.parameters,
                amount0Desired: 10 ether,
                amount1Desired: 10 ether,
                amount0Min: 0,
                amount1Min: 0,
                to: address(this),
                deadline: MAX_DEADLINE
            })
        );

        swapRouter.exactInputSingle(
            ICLSwapRouterBase.V4CLExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                recipient: address(this),
                amountIn: 1e18,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        vm.expectRevert(CLFullRange.TooMuchSlippage.selector);
        fullRange.addLiquidity(
            CLFullRange.AddLiquidityParams({
                currency0: key.currency0,
                currency1: key.currency1,
                fee: key.fee,
                parameters: key.parameters,
                amount0Desired: 10 ether,
                amount1Desired: 10 ether,
                amount0Min: 10 ether,
                amount1Min: 10 ether,
                to: address(this),
                deadline: MAX_DEADLINE
            })
        );
    }

    function test_AddLiquidity() public {
        poolManager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        uint256 prevBalance0 = key.currency0.balanceOf(address(this));
        uint256 prevBalance1 = key.currency1.balanceOf(address(this));

        fullRange.addLiquidity(
            CLFullRange.AddLiquidityParams({
                currency0: key.currency0,
                currency1: key.currency1,
                fee: key.fee,
                parameters: key.parameters,
                amount0Desired: 10 ether,
                amount1Desired: 10 ether,
                amount0Min: 0,
                amount1Min: 0,
                to: address(this),
                deadline: MAX_DEADLINE
            })
        );

        (bool hasAccruedFees, address liquidityToken) = fullRange.poolInfo(id);
        uint256 liquidityTokenBalance = PancakeV4ERC20(liquidityToken).balanceOf(address(this));

        assertEq(poolManager.getLiquidity(id), liquidityTokenBalance + LOCKED_LIQUIDITY);

        assertEq(key.currency0.balanceOf(address(this)), prevBalance0 - 10 ether);
        assertEq(key.currency1.balanceOf(address(this)), prevBalance1 - 10 ether);

        assertEq(liquidityTokenBalance, 10 ether - LOCKED_LIQUIDITY);
        assertEq(hasAccruedFees, false);

        swapRouter.exactInputSingle(
            ICLSwapRouterBase.V4CLExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                recipient: address(this),
                amountIn: 1e18,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        (hasAccruedFees,) = fullRange.poolInfo(id);
        assertEq(hasAccruedFees, true);

        fullRange.addLiquidity(
            CLFullRange.AddLiquidityParams({
                currency0: key.currency0,
                currency1: key.currency1,
                fee: key.fee,
                parameters: key.parameters,
                amount0Desired: 10 ether,
                amount1Desired: 10 ether,
                amount0Min: 0,
                amount1Min: 0,
                to: address(this),
                deadline: MAX_DEADLINE
            })
        );

        swapRouter.exactInputSingle(
            ICLSwapRouterBase.V4CLExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                recipient: address(this),
                amountIn: 1e18,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        (hasAccruedFees,) = fullRange.poolInfo(id);
        assertEq(hasAccruedFees, true);

        fullRange.addLiquidity(
            CLFullRange.AddLiquidityParams({
                currency0: keyWithLiq.currency0,
                currency1: keyWithLiq.currency1,
                fee: keyWithLiq.fee,
                parameters: keyWithLiq.parameters,
                amount0Desired: 10 ether,
                amount1Desired: 10 ether,
                amount0Min: 0,
                amount1Min: 0,
                to: address(this),
                deadline: MAX_DEADLINE
            })
        );
    }

    function testFuzz_AddLiquidity(uint256 amount) public {
        poolManager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        if (amount < LOCKED_LIQUIDITY) {
            vm.expectRevert(CLFullRange.LiquidityDoesntMeetMinimum.selector);
            fullRange.addLiquidity(
                CLFullRange.AddLiquidityParams({
                    currency0: key.currency0,
                    currency1: key.currency1,
                    fee: key.fee,
                    parameters: key.parameters,
                    amount0Desired: amount,
                    amount1Desired: amount,
                    amount0Min: 0,
                    amount1Min: 0,
                    to: address(this),
                    deadline: MAX_DEADLINE
                })
            );
        } else if (amount > MAX_TICK_LIQUIDITY) {
            vm.expectRevert();
            fullRange.addLiquidity(
                CLFullRange.AddLiquidityParams({
                    currency0: key.currency0,
                    currency1: key.currency1,
                    fee: key.fee,
                    parameters: key.parameters,
                    amount0Desired: amount,
                    amount1Desired: amount,
                    amount0Min: 0,
                    amount1Min: 0,
                    to: address(this),
                    deadline: MAX_DEADLINE
                })
            );
        } else {
            fullRange.addLiquidity(
                CLFullRange.AddLiquidityParams({
                    currency0: key.currency0,
                    currency1: key.currency1,
                    fee: key.fee,
                    parameters: key.parameters,
                    amount0Desired: amount,
                    amount1Desired: amount,
                    amount0Min: 0,
                    amount1Min: 0,
                    to: address(this),
                    deadline: MAX_DEADLINE
                })
            );

            (bool hasAccruedFees, address liquidityToken) = fullRange.poolInfo(id);
            uint256 liquidityTokenBalance = PancakeV4ERC20(liquidityToken).balanceOf(address(this));

            assertEq(poolManager.getLiquidity(id), liquidityTokenBalance + LOCKED_LIQUIDITY);
            assertEq(hasAccruedFees, false);
        }
    }

    function test_RevertIfNoLiquidity() public {
        poolManager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        (, address liquidityToken) = fullRange.poolInfo(id);

        PancakeV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

        vm.expectRevert();
        fullRange.removeLiquidity(
            CLFullRange.RemoveLiquidityParams({
                currency0: key.currency0,
                currency1: key.currency1,
                fee: key.fee,
                parameters: key.parameters,
                liquidity: 1e18,
                deadline: MAX_DEADLINE
            })
        );
    }

    function test_RemoveLiquidity() public {
        uint256 prevBalance0 = keyWithLiq.currency0.balanceOf(address(this));
        uint256 prevBalance1 = keyWithLiq.currency1.balanceOf(address(this));

        (, address liquidityToken) = fullRange.poolInfo(idWithLiq);

        PancakeV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

        fullRange.removeLiquidity(
            CLFullRange.RemoveLiquidityParams({
                currency0: keyWithLiq.currency0,
                currency1: keyWithLiq.currency1,
                fee: keyWithLiq.fee,
                parameters: keyWithLiq.parameters,
                liquidity: 1e18,
                deadline: MAX_DEADLINE
            })
        );

        (bool hasAccruedFees,) = fullRange.poolInfo(idWithLiq);
        uint256 liquidityTokenBalance = PancakeV4ERC20(liquidityToken).balanceOf(address(this));

        assertEq(poolManager.getLiquidity(idWithLiq), liquidityTokenBalance + LOCKED_LIQUIDITY);
        assertEq(PancakeV4ERC20(liquidityToken).balanceOf(address(this)), 99 ether - LOCKED_LIQUIDITY + 5);
        assertEq(keyWithLiq.currency0.balanceOf(address(this)), prevBalance0 + 1 ether - 1);
        assertEq(keyWithLiq.currency1.balanceOf(address(this)), prevBalance1 + 1 ether - 1);
        assertEq(hasAccruedFees, false);
    }

    function testFuzz_RemoveLiquidity(uint256 amount) public {
        poolManager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        fullRange.addLiquidity(
            CLFullRange.AddLiquidityParams({
                currency0: key.currency0,
                currency1: key.currency1,
                fee: key.fee,
                parameters: key.parameters,
                amount0Desired: 1000 ether,
                amount1Desired: 1000 ether,
                amount0Min: 0,
                amount1Min: 0,
                to: address(this),
                deadline: MAX_DEADLINE
            })
        );

        (, address liquidityToken) = fullRange.poolInfo(id);

        PancakeV4ERC20(liquidityToken).approve(address(fullRange), type(uint256).max);

        if (amount > PancakeV4ERC20(liquidityToken).balanceOf(address(this))) {
            vm.expectRevert();
            fullRange.removeLiquidity(
                CLFullRange.RemoveLiquidityParams({
                    currency0: key.currency0,
                    currency1: key.currency1,
                    fee: key.fee,
                    parameters: key.parameters,
                    liquidity: amount,
                    deadline: MAX_DEADLINE
                })
            );
        } else {
            uint256 prevLiquidityTokenBalance = PancakeV4ERC20(liquidityToken).balanceOf(address(this));

            fullRange.removeLiquidity(
                CLFullRange.RemoveLiquidityParams({
                    currency0: key.currency0,
                    currency1: key.currency1,
                    fee: key.fee,
                    parameters: key.parameters,
                    liquidity: amount,
                    deadline: MAX_DEADLINE
                })
            );

            uint256 liquidityTokenBalance = PancakeV4ERC20(liquidityToken).balanceOf(address(this));
            (bool hasAccruedFees,) = fullRange.poolInfo(id);

            assertEq(prevLiquidityTokenBalance - liquidityTokenBalance, amount);
            assertEq(poolManager.getLiquidity(id), liquidityTokenBalance + LOCKED_LIQUIDITY);
            assertEq(hasAccruedFees, false);
        }
    }
}
