// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {BinPoolManager} from "infinity-core/src/pool-bin/BinPoolManager.sol";
import {TokenFixture} from "infinity-core/test/helpers/TokenFixture.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {BinPoolParametersHelper} from "infinity-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {BinHelper} from "infinity-core/src/pool-bin/libraries/BinHelper.sol";
import {PriceHelper} from "infinity-core/src/pool-bin/libraries/PriceHelper.sol";
import {IPositionManager} from "../../src/interfaces/IPositionManager.sol";
import {BinPositionManager} from "../../src/pool-bin/BinPositionManager.sol";
import {IBinPositionManager} from "../../src/pool-bin/interfaces/IBinPositionManager.sol";
import {IWETH9} from "../../src/interfaces/external/IWETH9.sol";
import {BinLiquidityHelper} from "./helper/BinLiquidityHelper.sol";
import {Planner, Plan} from "../../src/libraries/Planner.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";
import {Permit2SignatureHelpers} from "../shared/Permit2SignatureHelpers.sol";
import {Permit2Forwarder} from "../../src/base/Permit2Forwarder.sol";

import {BinPositionManagerHelper} from "../../src/pool-bin/BinPositionManagerHelper.sol";
import {IBinPositionManagerWithERC1155} from "../../src/pool-bin/interfaces/IBinPositionManagerWithERC1155.sol";

