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
import {CLPosition} from "pancake-v4-core/src/pool-cl/libraries/CLPosition.sol";
import {CLPoolManagerRouter} from "pancake-v4-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {CLAntiSniping} from "../../src/pool-cl/anti-sniping/CLAntiSniping.sol";
import {Planner, Plan} from "pancake-v4-periphery/src/libraries/Planner.sol";
import {Actions} from "pancake-v4-periphery/src/libraries/Actions.sol";

import {console} from "forge-std/console.sol";
contract AntiSnipingTest is Test, Deployers, DeployPermit2 {
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;
    using Planner for Plan;

    uint24 constant FEE = 3000;
    uint128 constant POSITION_LOCK_DURATION = 1000;
    uint128 constant SAME_BLOCK_POSITIONS_LIMIT = 50;

    address constant ALICE = address(0x1111); // ALICE is an honest liquidity provider
    address constant BOB = address(0x2222); // BOB is wanna-be sniper
    address constant CANDY = address(0x3333); // CANDY is a normal user
    bytes32 constant ALICE_SALT = 0x0000000000000000000000000000000000000000000000000000000000000001;
    bytes32 constant BOB_SALT = 0x0000000000000000000000000000000000000000000000000000000000000002;

    IVault vault;
    ICLPoolManager poolManager;
    IAllowanceTransfer permit2;
    MockCLPositionManager cpm;
    MockCLSwapRouter swapRouter;

    CLAntiSniping antiSniping;
    CLPoolManagerRouter router;

    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;
    PoolKey key;
    PoolId id;
    uint256 aliceTokenId;
    uint256 bobTokenId;

    function setUp() public {
        (vault, poolManager) = createFreshManager();
        antiSniping = new CLAntiSniping(poolManager, POSITION_LOCK_DURATION, SAME_BLOCK_POSITIONS_LIMIT);

        permit2 = IAllowanceTransfer(deployPermit2());
        cpm = new MockCLPositionManager(vault, poolManager, permit2);
        swapRouter = new MockCLSwapRouter(vault, poolManager);
        router = new CLPoolManagerRouter(vault, poolManager);

        MockERC20[] memory tokens = deployTokens(2, type(uint256).max);
        token0 = tokens[0];
        token1 = tokens[1];
        (currency0, currency1) = SortTokens.sort(token0, token1);

        address[5] memory approvalAddress = [address(cpm), address(swapRouter), address(router), address(antiSniping), address(permit2)];

        vm.startPrank(ALICE);
        for (uint256 i; i < approvalAddress.length; i++) {
            token0.approve(approvalAddress[i], type(uint256).max);
            token1.approve(approvalAddress[i], type(uint256).max);
        }
        permit2.approve(address(token0), address(cpm), type(uint160).max, type(uint48).max);
        permit2.approve(address(token1), address(cpm), type(uint160).max, type(uint48).max);
        vm.stopPrank();

        vm.startPrank(BOB);
        for (uint256 i; i < approvalAddress.length; i++) {
            token0.approve(approvalAddress[i], type(uint256).max);
            token1.approve(approvalAddress[i], type(uint256).max);
        }
        permit2.approve(address(token0), address(cpm), type(uint160).max, type(uint48).max);
        permit2.approve(address(token1), address(cpm), type(uint160).max, type(uint48).max);
        vm.stopPrank();

        vm.startPrank(CANDY);
        for (uint256 i; i < approvalAddress.length; i++) {
            token0.approve(approvalAddress[i], type(uint256).max);
            token1.approve(approvalAddress[i], type(uint256).max);
        }
        permit2.approve(address(token0), address(cpm), type(uint160).max, type(uint48).max);
        permit2.approve(address(token1), address(cpm), type(uint160).max, type(uint48).max);
        vm.stopPrank();

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: antiSniping,
            poolManager: poolManager,
            fee: FEE,
            parameters: bytes32(uint256(antiSniping.getHooksRegistrationBitmap())).setTickSpacing(60)
        });
        id = key.toId();

        poolManager.initialize(key, SQRT_RATIO_1_1);

        token0.transfer(ALICE, 10000 ether);
        token1.transfer(ALICE, 10000 ether);
        token0.transfer(BOB, 10000 ether);
        token1.transfer(BOB, 10000 ether);
        token0.transfer(CANDY, 10000 ether);
        token1.transfer(CANDY, 10000 ether);
    }

    // Helper function to mint liquidity positions (add)
    function _mintLiquidityPosition(
        address user,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidityDelta,
        bytes memory hookData
    ) internal returns (uint256 tokenId) {
        vm.prank(user);
        (tokenId, ) = cpm.mint(
            key,
            tickLower,
            tickUpper,
            // liquidity:
            liquidityDelta,
            // amount0Max:
            10000e18,
            // amount1Max:
            10000e18,
            // owner:
            user,
            // hookData:
            hookData
        );
    }

    // Helper function to decrease liquidity positions (remove)
    function _decreaseLiquidityPosition(
        address user,
        uint256 tokenId,
        uint256 liquidityDelta,
        bytes memory hookData
    ) internal {
        vm.prank(user);
        cpm.decreaseLiquidity(
        // tokenId:
            tokenId,
            // poolKey:
            key,
            // liquidity:
            liquidityDelta,
            // amount0Min:
            0,
            // amount1Min:
            0,
            // hookData:
            hookData
        );
    }

    // Helper function to perform a swap
    function _performSwapExactOutputSingle(address user, bool zeroForOne, uint128 amountOut) internal {
        vm.prank(user);
        swapRouter.exactOutputSingle(
            ICLRouterBase.CLSwapExactOutputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountOut: amountOut,
                amountInMaximum: 1.01 ether,
                hookData: ZERO_BYTES
            }),
            block.timestamp
        );
    }

    // --- Test Scenarios ---

    function testGetParameters() public {
        assertEq(antiSniping.positionLockDuration(), POSITION_LOCK_DURATION);
        assertEq(antiSniping.sameBlockPositionsLimit(), SAME_BLOCK_POSITIONS_LIMIT);
    }

    /// @notice Test that swap fee sniping is prevented
    function testSwapFeeSnipingPrevention() public {
        // Record initial balances
        uint256 aliceToken0Before = currency0.balanceOf(ALICE);
        uint256 aliceToken1Before = currency1.balanceOf(ALICE);
        uint256 bobToken0Before = currency0.balanceOf(BOB);
        uint256 bobToken1Before = currency1.balanceOf(BOB);

        aliceTokenId = _mintLiquidityPosition(ALICE, -60, 60, 10000 ether, ZERO_BYTES);

        // Advance to next block
        vm.roll(2);

        bobTokenId = _mintLiquidityPosition(BOB, -60, 60, 10000 ether, ZERO_BYTES);

        // Swap occurs in the same block
        uint128 swapAmount = 1 ether;
        _performSwapExactOutputSingle(CANDY, true, swapAmount);

        // Expected fees from swap
        uint256 token0ExpectedFees = (uint256(swapAmount) * FEE) / 1e6; // Swap amount * fee percentage

        // Advance to next block and perform another swap
        vm.roll(3);
        _performSwapExactOutputSingle(CANDY, false, swapAmount);
        uint256 token1ExpectedFees = (uint256(swapAmount) * FEE) / 1e6;

        // Collect fee info
        PoolId poolId = key.toId();
        antiSniping.collectLastBlockInfo(poolId);

        // Calculate position keys
        bytes32 alicePositionKey = CLPosition.calculatePositionKey(address(cpm), -60, 60, ALICE_SALT);
        bytes32 bobPositionKey =
                            CLPosition.calculatePositionKey(address(cpm), -60, 60, BOB_SALT);

        // Verify that Alice did not accrue fees in the creation block
        assertEq(antiSniping.firstBlockFeesToken0(poolId, alicePositionKey), 0);
        assertEq(antiSniping.firstBlockFeesToken1(poolId, alicePositionKey), 0);

        // Verify that Bob accrued fees from the first swap
        assertApproxEqAbsDecimal(antiSniping.firstBlockFeesToken0(poolId, bobPositionKey), token0ExpectedFees / 2, 1e15, 18);
        assertEq(antiSniping.firstBlockFeesToken1(poolId, bobPositionKey), 0);

        // Advance to after position lock duration
        vm.roll(POSITION_LOCK_DURATION + 2);

        // Bob removes liquidity
        _decreaseLiquidityPosition(BOB, bobTokenId, 10000 ether, ZERO_BYTES);

        // Verify that Bob received fees from the second swap only
        uint256 bobToken0After = currency0.balanceOf(BOB);
        uint256 bobToken1After = currency1.balanceOf(BOB);
        assertApproxEqAbsDecimal(bobToken0After, bobToken0Before, 1e15, 18);
        assertApproxEqAbsDecimal(bobToken1After, bobToken1Before + token1ExpectedFees / 2, 1e15, 18);

        // Alice removes liquidity
        _decreaseLiquidityPosition(ALICE, aliceTokenId, 10000 ether, ZERO_BYTES);

        // Verify that Alice received full fees from the first swap and half from the second
        uint256 aliceToken0After = currency0.balanceOf(ALICE);
        uint256 aliceToken1After = currency1.balanceOf(ALICE);
        assertApproxEqAbsDecimal(aliceToken0After, aliceToken0Before + token0ExpectedFees, 1e15, 18);
        assertApproxEqAbsDecimal(aliceToken1After, aliceToken1Before + token1ExpectedFees / 2, 1e15, 18);
    }

    /// @notice Test that donation sniping is prevented
    function testDonationSnipingPrevention() public {
        // Record initial balances
        uint256 aliceToken0Before = currency0.balanceOf(ALICE);
        uint256 aliceToken1Before = currency1.balanceOf(ALICE);
        uint256 bobToken0Before = currency0.balanceOf(BOB);
        uint256 bobToken1Before = currency1.balanceOf(BOB);

        // Alice adds liquidity
        aliceTokenId = _mintLiquidityPosition(ALICE, -60, 60, 10000 ether, ZERO_BYTES);

        // Advance to next block
        vm.roll(2);

        bobTokenId = _mintLiquidityPosition(BOB, -60, 60, 10000 ether, ZERO_BYTES);

        vm.prank(CANDY);

        // Donation occurs
        uint256 token0Donation = 1 ether;
        uint256 token1Donation = 2 ether;
        router.donate(key, token0Donation, token1Donation, ZERO_BYTES);

        // Advance to next block and collect fee info
        vm.roll(3);
        PoolId poolId = key.toId();
        antiSniping.collectLastBlockInfo(poolId);

        // Calculate position keys
        bytes32 alicePositionKey = CLPosition.calculatePositionKey(address(cpm), -60, 60, ALICE_SALT);
        bytes32 bobPositionKey =
                            CLPosition.calculatePositionKey(address(cpm), -60, 60, BOB_SALT);

        // Verify that Alice did not accrue fees in the creation block
        assertEq(antiSniping.firstBlockFeesToken0(poolId, alicePositionKey), 0);
        assertEq(antiSniping.firstBlockFeesToken1(poolId, alicePositionKey), 0);

        // Verify that Bob accrued fees in the creation block
        uint256 allowedError = 0.00001e18; // 0.001%
        assertApproxEqRel(antiSniping.firstBlockFeesToken0(poolId, bobPositionKey), token0Donation / 2, allowedError);
        assertApproxEqRel(antiSniping.firstBlockFeesToken1(poolId, bobPositionKey), token1Donation / 2, allowedError);

        // Advance to after position lock duration
        vm.roll(POSITION_LOCK_DURATION + 2);

        // Bob removes liquidity
        _decreaseLiquidityPosition(BOB, bobTokenId, 10000 ether, ZERO_BYTES);

        // Verify that Bob did not receive any fees
        uint256 bobToken0After = currency0.balanceOf(BOB);
        uint256 bobToken1After = currency1.balanceOf(BOB);
        assertApproxEqRel(bobToken0After, bobToken0Before, allowedError);
        assertApproxEqRel(bobToken1After, bobToken1Before, allowedError);

        // Alice removes liquidity
        _decreaseLiquidityPosition(ALICE, aliceTokenId, 10000 ether, ZERO_BYTES);

        // Verify that Alice received all the donation fees
        uint256 aliceToken0After = currency0.balanceOf(ALICE);
        uint256 aliceToken1After = currency1.balanceOf(ALICE);
        assertApproxEqRel(aliceToken0After, aliceToken0Before + token0Donation, allowedError);
        assertApproxEqRel(aliceToken1After, aliceToken1Before + token1Donation, allowedError);
    }

    /// @notice Test that fees are returned to the sender when no liquidity is left to donate to
    function testFeeRedistributionWhenNoLiquidity() public {
        // Record initial balance
        uint256 aliceToken0Before = currency0.balanceOf(ALICE);

        // Alice adds liquidity
        aliceTokenId = _mintLiquidityPosition(ALICE, -60, 60, 10000 ether, ZERO_BYTES);

        // Swap occurs in the same block
        uint128 swapAmount = 1 ether;
        _performSwapExactOutputSingle(CANDY, true, swapAmount);
        uint256 token0ExpectedFees = (uint256(swapAmount) * FEE) / 1e6;

        // Advance to next block and collect fee info
        vm.roll(2);
        PoolId poolId = key.toId();
        antiSniping.collectLastBlockInfo(poolId);

        // Calculate position keys
        bytes32 alicePositionKey = CLPosition.calculatePositionKey(address(cpm), -60, 60, ALICE_SALT);

        // Verify that Alice accrued fees in the creation block
        assertApproxEqAbsDecimal(antiSniping.firstBlockFeesToken0(poolId, alicePositionKey), token0ExpectedFees, 1e15, 18);

        // Advance to after position lock duration
        vm.roll(POSITION_LOCK_DURATION + 1);

        // Alice removes liquidity
        _decreaseLiquidityPosition(ALICE, aliceTokenId, 10000 ether, ZERO_BYTES);

        // Verify that fees are returned to Alice since there's no liquidity left to donate to
        uint256 aliceToken0After = currency0.balanceOf(ALICE);
        assertApproxEqAbsDecimal(
            aliceToken0After, aliceToken0Before + uint256(swapAmount) + token0ExpectedFees, 1e15, 18
        );
    }

    // --- Safeguard Tests ---

    /// @notice Test that attempting to remove liquidity before lock duration reverts
    function testEarlyLiquidityRemovalReverts() public {
        // Alice adds liquidity
        aliceTokenId = _mintLiquidityPosition(ALICE, -60, 60, 10 ether, ZERO_BYTES);

        // Advance a few blocks but less than lock duration
        vm.roll(vm.getBlockNumber() + 5);
        assertLt(5, antiSniping.positionLockDuration());

        // Attempt to remove liquidity and expect revert
        vm.expectRevert();
        _decreaseLiquidityPosition(ALICE, aliceTokenId, 10 ether, ZERO_BYTES);
    }

    /// @notice Test that partial liquidity removal reverts
    function testPartialLiquidityRemovalReverts() public {
        // Alice adds liquidity
        aliceTokenId = _mintLiquidityPosition(ALICE, -60, 60, 10 ether, ZERO_BYTES);

        // Advance past lock duration
        vm.roll(POSITION_LOCK_DURATION);

        // Attempt to partially remove liquidity and expect revert
        vm.expectRevert();
        _decreaseLiquidityPosition(ALICE, aliceTokenId, 5 ether, ZERO_BYTES);
    }

    /// @notice Test that exceeding same block position limit reverts
    function testExceedingSameBlockPositionsLimitReverts() public {
        // Add positions up to the limit
        for (uint256 i = 0; i < SAME_BLOCK_POSITIONS_LIMIT; ++i) {
            _mintLiquidityPosition(ALICE, -60, 60, 10 ether, ZERO_BYTES);
        }

        // Attempt to add one more position and expect revert
        vm.expectRevert();
        _mintLiquidityPosition(ALICE, -60, 60, 10 ether, ZERO_BYTES);
    }
}