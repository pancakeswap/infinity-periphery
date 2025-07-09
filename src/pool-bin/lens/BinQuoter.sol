// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity 0.8.26;

import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {SafeCast} from "infinity-core/src/pool-bin/libraries/math/SafeCast.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {IBinQuoter} from "../interfaces/IBinQuoter.sol";
import {PathKey, PathKeyLibrary} from "../../libraries/PathKey.sol";
import {BaseInfinityQuoter} from "../../base/BaseInfinityQuoter.sol";
import {QuoterRevert} from "../../libraries/QuoterRevert.sol";

contract BinQuoter is BaseInfinityQuoter, IBinQuoter {
    using QuoterRevert for *;
    using SafeCast for uint128;

    IBinPoolManager public immutable poolManager;

    constructor(address _poolManager) BaseInfinityQuoter(_poolManager) {
        poolManager = IBinPoolManager(_poolManager);
    }

    /// @inheritdoc IBinQuoter
    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        override
        returns (uint256 amountOut, uint256 gasEstimate)
    {
        uint256 gasBefore = gasleft();
        try vault.lock(abi.encodeCall(this._quoteExactInputSingle, (params))) {}
        catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            // Extract the quote from QuoteSwap error, or throw if the quote failed
            (amountOut,) = reason.parseQuoteData();
        }
    }

    /// @inheritdoc IBinQuoter
    function quoteExactInputSingleList(QuoteExactSingleParams[] memory params)
        external
        returns (uint256 amountIn, uint256 gasEstimate)
    {
        uint256 gasBefore = gasleft();
        try vault.lock(abi.encodeCall(this._quoteExactInputSingleList, (params))) {}
        catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            // Extract the quote from QuoteSwap error, or throw if the quote failed
            (amountIn,) = reason.parseQuoteData();
        }
    }

    /// @inheritdoc IBinQuoter
    function quoteExactInput(QuoteExactParams memory params)
        external
        override
        returns (uint256 amountOut, uint256 gasEstimate)
    {
        uint256 gasBefore = gasleft();
        try vault.lock(abi.encodeCall(this._quoteExactInput, (params))) {}
        catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            // Extract the quote from QuoteSwap error, or throw if the quote failed
            (amountOut,) = reason.parseQuoteData();
        }
    }

    /// @inheritdoc IBinQuoter
    function quoteExactOutputSingle(QuoteExactSingleParams memory params)
        external
        override
        returns (uint256 amountIn, uint256 gasEstimate)
    {
        uint256 gasBefore = gasleft();
        try vault.lock(abi.encodeCall(this._quoteExactOutputSingle, (params))) {}
        catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            // Extract the quote from QuoteSwap error, or throw if the quote failed
            (amountIn,) = reason.parseQuoteData();
        }
    }

    /// @inheritdoc IBinQuoter
    function quoteExactOutput(QuoteExactParams memory params)
        external
        override
        returns (uint256 amountIn, uint256 gasEstimate)
    {
        uint256 gasBefore = gasleft();
        try vault.lock(abi.encodeCall(this._quoteExactOutput, (params))) {}
        catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            // Extract the quote from QuoteSwap error, or throw if the quote failed
            (amountIn,) = reason.parseQuoteData();
        }
    }

    /// @dev quote an ExactInput swap along a path of tokens, then revert with the result
    function _quoteExactInput(QuoteExactParams calldata params) external selfOnly returns (bytes memory) {
        uint256 pathLength = params.path.length;
        BalanceDelta swapDelta;
        uint128 amountIn = params.exactAmount;
        Currency inputCurrency = params.exactCurrency;
        PathKey calldata pathKey;

        for (uint256 i = 0; i < pathLength; i++) {
            pathKey = params.path[i];
            (PoolKey memory poolKey, bool zeroForOne) = pathKey.getPoolAndSwapDirection(inputCurrency);

            swapDelta = _swap(poolKey, zeroForOne, -amountIn.safeInt128(), pathKey.hookData);

            amountIn = zeroForOne ? uint128(swapDelta.amount1()) : uint128(swapDelta.amount0());
            inputCurrency = pathKey.intermediateCurrency;
        }
        // amountIn after the loop actually holds the amountOut of the trade
        amountIn.revertQuote(0);
    }

    /// @dev quote an ExactInput swap on a pool, then revert with the result
    function _quoteExactInputSingle(QuoteExactSingleParams calldata params) external selfOnly returns (bytes memory) {
        BalanceDelta swapDelta =
            _swap(params.poolKey, params.zeroForOne, -(params.exactAmount.safeInt128()), params.hookData);

        // the output delta of a swap is positive
        uint256 amountOut = params.zeroForOne ? uint128(swapDelta.amount1()) : uint128(swapDelta.amount0());
        amountOut.revertQuote(0);
    }

    /// @dev quote ExactInput swap list on a pool, then revert with the result of last swap
    function _quoteExactInputSingleList(QuoteExactSingleParams[] calldata swapParamList)
        external
        selfOnly
        returns (bytes memory)
    {
        uint256 swapLength = swapParamList.length;
        if (swapLength == 0) revert();
        uint256 amountOut;
        for (uint256 i = 0; i < swapLength; i++) {
            QuoteExactSingleParams memory params = swapParamList[i];
            BalanceDelta swapDelta =
                _swap(params.poolKey, params.zeroForOne, -(params.exactAmount.safeInt128()), params.hookData);
            if (i == swapLength - 1) {
                // the output delta of a swap is positive
                amountOut = params.zeroForOne ? uint128(swapDelta.amount1()) : uint128(swapDelta.amount0());
            }
        }
        amountOut.revertQuote(0);
    }

    /// @dev quote an ExactOutput swap along a path of tokens, then revert with the result
    function _quoteExactOutput(QuoteExactParams calldata params) external selfOnly returns (bytes memory) {
        uint256 pathLength = params.path.length;
        BalanceDelta swapDelta;
        uint128 amountOut = params.exactAmount;
        Currency outputCurrency = params.exactCurrency;
        PathKey calldata pathKey;

        for (uint256 i = pathLength; i > 0; i--) {
            pathKey = params.path[i - 1];
            (PoolKey memory poolKey, bool oneForZero) = pathKey.getPoolAndSwapDirection(outputCurrency);

            swapDelta = _swap(poolKey, !oneForZero, amountOut.safeInt128(), pathKey.hookData);

            amountOut = oneForZero ? uint128(-swapDelta.amount1()) : uint128(-swapDelta.amount0());
            outputCurrency = pathKey.intermediateCurrency;
        }
        // amountOut after the loop exits actually holds the amountIn of the trade
        amountOut.revertQuote(0);
    }

    /// @dev quote an ExactOutput swap on a pool, then revert with the result
    function _quoteExactOutputSingle(QuoteExactSingleParams calldata params) external selfOnly returns (bytes memory) {
        BalanceDelta swapDelta =
            _swap(params.poolKey, params.zeroForOne, params.exactAmount.safeInt128(), params.hookData);

        // the input delta of a swap is negative so we must flip it
        uint256 amountIn = params.zeroForOne ? uint128(-swapDelta.amount0()) : uint128(-swapDelta.amount1());
        amountIn.revertQuote(0);
    }

    /// @dev Execute a swap and return the balance delta
    /// @notice if amountSpecified < 0, the swap is exactInput, otherwise exactOutput
    function _swap(PoolKey memory poolKey, bool zeroForOne, int128 amountSpecified, bytes memory hookData)
        private
        returns (BalanceDelta deltas)
    {
        deltas = poolManager.swap(poolKey, zeroForOne, amountSpecified, hookData);

        /// @dev Check that the pool was not illiquid
        /// even BinPool will emit BinPool__OutOfLiquidity when the pool is illiquid
        /// We still need to apply the check in case hook contract manipulates the delta
        int128 amountSpecifiedActual = (zeroForOne == (amountSpecified < 0)) ? deltas.amount0() : deltas.amount1();
        if (amountSpecifiedActual != amountSpecified) {
            revert NotEnoughLiquidity(poolKey.toId());
        }
    }
}
