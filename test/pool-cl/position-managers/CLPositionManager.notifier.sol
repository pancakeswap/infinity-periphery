// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {CLPosition} from "infinity-core/src/pool-cl/libraries/CLPosition.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";

import {Hooks} from "infinity-core/src/libraries/Hooks.sol";
import {IPositionManager} from "../../../src/interfaces/IPositionManager.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";
import {MockCLSubscriber} from "../mocks/MockCLSubscriber.sol";
import {ICLSubscriber} from "../../../src/pool-cl/interfaces/ICLSubscriber.sol";
import {ICLPositionManager} from "../../../src/pool-cl/interfaces/ICLPositionManager.sol";
import {Plan, Planner} from "../../../src/libraries/Planner.sol";
import {Actions} from "../../../src/libraries/Actions.sol";
import {ICLNotifier} from "../../../src/pool-cl/interfaces/ICLNotifier.sol";
import {MockCLReturnDataSubscriber, MockCLRevertSubscriber} from "../mocks/MockCLBadSubscribers.sol";
import {CLPositionInfo, CLPositionInfoLibrary} from "../../../src/pool-cl/libraries/CLPositionInfoLibrary.sol";
import {MockCLReenterHook} from "../mocks/MockCLReenterHook.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";

contract CLPositionManagerNotifierTest is Test, PosmTestSetup {
    using CLPositionInfoLibrary for CLPositionInfo;

    IVault vault;
    ICLPoolManager manager;

    PoolId poolId;
    PoolKey key;
    PoolKey reenterKey;

    MockCLSubscriber sub;
    MockCLReturnDataSubscriber badSubscriber;
    MockCLRevertSubscriber revertSubscriber;
    MockCLReenterHook reenterHook;

    address alice = makeAddr("ALICE");
    address bob = makeAddr("BOB");

    function setUp() public {
        // This is needed to receive return deltas from modifyLiquidity calls.
        deployPosmHookSavesDelta();

        (vault, manager, key, poolId) = createFreshPool(ICLHooks(address(hook)), 3000, SQRT_RATIO_1_1);
        currency0 = key.currency0;
        currency1 = key.currency1;

        deployAndApproveRouter(vault, manager);

        // Requires currency0 and currency1 to be set in base Deployers contract.
        deployAndApprovePosm(vault, manager);

        sub = new MockCLSubscriber(lpm);
        badSubscriber = new MockCLReturnDataSubscriber(lpm);
        revertSubscriber = new MockCLRevertSubscriber(lpm);

        // set the reenter hook
        reenterHook = new MockCLReenterHook();
        reenterHook.setPosm(lpm);

        reenterKey = PoolKey(
            currency0,
            currency1,
            reenterHook,
            manager,
            3000,
            bytes32(uint256((60 << 16) | reenterHook.getHooksRegistrationBitmap()))
        );
        manager.initialize(reenterKey, SQRT_RATIO_1_1);
    }

    function test_subscribe_revertsWithEmptyPositionConfig() public {
        uint256 tokenId = lpm.nextTokenId();
        vm.expectRevert("NOT_MINTED");
        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);
    }

    function test_subscribe_revertsWhenNotApproved() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 100e18, alice, ZERO_BYTES);

        // this contract is not approved to operate on alice's liq

        vm.expectRevert(abi.encodeWithSelector(ICLPositionManager.NotApproved.selector, address(this)));
        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);
    }

    function test_subscribe_succeeds() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 100e18, alice, ZERO_BYTES);

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);

        (, CLPositionInfo info) = lpm.getPoolAndPositionInfo(tokenId);
        assertEq(info.hasSubscriber(), true);
        assertEq(address(lpm.subscriber(tokenId)), address(sub));
        assertEq(sub.notifySubscribeCount(), 1);
    }

    /// @notice Revert when subscribing to an address without code
    function test_subscribe_revert_empty(address _subscriber) public {
        vm.assume(_subscriber.code.length == 0);

        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 100e18, alice, ZERO_BYTES);

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(ICLNotifier.NoCodeSubscriber.selector));
        lpm.subscribe(tokenId, _subscriber, ZERO_BYTES);

        (, CLPositionInfo info) = lpm.getPoolAndPositionInfo(tokenId);
        assertEq(info.hasSubscriber(), false);
    }

    function test_subscribe_revertsWithAlreadySubscribed() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 100e18, alice, ZERO_BYTES);

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        // successfully subscribe
        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);
        assertEq(address(lpm.subscriber(tokenId)), address(sub));
        assertEq(sub.notifySubscribeCount(), 1);

        vm.expectRevert(abi.encodeWithSelector(ICLNotifier.AlreadySubscribed.selector, tokenId, sub));
        lpm.subscribe(tokenId, address(2), ZERO_BYTES);
    }

    function test_notifyModifyLiquidity_selfDestruct_revert() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 100e18, alice, ZERO_BYTES);

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);

        assertEq(address(lpm.subscriber(tokenId)), address(sub));

        // simulate selfdestruct by etching the bytecode to 0
        vm.etch(address(sub), ZERO_BYTES);

        uint256 liquidityToAdd = 10e18;
        _latestPoolKey = key;
        vm.expectRevert(abi.encodeWithSelector(ICLNotifier.NoCodeSubscriber.selector));
        increaseLiquidity(tokenId, liquidityToAdd, ZERO_BYTES);
    }

    function test_notifyModifyLiquidity_succeeds() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 100e18, alice, ZERO_BYTES);

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);

        assertEq(address(lpm.subscriber(tokenId)), address(sub));

        Plan memory plan = Planner.init();
        for (uint256 i = 0; i < 10; i++) {
            plan.add(
                Actions.CL_INCREASE_LIQUIDITY,
                abi.encode(tokenId, 10e18, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
            );
        }

        bytes memory calls = plan.finalizeModifyLiquidityWithSettlePair(key);
        lpm.modifyLiquidities(calls, _deadline);

        assertEq(sub.notifySubscribeCount(), 1);
        assertEq(sub.notifyModifyLiquidityCount(), 10);
    }

    function test_transferFrom_unsubscribes_selfDestruct() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 100e18, alice, ZERO_BYTES);

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);
        assertEq(address(lpm.subscriber(tokenId)), address(sub));

        // simulate selfdestruct by etching the bytecode to 0
        vm.etch(address(sub), ZERO_BYTES);

        // unsubscribe happens regardless of the subscriber contract's code
        lpm.transferFrom(alice, bob, tokenId);

        assertEq(lpm.positionInfo(tokenId).hasSubscriber(), false);
        assertEq(address(lpm.subscriber(tokenId)), address(0));
    }

    function test_notifyModifyLiquidity_args() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 100e18, alice, ZERO_BYTES);

        // donate to generate fee revenue, to be checked in subscriber
        uint256 feeRevenue0 = 1e18;
        uint256 feeRevenue1 = 0.1e18;
        router.donate(key, feeRevenue0, feeRevenue1, ZERO_BYTES);

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);

        assertEq(address(lpm.subscriber(tokenId)), address(sub));

        uint256 liquidityToAdd = 10e18;
        increaseLiquidity(tokenId, liquidityToAdd, ZERO_BYTES);

        assertEq(sub.notifyModifyLiquidityCount(), 1);
        assertEq(sub.liquidityChange(), int256(liquidityToAdd));
        assertEq(int256(sub.feesAccrued().amount0()), int256(feeRevenue0) - 1 wei);
        assertEq(int256(sub.feesAccrued().amount1()), int256(feeRevenue1) - 1 wei);
    }

    function test_safeTransferFrom_unsubscribes_selfDestruct() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 100e18, alice, ZERO_BYTES);

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);
        assertEq(address(lpm.subscriber(tokenId)), address(sub));

        // simulate selfdestruct by etching the bytecode to 0
        vm.etch(address(sub), ZERO_BYTES);

        // unsubscribe happens regardless of the subscriber contract's code
        lpm.safeTransferFrom(alice, bob, tokenId);
        assertEq(lpm.positionInfo(tokenId).hasSubscriber(), false);
        assertEq(address(lpm.subscriber(tokenId)), address(0));
    }

    function test_transferFrom_unsubscribes() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 100e18, alice, ZERO_BYTES);

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);

        assertEq(address(lpm.subscriber(tokenId)), address(sub));

        lpm.transferFrom(alice, bob, tokenId);

        assertEq(sub.notifyUnsubscribeCount(), 1);
        assertEq(lpm.positionInfo(tokenId).hasSubscriber(), false);
        assertEq(address(lpm.subscriber(tokenId)), address(0));
    }

    function test_unsubscribe_selfDestructed() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 100e18, alice, ZERO_BYTES);

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);

        // simulate selfdestruct by etching the bytecode to 0
        vm.etch(address(sub), ZERO_BYTES);

        lpm.unsubscribe(tokenId);

        (, CLPositionInfo info) = lpm.getPoolAndPositionInfo(tokenId);
        assertEq(info.hasSubscriber(), false);
        assertEq(address(lpm.subscriber(tokenId)), address(0));
    }

    function test_safeTransferFrom_unsubscribes() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 100e18, alice, ZERO_BYTES);

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);

        assertEq(address(lpm.subscriber(tokenId)), address(sub));

        lpm.safeTransferFrom(alice, bob, tokenId);

        assertEq(sub.notifyUnsubscribeCount(), 1);
        assertEq(lpm.positionInfo(tokenId).hasSubscriber(), false);
        assertEq(address(lpm.subscriber(tokenId)), address(0));
    }

    function test_safeTransferFrom_unsubscribes_withData() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 100e18, alice, ZERO_BYTES);

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);

        assertEq(address(lpm.subscriber(tokenId)), address(sub));

        lpm.safeTransferFrom(alice, bob, tokenId, "");

        assertEq(sub.notifyUnsubscribeCount(), 1);
        assertEq(lpm.positionInfo(tokenId).hasSubscriber(), false);
        assertEq(address(lpm.subscriber(tokenId)), address(0));
    }

    function test_unsubscribe_succeeds() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 100e18, alice, ZERO_BYTES);

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);

        lpm.unsubscribe(tokenId);

        assertEq(sub.notifyUnsubscribeCount(), 1);
        assertEq(address(lpm.subscriber(tokenId)), address(0));
    }

    function test_unsubscribe_isSuccessfulWithBadSubscriber() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 100e18, alice, ZERO_BYTES);

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(badSubscriber), ZERO_BYTES);

        MockCLReturnDataSubscriber(badSubscriber).setReturnDataSize(0x600000);
        lpm.unsubscribe(tokenId);

        // the subscriber contract call failed bc it used too much gas
        assertEq(MockCLReturnDataSubscriber(badSubscriber).notifyUnsubscribeCount(), 0);
        assertEq(address(lpm.subscriber(tokenId)), address(0));
    }

    function test_multicall_mint_subscribe() public {
        uint256 tokenId = lpm.nextTokenId();

        Plan memory plan = Planner.init();
        plan.add(
            Actions.CL_MINT_POSITION,
            abi.encode(key, -300, 300, 100e18, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, address(this), ZERO_BYTES)
        );
        bytes memory actions = plan.finalizeModifyLiquidityWithSettlePair(key);

        bytes[] memory calls = new bytes[](2);

        calls[0] = abi.encodeWithSelector(lpm.modifyLiquidities.selector, actions, _deadline);
        calls[1] = abi.encodeWithSelector(lpm.subscribe.selector, tokenId, sub, ZERO_BYTES);

        lpm.multicall(calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, 100e18);
        assertEq(sub.notifySubscribeCount(), 1);

        assertEq(address(lpm.subscriber(tokenId)), address(sub));
    }

    function test_multicall_mint_subscribe_increase() public {
        uint256 tokenId = lpm.nextTokenId();

        // Encode mint.
        Plan memory plan = Planner.init();
        plan.add(
            Actions.CL_MINT_POSITION,
            abi.encode(key, -300, 300, 100e18, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, address(this), ZERO_BYTES)
        );
        bytes memory actions = plan.finalizeModifyLiquidityWithSettlePair(key);

        // Encode increase separately.
        plan = Planner.init();
        plan.add(
            Actions.CL_INCREASE_LIQUIDITY,
            abi.encode(tokenId, 10e18, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );
        bytes memory actions2 = plan.finalizeModifyLiquidityWithSettlePair(key);

        bytes[] memory calls = new bytes[](3);

        calls[0] = abi.encodeWithSelector(lpm.modifyLiquidities.selector, actions, _deadline);
        calls[1] = abi.encodeWithSelector(lpm.subscribe.selector, tokenId, sub, ZERO_BYTES);
        calls[2] = abi.encodeWithSelector(lpm.modifyLiquidities.selector, actions2, _deadline);

        lpm.multicall(calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, 110e18);
        assertEq(sub.notifySubscribeCount(), 1);
        assertEq(sub.notifyModifyLiquidityCount(), 1);
        assertEq(address(lpm.subscriber(tokenId)), address(sub));
    }

    function test_unsubscribe_revertsWhenNotSubscribed() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 100e18, alice, ZERO_BYTES);

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        vm.expectRevert();
        vm.expectRevert(ICLNotifier.NotSubscribed.selector);
        lpm.unsubscribe(tokenId);
    }

    function test_unsubscribe_twice_reverts() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 100e18, alice, ZERO_BYTES);

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);

        lpm.unsubscribe(tokenId);

        vm.expectRevert(ICLNotifier.NotSubscribed.selector);
        lpm.unsubscribe(tokenId);
    }

    function test_subscribe_withData() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 100e18, alice, ZERO_BYTES);

        bytes memory subData = abi.encode(address(this));

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(sub), subData);

        assertEq(address(lpm.subscriber(tokenId)), address(sub));
        assertEq(sub.notifySubscribeCount(), 1);
        assertEq(abi.decode(sub.subscribeData(), (address)), address(this));
    }

    function test_subscribe_wraps_revert() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 100e18, alice, ZERO_BYTES);

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        revertSubscriber.setRevert(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(revertSubscriber),
                ICLSubscriber.notifySubscribe.selector,
                abi.encodeWithSelector(MockCLRevertSubscriber.TestRevert.selector, "notifySubscribe"),
                abi.encodeWithSelector(ICLNotifier.SubscriptionReverted.selector)
            )
        );
        lpm.subscribe(tokenId, address(revertSubscriber), ZERO_BYTES);
    }

    function test_notifyModifyLiquidiy_wraps_revert() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 100e18, alice, ZERO_BYTES);

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(revertSubscriber), ZERO_BYTES);

        Plan memory plan = Planner.init();
        for (uint256 i = 0; i < 10; i++) {
            plan.add(
                Actions.CL_INCREASE_LIQUIDITY,
                abi.encode(tokenId, 10e18, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
            );
        }

        bytes memory calls = plan.finalizeModifyLiquidityWithSettlePair(key);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(revertSubscriber),
                ICLSubscriber.notifyModifyLiquidity.selector,
                abi.encodeWithSelector(MockCLRevertSubscriber.TestRevert.selector, "notifyModifyLiquidity"),
                abi.encodeWithSelector(ICLNotifier.ModifyLiquidityNotificationReverted.selector)
            )
        );
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_notifyBurn_wraps_revert() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 100e18, alice, ZERO_BYTES);

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(revertSubscriber), ZERO_BYTES);

        bytes memory calls = getBurnEncoded(tokenId, ZERO_BYTES);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(revertSubscriber),
                ICLSubscriber.notifyBurn.selector,
                abi.encodeWithSelector(MockCLRevertSubscriber.TestRevert.selector, "notifyBurn"),
                abi.encodeWithSelector(ICLNotifier.BurnNotificationReverted.selector)
            )
        );
        lpm.modifyLiquidities(calls, _deadline);
    }

    /// @notice burning a position will automatically notify burn
    function test_notifyBurn_succeeds() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 100e18, alice, ZERO_BYTES);

        bytes memory subData = abi.encode(address(this));

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(sub), subData);

        assertEq(sub.notifyUnsubscribeCount(), 0);

        // burn the position, causing a notifyBurn
        burn(tokenId, ZERO_BYTES);

        // position is now unsubscribed
        assertEq(sub.notifyUnsubscribeCount(), 0);
        assertEq(sub.notifyBurnCount(), 1);
    }

    /// @notice Test that users cannot forcibly avoid unsubscribe logic via gas limits
    function test_fuzz_unsubscribe_with_gas_limit(uint64 gasLimit) public {
        // enforce a minimum amount of gas to avoid OutOfGas reverts
        gasLimit = uint64(bound(gasLimit, 125_000, block.gaslimit));

        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 100e18, alice, ZERO_BYTES);

        // approve this contract to operate on alices liq
        vm.startPrank(alice);
        lpm.approve(address(this), tokenId);
        vm.stopPrank();

        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);
        uint256 beforeUnsubCount = sub.notifyUnsubscribeCount();

        if (gasLimit < lpm.unsubscribeGasLimit()) {
            // gas too low to call a valid unsubscribe
            vm.expectRevert(ICLNotifier.GasLimitTooLow.selector);
            lpm.unsubscribe{gas: gasLimit}(tokenId);
        } else {
            // increasing gas limit succeeds and unsubscribe was called
            lpm.unsubscribe{gas: gasLimit}(tokenId);
            assertEq(sub.notifyUnsubscribeCount(), beforeUnsubCount + 1);
        }
    }

    function test_unsubscribe_reverts_VaultMustBeUnlocked() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(reenterKey, -60, 60, 10e18, address(this), ZERO_BYTES);

        bytes memory hookData = abi.encode(lpm.unsubscribe.selector, address(this), tokenId);
        bytes memory actions = getMintEncoded(reenterKey, -60, 60, 10e18, address(this), hookData);

        // approve hook as it should not revert because it does not have permissions
        lpm.approve(address(reenterHook), tokenId);
        // subscribe as it should not revert because there is no subscriber
        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);

        // should revert since the vault is locked
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(reenterHook),
                reenterHook.beforeAddLiquidity.selector,
                abi.encodeWithSelector(IPositionManager.VaultMustBeUnlocked.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        lpm.modifyLiquidities(actions, _deadline);
    }

    function test_subscribe_reverts_VaultMustBeUnlocked() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(reenterKey, -60, 60, 10e18, address(this), ZERO_BYTES);

        bytes memory hookData = abi.encode(lpm.subscribe.selector, address(this), tokenId);
        bytes memory actions = getMintEncoded(reenterKey, -60, 60, 10e18, address(this), hookData);

        // approve hook as it should not revert because it does not have permissions
        lpm.approve(address(reenterHook), tokenId);

        // should revert since the vault is locked
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(reenterHook),
                reenterHook.beforeAddLiquidity.selector,
                abi.encodeWithSelector(IPositionManager.VaultMustBeUnlocked.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        lpm.modifyLiquidities(actions, _deadline);
    }

    function test_transferFrom_reverts_VaultMustBeUnlocked() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(reenterKey, -60, 60, 10e18, address(this), ZERO_BYTES);

        bytes memory hookData = abi.encode(lpm.transferFrom.selector, address(this), tokenId);
        bytes memory actions = getMintEncoded(reenterKey, -60, 60, 10e18, address(this), hookData);

        // approve hook as it should not revert because it does not have permissions
        lpm.approve(address(reenterHook), tokenId);

        // should revert since the vault is locked
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(reenterHook),
                reenterHook.beforeAddLiquidity.selector,
                abi.encodeWithSelector(IPositionManager.VaultMustBeUnlocked.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        lpm.modifyLiquidities(actions, _deadline);
    }
}
