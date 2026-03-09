// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {BinPool} from "infinity-core/src/pool-bin/libraries/BinPool.sol";
import {BinPoolManager} from "infinity-core/src/pool-bin/BinPoolManager.sol";
import {BinPoolParametersHelper} from "infinity-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {BinPositionManager} from "../../src/pool-bin/BinPositionManager.sol";
import {IBinPositionManager} from "../../src/pool-bin/interfaces/IBinPositionManager.sol";
import {BinLiquidityHelper} from "./helper/BinLiquidityHelper.sol";
import {SafeCast} from "infinity-core/src/pool-bin/libraries/math/SafeCast.sol";
import {MockInfinityRouter} from "../mocks/MockInfinityRouter.sol";
import {IBinRouterBase} from "../../src/pool-bin/interfaces/IBinRouterBase.sol";
import {PathKey} from "../../src/libraries/PathKey.sol";
import {Plan, Planner} from "../../src/libraries/Planner.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {SafeCallback} from "../../src/base/SafeCallback.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IQuoter} from "../../src/interfaces/IQuoter.sol";
import {IBinQuoter, BinQuoter} from "../../src/pool-bin/lens/BinQuoter.sol";
import {QuoterRevert} from "../../src/libraries/QuoterRevert.sol";
import {IWETH9} from "../../src/interfaces/external/IWETH9.sol";

