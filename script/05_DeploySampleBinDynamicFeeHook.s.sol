// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";

import {SampleBinDynamicFeeHook} from "../src/pool-bin/dynamic-fee/SampleBinDynamicFeeHook.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";

/**
 * forge script script/05_DeploySampleBinDynamicFeeHook.s.sol:DeploySampleBinDynamicFeeHookScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow \
 *     --verify
 */
contract DeploySampleBinDynamicFeeHookScript is BaseScript {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address binPoolManager = getAddressFromConfig("binPoolManager");
        emit log_named_address("BinPoolManager", binPoolManager);

        SampleBinDynamicFeeHook feeHook = new SampleBinDynamicFeeHook(IBinPoolManager(binPoolManager));
        emit log_named_address("SampleBinDynamicFeeHook", address(feeHook));

        vm.stopBroadcast();
    }
}
