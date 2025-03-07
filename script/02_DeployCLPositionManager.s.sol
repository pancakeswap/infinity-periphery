// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {CLPositionManager} from "../src/pool-cl/CLPositionManager.sol";
import {ICLPositionDescriptor} from "../src/pool-cl/interfaces/ICLPositionDescriptor.sol";
import {IWETH9} from "../src/interfaces/external/IWETH9.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * Pre-req: foundry on stable (1.0) otherwise verify will fail: ref https://github.com/foundry-rs/foundry/issues/9698
 *
 * Step 1: Deploy
 * forge script script/02_DeployCLPositionManager.s.sol:DeployCLPositionManagerScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow \
 *     --verify
 */
contract DeployCLPositionManagerScript is BaseScript {
    function getDeploymentSalt() public pure override returns (bytes32) {
        return keccak256("INFINITY-PERIPHERY/CLPositionManager/1.0.0");
    }

    function run() public {
        Create3Factory factory = Create3Factory(getAddressFromConfig("create3Factory"));

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address vault = getAddressFromConfig("vault");
        emit log_named_address("Vault", vault);

        address clPoolManager = getAddressFromConfig("clPoolManager");
        emit log_named_address("CLPoolManager", clPoolManager);

        address permit2 = getAddressFromConfig("permit2");
        emit log_named_address("Permit2", permit2);

        uint256 unsubscribeGasLimit = getUint256FromConfig("clPositionManagerUnsubscribeGasLimit");
        emit log_named_uint("unsubscribeGasLimit", unsubscribeGasLimit);

        address clPositionDescriptor = getAddressFromConfig("clPositionDescriptor");
        emit log_named_address("CLPositionDescriptor", clPositionDescriptor);

        address weth = getAddressFromConfig("weth");
        emit log_named_address("WETH", weth);

        bytes memory creationCodeData = abi.encode(
            IVault(vault),
            ICLPoolManager(clPoolManager),
            IAllowanceTransfer(permit2),
            unsubscribeGasLimit,
            ICLPositionDescriptor(clPositionDescriptor),
            IWETH9(weth)
        );
        bytes memory creationCode = abi.encodePacked(type(CLPositionManager).creationCode, creationCodeData);
        address clPositionManager =
            factory.deploy(getDeploymentSalt(), creationCode, keccak256(creationCode), 0, new bytes(0), 0);

        emit log_named_address("CLPositionManager", clPositionManager);

        vm.stopBroadcast();
    }
}
