// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";

import {SampleCLDynamicFeeHook} from "../src/pool-cl/dynamic-fee/SampleCLDynamicFeeHook.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";

/**
 * forge script script/04_DeploySampleCLDynamicFeeHook.s.sol:DeploySampleCLDynamicFeeHookScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow \
 *     --verify
 */
contract DeploySampleCLDynamicFeeHookScript is BaseScript {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address clPoolManager = getAddressFromConfig("clPoolManager");
        emit log_named_address("CLPoolManager", clPoolManager);

        SampleCLDynamicFeeHook hookAddr = new SampleCLDynamicFeeHook(ICLPoolManager(clPoolManager));
        emit log_named_address("SampleCLDynamicFeeHook", address(hookAddr));

        vm.stopBroadcast();
    }
}
