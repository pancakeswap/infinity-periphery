// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";

import {MockBinCalldataDecoder} from "../mocks/MockBinCalldataDecoder.sol";
import {CalldataDecoder} from "../../../src/libraries/CalldataDecoder.sol";
import {IInfinityRouter} from "../../../src/interfaces/IInfinityRouter.sol";
import {IBinPositionManager} from "../../../src/pool-bin/interfaces/IBinPositionManager.sol";
import {IBinRouterBase} from "../../../src/pool-bin/interfaces/IBinRouterBase.sol";
import {PathKey} from "../../../src/libraries/PathKey.sol";

contract BinCalldataDecoderTest is Test {
    MockBinCalldataDecoder decoder;

    function setUp() public {
        decoder = new MockBinCalldataDecoder();
    }

    function test_fuzz_decodeBinAddLiquidityParams(IBinPositionManager.BinAddLiquidityParams memory _addLiquidityParams)
        public
        view
    {
        bytes memory params = abi.encode(_addLiquidityParams);
        IBinPositionManager.BinAddLiquidityParams memory addLiquidityParams =
            decoder.decodeBinAddLiquidityParams(params);

        _assertEq(addLiquidityParams.poolKey, _addLiquidityParams.poolKey);
        assertEq(addLiquidityParams.amount0, _addLiquidityParams.amount0);
        assertEq(addLiquidityParams.amount1, _addLiquidityParams.amount1);
        assertEq(addLiquidityParams.amount0Max, _addLiquidityParams.amount0Max);
        assertEq(addLiquidityParams.amount1Max, _addLiquidityParams.amount1Max);
        assertEq(addLiquidityParams.activeIdDesired, _addLiquidityParams.activeIdDesired);
        assertEq(addLiquidityParams.idSlippage, _addLiquidityParams.idSlippage);
        _assertEq(addLiquidityParams.deltaIds, _addLiquidityParams.deltaIds);
        _assertEq(addLiquidityParams.distributionX, _addLiquidityParams.distributionX);
        _assertEq(addLiquidityParams.distributionY, _addLiquidityParams.distributionY);
        assertEq(addLiquidityParams.to, _addLiquidityParams.to);
    }

    function test_fuzz_decodeBinRemoveLiquidityParams(
        IBinPositionManager.BinRemoveLiquidityParams memory _removeLiquidityParams
    ) public view {
        bytes memory params = abi.encode(_removeLiquidityParams);
        IBinPositionManager.BinRemoveLiquidityParams memory removeLiquidityParams =
            decoder.decodeBinRemoveLiquidityParams(params);

        _assertEq(removeLiquidityParams.poolKey, _removeLiquidityParams.poolKey);
        assertEq(removeLiquidityParams.amount0Min, _removeLiquidityParams.amount0Min);
        assertEq(removeLiquidityParams.amount1Min, _removeLiquidityParams.amount1Min);
        _assertEq(removeLiquidityParams.ids, _removeLiquidityParams.ids);
        _assertEq(removeLiquidityParams.amounts, _removeLiquidityParams.amounts);
        assertEq(removeLiquidityParams.from, _removeLiquidityParams.from);
    }

    function test_fuzz_decodeBinAddLiquidityFromDeltasParams(
        IBinPositionManager.BinAddLiquidityFromDeltasParams memory _addLiquidityParams
    ) public view {
        bytes memory params = abi.encode(_addLiquidityParams);
        IBinPositionManager.BinAddLiquidityFromDeltasParams memory addLiquidityParams =
            decoder.decodeBinAddLiquidityFromDeltasParams(params);

        _assertEq(addLiquidityParams.poolKey, _addLiquidityParams.poolKey);
        assertEq(addLiquidityParams.amount0Max, _addLiquidityParams.amount0Max);
        assertEq(addLiquidityParams.amount1Max, _addLiquidityParams.amount1Max);
        assertEq(addLiquidityParams.activeIdDesired, _addLiquidityParams.activeIdDesired);
        assertEq(addLiquidityParams.idSlippage, _addLiquidityParams.idSlippage);
        _assertEq(addLiquidityParams.deltaIds, _addLiquidityParams.deltaIds);
        _assertEq(addLiquidityParams.distributionX, _addLiquidityParams.distributionX);
        _assertEq(addLiquidityParams.distributionY, _addLiquidityParams.distributionY);
        assertEq(addLiquidityParams.to, _addLiquidityParams.to);
    }

    function test_fuzz_decodeBinSwapExactInParams(IInfinityRouter.BinSwapExactInputParams memory _swapParams)
        public
        view
    {
        bytes memory params = abi.encode(_swapParams);
        IInfinityRouter.BinSwapExactInputParams memory swapParams = decoder.decodeBinSwapExactInParams(params);

        assertEq(Currency.unwrap(swapParams.currencyIn), Currency.unwrap(_swapParams.currencyIn));
        _assertEq(swapParams.path, _swapParams.path);
        assertEq(swapParams.amountIn, _swapParams.amountIn);
        assertEq(swapParams.amountOutMinimum, _swapParams.amountOutMinimum);
    }

    function test_decodeBinSwapExactInParams_outOfBounds() public {
        PathKey[] memory path = new PathKey[](0);
        IInfinityRouter.BinSwapExactInputParams memory _swapParams = IBinRouterBase.BinSwapExactInputParams({
            currencyIn: Currency.wrap(makeAddr("currencyIn")), path: path, amountIn: 1 ether, amountOutMinimum: 1 ether
        });

        /// @dev params.length is 192 as abi.encode adds 32 bytes for dynamic field. However ether.js doesn't add 32 bytes
        /// thus we need to remove 32 bytes from the end of the params
        /// ref: https://ethereum.stackexchange.com/questions/152971/abi-encode-decode-mystery-additional-32-byte-field-uniswap-v2
        bytes memory params = abi.encode(_swapParams);
        assertEq(params.length, 192);
        bytes memory invalidParam = _removeBytes(params, 32 + 1);
        assertEq(invalidParam.length, params.length - 33);

        vm.expectRevert(CalldataDecoder.SliceOutOfBounds.selector);
        decoder.decodeBinSwapExactInParams(invalidParam);
    }

    function test_fuzz_decodeBinSwapExactInSingleParams(
        IInfinityRouter.BinSwapExactInputSingleParams memory _swapParams
    ) public view {
        bytes memory params = abi.encode(_swapParams);
        IInfinityRouter.BinSwapExactInputSingleParams memory swapParams =
            decoder.decodeBinSwapExactInSingleParams(params);

        _assertEq(swapParams.poolKey, _swapParams.poolKey);
        assertEq(swapParams.swapForY, _swapParams.swapForY);
        assertEq(swapParams.amountIn, _swapParams.amountIn);
        assertEq(swapParams.amountOutMinimum, _swapParams.amountOutMinimum);
        assertEq(swapParams.hookData, _swapParams.hookData);
    }

    function test_fuzz_decodeBinSwapExactInSingleParams_outOfBounds(PoolKey memory key) public {
        IInfinityRouter.BinSwapExactInputSingleParams memory _swapParams = IBinRouterBase.BinSwapExactInputSingleParams({
            poolKey: key, swapForY: true, amountIn: 1 ether, amountOutMinimum: 1 ether, hookData: ""
        });

        /// @dev params.length is 384 as abi.encode adds 32 bytes for dynamic field. However ether.js doesn't add 32 bytes
        /// thus we need to remove 32 bytes from the end of the params
        /// ref: https://ethereum.stackexchange.com/questions/152971/abi-encode-decode-mystery-additional-32-byte-field-uniswap-v2
        bytes memory params = abi.encode(_swapParams);
        assertEq(params.length, 0x180);
        bytes memory invalidParam = _removeBytes(params, 32 + 1);
        assertEq(invalidParam.length, 0x160 - 1);

        vm.expectRevert(CalldataDecoder.SliceOutOfBounds.selector);
        decoder.decodeBinSwapExactInSingleParams(invalidParam);
    }

    function test_fuzz_decodeBinSwapExactOutParams(IInfinityRouter.BinSwapExactOutputParams memory _swapParams)
        public
        view
    {
        bytes memory params = abi.encode(_swapParams);
        IInfinityRouter.BinSwapExactOutputParams memory swapParams = decoder.decodeBinSwapExactOutParams(params);

        assertEq(Currency.unwrap(swapParams.currencyOut), Currency.unwrap(_swapParams.currencyOut));
        _assertEq(swapParams.path, _swapParams.path);
        assertEq(swapParams.amountOut, _swapParams.amountOut);
        assertEq(swapParams.amountInMaximum, _swapParams.amountInMaximum);
    }

    function test_decodeBinSwapExactOutParams_outOfBounds() public {
        PathKey[] memory path = new PathKey[](0);
        IInfinityRouter.BinSwapExactOutputParams memory _swapParams = IBinRouterBase.BinSwapExactOutputParams({
            currencyOut: Currency.wrap(makeAddr("currencyOut")),
            path: path,
            amountOut: 1 ether,
            amountInMaximum: 1 ether
        });

        /// @dev params.length is 192 as abi.encode adds 32 bytes for dynamic field. However ether.js doesn't add 32 bytes
        /// thus we need to remove 32 bytes from the end of the params
        /// ref: https://ethereum.stackexchange.com/questions/152971/abi-encode-decode-mystery-additional-32-byte-field-uniswap-v2
        bytes memory params = abi.encode(_swapParams);
        assertEq(params.length, 192);
        bytes memory invalidParam = _removeBytes(params, 32 + 1);
        assertEq(invalidParam.length, params.length - 33);

        vm.expectRevert(CalldataDecoder.SliceOutOfBounds.selector);
        decoder.decodeBinSwapExactOutParams(invalidParam);
    }

    function test_fuzz_decodeBinSwapExactOutSingleParams(
        IInfinityRouter.BinSwapExactOutputSingleParams memory _swapParams
    ) public view {
        bytes memory params = abi.encode(_swapParams);
        IInfinityRouter.BinSwapExactOutputSingleParams memory swapParams =
            decoder.decodeBinSwapExactOutSingleParams(params);

        _assertEq(swapParams.poolKey, _swapParams.poolKey);
        assertEq(swapParams.swapForY, _swapParams.swapForY);
        assertEq(swapParams.amountOut, _swapParams.amountOut);
        assertEq(swapParams.amountInMaximum, _swapParams.amountInMaximum);
        assertEq(swapParams.hookData, _swapParams.hookData);
    }

    function test_fuzz_decodeBinSwapExactOutSingleParams_outOfBounds(PoolKey memory key) public {
        IInfinityRouter.BinSwapExactOutputSingleParams memory _swapParams = IBinRouterBase.BinSwapExactOutputSingleParams({
            poolKey: key, swapForY: true, amountOut: 1 ether, amountInMaximum: 1 ether, hookData: ""
        });

        /// @dev params.length is 384 as abi.encode adds 32 bytes for dynamic field. However ether.js doesn't add 32 bytes
        /// thus we need to remove 32 bytes from the end of the params
        /// ref: https://ethereum.stackexchange.com/questions/152971/abi-encode-decode-mystery-additional-32-byte-field-uniswap-v2
        bytes memory params = abi.encode(_swapParams);
        assertEq(params.length, 0x180);
        bytes memory invalidParam = _removeBytes(params, 32 + 1);
        assertEq(invalidParam.length, 0x160 - 1);

        vm.expectRevert(CalldataDecoder.SliceOutOfBounds.selector);
        decoder.decodeBinSwapExactOutSingleParams(invalidParam);
    }

    function _assertEq(PathKey[] memory path1, PathKey[] memory path2) internal pure {
        assertEq(path1.length, path2.length);
        for (uint256 i = 0; i < path1.length; i++) {
            assertEq(Currency.unwrap(path1[i].intermediateCurrency), Currency.unwrap(path2[i].intermediateCurrency));
            assertEq(path1[i].fee, path2[i].fee);
            assertEq(address(path1[i].hooks), address(path2[i].hooks));
            assertEq(address(path1[i].poolManager), address(path2[i].poolManager));
            assertEq(path1[i].hookData, path2[i].hookData);
            assertEq(path1[i].parameters, path2[i].parameters);
        }
    }

    function _assertEq(PoolKey memory key1, PoolKey memory key2) internal pure {
        assertEq(Currency.unwrap(key1.currency0), Currency.unwrap(key2.currency0));
        assertEq(Currency.unwrap(key1.currency1), Currency.unwrap(key2.currency1));
        assertEq(address(key1.hooks), address(key2.hooks));
        assertEq(address(key1.poolManager), address(key2.poolManager));
        assertEq(key1.fee, key2.fee);
        assertEq(key1.parameters, key2.parameters);
    }

    function _assertEq(int256[] memory arr1, int256[] memory arr2) internal pure {
        assertEq(arr1.length, arr2.length);
        for (uint256 i = 0; i < arr1.length; i++) {
            assertEq(arr1[i], arr2[i]);
        }
    }

    function _assertEq(uint256[] memory arr1, uint256[] memory arr2) internal pure {
        assertEq(arr1.length, arr2.length);
        for (uint256 i = 0; i < arr1.length; i++) {
            assertEq(arr1[i], arr2[i]);
        }
    }

    function _removeFinalByte(bytes memory params) internal pure returns (bytes memory result) {
        result = new bytes(params.length - 1);
        // dont copy the final byte
        for (uint256 i = 0; i < params.length - 2; i++) {
            result[i] = params[i];
        }
    }

    /// @param amountOfByteToRemove the number of bytes to remove from the end of params
    function _removeBytes(bytes memory params, uint256 amountOfByteToRemove)
        internal
        pure
        returns (bytes memory result)
    {
        result = new bytes(params.length - amountOfByteToRemove);
        // dont copy the final byte
        for (uint256 i = 0; i < result.length; i++) {
            result[i] = params[i];
        }
    }
}
