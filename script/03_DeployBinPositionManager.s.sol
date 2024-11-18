// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {BinPositionManager} from "../src/pool-bin/BinPositionManager.sol";
import {IWETH9} from "../src/interfaces/external/IWETH9.sol";
import {Create3Factory} from "pancake-create3-factory/src/Create3Factory.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * Step 1: Deploy
 * forge script script/03_DeployBinPositionManager.s.sol:DeployBinPositionManagerScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow
 *
 * Step 2: Verify
 * forge verify-contract <address> BinPositionManager --watch \
 *      --chain <chainId> --constructor-args $(cast abi-encode "constructor(address,address,address,address)" <vault> <binPoolManager> <permit2> <weth9>)
 */
contract DeployBinPositionManagerScript is BaseScript {
    function getDeploymentSalt() public pure override returns (bytes32) {
        return keccak256("PANCAKE-V4-PERIPHERY/BinPositionManager/0.90");
    }

    function run() public {
        Create3Factory factory = Create3Factory(getAddressFromConfig("create3Factory"));

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address vault = getAddressFromConfig("vault");
        emit log_named_address("Vault", vault);

        address binPoolManager = getAddressFromConfig("binPoolManager");
        emit log_named_address("BinPoolManager", binPoolManager);

        address permit2 = getAddressFromConfig("permit2");
        emit log_named_address("Permit2", permit2);

        address weth = getAddressFromConfig("weth");
        emit log_named_address("WETH", weth);

        bytes memory creationCodeData =
            abi.encode(IVault(vault), IBinPoolManager(binPoolManager), IAllowanceTransfer(permit2), IWETH9(weth));
        bytes memory creationCode = abi.encodePacked(type(BinPositionManager).creationCode, creationCodeData);
        address binPositionManager =
            factory.deploy(getDeploymentSalt(), creationCode, keccak256(creationCode), 0, new bytes(0), 0);
        emit log_named_address("BinPositionManager", binPositionManager);

        vm.stopBroadcast();
    }
}
