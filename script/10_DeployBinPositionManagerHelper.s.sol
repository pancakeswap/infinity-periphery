// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {IBinPositionManagerWithERC1155} from "../src/pool-bin/interfaces/IBinPositionManagerWithERC1155.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IWETH9} from "../src/interfaces/external/IWETH9.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";
import {BinPositionManagerHelper} from "../src/pool-bin/BinPositionManagerHelper.sol";

/**
 * Pre-req: foundry on stable (1.0) otherwise verify will fail: ref https://github.com/foundry-rs/foundry/issues/9698
 *
 * Step 1: Deploy
 * forge script script/10_DeployBinPositionManagerHelper.s.sol:DeployBinPositionManagerHelper -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow \
 *     --verify
 */
contract DeployBinPositionManagerHelper is BaseScript {
    function getDeploymentSalt() public pure override returns (bytes32) {
        return keccak256("INFINITY-PERIPHERY/BinPositionManagerHelper/1.0.0");
    }

    function run() public {
        Create3Factory factory = Create3Factory(getAddressFromConfig("create3Factory"));

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address binPoolManager = getAddressFromConfig("binPoolManager");
        emit log_named_address("binPoolManager", binPoolManager);

        address binPositionManager = getAddressFromConfig("binPositionManager");
        emit log_named_address("binPositionManager", binPositionManager);

        address permit2 = getAddressFromConfig("permit2");
        emit log_named_address("Permit2", permit2);

        address weth = getAddressFromConfig("weth");
        emit log_named_address("WETH", weth);

        bytes memory creationCodeData = abi.encode(
            IBinPoolManager(binPoolManager),
            IBinPositionManagerWithERC1155(binPositionManager),
            IAllowanceTransfer(permit2),
            IWETH9(weth)
        );
        bytes memory creationCode = abi.encodePacked(type(BinPositionManagerHelper).creationCode, creationCodeData);
        address binPositionManagerHelper =
            factory.deploy(getDeploymentSalt(), creationCode, keccak256(creationCode), 0, new bytes(0), 0);
        emit log_named_address("BinPositionManagerHelper", binPositionManagerHelper);

        vm.stopBroadcast();
    }
}
