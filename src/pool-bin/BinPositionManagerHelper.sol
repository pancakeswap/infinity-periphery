// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";

import {IBinPositionManager} from "./interfaces/IBinPositionManager.sol";
import {IBinPositionManagerWithERC1155} from "./interfaces/IBinPositionManagerWithERC1155.sol";
import {IWETH9} from "../interfaces/external/IWETH9.sol";
import {Actions} from "../libraries/Actions.sol";
import {BinCalldataDecoder} from "./libraries/BinCalldataDecoder.sol";
import {CalldataDecoder} from "../libraries/CalldataDecoder.sol";
import {BinTokenLibrary} from "./libraries/BinTokenLibrary.sol";
import {Multicall} from "../base/Multicall.sol";
import {Permit2Forwarder} from "../base/Permit2Forwarder.sol";
import {ReentrancyLock} from "../base/ReentrancyLock.sol";

/// @title BinPositionManagerHelper
/// @notice Helper contract for adding liquidity to bin pool with additional slippage protection
contract BinPositionManagerHelper is Multicall, Permit2Forwarder, ReentrancyLock {
    using CalldataDecoder for bytes;
    using BinCalldataDecoder for bytes;
    using BinTokenLibrary for PoolId;

    /// @notice Thrown when an unexpected address sends ETH to this contract
    error InvalidEthSender();
    /// @notice Thrown when theres multiple BIN_ADD_LIQUIDITY actions
    error DuplicateAddLiquidity();
    /// @notice Thrown when there's unsupported action in the payload
    error UnsupportedAction();
    /// @notice Thrown when no BIN_ADD_LIQUIDITY action is found in the payload
    error NoAddLiquidityAction();
    /// @notice Thrown when minLiquidityParam's binIds and minLiquidities length mismatch
    error MinLiquidityParamsLengthMismatch();
    /// @notice Thrown when slippage checks fail
    error SlippageCheck(uint24 binId, uint256 liquidityAdded);
    /// @notice Thrown when invalid (duplicate or non accending) binIds are found in minLiquidityParam
    error InvalidBinId(uint24 binid);

    struct MinLiquidityParams {
        /// @dev expect accending order of binIds eg. [20, 21, 22]
        uint24[] binIds;
        uint256[] minLiquidities;
    }

    IBinPoolManager public immutable binPoolManager;
    IBinPositionManagerWithERC1155 public immutable binPositionManager;
    IWETH9 public immutable WETH9;

    constructor(
        IBinPoolManager _binPoolManager,
        IBinPositionManagerWithERC1155 _binPositionManager,
        IAllowanceTransfer _permit2,
        IWETH9 _weth9
    ) Permit2Forwarder(_permit2) {
        binPoolManager = _binPoolManager;
        binPositionManager = _binPositionManager;
        permit2 = _permit2;
        WETH9 = _weth9;
    }

    /// @notice Add liquidities to bin pool with slippage protection
    /// @param payload - encoded actions and parameters for bin position manager
    /// @param deadline - deadline for the transaction
    /// @param minLiquidityParam - amount of [binId, liquidity] to mint
    /// @dev This function only support 1 BIN_ADD_LIQUIDITY call
    function addLiquidities(bytes calldata payload, uint256 deadline, MinLiquidityParams memory minLiquidityParam)
        external
        payable
        isNotLocked
    {
        if (minLiquidityParam.binIds.length != minLiquidityParam.minLiquidities.length) {
            revert MinLiquidityParamsLengthMismatch();
        }

        // Step 1: decode payload
        IBinPositionManager.BinAddLiquidityParams memory liquidityParams = _getAddLiquidityParam(payload);
        Currency currency0 = liquidityParams.poolKey.currency0;
        Currency currency1 = liquidityParams.poolKey.currency1;

        // Step 2: Transfer token from user and permit2 approve so BinPositionManager can take the tokens later
        if (!currency0.isNative()) {
            // for native case, do not need to check msg.value, as binPositionManager will revert
            permit2.transferFrom(msg.sender, address(this), liquidityParams.amount0Max, Currency.unwrap(currency0));
            _approveBinPm(currency0, liquidityParams.amount0Max);
        }
        permit2.transferFrom(msg.sender, address(this), liquidityParams.amount1Max, Currency.unwrap(currency1));
        _approveBinPm(currency1, liquidityParams.amount1Max);

        // Step 3a: Before Check user balance before
        address[] memory owners = new address[](minLiquidityParam.binIds.length);
        uint256[] memory tokenIds = new uint256[](minLiquidityParam.binIds.length);
        PoolId poolId = liquidityParams.poolKey.toId();
        uint24 tempBinId = 0; // check duplicate binId
        for (uint256 i = 0; i < minLiquidityParam.binIds.length; i++) {
            owners[i] = liquidityParams.to;
            // Sanity check -- eg. assume binId is accending order, so this will check duplicate as well
            if (tempBinId >= minLiquidityParam.binIds[i]) revert InvalidBinId(minLiquidityParam.binIds[i]);
            tempBinId = minLiquidityParam.binIds[i];
            tokenIds[i] = poolId.toTokenId(tempBinId);
        }
        uint256[] memory balBefore = binPositionManager.balanceOfBatch(owners, tokenIds);

        // Step 3b: modify liquidities
        binPositionManager.modifyLiquidities{value: msg.value}(payload, deadline);

        // Step 3c: Check user balance after
        uint256[] memory balAfter = binPositionManager.balanceOfBatch(owners, tokenIds);
        for (uint256 i = 0; i < minLiquidityParam.minLiquidities.length; i++) {
            uint256 liquidityAdded = balAfter[i] - balBefore[i];
            if (liquidityAdded < minLiquidityParam.minLiquidities[i]) {
                revert SlippageCheck(minLiquidityParam.binIds[i], liquidityAdded);
            }
        }

        // Step 4: refund the user of any balance t0, t1 in contract
        if (currency0.balanceOfSelf() > 0) {
            currency0.transfer(msg.sender, currency0.balanceOfSelf());
        }
        if (currency1.balanceOfSelf() > 0) {
            currency1.transfer(msg.sender, currency1.balanceOfSelf());
        }
    }

    /// @notice Initialize a infinity PCS bin pool
    /// @dev For a new pool, user will use multiCall[initializePool, addLiquidities], implementation copied from BinPositionManager
    function initializePool(PoolKey memory key, uint24 activeId) external payable {
        /// @dev if the pool revert due to other error (currencyOutOfOrder etc..), then the follow-up action to the pool will still revert accordingly
        try binPoolManager.initialize(key, activeId) {} catch {}
    }

    /// @notice Approve the bin position manager to spend the currency
    /// @dev assume currency is not native
    function _approveBinPm(Currency _currency, uint160 _amount) internal {
        IERC20(Currency.unwrap(_currency)).approve(address(permit2), _amount);
        permit2.approve(Currency.unwrap(_currency), address(binPositionManager), _amount, uint48(block.timestamp));
    }

    function _getAddLiquidityParam(bytes calldata payload)
        internal
        pure
        returns (IBinPositionManager.BinAddLiquidityParams memory liquidityParams)
    {
        (bytes calldata actions, bytes[] calldata params) = payload.decodeActionsRouterParams();
        uint256 numActions = actions.length;
        for (uint256 actionIndex = 0; actionIndex < numActions; actionIndex++) {
            uint256 action = uint8(actions[actionIndex]);

            if (action == Actions.BIN_ADD_LIQUIDITY) {
                if (liquidityParams.activeIdDesired != 0) revert DuplicateAddLiquidity();
                liquidityParams = params[actionIndex].decodeBinAddLiquidityParams();
            }

            // FE won't call BIN_ADD_LIQUIDITY_FROM_DELTAS
            if (action == Actions.BIN_ADD_LIQUIDITY_FROM_DELTAS || action == Actions.BIN_REMOVE_LIQUIDITY) {
                revert UnsupportedAction();
            }
        }

        if (liquidityParams.activeIdDesired == 0) {
            revert NoAddLiquidityAction();
        }

        return liquidityParams;
    }

    receive() external payable {
        if (msg.sender != address(WETH9) && msg.sender != address(binPositionManager)) revert InvalidEthSender();
    }
}
