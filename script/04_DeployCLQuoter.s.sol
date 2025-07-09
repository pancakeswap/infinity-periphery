// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";
import {CLQuoter} from "../src/pool-cl/lens/CLQuoter.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";

// Quoter Address : 0x0a46ccb50859bf6b7477d52db8b21fdc187d59e5

/**
 * Pre-req: foundry on stable (1.0) otherwise verify will fail: ref https://github.com/foundry-rs/foundry/issues/9698
 *
 * Step 1: Deploy
 * forge script script/04_DeployCLQuoter.s.sol:DeployCLQuoterScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow \
 *     --verify
 */
contract DeployCLQuoterScript is BaseScript {
    function getDeploymentSalt() public pure override returns (bytes32) {
        return keccak256("INFINITY-PERIPHERY/CLQuoter/1.0.0");
    }

    function run() public {
        // Create3Factory factory = Create3Factory(getAddressFromConfig("create3Factory"));

        vm.startBroadcast();

        address poolManager = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;

        address quoter = address(new CLQuoter(poolManager));

        console.log("Quoter address : ");
        console.logAddress(quoter);

        // address clPoolManager = getAddressFromConfig("clPoolManager");
        // emit log_named_address("CLPoolManager", clPoolManager);

        // bytes memory creationCodeData = abi.encode(clPoolManager);
        // bytes memory creationCode = abi.encodePacked(type(CLQuoter).creationCode, creationCodeData);
        // address clQuoter =
        //     factory.deploy(getDeploymentSalt(), creationCode, keccak256(creationCode), 0, new bytes(0), 0);
        // emit log_named_address("CLQuoter", clQuoter);

        vm.stopBroadcast();
    }
}
