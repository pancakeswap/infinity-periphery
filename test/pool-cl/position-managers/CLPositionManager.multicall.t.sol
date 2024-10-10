// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {CLPoolManager} from "pancake-v4-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {LiquidityAmounts} from "pancake-v4-core/test/pool-cl/helpers/LiquidityAmounts.sol";
import {TickMath} from "pancake-v4-core/src/pool-cl/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {CLPosition} from "pancake-v4-core/src/pool-cl/libraries/CLPosition.sol";
import {CLPoolParametersHelper} from "pancake-v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {CLPoolParametersHelper} from "pancake-v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IERC721Permit_v4} from "../../../src/pool-cl/base/ERC721Permit_v4.sol";
import {IMulticall_v4} from "../../../src/interfaces/IMulticall_v4.sol";
import {CLPositionManager} from "../../../src/pool-cl/CLPositionManager.sol";
import {IPositionManager} from "../../../src/interfaces/IPositionManager.sol";
import {DeltaResolver} from "../../../src/base/DeltaResolver.sol";
import {ICLPositionManager} from "../../../src/pool-cl/interfaces/ICLPositionManager.sol";
import {Actions} from "../../../src/libraries/Actions.sol";
import {Planner, Plan} from "../../../src/libraries/Planner.sol";
import {FeeMath} from "../shared/FeeMath.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";
import {ActionConstants} from "../../../src/libraries/ActionConstants.sol";
import {Permit2SignatureHelpers} from "../../shared/Permit2SignatureHelpers.sol";
import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";
import {Permit2Forwarder} from "../../../src/base/Permit2Forwarder.sol";

