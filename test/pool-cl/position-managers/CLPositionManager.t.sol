// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {toBalanceDelta, BalanceDelta, BalanceDeltaLibrary} from "infinity-core/src/types/BalanceDelta.sol";
import {LiquidityAmounts} from "infinity-core/test/pool-cl/helpers/LiquidityAmounts.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {CLPosition} from "infinity-core/src/pool-cl/libraries/CLPosition.sol";
import {SafeCast} from "infinity-core/src/libraries/SafeCast.sol";
import {Fuzzers} from "infinity-core/test/pool-cl/helpers/Fuzzers.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {MockCLSubscriber} from "../mocks/MockCLSubscriber.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPositionManager} from "../../../src/interfaces/IPositionManager.sol";
import {CLPositionManager} from "../../../src/pool-cl/CLPositionManager.sol";
import {DeltaResolver} from "../../../src/base/DeltaResolver.sol";
import {SlippageCheck} from "../../../src/libraries/SlippageCheck.sol";
import {ICLPositionManager} from "../../../src/pool-cl/interfaces/ICLPositionManager.sol";
import {Actions} from "../../../src/libraries/Actions.sol";
import {Planner, Plan} from "../../../src/libraries/Planner.sol";
import {FeeMath} from "../shared/FeeMath.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";
import {ActionConstants} from "../../../src/libraries/ActionConstants.sol";
import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";
import {BaseActionsRouter} from "../../../src/base/BaseActionsRouter.sol";
import {ReentrantToken} from "../mocks/ReentrantToken.sol";
import {ICLSubscriber} from "../../../src/pool-cl/interfaces/ICLSubscriber.sol";
import {CLPositionDescriptorOffChain} from "../../../src/pool-cl/CLPositionDescriptorOffChain.sol";

