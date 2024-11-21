// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";

import {SampleCLDynamicFeeHook} from "../src/pool-cl/dynamic-fee/SampleCLDynamicFeeHook.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";

/**
 * Step 1: Deploy
 * forge script script/04_DeploySampleCLDynamicFeeHook.s.sol:DeploySampleCLDynamicFeeHookScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow
 *
 * Step 2: Verify
 * forge verify-contract <address> SampleCLDynamicFeeHook --watch \
 *      --chain <chain_id> --constructor-args $(cast abi-encode "constructor(address)" "<clPoolManager>")
 */
contract DeploySampleCLDynamicFeeHookScript is BaseScript {
    function getDeploymentSalt() public pure override returns (bytes32) {
        return keccak256("PANCAKE-V4-HOOKS/SampleCLDynamicFeeHook/0.90");
    }

    function run() public {
        Create3Factory factory = Create3Factory(getAddressFromConfig("create3Factory"));

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address clPoolManager = getAddressFromConfig("clPoolManager");
        emit log_named_address("CLPoolManager", clPoolManager);

        bytes memory creationCode =
            abi.encodePacked(type(SampleCLDynamicFeeHook).creationCode, abi.encode(clPoolManager));
        address hookAddr =
            factory.deploy(getDeploymentSalt(), creationCode, keccak256(creationCode), 0, new bytes(0), 0);
        emit log_named_address("SampleCLDynamicFeeHook", address(hookAddr));

        vm.stopBroadcast();
    }
}
