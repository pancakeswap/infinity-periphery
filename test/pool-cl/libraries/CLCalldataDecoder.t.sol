// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";

import {MockCLCalldataDecoder} from "../mocks/MockCLCalldataDecoder.sol";
import {CalldataDecoder} from "../../../src/libraries/CalldataDecoder.sol";
import {IInfinityRouter} from "../../../src/interfaces/IInfinityRouter.sol";
import {ICLRouterBase} from "../../../src/pool-cl/interfaces/ICLRouterBase.sol";
import {PathKey} from "../../../src/libraries/PathKey.sol";

contract CLCalldataDecoderTest is Test {
    MockCLCalldataDecoder decoder;

    function setUp() public {
        decoder = new MockCLCalldataDecoder();
    }

    function test_fuzz_decodeModifyLiquidityParams(
        uint256 _tokenId,
        uint256 _liquidity,
        uint128 _amount0,
        uint128 _amount1,
        bytes calldata _hookData
    ) public view {
        bytes memory params = abi.encode(_tokenId, _liquidity, _amount0, _amount1, _hookData);
        (uint256 tokenId, uint256 liquidity, uint128 amount0, uint128 amount1, bytes memory hookData) =
            decoder.decodeCLModifyLiquidityParams(params);

        assertEq(tokenId, _tokenId);
        assertEq(liquidity, _liquidity);
        assertEq(amount0, _amount0);
        assertEq(amount1, _amount1);
        assertEq(hookData, _hookData);
    }

    function test_fuzz_decodeCLModifyLiquidityParams_outOfBounds(
        uint256 _tokenId,
        uint256 _liquidity,
        uint128 _amount0,
        uint128 _amount1
    ) public {
        bytes memory params = abi.encode(_tokenId, _liquidity, _amount0, _amount1, "");
        bytes memory invalidParam = _removeFinalByte(params);
        assertEq(invalidParam.length, params.length - 1);

        vm.expectRevert(CalldataDecoder.SliceOutOfBounds.selector);
        decoder.decodeCLModifyLiquidityParams(invalidParam);
    }

    function test_fuzz_decodeBurnParams(
        uint256 _tokenId,
        uint128 _amount0Min,
        uint128 _amount1Min,
        bytes calldata _hookData
    ) public view {
        bytes memory params = abi.encode(_tokenId, _amount0Min, _amount1Min, _hookData);
        (uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes memory hookData) =
            decoder.decodeCLBurnParams(params);

        assertEq(tokenId, _tokenId);
        assertEq(hookData, _hookData);
        assertEq(amount0Min, _amount0Min);
        assertEq(amount1Min, _amount1Min);
    }

    function test_fuzz_decodeMintParams(
        PoolKey calldata _poolKey,
        int24 _tickLower,
        int24 _tickUpper,
        uint256 _liquidity,
        uint128 _amount0Max,
        uint128 _amount1Max,
        address _owner,
        bytes calldata _hookData
    ) public view {
        bytes memory params = abi.encode(
            _poolKey, _tickLower, _tickUpper, _liquidity, _amount0Max, _amount1Max, _owner, _hookData
        );
        (
            PoolKey memory poolKey,
            int24 tickLower,
            int24 tickUpper,
            uint256 liquidity,
            uint128 amount0Max,
            uint128 amount1Max,
            address owner,
            bytes memory hookData
        ) = decoder.decodeCLMintParams(params);

        assertEq(PoolId.unwrap(poolKey.toId()), PoolId.unwrap(_poolKey.toId()));
        assertEq(tickLower, _tickLower);
        assertEq(tickUpper, _tickUpper);
        assertEq(liquidity, _liquidity);
        assertEq(amount0Max, _amount0Max);
        assertEq(amount1Max, _amount1Max);
        assertEq(owner, _owner);
        assertEq(hookData, _hookData);
    }

    function test_fuzz_decodeMintFromDeltasParams(
        PoolKey calldata _poolKey,
        int24 _tickLower,
        int24 _tickUpper,
        uint128 _amount0Max,
        uint128 _amount1Max,
        address _owner,
        bytes calldata _hookData
    ) public view {
        bytes memory params = abi.encode(_poolKey, _tickLower, _tickUpper, _amount0Max, _amount1Max, _owner, _hookData);

        (MockCLCalldataDecoder.CLMintFromDeltasParams memory mintParams) = decoder.decodeCLMintFromDeltasParams(params);

        _assertEq(mintParams.poolKey, _poolKey);
        assertEq(mintParams.tickLower, _tickLower);
        assertEq(mintParams.tickUpper, _tickUpper);
        assertEq(mintParams.amount0Max, _amount0Max);
        assertEq(mintParams.amount1Max, _amount1Max);
        assertEq(mintParams.owner, _owner);
        assertEq(mintParams.hookData, _hookData);
    }

    function test_fuzz_decodeSwapExactInParams(IInfinityRouter.CLSwapExactInputParams calldata _swapParams)
        public
        view
    {
        bytes memory params = abi.encode(_swapParams);
        IInfinityRouter.CLSwapExactInputParams memory swapParams = decoder.decodeCLSwapExactInParams(params);

        assertEq(Currency.unwrap(swapParams.currencyIn), Currency.unwrap(_swapParams.currencyIn));
        assertEq(swapParams.amountIn, _swapParams.amountIn);
        assertEq(swapParams.amountOutMinimum, _swapParams.amountOutMinimum);
        _assertEq(swapParams.path, _swapParams.path);
    }

    function test_decodeSwapExactInParams_outOfBounds() public {
        PathKey[] memory path = new PathKey[](0);
        IInfinityRouter.CLSwapExactInputParams memory _swapParams = ICLRouterBase.CLSwapExactInputParams({
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
        decoder.decodeCLSwapExactInParams(invalidParam);
    }

    function test_fuzz_decodeSwapExactInSingleParams(IInfinityRouter.CLSwapExactInputSingleParams calldata _swapParams)
        public
        view
    {
        bytes memory params = abi.encode(_swapParams);
        IInfinityRouter.CLSwapExactInputSingleParams memory swapParams = decoder.decodeCLSwapExactInSingleParams(params);

        assertEq(swapParams.zeroForOne, _swapParams.zeroForOne);
        assertEq(swapParams.amountIn, _swapParams.amountIn);
        assertEq(swapParams.amountOutMinimum, _swapParams.amountOutMinimum);
        assertEq(swapParams.hookData, _swapParams.hookData);
        _assertEq(swapParams.poolKey, _swapParams.poolKey);
    }

    function test_fuzz_decodeSwapExactInSingleParams_outOfBounds(PoolKey memory key) public {
        IInfinityRouter.CLSwapExactInputSingleParams memory _swapParams = ICLRouterBase.CLSwapExactInputSingleParams({
            poolKey: key, zeroForOne: true, amountIn: 1 ether, amountOutMinimum: 1 ether, hookData: ""
        });

        /// @dev params.length is 384 as abi.encode adds 32 bytes for dynamic field. However ether.js doesn't add 32 bytes
        /// thus we need to remove 32 bytes from the end of the params
        /// ref: https://ethereum.stackexchange.com/questions/152971/abi-encode-decode-mystery-additional-32-byte-field-uniswap-v2
        bytes memory params = abi.encode(_swapParams);
        assertEq(params.length, 0x180);
        bytes memory invalidParam = _removeBytes(params, 32 + 1);
        assertEq(invalidParam.length, 0x160 - 1);

        vm.expectRevert(CalldataDecoder.SliceOutOfBounds.selector);
        decoder.decodeCLSwapExactInSingleParams(invalidParam);
    }

    function test_fuzz_decodeSwapExactOutParams(IInfinityRouter.CLSwapExactOutputParams calldata _swapParams)
        public
        view
    {
        bytes memory params = abi.encode(_swapParams);
        IInfinityRouter.CLSwapExactOutputParams memory swapParams = decoder.decodeCLSwapExactOutParams(params);

        assertEq(Currency.unwrap(swapParams.currencyOut), Currency.unwrap(_swapParams.currencyOut));
        assertEq(swapParams.amountOut, _swapParams.amountOut);
        assertEq(swapParams.amountInMaximum, _swapParams.amountInMaximum);
        _assertEq(swapParams.path, _swapParams.path);
    }

    function test_decodeSwapExactOutParams_outOfBounds() public {
        PathKey[] memory path = new PathKey[](0);
        IInfinityRouter.CLSwapExactOutputParams memory _swapParams = ICLRouterBase.CLSwapExactOutputParams({
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
        decoder.decodeCLSwapExactOutParams(invalidParam);
    }

    function test_fuzz_decodeSwapExactOutSingleParams(
        IInfinityRouter.CLSwapExactOutputSingleParams calldata _swapParams
    ) public view {
        bytes memory params = abi.encode(_swapParams);
        IInfinityRouter.CLSwapExactOutputSingleParams memory swapParams =
            decoder.decodeCLSwapExactOutSingleParams(params);

        assertEq(swapParams.zeroForOne, _swapParams.zeroForOne);
        assertEq(swapParams.amountOut, _swapParams.amountOut);
        assertEq(swapParams.amountInMaximum, _swapParams.amountInMaximum);
        assertEq(swapParams.hookData, _swapParams.hookData);
        _assertEq(swapParams.poolKey, _swapParams.poolKey);
    }

    function test_fuzz_decodeIncreaseLiquidityFromAmountsParams(
        uint256 _tokenId,
        uint128 _amount0Max,
        uint128 _amount1Max,
        bytes calldata _hookData
    ) public view {
        bytes memory params = abi.encode(_tokenId, _amount0Max, _amount1Max, _hookData);

        (uint256 tokenId, uint128 amount0Max, uint128 amount1Max, bytes memory hookData) =
            decoder.decodeIncreaseLiquidityFromDeltasParams(params);
        assertEq(_tokenId, tokenId);
        assertEq(_amount0Max, amount0Max);
        assertEq(_amount1Max, amount1Max);
        assertEq(_hookData, hookData);
    }

    function test_fuzz_decodeSwapExactOutSingleParams_outOfBounds(PoolKey memory key) public {
        IInfinityRouter.CLSwapExactOutputSingleParams memory _swapParams = ICLRouterBase.CLSwapExactOutputSingleParams({
            poolKey: key, zeroForOne: true, amountOut: 1 ether, amountInMaximum: 1 ether, hookData: ""
        });

        /// @dev params.length is 384 as abi.encode adds 32 bytes for dynamic field. However ether.js doesn't add 32 bytes
        /// thus we need to remove 32 bytes from the end of the params
        /// ref: https://ethereum.stackexchange.com/questions/152971/abi-encode-decode-mystery-additional-32-byte-field-uniswap-v2
        bytes memory params = abi.encode(_swapParams);
        assertEq(params.length, 0x180);
        bytes memory invalidParam = _removeBytes(params, 32 + 1);
        assertEq(invalidParam.length, 0x160 - 1);

        vm.expectRevert(CalldataDecoder.SliceOutOfBounds.selector);
        decoder.decodeCLSwapExactOutSingleParams(invalidParam);
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
