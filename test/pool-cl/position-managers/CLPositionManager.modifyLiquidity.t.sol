// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {Hooks} from "infinity-core/src/libraries/Hooks.sol";
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
import {Tick} from "infinity-core/src/pool-cl/libraries/Tick.sol";
import {SafeCast} from "infinity-core/src/libraries/SafeCast.sol";
import {SafeCastTemp} from "../../../src/libraries/SafeCast.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/interfaces/IERC721.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {ReentrancyLock} from "../../../src/base/ReentrancyLock.sol";
import {CLPositionManager} from "../../../src/pool-cl/CLPositionManager.sol";
import {DeltaResolver} from "../../../src/base/DeltaResolver.sol";
import {ICLPositionManager} from "../../../src/pool-cl/interfaces/ICLPositionManager.sol";
import {Actions} from "../../../src/libraries/Actions.sol";
import {Planner, Plan} from "../../../src/libraries/Planner.sol";
import {FeeMath} from "../shared/FeeMath.sol";
import {PosmTestSetup} from "../shared/PosmTestSetup.sol";
import {ActionConstants} from "../../../src/libraries/ActionConstants.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {LiquidityFuzzers} from "../shared/fuzz/LiquidityFuzzers.sol";
import {MockFOT} from "../../mocks/MockFeeOnTransfer.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {BipsLibrary} from "../../../src/libraries/BipsLibrary.sol";