contract PositionManagerTest is Test, PosmTestSetup, LiquidityFuzzers {
    using FixedPointMathLib for uint256;
    using CLPoolParametersHelper for bytes32;

    error ContractSizeTooLarge(uint256 diff);

    IVault vault;
    ICLPoolManager manager;

    PoolId poolId;
    PoolKey key;

    address alice = makeAddr("ALICE");

    function setUp() public {
        // This is needed to receive return deltas from modifyLiquidity calls.
        deployPosmHookSavesDelta();

        (vault, manager, key, poolId) = createFreshPool(IHooks(address(hook)), 3000, SQRT_RATIO_1_1);
        currency0 = key.currency0;
        currency1 = key.currency1;

        deployAndApproveRouter(vault, manager);

        // Requires currency0 and currency1 to be set in base Deployers contract.
        deployAndApprovePosm(vault, manager);

        seedBalance(alice);
        approvePosmFor(alice);
    }

    function test_tokenURI() public {
        assertEq(lpm.tokenURI(1), "https://pancakeswap.finance/infinity/pool-cl/positions/1");
        assertEq(lpm.tokenURI(10), "https://pancakeswap.finance/infinity/pool-cl/positions/10");
        assertEq(lpm.tokenURI(2), "https://pancakeswap.finance/infinity/pool-cl/positions/2");
        assertEq(lpm.tokenURI(20), "https://pancakeswap.finance/infinity/pool-cl/positions/20");
        assertEq(
            lpm.tokenURI(type(uint256).max),
            "https://pancakeswap.finance/infinity/pool-cl/positions/115792089237316195423570985008687907853269984665640564039457584007913129639935"
        );

        // update the base token URI to be empty
        CLPositionDescriptorOffChain(address(positionDescriptor)).setBaseTokenURI("");
        assertEq(lpm.tokenURI(1), "");
        assertEq(lpm.tokenURI(10), "");
        assertEq(lpm.tokenURI(2), "");
        assertEq(lpm.tokenURI(20), "");
        assertEq(lpm.tokenURI(type(uint256).max), "");

        // update to be ipfs base URI
        CLPositionDescriptorOffChain(address(positionDescriptor)).setBaseTokenURI("ipfs://abcd/");
        assertEq(lpm.tokenURI(1), "ipfs://abcd/1");
        assertEq(lpm.tokenURI(10), "ipfs://abcd/10");
        assertEq(lpm.tokenURI(2), "ipfs://abcd/2");
        assertEq(lpm.tokenURI(20), "ipfs://abcd/20");
        assertEq(
            lpm.tokenURI(type(uint256).max),
            "ipfs://abcd/115792089237316195423570985008687907853269984665640564039457584007913129639935"
        );
    }

    function test_bytecodeSize() public {
        vm.snapshotValue("CLPositionManager bytecode size", address(lpm).code.length);

        if (address(lpm).code.length > 24576) {
            revert ContractSizeTooLarge(address(lpm).code.length - 24576);
        }
    }

    function test_modifyLiquidities_reverts_deadlinePassed() public {
        bytes memory calls = getMintEncoded(key, 0, 60, 1e18, ActionConstants.MSG_SENDER, "");

        uint256 deadline = vm.getBlockTimestamp() - 1;

        vm.expectRevert(abi.encodeWithSelector(IPositionManager.DeadlinePassed.selector, deadline));
        lpm.modifyLiquidities(calls, deadline);
    }

    function test_modifyLiquidities_reverts_mismatchedLengths() public {
        Plan memory planner = Planner.init();
        planner.add(Actions.CL_MINT_POSITION, abi.encode("test"));
        planner.add(Actions.CL_BURN_POSITION, abi.encode("test"));

        bytes[] memory badParams = new bytes[](1);

        vm.expectRevert(BaseActionsRouter.InputLengthMismatch.selector);
        lpm.modifyLiquidities(abi.encode(planner.actions, badParams), block.timestamp + 1);
    }

    function test_modifyLiquidities_reverts_reentrancy() public {
        // Create a reentrant token and initialize the pool
        Currency reentrantToken = Currency.wrap(address(new ReentrantToken(lpm)));
        (currency0, currency1) = (Currency.unwrap(reentrantToken) < Currency.unwrap(currency1))
            ? (reentrantToken, currency1)
            : (currency1, reentrantToken);

        // Set up approvals for the reentrant token
        approvePosmCurrency(reentrantToken);

        key.currency0 = currency0;
        key.currency1 = currency1;
        manager.initialize(key, SQRT_RATIO_1_1);

        // Try to add liquidity at that range, but the token reenters posm
        bytes memory calls = getMintEncoded(key, -60, 60, 1e18, ActionConstants.MSG_SENDER, "");

        // Permit2.transferFrom does not bubble the ContractLocked error and instead reverts with its own error
        vm.expectRevert("TRANSFER_FROM_FAILED");
        lpm.modifyLiquidities(calls, block.timestamp + 1);
    }

    function test_fuzz_mint_withLiquidityDelta(ICLPoolManager.ModifyLiquidityParams memory params, uint160 sqrtPriceX96)
        public
    {
        bound(sqrtPriceX96, MIN_PRICE_LIMIT, MAX_PRICE_LIMIT);
        params = createFuzzyLiquidityParams(key, params, sqrtPriceX96);
        // liquidity is a uint
        uint256 liquidityToAdd =
            params.liquidityDelta < 0 ? uint256(-params.liquidityDelta) : uint256(params.liquidityDelta);

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        uint256 tokenId = lpm.nextTokenId();
        vm.expectEmit(true, true, true, true);
        emit ICLPositionManager.ModifyLiquidity(tokenId, int256(liquidityToAdd), BalanceDeltaLibrary.ZERO_DELTA);

        mint(key, params.tickLower, params.tickUpper, liquidityToAdd, ActionConstants.MSG_SENDER, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();

        assertEq(tokenId, 1);
        assertEq(lpm.nextTokenId(), 2);
        assertEq(lpm.ownerOf(tokenId), address(this));

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, uint256(params.liquidityDelta));
        assertEq(balance0Before - currency0.balanceOfSelf(), uint256(int256(-delta.amount0())), "incorrect amount0");
        assertEq(balance1Before - currency1.balanceOfSelf(), uint256(int256(-delta.amount1())), "incorrect amount1");
    }

    function test_mint_exactTokenRatios() public {
        int24 tickLower = -int24(key.parameters.getTickSpacing());
        int24 tickUpper = int24(key.parameters.getTickSpacing());
        uint256 amount0Desired = 100e18;
        uint256 amount1Desired = 100e18;
        uint256 liquidityToAdd = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_RATIO_1_1,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            amount0Desired,
            amount1Desired
        );

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        uint256 tokenId = lpm.nextTokenId();
        mint(key, tickLower, tickUpper, liquidityToAdd, ActionConstants.MSG_SENDER, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();

        uint256 balance0After = currency0.balanceOfSelf();
        uint256 balance1After = currency1.balanceOfSelf();

        assertEq(tokenId, 1);
        assertEq(lpm.ownerOf(1), address(this));

        assertEq(uint256(int256(-delta.amount0())), amount0Desired);
        assertEq(uint256(int256(-delta.amount1())), amount1Desired);
        assertEq(balance0Before - balance0After, uint256(int256(-delta.amount0())));
        assertEq(balance1Before - balance1After, uint256(int256(-delta.amount1())));
    }

    function test_mint_toRecipient() public {
        int24 tickLower = -int24(key.parameters.getTickSpacing());
        int24 tickUpper = int24(key.parameters.getTickSpacing());
        uint256 amount0Desired = 100e18;
        uint256 amount1Desired = 100e18;
        uint256 liquidityToAdd = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_RATIO_1_1,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            amount0Desired,
            amount1Desired
        );

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        uint256 tokenId = lpm.nextTokenId();
        // mint to specific recipient, not using the recipient constants
        mint(key, tickLower, tickUpper, liquidityToAdd, alice, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();

        uint256 balance0After = currency0.balanceOfSelf();
        uint256 balance1After = currency1.balanceOfSelf();

        assertEq(tokenId, 1);
        assertEq(lpm.ownerOf(1), alice);

        assertEq(uint256(int256(-delta.amount0())), amount0Desired);
        assertEq(uint256(int256(-delta.amount1())), amount1Desired);
        assertEq(balance0Before - balance0After, uint256(int256(-delta.amount0())));
        assertEq(balance1Before - balance1After, uint256(int256(-delta.amount1())));
    }

    function test_fuzz_mint_recipient(ICLPoolManager.ModifyLiquidityParams memory seedParams) public {
        ICLPoolManager.ModifyLiquidityParams memory params = createFuzzyLiquidityParams(key, seedParams, SQRT_RATIO_1_1);
        uint256 liquidityToAdd =
            params.liquidityDelta < 0 ? uint256(-params.liquidityDelta) : uint256(params.liquidityDelta);

        uint256 tokenId = lpm.nextTokenId();
        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        uint256 balance0BeforeAlice = currency0.balanceOf(alice);
        uint256 balance1BeforeAlice = currency1.balanceOf(alice);
        mint(key, params.tickLower, params.tickUpper, liquidityToAdd, alice, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();

        assertEq(tokenId, 1);
        assertEq(lpm.ownerOf(tokenId), alice);

        // alice was not the payer
        assertEq(balance0Before - currency0.balanceOfSelf(), uint256(int256(-delta.amount0())));
        assertEq(balance1Before - currency1.balanceOfSelf(), uint256(int256(-delta.amount1())));
        assertEq(currency0.balanceOf(alice), balance0BeforeAlice);
        assertEq(currency1.balanceOf(alice), balance1BeforeAlice);
    }

    /// @dev clear cannot be used on mint (negative delta)
    function test_fuzz_mint_clear_revert(ICLPoolManager.ModifyLiquidityParams memory seedParams) public {
        ICLPoolManager.ModifyLiquidityParams memory params = createFuzzyLiquidityParams(key, seedParams, SQRT_RATIO_1_1);
        uint256 liquidityToAdd =
            params.liquidityDelta < 0 ? uint256(-params.liquidityDelta) : uint256(params.liquidityDelta);

        Plan memory planner = Planner.init();
        planner.add(
            Actions.CL_MINT_POSITION,
            abi.encode(
                key,
                params.tickLower,
                params.tickUpper,
                liquidityToAdd,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                address(this),
                ZERO_BYTES
            )
        );
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(key.currency0, type(uint256).max));
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(key.currency1, type(uint256).max));
        bytes memory calls = planner.encode();

        Currency negativeDeltaCurrency = currency0;
        // because we're fuzzing the range, single-sided mint with currency1 means currency0Delta = 0 and currency1Delta < 0
        if (params.tickUpper <= 0) {
            negativeDeltaCurrency = currency1;
        }

        vm.expectRevert(abi.encodeWithSelector(DeltaResolver.DeltaNotPositive.selector, negativeDeltaCurrency));
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_mint_slippage_revertAmount0() public {
        uint256 liquidity = 1e18;
        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_RATIO_1_1, TickMath.getSqrtRatioAtTick(-120), TickMath.getSqrtRatioAtTick(120), uint128(liquidity)
        );

        bytes memory calls = getMintEncoded(
            key, -120, 120, liquidity, 1 wei, MAX_SLIPPAGE_INCREASE, ActionConstants.MSG_SENDER, ZERO_BYTES
        );
        vm.expectRevert(abi.encodeWithSelector(SlippageCheck.MaximumAmountExceeded.selector, 1 wei, amount0 + 1));
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_mint_slippage_revertAmount1() public {
        uint256 liquidity = 1e18;
        (, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_RATIO_1_1, TickMath.getSqrtRatioAtTick(-120), TickMath.getSqrtRatioAtTick(120), uint128(liquidity)
        );

        bytes memory calls = getMintEncoded(
            key, -120, 120, liquidity, MAX_SLIPPAGE_INCREASE, 1 wei, ActionConstants.MSG_SENDER, ZERO_BYTES
        );
        vm.expectRevert(abi.encodeWithSelector(SlippageCheck.MaximumAmountExceeded.selector, 1 wei, amount1 + 1));
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_mint_slippage_exactDoesNotRevert() public {
        uint256 liquidity = 1e18;
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_RATIO_1_1, TickMath.getSqrtRatioAtTick(-120), TickMath.getSqrtRatioAtTick(120), uint128(liquidity)
        );
        assertEq(amount0, amount1); // symmetric liquidity
        uint128 slippage = uint128(amount0) + 1;

        bytes memory calls =
            getMintEncoded(key, -120, 120, liquidity, slippage, slippage, ActionConstants.MSG_SENDER, ZERO_BYTES);
        lpm.modifyLiquidities(calls, _deadline);
        BalanceDelta delta = getLastDelta();
        assertEq(uint256(int256(-delta.amount0())), slippage);
        assertEq(uint256(int256(-delta.amount1())), slippage);
    }

    function test_mint_slippage_revert_swap() public {
        // swapping will cause a slippage revert

        uint256 liquidity = 100e18;
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_RATIO_1_1, TickMath.getSqrtRatioAtTick(-120), TickMath.getSqrtRatioAtTick(120), uint128(liquidity)
        );
        assertEq(amount0, amount1); // symmetric liquidity
        uint128 slippage = uint128(amount0) + 1;

        bytes memory calls =
            getMintEncoded(key, -120, 120, liquidity, slippage, slippage, ActionConstants.MSG_SENDER, ZERO_BYTES);

        // swap to move the price and cause a slippage revert
        swap(key, true, -1e18, ZERO_BYTES);

        vm.expectRevert(
            abi.encodeWithSelector(SlippageCheck.MaximumAmountExceeded.selector, slippage, 1199947202932782783)
        );
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_fuzz_burn_emptyPosition(ICLPoolManager.ModifyLiquidityParams memory params) public {
        uint256 balance0Start = currency0.balanceOfSelf();
        uint256 balance1Start = currency1.balanceOfSelf();

        // create liquidity we can burn
        uint256 tokenId;
        (tokenId, params) = addFuzzyLiquidity(lpm, ActionConstants.MSG_SENDER, key, params, SQRT_RATIO_1_1, ZERO_BYTES);
        assertEq(tokenId, 1);
        assertEq(lpm.ownerOf(1), address(this));

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, uint256(params.liquidityDelta));

        // burn liquidity
        uint256 balance0BeforeBurn = currency0.balanceOfSelf();
        uint256 balance1BeforeBurn = currency1.balanceOfSelf();

        decreaseLiquidity(tokenId, liquidity, ZERO_BYTES);
        BalanceDelta deltaDecrease = getLastDelta();
        uint256 numDeltas = hook.numberDeltasReturned();
        // No decrease/modifyLiq call will actually happen on the call to burn so the deltas array will be the same length.
        burn(tokenId, ZERO_BYTES);
        assertEq(numDeltas, hook.numberDeltasReturned());

        liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, 0);

        assertEq(currency0.balanceOfSelf(), balance0BeforeBurn + uint256(int256(deltaDecrease.amount0())));
        assertEq(currency1.balanceOfSelf(), balance1BeforeBurn + uint256(uint128(deltaDecrease.amount1())));

        // 721 will revert if the token does not exist
        vm.expectRevert();
        lpm.ownerOf(1);

        // no tokens were lost, TODO: fuzzer showing off by 1 sometimes
        // Potentially because we round down in core. I believe this is known in V3. But let's check!
        assertApproxEqAbs(currency0.balanceOfSelf(), balance0Start, 1 wei);
        assertApproxEqAbs(currency1.balanceOfSelf(), balance1Start, 1 wei);
    }

    function test_fuzz_burn_nonEmptyPosition(ICLPoolManager.ModifyLiquidityParams memory params) public {
        uint256 balance0Start = currency0.balanceOfSelf();
        uint256 balance1Start = currency1.balanceOfSelf();

        // create liquidity we can burn
        uint256 tokenId;
        (tokenId, params) = addFuzzyLiquidity(lpm, ActionConstants.MSG_SENDER, key, params, SQRT_RATIO_1_1, ZERO_BYTES);
        assertEq(tokenId, 1);
        assertEq(lpm.ownerOf(1), address(this));

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, uint256(params.liquidityDelta));

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(params.tickLower),
            TickMath.getSqrtRatioAtTick(params.tickUpper),
            uint128(int128(params.liquidityDelta))
        );

        // burn liquidity
        uint256 balance0BeforeBurn = currency0.balanceOfSelf();
        uint256 balance1BeforeBurn = currency1.balanceOfSelf();

        // only emit modifyLiquidity when non-empty position gets burned
        vm.expectEmit(true, true, true, true);
        emit ICLPositionManager.ModifyLiquidity(tokenId, -int256(liquidity), BalanceDeltaLibrary.ZERO_DELTA);

        burn(tokenId, ZERO_BYTES);
        BalanceDelta deltaBurn = getLastDelta();

        assertEq(uint256(int256(deltaBurn.amount0())), amount0);
        assertEq(uint256(int256(deltaBurn.amount1())), amount1);

        liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, 0);

        assertEq(currency0.balanceOfSelf(), balance0BeforeBurn + uint256(int256(deltaBurn.amount0())));
        assertEq(currency1.balanceOfSelf(), balance1BeforeBurn + uint256(uint128(deltaBurn.amount1())));

        // OZ 721 will revert if the token does not exist
        vm.expectRevert();
        lpm.ownerOf(1);

        // no tokens were lost, TODO: fuzzer showing off by 1 sometimes
        // Potentially because we round down in core. I believe this is known in V3. But let's check!
        assertApproxEqAbs(currency0.balanceOfSelf(), balance0Start, 1 wei);
        assertApproxEqAbs(currency1.balanceOfSelf(), balance1Start, 1 wei);
    }

    function test_burn_slippage_revertAmount0() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -120, 120, 1e18, ActionConstants.MSG_SENDER, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();
        uint128 amount0 = uint128(-delta.amount0());

        bytes memory calls = getBurnEncoded(tokenId, amount0 + 1 wei, MIN_SLIPPAGE_DECREASE, ZERO_BYTES);
        vm.expectRevert(
            abi.encodeWithSelector(SlippageCheck.MinimumAmountInsufficient.selector, amount0 + 1, amount0 - 1)
        );
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_burn_slippage_revertAmount1() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -120, 120, 1e18, ActionConstants.MSG_SENDER, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();
        uint128 amount1 = uint128(-delta.amount1());

        bytes memory calls = getBurnEncoded(tokenId, MIN_SLIPPAGE_DECREASE, amount1 + 1 wei, ZERO_BYTES);

        // reverts on amount1, because the swap sent token0 into the pool and took token1
        vm.expectRevert(
            abi.encodeWithSelector(SlippageCheck.MinimumAmountInsufficient.selector, amount1 + 1, amount1 - 1)
        );
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_burn_slippage_exactDoesNotRevert() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -120, 120, 1e18, ActionConstants.MSG_SENDER, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();

        // TODO: why does burning a newly minted position return original delta - 1 wei?
        bytes memory calls =
            getBurnEncoded(tokenId, uint128(-delta.amount0()) - 1 wei, uint128(-delta.amount1()) - 1 wei, ZERO_BYTES);
        lpm.modifyLiquidities(calls, _deadline);
        BalanceDelta burnDelta = getLastDelta();

        assertApproxEqAbs(-delta.amount0(), burnDelta.amount0(), 1 wei);
        assertApproxEqAbs(-delta.amount1(), burnDelta.amount1(), 1 wei);
    }

    function test_burn_slippage_revert_swap() public {
        // swapping will cause a slippage revert
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -120, 120, 1e18, ActionConstants.MSG_SENDER, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();
        uint128 amount1 = uint128(-delta.amount1());

        bytes memory calls = getBurnEncoded(tokenId, uint128(-delta.amount0()) - 1 wei, amount1 - 1 wei, ZERO_BYTES);

        // swap to move the price and cause a slippage revert
        swap(key, true, -1e18, ZERO_BYTES);

        vm.expectRevert(abi.encodeWithSelector(SlippageCheck.MinimumAmountInsufficient.selector, amount1 - 1, 0));
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_fuzz_decreaseLiquidity(
        ICLPoolManager.ModifyLiquidityParams memory params,
        uint256 decreaseLiquidityDelta
    ) public {
        uint256 tokenId;
        (tokenId, params) = addFuzzyLiquidity(lpm, ActionConstants.MSG_SENDER, key, params, SQRT_RATIO_1_1, ZERO_BYTES);
        decreaseLiquidityDelta = uint256(bound(int256(decreaseLiquidityDelta), 0, params.liquidityDelta));

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        decreaseLiquidity(tokenId, decreaseLiquidityDelta, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);
        assertEq(liquidity, uint256(params.liquidityDelta) - decreaseLiquidityDelta);

        assertEq(currency0.balanceOfSelf(), balance0Before + uint256(uint128(delta.amount0())));
        assertEq(currency1.balanceOfSelf(), balance1Before + uint256(uint128(delta.amount1())));
    }

    /// @dev Clearing on decrease liquidity is allowed
    function test_fuzz_decreaseLiquidity_clear(
        ICLPoolManager.ModifyLiquidityParams memory params,
        uint256 decreaseLiquidityDelta
    ) public {
        uint256 tokenId;
        (tokenId, params) = addFuzzyLiquidity(lpm, address(this), key, params, SQRT_RATIO_1_1, ZERO_BYTES);
        decreaseLiquidityDelta = uint256(bound(int256(decreaseLiquidityDelta), 0, params.liquidityDelta));

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        // Clearing is allowed on decrease liquidity
        Plan memory planner = Planner.init();
        planner.add(
            Actions.CL_DECREASE_LIQUIDITY,
            abi.encode(tokenId, decreaseLiquidityDelta, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(key.currency0, type(uint256).max));
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(key.currency1, type(uint256).max));
        bytes memory calls = planner.encode();

        lpm.modifyLiquidities(calls, _deadline);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);
        assertEq(liquidity, uint256(params.liquidityDelta) - decreaseLiquidityDelta);

        // did not receive tokens, as they were forfeited with CLEAR
        assertEq(currency0.balanceOfSelf(), balance0Before);
        assertEq(currency1.balanceOfSelf(), balance1Before);
    }

    /// @dev Clearing on decrease will take tokens if the amount exceeds the clear limit
    function test_fuzz_decreaseLiquidity_clearExceedsThenTake(ICLPoolManager.ModifyLiquidityParams memory params)
        public
    {
        // use fuzzer for tick range
        params = createFuzzyTwoSidedLiquidityParams(key, params, SQRT_RATIO_1_1);

        uint256 liquidityToAdd = 1e18;
        uint256 liquidityToRemove = bound(liquidityToAdd, liquidityToAdd / 1000, liquidityToAdd);
        uint256 tokenId = lpm.nextTokenId();
        mint(key, params.tickLower, params.tickUpper, 1e18, address(this), ZERO_BYTES);

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_RATIO_1_1,
            TickMath.getSqrtRatioAtTick(params.tickLower),
            TickMath.getSqrtRatioAtTick(params.tickUpper),
            uint128(liquidityToRemove)
        );

        Plan memory planner = Planner.init();
        planner.add(
            Actions.CL_DECREASE_LIQUIDITY,
            abi.encode(tokenId, liquidityToRemove, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(key.currency0, amount0 - 1 wei));
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(key.currency1, amount1 - 1 wei));
        bytes memory calls = planner.encode();

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        // expect to take the tokens
        lpm.modifyLiquidities(calls, _deadline);
        BalanceDelta delta = getLastDelta();

        // amount exceeded clear limit, so we should have the tokens
        assertEq(uint128(delta.amount0()), amount0);
        assertEq(uint128(delta.amount1()), amount1);
        assertEq(currency0.balanceOfSelf(), balance0Before + amount0);
        assertEq(currency1.balanceOfSelf(), balance1Before + amount1);
    }

    function test_decreaseLiquidity_collectFees(
        ICLPoolManager.ModifyLiquidityParams memory params,
        uint256 decreaseLiquidityDelta
    ) public {
        uint256 tokenId;
        (tokenId, params) =
            addFuzzyTwoSidedLiquidity(lpm, ActionConstants.MSG_SENDER, key, params, SQRT_RATIO_1_1, ZERO_BYTES);
        decreaseLiquidityDelta = bound(decreaseLiquidityDelta, 1, uint256(params.liquidityDelta));

        // donate to generate fee revenue
        uint256 feeRevenue0 = 1e18;
        uint256 feeRevenue1 = 0.1e18;
        router.donate(key, feeRevenue0, feeRevenue1, ZERO_BYTES);

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        // 1. expect modifyLiquidity to be emitted with the correct values
        // 2. expect the returned delta to be the fee revenue
        vm.expectEmit(true, true, true, false);
        emit ICLPositionManager.ModifyLiquidity(
            tokenId,
            -int256(decreaseLiquidityDelta),
            /// @dev -1 as a hotfix for precision loss
            toBalanceDelta(int128(int256(feeRevenue0 - 1)), int128(int256(feeRevenue1 - 1)))
        );

        decreaseLiquidity(tokenId, decreaseLiquidityDelta, ZERO_BYTES);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, uint256(params.liquidityDelta) - decreaseLiquidityDelta);

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_RATIO_1_1,
            TickMath.getSqrtRatioAtTick(params.tickLower),
            TickMath.getSqrtRatioAtTick(params.tickUpper),
            uint128(decreaseLiquidityDelta)
        );

        // claimed both principal liquidity and fee revenue
        assertApproxEqAbs(currency0.balanceOfSelf() - balance0Before, amount0 + feeRevenue0, 1 wei);
        assertApproxEqAbs(currency1.balanceOfSelf() - balance1Before, amount1 + feeRevenue1, 1 wei);
    }

    function test_decreaseLiquidity_slippage_revertAmount0() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -120, 120, 1e18, ActionConstants.MSG_SENDER, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();
        uint128 amount0Delta = uint128(-delta.amount0());

        bytes memory calls = getDecreaseEncoded(tokenId, 1e18, amount0Delta + 1, MIN_SLIPPAGE_DECREASE, ZERO_BYTES);
        vm.expectRevert(
            abi.encodeWithSelector(SlippageCheck.MinimumAmountInsufficient.selector, amount0Delta + 1, amount0Delta - 1)
        );
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_decreaseLiquidity_slippage_revertAmount1() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -120, 120, 1e18, ActionConstants.MSG_SENDER, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();
        uint128 amount1Delta = uint128(-delta.amount0());

        bytes memory calls = getDecreaseEncoded(tokenId, 1e18, MIN_SLIPPAGE_DECREASE, amount1Delta + 1 wei, ZERO_BYTES);
        vm.expectRevert(
            abi.encodeWithSelector(SlippageCheck.MinimumAmountInsufficient.selector, amount1Delta + 1, amount1Delta - 1)
        );
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_decreaseLiquidity_slippage_exactDoesNotRevert() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -120, 120, 1e18, ActionConstants.MSG_SENDER, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();

        // TODO: why does decreasing a newly minted position return original delta - 1 wei?
        bytes memory calls = getDecreaseEncoded(
            tokenId, 1e18, uint128(-delta.amount0()) - 1 wei, uint128(-delta.amount1()) - 1 wei, ZERO_BYTES
        );
        lpm.modifyLiquidities(calls, _deadline);
        BalanceDelta decreaseDelta = getLastDelta();

        // TODO: why does decreasing a newly minted position return original delta - 1 wei?
        assertApproxEqAbs(-delta.amount0(), decreaseDelta.amount0(), 1 wei);
        assertApproxEqAbs(-delta.amount1(), decreaseDelta.amount1(), 1 wei);
    }

    function test_decreaseLiquidity_slippage_revert_swap() public {
        // swapping will cause a slippage revert
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -120, 120, 1e18, ActionConstants.MSG_SENDER, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();
        uint128 amount1 = uint128(-delta.amount1());

        bytes memory calls =
            getDecreaseEncoded(tokenId, 1e18, uint128(-delta.amount0()) - 1 wei, amount1 - 1 wei, ZERO_BYTES);

        // swap to move the price and cause a slippage revert
        swap(key, true, -1e18, ZERO_BYTES);

        // reverts on amount1, because the swap sent token0 into the pool and took token1
        vm.expectRevert(abi.encodeWithSelector(SlippageCheck.MinimumAmountInsufficient.selector, amount1 - 1, 0));
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_fuzz_decreaseLiquidity_assertCollectedBalance(
        ICLPoolManager.ModifyLiquidityParams memory params,
        uint256 decreaseLiquidityDelta
    ) public {
        uint256 tokenId;
        (tokenId, params) =
            addFuzzyTwoSidedLiquidity(lpm, ActionConstants.MSG_SENDER, key, params, SQRT_RATIO_1_1, ZERO_BYTES);
        decreaseLiquidityDelta = bound(decreaseLiquidityDelta, 1, uint256(params.liquidityDelta));

        // swap to create fees
        uint256 swapAmount = 0.01e18;
        swap(key, false, int256(swapAmount), ZERO_BYTES);

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();
        decreaseLiquidity(tokenId, decreaseLiquidityDelta, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, uint256(params.liquidityDelta) - decreaseLiquidityDelta);

        // The change in balance equals the delta returned.
        assertEq(currency0.balanceOfSelf() - balance0Before, uint256(int256(delta.amount0())));
        assertEq(currency1.balanceOfSelf() - balance1Before, uint256(int256(delta.amount1())));
    }

    function test_mintTransferBurn() public {
        uint256 liquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -600, 600, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);
        BalanceDelta mintDelta = getLastDelta();

        // transfer to alice
        lpm.transferFrom(address(this), alice, tokenId);

        // alice can burn the position
        bytes memory calls = getBurnEncoded(tokenId, ZERO_BYTES);

        uint256 balance0BeforeAlice = currency0.balanceOf(alice);
        uint256 balance1BeforeAlice = currency0.balanceOf(alice);

        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);

        // token was burned and does not exist anymore
        vm.expectRevert();
        lpm.ownerOf(tokenId);

        // alice received the principal liquidity
        assertApproxEqAbs(currency0.balanceOf(alice) - balance0BeforeAlice, uint128(-mintDelta.amount0()), 1 wei);
        assertApproxEqAbs(currency1.balanceOf(alice) - balance1BeforeAlice, uint128(-mintDelta.amount1()), 1 wei);
    }

    function test_mintTransferCollect() public {
        uint256 liquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -600, 600, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        // donate to generate fee revenue
        uint256 feeRevenue0 = 1e18;
        uint256 feeRevenue1 = 0.1e18;
        router.donate(key, feeRevenue0, feeRevenue1, ZERO_BYTES);

        // transfer to alice
        lpm.transferFrom(address(this), alice, tokenId);

        // alice can collect the fees
        uint256 balance0BeforeAlice = currency0.balanceOf(alice);
        uint256 balance1BeforeAlice = currency1.balanceOf(alice);
        vm.startPrank(alice);
        collect(tokenId, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();
        vm.stopPrank();

        // alice received the fee revenue
        assertApproxEqAbs(currency0.balanceOf(alice) - balance0BeforeAlice, feeRevenue0, 1 wei);
        assertApproxEqAbs(currency1.balanceOf(alice) - balance1BeforeAlice, feeRevenue1, 1 wei);
        assertApproxEqAbs(uint128(delta.amount0()), feeRevenue0, 1 wei);
        assertApproxEqAbs(uint128(delta.amount1()), feeRevenue1, 1 wei);
    }

    function test_mintTransferIncrease() public {
        uint256 liquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -600, 600, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        // transfer to alice
        lpm.transferFrom(address(this), alice, tokenId);

        // alice increases liquidity and is the payer
        uint256 balance0BeforeAlice = currency0.balanceOf(alice);
        uint256 balance1BeforeAlice = currency1.balanceOf(alice);
        vm.startPrank(alice);
        uint256 liquidityToAdd = 10e18;
        increaseLiquidity(tokenId, liquidityToAdd, ZERO_BYTES);
        BalanceDelta delta = getLastDelta();
        vm.stopPrank();

        // position liquidity increased
        uint256 newLiq = lpm.getPositionLiquidity(tokenId);
        assertEq(newLiq, liquidity + liquidityToAdd);

        // alice paid the tokens
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_RATIO_1_1, TickMath.getSqrtRatioAtTick(-600), TickMath.getSqrtRatioAtTick(600), uint128(liquidityToAdd)
        );
        assertApproxEqAbs(balance0BeforeAlice - currency0.balanceOf(alice), amount0, 1 wei);
        assertApproxEqAbs(balance1BeforeAlice - currency1.balanceOf(alice), amount1, 1 wei);
        assertApproxEqAbs(uint128(-delta.amount0()), amount0, 1 wei);
        assertApproxEqAbs(uint128(-delta.amount1()), amount1, 1 wei);
    }

    function test_mintTransferDecrease() public {
        uint256 liquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -600, 600, liquidity, ActionConstants.MSG_SENDER, ZERO_BYTES);

        // donate to generate fee revenue
        uint256 feeRevenue0 = 1e18;
        uint256 feeRevenue1 = 0.1e18;
        router.donate(key, feeRevenue0, feeRevenue1, ZERO_BYTES);

        // transfer to alice
        lpm.transferFrom(address(this), alice, tokenId);

        {
            // alice decreases liquidity and is the recipient
            uint256 balance0BeforeAlice = currency0.balanceOf(alice);
            uint256 balance1BeforeAlice = currency1.balanceOf(alice);
            vm.startPrank(alice);
            uint256 liquidityToRemove = 10e18;
            decreaseLiquidity(tokenId, liquidityToRemove, ZERO_BYTES);
            BalanceDelta delta = getLastDelta();
            vm.stopPrank();

            {
                // position liquidity decreased
                uint256 newLiq = lpm.getPositionLiquidity(tokenId);
                assertEq(newLiq, liquidity - liquidityToRemove);
            }

            // alice received the principal + fees
            (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
                SQRT_RATIO_1_1,
                TickMath.getSqrtRatioAtTick(-600),
                TickMath.getSqrtRatioAtTick(600),
                uint128(liquidityToRemove)
            );
            assertApproxEqAbs(currency0.balanceOf(alice) - balance0BeforeAlice, amount0 + feeRevenue0, 1 wei);
            assertApproxEqAbs(currency1.balanceOf(alice) - balance1BeforeAlice, amount1 + feeRevenue1, 1 wei);
            assertApproxEqAbs(uint128(delta.amount0()), amount0 + feeRevenue0, 1 wei);
            assertApproxEqAbs(uint128(delta.amount1()), amount1 + feeRevenue1, 1 wei);
        }
    }

    function test_initialize() public {
        // initialize a new pool and add liquidity
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0,
            hooks: IHooks(address(0)),
            poolManager: manager,
            parameters: bytes32(uint256((10 << 16) | 0x0000))
        });
        lpm.initializePool(key, SQRT_RATIO_1_1);

        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        assertEq(sqrtPriceX96, SQRT_RATIO_1_1);
        assertEq(tick, 0);
        assertEq(protocolFee, 0);
        assertEq(lpFee, key.fee);
    }

    function test_fuzz_initialize(uint160 sqrtPrice, uint24 fee) public {
        sqrtPrice =
            uint160(bound(sqrtPrice, TickMath.MIN_SQRT_RATIO, TickMath.MAX_SQRT_RATIO_MINUS_MIN_SQRT_RATIO_MINUS_ONE));
        fee = uint24(bound(fee, 0, LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE));
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            hooks: IHooks(address(0)),
            poolManager: manager,
            parameters: bytes32(uint256((10 << 16) | 0x0000))
        });
        lpm.initializePool(key, sqrtPrice);

        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        assertEq(sqrtPriceX96, sqrtPrice);
        assertEq(tick, TickMath.getTickAtSqrtRatio(sqrtPrice));
        assertEq(protocolFee, 0);
        assertEq(lpFee, fee);
    }

    // tests a decrease and take in both currencies
    // does not use take pair, so its less optimal
    function test_decrease_take() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -120, 120, 1e18, ActionConstants.MSG_SENDER, ZERO_BYTES);

        hook.clearDeltas();

        uint256 balanceBefore0 = currency0.balanceOfSelf();
        uint256 balanceBefore1 = currency1.balanceOfSelf();

        Plan memory plan = Planner.init();
        plan.add(
            Actions.CL_DECREASE_LIQUIDITY,
            abi.encode(tokenId, 1e18, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );
        bytes memory calls = plan.finalizeModifyLiquidityWithTake(key, ActionConstants.MSG_SENDER);

        lpm.modifyLiquidities(calls, _deadline);
        BalanceDelta delta = getLastDelta();

        assertEq(currency0.balanceOfSelf(), balanceBefore0 + uint256(int256(delta.amount0())));
        assertEq(currency1.balanceOfSelf(), balanceBefore1 + uint256(int256(delta.amount1())));
    }

    // decrease full range position
    // mint new one sided position in currency1
    // expect to TAKE currency0 and SETTLE currency1
    function test_decrease_increaseCurrency1_take_settle() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -120, 120, 1e18, ActionConstants.MSG_SENDER, ZERO_BYTES);

        hook.clearDeltas();

        uint256 balanceBefore0 = currency0.balanceOfSelf();
        uint256 balanceBefore1 = currency1.balanceOfSelf();

        uint256 tokenIdMint = lpm.nextTokenId();

        // one-sided liq in currency1
        Plan memory plan = Planner.init();
        plan.add(
            Actions.CL_DECREASE_LIQUIDITY,
            abi.encode(tokenId, 1e18, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );
        plan.add(
            Actions.CL_MINT_POSITION,
            abi.encode(
                key, -120, 0, 1e18, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ActionConstants.MSG_SENDER, ZERO_BYTES
            )
        );
        plan.add(Actions.TAKE, abi.encode(key.currency0, ActionConstants.MSG_SENDER, ActionConstants.OPEN_DELTA));
        plan.add(Actions.SETTLE, abi.encode(key.currency1, ActionConstants.OPEN_DELTA, true));
        bytes memory calls = plan.finalizeModifyLiquidityWithTake(key, ActionConstants.MSG_SENDER);

        lpm.modifyLiquidities(calls, _deadline);
        BalanceDelta deltaDecrease = hook.deltas(0);
        BalanceDelta deltaMint = hook.deltas(1);

        assertEq(deltaMint.amount0(), 0); // there is no currency0 in the new position
        assertEq(currency0.balanceOfSelf(), balanceBefore0 + uint256(int256(deltaDecrease.amount0())));
        assertEq(
            currency1.balanceOfSelf(), balanceBefore1 - uint256(-int256(deltaDecrease.amount1() + deltaMint.amount1()))
        );
        assertEq(lpm.ownerOf(tokenIdMint), address(this));
        assertLt(currency1.balanceOfSelf(), balanceBefore1); // currency1 was owed
        assertLt(uint256(int256(deltaDecrease.amount1())), uint256(int256(-deltaMint.amount1()))); // amount1 in the second position was greater than amount1 in the first position
    }

    function test_mint_emits_event() public {
        uint256 tokenId = lpm.nextTokenId();

        vm.expectEmit(true, false, false, true, address(lpm));
        emit ICLPositionManager.MintPosition(tokenId);
        mint(key, -60, 60, 1e18, ActionConstants.MSG_SENDER, ZERO_BYTES);
    }

    function test_fuzz_positions(ICLPoolManager.ModifyLiquidityParams memory params, uint256 decreaseLiquidityDelta)
        public
    {
        uint256 tokenId;
        // it will revert if the tokenId does not exist
        {
            tokenId = lpm.nextTokenId();
            vm.expectRevert(IPositionManager.InvalidTokenID.selector);
            lpm.positions(tokenId);
        }

        (tokenId, params) =
            addFuzzyTwoSidedLiquidity(lpm, ActionConstants.MSG_SENDER, key, params, SQRT_RATIO_1_1, ZERO_BYTES);

        // make sure the position info is correctly returned after updating liquidity
        {
            (
                PoolKey memory _poolKey,
                int24 _tickLower,
                int24 _tickUpper,
                uint128 _liquidity,
                uint256 _feeGrowthInside0LastX128,
                uint256 _feeGrowthInside1LastX128,
                ICLSubscriber _subscriber
            ) = lpm.positions(tokenId);

            assertEq(PoolId.unwrap(_poolKey.toId()), PoolId.unwrap(key.toId()));
            assertEq(_tickLower, params.tickLower);
            assertEq(_tickUpper, params.tickUpper);
            assertEq(_liquidity, uint256(params.liquidityDelta));
            assertEq(_feeGrowthInside0LastX128, 0);
            assertEq(_feeGrowthInside1LastX128, 0);
            assertEq(address(_subscriber), address(0));
        }

        decreaseLiquidityDelta = bound(decreaseLiquidityDelta, 1, uint256(params.liquidityDelta));
        // swap to create fees
        uint256 swapAmount = 0.01e18;
        swap(key, false, int256(swapAmount), ZERO_BYTES);

        // make sure nothing is updated after swap
        {
            (
                PoolKey memory _poolKey,
                int24 _tickLower,
                int24 _tickUpper,
                uint128 _liquidity,
                uint256 _feeGrowthInside0LastX128,
                uint256 _feeGrowthInside1LastX128,
                ICLSubscriber _subscriber
            ) = lpm.positions(tokenId);

            assertEq(PoolId.unwrap(_poolKey.toId()), PoolId.unwrap(key.toId()));
            assertEq(_tickLower, params.tickLower);
            assertEq(_tickUpper, params.tickUpper);
            assertEq(_liquidity, uint256(params.liquidityDelta));
            assertEq(_feeGrowthInside0LastX128, 0);
            assertEq(_feeGrowthInside1LastX128, 0);
            assertEq(address(_subscriber), address(0));
        }

        decreaseLiquidity(tokenId, decreaseLiquidityDelta, ZERO_BYTES);

        // make sure the position info is correctly returned after updating liquidity
        {
            (
                PoolKey memory _poolKey,
                int24 _tickLower,
                int24 _tickUpper,
                uint128 _liquidity,
                uint256 _feeGrowthInside0LastX128,
                uint256 _feeGrowthInside1LastX128,
                ICLSubscriber _subscriber
            ) = lpm.positions(tokenId);

            assertEq(PoolId.unwrap(_poolKey.toId()), PoolId.unwrap(key.toId()));
            assertEq(_tickLower, params.tickLower);
            assertEq(_tickUpper, params.tickUpper);
            assertEq(_liquidity, uint256(params.liquidityDelta) - decreaseLiquidityDelta);
            assertEq(_feeGrowthInside0LastX128, 0);
            // feeGrowthInside1LastX128 is updated after swap
            assertNotEq(_feeGrowthInside1LastX128, 0);
            assertEq(address(_subscriber), address(0));
        }

        MockCLSubscriber subscriber = new MockCLSubscriber(lpm);
        lpm.subscribe(tokenId, address(subscriber), ZERO_BYTES);

        // make sure the position info is correctly returned after subscribing
        {
            (,,,,,, ICLSubscriber _subscriber) = lpm.positions(tokenId);

            assertEq(address(_subscriber), address(subscriber));
        }
    }
}
