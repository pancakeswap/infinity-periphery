// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";
import {IBinQuoter} from "../src/pool-bin/interfaces/IBinQuoter.sol";
import {ICLQuoter} from "../src/pool-cl/interfaces/ICLQuoter.sol";
import {MixedQuoter} from "../src/MixedQuoter.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";

/**
 * Pre-req: foundry on stable (1.0) otherwise verify will fail: ref https://github.com/foundry-rs/foundry/issues/9698
 *
 * Step 1: Deploy
 * forge script script/08_DeployMixedQuoter.s.sol:DeployMixedQuoterScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow \
 *     --verify
 */
contract DeployMixedQuoterScript is BaseScript {
    function getDeploymentSalt() public pure override returns (bytes32) {
        return keccak256("INFINITY-PERIPHERY/MixedQuoter/1.0.0");
    }

    function run() public {
        Create3Factory factory = Create3Factory(getAddressFromConfig("create3Factory"));

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address factoryV3 = getAddressFromConfig("factoryV3");
        emit log_named_address("factoryV3", factoryV3);

        address factoryV2 = getAddressFromConfig("factoryV2");
        emit log_named_address("factoryV2", factoryV2);

        address factoryStable = getAddressFromConfig("factoryStable");
        emit log_named_address("factoryStable", factoryStable);

        address weth = getAddressFromConfig("weth");
        emit log_named_address("WETH", weth);

        address clQuoter = getAddressFromConfig("clQuoter");
        emit log_named_address("clQuoter", clQuoter);

        address binQuoter = getAddressFromConfig("binQuoter");
        emit log_named_address("binQuoter", binQuoter);

        bytes memory creationCode = abi.encodePacked(
            type(MixedQuoter).creationCode, abi.encode(factoryV3, factoryV2, factoryStable, weth, clQuoter, binQuoter)
        );
        address mixedQuoter =
            factory.deploy(getDeploymentSalt(), creationCode, keccak256(creationCode), 0, new bytes(0), 0);

        emit log_named_address("mixedQuoter", address(mixedQuoter));

        vm.stopBroadcast();
    }
}
