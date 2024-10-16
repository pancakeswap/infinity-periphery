// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {PoolId} from "pancake-v4-core/src/types/PoolId.sol";

import {MockCLCalldataDecoder} from "../mocks/MockCLCalldataDecoder.sol";
import {IV4Router} from "../../../src/interfaces/IV4Router.sol";
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
        bytes memory params =
            abi.encode(_poolKey, _tickLower, _tickUpper, _liquidity, _amount0Max, _amount1Max, _owner, _hookData);
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

    function test_fuzz_decodeSwapExactInParams(IV4Router.CLSwapExactInputParams calldata _swapParams) public view {
        bytes memory params = abi.encode(_swapParams);
        IV4Router.CLSwapExactInputParams memory swapParams = decoder.decodeCLSwapExactInParams(params);

        assertEq(Currency.unwrap(swapParams.currencyIn), Currency.unwrap(_swapParams.currencyIn));
        assertEq(swapParams.amountIn, _swapParams.amountIn);
        assertEq(swapParams.amountOutMinimum, _swapParams.amountOutMinimum);
        _assertEq(swapParams.path, _swapParams.path);
    }

    function test_fuzz_decodeSwapExactInSingleParams(IV4Router.CLSwapExactInputSingleParams calldata _swapParams)
        public
        view
    {
        bytes memory params = abi.encode(_swapParams);
        IV4Router.CLSwapExactInputSingleParams memory swapParams = decoder.decodeCLSwapExactInSingleParams(params);

        assertEq(swapParams.zeroForOne, _swapParams.zeroForOne);
        assertEq(swapParams.amountIn, _swapParams.amountIn);
        assertEq(swapParams.amountOutMinimum, _swapParams.amountOutMinimum);
        assertEq(swapParams.hookData, _swapParams.hookData);
        _assertEq(swapParams.poolKey, _swapParams.poolKey);
    }

    function test_fuzz_decodeSwapExactOutParams(IV4Router.CLSwapExactOutputParams calldata _swapParams) public view {
        bytes memory params = abi.encode(_swapParams);
        IV4Router.CLSwapExactOutputParams memory swapParams = decoder.decodeCLSwapExactOutParams(params);

        assertEq(Currency.unwrap(swapParams.currencyOut), Currency.unwrap(_swapParams.currencyOut));
        assertEq(swapParams.amountOut, _swapParams.amountOut);
        assertEq(swapParams.amountInMaximum, _swapParams.amountInMaximum);
        _assertEq(swapParams.path, _swapParams.path);
    }

    function test_fuzz_decodeSwapExactOutSingleParams(IV4Router.CLSwapExactOutputSingleParams calldata _swapParams)
        public
        view
    {
        bytes memory params = abi.encode(_swapParams);
        IV4Router.CLSwapExactOutputSingleParams memory swapParams = decoder.decodeCLSwapExactOutSingleParams(params);

        assertEq(swapParams.zeroForOne, _swapParams.zeroForOne);
        assertEq(swapParams.amountOut, _swapParams.amountOut);
        assertEq(swapParams.amountInMaximum, _swapParams.amountInMaximum);
        assertEq(swapParams.hookData, _swapParams.hookData);
        _assertEq(swapParams.poolKey, _swapParams.poolKey);
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
}
