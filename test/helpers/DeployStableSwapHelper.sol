// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";

interface IOwnable {
    function transferOwnership(address newOwner) external;
}

/// @notice helper to deploy PCS stable swap
contract DeployStableSwapHelper is Script {
    function deployStableSwap(address owner) public returns (address) {
        address lpFactory = deployLPFactory();
        address twoPoolDeployer = deployTwoPoolDeployer();
        address threePoolDeployer = deployThreePoolDeployer();
        bytes memory factoryArgs = abi.encode(lpFactory, twoPoolDeployer, threePoolDeployer);
        address factory = deployFactory(owner, factoryArgs);
        IOwnable(lpFactory).transferOwnership(factory);
        IOwnable(twoPoolDeployer).transferOwnership(factory);
        IOwnable(threePoolDeployer).transferOwnership(factory);
        return factory;
    }

    function deployFactory(address owner, bytes memory args) internal returns (address) {
        bytes memory pancakeStableSwapFactoryBytecode =
            vm.readFileBinary("./test/bin/pancakeStableSwapFactory.bytecode");
        bytes memory bytecodeWithArgs = abi.encodePacked(pancakeStableSwapFactoryBytecode, args);

        address factory;
        bytes32 salt = keccak256(abi.encodePacked(msg.sender, block.timestamp));
        assembly ("memory-safe") {
            factory := create2(0, add(bytecodeWithArgs, 32), mload(bytecodeWithArgs), salt)
        }
        IOwnable(factory).transferOwnership(owner);
        return factory;
    }

    function deployLPFactory() internal returns (address) {
        bytes memory pancakeStableSwapLPFactoryBytecode =
            vm.readFileBinary("./test/bin/pancakeStableSwapLPFactory.bytecode");
        address pancakeStableSwapLPFactory;
        bytes32 salt = keccak256(abi.encodePacked(msg.sender, block.timestamp));
        assembly ("memory-safe") {
            pancakeStableSwapLPFactory := create2(
                0,
                add(pancakeStableSwapLPFactoryBytecode, 32),
                mload(pancakeStableSwapLPFactoryBytecode),
                salt
            )
        }

        return pancakeStableSwapLPFactory;
    }

    function deployTwoPoolDeployer() internal returns (address) {
        bytes memory pancakeStableSwapTwoPoolDeployerBytecode =
            vm.readFileBinary("./test/bin/pancakeStableSwapTwoPoolDeployer.bytecode");

        address pancakeStableSwapTwoPoolDeployer;
        bytes32 salt = keccak256(abi.encodePacked(msg.sender, block.timestamp));
        assembly ("memory-safe") {
            pancakeStableSwapTwoPoolDeployer := create2(
                0,
                add(pancakeStableSwapTwoPoolDeployerBytecode, 32),
                mload(pancakeStableSwapTwoPoolDeployerBytecode),
                salt
            )
        }

        return pancakeStableSwapTwoPoolDeployer;
    }

    function deployThreePoolDeployer() internal returns (address) {
        bytes memory pancakeStableSwapThreePoolDeployerBytecode =
            vm.readFileBinary("./test/bin/pancakeStableSwapThreePoolDeployer.bytecode");

        address pancakeStableSwapThreePoolDeployer;
        bytes32 salt = keccak256(abi.encodePacked(msg.sender, block.timestamp));
        assembly ("memory-safe") {
            pancakeStableSwapThreePoolDeployer := create2(
                0,
                add(pancakeStableSwapThreePoolDeployerBytecode, 32),
                mload(pancakeStableSwapThreePoolDeployerBytecode),
                salt
            )
        }

        return pancakeStableSwapThreePoolDeployer;
    }
}
