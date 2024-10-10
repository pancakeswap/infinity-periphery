// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity 0.8.26;

import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPosition} from "pancake-v4-core/src/pool-cl/libraries/CLPosition.sol";
import {SafeCast} from "pancake-v4-core/src/libraries/SafeCast.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {PoolId} from "pancake-v4-core/src/types/PoolId.sol";
import {IPositionManager} from "../interfaces/IPositionManager.sol";
import {BaseActionsRouter} from "../base/BaseActionsRouter.sol";
import {ReentrancyLock} from "../base/ReentrancyLock.sol";
import {DeltaResolver} from "../base/DeltaResolver.sol";
import {Permit2Forwarder} from "../base/Permit2Forwarder.sol";
import {ICLPositionManager} from "./interfaces/ICLPositionManager.sol";
import {CalldataDecoder} from "../libraries/CalldataDecoder.sol";
import {CLCalldataDecoder} from "./libraries/CLCalldataDecoder.sol";
import {Actions} from "../libraries/Actions.sol";
import {ERC721Permit_v4} from "./base/ERC721Permit_v4.sol";
import {SlippageCheck} from "../libraries/SlippageCheck.sol";
import {Multicall_v4} from "../base/Multicall_v4.sol";
import {CLNotifier} from "./base/CLNotifier.sol";
import {CLPositionInfo, CLPositionInfoLibrary} from "./libraries/CLPositionInfoLibrary.sol";
import {ICLSubscriber} from "./interfaces/ICLSubscriber.sol";

