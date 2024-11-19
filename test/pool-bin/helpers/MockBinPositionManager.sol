// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {CommonBase} from "forge-std/Base.sol";
import {Vm} from "forge-std/Vm.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {IWETH9} from "pancake-v4-periphery/src/interfaces/external/IWETH9.sol";
import {IBinPositionManager} from "pancake-v4-periphery/src/pool-bin/interfaces/IBinPositionManager.sol";
import {BinPositionManager} from "pancake-v4-periphery/src/pool-bin/BinPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Planner, Plan} from "pancake-v4-periphery/src/libraries/Planner.sol";
import {Actions} from "pancake-v4-periphery/src/libraries/Actions.sol";

contract MockBinPositionManager is BinPositionManager, CommonBase {
    using Planner for Plan;

    constructor(IVault _vault, IBinPoolManager _binPoolManager, IAllowanceTransfer _permit2)
        BinPositionManager(_vault, _binPoolManager, _permit2, IWETH9(address(0)))
    {}

    function addLiquidity(IBinPositionManager.BinAddLiquidityParams calldata params)
        external
        payable
        returns (uint128, uint128, uint256[] memory tokenIds, uint256[] memory liquidityMinted)
    {
        Plan memory planner = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(params));
        bytes memory data = planner.finalizeModifyLiquidityWithClose(params.poolKey);

        vm.recordLogs();

        vm.prank(msg.sender);
        this.modifyLiquidities(data, block.timestamp);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        // find IBinFungibleToken.TransferBatch
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("TransferBatch(address,address,address,uint256[],uint256[])")) {
                (tokenIds, liquidityMinted) = abi.decode(entries[i].data, (uint256[], uint256[]));
            }
        }
    }

    function removeLiquidity(IBinPositionManager.BinRemoveLiquidityParams calldata params) external payable {
        Plan memory planner = Planner.init().add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(params));
        bytes memory data = planner.finalizeModifyLiquidityWithClose(params.poolKey);

        vm.prank(msg.sender);
        this.modifyLiquidities(data, block.timestamp);
    }
}
