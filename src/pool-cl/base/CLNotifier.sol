// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.0;

import {ICLSubscriber} from "../interfaces/ICLSubscriber.sol";
import {ICLNotifier} from "../interfaces/ICLNotifier.sol";
import {CLPositionInfo} from "../libraries/CLPositionInfoLibrary.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";

/// @notice Notifier is used to opt in to sending updates to external contracts about position modifications or transfers
abstract contract CLNotifier is ICLNotifier {
    using CustomRevert for address;

    ICLSubscriber private constant NO_SUBSCRIBER = ICLSubscriber(address(0));

    /// @inheritdoc ICLNotifier
    uint256 public immutable unsubscribeGasLimit;

    /// @inheritdoc ICLNotifier
    mapping(uint256 tokenId => ICLSubscriber subscriber) public subscriber;

    constructor(uint256 _unsubscribeGasLimit) {
        unsubscribeGasLimit = _unsubscribeGasLimit;
    }

    /// @notice Only allow callers that are approved as spenders or operators of the tokenId
    /// @dev to be implemented by the parent contract (CLPositionManager)
    /// @param caller the address of the caller
    /// @param tokenId the tokenId of the position
    modifier onlyIfApproved(address caller, uint256 tokenId) virtual;

    /// @notice Enforces that the Vault is unlocked.
    modifier onlyIfVaultUnlocked() virtual;

    function _setUnsubscribed(uint256 tokenId) internal virtual;
    function _setSubscribed(uint256 tokenId) internal virtual;

    /// @inheritdoc ICLNotifier
    function subscribe(uint256 tokenId, address newSubscriber, bytes calldata data)
        external
        payable
        onlyIfVaultUnlocked
        onlyIfApproved(msg.sender, tokenId)
    {
        ICLSubscriber _subscriber = subscriber[tokenId];

        if (_subscriber != NO_SUBSCRIBER) revert AlreadySubscribed(tokenId, address(_subscriber));
        _setSubscribed(tokenId);

        subscriber[tokenId] = ICLSubscriber(newSubscriber);

        bool success = _call(newSubscriber, abi.encodeCall(ICLSubscriber.notifySubscribe, (tokenId, data)));

        if (!success) {
            newSubscriber.bubbleUpAndRevertWith(ICLSubscriber.notifySubscribe.selector, SubscriptionReverted.selector);
        }

        emit Subscription(tokenId, newSubscriber);
    }

    /// @inheritdoc ICLNotifier
    function unsubscribe(uint256 tokenId) external payable onlyIfVaultUnlocked onlyIfApproved(msg.sender, tokenId) {
        _unsubscribe(tokenId);
    }

    function _unsubscribe(uint256 tokenId) internal {
        ICLSubscriber _subscriber = subscriber[tokenId];
        if (_subscriber == NO_SUBSCRIBER) revert NotSubscribed();
        _setUnsubscribed(tokenId);

        delete subscriber[tokenId];

        if (address(_subscriber).code.length > 0) {
            // require that the remaining gas is sufficient to notify the subscriber
            // otherwise, users can select a gas limit where .notifyUnsubscribe hits OutOfGas yet the
            // transaction/unsubscription can still succeed
            if (gasleft() < unsubscribeGasLimit) revert GasLimitTooLow();
            try _subscriber.notifyUnsubscribe{gas: unsubscribeGasLimit}(tokenId) {} catch {}
        }

        emit Unsubscription(tokenId, address(_subscriber));
    }

    /// @dev note this function also deletes the subscriber address from the mapping
    function _removeSubscriberAndNotifyBurn(
        uint256 tokenId,
        address owner,
        CLPositionInfo info,
        uint256 liquidity,
        BalanceDelta feesAccrued
    ) internal {
        address _subscriber = address(subscriber[tokenId]);

        // remove the subscriber
        delete subscriber[tokenId];

        bool success = _call(
            _subscriber, abi.encodeCall(ICLSubscriber.notifyBurn, (tokenId, owner, info, liquidity, feesAccrued))
        );

        if (!success) {
            _subscriber.bubbleUpAndRevertWith(ICLSubscriber.notifyBurn.selector, BurnNotificationReverted.selector);
        }
    }

    function _notifyModifyLiquidity(uint256 tokenId, int256 liquidityChange, BalanceDelta feesAccrued) internal {
        address _subscriber = address(subscriber[tokenId]);

        bool success = _call(
            _subscriber, abi.encodeCall(ICLSubscriber.notifyModifyLiquidity, (tokenId, liquidityChange, feesAccrued))
        );

        if (!success) {
            _subscriber.bubbleUpAndRevertWith(
                ICLSubscriber.notifyModifyLiquidity.selector, ModifyLiquidityNotificationReverted.selector
            );
        }
    }

    function _call(address target, bytes memory encodedCall) internal returns (bool success) {
        if (target.code.length == 0) revert NoCodeSubscriber();
        assembly ("memory-safe") {
            success := call(gas(), target, 0, add(encodedCall, 0x20), mload(encodedCall), 0, 0)
        }
    }
}