/// @title CLPositionManager
/// @notice Contract for modifying liquidity for PCS v4 CL pools
contract CLPositionManager is
    ICLPositionManager,
    ERC721Permit_v4,
    Multicall_v4,
    DeltaResolver,
    ReentrancyLock,
    BaseActionsRouter,
    CLNotifier,
    Permit2Forwarder
{
    using CalldataDecoder for bytes;
    using CLCalldataDecoder for bytes;
    using CLPositionInfoLibrary for CLPositionInfo;
    using SafeCast for uint256;
    using SlippageCheck for BalanceDelta;

    ICLPoolManager public immutable override clPoolManager;

    /// @inheritdoc ICLPositionManager
    /// @dev The ID of the next token that will be minted. Skips 0
    uint256 public nextTokenId = 1;

    mapping(uint256 tokenId => CLPositionInfo info) public positionInfo;
    mapping(bytes25 poolId => PoolKey poolKey) public poolKeys;

    constructor(IVault _vault, ICLPoolManager _clPoolManager, IAllowanceTransfer _permit2, uint256 _unsubscribeGasLimit)
        BaseActionsRouter(_vault)
        Permit2Forwarder(_permit2)
        ERC721Permit_v4("Pancakeswap V4 Positions NFT", "PCS-V4-POSM")
        CLNotifier(_unsubscribeGasLimit)
    {
        clPoolManager = _clPoolManager;
    }

    /// @dev <wip> might be refactored to BasePositionManager later
    /// @notice Reverts if the deadline has passed
    /// @param deadline The timestamp at which the call is no longer valid, passed in by the caller
    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlinePassed(deadline);
        _;
    }

    /// @notice Reverts if the caller is not the owner or approved for the ERC721 token
    /// @param caller The address of the caller
    /// @param tokenId the unique identifier of the ERC721 token
    /// @dev either msg.sender or msgSender() is passed in as the caller
    /// msgSender() should ONLY be used if this is being called from within the lockAcquired
    modifier onlyIfApproved(address caller, uint256 tokenId) override {
        if (!_isApprovedOrOwner(caller, tokenId)) revert NotApproved(caller);
        _;
    }

    /// @inheritdoc ICLPositionManager
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external payable override returns (int24) {
        return clPoolManager.initialize(key, sqrtPriceX96);
    }

    /// @inheritdoc IPositionManager
    function modifyLiquidities(bytes calldata payload, uint256 deadline)
        external
        payable
        override
        isNotLocked
        checkDeadline(deadline)
    {
        _executeActions(payload);
    }

    /// @inheritdoc IPositionManager
    function modifyLiquiditiesWithoutLock(bytes calldata actions, bytes[] calldata params)
        external
        payable
        override
        isNotLocked
    {
        _executeActionsWithoutLock(actions, params);
    }

    /// @inheritdoc BaseActionsRouter
    function msgSender() public view override returns (address) {
        return _getLocker();
    }

    function _handleAction(uint256 action, bytes calldata params) internal virtual override {
        if (action < Actions.CL_SWAP_EXACT_IN_SINGLE) {
            if (action == Actions.CL_INCREASE_LIQUIDITY) {
                (uint256 tokenId, uint256 liquidity, uint128 amount0Max, uint128 amount1Max, bytes calldata hookData) =
                    params.decodeCLModifyLiquidityParams();
                _increase(tokenId, liquidity, amount0Max, amount1Max, hookData);
                return;
            } else if (action == Actions.CL_DECREASE_LIQUIDITY) {
                (uint256 tokenId, uint256 liquidity, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData) =
                    params.decodeCLModifyLiquidityParams();
                _decrease(tokenId, liquidity, amount0Min, amount1Min, hookData);
                return;
            } else if (action == Actions.CL_MINT_POSITION) {
                (
                    PoolKey calldata poolKey,
                    int24 tickLower,
                    int24 tickUpper,
                    uint256 liquidity,
                    uint128 amount0Max,
                    uint128 amount1Max,
                    address owner,
                    bytes calldata hookData
                ) = params.decodeCLMintParams();
                _mint(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, _mapRecipient(owner), hookData);
                return;
            } else if (action == Actions.CL_BURN_POSITION) {
                // Will automatically decrease liquidity to 0 if the position is not already empty.
                (uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData) =
                    params.decodeCLBurnParams();
                _burn(tokenId, amount0Min, amount1Min, hookData);
                return;
            }
        } else {
            if (action == Actions.SETTLE_PAIR) {
                (Currency currency0, Currency currency1) = params.decodeCurrencyPair();
                _settlePair(currency0, currency1);
                return;
            } else if (action == Actions.TAKE_PAIR) {
                (Currency currency0, Currency currency1, address recipient) = params.decodeCurrencyPairAndAddress();
                _takePair(currency0, currency1, _mapRecipient(recipient));
                return;
            } else if (action == Actions.SETTLE) {
                (Currency currency, uint256 amount, bool payerIsUser) = params.decodeCurrencyUint256AndBool();
                _settle(currency, _mapPayer(payerIsUser), _mapSettleAmount(amount, currency));
                return;
            } else if (action == Actions.TAKE) {
                (Currency currency, address recipient, uint256 amount) = params.decodeCurrencyAddressAndUint256();
                _take(currency, _mapRecipient(recipient), _mapTakeAmount(amount, currency));
                return;
            } else if (action == Actions.CLOSE_CURRENCY) {
                Currency currency = params.decodeCurrency();
                _close(currency);
                return;
            } else if (action == Actions.CLEAR_OR_TAKE) {
                (Currency currency, uint256 amountMax) = params.decodeCurrencyAndUint256();
                _clearOrTake(currency, amountMax);
                return;
            } else if (action == Actions.SWEEP) {
                (Currency currency, address to) = params.decodeCurrencyAndAddress();
                _sweep(currency, _mapRecipient(to));
                return;
            }
        }
        revert UnsupportedAction(action);
    }

    /// @dev Calling increase with 0 liquidity will credit the caller with any underlying fees of the position
    function _increase(
        uint256 tokenId,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        bytes calldata hookData
    ) internal onlyIfApproved(msgSender(), tokenId) {
        (PoolKey memory poolKey, CLPositionInfo info) = getPoolAndPositionInfo(tokenId);

        // Note: The tokenId is used as the salt for this position, so every minted position has unique storage in the pool manager.
        (BalanceDelta liquidityDelta, BalanceDelta feesAccrued) =
            _modifyLiquidity(info, poolKey, liquidity.toInt256(), bytes32(tokenId), hookData);
        // Slippage checks should be done on the principal liquidityDelta which is the liquidityDelta - feesAccrued
        (liquidityDelta - feesAccrued).validateMaxIn(amount0Max, amount1Max);
    }

    /// @dev Calling decrease with 0 liquidity will credit the caller with any underlying fees of the position
    function _decrease(
        uint256 tokenId,
        uint256 liquidity,
        uint128 amount0Min,
        uint128 amount1Min,
        bytes calldata hookData
    ) internal onlyIfApproved(msgSender(), tokenId) {
        (PoolKey memory poolKey, CLPositionInfo info) = getPoolAndPositionInfo(tokenId);

        // Note: the tokenId is used as the salt.
        (BalanceDelta liquidityDelta, BalanceDelta feesAccrued) =
            _modifyLiquidity(info, poolKey, -(liquidity.toInt256()), bytes32(tokenId), hookData);

        // Slippage checks should be done on the principal liquidityDelta which is the liquidityDelta - feesAccrued
        (liquidityDelta - feesAccrued).validateMinOut(amount0Min, amount1Min);
    }

    function _mint(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        address owner,
        bytes calldata hookData
    ) internal {
        // mint receipt token
        uint256 tokenId;
        // tokenId is assigned to current nextTokenId before incrementing it
        unchecked {
            tokenId = nextTokenId++;
        }
        _mint(owner, tokenId);

        // Initialize the position info
        CLPositionInfo info = CLPositionInfoLibrary.initialize(poolKey, tickLower, tickUpper);
        positionInfo[tokenId] = info;

        // Store the poolKey if it is not already stored.
        // if parameter (hook permission and tickSpacing) is bytes(0), it means the pool is not initialized yet
        bytes25 poolId = info.poolId();
        if (poolKeys[poolId].parameters == bytes32(0)) {
            poolKeys[poolId] = poolKey;
        }

        // fee delta can be ignored as this is a new position
        (BalanceDelta liquidityDelta,) =
            _modifyLiquidity(info, poolKey, liquidity.toInt256(), bytes32(tokenId), hookData);
        liquidityDelta.validateMaxIn(amount0Max, amount1Max);

        emit MintPosition(tokenId);
    }

    /// @dev this is overloaded with ERC721Permit_v4._burn
    function _burn(uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData)
        internal
        onlyIfApproved(msgSender(), tokenId)
    {
        (PoolKey memory poolKey, CLPositionInfo info) = getPoolAndPositionInfo(tokenId);

        uint256 liquidity = uint256(_getLiquidity(tokenId, poolKey, info.tickLower(), info.tickUpper()));

        // Clear the position info.
        positionInfo[tokenId] = CLPositionInfoLibrary.EMPTY_POSITION_INFO;
        // Burn the token.
        _burn(tokenId);

        // Can only call modify if there is non zero liquidity.
        if (liquidity > 0) {
            (BalanceDelta liquidityDelta, BalanceDelta feesAccrued) =
                _modifyLiquidity(info, poolKey, -(liquidity.toInt256()), bytes32(tokenId), hookData);
            // Slippage checks should be done on the principal liquidityDelta which is the liquidityDelta - feesAccrued
            (liquidityDelta - feesAccrued).validateMinOut(amount0Min, amount1Min);
        }

        if (info.hasSubscriber()) _unsubscribe(tokenId);
    }

    function _settlePair(Currency currency0, Currency currency1) internal {
        // the locker is the payer when settling
        address caller = msgSender();
        _settle(currency0, caller, _getFullDebt(currency0));
        _settle(currency1, caller, _getFullDebt(currency1));
    }

    function _takePair(Currency currency0, Currency currency1, address recipient) internal {
        _take(currency0, recipient, _getFullCredit(currency0));
        _take(currency1, recipient, _getFullCredit(currency1));
    }

    function _close(Currency currency) internal {
        // this address has applied all deltas on behalf of the user/owner
        // it is safe to close this entire delta because of slippage checks throughout the batched calls.
        int256 currencyDelta = vault.currencyDelta(address(this), currency);

        // the locker is the payer or receiver
        address caller = msgSender();
        if (currencyDelta < 0) {
            _settle(currency, caller, uint256(-currencyDelta));
        } else if (currencyDelta > 0) {
            _take(currency, caller, uint256(currencyDelta));
        }
    }

    /// @dev integrators may elect to forfeit positive deltas with clear
    /// if the forfeit amount exceeds the user-specified max, the amount is taken instead
    function _clearOrTake(Currency currency, uint256 amountMax) internal {
        uint256 delta = _getFullCredit(currency);

        // forfeit the delta if its less than or equal to the user-specified limit
        if (delta <= amountMax) {
            vault.clear(currency, delta);
        } else {
            _take(currency, msgSender(), delta);
        }
    }

    /// @notice Sweeps the entire contract balance of specified currency to the recipient
    function _sweep(Currency currency, address to) internal {
        uint256 balance = currency.balanceOfSelf();
        if (balance > 0) currency.transfer(to, balance);
    }

    function _modifyLiquidity(
        CLPositionInfo info,
        PoolKey memory poolKey,
        int256 liquidityChange,
        bytes32 salt,
        bytes calldata hookData
    ) internal returns (BalanceDelta liquidityDelta, BalanceDelta feesAccrued) {
        (liquidityDelta, feesAccrued) = clPoolManager.modifyLiquidity(
            poolKey,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: info.tickLower(),
                tickUpper: info.tickUpper(),
                liquidityDelta: liquidityChange,
                salt: salt
            }),
            hookData
        );

        uint256 tokenId = uint256(salt);
        emit ModifyLiquidity(tokenId, liquidityChange, feesAccrued);

        if (info.hasSubscriber()) {
            _notifyModifyLiquidity(tokenId, liquidityChange, feesAccrued);
        }
    }

    function _pay(Currency currency, address payer, uint256 amount) internal override(DeltaResolver) {
        if (payer == address(this)) {
            currency.transfer(address(vault), amount);
        } else {
            permit2.transferFrom(payer, address(vault), uint160(amount), Currency.unwrap(currency));
        }
    }

    /// @notice an internal helper used by CLNotifier
    function _setSubscribed(uint256 tokenId) internal override {
        positionInfo[tokenId] = positionInfo[tokenId].setSubscribe();
    }

    /// @notice an internal helper used by CLNotifier
    function _setUnsubscribed(uint256 tokenId) internal override {
        positionInfo[tokenId] = positionInfo[tokenId].setUnsubscribe();
    }

    /// @dev overrides solmate transferFrom in case a notification to subscribers is needed
    function transferFrom(address from, address to, uint256 id) public virtual override {
        super.transferFrom(from, to, id);
        if (positionInfo[id].hasSubscriber()) _notifyTransfer(id, from, to);
    }

    /// @inheritdoc ICLPositionManager
    function getPoolAndPositionInfo(uint256 tokenId)
        public
        view
        returns (PoolKey memory poolKey, CLPositionInfo info)
    {
        info = positionInfo[tokenId];
        poolKey = poolKeys[info.poolId()];
    }

    /// @inheritdoc ICLPositionManager
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity) {
        (PoolKey memory poolKey, CLPositionInfo info) = getPoolAndPositionInfo(tokenId);
        return _getLiquidity(tokenId, poolKey, info.tickLower(), info.tickUpper());
    }

    /// @inheritdoc ICLPositionManager
    function positions(uint256 tokenId)
        external
        view
        returns (
            PoolKey memory poolKey,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            ICLSubscriber _subscriber
        )
    {
        CLPositionInfo info;
        (poolKey, info) = getPoolAndPositionInfo(tokenId);
        PoolId poolId = poolKey.toId();
        if (CLPositionInfo.unwrap(info) == 0) revert InvalidTokenID();
        tickLower = info.tickLower();
        tickUpper = info.tickUpper();

        CLPosition.Info memory position =
            clPoolManager.getPosition(poolId, address(this), tickLower, tickUpper, bytes32(tokenId));

        liquidity = position.liquidity;
        feeGrowthInside0LastX128 = position.feeGrowthInside0LastX128;
        feeGrowthInside1LastX128 = position.feeGrowthInside1LastX128;
        _subscriber = subscriber[tokenId];
    }

    function _getLiquidity(uint256 tokenId, PoolKey memory poolKey, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint128 liquidity)
    {
        CLPosition.Info memory position =
            clPoolManager.getPosition(poolKey.toId(), address(this), tickLower, tickUpper, bytes32(tokenId));

        liquidity = position.liquidity;
    }
}
