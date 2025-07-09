// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.24;

import {ParseBytes} from "infinity-core/src/libraries/ParseBytes.sol";

library QuoterRevert {
    using QuoterRevert for bytes;
    using ParseBytes for bytes;

    /// @notice error thrown when invalid revert bytes are thrown by the quote
    error UnexpectedRevertBytes(bytes revertData);

    /// @notice Error thrown containing the quote amount and sqrtPrice as the data, to be caught and parsed later
    error QuoteSwap(uint256 quoteAmount, uint256 sqrtPrice);

    /// @notice Reverts with the provided quoteAmount and sqrtPrice as revert data
    /// @dev Called when quoting, to record the quote amount and sqrtPrice in an error
    /// @dev QuoteSwap is used to differentiate this error from other errors thrown when simulating the swap
    function revertQuote(uint256 quoteAmount, uint256 sqrtPrice) internal pure {
        revert QuoteSwap(quoteAmount, sqrtPrice);
    }

    /// @notice reverts using the revertData as the reason
    /// @dev to bubble up both the valid QuoteSwap(amount) error, or an alternative error thrown during simulation
    function bubbleReason(bytes memory revertData) internal pure {
        // mload(revertData): the length of the revert data
        // add(revertData, 0x20): a pointer to the start of the revert data
        assembly ("memory-safe") {
            revert(add(revertData, 0x20), mload(revertData))
        }
    }

    /// @notice Validates whether a revert reason is a valid swap quote and extracts the quoteAmount and sqrtPrice
    /// @dev If valid, it decodes and returns both values; otherwise, it reverts
    function parseQuoteData(bytes memory reason) internal pure returns (uint256 quoteAmount, uint256 sqrtPrice) {
        // Check if the error starts with the QuoteSwap selector
        if (reason.parseSelector() != QuoteSwap.selector) {
            revert UnexpectedRevertBytes(reason);
        }

        // reason -> reason+0x1f: length of the reason bytes
        // reason+0x20 -> reason+0x23: selector of QuoteSwap
        // reason+0x24 -> reason+0x43: quoteAmount (32 bytes)
        // reason+0x44 -> reason+0x63: sqrtPrice (32 bytes)
        assembly ("memory-safe") {
            quoteAmount := mload(add(reason, 0x24))
            sqrtPrice := mload(add(reason, 0x44))
        }
    }
}
