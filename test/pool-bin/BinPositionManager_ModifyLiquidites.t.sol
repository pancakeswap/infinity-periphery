// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {BinPoolParametersHelper} from "infinity-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {SafeCast} from "infinity-core/src/pool-bin/libraries/math/SafeCast.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {BinPoolManager} from "infinity-core/src/pool-bin/BinPoolManager.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {PackedUint128Math} from "infinity-core/src/pool-bin/libraries/math/PackedUint128Math.sol";
import {TokenFixture} from "infinity-core/test/helpers/TokenFixture.sol";

import {DeltaResolver} from "../../src/base/DeltaResolver.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {IBinPositionManager} from "../../src/pool-bin/interfaces/IBinPositionManager.sol";
import {BinPositionManager} from "../../src/pool-bin/BinPositionManager.sol";
import {IBinFungibleToken} from "../../src/pool-bin/interfaces/IBinFungibleToken.sol";
import {Planner, Plan} from "../../src/libraries/Planner.sol";
import {BinTokenLibrary} from "../../src/pool-bin/libraries/BinTokenLibrary.sol";
import {BinLiquidityHelper} from "./helper/BinLiquidityHelper.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {BaseActionsRouter} from "../../src/base/BaseActionsRouter.sol";
import {SlippageCheck} from "../../src/libraries/SlippageCheck.sol";
import {BinHookHookData} from "./shared/BinHookHookData.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IWETH9} from "../../src/interfaces/external/IWETH9.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {BinPool} from "infinity-core/src/pool-bin/libraries/BinPool.sol";
import {MockFOT} from "../mocks/MockFeeOnTransfer.sol";