contract CLPositionManagerMulticallTest is Test, Permit2SignatureHelpers, PosmTestSetup, LiquidityFuzzers {
    using FixedPointMathLib for uint256;
    using Planner for Plan;
    using CLPoolParametersHelper for bytes32;

    IVault vault;
    ICLPoolManager manager;

    PoolId poolId;
    PoolKey key;

    address alice;
    uint256 alicePK;
    address bob;
    // bob used for permit2 signature tests
    uint256 bobPK;
    address charlie; // charlie will NOT approve posm in setup()
    uint256 charliePK;

    Permit2Forwarder permit2Forwarder;

    uint160 permitAmount = type(uint160).max;
    // the expiration of the allowance is large
    uint48 permitExpiration = uint48(block.timestamp + 10e18);
    uint48 permitNonce = 0;

    // redefine error from permit2/src/PermitErrors.sol since its hard-pinned to a solidity version
    error InvalidNonce();

    bytes32 PERMIT2_DOMAIN_SEPARATOR;

    function setUp() public {
        (alice, alicePK) = makeAddrAndKey("ALICE");
        (bob, bobPK) = makeAddrAndKey("BOB");
        (charlie, charliePK) = makeAddrAndKey("CHARLIE");

        // This is needed to receive return deltas from modifyLiquidity calls.
        deployPosmHookSavesDelta();

        (vault, manager, key, poolId) = createFreshPool(IHooks(address(hook)), 3000, SQRT_RATIO_1_1);
        currency0 = key.currency0;
        currency1 = key.currency1;

        deployAndApproveRouter(vault, manager);

        // Requires currency0 and currency1 to be set in base Deployers contract.
        deployAndApprovePosm(vault, manager);

        permit2Forwarder = new Permit2Forwarder(permit2);
        PERMIT2_DOMAIN_SEPARATOR = permit2.DOMAIN_SEPARATOR();

        seedBalance(alice);
        approvePosmFor(alice);

        seedBalance(bob);
        approvePosmFor(bob);
    }

    function test_multicall_initializePool_mint() public {
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0,
            hooks: IHooks(address(0)),
            poolManager: manager,
            parameters: bytes32(uint256((10 << 16) | 0x0000))
        });

        // Use multicall to initialize a pool and mint liquidity
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(lpm.initializePool.selector, key, SQRT_RATIO_1_1, ZERO_BYTES);

        Plan memory planner = Planner.init();
        planner.add(
            Actions.CL_MINT_POSITION,
            abi.encode(
                key,
                TickMath.minUsableTick(key.parameters.getTickSpacing()),
                TickMath.maxUsableTick(key.parameters.getTickSpacing()),
                100e18,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        bytes memory actions = planner.finalizeModifyLiquidityWithClose(key);

        calls[1] = abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, actions, _deadline);

        IMulticall_v4(address(lpm)).multicall(calls);

        // test swap, doesn't revert, showing the pool was initialized
        int256 amountSpecified = -1e18;
        BalanceDelta result = swap(key, true, amountSpecified, ZERO_BYTES);
        assertEq(result.amount0(), amountSpecified);
        assertGt(result.amount1(), 0);
    }

    // Ted will attempt to decrease liquidity without approval
    // posm's NotApproved(Ted) should bubble up through Multicall
    function test_multicall_bubbleRevert() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(
            key,
            TickMath.minUsableTick(key.parameters.getTickSpacing()),
            TickMath.maxUsableTick(key.parameters.getTickSpacing()),
            100e18,
            address(this),
            ZERO_BYTES
        );

        Plan memory planner = Planner.init();
        planner.add(
            Actions.CL_DECREASE_LIQUIDITY,
            abi.encode(tokenId, 100e18, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );
        bytes memory actions = planner.finalizeModifyLiquidityWithClose(key);

        // Use multicall to decrease liquidity
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, actions, _deadline);

        address ted = makeAddr("Ted");
        vm.startPrank(ted);
        vm.expectRevert(abi.encodeWithSelector(ICLPositionManager.NotApproved.selector, ted));
        lpm.multicall(calls);
        vm.stopPrank();
    }

    // decrease liquidity but forget to close
    // core's CurrencyNotSettled should bubble up through Multicall
    function test_multicall_bubbleRevert_core() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(
            key,
            TickMath.minUsableTick(key.parameters.getTickSpacing()),
            TickMath.maxUsableTick(key.parameters.getTickSpacing()),
            100e18,
            address(this),
            ZERO_BYTES
        );

        // do not close deltas to throw CurrencyNotSettled in core
        Plan memory planner = Planner.init();
        planner.add(
            Actions.CL_DECREASE_LIQUIDITY,
            abi.encode(tokenId, 100e18, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );
        bytes memory actions = planner.encode();

        // Use multicall to decrease liquidity
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, actions, _deadline);

        vm.expectRevert(IVault.CurrencyNotSettled.selector);
        lpm.multicall(calls);
    }

    // create a pool where tickSpacing is negative
    // core's TickSpacingTooSmall(int24) should bubble up through Multicall
    function test_multicall_bubbleRevert_core_args() public {
        int24 tickSpacing = -10;
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0,
            poolManager: manager,
            hooks: IHooks(address(0)),
            parameters: bytes32(uint256(int256(tickSpacing << 16) | 0x0000))
        });

        // Use multicall to initialize a pool
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(ICLPositionManager.initializePool.selector, key, SQRT_RATIO_1_1, ZERO_BYTES);

        vm.expectRevert(abi.encodeWithSelector(ICLPoolManager.TickSpacingTooSmall.selector, tickSpacing));
        lpm.multicall(calls);
    }

    function test_multicall_permitAndDecrease() public {
        uint256 liquidityAlice = 1e18;
        vm.startPrank(alice);
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -60, 60, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();

        // Alice gives Bob permission to operate on her liquidity
        uint256 nonce = 1;
        bytes32 digest = getDigest(bob, tokenId, nonce, block.timestamp + 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // bob gives himself permission and decreases liquidity
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            IERC721Permit_v4(lpm).permit.selector, bob, tokenId, block.timestamp + 1, nonce, signature
        );
        uint256 liquidityToRemove = 0.4444e18;
        bytes memory actions = getDecreaseEncoded(tokenId, liquidityToRemove, ZERO_BYTES);
        calls[1] = abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, actions, _deadline);

        vm.prank(bob);
        lpm.multicall(calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);
        assertEq(liquidity, liquidityAlice - liquidityToRemove);
    }

    function test_multicall_permit_mint() public {
        // 1. revoke the auto permit we give to posm for 1 token
        vm.prank(bob);
        permit2.approve(Currency.unwrap(currency0), address(lpm), 0, 0);

        (uint160 _amount,, uint48 _expiration) =
            permit2.allowance(address(bob), Currency.unwrap(currency0), address(this));

        assertEq(_amount, 0);
        assertEq(_expiration, 0);

        uint256 tokenId = lpm.nextTokenId();
        bytes memory mintCall = getMintEncoded(
            key,
            TickMath.minUsableTick(key.parameters.getTickSpacing()),
            TickMath.maxUsableTick(key.parameters.getTickSpacing()),
            10e18,
            bob,
            ZERO_BYTES
        );

        // 2 . call a mint that reverts because position manager doesn't have permission on permit2
        vm.expectRevert(abi.encodeWithSelector(IAllowanceTransfer.InsufficientAllowance.selector, 0));
        vm.prank(bob);
        lpm.modifyLiquidities(mintCall, _deadline);

        // 3. encode a permit for that revoked token
        IAllowanceTransfer.PermitSingle memory permit =
            defaultERC20PermitAllowance(Currency.unwrap(currency0), permitAmount, permitExpiration, permitNonce);
        permit.spender = address(lpm);
        bytes memory sig = getPermitSignature(permit, bobPK, PERMIT2_DOMAIN_SEPARATOR);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(Permit2Forwarder.permit.selector, bob, permit, sig);
        calls[1] = abi.encodeWithSelector(lpm.modifyLiquidities.selector, mintCall, _deadline);

        vm.prank(bob);
        lpm.multicall(calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        (_amount,,) = permit2.allowance(address(bob), Currency.unwrap(currency0), address(lpm));

        assertEq(_amount, permitAmount);
        assertEq(liquidity, 10e18);
        assertEq(lpm.ownerOf(tokenId), bob);
    }

    function test_multicall_permit_batch_mint() public {
        // 1. revoke the auto permit we give to posm for 1 token
        vm.prank(bob);
        permit2.approve(Currency.unwrap(currency0), address(lpm), 0, 0);
        permit2.approve(Currency.unwrap(currency1), address(lpm), 0, 0);

        (uint160 _amount0,, uint48 _expiration0) =
            permit2.allowance(address(bob), Currency.unwrap(currency0), address(this));

        (uint160 _amount1,, uint48 _expiration1) =
            permit2.allowance(address(bob), Currency.unwrap(currency1), address(this));

        assertEq(_amount0, 0);
        assertEq(_expiration0, 0);
        assertEq(_amount1, 0);
        assertEq(_expiration1, 0);

        uint256 tokenId = lpm.nextTokenId();
        bytes memory mintCall = getMintEncoded(
            key,
            TickMath.minUsableTick(key.parameters.getTickSpacing()),
            TickMath.maxUsableTick(key.parameters.getTickSpacing()),
            10e18,
            bob,
            ZERO_BYTES
        );

        // 2 . call a mint that reverts because position manager doesn't have permission on permit2
        vm.expectRevert(abi.encodeWithSelector(IAllowanceTransfer.InsufficientAllowance.selector, 0));
        vm.prank(bob);
        lpm.modifyLiquidities(mintCall, _deadline);

        // 3. encode a permit for that revoked token
        address[] memory tokens = new address[](2);
        tokens[0] = Currency.unwrap(currency0);
        tokens[1] = Currency.unwrap(currency1);

        IAllowanceTransfer.PermitBatch memory permit =
            defaultERC20PermitBatchAllowance(tokens, permitAmount, permitExpiration, permitNonce);
        permit.spender = address(lpm);
        bytes memory sig = getPermitBatchSignature(permit, bobPK, PERMIT2_DOMAIN_SEPARATOR);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(Permit2Forwarder.permitBatch.selector, bob, permit, sig);
        calls[1] = abi.encodeWithSelector(lpm.modifyLiquidities.selector, mintCall, _deadline);

        vm.prank(bob);
        lpm.multicall(calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        (_amount0,,) = permit2.allowance(address(bob), Currency.unwrap(currency0), address(lpm));
        (_amount1,,) = permit2.allowance(address(bob), Currency.unwrap(currency1), address(lpm));
        assertEq(_amount0, permitAmount);
        assertEq(_amount1, permitAmount);
        assertEq(liquidity, 10e18);
        assertEq(lpm.ownerOf(tokenId), bob);
    }

    /// @notice test that a front-ran permit does not fail a multicall with permit
    function test_multicall_permit_frontrun_suceeds() public {
        // Charlie signs permit for the two tokens
        IAllowanceTransfer.PermitSingle memory permit0 =
            defaultERC20PermitAllowance(Currency.unwrap(currency0), permitAmount, permitExpiration, permitNonce);
        permit0.spender = address(lpm);
        bytes memory sig0 = getPermitSignature(permit0, charliePK, PERMIT2_DOMAIN_SEPARATOR);

        IAllowanceTransfer.PermitSingle memory permit1 =
            defaultERC20PermitAllowance(Currency.unwrap(currency1), permitAmount, permitExpiration, permitNonce);
        permit1.spender = address(lpm);
        bytes memory sig1 = getPermitSignature(permit1, charliePK, PERMIT2_DOMAIN_SEPARATOR);

        // bob front-runs the permits
        vm.startPrank(bob);
        lpm.permit(charlie, permit0, sig0);
        lpm.permit(charlie, permit1, sig1);
        vm.stopPrank();

        // bob's front-run was successful
        (uint160 _amount, uint48 _expiration, uint48 _nonce) =
            permit2.allowance(charlie, Currency.unwrap(currency0), address(lpm));
        assertEq(_amount, permitAmount);
        assertEq(_expiration, permitExpiration);
        assertEq(_nonce, permitNonce + 1);
        (uint160 _amount1, uint48 _expiration1, uint48 _nonce1) =
            permit2.allowance(charlie, Currency.unwrap(currency1), address(lpm));
        assertEq(_amount1, permitAmount);
        assertEq(_expiration1, permitExpiration);
        assertEq(_nonce1, permitNonce + 1);

        // charlie tries to mint an LP token with multicall(permit, permit, mint)
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeWithSelector(Permit2Forwarder(lpm).permit.selector, charlie, permit0, sig0);
        calls[1] = abi.encodeWithSelector(Permit2Forwarder(lpm).permit.selector, charlie, permit1, sig1);
        bytes memory mintCall = getMintEncoded(
            key,
            TickMath.minUsableTick(key.parameters.getTickSpacing()),
            TickMath.maxUsableTick(key.parameters.getTickSpacing()),
            10e18,
            charlie,
            ZERO_BYTES
        );
        calls[2] = abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, mintCall, _deadline);

        uint256 tokenId = lpm.nextTokenId();
        vm.expectRevert();
        lpm.ownerOf(tokenId); // token does not exist

        bytes[] memory results = lpm.multicall(calls);
        assertEq(results[0], abi.encode(abi.encodeWithSelector(InvalidNonce.selector)));
        assertEq(results[1], abi.encode(abi.encodeWithSelector(InvalidNonce.selector)));

        assertEq(lpm.ownerOf(tokenId), charlie);
    }

    /// @notice test that a front-ran permitBatch does not fail a multicall with permitBatch
    function test_multicall_permitBatch_frontrun_suceeds() public {
        // Charlie signs permitBatch for the two tokens
        address[] memory tokens = new address[](2);
        tokens[0] = Currency.unwrap(currency0);
        tokens[1] = Currency.unwrap(currency1);

        IAllowanceTransfer.PermitBatch memory permit =
            defaultERC20PermitBatchAllowance(tokens, permitAmount, permitExpiration, permitNonce);
        permit.spender = address(lpm);
        bytes memory sig = getPermitBatchSignature(permit, charliePK, PERMIT2_DOMAIN_SEPARATOR);

        // bob front-runs the permits
        vm.prank(bob);
        lpm.permitBatch(charlie, permit, sig);

        // bob's front-run was successful
        (uint160 _amount, uint48 _expiration, uint48 _nonce) =
            permit2.allowance(charlie, Currency.unwrap(currency0), address(lpm));
        assertEq(_amount, permitAmount);
        assertEq(_expiration, permitExpiration);
        assertEq(_nonce, permitNonce + 1);
        (uint160 _amount1, uint48 _expiration1, uint48 _nonce1) =
            permit2.allowance(charlie, Currency.unwrap(currency1), address(lpm));
        assertEq(_amount1, permitAmount);
        assertEq(_expiration1, permitExpiration);
        assertEq(_nonce1, permitNonce + 1);

        // charlie tries to mint an LP token with multicall(permitBatch, mint)
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(Permit2Forwarder(lpm).permitBatch.selector, charlie, permit, sig);
        bytes memory mintCall = getMintEncoded(
            key,
            TickMath.minUsableTick(key.parameters.getTickSpacing()),
            TickMath.maxUsableTick(key.parameters.getTickSpacing()),
            10e18,
            charlie,
            ZERO_BYTES
        );
        calls[1] = abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, mintCall, _deadline);

        uint256 tokenId = lpm.nextTokenId();
        vm.expectRevert();
        lpm.ownerOf(tokenId); // token does not exist

        bytes[] memory results = lpm.multicall(calls);
        assertEq(results[0], abi.encode(abi.encodeWithSelector(InvalidNonce.selector)));

        assertEq(lpm.ownerOf(tokenId), charlie);
    }
}
