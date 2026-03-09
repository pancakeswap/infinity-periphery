// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {FixedPoint96} from "infinity-core/src/pool-cl/libraries/FixedPoint96.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {CLPool} from "infinity-core/src/pool-cl/libraries/CLPool.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {TokenFixture} from "../helpers/TokenFixture.sol";
import {MockInfinityRouter} from "../mocks/MockInfinityRouter.sol";
import {IInfinityRouter} from "../../src/interfaces/IInfinityRouter.sol";
import {ICLRouterBase} from "../../src/pool-cl/interfaces/ICLRouterBase.sol";
import {PathKey} from "../../src/libraries/PathKey.sol";
import {Plan, Planner} from "../../src/libraries/Planner.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";

contract CLSwapRouterTest is TokenFixture, Test {
    IVault public vault;
    ICLPoolManager public poolManager;
    CLPoolManagerRouter public positionManager;
    MockInfinityRouter public router;

    PoolKey public poolKey0;
    PoolKey public poolKey1;
    PoolKey public poolKey2;

    Plan plan;

    function setUp() public {
        plan = Planner.init();
        vault = new Vault();
        poolManager = new CLPoolManager(vault);
        vault.registerApp(address(poolManager));

        initializeTokens();
        vm.label(Currency.unwrap(currency0), "token0");
        vm.label(Currency.unwrap(currency1), "token1");
        vm.label(Currency.unwrap(currency2), "token2");

        positionManager = new CLPoolManagerRouter(vault, poolManager);
        IERC20(Currency.unwrap(currency0)).approve(address(positionManager), 1000 ether);
        IERC20(Currency.unwrap(currency1)).approve(address(positionManager), 1000 ether);
        IERC20(Currency.unwrap(currency2)).approve(address(positionManager), 1000 ether);

        router = new MockInfinityRouter(vault, poolManager, IBinPoolManager(address(0)));
        IERC20(Currency.unwrap(currency0)).approve(address(router), 1000 ether);
        IERC20(Currency.unwrap(currency1)).approve(address(router), 1000 ether);
        IERC20(Currency.unwrap(currency2)).approve(address(router), 1000 ether);

        poolKey0 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });
        // price 100
        uint160 sqrtPriceX96_100 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(poolKey0, sqrtPriceX96_100);

        positionManager.modifyPosition(
            poolKey0,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: 46053, tickUpper: 46055, liquidityDelta: 1e4 ether, salt: bytes32(0)
            }),
            new bytes(0)
        );

        poolKey1 = PoolKey({
            currency0: currency1,
            currency1: currency2,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });
        // price 1
        uint160 sqrtPriceX96_1 = uint160(1 * FixedPoint96.Q96);
        poolManager.initialize(poolKey1, sqrtPriceX96_1);

        positionManager.modifyPosition(
            poolKey1,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: -5, tickUpper: 5, liquidityDelta: 1e5 ether, salt: bytes32(0)
            }),
            new bytes(0)
        );

        vm.deal(msg.sender, 25 ether);
        poolKey2 = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: currency0,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });
        // price 1
        uint160 sqrtPriceX96_2 = uint160(1 * FixedPoint96.Q96);

        poolManager.initialize(poolKey2, sqrtPriceX96_2);

        positionManager.modifyPosition{value: 25 ether}(
            poolKey2,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: -5, tickUpper: 5, liquidityDelta: 1e5 ether, salt: bytes32(0)
            }),
            new bytes(0)
        );

        // token0-token1 amount 0.05 ether : 5 ether i.e. price = 100
        // token1-token2 amount 25 ether : 25 ether i.e. price = 1
        // eth-token0 amount 25 ether : 25 ether i.e. price = 1
    }

    function testExactInputSingle_EthPool_zeroForOne() external {
        address alice = makeAddr("alice");
        vm.startPrank(alice);
        vm.deal(alice, 0.01 ether);

        // before assertion
        assertEq(alice.balance, 0.01 ether);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(alice), 0 ether);

        // swap
        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(poolKey2, true, 0.01 ether, 0, bytes(""));

        plan = plan.add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(poolKey2.currency0, poolKey2.currency1, ActionConstants.MSG_SENDER);

        router.executeActions{value: 0.01 ether}(data);

        // after assertion
        assertEq(alice.balance, 0 ether);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(alice), 9969999005991099);
    }

    function testExactInputSingle_EthPool_OneForZero() external {
        // pre-req: mint and approve for alice
        address alice = makeAddr("alice");
        vm.startPrank(alice);
        MockERC20(Currency.unwrap(currency0)).mint(alice, 0.01 ether);
        IERC20(Currency.unwrap(currency0)).approve(address(router), 0.01 ether);

        // before assertion
        assertEq(alice.balance, 0 ether);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(alice), 0.01 ether);

        // swap
        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(poolKey2, false, 0.01 ether, 0, bytes(""));

        plan = plan.add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(poolKey2.currency1, poolKey2.currency0, ActionConstants.MSG_SENDER);

        router.executeActions(data);

        // after assertion
        assertEq(alice.balance, 9969999005991099);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(alice), 0);
    }

    function testExactInputSingle_zeroForOne() external {
        address recipient = makeAddr("recipient");
        uint256 recipientBalanceBefore = IERC20(Currency.unwrap(poolKey0.currency1)).balanceOf(recipient);
        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(poolKey0, true, 0.01 ether, 0, bytes(""));

        plan = plan.add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(poolKey0.currency0, poolKey0.currency1, recipient);

        router.executeActions(data);

        uint256 recipientBalanceAfter = IERC20(Currency.unwrap(poolKey0.currency1)).balanceOf(recipient);
        assertEq(recipientBalanceAfter - recipientBalanceBefore, 996990060009101709);
    }

    function testExactInputSingle_oneForZero() external {
        address recipient = makeAddr("recipient");
        uint256 recipientBalanceBefore = IERC20(Currency.unwrap(poolKey0.currency0)).balanceOf(recipient);
        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(poolKey0, false, 1 ether, 0, bytes(""));

        plan = plan.add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(poolKey0.currency1, poolKey0.currency0, recipient);

        router.executeActions(data);

        uint256 recipientBalanceAfter = IERC20(Currency.unwrap(poolKey0.currency0)).balanceOf(recipient);
        assertEq(recipientBalanceAfter - recipientBalanceBefore, 9969900600091017);
    }

    function testExactInputSingle_amountOutLessThanExpected() external {
        vm.expectRevert(abi.encodeWithSelector(IInfinityRouter.TooLittleReceived.selector, 2 ether, 996990060009101709));
        address recipient = makeAddr("recipient");
        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(poolKey0, true, 0.01 ether, 2 ether, bytes(""));

        plan = plan.add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(poolKey0.currency0, poolKey0.currency1, recipient);

        router.executeActions(data);
    }

    function testExactInputSingle_gas() external {
        address recipient = makeAddr("recipient");
        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(poolKey0, true, 0.01 ether, 0, bytes(""));

        plan = plan.add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(poolKey0.currency0, poolKey0.currency1, recipient);

        router.executeActions(data);
        vm.snapshotGasLastCall("testExactInputSingle_gas");
    }

    function testExactInput() external {
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: currency1,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });
        path[1] = PathKey({
            intermediateCurrency: currency2,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });

        address recipient = makeAddr("recipient");
        uint256 recipientBalanceBefore = IERC20(Currency.unwrap(currency2)).balanceOf(recipient);
        ICLRouterBase.CLSwapExactInputParams memory params =
            ICLRouterBase.CLSwapExactInputParams(currency0, path, 0.01 ether, 0);

        plan = plan.add(Actions.CL_SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency2, recipient);

        router.executeActions(data);

        uint256 recipientBalanceAfter = IERC20(Currency.unwrap(currency2)).balanceOf(recipient);
        assertEq(recipientBalanceAfter - recipientBalanceBefore, 993989209585378125);
    }

    function testExactInput_amountOutLessThanExpected() external {
        vm.expectRevert(abi.encodeWithSelector(IInfinityRouter.TooLittleReceived.selector, 2 ether, 993989209585378125));
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: currency1,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });
        path[1] = PathKey({
            intermediateCurrency: currency2,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });

        address recipient = makeAddr("recipient");
        ICLRouterBase.CLSwapExactInputParams memory params =
            ICLRouterBase.CLSwapExactInputParams(currency0, path, 0.01 ether, 2 ether);

        plan = plan.add(Actions.CL_SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency2, recipient);

        router.executeActions(data);
    }

    function testExactInput_gas() external {
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: currency1,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });
        path[1] = PathKey({
            intermediateCurrency: currency2,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });

        address recipient = makeAddr("recipient");
        ICLRouterBase.CLSwapExactInputParams memory params =
            ICLRouterBase.CLSwapExactInputParams(currency0, path, 0.01 ether, 0);

        plan = plan.add(Actions.CL_SWAP_EXACT_IN, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency2, recipient);

        router.executeActions(data);
        vm.snapshotGasLastCall("testExactInput_gas");
    }

    function testExactOutputSingle_zeroForOne() external {
        uint256 balanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        address recipient = makeAddr("recipient");
        uint256 recipientBalanceBefore = IERC20(Currency.unwrap(poolKey0.currency1)).balanceOf(recipient);
        ICLRouterBase.CLSwapExactOutputSingleParams memory params =
            ICLRouterBase.CLSwapExactOutputSingleParams(poolKey0, true, 1 ether, 0.0101 ether, bytes(""));

        plan = plan.add(Actions.CL_SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(poolKey0.currency0, poolKey0.currency1, recipient);

        router.executeActions(data);
        uint256 balanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 recipientBalanceAfter = IERC20(Currency.unwrap(poolKey0.currency1)).balanceOf(recipient);

        uint256 paid = balanceBefore - balanceAfter;
        assertEq(paid, 10030190572718166);
        assertEq(recipientBalanceAfter - recipientBalanceBefore, 1 ether);
    }

    function testExactOutputSingle_oneForZero() external {
        uint256 balanceBefore = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        address recipient = makeAddr("recipient");
        uint256 recipientBalanceBefore = IERC20(Currency.unwrap(poolKey0.currency0)).balanceOf(recipient);

        ICLRouterBase.CLSwapExactOutputSingleParams memory params =
            ICLRouterBase.CLSwapExactOutputSingleParams(poolKey0, false, 0.01 ether, 1.01 ether, bytes(""));

        plan = plan.add(Actions.CL_SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(poolKey0.currency1, poolKey0.currency0, recipient);

        router.executeActions(data);
        uint256 balanceAfter = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        uint256 recipientBalanceAfter = IERC20(Currency.unwrap(poolKey0.currency0)).balanceOf(recipient);

        uint256 paid = balanceBefore - balanceAfter;
        assertEq(paid, 1003019057271816451);
        assertEq(recipientBalanceAfter - recipientBalanceBefore, 0.01 ether);
    }

    function testExactOutputSingle_swapOpenDelta() public {
        // roughly 0.01 ether swap for 1 ether (pool0 -> price 100)
        uint256 expectedAmountIn = 10030190572718166;

        ICLRouterBase.CLSwapExactOutputSingleParams memory params = ICLRouterBase.CLSwapExactOutputSingleParams(
            poolKey0, true, ActionConstants.OPEN_DELTA, uint128(expectedAmountIn + 1), bytes("")
        );

        plan = plan.add(Actions.TAKE, abi.encode(poolKey0.currency1, ActionConstants.ADDRESS_THIS, 1 ether));
        plan = plan.add(Actions.CL_SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        plan = plan.add(Actions.SETTLE, abi.encode(poolKey0.currency0, ActionConstants.OPEN_DELTA, true));

        bytes memory data = plan.encode();

        uint256 callerInputBefore = poolKey0.currency0.balanceOfSelf();
        uint256 routerInputBefore = poolKey0.currency1.balanceOfSelf();
        uint256 callerOutputBefore = poolKey0.currency1.balanceOfSelf();

        router.executeActions(data);

        uint256 callerInputAfter = poolKey0.currency0.balanceOfSelf();
        uint256 routerInputAfter = poolKey0.currency1.balanceOfSelf();
        uint256 callerOutputAfter = poolKey0.currency1.balanceOfSelf();

        // caller paid
        assertEq(callerInputBefore - expectedAmountIn, callerInputAfter);
        assertEq(routerInputBefore, routerInputAfter);
        assertEq(callerOutputBefore, callerOutputAfter);
    }

    function testExactOutputSingle_amountOutLessThanExpected() external {
        vm.expectRevert(
            abi.encodeWithSelector(IInfinityRouter.TooMuchRequested.selector, 0.01 ether, 10030190572718166)
        );

        address recipient = makeAddr("recipient");
        ICLRouterBase.CLSwapExactOutputSingleParams memory params =
            ICLRouterBase.CLSwapExactOutputSingleParams(poolKey0, true, 1 ether, 0.01 ether, bytes(""));

        plan = plan.add(Actions.CL_SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(poolKey0.currency0, poolKey0.currency1, recipient);

        router.executeActions(data);
    }

    function testExactOutputSingle_gas() external {
        address recipient = makeAddr("recipient");
        ICLRouterBase.CLSwapExactOutputSingleParams memory params =
            ICLRouterBase.CLSwapExactOutputSingleParams(poolKey0, true, 1 ether, 0.0101 ether, bytes(""));

        plan = plan.add(Actions.CL_SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(poolKey0.currency0, poolKey0.currency1, recipient);

        router.executeActions(data);
        vm.snapshotGasLastCall("testExactOutputSingle_gas");
    }

    function testExactOutput() external {
        uint256 balanceBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));

        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: currency0,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });
        path[1] = PathKey({
            intermediateCurrency: currency1,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });

        address recipient = makeAddr("recipient");
        uint256 recipientBalanceBefore = IERC20(Currency.unwrap(currency2)).balanceOf(recipient);
        ICLRouterBase.CLSwapExactOutputParams memory params =
            ICLRouterBase.CLSwapExactOutputParams(currency2, path, 1 ether, 0.0101 ether);

        plan = plan.add(Actions.CL_SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency2, recipient);
        router.executeActions(data);

        uint256 balanceAfter = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 recipientBalanceAfter = IERC20(Currency.unwrap(currency2)).balanceOf(recipient);
        uint256 paid = balanceBefore - balanceAfter;

        assertEq(paid, 10060472596238902);
        assertEq(recipientBalanceAfter - recipientBalanceBefore, 1 ether);
    }

    function testExactOut_swapOpenDelta() public {
        // roughly 0.01 ether swap for 1 ether (pool0 -> price 100)
        uint256 expectedAmountIn = 10030190572718166;

        PathKey[] memory path = new PathKey[](1);
        path[0] = PathKey({
            intermediateCurrency: currency0,
            fee: poolKey0.fee,
            hooks: poolKey0.hooks,
            hookData: new bytes(0),
            poolManager: poolKey0.poolManager,
            parameters: poolKey0.parameters
        });

        ICLRouterBase.CLSwapExactOutputParams memory params = ICLRouterBase.CLSwapExactOutputParams(
            currency1, path, ActionConstants.OPEN_DELTA, uint128(expectedAmountIn + 1)
        );

        plan = plan.add(Actions.TAKE, abi.encode(poolKey0.currency1, ActionConstants.ADDRESS_THIS, 1 ether));
        plan = plan.add(Actions.CL_SWAP_EXACT_OUT, abi.encode(params));
        plan = plan.add(Actions.SETTLE, abi.encode(poolKey0.currency0, ActionConstants.OPEN_DELTA, true));

        bytes memory data = plan.encode();

        uint256 callerInputBefore = poolKey0.currency0.balanceOfSelf();
        uint256 routerInputBefore = poolKey0.currency1.balanceOfSelf();
        uint256 callerOutputBefore = poolKey0.currency1.balanceOfSelf();

        router.executeActions(data);

        uint256 callerInputAfter = poolKey0.currency0.balanceOfSelf();
        uint256 routerInputAfter = poolKey0.currency1.balanceOfSelf();
        uint256 callerOutputAfter = poolKey0.currency1.balanceOfSelf();

        // caller paid
        assertEq(callerInputBefore - expectedAmountIn, callerInputAfter);
        assertEq(routerInputBefore, routerInputAfter);
        assertEq(callerOutputBefore, callerOutputAfter);
    }

    function testExactOutput_amountInMoreThanExpected() external {
        vm.expectRevert(
            abi.encodeWithSelector(IInfinityRouter.TooMuchRequested.selector, 0.01 ether, 10060472596238902)
        );

        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: currency0,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });
        path[1] = PathKey({
            intermediateCurrency: currency1,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });

        address recipient = makeAddr("recipient");
        ICLRouterBase.CLSwapExactOutputParams memory params =
            ICLRouterBase.CLSwapExactOutputParams(currency2, path, 1 ether, 0.01 ether);

        plan = plan.add(Actions.CL_SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency2, recipient);
        router.executeActions(data);
    }

    function testExactOutput_gas() external {
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: currency0,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });
        path[1] = PathKey({
            intermediateCurrency: currency1,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: bytes32(uint256(0x10000))
        });

        address recipient = makeAddr("recipient");
        ICLRouterBase.CLSwapExactOutputParams memory params =
            ICLRouterBase.CLSwapExactOutputParams(currency2, path, 1 ether, 0.0101 ether);

        plan = plan.add(Actions.CL_SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency2, recipient);

        router.executeActions(data);
        vm.snapshotGasLastCall("testExactOutput_gas");
    }

    // allow refund of ETH
    receive() external payable {}
}
