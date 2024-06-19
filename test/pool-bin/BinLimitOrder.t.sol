// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";

import {IBinPoolManager} from "@pancakeswap/v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {IVault} from "@pancakeswap/v4-core/src/interfaces/IVault.sol";
import {BinPoolManager} from "@pancakeswap/v4-core/src/pool-bin/BinPoolManager.sol";
import {Vault} from "@pancakeswap/v4-core/src/Vault.sol";
import {Currency} from "@pancakeswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@pancakeswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@pancakeswap/v4-core/src/types/PoolId.sol";
import {BinPoolParametersHelper} from "@pancakeswap/v4-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {BinPosition} from "@pancakeswap/v4-core/src/pool-bin/libraries/BinPosition.sol";
import {Constants} from "@pancakeswap/v4-core/src/pool-bin/libraries/Constants.sol";
import {SortTokens} from "@pancakeswap/v4-core/test/helpers/SortTokens.sol";
import {IBinSwapRouterBase} from "@pancakeswap/v4-periphery/src/pool-bin/interfaces/IBinSwapRouterBase.sol";
import {BinSwapRouter} from "@pancakeswap/v4-periphery/src/pool-bin/BinSwapRouter.sol";
import {BinFungiblePositionManager} from "@pancakeswap/v4-periphery/src/pool-bin/BinFungiblePositionManager.sol";
import {IBinFungiblePositionManager} from
    "@pancakeswap/v4-periphery/src/pool-bin/interfaces/IBinFungiblePositionManager.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {BinLimitOrder, Epoch, EpochLibrary} from "../../src/pool-bin/limit-order/BinLimitOrder.sol";
import {Deployers} from "./helpers/Deployers.sol";