contract BinPositionManagerHelperTest is
    Test,
    Permit2SignatureHelpers,
    TokenFixture,
    DeployPermit2,
    BinLiquidityHelper
{
    using BinPoolParametersHelper for bytes32;

    error ContractSizeTooLarge(uint256 diff);

    bytes constant ZERO_BYTES = new bytes(0);
    uint256 _deadline = block.timestamp + 1;

    Vault vault;
    BinPoolManager poolManager;
    BinPositionManager binPm;
    IAllowanceTransfer permit2;
    BinPositionManagerHelper binPmHelper;

    MockERC20 token0;
    MockERC20 token1;

    PoolKey key1; // initialized pool
    PoolKey key2; // uninitialized pool
    PoolKey key3; // initialized pool with native eth

    bytes32 poolParam;
    address alice = makeAddr("alice");
    uint24 activeId = 2 ** 23; // where token0 and token1 price is the same

    function setUp() public {
        vault = new Vault();
        poolManager = new BinPoolManager(IVault(address(vault)));
        vault.registerApp(address(poolManager));
        permit2 = IAllowanceTransfer(deployPermit2());
        initializeTokens();
        (token0, token1) = (MockERC20(Currency.unwrap(currency0)), MockERC20(Currency.unwrap(currency1)));

        binPm = new BinPositionManager(
            IVault(address(vault)), IBinPoolManager(address(poolManager)), permit2, IWETH9(address(0))
        );

        binPmHelper = new BinPositionManagerHelper(
            IBinPoolManager(address(poolManager)),
            IBinPositionManagerWithERC1155(address(binPm)),
            permit2,
            IWETH9(address(0))
        );

        key1 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: IBinPoolManager(address(poolManager)),
            fee: uint24(1000), // 0.1% pool
            parameters: poolParam.setBinStep(10) // binStep
        });
        binPmHelper.initializePool(key1, activeId);

        key2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: IBinPoolManager(address(poolManager)),
            fee: uint24(10_000), // 1% pool
            parameters: poolParam.setBinStep(100) // binStep
        });

        key3 = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: IBinPoolManager(address(poolManager)),
            fee: uint24(10_000), // 1% pool
            parameters: poolParam.setBinStep(100) // binStep
        });
        binPmHelper.initializePool(key3, activeId);

        // pre-req: alice approve permit2 -> binPmHelper for token0/token1
        approveBinPm(alice, key1, address(binPmHelper), permit2);
        approveBinPm(alice, key3, address(binPmHelper), permit2);
    }

    function test_bytecodeSize() public {
        vm.snapshotValue("BinPositionManagerHelper size", address(binPmHelper).code.length);

        if (address(binPmHelper).code.length > 24576) {
            revert ContractSizeTooLarge(address(binPmHelper).code.length - 24576);
        }
    }

    function test_addLiquidities_MinLiquidityParamsLengthMismatch() public {
        // step 1: prepare param liquidity. means roughly 3 bins
        // with the following tokens in each bin: [1.5 token1, 1.5 token1 + 1.5 token0, 1.5 token0]
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(key1, binIds, 3 ether, 3 ether, activeId, alice);

        // step 2: prepare minLiquidity param -- since id slippage, is 0, we can just check activeId minLiquidity
        uint24[] memory minLiquidityBinIds = new uint24[](1);
        uint256[] memory minLiquiditys = new uint256[](2);
        minLiquidityBinIds[0] = activeId;
        minLiquiditys[0] = 1e18;
        minLiquiditys[1] = 2e18; // mismatch length
        BinPositionManagerHelper.MinLiquidityParams memory minLiquidityParam =
            BinPositionManagerHelper.MinLiquidityParams({binIds: minLiquidityBinIds, minLiquidities: minLiquiditys});

        Plan memory planner = Planner.init();
        planner.add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        planner.add(Actions.SETTLE_PAIR, abi.encode(currency0, currency1));
        bytes memory payload = planner.encode();
        vm.prank(alice);
        vm.expectRevert(BinPositionManagerHelper.MinLiquidityParamsLengthMismatch.selector);
        binPmHelper.addLiquidities(payload, _deadline, minLiquidityParam);
    }

    function test_addLiquidities_InvalidBinId() public {
        // before
        token0.mint(alice, 4 ether);
        token1.mint(alice, 4 ether);
        assertEq(token0.balanceOf(alice), 4 ether);
        assertEq(token1.balanceOf(alice), 4 ether);

        // step 1: prepare param liquidity. means roughly 3 bins
        // with the following tokens in each bin: [1.5 token1, 1.5 token1 + 1.5 token0, 1.5 token0]
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(key1, binIds, 3 ether, 3 ether, activeId, alice);
        param.amount0Max = 3 ether * 1.1; // assume 10% slippage
        param.amount1Max = 3 ether * 1.1; // assume 10% slippage
        param.idSlippage = 0; // actveId is the same

        // step 2: prepare minLiquidity param -- since id slippage, is 0, we can just check activeId minLiquidity
        uint24[] memory minLiquidityBinIds = new uint24[](2);
        uint256[] memory minLiquiditys = new uint256[](2);
        uint256 price = PriceHelper.getPriceFromId(activeId, key1.parameters.getBinStep());
        minLiquidityBinIds[0] = activeId;
        minLiquidityBinIds[1] = activeId; // duplicate binId
        minLiquiditys[0] = BinHelper.getLiquidity(1.5 ether, 1.5 ether, price) * 9999 / 10_000; // 0.01% slippage
        minLiquiditys[1] = BinHelper.getLiquidity(1.5 ether, 1.5 ether, price) * 9999 / 10_000; // 0.01% slippage
        BinPositionManagerHelper.MinLiquidityParams memory minLiquidityParam =
            BinPositionManagerHelper.MinLiquidityParams({binIds: minLiquidityBinIds, minLiquidities: minLiquiditys});

        // Step 3: prepare and call
        Plan memory planner = Planner.init();
        planner.add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        planner.add(Actions.SETTLE_PAIR, abi.encode(currency0, currency1));
        bytes memory payload = planner.encode();
        vm.expectRevert(abi.encodeWithSelector(BinPositionManagerHelper.InvalidBinId.selector, activeId));
        vm.prank(alice);
        binPmHelper.addLiquidities(payload, _deadline, minLiquidityParam);
    }

    function test_addLiquidities_existingPool() public {
        // before
        token0.mint(alice, 4 ether);
        token1.mint(alice, 4 ether);
        assertEq(token0.balanceOf(alice), 4 ether);
        assertEq(token1.balanceOf(alice), 4 ether);

        // step 1: prepare param liquidity. means roughly 3 bins
        // with the following tokens in each bin: [1.5 token1, 1.5 token1 + 1.5 token0, 1.5 token0]
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(key1, binIds, 3 ether, 3 ether, activeId, alice);
        param.amount0Max = 3 ether * 1.1; // assume 10% slippage
        param.amount1Max = 3 ether * 1.1; // assume 10% slippage
        param.idSlippage = 0; // actveId is the same

        // step 2: prepare minLiquidity param -- since id slippage, is 0, we can just check activeId minLiquidity
        uint24[] memory minLiquidityBinIds = new uint24[](1);
        uint256[] memory minLiquiditys = new uint256[](1);
        uint256 price = PriceHelper.getPriceFromId(activeId, key1.parameters.getBinStep());
        minLiquidityBinIds[0] = activeId;
        minLiquiditys[0] = BinHelper.getLiquidity(1.5 ether, 1.5 ether, price) * 9999 / 10_000; // 0.01% slippage
        BinPositionManagerHelper.MinLiquidityParams memory minLiquidityParam =
            BinPositionManagerHelper.MinLiquidityParams({binIds: minLiquidityBinIds, minLiquidities: minLiquiditys});

        // Step 3: prepare and call
        Plan memory planner = Planner.init();
        planner.add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        planner.add(Actions.SETTLE_PAIR, abi.encode(currency0, currency1));
        bytes memory payload = planner.encode();
        vm.prank(alice);
        binPmHelper.addLiquidities(payload, _deadline, minLiquidityParam);
        vm.snapshotGasLastCall("test_addLiquidities_existingPool");

        // after
        assertEq(token0.balanceOf(alice), 1 ether); // initial 4 ether, then minus 3 ether added
        assertEq(token1.balanceOf(alice), 1 ether); // initial 4 ether, then minus 3 ether added
    }

    /// @dev mint to bob instead
    function test_addLiquidities_existingPool_bobReceiver() public {
        address bob = makeAddr("bob");

        // before
        token0.mint(alice, 4 ether);
        token1.mint(alice, 4 ether);
        assertEq(token0.balanceOf(alice), 4 ether);
        assertEq(token1.balanceOf(alice), 4 ether);

        // step 1: prepare param liquidity. means roughly 3 bins
        // with the following tokens in each bin: [1.5 token1, 1.5 token1 + 1.5 token0, 1.5 token0]
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(key1, binIds, 3 ether, 3 ether, activeId, bob);
        param.amount0Max = 3 ether * 1.1; // assume 10% slippage
        param.amount1Max = 3 ether * 1.1; // assume 10% slippage
        param.idSlippage = 0; // actveId is the same

        // step 2: prepare minLiquidity param -- since id slippage, is 0, we can just check activeId minLiquidity
        uint24[] memory minLiquidityBinIds = new uint24[](1);
        uint256[] memory minLiquiditys = new uint256[](1);
        uint256 price = PriceHelper.getPriceFromId(activeId, key1.parameters.getBinStep());
        minLiquidityBinIds[0] = activeId;
        minLiquiditys[0] = BinHelper.getLiquidity(1.5 ether, 1.5 ether, price) * 9999 / 10_000; // 0.01% slippage
        BinPositionManagerHelper.MinLiquidityParams memory minLiquidityParam =
            BinPositionManagerHelper.MinLiquidityParams({binIds: minLiquidityBinIds, minLiquidities: minLiquiditys});

        // Step 3: prepare and call
        Plan memory planner = Planner.init();
        planner.add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        planner.add(Actions.SETTLE_PAIR, abi.encode(currency0, currency1));
        bytes memory payload = planner.encode();
        vm.prank(alice);
        binPmHelper.addLiquidities(payload, _deadline, minLiquidityParam);
        vm.snapshotGasLastCall("test_addLiquidities_existingPool_bobReceiver");

        // after
        assertEq(token0.balanceOf(alice), 1 ether); // initial 4 ether, then minus 3 ether added
        assertEq(token1.balanceOf(alice), 1 ether); // initial 4 ether, then minus 3 ether added
    }

    /// @dev ensure add liquidity works for pool with currency0 as native token
    function test_addLiquidities_existingPool_nativeToken() public {
        // before
        vm.deal(alice, 4 ether);
        token1.mint(alice, 4 ether);
        assertEq(alice.balance, 4 ether);
        assertEq(token1.balanceOf(alice), 4 ether);

        // step 1: prepare param liquidity. means roughly 3 bins
        // with the following tokens in each bin: [1.5 token1, 1.5 token1 + 1.5 token0, 1.5 token0]
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(key3, binIds, 3 ether, 3 ether, activeId, alice);
        param.amount0Max = 3 ether * 1.1; // assume 10% slippage
        param.amount1Max = 3 ether * 1.1; // assume 10% slippage
        param.idSlippage = 0; // actveId is the same

        // step 2: prepare minLiquidity param -- since id slippage, is 0, we can just check activeId minLiquidity
        uint24[] memory minLiquidityBinIds = new uint24[](1);
        uint256[] memory minLiquiditys = new uint256[](1);
        uint256 price = PriceHelper.getPriceFromId(activeId, key3.parameters.getBinStep());
        minLiquidityBinIds[0] = activeId;
        minLiquiditys[0] = BinHelper.getLiquidity(1.5 ether, 1.5 ether, price) * 9999 / 10_000; // 0.01% slippage
        BinPositionManagerHelper.MinLiquidityParams memory minLiquidityParam =
            BinPositionManagerHelper.MinLiquidityParams({binIds: minLiquidityBinIds, minLiquidities: minLiquiditys});

        // Step 3: prepare and call
        Plan memory planner = Planner.init();
        planner.add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        planner.add(Actions.SETTLE_PAIR, abi.encode(key3.currency0, key3.currency1));
        planner.add(Actions.SWEEP, abi.encode(CurrencyLibrary.NATIVE, ActionConstants.MSG_SENDER));
        bytes memory payload = planner.encode();
        vm.prank(alice);
        binPmHelper.addLiquidities{value: 4 ether}(payload, _deadline, minLiquidityParam);
        vm.snapshotGasLastCall("test_addLiquidities_existingPool_nativeToken");

        // after
        assertEq(alice.balance, 1 ether); // initial 4 ether, then minus 3 ether added
        assertEq(token1.balanceOf(alice), 1 ether); // initial 4 ether, then minus 3 ether added
    }

    function test_addLiquidities_existingPool_slippage() public {
        // before
        token0.mint(alice, 4 ether);
        token1.mint(alice, 4 ether);

        // step 1: prepare param liquidity. means roughly 3 bins
        // with the following tokens in each bin: [1.5 token1, 1.5 token1 + 1.5 token0, 1.5 token0]
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(key1, binIds, 2 ether, 2 ether, activeId, alice);
        param.amount0Max = 2 ether * 1.1; // assume 10% slippage
        param.amount1Max = 2 ether * 1.1; // assume 10% slippage
        param.idSlippage = 0; // actveId is the same

        // step 2: prepare minLiquidity param -- since id slippage, is 0, we can just check activeId minLiquidity
        uint24[] memory minLiquidityBinIds = new uint24[](1);
        uint256[] memory minLiquiditys = new uint256[](1);
        uint256 price = PriceHelper.getPriceFromId(activeId, key1.parameters.getBinStep());
        minLiquidityBinIds[0] = activeId;
        // expected 1 liquidity more than default. its in 128.128 format
        minLiquiditys[0] = BinHelper.getLiquidity(1 ether, 1 ether, price) * 105 / 100; // expect 5% more
        BinPositionManagerHelper.MinLiquidityParams memory minLiquidityParam =
            BinPositionManagerHelper.MinLiquidityParams({binIds: minLiquidityBinIds, minLiquidities: minLiquiditys});

        // Step 3: prepare and call
        Plan memory planner = Planner.init();
        planner.add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        planner.add(Actions.SETTLE_PAIR, abi.encode(currency0, currency1));
        bytes memory payload = planner.encode();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                BinPositionManagerHelper.SlippageCheck.selector,
                minLiquidityBinIds[0],
                680564733841876926926749214863536422911999999999999999000 // roughly BinHelper.getLiquidity(1 ether, 1 ether, price)
            )
        );
        binPmHelper.addLiquidities(payload, _deadline, minLiquidityParam);
    }

    /// @dev example test with multiCall (to include initializePool)
    function test_addLiquidities_newPool() public {
        // before
        token0.mint(alice, 4 ether);
        token1.mint(alice, 4 ether);
        assertEq(token0.balanceOf(alice), 4 ether);
        assertEq(token1.balanceOf(alice), 4 ether);

        // step 1: prepare param liquidity. means roughly 3 bins
        // with the following tokens in each bin: [1.5 token1, 1.5 token1 + 1.5 token0, 1.5 token0]
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(key2, binIds, 3 ether, 3 ether, activeId, alice);
        param.amount0Max = 3 ether * 1.1; // assume 10% slippage
        param.amount1Max = 3 ether * 1.1; // assume 10% slippage
        param.idSlippage = 0; // actveId is the same

        // step 2: prepare minLiquidity param -- since id slippage, is 0, we can just check activeId minLiquidity
        uint24[] memory minLiquidityBinIds = new uint24[](1);
        uint256[] memory minLiquiditys = new uint256[](1);
        uint256 price = PriceHelper.getPriceFromId(activeId, key2.parameters.getBinStep());
        minLiquidityBinIds[0] = activeId;
        minLiquiditys[0] = BinHelper.getLiquidity(1.5 ether, 1.5 ether, price) * 9999 / 10_000; // 0.01% slippage
        BinPositionManagerHelper.MinLiquidityParams memory minLiquidityParam =
            BinPositionManagerHelper.MinLiquidityParams({binIds: minLiquidityBinIds, minLiquidities: minLiquiditys});

        // Step 3: prepare and call
        Plan memory planner = Planner.init();
        planner.add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        planner.add(Actions.SETTLE_PAIR, abi.encode(currency0, currency1));
        bytes memory payload = planner.encode();

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(binPmHelper.initializePool.selector, key2, activeId, ZERO_BYTES);
        calls[1] = abi.encodeWithSelector(binPmHelper.addLiquidities.selector, payload, _deadline, minLiquidityParam);
        vm.prank(alice);
        binPmHelper.multicall(calls);
        vm.snapshotGasLastCall("test_addLiquidities_newPool");

        // after
        assertEq(token0.balanceOf(alice), 1 ether); // initial 4 ether, then minus 3 ether added
        assertEq(token1.balanceOf(alice), 1 ether); // initial 4 ether, then minus 3 ether added
    }

    /// @dev example test with multiCall (to include initializePool and permit for new user)
    function test_addLiquidities_newPool_WithPermit() public {
        (address bob, uint256 bobPK) = makeAddrAndKey("bob");

        // before, require bob to approve token to permit2
        token0.mint(bob, 4 ether);
        token1.mint(bob, 4 ether);
        assertEq(token0.balanceOf(bob), 4 ether);
        assertEq(token1.balanceOf(bob), 4 ether);
        vm.startPrank(bob);
        token0.approve(address(permit2), type(uint256).max);
        token1.approve(address(permit2), type(uint256).max);
        vm.stopPrank();

        // step 1: prepare param liquidity. means roughly 3 bins
        // with the following tokens in each bin: [1.5 token1, 1.5 token1 + 1.5 token0, 1.5 token0]
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(key2, binIds, 3 ether, 3 ether, activeId, bob);
        param.amount0Max = 3 ether * 1.1; // assume 10% slippage
        param.amount1Max = 3 ether * 1.1; // assume 10% slippage
        param.idSlippage = 0; // actveId is the same

        // step 2: prepare minLiquidity param -- since id slippage, is 0, we can just check activeId minLiquidity
        uint24[] memory minLiquidityBinIds = new uint24[](1);
        uint256[] memory minLiquiditys = new uint256[](1);
        uint256 price = PriceHelper.getPriceFromId(activeId, key2.parameters.getBinStep());
        minLiquidityBinIds[0] = activeId;
        minLiquiditys[0] = BinHelper.getLiquidity(1.5 ether, 1.5 ether, price) * 9999 / 10_000; // 0.01% slippage
        BinPositionManagerHelper.MinLiquidityParams memory minLiquidityParam =
            BinPositionManagerHelper.MinLiquidityParams({binIds: minLiquidityBinIds, minLiquidities: minLiquiditys});

        // step 2b prepare the permit payload
        uint160 permitAmount = type(uint160).max;
        uint48 permitExpiration = uint48(block.timestamp + 10e18);
        uint48 permitNonce = 0;
        IAllowanceTransfer.PermitSingle memory permit0 =
            defaultERC20PermitAllowance(Currency.unwrap(currency0), permitAmount, permitExpiration, permitNonce);
        permit0.spender = address(binPmHelper);
        bytes memory sig0 = getPermitSignature(permit0, bobPK, permit2.DOMAIN_SEPARATOR());
        IAllowanceTransfer.PermitSingle memory permit1 =
            defaultERC20PermitAllowance(Currency.unwrap(currency1), permitAmount, permitExpiration, permitNonce);
        permit1.spender = address(binPmHelper);
        bytes memory sig1 = getPermitSignature(permit1, bobPK, permit2.DOMAIN_SEPARATOR());

        // Step 3: prepare addLiquidities payload
        Plan memory planner = Planner.init();
        planner.add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        planner.add(Actions.SETTLE_PAIR, abi.encode(currency0, currency1));
        bytes memory payload = planner.encode();

        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeWithSelector(binPmHelper.initializePool.selector, key2, activeId, ZERO_BYTES);
        calls[1] = abi.encodeWithSelector(Permit2Forwarder.permit.selector, bob, permit0, sig0);
        calls[2] = abi.encodeWithSelector(Permit2Forwarder.permit.selector, bob, permit1, sig1);
        calls[3] = abi.encodeWithSelector(binPmHelper.addLiquidities.selector, payload, _deadline, minLiquidityParam);
        vm.prank(bob);
        binPmHelper.multicall(calls);
        vm.snapshotGasLastCall("test_addLiquidities_newPool_WithPermit");

        // after
        assertEq(token0.balanceOf(bob), 1 ether); // initial 4 ether, then minus 3 ether added
        assertEq(token1.balanceOf(bob), 1 ether); // initial 4 ether, then minus 3 ether added
    }

    function test_addLiquidities_newPool_DuplicateAddLiquidity() external {
        // step 1: prepare param liquidity.
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(key1, binIds, 3 ether, 3 ether, activeId, alice);

        // step 2: prepare minLiquidity param -- since id slippage, is 0, we can just check activeId minLiquidity
        uint24[] memory minLiquidityBinIds = new uint24[](1);
        uint256[] memory minLiquiditys = new uint256[](1);
        BinPositionManagerHelper.MinLiquidityParams memory minLiquidityParam =
            BinPositionManagerHelper.MinLiquidityParams({binIds: minLiquidityBinIds, minLiquidities: minLiquiditys});

        // Step 3: prepare and call
        Plan memory planner = Planner.init();
        planner.add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        planner.add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        planner.add(Actions.SETTLE_PAIR, abi.encode(currency0, currency1));
        bytes memory payload = planner.encode();
        vm.prank(alice);
        vm.expectRevert(BinPositionManagerHelper.DuplicateAddLiquidity.selector);
        binPmHelper.addLiquidities(payload, _deadline, minLiquidityParam);
    }

    function test_addLiquidities_newPool_UnsupportedAction() external {
        // step 1: prepare param liquidity.
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(key1, binIds, 3 ether, 3 ether, activeId, alice);

        // step 2: prepare minLiquidity param -- since id slippage, is 0, we can just check activeId minLiquidity
        uint24[] memory minLiquidityBinIds = new uint24[](1);
        uint256[] memory minLiquiditys = new uint256[](1);
        BinPositionManagerHelper.MinLiquidityParams memory minLiquidityParam =
            BinPositionManagerHelper.MinLiquidityParams({binIds: minLiquidityBinIds, minLiquidities: minLiquiditys});

        // Step 3: prepare and call
        Plan memory planner = Planner.init();
        planner.add(Actions.BIN_ADD_LIQUIDITY_FROM_DELTAS, abi.encode(param));
        planner.add(Actions.SETTLE_PAIR, abi.encode(currency0, currency1));
        bytes memory payload = planner.encode();
        vm.prank(alice);
        vm.expectRevert(BinPositionManagerHelper.UnsupportedAction.selector);
        binPmHelper.addLiquidities(payload, _deadline, minLiquidityParam);
    }

    function test_addLiquidities_newPool_NoAddLiquidityAction() external {
        uint24[] memory minLiquidityBinIds = new uint24[](1);
        uint256[] memory minLiquiditys = new uint256[](1);
        BinPositionManagerHelper.MinLiquidityParams memory minLiquidityParam =
            BinPositionManagerHelper.MinLiquidityParams({binIds: minLiquidityBinIds, minLiquidities: minLiquiditys});

        // Prepare and call
        Plan memory planner = Planner.init();
        planner.add(Actions.SETTLE_PAIR, abi.encode(currency0, currency1));
        bytes memory payload = planner.encode();
        vm.prank(alice);
        vm.expectRevert(BinPositionManagerHelper.NoAddLiquidityAction.selector);
        binPmHelper.addLiquidities(payload, _deadline, minLiquidityParam);
    }

    function test_addLiquidities_newPool_MinLiquidityParamsLengthMismatch() external {
        // step 1: prepare param liquidity.
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinPositionManager.BinAddLiquidityParams memory param =
            _getAddParams(key1, binIds, 3 ether, 3 ether, activeId, alice);

        // step 2: prepare minLiquidity param -- since id slippage, is 0, we can just check activeId minLiquidity
        uint24[] memory minLiquidityBinIds = new uint24[](1);
        uint256[] memory minLiquiditys = new uint256[](2);
        BinPositionManagerHelper.MinLiquidityParams memory minLiquidityParam =
            BinPositionManagerHelper.MinLiquidityParams({binIds: minLiquidityBinIds, minLiquidities: minLiquiditys});

        // Step 3: prepare and call
        Plan memory planner = Planner.init();
        planner.add(Actions.BIN_ADD_LIQUIDITY, abi.encode(param));
        bytes memory payload = planner.encode();
        vm.prank(alice);
        vm.expectRevert(BinPositionManagerHelper.MinLiquidityParamsLengthMismatch.selector);
        binPmHelper.addLiquidities(payload, _deadline, minLiquidityParam);
    }

    function _getMinLiquidityParam(uint24[] memory binIds, uint256[] memory minLiquidities)
        internal
        pure
        returns (BinPositionManagerHelper.MinLiquidityParams memory)
    {
        require(binIds.length == minLiquidities.length, "BinPositionManagerHelper: length mismatch");

        return BinPositionManagerHelper.MinLiquidityParams({binIds: binIds, minLiquidities: minLiquidities});
    }
}
