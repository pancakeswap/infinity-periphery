// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";

import {MockCalldataDecoder} from "../mocks/MockCalldataDecoder.sol";
import {IInfinityRouter} from "../../src/interfaces/IInfinityRouter.sol";
import {PathKey} from "../../src/libraries/PathKey.sol";
import {CalldataDecoder} from "../../src/libraries/CalldataDecoder.sol";

contract CalldataDecoderTest is Test {
    MockCalldataDecoder decoder;

    function setUp() public {
        decoder = new MockCalldataDecoder();
    }

    function test_fuzz_decodeCurrencyAndAddress(Currency _currency, address __address) public view {
        bytes memory params = abi.encode(_currency, __address);
        (Currency currency, address _address) = decoder.decodeCurrencyAndAddress(params);

        assertEq(Currency.unwrap(currency), Currency.unwrap(_currency));
        assertEq(_address, __address);
    }

    function test_fuzz_decodeCurrencyAndAddress_outOfBounds(Currency _currency, address __address) public {
        bytes memory params = abi.encode(_currency, __address);
        bytes memory invalidParams = _removeFinalByte(params);

        assertEq(invalidParams.length, params.length - 1);

        vm.expectRevert(CalldataDecoder.SliceOutOfBounds.selector);
        decoder.decodeCurrencyAndAddress(invalidParams);
    }

    function test_fuzz_decodeCurrency(Currency _currency) public view {
        bytes memory params = abi.encode(_currency);
        (Currency currency) = decoder.decodeCurrency(params);

        assertEq(Currency.unwrap(currency), Currency.unwrap(_currency));
    }

    function test_fuzz_decodeCurrency_outOfBounds(Currency _currency) public {
        bytes memory params = abi.encode(_currency);
        bytes memory invalidParams = _removeFinalByte(params);

        assertEq(invalidParams.length, params.length - 1);

        vm.expectRevert(CalldataDecoder.SliceOutOfBounds.selector);
        decoder.decodeCurrency(invalidParams);
    }

    function test_fuzz_decodeActionsRouterParams(bytes memory _actions, bytes[] memory _actionParams) public view {
        bytes memory params = abi.encode(_actions, _actionParams);
        (bytes memory actions, bytes[] memory actionParams) = decoder.decodeActionsRouterParams(params);

        assertEq(actions, _actions);
        for (uint256 i = 0; i < _actionParams.length; i++) {
            assertEq(actionParams[i], _actionParams[i]);
        }
    }

    function test_decodeActionsRouterParams_sliceOutOfBounds() public {
        // create actions and parameters
        bytes memory _actions = hex"12345678";
        bytes[] memory _actionParams = new bytes[](4);
        _actionParams[0] = hex"11111111";
        _actionParams[1] = hex"22";
        _actionParams[2] = hex"3333333333333333";
        _actionParams[3] = hex"4444444444444444444444444444444444444444444444444444444444444444";

        bytes memory params = abi.encode(_actions, _actionParams);

        bytes memory invalidParams = new bytes(params.length - 1);
        // dont copy the final byte
        for (uint256 i = 0; i < params.length - 2; i++) {
            invalidParams[i] = params[i];
        }

        assertEq(invalidParams.length, params.length - 1);

        vm.expectRevert(CalldataDecoder.SliceOutOfBounds.selector);
        decoder.decodeActionsRouterParams(invalidParams);
    }

    function test_decodeActionsRouterParams_emptyParams() public view {
        // create actions and parameters
        bytes memory _actions = hex"";
        bytes[] memory _actionParams = new bytes[](0);

        bytes memory params = abi.encode(_actions, _actionParams);

        (bytes memory actions, bytes[] memory actionParams) = decoder.decodeActionsRouterParams(params);
        assertEq(actions, _actions);
        assertEq(actionParams.length, _actionParams.length);
        assertEq(actionParams.length, 0);
    }

    function test_fuzz_decodeCurrencyPair(Currency _currency0, Currency _currency1) public view {
        bytes memory params = abi.encode(_currency0, _currency1);
        (Currency currency0, Currency currency1) = decoder.decodeCurrencyPair(params);

        assertEq(Currency.unwrap(currency0), Currency.unwrap(_currency0));
        assertEq(Currency.unwrap(currency1), Currency.unwrap(_currency1));
    }

    function test_fuzz_decodeCurrencyPair_outOfBounds(Currency _currency0, Currency _currency1) public {
        bytes memory params = abi.encode(_currency0, _currency1);
        bytes memory invalidParams = _removeFinalByte(params);

        assertEq(invalidParams.length, params.length - 1);

        vm.expectRevert(CalldataDecoder.SliceOutOfBounds.selector);
        decoder.decodeCurrencyPair(invalidParams);
    }

    function test_fuzz_decodeCurrencyPairAndAddress(Currency _currency0, Currency _currency1, address __address)
        public
        view
    {
        bytes memory params = abi.encode(_currency0, _currency1, __address);
        (Currency currency0, Currency currency1, address _address) = decoder.decodeCurrencyPairAndAddress(params);

        assertEq(Currency.unwrap(currency0), Currency.unwrap(_currency0));
        assertEq(Currency.unwrap(currency1), Currency.unwrap(_currency1));
        assertEq(_address, __address);
    }

    function test_fuzz_decodeCurrencyPairAndAddress__outOfBounds(
        Currency _currency0,
        Currency _currency1,
        address __address
    ) public {
        bytes memory params = abi.encode(_currency0, _currency1, __address);
        bytes memory invalidParams = _removeFinalByte(params);

        assertEq(invalidParams.length, params.length - 1);

        vm.expectRevert(CalldataDecoder.SliceOutOfBounds.selector);
        decoder.decodeCurrencyPairAndAddress(invalidParams);
    }

    function test_fuzz_decodeCurrencyAddressAndUint256(Currency _currency, address _addr, uint256 _amount) public view {
        bytes memory params = abi.encode(_currency, _addr, _amount);
        (Currency currency, address addr, uint256 amount) = decoder.decodeCurrencyAddressAndUint256(params);

        assertEq(Currency.unwrap(currency), Currency.unwrap(_currency));
        assertEq(addr, _addr);
        assertEq(amount, _amount);
    }

    function test_fuzz_decodeCurrencyAddressAndUint256_outOfBounds(Currency _currency, address _addr, uint256 _amount)
        public
    {
        bytes memory params = abi.encode(_currency, _addr, _amount);
        bytes memory invalidParams = _removeFinalByte(params);

        assertEq(invalidParams.length, params.length - 1);

        vm.expectRevert(CalldataDecoder.SliceOutOfBounds.selector);
        decoder.decodeCurrencyAddressAndUint256(invalidParams);
    }

    function test_fuzz_decodeCurrencyAndUint256(Currency _currency, uint256 _amount) public view {
        bytes memory params = abi.encode(_currency, _amount);
        (Currency currency, uint256 amount) = decoder.decodeCurrencyAndUint256(params);

        assertEq(Currency.unwrap(currency), Currency.unwrap(_currency));
        assertEq(amount, _amount);
    }

    function test_fuzz_decodeCurrencyAndUint256_outOfBounds(Currency _currency, uint256 _amount) public {
        bytes memory params = abi.encode(_currency, _amount);
        bytes memory invalidParams = _removeFinalByte(params);

        assertEq(invalidParams.length, params.length - 1);

        vm.expectRevert(CalldataDecoder.SliceOutOfBounds.selector);
        decoder.decodeCurrencyAndUint256(invalidParams);
    }

    function test_fuzz_decodeUint256(uint256 _amount) public view {
        bytes memory params = abi.encode(_amount);
        uint256 amount = decoder.decodeUint256(params);

        assertEq(amount, _amount);
    }

    function test_fuzz_decodeUint256_outOfBounds(uint256 _amount) public {
        bytes memory params = abi.encode(_amount);
        bytes memory invalidParams = _removeFinalByte(params);

        assertEq(invalidParams.length, params.length - 1);

        vm.expectRevert(CalldataDecoder.SliceOutOfBounds.selector);
        decoder.decodeUint256(invalidParams);
    }

    function _removeFinalByte(bytes memory params) internal pure returns (bytes memory result) {
        result = new bytes(params.length - 1);
        // dont copy the final byte
        for (uint256 i = 0; i < params.length - 2; i++) {
            result[i] = params[i];
        }
    }
}