contract BinQuoterTest is Test, BinLiquidityHelper, DeployPermit2 {
    using SafeCast for uint256;
    using BinPoolParametersHelper for bytes32;

    error ContractSizeTooLarge(uint256 diff);

    bytes constant ZERO_BYTES = new bytes(0);
    uint256 _deadline = block.timestamp + 1;

    IVault public vault;
    PoolKey key;
    PoolKey key2;
    PoolKey key3;
    BinPoolManager poolManager;
    BinPositionManager binPm;
    BinQuoter quoter;

    MockERC20 token0;
    MockERC20 token1;
    MockERC20 token2;
    bytes32 poolParam;
    MockInfinityRouter public router;
    IAllowanceTransfer permit2;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint24 activeId = 2 ** 23; // where token0 and token1 price is the same

    Plan plan;

    function setUp() public {
        plan = Planner.init();
        vault = new Vault();
        poolManager = new BinPoolManager(IVault(address(vault)));
        vault.registerApp(address(poolManager));
        router = new MockInfinityRouter(vault, ICLPoolManager(address(0)), IBinPoolManager(address(poolManager)));
        permit2 = IAllowanceTransfer(deployPermit2());
        binPm = new BinPositionManager(
            IVault(address(vault)), IBinPoolManager(address(poolManager)), permit2, IWETH9(address(0))
        );
        quoter = new BinQuoter(address(poolManager));

        token0 = new MockERC20("TestA", "A", 18);
        token1 = new MockERC20("TestB", "B", 18);
        token2 = new MockERC20("TestC", "C", 18);

        // sort token
        (token0, token1) = token0 > token1 ? (token1, token0) : (token0, token1);
        if (token2 < token0) {
            (token0, token1, token2) = (token2, token0, token1);
        } else if (token2 < token1) {
            (token1, token2) = (token2, token1);
        }

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            hooks: IHooks(address(0)),
            poolManager: IBinPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam.setBinStep(10) // binStep
        });
        key2 = PoolKey({
            currency0: Currency.wrap(address(token1)),
            currency1: Currency.wrap(address(token2)),
            hooks: IHooks(address(0)),
            poolManager: IBinPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam.setBinStep(10) // binStep
        });
        key3 = PoolKey({
            currency0: Currency.wrap(address(address(0))),
            currency1: Currency.wrap(address(token0)),
            hooks: IHooks(address(0)),
            poolManager: IBinPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam.setBinStep(10) // binStep
        });

        poolManager.initialize(key, activeId);
        poolManager.initialize(key2, activeId);
        poolManager.initialize(key3, activeId);

        approveBinPmForCurrency(alice, Currency.wrap(address(token0)), address(binPm), permit2);
        approveBinPmForCurrency(alice, Currency.wrap(address(token1)), address(binPm), permit2);
        approveBinPmForCurrency(alice, Currency.wrap(address(token2)), address(binPm), permit2);

        vm.startPrank(alice);
        token0.approve(address(router), 1000 ether);
        token1.approve(address(router), 1000 ether);
        token2.approve(address(router), 1000 ether);

        // add liquidity, 10 ether across 3 bins for both pool
        token0.mint(alice, 10 ether);
        token1.mint(alice, 20 ether); // 20 as token1 is used in both pool
        token2.mint(alice, 10 ether);
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinPositionManager.BinAddLiquidityParams memory addParams;
        addParams = _getAddParams(key, binIds, 10 ether, 10 ether, activeId, alice);
        Plan memory planner = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(addParams));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(key);
        binPm.modifyLiquidities(payload, _deadline);

        addParams = _getAddParams(key2, binIds, 10 ether, 10 ether, activeId, alice);
        planner = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(addParams));
        payload = planner.finalizeModifyLiquidityWithClose(key2);
        binPm.modifyLiquidities(payload, _deadline);

        // add liquidity for ETH-token0 native pool (10 eth each)
        token0.mint(alice, 10 ether);
        vm.deal(alice, 10 ether);
        addParams = _getAddParams(key3, binIds, 10 ether, 10 ether, activeId, alice);
        planner = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(addParams));
        payload = planner.finalizeModifyLiquidityWithClose(key3);
        binPm.modifyLiquidities{value: 10 ether}(payload, _deadline);
    }

    function test_bytecodeSize() public {
        vm.snapshotValue("BinQuoterBytecode size", address(quoter).code.length);

        if (address(quoter).code.length > 24576) {
            revert ContractSizeTooLarge(address(quoter).code.length - 24576);
        }
    }

    function testQuoter_quoteExactInputSingle_zeroForOne() public {
        vm.startPrank(alice);

        vm.deal(alice, 1 ether);
        assertEq(alice.balance, 1 ether);
        assertEq(token0.balanceOf(alice), 0 ether);

        (uint256 _amountOut, uint256 _gasEstimate) = quoter.quoteExactInputSingle(
            IQuoter.QuoteExactSingleParams({
                poolKey: key3, zeroForOne: true, exactAmount: 1 ether, hookData: new bytes(0)
            })
        );

        uint256 aliceCurrency1BalanceBefore = key3.currency1.balanceOf(alice);

        vm.expectEmit(true, true, true, true);
        emit IBinPoolManager.Swap(
            key3.toId(), address(router), -1 ether, int128(uint128(_amountOut)), activeId, key3.fee, 0
        );
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(vault), alice, uint256(uint128(_amountOut)));

        IBinRouterBase.BinSwapExactInputSingleParams memory params =
            IBinRouterBase.BinSwapExactInputSingleParams(key3, true, 1 ether, 0, bytes(""));

        plan = plan.add(Actions.BIN_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key3.currency0, key3.currency1, alice);

        router.executeActions{value: 1 ether}(data);

        uint256 aliceCurrency1BalanceAfter = key3.currency1.balanceOf(alice);
        uint256 amountOut = aliceCurrency1BalanceAfter - aliceCurrency1BalanceBefore;

        assertEq(_amountOut, amountOut);
        assertEq(amountOut, 997000000000000000);
        assertEq(alice.balance, 0 ether);
        assertEq(token0.balanceOf(alice), amountOut);

        assertGt(_gasEstimate, 40000);
        assertLt(_gasEstimate, 50000);
    }

    function testQuoter_quoteExactInputSingle_oneForZero() public {
        vm.startPrank(alice);

        token0.mint(alice, 1 ether);
        assertEq(alice.balance, 0 ether);
        assertEq(token0.balanceOf(alice), 1 ether);

        (uint256 _amountOut, uint256 _gasEstimate) = quoter.quoteExactInputSingle(
            IQuoter.QuoteExactSingleParams({
                poolKey: key3, zeroForOne: false, exactAmount: 1 ether, hookData: new bytes(0)
            })
        );

        uint256 aliceCurrency0BalanceBefore = key3.currency0.balanceOf(alice);

        vm.expectEmit(true, true, true, true);
        emit IBinPoolManager.Swap(
            key3.toId(), address(router), int128(uint128(_amountOut)), -1 ether, activeId, key3.fee, 0
        );
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(alice, address(vault), 1 ether);

        IBinRouterBase.BinSwapExactInputSingleParams memory params =
            IBinRouterBase.BinSwapExactInputSingleParams(key3, false, 1 ether, 0, bytes(""));

        plan = plan.add(Actions.BIN_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key3.currency1, key3.currency0, alice);

        router.executeActions(data);

        uint256 aliceCurrency0BalanceAfter = key3.currency0.balanceOf(alice);

        uint256 amountOut = aliceCurrency0BalanceAfter - aliceCurrency0BalanceBefore;
        assertEq(_amountOut, amountOut);
        assertEq(amountOut, 997000000000000000);
        assertEq(alice.balance, amountOut);
        assertEq(token0.balanceOf(alice), 0 ether);

        assertGt(_gasEstimate, 40000);
        assertLt(_gasEstimate, 50000);
    }

    function testQuoter_quoteExactInput_SingleHop() public {
        vm.startPrank(alice);
        token0.mint(alice, 1 ether);

        PathKey[] memory path = new PathKey[](1);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(token1)),
            fee: key.fee,
            hooks: key.hooks,
            hookData: new bytes(0),
            poolManager: key.poolManager,
            parameters: key.parameters
        });

        PathKey[] memory quoter_path = new PathKey[](1);
        quoter_path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(token1)),
            fee: key.fee,
            hooks: key.hooks,
            hookData: new bytes(0),
            poolManager: key.poolManager,
            parameters: key.parameters
        });

        (uint256 _amountOut, uint256 _gasEstimate) = quoter.quoteExactInput(
            IQuoter.QuoteExactParams({
                exactCurrency: Currency.wrap(address(token0)), path: quoter_path, exactAmount: 1 ether
            })
        );

        uint256 aliceCurrency1BalanceBefore = key.currency1.balanceOf(alice);
        vm.expectEmit(true, true, true, true);
        emit IBinPoolManager.Swap(
            key.toId(), address(router), -1 ether, int128(uint128(_amountOut)), activeId, key.fee, 0
        );
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(alice, address(vault), 1 ether);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(vault), alice, _amountOut);

        IBinRouterBase.BinSwapExactInputParams memory params =
            IBinRouterBase.BinSwapExactInputParams(Currency.wrap(address(token0)), path, 1 ether, 0);

        plan = plan.add(Actions.BIN_SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(Currency.wrap(address(token0)), Currency.wrap(address(token1)), alice);
        router.executeActions(data);

        uint256 aliceCurrency1BalanceAfter = key.currency1.balanceOf(alice);

        uint256 amountOut = aliceCurrency1BalanceAfter - aliceCurrency1BalanceBefore;

        assertEq(_amountOut, amountOut);
        assertEq(token1.balanceOf(alice), amountOut);

        assertGt(_gasEstimate, 45000);
        assertLt(_gasEstimate, 55000);
    }

    function testQuoter_quoteExactInput_MultiHop() public {
        vm.startPrank(alice);
        token0.mint(alice, 1 ether);

        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(token1)),
            fee: key.fee,
            hooks: key.hooks,
            hookData: new bytes(0),
            poolManager: key.poolManager,
            parameters: key.parameters
        });
        path[1] = PathKey({
            intermediateCurrency: Currency.wrap(address(token2)),
            fee: key2.fee,
            hooks: key2.hooks,
            hookData: new bytes(0),
            poolManager: key2.poolManager,
            parameters: key2.parameters
        });

        PathKey[] memory quoter_path = new PathKey[](2);
        quoter_path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(token1)),
            fee: key.fee,
            hooks: key.hooks,
            hookData: new bytes(0),
            poolManager: key.poolManager,
            parameters: key.parameters
        });
        quoter_path[1] = PathKey({
            intermediateCurrency: Currency.wrap(address(token2)),
            fee: key2.fee,
            hooks: key2.hooks,
            hookData: new bytes(0),
            poolManager: key2.poolManager,
            parameters: key2.parameters
        });

        (uint256 _amountOut, uint256 _gasEstimate) = quoter.quoteExactInput(
            IQuoter.QuoteExactParams({
                exactCurrency: Currency.wrap(address(token0)), path: quoter_path, exactAmount: 1 ether
            })
        );

        uint256 bobToken2BalanceBefore = key2.currency1.balanceOf(bob);

        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(alice, address(vault), 1 ether);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(vault), address(bob), _amountOut);

        IBinRouterBase.BinSwapExactInputParams memory params =
            IBinRouterBase.BinSwapExactInputParams(Currency.wrap(address(token0)), path, 1 ether, 0);

        plan = plan.add(Actions.BIN_SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(Currency.wrap(address(token0)), Currency.wrap(address(token2)), bob);
        router.executeActions(data);

        uint256 bobToken2BalanceAfter = key2.currency1.balanceOf(bob);

        uint256 amountOut = bobToken2BalanceAfter - bobToken2BalanceBefore;

        assertEq(_amountOut, amountOut);
        // 1 ether * 0.997 * 0.997 (0.3% fee twice)
        assertEq(amountOut, 994009000000000000);
        assertEq(token2.balanceOf(alice), 0);
        assertEq(token2.balanceOf(bob), amountOut);

        assertGt(_gasEstimate, 80000);
        assertLt(_gasEstimate, 90000);
    }

    function testQuoter_quoteExactOutputSingle_zeroForOne() public {
        vm.startPrank(alice);
        token0.mint(alice, 1 ether);

        (uint256 _amountIn, uint256 _gasEstimate) = quoter.quoteExactOutputSingle(
            IQuoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: true, exactAmount: 0.5 ether, hookData: new bytes(0)
            })
        );

        uint256 aliceCurrency0BalanceBefore = key.currency0.balanceOf(alice);

        vm.expectEmit(true, true, true, true);
        emit IBinPoolManager.Swap(
            key.toId(), address(router), -int128(uint128(_amountIn)), 0.5 ether, activeId, key.fee, 0
        );
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(alice, address(vault), _amountIn);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(vault), address(bob), 0.5 ether);

        IBinRouterBase.BinSwapExactOutputSingleParams memory params =
            IBinRouterBase.BinSwapExactOutputSingleParams(key, true, 0.5 ether, 1 ether, bytes(""));

        plan = plan.add(Actions.BIN_SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key.currency0, key.currency1, bob);
        router.executeActions(data);

        uint256 aliceCurrency0BalanceAfter = key.currency0.balanceOf(alice);

        uint256 amountIn = aliceCurrency0BalanceBefore - aliceCurrency0BalanceAfter;

        assertEq(_amountIn, amountIn);
        assertEq(token0.balanceOf(alice), 1 ether - amountIn);
        assertEq(token1.balanceOf(alice), 0 ether);
        assertEq(token1.balanceOf(bob), 0.5 ether);

        assertGt(_gasEstimate, 45000);
        assertLt(_gasEstimate, 55000);
    }

    function testQuoter_quoteExactOutputSingle_oneForZero() public {
        vm.startPrank(alice);
        token1.mint(alice, 1 ether);

        (uint256 _amountIn, uint256 _gasEstimate) = quoter.quoteExactOutputSingle(
            IQuoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: false, exactAmount: 0.5 ether, hookData: new bytes(0)
            })
        );

        uint256 aliceCurrency1BalanceBefore = key.currency1.balanceOf(alice);

        vm.expectEmit(true, true, true, true);
        emit IBinPoolManager.Swap(
            key.toId(), address(router), 0.5 ether, -int128(uint128(_amountIn)), activeId, key.fee, 0
        );
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(alice, address(vault), _amountIn);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(vault), address(bob), 0.5 ether);

        IBinRouterBase.BinSwapExactOutputSingleParams memory params =
            IBinRouterBase.BinSwapExactOutputSingleParams(key, false, 0.5 ether, 1 ether, bytes(""));

        plan = plan.add(Actions.BIN_SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(key.currency1, key.currency0, bob);
        router.executeActions(data);

        uint256 aliceCurrency1BalanceAfter = key.currency1.balanceOf(alice);

        uint256 amountIn = aliceCurrency1BalanceBefore - aliceCurrency1BalanceAfter;

        assertEq(_amountIn, amountIn);
        assertEq(token0.balanceOf(alice), 0 ether);
        assertEq(token1.balanceOf(alice), 1 ether - amountIn);
        assertEq(token0.balanceOf(bob), 0.5 ether);

        assertGt(_gasEstimate, 45000);
        assertLt(_gasEstimate, 55000);
    }

    function testQuoter_quoteExactOutput_SingleHop() public {
        // swap token0 input -> token1 output
        vm.startPrank(alice);
        token0.mint(alice, 1 ether);

        PathKey[] memory path = new PathKey[](1);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(token0)),
            fee: key.fee,
            hooks: key.hooks,
            hookData: new bytes(0),
            poolManager: key.poolManager,
            parameters: key.parameters
        });

        // before test validation
        assertEq(token0.balanceOf(alice), 1 ether);
        assertEq(token1.balanceOf(alice), 0);

        PathKey[] memory quoter_path = new PathKey[](1);
        quoter_path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(token0)),
            fee: key.fee,
            hooks: key.hooks,
            hookData: new bytes(0),
            poolManager: key.poolManager,
            parameters: key.parameters
        });

        (uint256 _amountIn, uint256 _gasEstimate) = quoter.quoteExactOutput(
            IQuoter.QuoteExactParams({
                exactCurrency: Currency.wrap(address(token1)), path: quoter_path, exactAmount: 0.5 ether
            })
        );

        uint256 aliceCurrency0BalanceBefore = key.currency0.balanceOf(alice);

        vm.expectEmit(true, true, true, true);
        emit IBinPoolManager.Swap(
            key.toId(), address(router), -int128(uint128(_amountIn)), 0.5 ether, activeId, key.fee, 0
        );
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(alice, address(vault), _amountIn);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(vault), alice, 0.5 ether);

        IBinRouterBase.BinSwapExactOutputParams memory params =
            IBinRouterBase.BinSwapExactOutputParams(key.currency1, path, 0.5 ether, 1 ether);

        plan = plan.add(Actions.BIN_SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(Currency.wrap(address(token0)), Currency.wrap(address(token1)), alice);
        router.executeActions(data);

        uint256 aliceCurrency0BalanceAfter = key.currency0.balanceOf(alice);

        uint256 amountIn = aliceCurrency0BalanceBefore - aliceCurrency0BalanceAfter;

        // after test validation
        assertEq(_amountIn, amountIn);
        assertEq(amountIn, 501504513540621866); // amt in should be greater than 0.5 eth
        assertEq(token0.balanceOf(alice), 1 ether - amountIn);
        assertEq(token1.balanceOf(alice), 0.5 ether);

        assertGt(_gasEstimate, 40000);
        assertLt(_gasEstimate, 50000);
    }

    function testQuoter_quoteExactOutput_MultiHop() public {
        // swap token0 input -> token1 -> token2 output
        vm.startPrank(alice);
        token0.mint(alice, 1 ether);

        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(token0)),
            fee: key.fee,
            hooks: key.hooks,
            hookData: new bytes(0),
            poolManager: key.poolManager,
            parameters: key.parameters
        });
        path[1] = PathKey({
            intermediateCurrency: Currency.wrap(address(token1)),
            fee: key2.fee,
            hooks: key2.hooks,
            hookData: new bytes(0),
            poolManager: key2.poolManager,
            parameters: key2.parameters
        });

        PathKey[] memory quoter_path = new PathKey[](2);
        quoter_path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(token0)),
            fee: key.fee,
            hooks: key.hooks,
            hookData: new bytes(0),
            poolManager: key.poolManager,
            parameters: key.parameters
        });
        quoter_path[1] = PathKey({
            intermediateCurrency: Currency.wrap(address(token1)),
            fee: key2.fee,
            hooks: key2.hooks,
            hookData: new bytes(0),
            poolManager: key2.poolManager,
            parameters: key2.parameters
        });

        (uint256 _amountIn, uint256 _gasEstimate) = quoter.quoteExactOutput(
            IQuoter.QuoteExactParams({
                exactCurrency: Currency.wrap(address(token2)), path: quoter_path, exactAmount: 0.5 ether
            })
        );

        // before test validation
        assertEq(token0.balanceOf(alice), 1 ether);
        assertEq(token1.balanceOf(alice), 0);
        assertEq(token2.balanceOf(alice), 0);
        assertEq(token2.balanceOf(bob), 0 ether);

        uint256 aliceCurrency0BalanceBefore = key.currency0.balanceOf(alice);

        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(alice, address(vault), _amountIn);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(vault), address(bob), 0.5 ether);

        IBinRouterBase.BinSwapExactOutputParams memory params =
            IBinRouterBase.BinSwapExactOutputParams(Currency.wrap(address(token2)), path, 0.5 ether, 1 ether);

        plan = plan.add(Actions.BIN_SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(Currency.wrap(address(token0)), Currency.wrap(address(token2)), bob);
        router.executeActions(data);

        uint256 aliceCurrency0BalanceAfter = key.currency0.balanceOf(alice);

        uint256 amountIn = aliceCurrency0BalanceBefore - aliceCurrency0BalanceAfter;

        // after test validation
        // amt in should be greater than 0.5 eth + 0.3% fee twice (2 pool)
        assertEq(_amountIn, amountIn);
        assertEq(amountIn, 503013554203231561);
        assertEq(token0.balanceOf(alice), 1 ether - amountIn);
        assertEq(token2.balanceOf(bob), 0.5 ether);

        assertGt(_gasEstimate, 75000);
        assertLt(_gasEstimate, 85000);
    }

    function testQuoter_lockAcquired_revert_InvalidLockAcquiredSender() public {
        vm.startPrank(alice);
        vm.expectRevert(SafeCallback.NotVault.selector);
        quoter.lockAcquired(abi.encodeWithSelector(quoter.lockAcquired.selector, "0x"));
    }

    function testQuoter_lockAcquired_revert_LockFailure() public {
        vm.startPrank(address(vault));
        vm.expectRevert();
        quoter.lockAcquired(abi.encodeWithSelector(quoter.lockAcquired.selector, address(this), "0x"));
    }

    function testQuoter_lockAcquired_revert_NotSelf() public {
        vm.startPrank(alice);
        vm.expectRevert(IQuoter.NotSelf.selector);

        quoter._quoteExactInputSingle(
            IQuoter.QuoteExactSingleParams({
                poolKey: key3, zeroForOne: true, exactAmount: 1 ether, hookData: new bytes(0)
            })
        );
    }

    function testQuoter_lockAcquired_revert_UnexpectedRevertBytes() public {
        vm.startPrank(alice);

        vm.expectRevert(
            abi.encodeWithSelector(
                QuoterRevert.UnexpectedRevertBytes.selector,
                abi.encodeWithSelector(BinPool.BinPool__OutOfLiquidity.selector)
            )
        );
        quoter.quoteExactOutputSingle(
            IQuoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: true, exactAmount: 20 ether, hookData: new bytes(0)
            })
        );
    }
}