contract BinLimitOrderHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using BinPoolParametersHelper for bytes32;

    uint24 constant BIN_ID_1_1 = 2 ** 23;

    IVault vault;
    IBinPoolManager poolManager;
    BinFungiblePositionManager bfp;
    BinSwapRouter swapRouter;

    BinLimitOrder limitOrder;

    MockERC20 token0;
    MockERC20 token1;
    PoolKey key;
    PoolId id;

    function setUp() public {
        token0 = deployToken("MockToken0", "MT0", type(uint256).max);
        token1 = deployToken("MockToken1", "MT1", type(uint256).max);
        (Currency currency0, Currency currency1) = SortTokens.sort(token0, token1);

        (vault, poolManager) = createFreshManager();
        limitOrder = new BinLimitOrder(poolManager);

        bfp = new BinFungiblePositionManager(vault, poolManager, address(0));
        swapRouter = new BinSwapRouter(vault, poolManager, address(0));

        address[3] memory approvalAddress = [address(bfp), address(swapRouter), address(limitOrder)];
        for (uint256 i; i < approvalAddress.length; i++) {
            token0.approve(approvalAddress[i], type(uint256).max);
            token1.approve(approvalAddress[i], type(uint256).max);
        }

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: limitOrder,
            poolManager: poolManager,
            fee: 0,
            parameters: bytes32(uint256(limitOrder.getHooksRegistrationBitmap())).setBinStep(60)
        });
        id = key.toId();

        poolManager.initialize(key, BIN_ID_1_1, ZERO_BYTES);

        uint256 numBins = 5;
        int256[] memory deltaIds = new int256[](numBins);
        deltaIds[0] = -2;
        deltaIds[1] = -1;
        deltaIds[2] = 0;
        deltaIds[3] = 1;
        deltaIds[4] = 2;
        uint256[] memory distributionX = new uint256[](numBins);
        distributionX[0] = 0;
        distributionX[1] = 0;
        distributionX[2] = Constants.PRECISION / 3;
        distributionX[3] = Constants.PRECISION / 3;
        distributionX[4] = Constants.PRECISION / 3;
        uint256[] memory distributionY = new uint256[](numBins);
        distributionY[0] = Constants.PRECISION / 3;
        distributionY[1] = Constants.PRECISION / 3;
        distributionY[2] = Constants.PRECISION / 3;
        distributionY[3] = 0;
        distributionY[4] = 0;
        bfp.addLiquidity(
            IBinFungiblePositionManager.AddLiquidityParams({
                poolKey: key,
                amount0: 3 * 1e18,
                amount1: 3 * 1e18,
                amount0Min: 0,
                amount1Min: 0,
                activeIdDesired: BIN_ID_1_1,
                idSlippage: 0,
                deltaIds: deltaIds,
                distributionX: distributionX,
                distributionY: distributionY,
                to: address(this),
                deadline: block.timestamp
            })
        );
    }

    function testGetActiveIdLast() public {
        assertEq(limitOrder.getActiveIdLast(id), BIN_ID_1_1);
    }

    function testGetActiveIdLastWithDifferentPrice() public {
        PoolKey memory differentKey = PoolKey({
            currency0: key.currency0,
            currency1: key.currency1,
            hooks: limitOrder,
            poolManager: poolManager,
            fee: 0,
            parameters: bytes32(uint256(limitOrder.getHooksRegistrationBitmap())).setBinStep(61)
        });

        poolManager.initialize(differentKey, BIN_ID_1_1 + 1, ZERO_BYTES);
        assertEq(limitOrder.getActiveIdLast(differentKey.toId()), BIN_ID_1_1 + 1);
    }

    function testEpochNext() public {
        assertTrue(EpochLibrary.equals(limitOrder.epochNext(), Epoch.wrap(1)));
    }

    function test_RevertIfPlaceZeroAmount() public {
        vm.expectRevert(BinLimitOrder.ZeroAmount.selector);
        limitOrder.place(key, BIN_ID_1_1 + 1, true, 0);
    }

    function test_RevertIfPlaceInRange() public {
        vm.expectRevert(BinLimitOrder.InRange.selector);
        limitOrder.place(key, BIN_ID_1_1, true, 1e18);
        vm.expectRevert(BinLimitOrder.InRange.selector);
        limitOrder.place(key, BIN_ID_1_1, false, 1e18);
    }

    function test_RevertIfPlaceCrossedRange() public {
        vm.expectRevert(BinLimitOrder.CrossedRange.selector);
        limitOrder.place(key, BIN_ID_1_1 - 1, true, 1e18);
        vm.expectRevert(BinLimitOrder.CrossedRange.selector);
        limitOrder.place(key, BIN_ID_1_1 + 1, false, 1e18);
    }

    function test_Place() public {
        uint24 binId = BIN_ID_1_1 + 1;
        bool swapForY = true;
        uint128 amount = 1e18;
        limitOrder.place(key, binId, swapForY, amount);

        address other = 0x1111111111111111111111111111111111111111;
        token0.transfer(other, 1e18);
        token1.transfer(other, 1e18);
        vm.startPrank(other);
        token0.approve(address(limitOrder), type(uint256).max);
        token1.approve(address(limitOrder), type(uint256).max);
        limitOrder.place(key, binId, swapForY, amount);
        vm.stopPrank();

        assertTrue(EpochLibrary.equals(limitOrder.getEpoch(key, binId, swapForY), Epoch.wrap(1)));
        BinPosition.Info memory position = poolManager.getPosition(id, address(limitOrder), binId, bytes32(0));
        assertEq(position.share, 2 * 342324061122464094244154855076358820724000000000000000000);

        (bool filled,,, uint256 token0Total, uint256 token1Total, uint256 liquidityTotal) =
            limitOrder.epochInfos(Epoch.wrap(1));
        assertFalse(filled);
        assertEq(token0Total, 0);
        assertEq(token1Total, 0);
        assertEq(liquidityTotal, 2 * 342324061122464094244154855076358820724000000000000000000);
        assertEq(
            limitOrder.getEpochLiquidity(Epoch.wrap(1), address(this)),
            342324061122464094244154855076358820724000000000000000000
        );
        assertEq(
            limitOrder.getEpochLiquidity(Epoch.wrap(1), other),
            342324061122464094244154855076358820724000000000000000000
        );
    }

    event Transfer(address indexed from, address indexed to, uint256 value);

    function test_Kill() public {
        uint24 activeId = BIN_ID_1_1 + 1;
        bool swapForY = true;
        uint128 amount = 1e18;
        limitOrder.place(key, activeId, swapForY, amount);
        vm.expectEmit(true, true, true, true, Currency.unwrap(key.currency0));
        emit Transfer(address(vault), address(this), 1e18);
        limitOrder.kill(key, activeId, swapForY, address(this));
    }

    function test_Withdraw() public {
        limitOrder.place(key, BIN_ID_1_1 + 1, true, 1e18);

        swapRouter.exactInputSingle(
            IBinSwapRouterBase.V4BinExactInputSingleParams({
                poolKey: key,
                swapForY: false,
                recipient: address(this),
                amountIn: 4 * 1e18,
                amountOutMinimum: 0,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );

        assertEq(limitOrder.getActiveIdLast(id), BIN_ID_1_1 + 2);
        (uint24 activeId,,) = poolManager.getSlot0(id);
        assertEq(activeId, BIN_ID_1_1 + 2);

        (bool filled,,, uint256 token0Total, uint256 token1Total,) = limitOrder.epochInfos(Epoch.wrap(1));

        assertTrue(filled);
        assertEq(token0Total, 0);
        assertEq(token1Total, 1.006e18);
        BinPosition.Info memory position = poolManager.getPosition(id, address(limitOrder), BIN_ID_1_1 + 1, bytes32(0));
        assertEq(position.share, 0);

        vm.expectEmit(true, true, true, true, Currency.unwrap(key.currency1));
        emit Transfer(address(vault), address(this), 1.006e18);
        limitOrder.withdraw(Epoch.wrap(1), address(this));

        (,,, token0Total, token1Total,) = limitOrder.epochInfos(Epoch.wrap(1));

        assertEq(token0Total, 0);
        assertEq(token1Total, 0);
    }
}