contract CLPositionManagerModifyLiquiditiesTest is Test, PosmTestSetup, LiquidityFuzzers {
    using CLPoolParametersHelper for bytes32;
    using BipsLibrary for uint256;

    MockERC20 fotToken;

    IVault vault;
    ICLPoolManager manager;

    PoolId poolId;
    PoolKey key;
    PoolKey nativeKey;
    PoolKey wethKey;
    PoolKey fotKey;

    struct PositionConfig {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
    }

    PositionConfig wethConfig;
    PositionConfig nativeConfig;
    PositionConfig fotConfig;

    address alice;
    uint256 alicePK;
    address bob;

    function setUp() public {
        (alice, alicePK) = makeAddrAndKey("ALICE");
        (bob,) = makeAddrAndKey("BOB");

        (currency0, currency1) = deployCurrencies(2 ** 255);

        (vault, manager) = createFreshManager();
        deployAndApproveRouter(vault, manager);

        // Requires currency0 and currency1 to be set in base Deployers contract.
        deployAndApprovePosm(vault, manager);

        // must deploy after posm
        // Deploys a hook which can accesses IPositionManager.modifyLiquiditiesWithoutUnlock
        deployPosmHookModifyLiquidities();

        key = PoolKey(
            currency0,
            currency1,
            IHooks(address(hookModifyLiquidities)),
            manager,
            3000,
            bytes32(uint256((60 << 16) | 0x00ff))
        );
        poolId = key.toId();
        manager.initialize(key, SQRT_RATIO_1_1);

        seedBalance(alice);
        approvePosmFor(alice);
        seedBalance(address(hookModifyLiquidities));

        nativeKey =
            PoolKey(CurrencyLibrary.NATIVE, currency1, IHooks(address(0)), manager, 3000, bytes32(uint256(60 << 16)));
        manager.initialize(nativeKey, SQRT_RATIO_1_1);

        wethKey = PoolKey(
            Currency.wrap(address(_WETH9)), currency1, IHooks(address(0)), manager, 3000, bytes32(uint256(60 << 16))
        );
        manager.initialize(wethKey, SQRT_RATIO_1_1);

        seedWeth(address(this));
        approvePosmCurrency(Currency.wrap(address(_WETH9)));

        fotToken = new MockFOT();
        fotToken.mint(address(this), STARTING_USER_BALANCE);
        approvePosmCurrency(Currency.wrap(address(fotToken)));

        fotKey = PoolKey(
            address(fotToken) > Currency.unwrap(currency1) ? currency1 : Currency.wrap(address(fotToken)),
            address(fotToken) > Currency.unwrap(currency1) ? Currency.wrap(address(fotToken)) : currency1,
            IHooks(address(0)),
            manager,
            3000,
            bytes32(uint256(60 << 16))
        );

        manager.initialize(fotKey, SQRT_RATIO_1_1);

        // seedWeth(address(this));
        wethConfig = PositionConfig({
            poolKey: wethKey, tickLower: TickMath.minUsableTick(60), tickUpper: TickMath.maxUsableTick(60)
        });
        nativeConfig = PositionConfig({poolKey: nativeKey, tickLower: -120, tickUpper: 120});
        fotConfig = PositionConfig({poolKey: fotKey, tickLower: -120, tickUpper: 120});

        vm.deal(address(this), 1000 ether);
    }

    /// @dev minting liquidity without approval is allowable
    function test_hook_mint() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -60, 60, initialLiquidity, address(this), ZERO_BYTES);

        // hook mints a new position in beforeSwap via hookData
        uint256 hookTokenId = lpm.nextTokenId();
        uint256 newLiquidity = 10e18;
        bytes memory calls = getMintEncoded(key, -60, 60, newLiquidity, address(hookModifyLiquidities), ZERO_BYTES);

        swap(key, true, -1e18, calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        // original liquidity unchanged
        assertEq(liquidity, initialLiquidity, "fuck");

        // hook minted its own position
        liquidity = lpm.getPositionLiquidity(hookTokenId);
        assertEq(liquidity, newLiquidity);

        assertEq(lpm.ownerOf(tokenId), address(this)); // original position owned by this contract
        assertEq(lpm.ownerOf(hookTokenId), address(hookModifyLiquidities)); // hook position owned by hook
    }

    /// @dev hook must be approved to increase liquidity
    function test_hook_increaseLiquidity() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -60, 60, initialLiquidity, address(this), ZERO_BYTES);

        // approve the hook for increasing liquidity
        lpm.approve(address(hookModifyLiquidities), tokenId);

        // hook increases liquidity in beforeSwap via hookData
        uint256 newLiquidity = 10e18;
        bytes memory calls = getIncreaseEncoded(tokenId, newLiquidity, ZERO_BYTES);

        swap(key, true, -1e18, calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, initialLiquidity + newLiquidity);
    }

    /// @dev hook can decrease liquidity with approval
    function test_hook_decreaseLiquidity() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -60, 60, initialLiquidity, address(this), ZERO_BYTES);

        // approve the hook for decreasing liquidity
        lpm.approve(address(hookModifyLiquidities), tokenId);

        // hook decreases liquidity in beforeSwap via hookData
        uint256 liquidityToDecrease = 10e18;
        bytes memory calls = getDecreaseEncoded(tokenId, liquidityToDecrease, ZERO_BYTES);

        swap(key, true, -1e18, calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        assertEq(liquidity, initialLiquidity - liquidityToDecrease);
    }

    /// @dev hook can collect liquidity with approval
    function test_hook_collect() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -60, 60, initialLiquidity, address(this), ZERO_BYTES);

        // approve the hook for collecting liquidity
        lpm.approve(address(hookModifyLiquidities), tokenId);

        // donate to generate revenue
        uint256 feeRevenue0 = 1e18;
        uint256 feeRevenue1 = 0.1e18;
        router.donate(key, feeRevenue0, feeRevenue1, ZERO_BYTES);

        uint256 balance0HookBefore = currency0.balanceOf(address(hookModifyLiquidities));
        uint256 balance1HookBefore = currency1.balanceOf(address(hookModifyLiquidities));

        // hook collects liquidity in beforeSwap via hookData
        bytes memory calls = getCollectEncoded(tokenId, ZERO_BYTES);
        swap(key, true, -1e18, calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        // liquidity unchanged
        assertEq(liquidity, initialLiquidity);

        // hook collected the fee revenue
        assertEq(currency0.balanceOf(address(hookModifyLiquidities)), balance0HookBefore + feeRevenue0 - 1 wei); // imprecision, core is keeping 1 wei
        assertEq(currency1.balanceOf(address(hookModifyLiquidities)), balance1HookBefore + feeRevenue1 - 1 wei);
    }

    /// @dev hook can burn liquidity with approval
    function test_hook_burn() public {
        // mint some liquidity that is NOT burned in beforeSwap
        mint(key, -60, 60, 100e18, address(this), ZERO_BYTES);

        // the position to be burned by the hook
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -60, 60, initialLiquidity, address(this), ZERO_BYTES);
        // TODO: make this less jank since HookModifyLiquidites also has delta saving capabilities
        // BalanceDelta mintDelta = getLastDelta();
        BalanceDelta mintDelta = hookModifyLiquidities.deltas(hookModifyLiquidities.numberDeltasReturned() - 1);

        // approve the hook for burning liquidity
        lpm.approve(address(hookModifyLiquidities), tokenId);

        uint256 balance0HookBefore = currency0.balanceOf(address(hookModifyLiquidities));
        uint256 balance1HookBefore = currency1.balanceOf(address(hookModifyLiquidities));

        // hook burns liquidity in beforeSwap via hookData
        bytes memory calls = getBurnEncoded(tokenId, ZERO_BYTES);
        swap(key, true, -1e18, calls);

        uint256 liquidity = lpm.getPositionLiquidity(tokenId);

        // liquidity burned
        assertEq(liquidity, 0);
        // 721 will revert if the token does not exist
        vm.expectRevert();
        lpm.ownerOf(tokenId);

        // hook claimed the burned liquidity
        assertEq(
            currency0.balanceOf(address(hookModifyLiquidities)),
            balance0HookBefore + uint128(-mintDelta.amount0() - 1 wei) // imprecision since core is keeping 1 wei
        );
        assertEq(
            currency1.balanceOf(address(hookModifyLiquidities)),
            balance1HookBefore + uint128(-mintDelta.amount1() - 1 wei)
        );
    }

    // --- Revert Scenarios --- //
    /// @dev Hook does not have approval so increasing liquidity should revert
    function test_hook_increaseLiquidity_revert() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -60, 60, initialLiquidity, address(this), ZERO_BYTES);

        // hook decreases liquidity in beforeSwap via hookData
        uint256 liquidityToAdd = 10e18;
        bytes memory calls = getIncreaseEncoded(tokenId, liquidityToAdd, ZERO_BYTES);

        // should revert because hook is not approved
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hookModifyLiquidities),
                hookModifyLiquidities.beforeSwap.selector,
                abi.encodeWithSelector(ICLPositionManager.NotApproved.selector, address(hookModifyLiquidities)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(key, true, -1e18, calls);
    }

    /// @dev Hook does not have approval so decreasing liquidity should revert
    function test_hook_decreaseLiquidity_revert() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -60, 60, initialLiquidity, address(this), ZERO_BYTES);

        // hook decreases liquidity in beforeSwap via hookData
        uint256 liquidityToDecrease = 10e18;
        bytes memory calls = getDecreaseEncoded(tokenId, liquidityToDecrease, ZERO_BYTES);

        // should revert because hook is not approved
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hookModifyLiquidities),
                hookModifyLiquidities.beforeSwap.selector,
                abi.encodeWithSelector(ICLPositionManager.NotApproved.selector, address(hookModifyLiquidities)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(key, true, -1e18, calls);
    }

    /// @dev hook does not have approval so collecting liquidity should revert
    function test_hook_collect_revert() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -60, 60, initialLiquidity, address(this), ZERO_BYTES);

        // donate to generate revenue
        uint256 feeRevenue0 = 1e18;
        uint256 feeRevenue1 = 0.1e18;
        router.donate(key, feeRevenue0, feeRevenue1, ZERO_BYTES);

        // hook collects liquidity in beforeSwap via hookData
        bytes memory calls = getCollectEncoded(tokenId, ZERO_BYTES);

        // should revert because hook is not approved
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hookModifyLiquidities),
                hookModifyLiquidities.beforeSwap.selector,
                abi.encodeWithSelector(ICLPositionManager.NotApproved.selector, address(hookModifyLiquidities)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(key, true, -1e18, calls);
    }

    /// @dev hook does not have approval so burning liquidity should revert
    function test_hook_burn_revert() public {
        // the position to be burned by the hook
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -60, 60, initialLiquidity, address(this), ZERO_BYTES);

        // hook burns liquidity in beforeSwap via hookData
        bytes memory calls = getBurnEncoded(tokenId, ZERO_BYTES);

        // should revert because hook is not approved
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hookModifyLiquidities),
                hookModifyLiquidities.beforeSwap.selector,
                abi.encodeWithSelector(ICLPositionManager.NotApproved.selector, address(hookModifyLiquidities)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(key, true, -1e18, calls);
    }

    /// @dev hook cannot re-enter modifyLiquiditiesWithoutUnlock in beforeRemoveLiquidity
    function test_hook_increaseLiquidity_reenter_revert() public {
        uint256 initialLiquidity = 100e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(key, -60, 60, initialLiquidity, address(this), ZERO_BYTES);

        uint256 newLiquidity = 10e18;

        // to be provided as hookData, so beforeAddLiquidity attempts to increase liquidity
        bytes memory hookCall = getIncreaseEncoded(tokenId, newLiquidity, ZERO_BYTES);
        bytes memory calls = getIncreaseEncoded(tokenId, newLiquidity, hookCall);

        // should revert because hook is re-entering modifyLiquiditiesWithoutUnlock
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hookModifyLiquidities),
                hookModifyLiquidities.beforeAddLiquidity.selector,
                abi.encodeWithSelector(ReentrancyLock.ContractLocked.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        lpm.modifyLiquidities(calls, _deadline);
    }

    function test_wrap_mint_usingContractBalance() public {
        // weth-currency1 pool initialized as wethKey
        // input: eth, currency1
        // modifyLiquidities call to mint liquidity weth and currency1
        // 1 _wrap with contract balance
        // 2 _mint
        // 3 _settle weth where the payer is the contract
        // 4 _close currency1, payer is caller
        // 5 _sweep weth since eth was entirely wrapped

        uint256 balanceEthBefore = address(this).balance;
        uint256 balance1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        uint256 tokenId = lpm.nextTokenId();

        uint128 liquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_RATIO_1_1,
            TickMath.getSqrtRatioAtTick(wethConfig.tickLower),
            TickMath.getSqrtRatioAtTick(wethConfig.tickUpper),
            100 ether,
            100 ether
        );

        Plan memory planner = Planner.init();
        planner.add(Actions.WRAP, abi.encode(ActionConstants.CONTRACT_BALANCE));
        planner.add(
            Actions.CL_MINT_POSITION,
            abi.encode(
                wethConfig.poolKey,
                wethConfig.tickLower,
                wethConfig.tickUpper,
                liquidityAmount,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );

        // weth9 payer is the contract
        planner.add(Actions.SETTLE, abi.encode(address(_WETH9), ActionConstants.OPEN_DELTA, false));
        // other currency can close normally
        planner.add(Actions.CLOSE_CURRENCY, abi.encode(currency1));
        // we wrapped the full contract balance so we sweep back in the wrapped currency
        planner.add(Actions.SWEEP, abi.encode(address(_WETH9), ActionConstants.MSG_SENDER));
        bytes memory actions = planner.encode();

        // Overestimate eth amount.
        lpm.modifyLiquidities{value: 102 ether}(actions, _deadline);

        uint256 balanceEthAfter = address(this).balance;
        uint256 balance1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        // The full eth amount was "spent" because some was wrapped into weth and refunded.
        assertApproxEqAbs(balanceEthBefore - balanceEthAfter, 102 ether, 1 wei);
        assertApproxEqAbs(balance1Before - balance1After, 100 ether, 1 wei);
        assertEq(lpm.ownerOf(tokenId), address(this));
        assertEq(lpm.getPositionLiquidity(tokenId), liquidityAmount);
        assertEq(_WETH9.balanceOf(address(lpm)), 0);
        assertEq(address(lpm).balance, 0);
    }

    function test_wrap_mint_openDelta() public {
        // weth-currency1 pool initialized as wethKey
        // input: eth, currency1
        // modifyLiquidities call to mint liquidity weth and currency1
        // 1 _mint
        // 2 _wrap with open delta
        // 3 _settle weth where the payer is the contract
        // 4 _close currency1, payer is caller
        // 5 _sweep eth since only the open delta amount was wrapped

        uint256 balanceEthBefore = address(this).balance;
        uint256 balance1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        uint256 tokenId = lpm.nextTokenId();

        uint128 liquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_RATIO_1_1,
            TickMath.getSqrtRatioAtTick(wethConfig.tickLower),
            TickMath.getSqrtRatioAtTick(wethConfig.tickUpper),
            100 ether,
            100 ether
        );

        Plan memory planner = Planner.init();

        planner.add(
            Actions.CL_MINT_POSITION,
            abi.encode(
                wethConfig.poolKey,
                wethConfig.tickLower,
                wethConfig.tickUpper,
                liquidityAmount,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );

        planner.add(Actions.WRAP, abi.encode(ActionConstants.OPEN_DELTA));

        // weth9 payer is the contract
        planner.add(Actions.SETTLE, abi.encode(address(_WETH9), ActionConstants.OPEN_DELTA, false));
        // other currency can close normally
        planner.add(Actions.CLOSE_CURRENCY, abi.encode(currency1));
        // we wrapped the open delta balance so we sweep back in the native currency
        planner.add(Actions.SWEEP, abi.encode(CurrencyLibrary.NATIVE, ActionConstants.MSG_SENDER));
        bytes memory actions = planner.encode();

        lpm.modifyLiquidities{value: 102 ether}(actions, _deadline);

        uint256 balanceEthAfter = address(this).balance;
        uint256 balance1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        // Approx 100 eth was spent because the extra 2 were refunded.
        assertApproxEqAbs(balanceEthBefore - balanceEthAfter, 100 ether, 1 wei);
        assertApproxEqAbs(balance1Before - balance1After, 100 ether, 1 wei);
        assertEq(lpm.ownerOf(tokenId), address(this));
        assertEq(lpm.getPositionLiquidity(tokenId), liquidityAmount);
        assertEq(_WETH9.balanceOf(address(lpm)), 0);
        assertEq(address(lpm).balance, 0);
    }

    function test_wrap_mint_usingExactAmount() public {
        // weth-currency1 pool initialized as wethKey
        // input: eth, currency1
        // modifyLiquidities call to mint liquidity weth and currency1
        // 1 _wrap with an amount
        // 2 _mint
        // 3 _settle weth where the payer is the contract
        // 4 _close currency1, payer is caller
        // 5 _sweep weth since eth was entirely wrapped

        uint256 balanceEthBefore = address(this).balance;
        uint256 balance1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        uint256 tokenId = lpm.nextTokenId();

        uint128 liquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_RATIO_1_1,
            TickMath.getSqrtRatioAtTick(wethConfig.tickLower),
            TickMath.getSqrtRatioAtTick(wethConfig.tickUpper),
            100 ether,
            100 ether
        );

        Plan memory planner = Planner.init();
        planner.add(Actions.WRAP, abi.encode(100 ether));
        planner.add(
            Actions.CL_MINT_POSITION,
            abi.encode(
                wethConfig.poolKey,
                wethConfig.tickLower,
                wethConfig.tickUpper,
                liquidityAmount,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );

        // weth9 payer is the contract
        planner.add(Actions.SETTLE, abi.encode(address(_WETH9), ActionConstants.OPEN_DELTA, false));
        // other currency can close normally
        planner.add(Actions.CLOSE_CURRENCY, abi.encode(currency1));
        // we wrapped all 100 eth so we sweep back in the wrapped currency for safety measure
        planner.add(Actions.SWEEP, abi.encode(address(_WETH9), ActionConstants.MSG_SENDER));
        bytes memory actions = planner.encode();

        lpm.modifyLiquidities{value: 100 ether}(actions, _deadline);

        uint256 balanceEthAfter = address(this).balance;
        uint256 balance1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        // The full eth amount was "spent" because some was wrapped into weth and refunded.
        assertApproxEqAbs(balanceEthBefore - balanceEthAfter, 100 ether, 1 wei);
        assertApproxEqAbs(balance1Before - balance1After, 100 ether, 1 wei);
        assertEq(lpm.ownerOf(tokenId), address(this));
        assertEq(lpm.getPositionLiquidity(tokenId), liquidityAmount);
        assertEq(_WETH9.balanceOf(address(lpm)), 0);
        assertEq(address(lpm).balance, 0);
    }

    function test_wrap_mint_revertsInsufficientBalance() public {
        // 1 _wrap with more eth than is sent in

        Plan memory planner = Planner.init();
        // Wrap more eth than what is sent in.
        planner.add(Actions.WRAP, abi.encode(101 ether));

        bytes memory actions = planner.encode();

        vm.expectRevert(DeltaResolver.InsufficientBalance.selector);
        lpm.modifyLiquidities{value: 100 ether}(actions, _deadline);
    }

    function test_unwrap_usingContractBalance() public {
        // weth-currency1 pool
        // output: eth, currency1
        // modifyLiquidities call to mint liquidity weth and currency1
        // 1 _burn
        // 2 _take where the weth is sent to the lpm contract
        // 3 _take where currency1 is sent to the msg sender
        // 4 _unwrap using contract balance
        // 5 _sweep where eth is sent to msg sender
        uint256 tokenId = lpm.nextTokenId();

        uint128 liquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_RATIO_1_1,
            TickMath.getSqrtRatioAtTick(wethConfig.tickLower),
            TickMath.getSqrtRatioAtTick(wethConfig.tickUpper),
            100 ether,
            100 ether
        );

        bytes memory actions = getMintEncoded(
            wethConfig.poolKey, wethConfig.tickLower, wethConfig.tickUpper, liquidityAmount, address(this), ZERO_BYTES
        );
        lpm.modifyLiquidities(actions, _deadline);

        assertEq(lpm.getPositionLiquidity(tokenId), liquidityAmount);

        uint256 balanceEthBefore = address(this).balance;
        uint256 balance1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        Plan memory planner = Planner.init();
        planner.add(
            Actions.CL_BURN_POSITION, abi.encode(tokenId, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );
        // take the weth to the position manager to be unwrapped
        planner.add(Actions.TAKE, abi.encode(address(_WETH9), ActionConstants.ADDRESS_THIS, ActionConstants.OPEN_DELTA));
        planner.add(
            Actions.TAKE,
            abi.encode(address(Currency.unwrap(currency1)), ActionConstants.MSG_SENDER, ActionConstants.OPEN_DELTA)
        );
        planner.add(Actions.UNWRAP, abi.encode(ActionConstants.CONTRACT_BALANCE));
        planner.add(Actions.SWEEP, abi.encode(CurrencyLibrary.NATIVE, ActionConstants.MSG_SENDER));

        actions = planner.encode();

        lpm.modifyLiquidities(actions, _deadline);

        uint256 balanceEthAfter = address(this).balance;
        uint256 balance1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        assertApproxEqAbs(balanceEthAfter - balanceEthBefore, 100 ether, 1 wei);
        assertApproxEqAbs(balance1After - balance1Before, 100 ether, 1 wei);
        assertEq(lpm.getPositionLiquidity(tokenId), 0);
        assertEq(_WETH9.balanceOf(address(lpm)), 0);
        assertEq(address(lpm).balance, 0);
    }

    function test_unwrap_openDelta_reinvest() public {
        // weth-currency1 pool rolls half to eth-currency1 pool
        // output: eth, currency1
        // modifyLiquidities call to mint liquidity weth and currency1
        // 1 _burn (weth-currency1)
        // 2 _take where the weth is sent to the lpm contract
        // 4 _mint to an eth pool
        // 4 _unwrap using open delta (pool managers ETH balance)
        // 3 _take where leftover currency1 is sent to the msg sender
        // 5 _settle eth open delta
        // 5 _sweep leftover weth

        uint256 tokenId = lpm.nextTokenId();

        uint128 liquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_RATIO_1_1,
            TickMath.getSqrtRatioAtTick(wethConfig.tickLower),
            TickMath.getSqrtRatioAtTick(wethConfig.tickUpper),
            100 ether,
            100 ether
        );

        bytes memory actions = getMintEncoded(
            wethConfig.poolKey, wethConfig.tickLower, wethConfig.tickUpper, liquidityAmount, address(this), ZERO_BYTES
        );
        lpm.modifyLiquidities(actions, _deadline);

        assertEq(lpm.getPositionLiquidity(tokenId), liquidityAmount);

        uint256 balanceEthBefore = address(this).balance;
        uint256 balance1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        uint256 balanceWethBefore = _WETH9.balanceOf(address(this));

        uint128 newLiquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_RATIO_1_1,
            TickMath.getSqrtRatioAtTick(nativeConfig.tickLower),
            TickMath.getSqrtRatioAtTick(nativeConfig.tickUpper),
            50 ether,
            50 ether
        );

        Plan memory planner = Planner.init();
        planner.add(
            Actions.CL_BURN_POSITION, abi.encode(tokenId, MIN_SLIPPAGE_DECREASE, MIN_SLIPPAGE_DECREASE, ZERO_BYTES)
        );
        // take the weth to the position manager to be unwrapped
        planner.add(Actions.TAKE, abi.encode(address(_WETH9), ActionConstants.ADDRESS_THIS, ActionConstants.OPEN_DELTA));
        planner.add(
            Actions.CL_MINT_POSITION,
            abi.encode(
                nativeConfig.poolKey,
                nativeConfig.tickLower,
                nativeConfig.tickUpper,
                newLiquidityAmount,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        planner.add(Actions.UNWRAP, abi.encode(ActionConstants.OPEN_DELTA));
        // pay the eth
        planner.add(Actions.SETTLE, abi.encode(CurrencyLibrary.NATIVE, ActionConstants.OPEN_DELTA, false));
        // take the leftover currency1
        planner.add(
            Actions.TAKE,
            abi.encode(address(Currency.unwrap(currency1)), ActionConstants.MSG_SENDER, ActionConstants.OPEN_DELTA)
        );
        planner.add(Actions.SWEEP, abi.encode(address(_WETH9), ActionConstants.MSG_SENDER));

        actions = planner.encode();

        lpm.modifyLiquidities(actions, _deadline);

        uint256 balanceEthAfter = address(this).balance;
        uint256 balance1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        uint256 balanceWethAfter = _WETH9.balanceOf(address(this));

        // Eth balance should not change.
        assertEq(balanceEthAfter, balanceEthBefore);
        // Only half of the original liquidity was reinvested.
        assertApproxEqAbs(balance1After - balance1Before, 50 ether, 1 wei);
        assertApproxEqAbs(balanceWethAfter - balanceWethBefore, 50 ether, 1 wei);
        assertEq(lpm.getPositionLiquidity(tokenId), 0);
        assertEq(_WETH9.balanceOf(address(lpm)), 0);
        assertEq(address(lpm).balance, 0);
    }

    function test_unwrap_revertsInsufficientBalance() public {
        // 1 _unwrap with more than is in the contract

        Plan memory planner = Planner.init();
        // unwraps more eth than what is in the contract
        planner.add(Actions.UNWRAP, abi.encode(101 ether));

        bytes memory actions = planner.encode();

        vm.expectRevert(DeltaResolver.InsufficientBalance.selector);
        lpm.modifyLiquidities(actions, _deadline);
    }

    function test_mintFromDeltas_fot() public {
        // Use a 1% fee.
        MockFOT(address(fotToken)).setFee(100);
        uint256 tokenId = lpm.nextTokenId();

        uint256 fotBalanceBefore = Currency.wrap(address(fotToken)).balanceOf(address(this));

        uint256 amountAfterTransfer = 990e18;
        uint256 amountToSendFot = 1000e18;

        (uint256 amount0, uint256 amount1) = fotKey.currency0 == Currency.wrap(address(fotToken))
            ? (amountToSendFot, amountAfterTransfer)
            : (amountAfterTransfer, amountToSendFot);

        // Calculcate the expected liquidity from the amounts after the transfer. They are the same for both currencies.
        uint256 expectedLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_RATIO_1_1,
            TickMath.getSqrtRatioAtTick(fotConfig.tickLower),
            TickMath.getSqrtRatioAtTick(fotConfig.tickUpper),
            amountAfterTransfer,
            amountAfterTransfer
        );

        Plan memory planner = Planner.init();
        planner.add(Actions.SETTLE, abi.encode(fotKey.currency0, amount0, true));
        planner.add(Actions.SETTLE, abi.encode(fotKey.currency1, amount1, true));
        planner.add(
            Actions.CL_MINT_POSITION_FROM_DELTAS,
            abi.encode(
                fotKey,
                fotConfig.tickLower,
                fotConfig.tickUpper,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );

        bytes memory plan = planner.encode();

        lpm.modifyLiquidities(plan, _deadline);

        uint256 fotBalanceAfter = Currency.wrap(address(fotToken)).balanceOf(address(this));

        assertEq(lpm.ownerOf(tokenId), address(this));
        assertEq(lpm.getPositionLiquidity(tokenId), expectedLiquidity);
        assertEq(fotBalanceBefore - fotBalanceAfter, 1000e18);
    }

    function test_increaseFromDeltas() public {
        uint128 initialLiquidity = 1000e18;
        uint256 tokenId = lpm.nextTokenId();
        mint(fotConfig.poolKey, fotConfig.tickLower, fotConfig.tickUpper, initialLiquidity, address(this), ZERO_BYTES);

        assertEq(lpm.ownerOf(tokenId), address(this));
        assertEq(lpm.getPositionLiquidity(tokenId), initialLiquidity);

        Plan memory planner = Planner.init();
        planner.add(Actions.SETTLE, abi.encode(fotKey.currency0, 10e18, true));
        planner.add(Actions.SETTLE, abi.encode(fotKey.currency1, 10e18, true));
        planner.add(
            Actions.CL_INCREASE_LIQUIDITY_FROM_DELTAS,
            abi.encode(tokenId, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );

        bytes memory actions = planner.encode();

        lpm.modifyLiquidities(actions, _deadline);

        uint128 newLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_RATIO_1_1,
            TickMath.getSqrtRatioAtTick(fotConfig.tickLower),
            TickMath.getSqrtRatioAtTick(fotConfig.tickUpper),
            10e18,
            10e18
        );

        assertEq(lpm.getPositionLiquidity(tokenId), initialLiquidity + newLiquidity);
    }

    function test_increaseFromDeltas_fot() public {
        uint128 initialLiquidity = 1000e18;
        uint256 tokenId = lpm.nextTokenId();

        mint(fotConfig.poolKey, fotConfig.tickLower, fotConfig.tickUpper, initialLiquidity, address(this), ZERO_BYTES);

        assertEq(lpm.ownerOf(tokenId), address(this));
        assertEq(lpm.getPositionLiquidity(tokenId), initialLiquidity);

        // Use a 1% fee.
        MockFOT(address(fotToken)).setFee(100);

        // Set the fee on transfer amount 1% higher.
        (uint256 amount0, uint256 amount1) =
            fotKey.currency0 == Currency.wrap(address(fotToken)) ? (100e18, 99e18) : (99e18, 100e18);

        Plan memory planner = Planner.init();
        planner.add(Actions.SETTLE, abi.encode(fotKey.currency0, amount0, true));
        planner.add(Actions.SETTLE, abi.encode(fotKey.currency1, amount1, true));
        planner.add(
            Actions.CL_INCREASE_LIQUIDITY_FROM_DELTAS,
            abi.encode(tokenId, MAX_SLIPPAGE_INCREASE, MAX_SLIPPAGE_INCREASE, ZERO_BYTES)
        );

        bytes memory actions = planner.encode();

        lpm.modifyLiquidities(actions, _deadline);

        (uint256 amount0AfterTransfer, uint256 amount1AfterTransfer) =
            fotKey.currency0 == Currency.wrap(address(fotToken)) ? (99e18, 100e18) : (100e18, 99e18);

        uint128 newLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_RATIO_1_1,
            TickMath.getSqrtRatioAtTick(fotConfig.tickLower),
            TickMath.getSqrtRatioAtTick(fotConfig.tickUpper),
            amount0AfterTransfer,
            amount1AfterTransfer
        );

        assertEq(lpm.getPositionLiquidity(tokenId), initialLiquidity + newLiquidity);
    }

    function test_fuzz_mintFromDeltas_burn_fot(
        uint256 bips,
        uint256 amount0,
        uint256 amount1,
        int24 tickLower,
        int24 tickUpper
    ) public {
        bips = bound(bips, 1, 10_000);
        MockFOT(address(fotToken)).setFee(bips);

        tickLower = int24(
            bound(
                tickLower,
                fotKey.parameters.getTickSpacing() * (TickMath.MIN_TICK / fotKey.parameters.getTickSpacing()),
                fotKey.parameters.getTickSpacing() * (TickMath.MAX_TICK / fotKey.parameters.getTickSpacing())
            )
        );
        tickUpper = int24(
            bound(
                tickUpper,
                fotKey.parameters.getTickSpacing() * (TickMath.MIN_TICK / fotKey.parameters.getTickSpacing()),
                fotKey.parameters.getTickSpacing() * (TickMath.MAX_TICK / fotKey.parameters.getTickSpacing())
            )
        );

        tickLower = fotKey.parameters.getTickSpacing() * (tickLower / fotKey.parameters.getTickSpacing());
        tickUpper = fotKey.parameters.getTickSpacing() * (tickUpper / fotKey.parameters.getTickSpacing());
        vm.assume(tickUpper > tickLower);

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(fotKey.toId());
        uint128 maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(fotKey.parameters.getTickSpacing());

        (uint256 maxAmount0, uint256 maxAmount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            maxLiquidityPerTick
        );

        maxAmount0 = maxAmount0 == 0 ? 1 : maxAmount0 > STARTING_USER_BALANCE ? STARTING_USER_BALANCE : maxAmount0;
        maxAmount1 = maxAmount1 == 0 ? 1 : maxAmount1 > STARTING_USER_BALANCE ? STARTING_USER_BALANCE : maxAmount1;
        amount0 = bound(amount0, 1, maxAmount0);
        amount1 = bound(amount1, 1, maxAmount1);

        uint256 tokenId = lpm.nextTokenId();

        uint256 balance0 = fotKey.currency0.balanceOf(address(this));
        uint256 balance1 = fotKey.currency1.balanceOf(address(this));
        uint256 balance0PM = fotKey.currency0.balanceOf(address(manager));
        uint256 balance1PM = fotKey.currency1.balanceOf(address(manager));

        Plan memory planner = Planner.init();
        planner.add(Actions.SETTLE, abi.encode(fotKey.currency0, amount0, true));
        planner.add(Actions.SETTLE, abi.encode(fotKey.currency1, amount1, true));
        planner.add(
            Actions.CL_MINT_POSITION_FROM_DELTAS,
            abi.encode(
                fotKey,
                tickLower,
                tickUpper,
                MAX_SLIPPAGE_INCREASE,
                MAX_SLIPPAGE_INCREASE,
                ActionConstants.MSG_SENDER,
                ZERO_BYTES
            )
        );
        // take the excess of each currency
        planner.add(Actions.TAKE_PAIR, abi.encode(fotKey.currency0, fotKey.currency1, ActionConstants.MSG_SENDER));

        bytes memory actions = planner.encode();

        bool currency0IsFOT = fotKey.currency0 == Currency.wrap(address(fotToken));
        bool positionIsEntirelyInOtherToken = currency0IsFOT
            ? tickUpper <= TickMath.getTickAtSqrtRatio(sqrtPriceX96)
            : tickLower >= TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        if (bips == 10000 && !positionIsEntirelyInOtherToken) {
            vm.expectRevert(CLPosition.CannotUpdateEmptyPosition.selector);
            lpm.modifyLiquidities(actions, _deadline);
        } else {
            // MINT FROM DELTAS.
            lpm.modifyLiquidities(actions, _deadline);

            uint256 balance0After = fotKey.currency0.balanceOf(address(this));
            uint256 balance1After = fotKey.currency1.balanceOf(address(this));
            uint256 balance0PMAfter = fotKey.currency0.balanceOf(address(vault));
            uint256 balance1PMAfter = fotKey.currency1.balanceOf(address(vault));

            // Calculate the expected resulting balances used to create liquidity after the fee is applied.
            uint256 amountInFOT = currency0IsFOT ? amount0 : amount1;
            uint256 expectedFee = amountInFOT.calculatePortion(bips);
            (uint256 expected0, uint256 expected1) = currency0IsFOT
                ? (balance0 - balance0After - expectedFee, balance1 - balance1After)
                : (balance0 - balance0After, balance1 - balance1After - expectedFee);

            assertEq(expected0, balance0PMAfter - balance0PM);
            assertEq(expected1, balance1PMAfter - balance1PM);

            // the liquidity that was created is a diff of the balance change
            uint128 expectedLiquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(tickLower),
                TickMath.getSqrtRatioAtTick(tickUpper),
                expected0,
                expected1
            );

            assertEq(lpm.ownerOf(tokenId), address(this));
            assertEq(lpm.getPositionLiquidity(tokenId), expectedLiquidity);

            // BURN.
            planner = Planner.init();
            // Note that the slippage does not include the fee from the transfer.
            planner.add(
                Actions.CL_BURN_POSITION,
                abi.encode(tokenId, expected0 == 0 ? 0 : expected0 - 1, expected1 == 0 ? 0 : expected1 - 1, ZERO_BYTES)
            );

            planner.add(Actions.TAKE_PAIR, abi.encode(fotKey.currency0, fotKey.currency1, ActionConstants.MSG_SENDER));

            actions = planner.encode();

            lpm.modifyLiquidities(actions, _deadline);

            assertEq(lpm.getPositionLiquidity(tokenId), 0);
        }
    }

    // to receive refunds of spare eth from test helpers
    receive() external payable {}
}
