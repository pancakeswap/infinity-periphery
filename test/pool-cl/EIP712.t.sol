//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {EIP712} from "../../src/pool-cl/base/EIP712.sol";

contract EIP712Test is EIP712, Test {
    constructor() EIP712("EIP712Test") {}

    function setUp() public {}

    function test_domainSeparator() public view {
        assertEq(
            DOMAIN_SEPARATOR(),
            keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)"),
                    keccak256(bytes("EIP712Test")),
                    block.chainid,
                    address(this)
                )
            )
        );
    }

    function test_hashTypedData() public view {
        bytes32 dataHash = keccak256(abi.encodePacked("data"));
        assertEq(_hashTypedData(dataHash), keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), dataHash)));
    }

    function test_rebuildDomainSeparator() public {
        uint256 chainId = 4444;
        vm.chainId(chainId);
        assertEq(
            DOMAIN_SEPARATOR(),
            keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)"),
                    keccak256(bytes("EIP712Test")),
                    chainId,
                    address(this)
                )
            )
        );
    }
}
