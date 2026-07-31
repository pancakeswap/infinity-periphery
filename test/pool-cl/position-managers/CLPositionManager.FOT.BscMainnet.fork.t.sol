// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {CLPositionManager} from "../../../src/pool-cl/CLPositionManager.sol";
import {LiquidityAmounts} from "../../../src/pool-cl/libraries/LiquidityAmounts.sol";
import {Actions} from "../../../src/libraries/Actions.sol";
import {ActionConstants} from "../../../src/libraries/ActionConstants.sol";
import {Planner, Plan} from "../../../src/libraries/Planner.sol";

/// @notice BSC mainnet fork test: add liquidity with a fee-on-transfer (FOT) token through the
/// already-deployed CLPositionManager, using the same "measure, don't predict" pattern as the
/// FOT-aware swap adapter (see docs/Adapting Fee-on-Transfer Token Swaps In Infinity.md):
///
///   1. SETTLE the gross amount first — the Vault credits only the after-tax net amount it
///      actually received (`vault.settle()` measures the real balance increment);
///   2. CL_MINT_POSITION_FROM_DELTAS / CL_INCREASE_LIQUIDITY_FROM_DELTAS derive the liquidity
///      from the measured open deltas, so the order size always matches what arrived;
///   3. CLOSE_CURRENCY refunds whatever the mint did not consume.
///
/// The token under test is MarsCoin (a `FlapTaxTokenV3`), a real FOT token on BSC:
/// `taxRate() == 300` (3%) on transfers sent to any address registered in its `pools(address)`
/// registry, and the Infinity Vault IS registered — so every transfer into the Vault only
/// delivers 97% of the nominal amount.
contract CLPositionManagerFOTBscMainnetForkTest is Test {
    using Planner for Plan;
    using CurrencyLibrary for Currency;

    // PancakeSwap Infinity on BSC (script/config/bsc-mainnet.json)
    IVault constant VAULT = IVault(0x238a358808379702088667322f80aC48bAd5e6c4);
    ICLPoolManager constant CL_POOL_MANAGER = ICLPoolManager(0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b);
    CLPositionManager constant LPM = CLPositionManager(payable(0x55f4c8abA71A1e923edC303eb4fEfF14608cC226));
    IAllowanceTransfer constant PERMIT2 = IAllowanceTransfer(0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768);

    // MarsCoin, a FlapTaxTokenV3 taxing 3% on transfers to registered pools (incl. the Vault)
    IERC20 constant MARS = IERC20(0xFe189E97832DA1573e4e4Ff034F4fFC3a15c7777);

    // sqrt(1) * 2^96, i.e. price 1:1
    uint160 constant SQRT_RATIO_1_1 = 79228162514264337593543950336;

    int24 constant TICK_LOWER = -600;
    int24 constant TICK_UPPER = 600;

    bytes constant ZERO_BYTES = bytes("");

    // NOTE: do not use common names like makeAddr("alice") on a mainnet fork — their private
    // keys are publicly known (keccak256 of the label) and sweeper bots have installed EIP-7702
    // delegations on them on BSC, silently forwarding any native refund out of the account
    address alice = makeAddr("infinity-fot-fork-lp");

    PoolKey poolKey;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BSC_FORK_URL", string("https://bsc-rpc.publicnode.com")), 113009000);

        // sanity: MarsCoin really taxes transfers to the Infinity Vault
        (, bytes memory taxRateData) = address(MARS).staticcall(abi.encodeWithSignature("taxRate()"));
        assertEq(abi.decode(taxRateData, (uint256)), 300, "MarsCoin tax rate changed");
        (, bytes memory isPoolData) = address(MARS).staticcall(abi.encodeWithSignature("pools(address)", address(VAULT)));
        assertTrue(abi.decode(isPoolData, (bool)), "Infinity Vault not registered as taxed pool");

        // create a fresh BNB/MARS CL pool on the real CLPoolManager via the real position manager
        poolKey = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: Currency.wrap(address(MARS)),
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(CL_POOL_MANAGER)),
            fee: 3000,
            parameters: CLPoolParametersHelper.setTickSpacing(bytes32(0), 60)
        });
        LPM.initializePool(poolKey, SQRT_RATIO_1_1);

        // fund alice and set up the standard permit2 allowance chain for the position manager
        vm.etch(alice, ""); // drop any code (e.g. a 7702 delegation) the address has on mainnet
        vm.deal(alice, 1_000 ether);
        deal(address(MARS), alice, 1_000e18);
        vm.startPrank(alice);
        MARS.approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(address(MARS), address(LPM), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    /// @notice the naive flow (mint with the nominal amount, settle the resulting debt) can never
    /// zero the MARS delta: settling `debt` only delivers `0.97 * debt` to the Vault
    function test_mint_naive_revertsCurrencyNotSettled() public {
        uint256 amount = 100e18;
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_RATIO_1_1,
            TickMath.getSqrtRatioAtTick(TICK_LOWER),
            TickMath.getSqrtRatioAtTick(TICK_UPPER),
            amount,
            amount
        );

        Plan memory planner = Planner.init();
        planner.add(
            Actions.CL_MINT_POSITION,
            abi.encode(
                poolKey,
                TICK_LOWER,
                TICK_UPPER,
                liquidity,
                type(uint128).max,
                type(uint128).max,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        planner.add(Actions.CLOSE_CURRENCY, abi.encode(poolKey.currency0));
        planner.add(Actions.CLOSE_CURRENCY, abi.encode(poolKey.currency1));
        bytes memory plan = planner.encode();

        vm.startPrank(alice);
        vm.expectRevert(IVault.CurrencyNotSettled.selector);
        LPM.modifyLiquidities{value: amount}(plan, block.timestamp + 60);
        vm.stopPrank();
    }

    /// @notice FOT-aware mint: settle the gross first, mint from the measured deltas.
    /// BNB side is sized to the (probe-measured) after-tax MARS so both sides are fully consumed.
    function test_mintFromDeltas_fot() public {
        uint256 grossMars = 100e18;
        uint256 netMars = _measureNetTransferToVault(grossMars);
        // MarsCoin taxes 3%: only 97 MARS actually reaches the Vault
        assertEq(netMars, grossMars * 9700 / 10000);
        uint256 bnbAmount = netMars;

        uint128 expectedLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_RATIO_1_1,
            TickMath.getSqrtRatioAtTick(TICK_LOWER),
            TickMath.getSqrtRatioAtTick(TICK_UPPER),
            bnbAmount, // currency0 = BNB net (no tax)
            netMars // currency1 = MARS net (after tax)
        );

        uint256 tokenId = LPM.nextTokenId();
        uint256 aliceMarsBefore = MARS.balanceOf(alice);
        uint256 aliceBnbBefore = alice.balance;
        uint256 vaultMarsBefore = MARS.balanceOf(address(VAULT));

        vm.startPrank(alice);
        LPM.modifyLiquidities{value: bnbAmount}(_fotMintPlan(grossMars, bnbAmount), block.timestamp + 60);
        vm.stopPrank();

        // position minted to alice, sized by the measured net amounts
        assertEq(LPM.ownerOf(tokenId), alice);
        assertEq(LPM.getPositionLiquidity(tokenId), expectedLiquidity);

        // alice paid the full nominal amounts (up to rounding dust refunded by CLOSE_CURRENCY)
        assertApproxEqAbs(aliceMarsBefore - MARS.balanceOf(alice), grossMars, 2);
        assertApproxEqAbs(aliceBnbBefore - alice.balance, bnbAmount, 2);

        // the Vault received exactly the after-tax amount, and the mint consumed all of it
        assertApproxEqAbs(MARS.balanceOf(address(VAULT)) - vaultMarsBefore, netMars, 2);

        // nothing is stuck in the position manager
        assertEq(MARS.balanceOf(address(LPM)), 0);
        assertEq(address(LPM).balance, 0);
    }

    /// @notice when the settled amounts do not match the pool ratio after tax (here: 3% excess
    /// BNB), the mint is bound by the smaller side and CLOSE_CURRENCY refunds the leftover
    function test_mintFromDeltas_fot_refundsLeftover() public {
        uint256 grossMars = 100e18;
        uint256 netMars = _measureNetTransferToVault(grossMars);
        // send BNB 1:1 with the *gross* MARS: after the 3% tax the BNB side is oversupplied
        uint256 bnbAmount = grossMars;

        uint128 expectedLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_RATIO_1_1,
            TickMath.getSqrtRatioAtTick(TICK_LOWER),
            TickMath.getSqrtRatioAtTick(TICK_UPPER),
            bnbAmount,
            netMars
        );

        uint256 tokenId = LPM.nextTokenId();
        uint256 aliceBnbBefore = alice.balance;

        vm.startPrank(alice);
        LPM.modifyLiquidities{value: bnbAmount}(_fotMintPlan(grossMars, bnbAmount), block.timestamp + 60);
        vm.stopPrank();

        assertEq(LPM.ownerOf(tokenId), alice);
        assertEq(LPM.getPositionLiquidity(tokenId), expectedLiquidity);

        // liquidity is bound by the after-tax MARS; the surplus BNB comes back via CLOSE_CURRENCY
        uint256 bnbSpent = aliceBnbBefore - alice.balance;
        assertLt(bnbSpent, bnbAmount);
        assertApproxEqAbs(bnbSpent, netMars, 1e15); // ~= net side, small tick-range asymmetry only

        assertEq(MARS.balanceOf(address(LPM)), 0);
        assertEq(address(LPM).balance, 0);
    }

    /// @notice FOT-aware increase on an existing position: settle gross, increase from deltas
    function test_increaseFromDeltas_fot() public {
        // mint the initial position with the FOT-aware flow
        uint256 grossMars = 100e18;
        uint256 netMars = _measureNetTransferToVault(grossMars);
        uint256 tokenId = LPM.nextTokenId();
        vm.startPrank(alice);
        LPM.modifyLiquidities{value: netMars}(_fotMintPlan(grossMars, netMars), block.timestamp + 60);
        vm.stopPrank();
        uint128 liquidityBefore = LPM.getPositionLiquidity(tokenId);

        // increase with another gross 50 MARS (net 48.5) + matching BNB
        uint256 grossMars2 = 50e18;
        uint256 netMars2 = _measureNetTransferToVault(grossMars2);
        uint256 bnbAmount2 = netMars2;

        uint128 expectedAddedLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_RATIO_1_1, // no swaps in this test, price has not moved
            TickMath.getSqrtRatioAtTick(TICK_LOWER),
            TickMath.getSqrtRatioAtTick(TICK_UPPER),
            bnbAmount2,
            netMars2
        );

        Plan memory planner = Planner.init();
        planner.add(Actions.SETTLE, abi.encode(CurrencyLibrary.NATIVE, bnbAmount2, false));
        planner.add(Actions.SETTLE, abi.encode(Currency.wrap(address(MARS)), grossMars2, true));
        planner.add(
            Actions.CL_INCREASE_LIQUIDITY_FROM_DELTAS,
            abi.encode(tokenId, type(uint128).max, type(uint128).max, ZERO_BYTES)
        );
        planner.add(Actions.CLOSE_CURRENCY, abi.encode(poolKey.currency0));
        planner.add(Actions.CLOSE_CURRENCY, abi.encode(poolKey.currency1));
        bytes memory plan = planner.encode();

        vm.startPrank(alice);
        LPM.modifyLiquidities{value: bnbAmount2}(plan, block.timestamp + 60);
        vm.stopPrank();

        assertEq(LPM.getPositionLiquidity(tokenId), liquidityBefore + expectedAddedLiquidity);
        assertEq(MARS.balanceOf(address(LPM)), 0);
        assertEq(address(LPM).balance, 0);
    }

    /// @notice removing liquidity needs NO special settlement handling: the Vault is the payer,
    /// `take` books the nominal amount at the moment of the call, and any transfer loss happens
    /// AFTER the accounting — the deltas always zero out and nothing reverts.
    ///
    /// HOWEVER (measured on this fork): MarsCoin taxes transfers FROM registered pools too, so
    /// the user receives 3% less than what the vault paid. This is the token's own rule — no
    /// contract trick can avoid it; quoting/slippage display must use the after-tax amount.
    function test_decreaseAndTake_standardFlow() public {
        // mint with the FOT-aware flow first
        uint256 grossMars = 100e18;
        uint256 netMars = _measureNetTransferToVault(grossMars);
        // measure the OUTBOUND tax as well (spends part of the probe donation above)
        uint256 outNetPerEther = _measureNetTransferFromVault(1 ether);
        uint256 tokenId = LPM.nextTokenId();
        vm.startPrank(alice);
        LPM.modifyLiquidities{value: netMars}(_fotMintPlan(grossMars, netMars), block.timestamp + 60);
        vm.stopPrank();
        uint128 liquidity = LPM.getPositionLiquidity(tokenId);

        // remove everything with the completely STANDARD flow — no settle-first tricks
        Plan memory planner = Planner.init();
        planner.add(Actions.CL_DECREASE_LIQUIDITY, abi.encode(tokenId, uint256(liquidity), 0, 0, ZERO_BYTES));
        planner.add(Actions.TAKE_PAIR, abi.encode(poolKey.currency0, poolKey.currency1, ActionConstants.MSG_SENDER));
        bytes memory plan = planner.encode();

        uint256 aliceMarsBefore = MARS.balanceOf(alice);
        uint256 aliceBnbBefore = alice.balance;
        uint256 vaultMarsBefore = MARS.balanceOf(address(VAULT));

        vm.startPrank(alice);
        LPM.modifyLiquidities(plan, block.timestamp + 60);
        vm.stopPrank();

        uint256 aliceMarsReceived = MARS.balanceOf(alice) - aliceMarsBefore;
        uint256 vaultMarsPaid = vaultMarsBefore - MARS.balanceOf(address(VAULT));

        // the vault pays out the full nominal principal — the accounting is untouched by FOT
        assertApproxEqAbs(vaultMarsPaid, netMars, 2);
        assertApproxEqAbs(alice.balance - aliceBnbBefore, netMars, 2);

        // ...but MarsCoin taxes the way OUT of the vault too: alice receives the after-tax net
        assertLt(aliceMarsReceived, vaultMarsPaid);
        assertApproxEqAbs(aliceMarsReceived, vaultMarsPaid * outNetPerEther / 1 ether, 2);

        assertEq(LPM.getPositionLiquidity(tokenId), 0);
        assertEq(MARS.balanceOf(address(LPM)), 0);
        assertEq(address(LPM).balance, 0);
    }

    /// @dev SETTLE gross → mint from measured deltas → refund whatever was not consumed
    function _fotMintPlan(uint256 grossMars, uint256 bnbAmount) internal view returns (bytes memory) {
        Plan memory planner = Planner.init();
        planner.add(Actions.SETTLE, abi.encode(CurrencyLibrary.NATIVE, bnbAmount, false));
        planner.add(Actions.SETTLE, abi.encode(Currency.wrap(address(MARS)), grossMars, true));
        planner.add(
            Actions.CL_MINT_POSITION_FROM_DELTAS,
            abi.encode(
                poolKey,
                TICK_LOWER,
                TICK_UPPER,
                type(uint128).max,
                type(uint128).max,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        planner.add(Actions.CLOSE_CURRENCY, abi.encode(poolKey.currency0));
        planner.add(Actions.CLOSE_CURRENCY, abi.encode(poolKey.currency1));
        return planner.encode();
    }

    /// @dev measure the OUTBOUND tax by transferring part of the probe donation back out of the
    /// Vault; the donation is untracked surplus, so vault solvency and pool state are unaffected
    function _measureNetTransferFromVault(uint256 amount) internal returns (uint256 net) {
        address probe = makeAddr("infinity-fot-fork-out-probe");
        vm.prank(address(VAULT));
        MARS.transfer(probe, amount);
        net = MARS.balanceOf(probe);
    }

    /// @dev measure the effective after-tax amount with a probe transfer instead of hardcoding
    /// the 3% rate: a plain donation to the Vault does not affect pool state (settle always
    /// sync()s first) and mirrors exactly what the Vault receives during the real settle
    function _measureNetTransferToVault(uint256 amount) internal returns (uint256 net) {
        address probe = makeAddr("probe");
        deal(address(MARS), probe, amount);
        uint256 vaultBalanceBefore = MARS.balanceOf(address(VAULT));
        vm.prank(probe);
        MARS.transfer(address(VAULT), amount);
        net = MARS.balanceOf(address(VAULT)) - vaultBalanceBefore;
    }
}
