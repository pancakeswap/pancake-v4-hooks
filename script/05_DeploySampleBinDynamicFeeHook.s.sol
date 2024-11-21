// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";

import {SampleBinDynamicFeeHook} from "../src/pool-bin/dynamic-fee/SampleBinDynamicFeeHook.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";

/**
 * Step 1: Deploy
 * forge script script/05_DeploySampleBinDynamicFeeHook.s.sol:DeploySampleBinDynamicFeeHookScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow
 *
 * Step 2: Verify
 * forge verify-contract <address> SampleBinDynamicFeeHook --watch \
 *      --chain <chain_id> --constructor-args $(cast abi-encode "constructor(address)" "<binPoolManager>")
 */
contract DeploySampleBinDynamicFeeHookScript is BaseScript {
    function getDeploymentSalt() public pure override returns (bytes32) {
        return keccak256("PANCAKE-V4-HOOKS/SampleBinDynamicFeeHook/0.90");
    }

    function run() public {
        Create3Factory factory = Create3Factory(getAddressFromConfig("create3Factory"));

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address binPoolManager = getAddressFromConfig("binPoolManager");
        emit log_named_address("BinPoolManager", binPoolManager);

        bytes memory creationCode =
            abi.encodePacked(type(SampleBinDynamicFeeHook).creationCode, abi.encode(binPoolManager));
        address feeHook = factory.deploy(getDeploymentSalt(), creationCode, keccak256(creationCode), 0, new bytes(0), 0);
        emit log_named_address("SampleBinDynamicFeeHook", address(feeHook));

        vm.stopBroadcast();
    }
}
