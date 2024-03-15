// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";

import {ICLPoolManager} from "@pancakeswap/v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "@pancakeswap/v4-core/src/interfaces/IVault.sol";
import {CLPoolManager} from "@pancakeswap/v4-core/src/pool-cl/CLPoolManager.sol";
import {Vault} from "@pancakeswap/v4-core/src/Vault.sol";
import {Currency} from "@pancakeswap/v4-core/src/types/Currency.sol";
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

import {CLLimitOrder, Epoch, EpochLibrary} from "../../src/pool-cl/limit-order/CLLimitOrder.sol";

contract CLLimitOrderHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using FeeLibrary for uint24;
    using CLPoolParametersHelper for bytes32;

    uint160 constant SQRT_RATIO_10_1 = 250541448375047931186413801569;

    IVault vault;
    ICLPoolManager poolManager;
    NonfungiblePositionManager nfp;
    CLSwapRouter swapRouter;

    CLLimitOrder limitOrder;

    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;
    PoolKey key;
    PoolId id;

    function setUp() public {
        (vault, poolManager) = createFreshManager();
        limitOrder = new CLLimitOrder(poolManager);

        nfp = new NonfungiblePositionManager(vault, poolManager, address(0), address(0));
        swapRouter = new CLSwapRouter(vault, poolManager, address(0));

        MockERC20[] memory tokens = deployTokens(2, type(uint256).max);
        token0 = tokens[0];
        token1 = tokens[1];
        (currency0, currency1) = SortTokens.sort(token0, token1);

        address[3] memory approvalAddress = [address(nfp), address(swapRouter), address(limitOrder)];
        for (uint256 i; i < approvalAddress.length; i++) {
            token0.approve(approvalAddress[i], type(uint256).max);
            token1.approve(approvalAddress[i], type(uint256).max);
        }

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: limitOrder,
            poolManager: poolManager,
            fee: 3000,
            parameters: bytes32(uint256(limitOrder.getHooksRegistrationBitmap())).setTickSpacing(60)
        });
        id = key.toId();

        poolManager.initialize(key, SQRT_RATIO_1_1, ZERO_BYTES);

        nfp.mint(
            INonfungiblePositionManager.MintParams({
                poolKey: key,
                tickLower: -120,
                tickUpper: 120,
                amount0Desired: 1e18,
                amount1Desired: 1e18,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
    }

    function testGetTickLowerLast() public {
        assertEq(limitOrder.getTickLowerLast(id), 0);
    }

    function testGetTickLowerLastWithDifferentPrice() public {
        PoolKey memory differentKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: limitOrder,
            poolManager: poolManager,
            fee: 3000,
            parameters: bytes32(uint256(limitOrder.getHooksRegistrationBitmap())).setTickSpacing(61)
        });

        poolManager.initialize(differentKey, SQRT_RATIO_10_1, ZERO_BYTES);
        assertEq(limitOrder.getTickLowerLast(differentKey.toId()), 22997);
    }

    function testEpochNext() public {
        assertTrue(EpochLibrary.equals(limitOrder.epochNext(), Epoch.wrap(1)));
    }

    function testZeroLiquidityRevert() public {
        vm.expectRevert(CLLimitOrder.ZeroLiquidity.selector);
        limitOrder.place(key, 0, true, 0);
    }

    function testZeroForOneRightBoundaryOfCurrentRange() public {
        int24 tickLower = 60;
        bool zeroForOne = true;
        uint128 liquidity = 1000000;
        limitOrder.place(key, tickLower, zeroForOne, liquidity);
        assertTrue(EpochLibrary.equals(limitOrder.getEpoch(key, tickLower, zeroForOne), Epoch.wrap(1)));
        assertEq(poolManager.getLiquidity(id, address(limitOrder), tickLower, tickLower + 60), liquidity);
    }

    function testZeroForOneLeftBoundaryOfCurrentRange() public {
        int24 tickLower = 0;
        bool zeroForOne = true;
        uint128 liquidity = 1000000;
        limitOrder.place(key, tickLower, zeroForOne, liquidity);
        assertTrue(EpochLibrary.equals(limitOrder.getEpoch(key, tickLower, zeroForOne), Epoch.wrap(1)));
        assertEq(poolManager.getLiquidity(id, address(limitOrder), tickLower, tickLower + 60), liquidity);
    }

    function testZeroForOneCrossedRangeRevert() public {
        vm.expectRevert(CLLimitOrder.CrossedRange.selector);
        limitOrder.place(key, -60, true, 1000000);
    }

    function testZeroForOneInRangeRevert() public {
        // swapping is free, there's no liquidity in the pool, so we only need to specify 1 wei
        swapRouter.exactInputSingle(
            ICLSwapRouterBase.V4CLExactInputSingleParams({
                poolKey: key,
                zeroForOne: false,
                recipient: address(this),
                amountIn: 1e18,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: SQRT_RATIO_1_1 + 1,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        vm.expectRevert(CLLimitOrder.InRange.selector);
        limitOrder.place(key, 0, true, 1000000);
    }

    function testNotZeroForOneLeftBoundaryOfCurrentRange() public {
        int24 tickLower = -60;
        bool zeroForOne = false;
        uint128 liquidity = 1000000;
        limitOrder.place(key, tickLower, zeroForOne, liquidity);
        assertTrue(EpochLibrary.equals(limitOrder.getEpoch(key, tickLower, zeroForOne), Epoch.wrap(1)));
        assertEq(poolManager.getLiquidity(id, address(limitOrder), tickLower, tickLower + 60), liquidity);
    }

    function testNotZeroForOneCrossedRangeRevert() public {
        vm.expectRevert(CLLimitOrder.CrossedRange.selector);
        limitOrder.place(key, 0, false, 1000000);
    }

    function testNotZeroForOneInRangeRevert() public {
        // swapping is free, there's no liquidity in the pool, so we only need to specify 1 wei
        swapRouter.exactInputSingle(
            ICLSwapRouterBase.V4CLExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                recipient: address(this),
                amountIn: 1e18,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: SQRT_RATIO_1_1 - 1,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        vm.expectRevert(CLLimitOrder.InRange.selector);
        limitOrder.place(key, -60, false, 1000000);
    }

    function testMultipleLPs() public {
        int24 tickLower = 60;
        bool zeroForOne = true;
        uint128 liquidity = 1000000;
        limitOrder.place(key, tickLower, zeroForOne, liquidity);
        address other = 0x1111111111111111111111111111111111111111;
        token0.transfer(other, 1e18);
        token1.transfer(other, 1e18);
        vm.startPrank(other);
        token0.approve(address(limitOrder), type(uint256).max);
        token1.approve(address(limitOrder), type(uint256).max);
        limitOrder.place(key, tickLower, zeroForOne, liquidity);
        vm.stopPrank();
        assertTrue(EpochLibrary.equals(limitOrder.getEpoch(key, tickLower, zeroForOne), Epoch.wrap(1)));
        assertEq(poolManager.getLiquidity(id, address(limitOrder), tickLower, tickLower + 60), liquidity * 2);

        (bool filled,,, uint256 token0Total, uint256 token1Total, uint128 liquidityTotal) =
            limitOrder.epochInfos(Epoch.wrap(1));
        assertFalse(filled);
        assertEq(token0Total, 0);
        assertEq(token1Total, 0);
        assertEq(liquidityTotal, liquidity * 2);
        assertEq(limitOrder.getEpochLiquidity(Epoch.wrap(1), address(this)), liquidity);
        assertEq(limitOrder.getEpochLiquidity(Epoch.wrap(1), other), liquidity);
    }

    event Transfer(address indexed from, address indexed to, uint256 value);

    function testKill() public {
        int24 tickLower = 0;
        bool zeroForOne = true;
        uint128 liquidity = 1000000;
        limitOrder.place(key, tickLower, zeroForOne, liquidity);
        vm.expectEmit(true, true, true, true, address(token0));
        emit Transfer(address(vault), address(this), 2995);
        limitOrder.kill(key, tickLower, zeroForOne, address(this));
    }

    function testSwapAcrossRange() public {
        int24 tickLower = 0;
        bool zeroForOne = true;
        uint128 liquidity = 1000000;
        limitOrder.place(key, tickLower, zeroForOne, liquidity);

        swapRouter.exactInputSingle(
            ICLSwapRouterBase.V4CLExactInputSingleParams({
                poolKey: key,
                zeroForOne: false,
                recipient: address(this),
                amountIn: 1e18,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(60),
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        assertEq(limitOrder.getTickLowerLast(id), 60);
        (, int24 tick,,) = poolManager.getSlot0(id);
        assertEq(tick, 60);

        (bool filled,,, uint256 token0Total, uint256 token1Total,) = limitOrder.epochInfos(Epoch.wrap(1));

        assertTrue(filled);
        assertEq(token0Total, 0);
        assertEq(token1Total, 2996 + 17); // 3013, 2 wei of dust
        assertEq(poolManager.getLiquidity(id, address(limitOrder), tickLower, tickLower + 60), 0);

        vm.expectEmit(true, true, true, true, address(token1));
        emit Transfer(address(vault), address(this), 2996 + 17);
        limitOrder.withdraw(Epoch.wrap(1), address(this));

        (,,, token0Total, token1Total,) = limitOrder.epochInfos(Epoch.wrap(1));

        assertEq(token0Total, 0);
        assertEq(token1Total, 0);
    }
}
