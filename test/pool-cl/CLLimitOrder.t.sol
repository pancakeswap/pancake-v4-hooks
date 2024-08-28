// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {CLPoolManager} from "pancake-v4-core/src/pool-cl/CLPoolManager.sol";
import {Vault} from "pancake-v4-core/src/Vault.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {CLPoolParametersHelper} from "pancake-v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "pancake-v4-core/src/pool-cl/libraries/TickMath.sol";
import {SortTokens} from "pancake-v4-core/test/helpers/SortTokens.sol";
import {Deployers} from "pancake-v4-core/test/pool-cl/helpers/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Hooks} from "pancake-v4-core/src/libraries/Hooks.sol";
import {ICLRouterBase} from "pancake-v4-periphery/src/pool-cl/interfaces/ICLRouterBase.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {MockCLSwapRouter} from "./helpers/MockCLSwapRouter.sol";
import {MockCLPositionManager} from "./helpers/MockCLPositionManager.sol";
import {PositionConfig} from "pancake-v4-periphery/src/pool-cl/libraries/PositionConfig.sol";

import {CLLimitOrder, Epoch, EpochLibrary} from "../../src/pool-cl/limit-order/CLLimitOrder.sol";

contract CLLimitOrderHookTest is Test, Deployers, DeployPermit2 {
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;

    uint160 constant SQRT_RATIO_10_1 = 250541448375047931186413801569;

    IVault vault;
    ICLPoolManager poolManager;
    IAllowanceTransfer permit2;
    MockCLPositionManager cpm;
    MockCLSwapRouter swapRouter;

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

        permit2 = IAllowanceTransfer(deployPermit2());
        cpm = new MockCLPositionManager(vault, poolManager, permit2);
        swapRouter = new MockCLSwapRouter(vault, poolManager);

        MockERC20[] memory tokens = deployTokens(2, type(uint256).max);
        token0 = tokens[0];
        token1 = tokens[1];
        (currency0, currency1) = SortTokens.sort(token0, token1);

        address[4] memory approvalAddress = [address(cpm), address(swapRouter), address(limitOrder), address(permit2)];
        for (uint256 i; i < approvalAddress.length; i++) {
            token0.approve(approvalAddress[i], type(uint256).max);
            token1.approve(approvalAddress[i], type(uint256).max);
        }
        permit2.approve(address(token0), address(cpm), type(uint160).max, type(uint48).max);
        permit2.approve(address(token1), address(cpm), type(uint160).max, type(uint48).max);

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

        PositionConfig memory config = PositionConfig({poolKey: key, tickLower: -120, tickUpper: 120});

        cpm.mint(
            config,
            // liquidity:
            10e18,
            // amount0Max:
            100e18,
            // amount1Max:
            100e18,
            // owner:
            address(this),
            // hookData:
            ZERO_BYTES
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
        assertEq(poolManager.getLiquidity(id, address(limitOrder), tickLower, tickLower + 60, bytes32(0)), liquidity);
    }

    function testZeroForOneLeftBoundaryOfCurrentRange() public {
        int24 tickLower = 0;
        bool zeroForOne = true;
        uint128 liquidity = 1000000;
        limitOrder.place(key, tickLower, zeroForOne, liquidity);
        assertTrue(EpochLibrary.equals(limitOrder.getEpoch(key, tickLower, zeroForOne), Epoch.wrap(1)));
        assertEq(poolManager.getLiquidity(id, address(limitOrder), tickLower, tickLower + 60, bytes32(0)), liquidity);
    }

    function testZeroForOneCrossedRangeRevert() public {
        vm.expectRevert(CLLimitOrder.CrossedRange.selector);
        limitOrder.place(key, -60, true, 1000000);
    }

    function testZeroForOneInRangeRevert() public {
        // swapping is free, there's no liquidity in the pool, so we only need to specify 1 wei
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: false,
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
        assertEq(poolManager.getLiquidity(id, address(limitOrder), tickLower, tickLower + 60, bytes32(0)), liquidity);
    }

    function testNotZeroForOneCrossedRangeRevert() public {
        vm.expectRevert(CLLimitOrder.CrossedRange.selector);
        limitOrder.place(key, 0, false, 1000000);
    }

    function testNotZeroForOneInRangeRevert() public {
        // swapping is free, there's no liquidity in the pool, so we only need to specify 1 wei
        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
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
        assertEq(
            poolManager.getLiquidity(id, address(limitOrder), tickLower, tickLower + 60, bytes32(0)), liquidity * 2
        );

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

        vm.recordLogs();
        limitOrder.kill(key, tickLower, zeroForOne, address(this));

        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries[1].topics[0], Transfer.selector);
        assertEq(entries[1].topics[1], bytes32(uint256(uint160(address(vault)))));
        assertEq(entries[1].topics[2], bytes32(uint256(uint160(address(this)))));
        assertEq(abi.decode(entries[1].data, (uint256)), 2995);
    }

    function testSwapAcrossRange() public {
        int24 tickLower = 0;
        bool zeroForOne = true;
        uint128 liquidity = 1000000;
        limitOrder.place(key, tickLower, zeroForOne, liquidity);

        swapRouter.exactInputSingle(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: false,
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
        assertEq(token1Total, 2996 + 17);
        assertEq(poolManager.getLiquidity(id, address(limitOrder), tickLower, tickLower + 60, bytes32(0)), 0);

        vm.recordLogs();
        limitOrder.withdraw(Epoch.wrap(1), address(this));

        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries[1].topics[0], Transfer.selector);
        assertEq(entries[1].topics[1], bytes32(uint256(uint160(address(vault)))));
        assertEq(entries[1].topics[2], bytes32(uint256(uint160(address(this)))));
        assertEq(abi.decode(entries[1].data, (uint256)), 2996 + 17);

        (,,, token0Total, token1Total,) = limitOrder.epochInfos(Epoch.wrap(1));

        assertEq(token0Total, 0);
        assertEq(token1Total, 0);
    }
}
