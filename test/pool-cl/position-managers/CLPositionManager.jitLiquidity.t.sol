// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";

import {PosmTestSetup} from "../shared/PosmTestSetup.sol";

/// @notice End-to-end regression for infinity-core's mid-lock `reservesOfApp` fix, exercised through
/// the position manager: a hook mints a just-in-time position in `beforeSwap` and burns it in
/// `afterSwap` via modifyLiquiditiesWithoutLock, on a pool with NO other liquidity.
///
/// The afterSwap burn withdraws the swap input before the pool manager books it, which used to
/// revert with an arithmetic underflow and now settles through a transient app deficit.
contract CLPositionManagerJitLiquidityTest is Test, PosmTestSetup {
    using CLPoolParametersHelper for bytes32;
    using PoolIdLibrary for PoolKey;

    int24 constant TICK_LOWER = -120;
    int24 constant TICK_UPPER = 120;
    uint256 constant JIT_LIQUIDITY = 1000e18;

    IVault vault;
    ICLPoolManager manager;

    PoolKey key;
    PoolId poolId;

    function setUp() public {
        (currency0, currency1) = deployCurrencies(2 ** 255);

        (vault, manager) = createFreshManager();
        deployAndApproveRouter(vault, manager);
        deployAndApprovePosm(vault, manager);

        // must deploy after posm
        deployPosmHookJitLiquidity(vault);

        key = PoolKey(
            currency0,
            currency1,
            IHooks(address(hookJitLiquidity)),
            manager,
            3000,
            bytes32(uint256(hookJitLiquidity.getHooksRegistrationBitmap())).setTickSpacing(10)
        );
        poolId = key.toId();
        manager.initialize(key, SQRT_RATIO_1_1);

        // the hook funds its own JIT positions. Part of its inventory is parked in the vault as
        // claim tokens so the vault holds enough ERC20 for the afterSwap burn to take the swap input
        // back out before the trader has transferred it in
        seedBalance(address(hookJitLiquidity));
        hookJitLiquidity.depositClaims(currency0, currency1, 100 ether, 100 ether);

        // posm resolves the tokenId's pool key off-chain because the position does not exist yet
        // when the burn payload is encoded
        _latestPoolKey = key;
    }

    /// @dev The pool holds ONLY the hook's just-in-time liquidity, so the afterSwap burn takes the
    /// swap input back out of the pool manager before the swap itself has booked it.
    function test_jit_mintBeforeSwap_burnAfterSwap() public {
        uint256 jitTokenId = _refreshJitCalls();

        swap(key, true, -1 ether, ZERO_BYTES);

        // the deficit path was actually exercised: right after the burn the pool manager's reserves
        // were transiently overdrawn on the input currency only
        assertGt(hookJitLiquidity.deficitAfterBurn0(), 0, "burn overdraws the swap-input currency mid-lock");
        assertEq(hookJitLiquidity.deficitAfterBurn1(), 0, "output currency reserve never overdraws");

        // fully repaid once the swap's own delta was booked, so the lock was allowed to close
        assertEq(vault.getAppDeficitCount(), 0, "deficit fully repaid by the swap's own booking");
        assertEq(vault.appCurrencyDeficit(address(manager), currency0), 0);
        assertEq(vault.appCurrencyDeficit(address(manager), currency1), 0);

        // posm burnt the position: the ERC721 is gone and the pool is back to no liquidity
        assertEq(lpm.getPositionLiquidity(jitTokenId), 0);
        vm.expectRevert();
        lpm.ownerOf(jitTokenId);
        assertEq(manager.getLiquidity(poolId), 0);

        // only mint/burn rounding dust is left behind in the app's reserves
        assertLe(vault.reservesOfApp(address(manager), currency0), 10, "only rounding dust remains");
        assertLe(vault.reservesOfApp(address(manager), currency1), 10, "only rounding dust remains");
    }

    /// @dev Same flow in both directions, repeated: every swap overdraws and repays, none revert.
    function test_jit_mintBeforeSwap_burnAfterSwap_repeated() public {
        for (uint256 i; i < 3; ++i) {
            _refreshJitCalls();
            swap(key, true, -1 ether, ZERO_BYTES);
            assertGt(hookJitLiquidity.deficitAfterBurn0(), 0);
            assertEq(hookJitLiquidity.deficitAfterBurn1(), 0);
            assertEq(vault.getAppDeficitCount(), 0);

            _refreshJitCalls();
            swap(key, false, -1 ether, ZERO_BYTES);
            assertEq(hookJitLiquidity.deficitAfterBurn0(), 0);
            assertGt(hookJitLiquidity.deficitAfterBurn1(), 0);
            assertEq(vault.getAppDeficitCount(), 0);
        }
    }

    /// @dev point the hook at the tokenId its next mint will receive
    function _refreshJitCalls() internal returns (uint256 jitTokenId) {
        jitTokenId = lpm.nextTokenId();
        hookJitLiquidity.setJitCalls(
            getMintEncoded(key, TICK_LOWER, TICK_UPPER, JIT_LIQUIDITY, address(hookJitLiquidity), ZERO_BYTES),
            getBurnEncoded(jitTokenId, ZERO_BYTES)
        );
    }
}
