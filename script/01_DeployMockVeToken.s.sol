// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/**
 * Step 1: Deploy
 * forge script script/01_DeployMockVeToken.s.sol:DeployMockVeTokenScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow
 *
 * Step 2: Verify
 * forge verify-contract <address> lib/pancake-v4-universal-router/lib/pancake-v4-periphery/lib/pancake-v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol:MockERC20 --watch \
 *      --chain <chain_id> --constructor-args $(cast abi-encode "constructor(string, string, uint256)" "MockVeCake" "VeCake" "18")
 */
contract DeployMockVeTokenScript is BaseScript {
    function getDeploymentSalt() public pure override returns (bytes32) {
        return keccak256("PANCAKE-V4-HOOKS/MockERC20/0.90");
    }

    function run() public {
        Create3Factory factory = Create3Factory(getAddressFromConfig("create3Factory"));

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        bytes memory creationCode =
            abi.encodePacked(type(MockERC20).creationCode, abi.encode("MockVeCake", "VeCake", 18));
        address VeCake = factory.deploy(getDeploymentSalt(), creationCode, keccak256(creationCode), 0, new bytes(0), 0);

        emit log_named_address("MockVeCake", address(VeCake));

        vm.stopBroadcast();
    }
}
