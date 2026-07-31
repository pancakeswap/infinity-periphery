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

/// @notice BSC mainnet fork test: add liquidity with an xStock (rebasing-multiplier) token
/// through the already-deployed CLPositionManager, using the same "measure, don't predict"
/// pattern verified for fee-on-transfer tokens in CLPositionManager.FOT.BscMainnet.fork.t.sol.
///
/// The token under test is NVIDIA xStock (NVDAx, `0xc845...849d`), a Backed-style token that
/// stores balances as underlying shares and computes `balanceOf = shares * multiplier / 1e18`.
/// A transfer converts amount -> shares -> amount with two floor divisions, so the recipient
/// usually receives **1 wei less** than the nominal amount:
///
///   - the naive flow (mint with the nominal-amount liquidity, settle the exact debt after)
///     leaves the NVDAx delta 1 wei short -> `CurrencyNotSettled` revert;
///   - the FOT-aware flow (SETTLE the gross first, mint FROM_DELTAS with the measured credit)
///     absorbs the 1 wei deficiency automatically — both cases are just "sent != received",
///     only the magnitude differs (1 wei here vs 3% for a transfer-tax token).
contract CLPositionManagerXStockBscMainnetForkTest is Test {
    using Planner for Plan;
    using CurrencyLibrary for Currency;

    // PancakeSwap Infinity on BSC (script/config/bsc-mainnet.json)
    IVault constant VAULT = IVault(0x238a358808379702088667322f80aC48bAd5e6c4);
    ICLPoolManager constant CL_POOL_MANAGER = ICLPoolManager(0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b);
    CLPositionManager constant LPM = CLPositionManager(payable(0x55f4c8abA71A1e923edC303eb4fEfF14608cC226));
    IAllowanceTransfer constant PERMIT2 = IAllowanceTransfer(0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768);

    // NVIDIA xStock: balances are shares scaled by a non-1e18 multiplier, transfers round down
    IERC20 constant NVDAX = IERC20(0xc845b2894dBddd03858fd2D643B4eF725fE0849d);

    // sqrt(1) * 2^96, i.e. price 1:1
    uint160 constant SQRT_RATIO_1_1 = 79228162514264337593543950336;

    int24 constant TICK_LOWER = -600;
    int24 constant TICK_UPPER = 600;

    bytes constant ZERO_BYTES = bytes("");

    // NOTE: do not use common names like makeAddr("alice") on a mainnet fork — their private
    // keys are publicly known (keccak256 of the label) and sweeper bots have installed EIP-7702
    // delegations on them on BSC, silently forwarding any native refund out of the account
    address alice = makeAddr("infinity-xstock-fork-lp");

    PoolKey poolKey;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BSC_FORK_URL", string("https://bsc-mainnet.public.blastapi.io")), 113009000);

        // sanity: NVDAx really is a rebasing-multiplier token (multiplier != 1e18)
        (, bytes memory multiplierData) = address(NVDAX).staticcall(abi.encodeWithSignature("multiplier()"));
        assertTrue(abi.decode(multiplierData, (uint256)) != 1e18, "NVDAx multiplier is exactly 1e18");

        // create a fresh BNB/NVDAx CL pool on the real CLPoolManager via the real position manager
        poolKey = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: Currency.wrap(address(NVDAX)),
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(CL_POOL_MANAGER)),
            fee: 3000,
            parameters: CLPoolParametersHelper.setTickSpacing(bytes32(0), 60)
        });
        LPM.initializePool(poolKey, SQRT_RATIO_1_1);

        // fund alice and set up the standard permit2 allowance chain for the position manager
        vm.etch(alice, ""); // drop any code (e.g. a 7702 delegation) the address has on mainnet
        vm.deal(alice, 1_000 ether);
        _mintNVDAx(alice, 100e18);
        vm.startPrank(alice);
        NVDAX.approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(address(NVDAX), address(LPM), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    /// @notice documents the root cause: an NVDAx transfer delivers less than the nominal
    /// amount because of the shares <-> amount floor-division round trip
    function test_nvdaxTransferLosesPrecision() public {
        uint256 amount = 10e18;
        uint256 net = _measureNetTransferToVault(amount);

        // the recipient receives less than the nominal amount (typically 1 wei short)
        assertLt(net, amount);
        // ...but the deficiency is tiny: precision loss, not a transfer tax
        assertGt(net, amount - 1000);
    }

    /// @notice the naive flow (mint with the nominal-amount liquidity, settle the exact debt
    /// after) can never zero the NVDAx delta: settling `debt` delivers `debt - 1` to the Vault
    function test_mint_naive_revertsCurrencyNotSettled() public {
        uint256 amount = 10e18;
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
    /// The 1 wei transfer loss is absorbed without the contract knowing it exists.
    function test_mintFromDeltas_xstock() public {
        uint256 grossNvdax = 10e18;
        uint256 netNvdax = _measureNetTransferToVault(grossNvdax);
        assertLt(netNvdax, grossNvdax);
        uint256 bnbAmount = netNvdax;

        uint128 expectedLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_RATIO_1_1,
            TickMath.getSqrtRatioAtTick(TICK_LOWER),
            TickMath.getSqrtRatioAtTick(TICK_UPPER),
            bnbAmount, // currency0 = BNB net (no loss)
            netNvdax // currency1 = NVDAx net (after the rounding loss)
        );

        uint256 tokenId = LPM.nextTokenId();
        uint256 aliceNvdaxBefore = NVDAX.balanceOf(alice);
        uint256 aliceBnbBefore = alice.balance;
        uint256 vaultNvdaxBefore = NVDAX.balanceOf(address(VAULT));

        vm.startPrank(alice);
        LPM.modifyLiquidities{value: bnbAmount}(_fotMintPlan(grossNvdax, bnbAmount), block.timestamp + 60);
        vm.stopPrank();

        // position minted to alice, sized by the measured net amounts
        assertEq(LPM.ownerOf(tokenId), alice);
        assertEq(LPM.getPositionLiquidity(tokenId), expectedLiquidity);

        // alice paid the nominal amounts (her own balance may shed extra weis from the token's
        // share accounting and the CLOSE_CURRENCY dust refund, hence approximate)
        assertApproxEqAbs(aliceNvdaxBefore - NVDAX.balanceOf(alice), grossNvdax, 10);
        assertApproxEqAbs(aliceBnbBefore - alice.balance, bnbAmount, 2);

        // the Vault received the measured net, and the mint consumed all of it (minus dust)
        assertApproxEqAbs(NVDAX.balanceOf(address(VAULT)) - vaultNvdaxBefore, netNvdax, 2);

        // nothing is stuck in the position manager
        assertEq(NVDAX.balanceOf(address(LPM)), 0);
        assertEq(address(LPM).balance, 0);
    }

    /// @notice FOT-aware increase on an existing position: settle gross, increase from deltas
    function test_increaseFromDeltas_xstock() public {
        // mint the initial position with the FOT-aware flow
        uint256 grossNvdax = 10e18;
        uint256 netNvdax = _measureNetTransferToVault(grossNvdax);
        uint256 tokenId = LPM.nextTokenId();
        vm.startPrank(alice);
        LPM.modifyLiquidities{value: netNvdax}(_fotMintPlan(grossNvdax, netNvdax), block.timestamp + 60);
        vm.stopPrank();
        uint128 liquidityBefore = LPM.getPositionLiquidity(tokenId);

        // increase with another gross 5 NVDAx + matching BNB
        uint256 grossNvdax2 = 5e18;
        uint256 netNvdax2 = _measureNetTransferToVault(grossNvdax2);
        uint256 bnbAmount2 = netNvdax2;

        uint128 expectedAddedLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_RATIO_1_1, // no swaps in this test, price has not moved
            TickMath.getSqrtRatioAtTick(TICK_LOWER),
            TickMath.getSqrtRatioAtTick(TICK_UPPER),
            bnbAmount2,
            netNvdax2
        );

        Plan memory planner = Planner.init();
        planner.add(Actions.SETTLE, abi.encode(CurrencyLibrary.NATIVE, bnbAmount2, false));
        planner.add(Actions.SETTLE, abi.encode(Currency.wrap(address(NVDAX)), grossNvdax2, true));
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
        assertEq(NVDAX.balanceOf(address(LPM)), 0);
        assertEq(address(LPM).balance, 0);
    }

    /// @notice removing liquidity needs NO special handling: the Vault is the payer, `take`
    /// books the nominal amount at the moment of the call, and the shares-rounding loss happens
    /// AFTER the accounting — the deltas always zero out. The user's received amount may be a
    /// wei short of what the vault paid (the token's rounding), which is a display concern only.
    function test_decreaseAndTake_standardFlow() public {
        // mint with the FOT-aware flow first
        uint256 grossNvdax = 10e18;
        uint256 netNvdax = _measureNetTransferToVault(grossNvdax);
        uint256 tokenId = LPM.nextTokenId();
        vm.startPrank(alice);
        LPM.modifyLiquidities{value: netNvdax}(_fotMintPlan(grossNvdax, netNvdax), block.timestamp + 60);
        vm.stopPrank();
        uint128 liquidity = LPM.getPositionLiquidity(tokenId);

        // remove everything with the completely STANDARD flow — no settle-first tricks
        Plan memory planner = Planner.init();
        planner.add(Actions.CL_DECREASE_LIQUIDITY, abi.encode(tokenId, uint256(liquidity), 0, 0, ZERO_BYTES));
        planner.add(Actions.TAKE_PAIR, abi.encode(poolKey.currency0, poolKey.currency1, ActionConstants.MSG_SENDER));
        bytes memory plan = planner.encode();

        uint256 aliceNvdaxBefore = NVDAX.balanceOf(alice);
        uint256 aliceBnbBefore = alice.balance;
        uint256 vaultNvdaxBefore = NVDAX.balanceOf(address(VAULT));

        vm.startPrank(alice);
        LPM.modifyLiquidities(plan, block.timestamp + 60);
        vm.stopPrank();

        uint256 aliceNvdaxReceived = NVDAX.balanceOf(alice) - aliceNvdaxBefore;
        uint256 vaultNvdaxPaid = vaultNvdaxBefore - NVDAX.balanceOf(address(VAULT));

        // the full principal comes back (minus core rounding and the token's wei-level loss)
        assertApproxEqAbs(aliceNvdaxReceived, netNvdax, 4);
        assertApproxEqAbs(alice.balance - aliceBnbBefore, netNvdax, 2);

        // the rounding loss (if any) is paid by the recipient, never by the vault's accounting
        assertLe(aliceNvdaxReceived, vaultNvdaxPaid);
        assertApproxEqAbs(aliceNvdaxReceived, vaultNvdaxPaid, 2);

        assertEq(LPM.getPositionLiquidity(tokenId), 0);
        assertEq(NVDAX.balanceOf(address(LPM)), 0);
        assertEq(address(LPM).balance, 0);
    }

    /// @dev SETTLE gross → mint from measured deltas → refund whatever was not consumed
    function _fotMintPlan(uint256 grossNvdax, uint256 bnbAmount) internal view returns (bytes memory) {
        Plan memory planner = Planner.init();
        planner.add(Actions.SETTLE, abi.encode(CurrencyLibrary.NATIVE, bnbAmount, false));
        planner.add(Actions.SETTLE, abi.encode(Currency.wrap(address(NVDAX)), grossNvdax, true));
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

    uint256 probeNonce;

    /// @dev measure the effective received amount with a probe transfer of the same size:
    /// a plain donation to the Vault does not affect pool state (settle always sync()s first)
    /// and the multiplier cannot change within the forked block, so the loss is deterministic.
    /// A FRESH probe address is used per measurement: _mintNVDAx's slot probing is only safe
    /// for an address with zero shares — with leftover shares, overwriting the multiplier slot
    /// (also read by balanceOf) would inflate the balance and be mistaken for the shares slot
    function _measureNetTransferToVault(uint256 amount) internal returns (uint256 net) {
        address probe = makeAddr(string.concat("infinity-xstock-fork-probe-", vm.toString(probeNonce++)));
        _mintNVDAx(probe, amount);
        uint256 vaultBalanceBefore = NVDAX.balanceOf(address(VAULT));
        vm.prank(probe);
        NVDAX.transfer(address(VAULT), amount);
        net = NVDAX.balanceOf(address(VAULT)) - vaultBalanceBefore;
    }

    /// @notice mint NVDAx to `to` by locating its shares storage slot at runtime.
    /// @dev `deal()` cannot be used: `balanceOf` is `shares * multiplier / 1e18`, so stdStorage's
    /// write-and-read-back probing never matches. Instead we record which slots `balanceOf`
    /// reads, overwrite each candidate with the target share amount and keep the one that
    /// actually changes the reported balance (restoring the others).
    function _mintNVDAx(address to, uint256 shareAmount) internal {
        uint256 balanceBefore = NVDAX.balanceOf(to);

        vm.record();
        NVDAX.balanceOf(to);
        (bytes32[] memory reads,) = vm.accesses(address(NVDAX));

        for (uint256 i = 0; i < reads.length; i++) {
            bytes32 prev = vm.load(address(NVDAX), reads[i]);
            vm.store(address(NVDAX), reads[i], bytes32(shareAmount));

            // low-level call: overwriting an unrelated slot (e.g. the proxy implementation
            // slot) can make balanceOf revert, which just means "wrong slot, restore"
            (bool ok, bytes memory ret) =
                address(NVDAX).staticcall(abi.encodeWithSelector(IERC20.balanceOf.selector, to));
            if (ok && ret.length == 32 && abi.decode(ret, (uint256)) > balanceBefore) {
                return; // found the shares slot, keep the write
            }
            vm.store(address(NVDAX), reads[i], prev);
        }

        revert("NVDAx shares slot not found");
    }
}