contract BinPositionManager_ModifyLiquidityTest is BinLiquidityHelper, TokenFixture, DeployPermit2 {
    using BinPoolParametersHelper for bytes32;
    using SafeCast for uint256;
    using BinTokenLibrary for PoolId;

    IWETH9 public _WETH9 = IWETH9(address(new WETH()));
    MockERC20 fotToken;

    bytes constant ZERO_BYTES = new bytes(0);
    uint256 _deadline = block.timestamp + 1;

    PoolKey key1;
    PoolKey key2; // with hookData hook

    PoolKey nativeKey;
    PoolKey wethKey;
    PoolKey fotKey;

    BinHookHookData hook;
    Vault vault;
    BinPoolManager poolManager;
    BinPositionManager binPm;
    IAllowanceTransfer permit2;
    MockERC20 token0;
    MockERC20 token1;

    bytes32 poolParam;
    address alice = makeAddr("alice");
    uint24 activeId = 2 ** 23; // where token0 and token1 price is the same

    function setUp() public {
        fotToken = new MockFOT();
        fotToken.mint(address(this), 10000 ether);

        vault = new Vault();
        poolManager = new BinPoolManager(IVault(address(vault)));
        vault.registerApp(address(poolManager));
        permit2 = IAllowanceTransfer(deployPermit2());
        initializeTokens();
        (token0, token1) = (MockERC20(Currency.unwrap(currency0)), MockERC20(Currency.unwrap(currency1)));

        binPm = new BinPositionManager(IVault(address(vault)), IBinPoolManager(address(poolManager)), permit2, _WETH9);
        key1 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: IBinPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam.setBinStep(10) // binStep
        });
        binPm.initializePool(key1, activeId);

        hook = new BinHookHookData();
        key2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(hook)),
            poolManager: IBinPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: bytes32(uint256(hook.getHooksRegistrationBitmap())).setBinStep(10) // binStep
        });
        binPm.initializePool(key2, activeId);

        nativeKey = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: IBinPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam.setBinStep(10) // binStep
        });
        binPm.initializePool(nativeKey, activeId);

        wethKey = PoolKey({
            currency0: Currency.wrap(address(_WETH9)),
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: IBinPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam.setBinStep(10) // binStep
        });
        binPm.initializePool(wethKey, activeId);

        fotKey = PoolKey({
            currency0: address(fotToken) > Currency.unwrap(currency1) ? currency1 : Currency.wrap(address(fotToken)),
            currency1: address(fotToken) > Currency.unwrap(currency1) ? Currency.wrap(address(fotToken)) : currency1,
            hooks: IHooks(address(0)),
            poolManager: IBinPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam.setBinStep(10) // binStep
        });
        binPm.initializePool(fotKey, activeId);

        // approval
        approveBinPm(address(this), key1, address(binPm), permit2);
        approveBinPm(alice, key1, address(binPm), permit2);
        approveBinPm(address(this), wethKey, address(binPm), permit2);
        approveBinPm(address(this), fotKey, address(binPm), permit2);

        // sufficient eth/weth
        vm.deal(address(this), 2000 ether);
        _WETH9.deposit{value: 1000 ether}();
    }

    function test_modifyLiquidity_beforeDeadline() public {
        vm.warp(1000);

        bytes memory payload = Planner.init().finalizeModifyLiquidityWithClose(key1);

        vm.expectRevert(abi.encodeWithSelector(IPositionManager.DeadlinePassed.selector, 900));
        binPm.modifyLiquidities(payload, 900);
    }

    function test_addLiquidity_inputLengthMisMatch() public {
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinPositionManager.BinAddLiquidityParams memory param;
        bytes memory payload;

        // distributionX mismatch
        param = _getAddParams(key1, binIds, 100, 100, activeId, address(this));
        param.distributionX = new uint256[](0);
        payload = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param)).encode();
        vm.expectRevert(BaseActionsRouter.InputLengthMismatch.selector);
        binPm.modifyLiquidities(payload, _deadline);

        // distributionY mismatch
        param = _getAddParams(key1, binIds, 100, 100, activeId, address(this));
        param.distributionY = new uint256[](0);
        payload = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param)).encode();
        vm.expectRevert(BaseActionsRouter.InputLengthMismatch.selector);
        binPm.modifyLiquidities(payload, _deadline);

        // deltaIds mismatch
        param = _getAddParams(key1, binIds, 100, 100, activeId, address(this));
        param.deltaIds = new int256[](0);
        payload = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param)).encode();
        vm.expectRevert(BaseActionsRouter.InputLengthMismatch.selector);
        binPm.modifyLiquidities(payload, _deadline);
    }

    function test_addLiquidity_inputActiveIdMismatch(uint256 input) public {
        input = bound(input, uint256(type(uint24).max) + 1, type(uint256).max);

        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinPositionManager.BinAddLiquidityParams memory param;
        bytes memory payload;

        // active id above type(uint24).max
        param = _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        param.activeIdDesired = input;
        payload = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param)).encode();
        vm.expectRevert(abi.encodeWithSelector(IBinPositionManager.AddLiquidityInputActiveIdMismatch.selector));
        binPm.modifyLiquidities(payload, _deadline);

        // active id normal, but slippage above type(uint24).max
        param = _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        param.idSlippage = input;
        payload = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param)).encode();
        vm.expectRevert(abi.encodeWithSelector(IBinPositionManager.AddLiquidityInputActiveIdMismatch.selector));
        binPm.modifyLiquidities(payload, _deadline);
    }

    function test_addLiquidity_idDesiredOverflow() public {
        uint24[] memory binIds = getBinIds(activeId, 3);

        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        param.activeIdDesired = activeId - 1;
        bytes memory payload = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param)).encode();
        vm.expectRevert(
            abi.encodeWithSelector(
                IBinPositionManager.IdSlippageCaught.selector, param.activeIdDesired, param.idSlippage, activeId
            )
        );
        binPm.modifyLiquidities(payload, _deadline);
    }

    function test_addLiquidity_MaximumAmountExceeded() public {
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinPositionManager.BinAddLiquidityParams memory param;
        bytes memory payload;

        // overwrite amount0Max
        param = _getAddParams(key1, binIds, 1 ether, 0.5 ether, activeId, alice);
        param.amount0Max = 0.9 ether;
        payload = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param)).encode();
        vm.expectRevert(abi.encodeWithSelector(SlippageCheck.MaximumAmountExceeded.selector, 0.9 ether, 1 ether));
        binPm.modifyLiquidities(payload, _deadline);

        // overwrite amount1Max
        param = _getAddParams(key1, binIds, 0.5 ether, 1 ether, activeId, alice);
        param.amount1Max = 0.8 ether;
        payload = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param)).encode();
        vm.expectRevert(abi.encodeWithSelector(SlippageCheck.MaximumAmountExceeded.selector, 0.8 ether, 1 ether));
        binPm.modifyLiquidities(payload, _deadline);

        // overwrite to within limit - case 1
        param = _getAddParams(key1, binIds, 2 ether, 3 ether, activeId, alice);
        param.amount0Max = 2 ether;
        param.amount1Max = 3 ether;
        Plan memory planner = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        payload = planner.finalizeModifyLiquidityWithClose(key1);
        binPm.modifyLiquidities(payload, _deadline);

        // overwrite to within limit - case 2
        param = _getAddParams(key1, binIds, 3 ether, 2 ether, activeId, alice);
        param.amount0Max = 3 ether;
        param.amount1Max = 2 ether;
        planner = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        payload = planner.finalizeModifyLiquidityWithClose(key1);
        binPm.modifyLiquidities(payload, _deadline);
    }

    function test_addLiquidity_SingleBin() public {
        uint24[] memory binIds = getBinIds(activeId, 1);
        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, address(this));
        Plan memory planner = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key1);

        binPm.modifyLiquidities(payload, _deadline);
        vm.snapshotGasLastCall("test_addLiquidity_SingleBin");
    }

    function test_addLiquidity_ThreeBins() public {
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        Plan memory planner = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key1);

        // building event to verify
        uint256[] memory liquidityMinted = new uint256[](binIds.length);
        bytes32 binReserves = PackedUint128Math.encode(0, 0); // binReserve=0 for new pool
        // since BinPool.MINIMUM_SHARE will be locked up, we need to exclude it from the expected value
        liquidityMinted[0] =
            calculateLiquidityMinted(binReserves, 0 ether, 0.5 ether, binIds[0], 10, 0) - BinPool.MINIMUM_SHARE;
        liquidityMinted[1] =
            calculateLiquidityMinted(binReserves, 0.5 ether, 0.5 ether, binIds[1], 10, 0) - BinPool.MINIMUM_SHARE;
        liquidityMinted[2] =
            calculateLiquidityMinted(binReserves, 0.5 ether, 0 ether, binIds[2], 10, 0) - BinPool.MINIMUM_SHARE;
        uint256[] memory tokenIds = new uint256[](binIds.length);
        for (uint256 i; i < binIds.length; i++) {
            tokenIds[i] = key1.toId().toTokenId(binIds[i]);
        }
        vm.expectEmit();
        emit IBinFungibleToken.TransferBatch(address(this), address(0), alice, tokenIds, liquidityMinted);

        binPm.modifyLiquidities(payload, _deadline);
        vm.snapshotGasLastCall("test_addLiquidity_ThreeBins");
    }

    function test_addLiquidity_OutsideActiveId() public {
        token1.mint(alice, 2 ether);

        // before: 2 ether
        assertEq(token1.balanceOf(alice), 2 ether);
        vm.startPrank(alice);

        uint24[] memory binIds = getBinIds(activeId - 10, 5); // 5 bins to the left
        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        Plan memory planner = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key1);

        binPm.modifyLiquidities(payload, _deadline);
        vm.snapshotGasLastCall("test_addLiquidity_OutsideActiveId");

        // after: 1 ether consumed
        assertEq(token1.balanceOf(alice), 1 ether);

        // verify nft minted to user
        bytes32 binReserves = PackedUint128Math.encode(0, 0); // binReserve=0 for new pool
        for (uint256 i; i < binIds.length; i++) {
            uint256 tokenId = key1.toId().toTokenId(binIds[i]);
            uint256 bal = binPm.balanceOf(alice, tokenId);
            uint256 expectedBal = calculateLiquidityMinted(binReserves, 0, 0.2 ether, binIds[i], 10, 0);
            // the share should be less than expected due to our lockup mechanism
            assertApproxEqAbs(bal, expectedBal, BinPool.MINIMUM_SHARE);
        }

        // re-add existing id, gas should be way cheaper
        binPm.modifyLiquidities(payload, _deadline);
        vm.snapshotGasLastCall("test_addLiquidity_OutsideActiveId");
    }

    function test_addLiquidity_HookData() public {
        // add liquidity
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(key2, binIds, 1 ether, 1 ether, activeId, address(this));
        param.hookData = "data";

        Plan memory planner = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key1);
        binPm.modifyLiquidities(payload, _deadline);

        assertEq(hook.beforeMintHookData(), param.hookData);
        assertEq(hook.afterMintHookData(), param.hookData);
        assertEq(hook.beforeBurnHookData(), "");
        assertEq(hook.afterBurnHookData(), "");
    }

    function test_positions() public {
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, alice);
        Plan memory planner = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key1);
        binPm.modifyLiquidities(payload, _deadline);

        for (uint256 i; i < binIds.length; i++) {
            uint256 tokenId = calculateTokenId(key1.toId(), binIds[i]);

            (PoolKey memory _poolKey, uint24 binId) = binPm.positions(tokenId);
            assertEq(PoolId.unwrap(_poolKey.toId()), PoolId.unwrap(key1.toId()));
            assertEq(binId, binIds[i]);
        }
    }

    function test_decreaseLiquidity_InputLengthMismatch() public {
        uint24[] memory binIds = getBinIds(activeId, 3);
        (, uint256[] memory liquidityMinted) = _addLiquidity(binPm, key1, binIds, activeId);

        IBinPositionManager.BinRemoveLiquidityParams memory param;
        bytes memory payload;

        // amount mismatch
        param = _getRemoveParams(key1, binIds, liquidityMinted, address(this));
        param.amounts = new uint256[](0);
        payload = Planner.init().add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param)).encode();
        vm.expectRevert(abi.encodeWithSelector(BaseActionsRouter.InputLengthMismatch.selector));
        binPm.modifyLiquidities(payload, _deadline);

        // id mismatch
        param = _getRemoveParams(key1, binIds, liquidityMinted, address(this));
        param.ids = new uint256[](0);
        payload = Planner.init().add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param)).encode();
        vm.expectRevert(abi.encodeWithSelector(BaseActionsRouter.InputLengthMismatch.selector));
        binPm.modifyLiquidities(payload, _deadline);
    }

    function test_decreaseLiquidity_MinimumAmountInsufficient() public {
        // add 1 ether of token0 and token1
        uint24[] memory binIds = getBinIds(activeId, 3);
        (, uint256[] memory liquidityMinted) = _addLiquidity(binPm, key1, binIds, activeId);

        IBinPositionManager.BinRemoveLiquidityParams memory param;
        bytes memory payload;

        // the actual amount is 1 ether - 2 for both tokens since we lock up some dust

        // amount0 min slippage
        param = _getRemoveParams(key1, binIds, liquidityMinted, address(this));
        param.amount0Min = 2 ether;
        payload = Planner.init().add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param)).encode();
        vm.expectRevert(
            abi.encodeWithSelector(SlippageCheck.MinimumAmountInsufficient.selector, param.amount0Min, 1 ether - 2)
        );
        binPm.modifyLiquidities(payload, _deadline);

        // amount1 min slippage
        param = _getRemoveParams(key1, binIds, liquidityMinted, address(this));
        param.amount1Min = 2 ether;
        payload = Planner.init().add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param)).encode();
        vm.expectRevert(
            abi.encodeWithSelector(SlippageCheck.MinimumAmountInsufficient.selector, param.amount1Min, 1 ether - 2)
        );
        binPm.modifyLiquidities(payload, _deadline);

        // amount and amount0 min slippage
        param = _getRemoveParams(key1, binIds, liquidityMinted, address(this));
        param.amount0Min = 2 ether;
        param.amount1Min = 2 ether;
        payload = Planner.init().add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param)).encode();
        vm.expectRevert(
            abi.encodeWithSelector(SlippageCheck.MinimumAmountInsufficient.selector, param.amount0Min, 1 ether - 2)
        );
        binPm.modifyLiquidities(payload, _deadline);
    }

    function test_decreaseLiquidity_threeBins() public {
        // add liquidity
        uint24[] memory binIds = getBinIds(activeId, 3);
        (uint256[] memory tokenIds, uint256[] memory liquidityMinted) = _addLiquidity(binPm, key1, binIds, activeId);

        // check initial token balance and verify liquidity minted greater than 0
        assertEq(token0.balanceOf(address(this)), 999 ether);
        assertEq(token1.balanceOf(address(this)), 999 ether);
        for (uint256 i; i < tokenIds.length; i++) {
            assertGt(binPm.balanceOf(address(this), tokenIds[i]), 0);
        }

        IBinPositionManager.BinRemoveLiquidityParams memory param =
            _getRemoveParams(key1, binIds, liquidityMinted, address(this));
        Plan memory planner = Planner.init().add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key1);

        // Verify event emitted
        vm.expectEmit();
        emit IBinFungibleToken.TransferBatch(address(this), address(this), address(0), tokenIds, liquidityMinted);

        binPm.modifyLiquidities(payload, _deadline);
        vm.snapshotGasLastCall("test_decreaseLiquidity_threeBins");

        // after remove liqudiity, there will be some dust locked in the contract to prevent inflation attack
        // 3 bins, left with (0, 1) (1, 1) (1, 0)
        assertEq(token0.balanceOf(address(this)), 1000 ether - 2);
        assertEq(token1.balanceOf(address(this)), 1000 ether - 2);

        // check reserve of each bin
        (uint128 binReserveX, uint128 binReserveY, uint256 binLiquidity, uint256 totalShares) =
            poolManager.getBin(key1.toId(), binIds[0]);
        assertEq(binReserveX, 0);
        assertEq(binReserveY, 1);
        assertGt(binLiquidity, 0);
        assertEq(totalShares, BinPool.MINIMUM_SHARE);

        (binReserveX, binReserveY, binLiquidity, totalShares) = poolManager.getBin(key1.toId(), binIds[1]);
        assertEq(binReserveX, 1);
        assertEq(binReserveY, 1);
        assertGt(binLiquidity, 0);
        assertEq(totalShares, BinPool.MINIMUM_SHARE);

        (binReserveX, binReserveY, binLiquidity, totalShares) = poolManager.getBin(key1.toId(), binIds[2]);
        assertEq(binReserveX, 1);
        assertEq(binReserveY, 0);
        assertGt(binLiquidity, 0);
        assertEq(totalShares, BinPool.MINIMUM_SHARE);
    }

    function test_decreaseLiquidity_threeBins_half() public {
        uint24[] memory binIds = getBinIds(activeId, 3);
        (, uint256[] memory liquidityMinted) = _addLiquidity(binPm, key1, binIds, activeId);

        IBinPositionManager.BinRemoveLiquidityParams memory param =
            _getRemoveParams(key1, binIds, liquidityMinted, address(this));
        for (uint256 i; i < param.amounts.length; i++) {
            param.amounts[i] = param.amounts[i] / 2;
        }
        Plan memory planner = Planner.init().add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key1);

        binPm.modifyLiquidities(payload, _deadline);
        vm.snapshotGasLastCall("test_decreaseLiquidity_threeBins_half");
    }

    function test_decreaseLiquidity_overBalance() public {
        uint24[] memory binIds = getBinIds(activeId, 3);
        (, uint256[] memory liquidityMinted) = _addLiquidity(binPm, key1, binIds, activeId);

        IBinPositionManager.BinRemoveLiquidityParams memory param =
            _getRemoveParams(key1, binIds, liquidityMinted, address(this));
        for (uint256 i; i < param.amounts.length; i++) {
            param.amounts[i] = param.amounts[i] * 2;
        }

        Plan memory planner = Planner.init().add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key1);

        vm.expectRevert(stdError.arithmeticError);
        binPm.modifyLiquidities(payload, _deadline);
    }

    function test_decreaseLiquidity_withoutSpenderApproval() public {
        uint24[] memory binIds = getBinIds(activeId, 3);
        (, uint256[] memory liquidityMinted) = _addLiquidity(binPm, key1, binIds, activeId);

        // alice try to remove on behalf of address(this)
        vm.startPrank(alice);
        IBinPositionManager.BinRemoveLiquidityParams memory param =
            _getRemoveParams(key1, binIds, liquidityMinted, address(this));
        Plan memory planner = Planner.init().add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key1);

        vm.expectRevert(
            abi.encodeWithSelector(IBinFungibleToken.BinFungibleToken_SpenderNotApproved.selector, address(this), alice)
        );
        binPm.modifyLiquidities(payload, _deadline);
    }

    function test_decreaseLiquidity_withSpenderApproval() public {
        uint24[] memory binIds = getBinIds(activeId, 3);
        (, uint256[] memory liquidityMinted) = _addLiquidity(binPm, key1, binIds, activeId);
        binPm.approveForAll(alice, true);

        // before, verify alice balance
        assertEq(token1.balanceOf(alice), 0 ether);
        assertEq(token1.balanceOf(alice), 0 ether);

        // alice try to remove on behalf of address(this)
        vm.startPrank(alice);
        IBinPositionManager.BinRemoveLiquidityParams memory param =
            _getRemoveParams(key1, binIds, liquidityMinted, address(this));
        Plan memory planner = Planner.init().add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key1);
        binPm.modifyLiquidities(payload, _deadline);

        // after, verify alice balance increased as tokens sent to alice
        // and there will be some dust locked in the contract to prevent inflation attack
        // 3 bins, left with (0, 1) (1, 1) (1, 0)
        assertEq(token1.balanceOf(alice), 1 ether - 2);
        assertEq(token1.balanceOf(alice), 1 ether - 2);

        // check reserve of each bin
        (uint128 binReserveX, uint128 binReserveY, uint256 binLiquidity, uint256 totalShares) =
            poolManager.getBin(key1.toId(), binIds[0]);
        assertEq(binReserveX, 0);
        assertEq(binReserveY, 1);
        assertGt(binLiquidity, 0);
        assertEq(totalShares, BinPool.MINIMUM_SHARE);

        (binReserveX, binReserveY, binLiquidity, totalShares) = poolManager.getBin(key1.toId(), binIds[1]);
        assertEq(binReserveX, 1);
        assertEq(binReserveY, 1);
        assertGt(binLiquidity, 0);
        assertEq(totalShares, BinPool.MINIMUM_SHARE);

        (binReserveX, binReserveY, binLiquidity, totalShares) = poolManager.getBin(key1.toId(), binIds[2]);
        assertEq(binReserveX, 1);
        assertEq(binReserveY, 0);
        assertGt(binLiquidity, 0);
        assertEq(totalShares, BinPool.MINIMUM_SHARE);
    }

    function test_removeLiquidity_hookData() public {
        // pre-req: add liquidity
        uint24[] memory binIds = getBinIds(activeId, 3);
        (, uint256[] memory liquidityMinted) = _addLiquidity(binPm, key2, binIds, activeId);

        // remove liquidity
        IBinPositionManager.BinRemoveLiquidityParams memory param =
            _getRemoveParams(key2, binIds, liquidityMinted, address(this));
        param.hookData = "data";
        Plan memory planner = Planner.init().add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key2);

        binPm.modifyLiquidities(payload, _deadline);

        assertEq(hook.beforeMintHookData(), "");
        assertEq(hook.afterMintHookData(), "");
        assertEq(hook.beforeBurnHookData(), param.hookData);
        assertEq(hook.afterBurnHookData(), param.hookData);
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

        uint24[] memory binIds = getBinIds(activeId, 1);
        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(wethKey, binIds, 1 ether, 1 ether, activeId, address(this));
        Plan memory planner = Planner.init();

        planner.add(Actions.WRAP, abi.encode(ActionConstants.CONTRACT_BALANCE));
        planner.add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        // weth9 payer is the contract
        planner.add(Actions.SETTLE, abi.encode(address(_WETH9), ActionConstants.OPEN_DELTA, false));
        // other currency can close normally
        planner.add(Actions.CLOSE_CURRENCY, abi.encode(currency1));
        // we wrapped the full contract balance so we sweep back in the wrapped currency
        planner.add(Actions.SWEEP, abi.encode(address(_WETH9), ActionConstants.MSG_SENDER));
        bytes memory actions = planner.encode();

        uint256 balanceEthBefore = address(this).balance;
        uint256 balance1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        binPm.modifyLiquidities{value: 1 ether}(actions, _deadline);

        uint256 balanceEthAfter = address(this).balance;
        uint256 balance1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        // The full eth amount was "spent" because some was wrapped into weth and refunded.
        assertApproxEqAbs(balanceEthBefore - balanceEthAfter, 1 ether, 1 wei);
        assertApproxEqAbs(balance1Before - balance1After, 1 ether, 1 wei);

        // no eth/weth left in the contract
        assertEq(_WETH9.balanceOf(address(binPm)), 0);
        assertEq(address(binPm).balance, 0);
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

        uint24[] memory binIds = getBinIds(activeId, 1);
        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(wethKey, binIds, 1 ether, 1 ether, activeId, address(this));
        Plan memory planner = Planner.init();

        planner.add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        planner.add(Actions.WRAP, abi.encode(ActionConstants.OPEN_DELTA));
        // weth9 payer is the contract
        planner.add(Actions.SETTLE, abi.encode(address(_WETH9), ActionConstants.OPEN_DELTA, false));
        // other currency can close normally
        planner.add(Actions.CLOSE_CURRENCY, abi.encode(currency1));
        // we wrapped the full contract balance so we sweep back in the wrapped currency
        planner.add(Actions.SWEEP, abi.encode(address(_WETH9), ActionConstants.MSG_SENDER));
        bytes memory actions = planner.encode();

        uint256 balanceEthBefore = address(this).balance;
        uint256 balance1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        binPm.modifyLiquidities{value: 1 ether}(actions, _deadline);

        uint256 balanceEthAfter = address(this).balance;
        uint256 balance1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        // The full eth amount was "spent" because some was wrapped into weth and refunded.
        assertApproxEqAbs(balanceEthBefore - balanceEthAfter, 1 ether, 1 wei);
        assertApproxEqAbs(balance1Before - balance1After, 1 ether, 1 wei);

        // no eth/weth left in the contract
        assertEq(_WETH9.balanceOf(address(binPm)), 0);
        assertEq(address(binPm).balance, 0);
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

        uint24[] memory binIds = getBinIds(activeId, 1);
        Plan memory planner = Planner.init();

        planner.add(Actions.WRAP, abi.encode(1 ether));
        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(wethKey, binIds, 1 ether, 1 ether, activeId, address(this));
        planner.add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        // weth9 payer is the contract
        planner.add(Actions.SETTLE, abi.encode(address(_WETH9), ActionConstants.OPEN_DELTA, false));
        // other currency can close normally
        planner.add(Actions.CLOSE_CURRENCY, abi.encode(currency1));
        // we wrapped the full contract balance so we sweep back in the wrapped currency
        planner.add(Actions.SWEEP, abi.encode(address(_WETH9), ActionConstants.MSG_SENDER));
        bytes memory actions = planner.encode();

        uint256 balanceEthBefore = address(this).balance;
        uint256 balance1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        binPm.modifyLiquidities{value: 1 ether}(actions, _deadline);

        uint256 balanceEthAfter = address(this).balance;
        uint256 balance1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        // The full eth amount was "spent" because some was wrapped into weth and refunded.
        assertApproxEqAbs(balanceEthBefore - balanceEthAfter, 1 ether, 1 wei);
        assertApproxEqAbs(balance1Before - balance1After, 1 ether, 1 wei);

        // no eth/weth left in the contract
        assertEq(_WETH9.balanceOf(address(binPm)), 0);
        assertEq(address(binPm).balance, 0);
    }

    function test_wrap_mint_revertsInsufficientBalance() public {
        // 1 _wrap with more eth than is sent in

        Plan memory planner = Planner.init();
        // Wrap more eth than what is sent in.
        planner.add(Actions.WRAP, abi.encode(101 ether));

        bytes memory actions = planner.encode();

        vm.expectRevert(DeltaResolver.InsufficientBalance.selector);
        binPm.modifyLiquidities{value: 100 ether}(actions, _deadline);
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

        uint24[] memory binIds = getBinIds(activeId, 1);
        (, uint256[] memory liquidityMinted) = _addLiquidity(binPm, wethKey, binIds, activeId);

        Plan memory planner = Planner.init();
        IBinPositionManager.BinRemoveLiquidityParams memory param =
            _getRemoveParams(wethKey, binIds, liquidityMinted, address(this));
        planner.add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param)).encode();
        // take the weth to the position manager to be unwrapped
        planner.add(Actions.TAKE, abi.encode(address(_WETH9), ActionConstants.ADDRESS_THIS, ActionConstants.OPEN_DELTA));
        planner.add(
            Actions.TAKE,
            abi.encode(address(Currency.unwrap(currency1)), ActionConstants.MSG_SENDER, ActionConstants.OPEN_DELTA)
        );
        planner.add(Actions.UNWRAP, abi.encode(ActionConstants.CONTRACT_BALANCE));
        planner.add(Actions.SWEEP, abi.encode(CurrencyLibrary.NATIVE, ActionConstants.MSG_SENDER));

        bytes memory actions = planner.encode();

        uint256 balanceEthBefore = address(this).balance;
        uint256 balance1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        binPm.modifyLiquidities(actions, _deadline);

        uint256 balanceEthAfter = address(this).balance;
        uint256 balance1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        assertApproxEqAbs(balanceEthAfter - balanceEthBefore, 1 ether, 1 wei);
        assertApproxEqAbs(balance1After - balance1Before, 1 ether, 1 wei);

        // no eth/weth left in the contract
        assertEq(_WETH9.balanceOf(address(binPm)), 0);
        assertEq(address(binPm).balance, 0);
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

        uint24[] memory binIds = getBinIds(activeId, 1);
        (, uint256[] memory liquidityMinted) = _addLiquidity(binPm, wethKey, binIds, activeId);

        Plan memory planner = Planner.init();
        IBinPositionManager.BinRemoveLiquidityParams memory param =
            _getRemoveParams(wethKey, binIds, liquidityMinted, address(this));
        planner.add(Actions.BIN_REMOVE_LIQUIDITY, abi.encode(param)).encode();
        // take the weth to the position manager to be unwrapped
        planner.add(Actions.TAKE, abi.encode(address(_WETH9), ActionConstants.ADDRESS_THIS, ActionConstants.OPEN_DELTA));

        IBinPositionManager.BinAddLiquidityParams memory param2 =
            _getAddParams(nativeKey, binIds, 0.5 ether, 0.5 ether, activeId, address(this));
        planner.add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param2));

        planner.add(Actions.UNWRAP, abi.encode(ActionConstants.OPEN_DELTA));
        // pay the eth
        planner.add(Actions.SETTLE, abi.encode(CurrencyLibrary.NATIVE, ActionConstants.OPEN_DELTA, false));
        // take the leftover currency1
        planner.add(
            Actions.TAKE,
            abi.encode(address(Currency.unwrap(currency1)), ActionConstants.MSG_SENDER, ActionConstants.OPEN_DELTA)
        );
        planner.add(Actions.SWEEP, abi.encode(address(_WETH9), ActionConstants.MSG_SENDER));

        bytes memory actions = planner.encode();

        uint256 balanceWethBefore = _WETH9.balanceOf(address(this));
        uint256 balance1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        binPm.modifyLiquidities(actions, _deadline);

        uint256 balanceWethAfter = _WETH9.balanceOf(address(this));
        uint256 balance1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        assertApproxEqAbs(balanceWethAfter - balanceWethBefore, 0.5 ether, 1 wei);
        assertApproxEqAbs(balance1After - balance1Before, 0.5 ether, 1 wei);

        // no eth/weth left in the contract
        assertEq(_WETH9.balanceOf(address(binPm)), 0);
        assertEq(address(binPm).balance, 0);
    }

    function test_unwrap_revertsInsufficientBalance() public {
        // 1 _unwrap with more than is in the contract

        Plan memory planner = Planner.init();
        // unwraps more eth than what is in the contract
        planner.add(Actions.UNWRAP, abi.encode(101 ether));

        bytes memory actions = planner.encode();

        vm.expectRevert(DeltaResolver.InsufficientBalance.selector);
        binPm.modifyLiquidities(actions, _deadline);
    }

    function test_transferLiquidityToken() public {
        uint24[] memory binIds = getBinIds(activeId, 1);
        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, address(this));
        Plan memory planner = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key1);
        binPm.modifyLiquidities(payload, _deadline);

        uint256 tokenId = key1.toId().toTokenId(binIds[0]);
        uint256 tokenBalance = binPm.balanceOf(address(this), tokenId);
        assertGt(tokenBalance, 0);

        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = tokenBalance;
        binPm.batchTransferFrom(address(this), makeAddr("someone"), ids, amounts);

        // verify transfer successful
        assertEq(binPm.balanceOf(address(this), tokenId), 0);
        assertEq(binPm.balanceOf(makeAddr("someone"), tokenId), tokenBalance);
    }

    function test_transferLiquidityToken_revertIfVaultLocked() public {
        uint24[] memory binIds = getBinIds(activeId, 1);
        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(key1, binIds, 1 ether, 1 ether, activeId, address(this));
        Plan memory planner = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key1);
        binPm.modifyLiquidities(payload, _deadline);

        uint256 tokenId = key1.toId().toTokenId(binIds[0]);
        uint256 tokenBalance = binPm.balanceOf(address(this), tokenId);
        assertGt(tokenBalance, 0);

        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = tokenBalance;
        // lock the vault so that the transfer fails
        vault.lock(
            abi.encodeCall(
                BinPositionManager_ModifyLiquidityTest._test_transferLiquidityToken_revertIfVaultLocked, (ids, amounts)
            )
        );
    }

    function _test_transferLiquidityToken_revertIfVaultLocked(uint256[] memory ids, uint256[] memory amounts) external {
        vm.expectRevert(IPositionManager.VaultMustBeUnlocked.selector);
        binPm.batchTransferFrom(address(this), makeAddr("someone"), ids, amounts);
    }

    function test_addLiquidityFromDeltas_fot() public {
        // Use a 1% fee.
        MockFOT(address(fotToken)).setFee(100);

        uint256 fotBalanceBefore = Currency.wrap(address(fotToken)).balanceOf(address(this));

        uint256 amountAfterTransfer = 990e18;
        uint256 amountToSendFot = 1000e18;

        (uint256 amount0, uint256 amount1) = fotKey.currency0 == Currency.wrap(address(fotToken))
            ? (amountToSendFot, amountAfterTransfer)
            : (amountAfterTransfer, amountToSendFot);

        Plan memory planner = Planner.init();
        planner.add(Actions.SETTLE, abi.encode(fotKey.currency0, amount0, true));
        planner.add(Actions.SETTLE, abi.encode(fotKey.currency1, amount1, true));

        uint24[] memory binIds = getBinIds(activeId, 1);
        IBinPositionManager.BinAddLiquidityParams memory _param = _getAddParams(
            fotKey, binIds, uint128(amountAfterTransfer), uint128(amountAfterTransfer), activeId, address(this)
        );

        IBinPositionManager.BinAddLiquidityFromDeltasParams memory param =
            IBinPositionManager.BinAddLiquidityFromDeltasParams({
                poolKey: _param.poolKey,
                amount0Max: _param.amount0Max,
                amount1Max: _param.amount1Max,
                activeIdDesired: _param.activeIdDesired,
                idSlippage: _param.idSlippage,
                deltaIds: _param.deltaIds,
                distributionX: _param.distributionX,
                distributionY: _param.distributionY,
                to: _param.to,
                hookData: _param.hookData
            });
        planner.add(Actions.BIN_ADD_LIQUIDITY_FROM_DELTAS, abi.encode(param));

        bytes memory plan = planner.encode();

        binPm.modifyLiquidities(plan, _deadline);

        uint256 fotBalanceAfter = Currency.wrap(address(fotToken)).balanceOf(address(this));

        // make sure bin position token was minted to the caller
        uint256 tokenId = fotKey.toId().toTokenId(binIds[0]);
        uint256 tokenBalance = binPm.balanceOf(address(this), tokenId);
        assertGt(tokenBalance, 0);

        // make sure the liquidity was added to the pool with considering the transfer fee
        (uint128 binReserveX, uint128 binReserveY,,) = poolManager.getBin(fotKey.toId(), binIds[0]);
        assertEq(binReserveX, amountAfterTransfer);
        assertEq(binReserveY, amountAfterTransfer);

        // make sure expected amount of fot was transferred
        assertEq(fotBalanceBefore - fotBalanceAfter, amountToSendFot);
    }

    function test_addLiquidityFromDeltas() public {
        uint256 currency0TokenBefore = key1.currency0.balanceOf(address(this));
        uint256 currency1TokenBefore = key1.currency1.balanceOf(address(this));

        uint256 amountToSend = 1000e18;

        Plan memory planner = Planner.init();
        planner.add(Actions.SETTLE, abi.encode(key1.currency0, amountToSend, true));
        planner.add(Actions.SETTLE, abi.encode(key1.currency1, amountToSend, true));

        uint24[] memory binIds = getBinIds(activeId, 1);
        IBinPositionManager.BinAddLiquidityParams memory _param =
            _getAddParams(key1, binIds, uint128(amountToSend), uint128(amountToSend), activeId, address(this));

        IBinPositionManager.BinAddLiquidityFromDeltasParams memory param =
            IBinPositionManager.BinAddLiquidityFromDeltasParams({
                poolKey: _param.poolKey,
                amount0Max: _param.amount0Max,
                amount1Max: _param.amount1Max,
                activeIdDesired: _param.activeIdDesired,
                idSlippage: _param.idSlippage,
                deltaIds: _param.deltaIds,
                distributionX: _param.distributionX,
                distributionY: _param.distributionY,
                to: _param.to,
                hookData: _param.hookData
            });
        planner.add(Actions.BIN_ADD_LIQUIDITY_FROM_DELTAS, abi.encode(param));

        bytes memory plan = planner.encode();

        binPm.modifyLiquidities(plan, _deadline);

        uint256 currency0TokenAfter = key1.currency0.balanceOf(address(this));
        uint256 currency1TokenAfter = key1.currency1.balanceOf(address(this));

        // make sure bin position token was minted to the caller
        uint256 tokenId = key1.toId().toTokenId(binIds[0]);
        uint256 tokenBalance = binPm.balanceOf(address(this), tokenId);
        assertGt(tokenBalance, 0);

        // make sure the liquidity was added to the pool with considering the transfer fee
        (uint128 binReserveX, uint128 binReserveY,,) = poolManager.getBin(key1.toId(), binIds[0]);
        assertEq(binReserveX, amountToSend);
        assertEq(binReserveY, amountToSend);

        // make sure expected amount was transferred
        assertEq(currency0TokenBefore - currency0TokenAfter, amountToSend);
        assertEq(currency1TokenBefore - currency1TokenAfter, amountToSend);
    }

    function testFuzz_addLiquidityFromDeltas_fot(uint256 bips, uint256 amount0, uint256 amount1) public {
        bips = bound(bips, 1, 10_000);
        MockFOT(address(fotToken)).setFee(bips);

        amount0 = bound(amount0, 0, 1000 ether);
        amount1 = bound(amount1, 0, 1000 ether);
        vm.assume(amount0 > 0 || amount1 > 0);

        uint8 binNum = 1;

        uint256 token0Before = fotKey.currency0.balanceOf(address(this));
        uint256 token1Before = fotKey.currency1.balanceOf(address(this));

        bool isCurrency0FotToken = fotKey.currency0 == Currency.wrap(address(fotToken));
        uint256 amount0AfterTransfer = amount0;
        uint256 amount1AfterTransfer = amount1;
        if (isCurrency0FotToken) {
            amount0AfterTransfer = amount0 - amount0 * bips / 10_000;
        } else {
            amount1AfterTransfer = amount1 - amount1 * bips / 10_000;
        }

        Plan memory planner = Planner.init();
        planner.add(Actions.SETTLE, abi.encode(fotKey.currency0, amount0, true));
        planner.add(Actions.SETTLE, abi.encode(fotKey.currency1, amount1, true));

        uint24[] memory binIds = getBinIds(activeId, binNum);
        IBinPositionManager.BinAddLiquidityParams memory _param = _getAddParams(
            fotKey, binIds, uint128(amount0AfterTransfer), uint128(amount1AfterTransfer), activeId, address(this)
        );
        IBinPositionManager.BinAddLiquidityFromDeltasParams memory param =
            IBinPositionManager.BinAddLiquidityFromDeltasParams({
                poolKey: _param.poolKey,
                amount0Max: _param.amount0Max,
                amount1Max: _param.amount1Max,
                activeIdDesired: _param.activeIdDesired,
                idSlippage: _param.idSlippage,
                deltaIds: _param.deltaIds,
                distributionX: _param.distributionX,
                distributionY: _param.distributionY,
                to: _param.to,
                hookData: _param.hookData
            });
        planner.add(Actions.BIN_ADD_LIQUIDITY_FROM_DELTAS, abi.encode(param));

        bytes memory plan = planner.encode();

        // if the fee is 100% and amount of normal currency is 0, the transaction will revert
        if (bips == 10000 && ((isCurrency0FotToken && amount1 == 0) || (!isCurrency0FotToken && amount0 == 0))) {
            vm.expectRevert();
            binPm.modifyLiquidities(plan, _deadline);
            return;
        }

        binPm.modifyLiquidities(plan, _deadline);

        uint256 token0After = fotKey.currency0.balanceOf(address(this));
        uint256 token1After = fotKey.currency1.balanceOf(address(this));

        // make sure bin position token was minted to the caller
        for (uint256 i = 0; i < binNum; i++) {
            uint256 tokenId = fotKey.toId().toTokenId(binIds[i]);
            uint256 tokenBalance = binPm.balanceOf(address(this), tokenId);
            assertGt(tokenBalance, 0);
        }

        // make sure the liquidity was added to the pool with considering the transfer fee
        for (uint256 i = 0; i < binNum; i++) {
            (uint128 binReserveX, uint128 binReserveY,,) = poolManager.getBin(fotKey.toId(), binIds[i]);
            assertEq(binReserveX, amount0AfterTransfer / binNum);
            assertEq(binReserveY, amount1AfterTransfer / binNum);
        }

        // make sure expected amount of fot was transferred
        assertEq(token0Before - token0After, amount0);
        assertEq(token1Before - token1After, amount1);
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory result) {
        // forward the call and bubble up the error if revert
        bool success;
        (success, result) = address(this).call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

    // to receive refunds of spare eth from test helpers
    receive() external payable {}
}
