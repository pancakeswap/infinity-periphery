// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "infinity-core/src/types/BeforeSwapDelta.sol";
import {BaseCLTestHook} from "infinity-core/test/pool-cl/helpers/BaseCLTestHook.sol";
import {CurrencySettlement} from "infinity-core/test/helpers/CurrencySettlement.sol";

import {ICLPositionManager} from "../../../src/pool-cl/interfaces/ICLPositionManager.sol";

/// @notice This contract is NOT a production use contract. It is a just-in-time liquidity hook which
/// mints a position through the position manager in `beforeSwap` and burns it again in `afterSwap`,
/// both via IPositionManager.modifyLiquiditiesWithoutLock.
/// @dev The `afterSwap` burn runs BEFORE the pool manager books the swap's own delta to
/// `reservesOfApp`, so on the swap-input currency the position manager withdraws more than is
/// currently booked. infinity-core used to revert with an arithmetic underflow here; it now records a
/// transient deficit which the swap's own booking repays before the lock is released.
contract HookJitLiquidity is BaseCLTestHook, ILockCallback {
    using CurrencySettlement for Currency;

    IVault vault;
    ICLPositionManager posm;
    IAllowanceTransfer permit2;

    /// @dev encoded (bytes actions, bytes[] params) payloads, set by the test
    bytes mintCalls;
    bytes burnCalls;

    /// @dev the pool manager's transient deficit observed right after the afterSwap burn, recorded
    /// so tests can assert the deficit path was actually exercised
    uint256 public deficitAfterBurn0;
    uint256 public deficitAfterBurn1;

    function setAddresses(IVault _vault, ICLPositionManager _posm, IAllowanceTransfer _permit2) external {
        vault = _vault;
        posm = _posm;
        permit2 = _permit2;
    }

    function setJitCalls(bytes calldata _mintCalls, bytes calldata _burnCalls) external {
        mintCalls = _mintCalls;
        burnCalls = _burnCalls;
    }

    /// @notice Turn `amount0`/`amount1` of the hook's ERC20 balance into vault claim tokens. The
    /// claims leave the vault holding the underlying ERC20, which is what lets the afterSwap burn
    /// take the swap input out of the vault before the trader has transferred it in.
    function depositClaims(Currency currency0, Currency currency1, uint256 amount0, uint256 amount1) external {
        vault.lock(abi.encode(currency0, currency1, amount0, amount1));
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        (Currency currency0, Currency currency1, uint256 amount0, uint256 amount1) =
            abi.decode(data, (Currency, Currency, uint256, uint256));
        currency0.settle(vault, address(this), amount0, false);
        currency0.take(vault, address(this), amount0, true);
        currency1.settle(vault, address(this), amount1, false);
        currency1.take(vault, address(this), amount1, true);
        return "";
    }

    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return _hooksRegistrationBitmapFrom(
            Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                befreSwapReturnsDelta: false,
                afterSwapReturnsDelta: false,
                afterAddLiquidityReturnsDelta: false,
                afterRemoveLiquidityReturnsDelta: false
            })
        );
    }

    function beforeSwap(address, PoolKey calldata key, ICLPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        approvePosmCurrency(key.currency0);
        approvePosmCurrency(key.currency1);

        _modifyLiquidities(mintCalls);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address, PoolKey calldata key, ICLPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        override
        returns (bytes4, int128)
    {
        _modifyLiquidities(burnCalls);

        // the burn ran before the swap's own delta was booked: on the swap-input currency the pool
        // manager's reserves are transiently overdrawn -- snapshot the deficit for the test
        deficitAfterBurn0 = vault.appCurrencyDeficit(address(key.poolManager), key.currency0);
        deficitAfterBurn1 = vault.appCurrencyDeficit(address(key.poolManager), key.currency1);

        return (this.afterSwap.selector, 0);
    }

    function _modifyLiquidities(bytes memory calls) internal {
        (bytes memory actions, bytes[] memory params) = abi.decode(calls, (bytes, bytes[]));
        posm.modifyLiquiditiesWithoutLock(actions, params);
    }

    function approvePosmCurrency(Currency currency) internal {
        if (currency.isNative()) return;

        // Because POSM uses permit2, we must execute 2 permits/approvals.
        // 1. First, the caller must approve permit2 on the token.
        IERC20(Currency.unwrap(currency)).approve(address(permit2), type(uint256).max);
        // 2. Then, the caller must approve POSM as a spender of permit2.
        permit2.approve(Currency.unwrap(currency), address(posm), type(uint160).max, type(uint48).max);
    }
}
