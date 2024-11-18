// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {CLMigrator} from "../src/pool-cl/CLMigrator.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * Step 1: Deploy
 * forge script script/06_DeployCLMigrator.s.sol:DeployCLMigratorScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow
 *
 * Step 2: Verify
 * forge verify-contract <address> CLMigrator --watch \
 *      --chain <chainId> --constructor-args $(cast abi-encode "constructor(address,address,address)" <weth> <clPositionManager> <permit2>)
 */
contract DeployCLMigratorScript is BaseScript {
    function getDeploymentSalt() public pure override returns (bytes32) {
        return keccak256("PANCAKE-V4-PERIPHERY/CLMigrator/0.90");
    }

    function run() public {
        Create3Factory factory = Create3Factory(getAddressFromConfig("create3Factory"));

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address weth = getAddressFromConfig("weth");
        emit log_named_address("WETH", weth);

        address clPositionManager = getAddressFromConfig("clPositionManager");
        emit log_named_address("CLPositionManager", clPositionManager);

        address permit2 = getAddressFromConfig("permit2");
        emit log_named_address("Permit2", permit2);

        /// @dev prepare the payload to transfer ownership from deployer to real owner
        bytes memory afterDeploymentExecutionPayload =
            abi.encodeWithSelector(Ownable.transferOwnership.selector, getAddressFromConfig("owner"));

        bytes memory creationCode = abi.encodePacked(
            type(CLMigrator).creationCode, abi.encode(weth, clPositionManager, IAllowanceTransfer(permit2))
        );
        address clMigrator = factory.deploy(
            getDeploymentSalt(), creationCode, keccak256(creationCode), 0, afterDeploymentExecutionPayload, 0
        );

        emit log_named_address("CLMigrator", address(clMigrator));

        vm.stopBroadcast();
    }
}
