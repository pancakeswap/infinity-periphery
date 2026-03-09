// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {LiquidityAmounts} from "infinity-core/test/pool-cl/helpers/LiquidityAmounts.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {CLPosition} from "infinity-core/src/pool-cl/libraries/CLPosition.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IMulticall} from "../../../src/interfaces/IMulticall.sol";
import {CLPositionManager} from "../../../src/pool-cl/CLPositionManager.sol";
import {IPositionManager} from "../../../src/interfaces/IPositionManager.sol";
import {DeltaResolver} from "../../../src/base/DeltaResolver.sol";
import {ICLPositionManager} from "../../../src/pool-cl/interfaces/ICLPositionManager.sol";
import {Actions} from "../../../src/libraries/Actions.sol";
import {Planner, Plan} from "../../../src/libraries/Planner.sol";
import {FeeMath} from "../shared/FeeMath.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";
import {ActionConstants} from "../../../src/libraries/ActionConstants.sol";
import {MockCLSubscriber} from "../mocks/MockCLSubscriber.sol";

contract CLPositionManagerGasTest is Test, PosmTestSetup {
    using FixedPointMathLib for uint256;
    using CLPoolParametersHelper for bytes32;

    IVault vault;
    ICLPoolManager manager;

    PoolId poolId;
    PoolKey key;
    PoolKey nativeKey;

    address alice;
    uint256 alicePK;
    address bob;
    uint256 bobPK;

    // expresses the fee as a wad (i.e. 3000 = 0.003e18 = 0.30%)
    uint256 FEE_WAD;

    MockCLSubscriber sub;

    function setUp() public {
        (alice, alicePK) = makeAddrAndKey("ALICE");
        (bob, bobPK) = makeAddrAndKey("BOB");

        // This is needed to receive return deltas from modifyLiquidity calls.
        deployPosmHookSavesDelta();

        (vault, manager, key, poolId) = createFreshPool(IHooks(address(hook)), 3000, SQRT_RATIO_1_1);
        currency0 = key.currency0;
        currency1 = key.currency1;

        deployAndApproveRouter(vault, manager);

        nativeKey = key;
        nativeKey.currency0 = CurrencyLibrary.NATIVE;
        manager.initialize(nativeKey, SQRT_RATIO_1_1);

        // (nativeKey,) = initPool(CurrencyLibrary.NATIVE, currency1, IHooks(hook), 3000, SQRT_RATIO_1_1, ZERO_BYTES);
        FEE_WAD = uint256(key.fee).mulDivDown(FixedPointMathLib.WAD, 1_000_000);

        // Requires currency0 and currency1 to be set in base Deployers contract.
        deployAndApprovePosm(vault, manager);

        // Give tokens to Alice and Bob.
        seedBalance(alice);
        seedBalance(bob);

        // Approve posm for Alice and bob.
        approvePosmFor(alice);
        approvePosmFor(bob);

        sub = new MockCLSubscriber(lpm);
    }

    function test_gas_mint_withClose() public {
        Plan memory planner = Planner.init()
            .add(
                Actions.CL_MINT_POSITION,
                abi.encode(
                    key,
                    -300,
                    300,
                    10_000 ether,
                    MAX_SLIPPAGE_INCREASE,
                    MAX_SLIPPAGE_INCREASE,
                    ActionConstants.MSG_SENDER,
                    ZERO_BYTES
                )
            );
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(key);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_mint_withClose");
    }

    function test_gas_mint_withSettlePair() public {
        Plan memory planner = Planner.init()
            .add(
                Actions.CL_MINT_POSITION,
                abi.encode(
                    key,
                    -300,
                    300,
                    10_000 ether,
                    MAX_SLIPPAGE_INCREASE,
                    MAX_SLIPPAGE_INCREASE,
                    address(this),
                    ZERO_BYTES
                )
            );
        bytes memory calls = planner.finalizeModifyLiquidityWithSettlePair(key);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_mint_withSettlePair");
    }

    function test_gas_mint_differentRanges() public {
        // Explicitly mint to a new range on the same pool.
        vm.startPrank(bob);
        mint(key, 0, 60, 10_000 ether, address(bob), ZERO_BYTES);
        vm.stopPrank();
        // Mint to a diff config, diff user.
        Plan memory planner = Planner.init()
            .add(
                Actions.CL_MINT_POSITION,
                abi.encode(
                    key,
                    -300,
                    300,
                    10_000 ether,
                    MAX_SLIPPAGE_INCREASE,
                    MAX_SLIPPAGE_INCREASE,
                    ActionConstants.MSG_SENDER,
                    ZERO_BYTES
                )
            );
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(key);
        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_mint_differentRanges");
    }

    function test_gas_mint_sameTickLower() public {
        // Explicitly mint to range whos tickLower is the same.
        vm.startPrank(bob);
        mint(key, -300, -60, 10_000 ether, address(bob), ZERO_BYTES);
        vm.stopPrank();
        // Mint to a diff config, diff user.
        Plan memory planner = Planner.init()
            .add(
                Actions.CL_MINT_POSITION,
                abi.encode(
                    key,
                    -300,
                    300,
                    10_000 ether,
                    MAX_SLIPPAGE_INCREASE,
                    MAX_SLIPPAGE_INCREASE,
                    ActionConstants.MSG_SENDER,
                    ZERO_BYTES
                )
            );
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(key);
        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_mint_sameTickLower");
    }

    function test_gas_mint_sameTickUpper() public {
        // Explicitly mint to range whos tickUpperis the same.
        vm.startPrank(bob);
        mint(key, 60, 300, 10_000 ether, address(bob), ZERO_BYTES);
        vm.stopPrank();
        // Mint to a diff config, diff user.
        Plan memory planner = Planner.init()
            .add(
                Actions.CL_MINT_POSITION,
                abi.encode(
                    key,
                    -300,
                    300,
                    10_000 ether,
                    MAX_SLIPPAGE_INCREASE,
                    MAX_SLIPPAGE_INCREASE,
                    ActionConstants.MSG_SENDER,
                    ZERO_BYTES
                )
            );
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(key);
        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_mint_sameTickUpper");
    }

    function test_gas_increaseLiquidity_erc20_withClose() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        Plan memory planner = Planner.init()
            .add(
                Actions.CL_INCREASE_LIQUIDITY,
                abi.encode(tokenId, 10_000 ether, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
            );

        bytes memory calls = planner.finalizeModifyLiquidityWithClose(key);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_increaseLiquidity_erc20_withClose");
    }

    function test_gas_increaseLiquidity_erc20_withSettlePair() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 10_000 ether, address(this), ZERO_BYTES);

        Plan memory planner = Planner.init()
            .add(
                Actions.CL_INCREASE_LIQUIDITY,
                abi.encode(tokenId, 10_000 ether, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
            );

        bytes memory calls = planner.finalizeModifyLiquidityWithSettlePair(key);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_increaseLiquidity_erc20_withSettlePair");
    }

    function test_gas_autocompound_exactUnclaimedFees() public {
        // Alice and Bob provide liquidity on the range
        // Alice uses her exact fees to increase liquidity (compounding)

        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;

        // alice provides liquidity
        vm.startPrank(alice);
        uint256 tokenIdAlice = lpm.nextTokenId();
        mint(key, -300, 300, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();

        // bob provides liquidity
        vm.startPrank(bob);
        mint(key, -300, 300, liquidityBob, bob, ZERO_BYTES);
        vm.stopPrank();

        // donate to create fees
        uint256 amountDonate = 0.2e18;
        router.donate(key, amountDonate, amountDonate, ZERO_BYTES);

        // alice uses her exact fees to increase liquidity
        uint256 tokensOwedAlice = amountDonate.mulDivDown(liquidityAlice, liquidityAlice + liquidityBob) - 1;

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(-300),
            TickMath.getSqrtRatioAtTick(300),
            tokensOwedAlice,
            tokensOwedAlice
        );

        Plan memory planner = Planner.init()
            .add(
                Actions.CL_INCREASE_LIQUIDITY,
                abi.encode(tokenIdAlice, liquidityDelta, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
            );
        // because its a perfect autocompound, the delta is exactly 0 and we dont need to "close" deltas
        bytes memory calls = planner.encode();

        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_autocompound_exactUnclaimedFees");
    }

    function test_gas_autocompound_clearExcess() public {
        // Alice and Bob provide liquidity on the range
        // Alice uses her exact fees to increase liquidity (compounding)

        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;

        // alice provides liquidity
        vm.startPrank(alice);
        uint256 tokenIdAlice = lpm.nextTokenId();
        mint(key, -300, 300, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();

        // bob provides liquidity
        vm.startPrank(bob);
        mint(key, -300, 300, liquidityBob, bob, ZERO_BYTES);
        vm.stopPrank();

        // donate to create fees
        uint256 amountDonate = 0.2e18;
        router.donate(key, amountDonate, amountDonate, ZERO_BYTES);

        // alice will use half of her fees to increase liquidity
        uint256 halfTokensOwedAlice = (amountDonate.mulDivDown(liquidityAlice, liquidityAlice + liquidityBob) - 1) / 2;

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(-300),
            TickMath.getSqrtRatioAtTick(300),
            halfTokensOwedAlice,
            halfTokensOwedAlice
        );

        // Alice elects to forfeit unclaimed tokens
        Plan memory planner = Planner.init();
        planner.add(
            Actions.CL_INCREASE_LIQUIDITY,
            abi.encode(tokenIdAlice, liquidityDelta, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(key.currency0, halfTokensOwedAlice + 1 wei));
        planner.add(Actions.CLEAR_OR_TAKE, abi.encode(key.currency1, halfTokensOwedAlice + 1 wei));
        bytes memory calls = planner.encode();

        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_autocompound_clearExcess");
    }

    // Autocompounding but the excess fees are taken to the user
    function test_gas_autocompound_excessFeesCredit() public {
        // Alice and Bob provide liquidity on the range
        // Alice uses her fees to increase liquidity. Excess fees are accounted to alice
        uint256 liquidityAlice = 3_000e18;
        uint256 liquidityBob = 1_000e18;

        // alice provides liquidity
        vm.startPrank(alice);
        uint256 tokenIdAlice = lpm.nextTokenId();
        mint(key, -300, 300, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();

        // bob provides liquidity
        vm.startPrank(bob);
        mint(key, -300, 300, liquidityBob, bob, ZERO_BYTES);
        vm.stopPrank();

        // donate to create fees
        uint256 amountDonate = 20e18;
        router.donate(key, amountDonate, amountDonate, ZERO_BYTES);

        // alice will use half of her fees to increase liquidity
        uint256 halfTokensOwedAlice = (amountDonate.mulDivDown(liquidityAlice, liquidityAlice + liquidityBob) - 1) / 2;

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        uint256 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(-300),
            TickMath.getSqrtRatioAtTick(300),
            halfTokensOwedAlice,
            halfTokensOwedAlice
        );

        Plan memory planner = Planner.init()
            .add(
                Actions.CL_INCREASE_LIQUIDITY,
                abi.encode(tokenIdAlice, liquidityDelta, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
            );

        bytes memory calls = planner.finalizeModifyLiquidityWithClose(key);

        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_autocompound_excessFeesCredit");
    }

    function test_gas_decreaseLiquidity_withClose() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        Plan memory planner = Planner.init()
            .add(
                Actions.CL_DECREASE_LIQUIDITY,
                abi.encode(tokenId, 10_000 ether, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
            );

        bytes memory calls = planner.finalizeModifyLiquidityWithClose(key);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_decreaseLiquidity_withClose");
    }

    function test_gas_decreaseLiquidity_withTakePair() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        Plan memory planner = Planner.init()
            .add(
                Actions.CL_DECREASE_LIQUIDITY,
                abi.encode(tokenId, 10_000 ether, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
            );

        bytes memory calls = planner.finalizeModifyLiquidityWithTakePair(key, address(this));
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_decreaseLiquidity_withTakePair");
    }

    function test_gas_multicall_initialize_mint() public {
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

        IMulticall(lpm).multicall(calls);
        vm.snapshotGasLastCall("test_gas_multicall_initialize_mint");
    }

    function test_gas_collect_withClose() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        // donate to create fee revenue
        router.donate(key, 0.2e18, 0.2e18, ZERO_BYTES);

        // Collect by calling decrease with 0.
        Plan memory planner = Planner.init()
            .add(
                Actions.CL_DECREASE_LIQUIDITY,
                abi.encode(tokenId, 0, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
            );

        bytes memory calls = planner.finalizeModifyLiquidityWithClose(key);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_collect_withClose");
    }

    function test_gas_collect_withTakePair() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        // donate to create fee revenue
        router.donate(key, 0.2e18, 0.2e18, ZERO_BYTES);

        // Collect by calling decrease with 0.
        Plan memory planner = Planner.init()
            .add(
                Actions.CL_DECREASE_LIQUIDITY,
                abi.encode(tokenId, 0, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
            );

        bytes memory calls = planner.finalizeModifyLiquidityWithTakePair(key, address(this));
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_collect_withTakePair");
    }

    // same-range gas tests
    function test_gas_sameRange_mint() public {
        mint(key, -300, 300, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        Plan memory planner = Planner.init()
            .add(
                Actions.CL_MINT_POSITION,
                abi.encode(
                    key,
                    -300,
                    300,
                    10_001 ether,
                    MAX_SLIPPAGE_INCREASE,
                    MAX_SLIPPAGE_INCREASE,
                    ActionConstants.MSG_SENDER,
                    ZERO_BYTES
                )
            );
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(key);
        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_sameRange_mint");
    }

    function test_gas_sameRange_decrease() public {
        // two positions of the same config, one of them decreases the entirety of the liquidity
        vm.startPrank(alice);
        mint(key, -300, 300, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);
        vm.stopPrank();

        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        Plan memory planner = Planner.init()
            .add(
                Actions.CL_DECREASE_LIQUIDITY,
                abi.encode(tokenId, 10_000 ether, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
            );

        bytes memory calls = planner.finalizeModifyLiquidityWithClose(key);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_sameRange_decrease");
    }

    function test_gas_sameRange_collect() public {
        // two positions of the same config, one of them collects all their fees
        vm.startPrank(alice);
        mint(key, -300, 300, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);
        vm.stopPrank();

        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        // donate to create fee revenue
        router.donate(key, 0.2e18, 0.2e18, ZERO_BYTES);

        Plan memory planner = Planner.init()
            .add(
                Actions.CL_DECREASE_LIQUIDITY,
                abi.encode(tokenId, 0, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
            );

        bytes memory calls = planner.finalizeModifyLiquidityWithClose(key);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_sameRange_collect");
    }

    function test_gas_burn_nonEmptyPosition_withClose() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        Plan memory planner = Planner.init()
            .add(
                Actions.CL_BURN_POSITION, abi.encode(tokenId, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
            );
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(key);

        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_burn_nonEmptyPosition_withClose");
    }

    function test_gas_burn_nonEmptyPosition_withTakePair() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        Plan memory planner = Planner.init()
            .add(
                Actions.CL_BURN_POSITION, abi.encode(tokenId, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
            );
        bytes memory calls = planner.finalizeModifyLiquidityWithTakePair(key, address(this));

        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_burn_nonEmptyPosition_withTakePair");
    }

    function test_gas_burnEmpty() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        decreaseLiquidity(tokenId, 10_000 ether, ZERO_BYTES);
        Plan memory planner = Planner.init()
            .add(
                Actions.CL_BURN_POSITION, abi.encode(tokenId, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
            );

        // There is no need to include CLOSE commands.
        bytes memory calls = planner.encode();
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_burnEmpty");
    }

    function test_gas_decrease_burnEmpty_batch() public {
        // Will be more expensive than not encoding a decrease and just encoding a burn.
        // ie. check this against PositionManager_burn_nonEmpty
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        Plan memory planner = Planner.init()
            .add(
                Actions.CL_DECREASE_LIQUIDITY,
                abi.encode(tokenId, 10_000 ether, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
            );
        planner.add(
            Actions.CL_BURN_POSITION, abi.encode(tokenId, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );

        // We must include CLOSE commands.
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(key);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_decrease_burnEmpty_batch");
    }

    // TODO: ERC6909 Support.
    function test_gas_increaseLiquidity_erc6909() public {}
    function test_gas_decreaseLiquidity_erc6909() public {}

    // Native Token Gas Tests
    function test_gas_mint_native() public {
        uint256 liquidityToAdd = 10_000 ether;
        bytes memory calls =
            getMintEncoded(nativeKey, -300, 300, liquidityToAdd, ActionConstants.MSG_SENDER, ZERO_BYTES);

        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_RATIO_1_1, TickMath.getSqrtRatioAtTick(-300), TickMath.getSqrtRatioAtTick(300), uint128(liquidityToAdd)
        );
        lpm.modifyLiquidities{value: amount0 + 1}(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_mint_native");
    }

    function test_gas_mint_native_excess_withClose() public {
        uint256 liquidityToAdd = 10_000 ether;

        Plan memory planner = Planner.init();
        planner.add(
            Actions.CL_MINT_POSITION,
            abi.encode(
                nativeKey,
                -300,
                300,
                liquidityToAdd,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        planner.add(Actions.CLOSE_CURRENCY, abi.encode(nativeKey.currency0));
        planner.add(Actions.CLOSE_CURRENCY, abi.encode(nativeKey.currency1));
        planner.add(Actions.SWEEP, abi.encode(CurrencyLibrary.NATIVE, ActionConstants.MSG_SENDER));
        bytes memory calls = planner.encode();

        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_RATIO_1_1, TickMath.getSqrtRatioAtTick(-300), TickMath.getSqrtRatioAtTick(300), uint128(liquidityToAdd)
        );
        // overpay on the native token
        lpm.modifyLiquidities{value: amount0 * 2}(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_mint_native_excess_withClose");
    }

    function test_gas_mint_native_excess_withSettlePair() public {
        uint256 liquidityToAdd = 10_000 ether;

        Plan memory planner = Planner.init();
        planner.add(
            Actions.CL_MINT_POSITION,
            abi.encode(
                nativeKey,
                -300,
                300,
                liquidityToAdd,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                address(this),
                ZERO_BYTES
            )
        );
        planner.add(Actions.SETTLE_PAIR, abi.encode(nativeKey.currency0, nativeKey.currency1));
        planner.add(Actions.SWEEP, abi.encode(CurrencyLibrary.NATIVE, address(this)));
        bytes memory calls = planner.encode();

        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_RATIO_1_1, TickMath.getSqrtRatioAtTick(-300), TickMath.getSqrtRatioAtTick(300), uint128(liquidityToAdd)
        );
        // overpay on the native token
        lpm.modifyLiquidities{value: amount0 * 2}(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_mint_native_excess_withSettlePair");
    }

    function test_gas_increase_native() public {
        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_RATIO_1_1, nativeKey, -300, 300, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        uint256 liquidityToAdd = 10_000 ether;
        bytes memory calls = getIncreaseEncoded(tokenId, liquidityToAdd, ZERO_BYTES);
        (uint256 amount0,) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_RATIO_1_1, TickMath.getSqrtRatioAtTick(-300), TickMath.getSqrtRatioAtTick(300), uint128(liquidityToAdd)
        );
        lpm.modifyLiquidities{value: amount0 + 1}(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_increase_native");
    }

    function test_gas_decrease_native() public {
        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_RATIO_1_1, nativeKey, -300, 300, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        uint256 liquidityToRemove = 10_000 ether;
        bytes memory calls = getDecreaseEncoded(tokenId, liquidityToRemove, ZERO_BYTES);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_decrease_native");
    }

    function test_gas_collect_native() public {
        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_RATIO_1_1, nativeKey, -300, 300, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        // donate to create fee revenue
        router.donate{value: 0.2e18}(nativeKey, 0.2e18, 0.2e18, ZERO_BYTES);

        bytes memory calls = getCollectEncoded(tokenId, ZERO_BYTES);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_collect_native");
    }

    function test_gas_burn_nonEmptyPosition_native_withClose() public {
        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_RATIO_1_1, nativeKey, -300, 300, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        Plan memory planner = Planner.init()
            .add(
                Actions.CL_BURN_POSITION, abi.encode(tokenId, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
            );
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(nativeKey);

        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_burn_nonEmptyPosition_native_withClose");
    }

    function test_gas_burn_nonEmptyPosition_native_withTakePair() public {
        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_RATIO_1_1, nativeKey, -300, 300, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        Plan memory planner = Planner.init()
            .add(
                Actions.CL_BURN_POSITION, abi.encode(tokenId, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
            );
        bytes memory calls = planner.finalizeModifyLiquidityWithTakePair(nativeKey, address(this));

        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_burn_nonEmptyPosition_native_withTakePair");
    }

    function test_gas_burnEmpty_native() public {
        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_RATIO_1_1, nativeKey, -300, 300, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        decreaseLiquidity(tokenId, 10_000 ether, ZERO_BYTES);
        Plan memory planner = Planner.init()
            .add(
                Actions.CL_BURN_POSITION, abi.encode(tokenId, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
            );

        // There is no need to include CLOSE commands.
        bytes memory calls = planner.encode();
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_burnEmpty_native");
    }

    function test_gas_decrease_burnEmpty_batch_native() public {
        // Will be more expensive than not encoding a decrease and just encoding a burn.
        // ie. check this against PositionManager_burn_nonEmpty
        uint256 tokenId = lpm.nextTokenId();
        mintWithNative(SQRT_RATIO_1_1, nativeKey, -300, 300, 10_000 ether, ActionConstants.MSG_SENDER, ZERO_BYTES);

        Plan memory planner = Planner.init()
            .add(
                Actions.CL_DECREASE_LIQUIDITY,
                abi.encode(tokenId, 10_000 ether, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
            );
        planner.add(Actions.CL_BURN_POSITION, abi.encode(tokenId, 0 wei, 0 wei, ZERO_BYTES));

        // We must include CLOSE commands.
        bytes memory calls = planner.finalizeModifyLiquidityWithClose(nativeKey);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_decrease_burnEmpty_batch_native");
    }

    function test_gas_permit() public {
        // alice permits for the first time
        uint256 liquidityAlice = 1e18;
        vm.startPrank(alice);
        uint256 tokenIdAlice = lpm.nextTokenId();
        mint(key, -300, 300, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();

        // alice gives operator permission to bob
        uint256 nonce = 1;
        bytes32 digest = getDigest(bob, tokenIdAlice, nonce, block.timestamp + 1);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(bob);
        lpm.permit(bob, tokenIdAlice, block.timestamp + 1, nonce, signature);
        vm.snapshotGasLastCall("test_gas_permit");
    }

    function test_gas_permit_secondPosition() public {
        // alice permits for her two tokens, benchmark the 2nd permit
        uint256 liquidityAlice = 1e18;
        vm.startPrank(alice);
        uint256 tokenIdAlice = lpm.nextTokenId();
        mint(key, -300, 300, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();

        // alice gives operator permission to bob
        uint256 nonce = 1;
        bytes32 digest = getDigest(bob, tokenIdAlice, nonce, block.timestamp + 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(bob);
        lpm.permit(bob, tokenIdAlice, block.timestamp + 1, nonce, signature);

        // alice creates another position
        vm.startPrank(alice);
        tokenIdAlice = lpm.nextTokenId();
        mint(key, -300, 300, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();

        // alice gives operator permission to bob
        nonce = 2;
        digest = getDigest(bob, tokenIdAlice, nonce, block.timestamp + 1);
        (v, r, s) = vm.sign(alicePK, digest);
        signature = abi.encodePacked(r, s, v);

        vm.prank(bob);
        lpm.permit(bob, tokenIdAlice, block.timestamp + 1, nonce, signature);
        vm.snapshotGasLastCall("test_gas_permit_secondPosition");
    }

    function test_gas_permit_twice() public {
        // alice permits the same token, twice
        address charlie = makeAddr("CHARLIE");

        uint256 liquidityAlice = 1e18;
        vm.startPrank(alice);
        uint256 tokenIdAlice = lpm.nextTokenId();
        mint(key, -300, 300, liquidityAlice, alice, ZERO_BYTES);
        vm.stopPrank();

        // alice gives operator permission to bob
        uint256 nonce = 1;
        bytes32 digest = getDigest(bob, tokenIdAlice, nonce, block.timestamp + 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(bob);
        lpm.permit(bob, tokenIdAlice, block.timestamp + 1, nonce, signature);

        // alice gives operator permission to charlie
        nonce = 2;
        digest = getDigest(charlie, tokenIdAlice, nonce, block.timestamp + 1);
        (v, r, s) = vm.sign(alicePK, digest);
        signature = abi.encodePacked(r, s, v);

        vm.prank(bob);
        lpm.permit(charlie, tokenIdAlice, block.timestamp + 1, nonce, signature);
        vm.snapshotGasLastCall("test_gas_permit_twice");
    }

    function test_gas_mint_settleWithBalance_sweep() public {
        uint256 liquidityAlice = 3_000e18;

        Plan memory planner = Planner.init();
        planner.add(
            Actions.CL_MINT_POSITION,
            abi.encode(key, -300, 300, liquidityAlice, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, alice, ZERO_BYTES)
        );
        planner.add(Actions.SETTLE, abi.encode(currency0, ActionConstants.OPEN_DELTA, false));
        planner.add(Actions.SETTLE, abi.encode(currency1, ActionConstants.OPEN_DELTA, false));
        planner.add(Actions.SWEEP, abi.encode(currency0, ActionConstants.MSG_SENDER));
        planner.add(Actions.SWEEP, abi.encode(currency1, ActionConstants.MSG_SENDER));

        currency0.transfer(address(lpm), 100e18);
        currency1.transfer(address(lpm), 100e18);

        bytes memory calls = planner.encode();

        vm.prank(alice);
        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_mint_settleWithBalance_sweep");
    }

    // Does not encode a take pair
    function test_gas_decrease_take_take() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 1e18, ActionConstants.MSG_SENDER, ZERO_BYTES);

        Plan memory plan = Planner.init();
        plan.add(
            Actions.CL_DECREASE_LIQUIDITY,
            abi.encode(tokenId, 1e18, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );
        bytes memory calls = plan.finalizeModifyLiquidityWithTake(key, ActionConstants.MSG_SENDER);

        lpm.modifyLiquidities(calls, _deadline);
        vm.snapshotGasLastCall("test_gas_decrease_take_take");
    }

    function test_gas_subscribe_unsubscribe() public {
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -300, 300, 1e18, ActionConstants.MSG_SENDER, ZERO_BYTES);

        lpm.subscribe(tokenId, address(sub), ZERO_BYTES);
        vm.snapshotGasLastCall("test_gas_subscribe_unsubscribe_sub");

        lpm.unsubscribe(tokenId);
        vm.snapshotGasLastCall("test_gas_subscribe_unsubscribe_ubsub");
    }

    receive() external payable {}
}
