// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IQuoter} from "../../interfaces/IQuoter.sol";

/// @title ICLQuoter Interface
/// @notice Supports quoting the delta amounts for exact input or exact output swaps.
/// @notice For each pool also tells you the estimation of gas cost for the swap.
/// @dev These functions are not marked view because they rely on calling non-view functions and reverting
/// to compute the result. They are also not gas efficient and should not be called on-chain.
interface ICLQuoter is IQuoter {
    /// @notice Returns the delta amounts for a given exact input swap of a single pool
    /// @param params The params for the quote, encoded as `QuoteExactSingleParams`
    /// poolKey The key for identifying a infinity pool
    /// zeroForOne If the swap is from currency0 to currency1
    /// exactAmount The desired input amount
    /// hookData arbitrary hookData to pass into the associated hooks
    /// @return amountOut The output quote for the exactIn swap
    /// @return gasEstimate Estimated gas units used for the swap
    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);

    /// @notice Returns the last swap delta amounts for a given exact input in a list of swap
    /// @param params The params for the quote, encoded as `QuoteExactSingleParams[]`
    /// poolKey The key for identifying a infinity pool
    /// zeroForOne If the swap is from currency0 to currency1
    /// exactAmount The desired input amount
    /// hookData arbitrary hookData to pass into the associated hooks
    /// @return amountOut The last swap output quote for the exactIn swap
    /// @return gasEstimate Estimated gas units used for the swap
    function quoteExactInputSingleList(QuoteExactSingleParams[] memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);

    /// @notice Returns the delta amounts along the swap path for a given exact input swap
    /// @param params the params for the quote, encoded as 'QuoteExactParams'
    /// currencyIn The input currency of the swap
    /// path The path of the swap encoded as PathKeys that contains currency, fee, tickSpacing, and hook info
    /// exactAmount The desired input amount
    /// @return amountOut The output quote for the exactIn swap
    /// @return gasEstimate Estimated gas units used for the swap
    function quoteExactInput(QuoteExactParams memory params) external returns (uint256 amountOut, uint256 gasEstimate);

    /// @notice Returns the delta amounts for a given exact output swap of a single pool
    /// @param params The params for the quote, encoded as `QuoteExactSingleParams`
    /// poolKey The key for identifying a infinity pool
    /// zeroForOne If the swap is from currency0 to currency1
    /// exactAmount The desired output amount
    /// hookData arbitrary hookData to pass into the associated hooks
    /// @return amountIn The input quote for the exactOut swap
    /// @return gasEstimate Estimated gas units used for the swap
    function quoteExactOutputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountIn, uint256 gasEstimate);

    /// @notice Returns the delta amounts along the swap path for a given exact output swap
    /// @param params the params for the quote, encoded as 'QuoteExactParams'
    /// currencyOut The output currency of the swap
    /// path The path of the swap encoded as PathKeys that contains currency, fee, tickSpacing, and hook info
    /// exactAmount The desired output amount
    /// @return amountIn The input quote for the exactOut swap
    /// @return gasEstimate Estimated gas units used for the swap
    function quoteExactOutput(QuoteExactParams memory params) external returns (uint256 amountIn, uint256 gasEstimate);
}
