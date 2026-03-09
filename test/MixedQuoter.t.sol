// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {OldVersionHelper} from "./helpers/OldVersionHelper.sol";
import {IPancakePair} from "../src/interfaces/external/IPancakePair.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CLPositionManager} from "../src/pool-cl/CLPositionManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {BinPoolManager} from "infinity-core/src/pool-bin/BinPoolManager.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {PosmTestSetup} from "./pool-cl/shared/PosmTestSetup.sol";
import {Permit2ApproveHelper} from "./helpers/Permit2ApproveHelper.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Permit2Forwarder} from "../src/base/Permit2Forwarder.sol";
import {IV3NonfungiblePositionManager} from "../src/interfaces/external/IV3NonfungiblePositionManager.sol";
import {IMixedQuoter} from "../src/interfaces/IMixedQuoter.sol";
import {MixedQuoter} from "../src/MixedQuoter.sol";
import {IQuoter} from "../src/interfaces/IQuoter.sol";
import {ICLQuoter} from "../src/pool-cl/interfaces/ICLQuoter.sol";
import {IBinQuoter} from "../src/pool-bin/interfaces/IBinQuoter.sol";
import {MixedQuoterActions} from "../src/libraries/MixedQuoterActions.sol";
import {IPancakeFactory} from "../src/interfaces/external/IPancakeFactory.sol";
import {IPancakeV3Factory} from "../src/interfaces/external/IPancakeV3Factory.sol";
import {ICLQuoter} from "../src/pool-cl/interfaces/ICLQuoter.sol";
import {CLQuoter} from "../src/pool-cl/lens/CLQuoter.sol";
import {BinPositionManager} from "../src/pool-bin/BinPositionManager.sol";
import {IBinPositionManager} from "../src/pool-bin/interfaces/IBinPositionManager.sol";
import {IBinQuoter, BinQuoter} from "../src/pool-bin/lens/BinQuoter.sol";
import {BinPoolParametersHelper} from "infinity-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {BinLiquidityHelper} from "./pool-bin/helper/BinLiquidityHelper.sol";
import {Plan, Planner} from "../src/libraries/Planner.sol";
import {Actions} from "../src/libraries/Actions.sol";
import {DeployStableSwapHelper} from "./helpers/DeployStableSwapHelper.sol";
import {IStableSwapFactory} from "../src/interfaces/external/IStableSwapFactory.sol";
import {IStableSwap} from "../src/interfaces/external/IStableSwap.sol";
import {IWETH9} from "../src/interfaces/external/IWETH9.sol";
import {MockInfinityRouter} from "./mocks/MockInfinityRouter.sol";
import {ICLRouterBase} from "../src/pool-cl/interfaces/ICLRouterBase.sol";
import {IBinRouterBase} from "../src/pool-bin/interfaces/IBinRouterBase.sol";
import {ActionConstants} from "../src/libraries/ActionConstants.sol";
import {V3SmartRouterHelper} from "../src/libraries/external/V3SmartRouterHelper.sol";
import {MixedQuoterRecorder} from "../src/libraries/MixedQuoterRecorder.sol";
import {PancakeV3Router} from "./helpers/PancakeV3Router.sol";

contract MixedQuoterTest is
    Test,
    OldVersionHelper,
    PosmTestSetup,
    Permit2ApproveHelper,
    BinLiquidityHelper,
    DeployStableSwapHelper
{
    using SafeCast for *;
    using CLPoolParametersHelper for bytes32;
    using BinPoolParametersHelper for bytes32;

    error ContractSizeTooLarge(uint256 diff);

    uint160 public constant INIT_SQRT_PRICE = 79228162514264337593543950336;
    uint24 activeId = 2 ** 23; // where token0 and token1 price is the same

    IWETH9 weth;
    MockERC20 token0;
    MockERC20 token1;
    MockERC20 token2;
    MockERC20 token3;
    MockERC20 token4;
    MockERC20 token5;

    MockInfinityRouter infinityRouter;

    IVault vault;
    ICLPoolManager clPoolManager;

    IPancakeFactory v2Factory;
    IPancakePair v2Pair;
    IPancakePair v2PairWithoutNativeToken;

    address v3Deployer;
    IPancakeV3Factory v3Factory;
    IV3NonfungiblePositionManager v3Nfpm;
    PancakeV3Router v3Router;

    IStableSwapFactory stableSwapFactory;
    IStableSwap stableSwapPair;

    IBinPoolManager binPoolManager;
    BinPositionManager binPm;
    ICLQuoter clQuoter;
    IBinQuoter binQuoter;
    MixedQuoter mixedQuoter;

    PoolId poolId;
    PoolKey poolKey;
    PoolKey poolKeyWithNativeToken;
    PoolKey poolKeyWithWETH;

    bytes32 binPoolParam;

    PoolKey binPoolKey;

    Plan plan;

    function setUp() public {
        plan = Planner.init();

        weth = _WETH9;
        token2 = new MockERC20("Token0", "TKN2", 18);
        token3 = new MockERC20("Token1", "TKN3", 18);
        token4 = new MockERC20("Token2", "TKN4", 18);
        token5 = new MockERC20("Token3", "TKN5", 18);
        (token2, token3) = token2 < token3 ? (token2, token3) : (token3, token2);
        (token3, token4) = token3 < token4 ? (token3, token4) : (token4, token3);
        deployPosmHookSavesDelta();
        (vault, clPoolManager, poolKey, poolId) = createFreshPool(IHooks(address(hook)), 3000, SQRT_RATIO_1_1);

        binPoolManager = new BinPoolManager(vault);
        vault.registerApp(address(binPoolManager));

        infinityRouter = new MockInfinityRouter(vault, clPoolManager, binPoolManager);
        MockERC20(Currency.unwrap(poolKey.currency0)).approve(address(infinityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(poolKey.currency1)).approve(address(infinityRouter), type(uint256).max);
        token2.approve(address(infinityRouter), type(uint256).max);
        token3.approve(address(infinityRouter), type(uint256).max);
        token4.approve(address(infinityRouter), type(uint256).max);
        token5.approve(address(infinityRouter), type(uint256).max);

        currency0 = poolKey.currency0;
        currency1 = poolKey.currency1;
        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));
        deployAndApprovePosm(vault, clPoolManager);

        binPm = new BinPositionManager(vault, binPoolManager, permit2, IWETH9(_WETH9));

        clQuoter = new CLQuoter(address(clPoolManager));
        binQuoter = new BinQuoter(address(binPoolManager));

        binPoolKey = PoolKey({
            currency0: Currency.wrap(address(token3)),
            currency1: Currency.wrap(address(token4)),
            hooks: IHooks(address(0)),
            poolManager: binPoolManager,
            fee: uint24(3000), // 3000 = 0.3%
            parameters: binPoolParam.setBinStep(10) // binStep
        });

        poolKeyWithNativeToken = poolKey;
        poolKeyWithNativeToken.currency0 = Currency.wrap(address(0));
        poolKeyWithNativeToken.currency1 = Currency.wrap(address(token1));
        clPoolManager.initialize(poolKeyWithNativeToken, SQRT_RATIO_1_1);

        //set pool with WETH
        poolKeyWithWETH = poolKey;
        if (address(weth) < address(token2)) {
            poolKeyWithWETH.currency0 = Currency.wrap(address(weth));
            poolKeyWithWETH.currency1 = Currency.wrap(address(token2));
        } else {
            poolKeyWithWETH.currency0 = Currency.wrap(address(token2));
            poolKeyWithWETH.currency1 = Currency.wrap(address(weth));
        }
        clPoolManager.initialize(poolKeyWithWETH, SQRT_RATIO_1_1);

        // make sure the contract has enough balance
        deal(address(this), 100000 ether);
        weth.deposit{value: 10000 ether}();
        token2.mint(address(this), 10000 ether);
        token3.mint(address(this), 10000 ether);
        token4.mint(address(this), 10000 ether);
        token5.mint(address(this), 10000 ether);

        v2Factory = IPancakeFactory(createContractThroughBytecode(_getBytecodePath()));
        v2Pair = IPancakePair(v2Factory.createPair(address(weth), address(token2)));
        v2PairWithoutNativeToken = IPancakePair(v2Factory.createPair(address(token2), address(token3)));

        // pcs v3
        if (bytes(_getDeployerBytecodePath()).length != 0) {
            v3Deployer = createContractThroughBytecode(_getDeployerBytecodePath());
            v3Factory = IPancakeV3Factory(
                createContractThroughBytecode(_getFactoryBytecodePath(), toBytes32(address(v3Deployer)))
            );
            (bool success,) = v3Deployer.call(abi.encodeWithSignature("setFactoryAddress(address)", address(v3Factory)));
            require(success, "setFactoryAddress failed");
            v3Nfpm = IV3NonfungiblePositionManager(
                createContractThroughBytecode(
                    _getNfpmBytecodePath(),
                    toBytes32(v3Deployer),
                    toBytes32(address(v3Factory)),
                    toBytes32(address(weth)),
                    0
                )
            );
        } else {
            v3Factory = IPancakeV3Factory(createContractThroughBytecode(_getFactoryBytecodePath()));

            v3Nfpm = IV3NonfungiblePositionManager(
                createContractThroughBytecode(
                    _getNfpmBytecodePath(), toBytes32(address(v3Factory)), toBytes32(address(weth)), 0
                )
            );
        }

        v3Router = new PancakeV3Router(v3Factory);

        // make sure v3Nfpm has allowance
        weth.approve(address(v3Nfpm), type(uint256).max);
        token2.approve(address(v3Nfpm), type(uint256).max);
        token3.approve(address(v3Nfpm), type(uint256).max);
        // approve v3Router
        weth.approve(address(v3Router), type(uint256).max);
        token2.approve(address(v3Router), type(uint256).max);
        token3.approve(address(v3Router), type(uint256).max);

        // 1. mint some liquidity to the v3 pool
        _mintV3Liquidity(address(weth), address(token2));

        // 1. mint some liquidity to the v2 pair
        _mintV2Liquidity(v2Pair);
        _mintV2Liquidity(v2PairWithoutNativeToken);

        // set stable swap
        stableSwapFactory = IStableSwapFactory(deployStableSwap(address(this)));
        stableSwapFactory.createSwapPair(address(token1), address(token2), 1000, 4000000, 5000000000);
        IStableSwapFactory.StableSwapPairInfo memory ssPairInfo =
            stableSwapFactory.getPairInfo(address(token1), address(token2));
        stableSwapPair = IStableSwap(ssPairInfo.swapContract);
        token1.approve(address(stableSwapPair), type(uint256).max);
        token2.approve(address(stableSwapPair), type(uint256).max);
        uint256[2] memory liquidityAmounts;
        liquidityAmounts[0] = 10 ether;
        liquidityAmounts[1] = 10 ether;
        stableSwapPair.add_liquidity(liquidityAmounts, 0);

        // deploy mixed quoter
        mixedQuoter = new MixedQuoter(
            // v3Deployer,
            address(v3Factory),
            address(v2Factory),
            address(stableSwapFactory),
            address(weth),
            clQuoter,
            binQuoter
        );

        seedBalance(address(this));
        approvePosmFor(address(this));
        mint(poolKey, -300, 300, 3000 ether, address(this), ZERO_BYTES);

        permit2Approve(address(this), permit2, address(weth), address(lpm));
        permit2Approve(address(this), permit2, address(token1), address(lpm));
        permit2Approve(address(this), permit2, address(token2), address(lpm));

        mintWithNative(0, poolKeyWithNativeToken, -300, 300, 1000 ether, address(this), ZERO_BYTES);

        mint(poolKeyWithWETH, -300, 300, 1000 ether, address(this), ZERO_BYTES);

        // mint some liquidity to the bin pool
        binPoolManager.initialize(binPoolKey, activeId);
        permit2Approve(address(this), permit2, address(token3), address(binPm));
        permit2Approve(address(this), permit2, address(token4), address(binPm));

        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinPositionManager.BinAddLiquidityParams memory addParams;
        addParams = _getAddParams(binPoolKey, binIds, 10 ether, 10 ether, activeId, address(this));
        Plan memory planner = Planner.init().add(Actions.BIN_ADD_LIQUIDITY, abi.encode(addParams));
        bytes memory payload = planner.finalizeModifyLiquidityWithClose(binPoolKey);
        binPm.modifyLiquidities(payload, block.timestamp + 1);
    }

    function test_bytecodeSize() public {
        vm.snapshotValue("MixedQuoterBytecode size", address(mixedQuoter).code.length);

        if (address(mixedQuoter).code.length > 24576) {
            revert ContractSizeTooLarge(address(mixedQuoter).code.length - 24576);
        }
    }

    function testQuoteExactInputSingleStable() public {
        address[] memory paths = new address[](2);
        paths[0] = address(token1);
        paths[1] = address(token2);

        bytes memory actions = new bytes(1);
        actions[0] = bytes1(uint8(MixedQuoterActions.SS_2_EXACT_INPUT_SINGLE));

        bytes[] memory params = new bytes[](1);

        (uint256 amountOut, uint256 gasEstimate) = mixedQuoter.quoteMixedExactInput(paths, actions, params, 1 ether);

        assertEq(amountOut, 999499143496490285);
        assertGt(gasEstimate, 40000);
        assertLt(gasEstimate, 50000);
    }

    function test_quoteMixedExactInputSharedContext_SS2_revert_INVALID_SWAP_DIRECTION() public {
        address[] memory paths = new address[](2);
        paths[0] = address(token1);
        paths[1] = address(token2);

        address[] memory paths2 = new address[](2);
        paths2[0] = address(token2);
        paths2[1] = address(token1);

        bytes memory actions = new bytes(1);
        actions[0] = bytes1(uint8(MixedQuoterActions.SS_2_EXACT_INPUT_SINGLE));

        bytes[] memory params = new bytes[](1);

        // path 1: (0.5)token1 -> token2
        // path 2: (0.5)token1 -> token2
        bytes[] memory multicallBytes = new bytes[](2);
        multicallBytes[0] = abi.encodeWithSelector(
            IMixedQuoter.quoteMixedExactInputSharedContext.selector, paths, actions, params, 0.5 ether
        );
        multicallBytes[1] = abi.encodeWithSelector(
            IMixedQuoter.quoteMixedExactInputSharedContext.selector, paths2, actions, params, 0.5 ether
        );
        vm.expectRevert(MixedQuoterRecorder.INVALID_SWAP_DIRECTION.selector);
        mixedQuoter.multicall(multicallBytes);
    }

    function test_quoteMixedExactInputSharedContext_SS2() public {
        address[] memory paths = new address[](2);
        paths[0] = address(token1);
        paths[1] = address(token2);
        bool isZeroForOne = token1 < token2;

        bytes memory actions = new bytes(1);
        actions[0] = bytes1(uint8(MixedQuoterActions.SS_2_EXACT_INPUT_SINGLE));

        bytes[] memory params = new bytes[](1);

        // swap 0.5 ether
        (uint256 amountOut, uint256 gasEstimate) = mixedQuoter.quoteMixedExactInput(paths, actions, params, 0.5 ether);
        uint256 swapPath1Output = amountOut;

        // swap 1 ether
        (amountOut, gasEstimate) = mixedQuoter.quoteMixedExactInput(paths, actions, params, 1 ether);
        uint256 swapPath2Output = amountOut - swapPath1Output;

        // path 1: (0.5)token1 -> token2
        // path 2: (0.5)token1 -> token2
        bytes[] memory multicallBytes = new bytes[](2);
        multicallBytes[0] = abi.encodeWithSelector(
            IMixedQuoter.quoteMixedExactInputSharedContext.selector, paths, actions, params, 0.5 ether
        );
        multicallBytes[1] = abi.encodeWithSelector(
            IMixedQuoter.quoteMixedExactInputSharedContext.selector, paths, actions, params, 0.5 ether
        );
        bytes[] memory results = mixedQuoter.multicall(multicallBytes);

        (uint256 amountOutOfRoute1,) = abi.decode(results[0], (uint256, uint256));
        (uint256 amountOutOfRoute2,) = abi.decode(results[1], (uint256, uint256));
        assertEq(amountOutOfRoute1, swapPath1Output);
        assertEq(amountOutOfRoute2, swapPath2Output);

        // swap 0.5 ether in stable swap
        uint256 route1TokenOutBalanceBefore = token2.balanceOf(address(this));
        stableSwapPair.exchange(isZeroForOne ? 0 : 1, isZeroForOne ? 1 : 0, 0.5 ether, 0);
        uint256 route1TokenOutBalanceAfter = token2.balanceOf(address(this));
        assertEq(route1TokenOutBalanceAfter - route1TokenOutBalanceBefore, amountOutOfRoute1);

        // swap 0.5 ether in stable swap
        uint256 route2TokenOutBalanceBefore = token2.balanceOf(address(this));
        stableSwapPair.exchange(isZeroForOne ? 0 : 1, isZeroForOne ? 1 : 0, 0.5 ether, 0);
        uint256 route2TokenOutBalanceAfter = token2.balanceOf(address(this));
        // not exactly equal , but difference is very small, less than 1/1000000
        assertApproxEqRel(route2TokenOutBalanceAfter - route2TokenOutBalanceBefore, amountOutOfRoute2, 1e18 / 1000000);
    }

    function testFuzz_quoteMixedExactInputSharedContext_SS2(uint8 firstSwapPercent, bool isZeroForOne) public {
        uint256 OneHundredPercent = type(uint8).max;
        vm.assume(firstSwapPercent > 0 && firstSwapPercent < OneHundredPercent);
        uint256 totalSwapAmount = 1 ether;
        uint128 firstSwapAmount = uint128((totalSwapAmount * firstSwapPercent) / OneHundredPercent);
        uint128 secondSwapAmount = uint128(totalSwapAmount - firstSwapAmount);
        (MockERC20 token0OfSS, MockERC20 token1OfSS) =
            address(token1) < address(token2) ? (token1, token2) : (token2, token1);

        address[] memory paths = new address[](2);
        if (isZeroForOne) {
            paths[0] = address(token0OfSS);
            paths[1] = address(token1OfSS);
        } else {
            paths[0] = address(token1OfSS);
            paths[1] = address(token0OfSS);
        }

        bytes memory actions = new bytes(1);
        actions[0] = bytes1(uint8(MixedQuoterActions.SS_2_EXACT_INPUT_SINGLE));

        bytes[] memory params = new bytes[](1);

        bytes[] memory multicallBytes = new bytes[](2);
        multicallBytes[0] = abi.encodeWithSelector(
            IMixedQuoter.quoteMixedExactInputSharedContext.selector, paths, actions, params, firstSwapAmount
        );
        multicallBytes[1] = abi.encodeWithSelector(
            IMixedQuoter.quoteMixedExactInputSharedContext.selector, paths, actions, params, secondSwapAmount
        );
        bytes[] memory results = mixedQuoter.multicall(multicallBytes);

        (uint256 amountOutOfRoute1,) = abi.decode(results[0], (uint256, uint256));
        (uint256 amountOutOfRoute2,) = abi.decode(results[1], (uint256, uint256));

        // first swap in stable swap
        uint256 route1TokenOutBalanceBefore;
        if (isZeroForOne) {
            route1TokenOutBalanceBefore = token1OfSS.balanceOf(address(this));
        } else {
            route1TokenOutBalanceBefore = token0OfSS.balanceOf(address(this));
        }
        stableSwapPair.exchange(isZeroForOne ? 0 : 1, isZeroForOne ? 1 : 0, firstSwapAmount, 0);
        uint256 route1TokenOutBalanceAfter;
        if (isZeroForOne) {
            route1TokenOutBalanceAfter = token1OfSS.balanceOf(address(this));
        } else {
            route1TokenOutBalanceAfter = token0OfSS.balanceOf(address(this));
        }
        assertEq(route1TokenOutBalanceAfter - route1TokenOutBalanceBefore, amountOutOfRoute1);

        // second swap in stable swap
        uint256 route2TokenOutBalanceBefore;
        if (isZeroForOne) {
            route2TokenOutBalanceBefore = token1OfSS.balanceOf(address(this));
        } else {
            route2TokenOutBalanceBefore = token0OfSS.balanceOf(address(this));
        }
        stableSwapPair.exchange(isZeroForOne ? 0 : 1, isZeroForOne ? 1 : 0, secondSwapAmount, 0);
        uint256 route2TokenOutBalanceAfter;
        if (isZeroForOne) {
            route2TokenOutBalanceAfter = token1OfSS.balanceOf(address(this));
        } else {
            route2TokenOutBalanceAfter = token0OfSS.balanceOf(address(this));
        }
        // not exactly equal , but difference is very small, less than 1/1000000
        assertApproxEqRel(route2TokenOutBalanceAfter - route2TokenOutBalanceBefore, amountOutOfRoute2, 1e18 / 1000000);
    }

    function testQuoteExactInputSingleV2() public {
        address[] memory paths = new address[](2);
        paths[0] = address(weth);
        paths[1] = address(token2);

        bytes memory actions = new bytes(1);
        actions[0] = bytes1(uint8(MixedQuoterActions.V2_EXACT_INPUT_SINGLE));
        bytes[] memory params = new bytes[](1);

        (uint256 amountOut, uint256 gasEstimate) = mixedQuoter.quoteMixedExactInput(paths, actions, params, 1 ether);

        assertEq(amountOut, 907024323709934075);
        assertGt(gasEstimate, 10000);
        assertLt(gasEstimate, 20000);
    }

    function test_quoteMixedExactInputSharedContext_V2_revert_INVALID_SWAP_DIRECTION() public {
        address[] memory paths = new address[](2);
        paths[0] = address(weth);
        paths[1] = address(token2);

        address[] memory paths2 = new address[](2);
        paths2[0] = address(token2);
        paths2[1] = address(weth);

        bytes memory actions = new bytes(1);
        actions[0] = bytes1(uint8(MixedQuoterActions.V2_EXACT_INPUT_SINGLE));
        bytes[] memory params = new bytes[](1);

        // path 1: (0.5)weth -> token2
        // path 2: (0.5)weth -> token2
        bytes[] memory multicallBytes = new bytes[](2);
        multicallBytes[0] = abi.encodeWithSelector(
            IMixedQuoter.quoteMixedExactInputSharedContext.selector, paths, actions, params, 0.5 ether
        );
        multicallBytes[1] = abi.encodeWithSelector(
            IMixedQuoter.quoteMixedExactInputSharedContext.selector, paths2, actions, params, 0.5 ether
        );
        vm.expectRevert(MixedQuoterRecorder.INVALID_SWAP_DIRECTION.selector);
        mixedQuoter.multicall(multicallBytes);
    }

    function test_quoteMixedExactInputSharedContext_V2() public {
        address[] memory paths = new address[](2);
        paths[0] = address(weth);
        paths[1] = address(token2);

        bytes memory actions = new bytes(1);
        actions[0] = bytes1(uint8(MixedQuoterActions.V2_EXACT_INPUT_SINGLE));
        bytes[] memory params = new bytes[](1);

        // path 1: (0.3)weth -> token2
        // path 2: (0.4)weth -> token2
        // path 3: (0.5)weth -> token2

        bytes[] memory multicallBytes = new bytes[](3);
        multicallBytes[0] = abi.encodeWithSelector(
            IMixedQuoter.quoteMixedExactInputSharedContext.selector, paths, actions, params, 0.3 ether
        );
        multicallBytes[1] = abi.encodeWithSelector(
            IMixedQuoter.quoteMixedExactInputSharedContext.selector, paths, actions, params, 0.4 ether
        );
        multicallBytes[2] = abi.encodeWithSelector(
            IMixedQuoter.quoteMixedExactInputSharedContext.selector, paths, actions, params, 0.5 ether
        );
        bytes[] memory results = mixedQuoter.multicall(multicallBytes);

        (uint256 amountOutOfRoute1,) = abi.decode(results[0], (uint256, uint256));
        (uint256 amountOutOfRoute2,) = abi.decode(results[1], (uint256, uint256));
        (uint256 amountOutOfRoute3,) = abi.decode(results[2], (uint256, uint256));

        // swap 0.3 ether in v2 pair
        uint256 route1TokenOutBalanceBefore = token2.balanceOf(address(this));
        _swapV2(address(weth), address(token2), 0.3 ether);
        uint256 route1TokenOutBalanceAfter = token2.balanceOf(address(this));
        assertEq(route1TokenOutBalanceAfter - route1TokenOutBalanceBefore, amountOutOfRoute1);

        // swap 0.4 ether in v2 pair
        uint256 route2TokenOutBalanceBefore = token2.balanceOf(address(this));
        _swapV2(address(weth), address(token2), 0.4 ether);
        uint256 route2TokenOutBalanceAfter = token2.balanceOf(address(this));
        assertEq(route2TokenOutBalanceAfter - route2TokenOutBalanceBefore, amountOutOfRoute2);

        // swap 0.5 ether in v2 pair
        uint256 route3TokenOutBalanceBefore = token2.balanceOf(address(this));
        _swapV2(address(weth), address(token2), 0.5 ether);
        uint256 route3TokenOutBalanceAfter = token2.balanceOf(address(this));
        assertEq(route3TokenOutBalanceAfter - route3TokenOutBalanceBefore, amountOutOfRoute3);
    }

    function testFuzz_quoteMixedExactInputSharedContext_V2(uint8 firstSwapPercent, bool isZeroForOne) public {
        uint256 OneHundredPercent = type(uint8).max;
        vm.assume(firstSwapPercent > 0 && firstSwapPercent < OneHundredPercent);
        uint256 totalSwapAmount = 1 ether;
        uint128 firstSwapAmount = uint128((totalSwapAmount * firstSwapPercent) / OneHundredPercent);
        uint128 secondSwapAmount = uint128(totalSwapAmount - firstSwapAmount);
        (MockERC20 token0OfV2, MockERC20 token1OfV2) =
            address(weth) < address(token2) ? (MockERC20(address(weth)), token2) : (token2, MockERC20(address(weth)));

        address[] memory paths = new address[](2);
        if (isZeroForOne) {
            paths[0] = address(token0OfV2);
            paths[1] = address(token1OfV2);
        } else {
            paths[0] = address(token1OfV2);
            paths[1] = address(token0OfV2);
        }

        bytes memory actions = new bytes(1);
        actions[0] = bytes1(uint8(MixedQuoterActions.V2_EXACT_INPUT_SINGLE));
        bytes[] memory params = new bytes[](1);

        bytes[] memory multicallBytes = new bytes[](2);
        multicallBytes[0] = abi.encodeWithSelector(
            IMixedQuoter.quoteMixedExactInputSharedContext.selector, paths, actions, params, firstSwapAmount
        );
        multicallBytes[1] = abi.encodeWithSelector(
            IMixedQuoter.quoteMixedExactInputSharedContext.selector, paths, actions, params, secondSwapAmount
        );
        bytes[] memory results = mixedQuoter.multicall(multicallBytes);

        (uint256 amountOutOfRoute1,) = abi.decode(results[0], (uint256, uint256));
        (uint256 amountOutOfRoute2,) = abi.decode(results[1], (uint256, uint256));

        // first swap in v2 pair
        uint256 route1TokenOutBalanceBefore;
        if (isZeroForOne) {
            route1TokenOutBalanceBefore = token1OfV2.balanceOf(address(this));
        } else {
            route1TokenOutBalanceBefore = token0OfV2.balanceOf(address(this));
        }
        if (isZeroForOne) {
            _swapV2(address(token0OfV2), address(token1OfV2), firstSwapAmount);
        } else {
            _swapV2(address(token1OfV2), address(token0OfV2), firstSwapAmount);
        }
        uint256 route1TokenOutBalanceAfter;
        if (isZeroForOne) {
            route1TokenOutBalanceAfter = token1OfV2.balanceOf(address(this));
        } else {
            route1TokenOutBalanceAfter = token0OfV2.balanceOf(address(this));
        }

        assertEq(route1TokenOutBalanceAfter - route1TokenOutBalanceBefore, amountOutOfRoute1);

        // second swap in v2 pair
        uint256 route2TokenOutBalanceBefore;
        if (isZeroForOne) {
            route2TokenOutBalanceBefore = token1OfV2.balanceOf(address(this));
        } else {
            route2TokenOutBalanceBefore = token0OfV2.balanceOf(address(this));
        }
        if (isZeroForOne) {
            _swapV2(address(token0OfV2), address(token1OfV2), secondSwapAmount);
        } else {
            _swapV2(address(token1OfV2), address(token0OfV2), secondSwapAmount);
        }
        uint256 route2TokenOutBalanceAfter;
        if (isZeroForOne) {
            route2TokenOutBalanceAfter = token1OfV2.balanceOf(address(this));
        } else {
            route2TokenOutBalanceAfter = token0OfV2.balanceOf(address(this));
        }
        assertEq(route2TokenOutBalanceAfter - route2TokenOutBalanceBefore, amountOutOfRoute2);
    }

    function testQuoteExactInputSingleV3() public {
        address[] memory paths = new address[](2);
        paths[0] = address(weth);
        paths[1] = address(token2);

        bytes memory actions = new bytes(1);
        actions[0] = bytes1(uint8(MixedQuoterActions.V3_EXACT_INPUT_SINGLE));

        bytes[] memory params = new bytes[](1);
        uint24 fee = 500;
        params[0] = abi.encode(fee);

        (uint256 amountOut, uint256 gasEstimate) = mixedQuoter.quoteMixedExactInput(paths, actions, params, 1 ether);

        assertEq(amountOut, 999002019627632472);
        assertGt(gasEstimate, 120000);
        assertLt(gasEstimate, 130000);
    }

    function test_quoteMixedExactInputSharedContext_V3_revert_INVALID_SWAP_DIRECTION() public {
        address[] memory paths = new address[](2);
        paths[0] = address(weth);
        paths[1] = address(token2);

        address[] memory paths2 = new address[](2);
        paths2[0] = address(token2);
        paths2[1] = address(weth);

        bytes memory actions = new bytes(1);
        actions[0] = bytes1(uint8(MixedQuoterActions.V3_EXACT_INPUT_SINGLE));

        bytes[] memory params = new bytes[](1);
        uint24 fee = 500;
        params[0] = abi.encode(fee);

        // path 1: (0.5)weth -> token2
        // path 2: (0.5)weth -> token2
        bytes[] memory multicallBytes = new bytes[](2);
        multicallBytes[0] = abi.encodeWithSelector(
            IMixedQuoter.quoteMixedExactInputSharedContext.selector, paths, actions, params, 0.5 ether
        );
        multicallBytes[1] = abi.encodeWithSelector(
            IMixedQuoter.quoteMixedExactInputSharedContext.selector, paths2, actions, params, 0.5 ether
        );
        vm.expectRevert(MixedQuoterRecorder.INVALID_SWAP_DIRECTION.selector);
        mixedQuoter.multicall(multicallBytes);
    }

    function test_quoteMixedExactInputSharedContext_V3() public {
        address[] memory paths = new address[](2);
        paths[0] = address(weth);
        paths[1] = address(token2);

        bytes memory actions = new bytes(1);
        actions[0] = bytes1(uint8(MixedQuoterActions.V3_EXACT_INPUT_SINGLE));

        bytes[] memory params = new bytes[](1);
        uint24 fee = 500;
        params[0] = abi.encode(fee);

        // swap 0.3 ether
        (uint256 amountOut,) = mixedQuoter.quoteMixedExactInput(paths, actions, params, 0.3 ether);
        uint256 swapPath1Output = amountOut;

        // swap 1 ether
        (amountOut,) = mixedQuoter.quoteMixedExactInput(paths, actions, params, 1 ether);
        uint256 swapPath2Output = amountOut - swapPath1Output;

        // path 1: (0.3)weth -> token2
        // path 2: (0.7)weth -> token2

        bytes[] memory multicallBytes = new bytes[](2);
        multicallBytes[0] = abi.encodeWithSelector(
            IMixedQuoter.quoteMixedExactInputSharedContext.selector, paths, actions, params, 0.3 ether
        );
        multicallBytes[1] = abi.encodeWithSelector(
            IMixedQuoter.quoteMixedExactInputSharedContext.selector, paths, actions, params, 0.7 ether
        );

        bytes[] memory results = mixedQuoter.multicall(multicallBytes);

        (uint256 amountOutOfRoute1,) = abi.decode(results[0], (uint256, uint256));
        (uint256 amountOutOfRoute2,) = abi.decode(results[1], (uint256, uint256));
        assertEq(amountOutOfRoute1, swapPath1Output);
        assertEq(amountOutOfRoute2, swapPath2Output);

        // swap 0.3 ether in v3 pool
        PancakeV3Router.ExactInputSingleParams memory swapParams1 = PancakeV3Router.ExactInputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(token2),
            fee: fee,
            recipient: address(this),
            deadline: block.timestamp + 1,
            amountIn: 0.3 ether,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        uint256 route1TokenOutBalanceBefore = token2.balanceOf(address(this));
        v3Router.exactInputSingle(swapParams1);
        uint256 route1TokenOutBalanceAfter = token2.balanceOf(address(this));

        assertEq(route1TokenOutBalanceAfter - route1TokenOutBalanceBefore, amountOutOfRoute1);

        //swap 0.7 ether in v3 pool
        PancakeV3Router.ExactInputSingleParams memory swapParams2 = PancakeV3Router.ExactInputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(token2),
            fee: fee,
            recipient: address(this),
            deadline: block.timestamp + 1,
            amountIn: 0.7 ether,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        uint256 route2TokenOutBalanceBefore = token2.balanceOf(address(this));
        v3Router.exactInputSingle(swapParams2);
        uint256 route2TokenOutBalanceAfter = token2.balanceOf(address(this));
        assertEq(route2TokenOutBalanceAfter - route2TokenOutBalanceBefore, amountOutOfRoute2 - 1);
    }

    function testFuzz_quoteMixedExactInputSharedContext_V3(uint8 firstSwapPercent, bool isZeroForOne) public {
        uint256 OneHundredPercent = type(uint8).max;
        vm.assume(firstSwapPercent > 0 && firstSwapPercent < OneHundredPercent);
        uint256 totalSwapAmount = 1 ether;
        uint128 firstSwapAmount = uint128((totalSwapAmount * firstSwapPercent) / OneHundredPercent);
        uint128 secondSwapAmount = uint128(totalSwapAmount - firstSwapAmount);
        (MockERC20 token0OfV3, MockERC20 token1OfV3) =
            address(weth) < address(token2) ? (MockERC20(address(weth)), token2) : (token2, MockERC20(address(weth)));

        address[] memory paths = new address[](2);
        if (isZeroForOne) {
            paths[0] = address(token0OfV3);
            paths[1] = address(token1OfV3);
        } else {
            paths[0] = address(token1OfV3);
            paths[1] = address(token0OfV3);
        }

        bytes memory actions = new bytes(1);
        actions[0] = bytes1(uint8(MixedQuoterActions.V3_EXACT_INPUT_SINGLE));

        bytes[] memory params = new bytes[](1);
        uint24 fee = 500;
        params[0] = abi.encode(fee);

        bytes[] memory multicallBytes = new bytes[](2);
        multicallBytes[0] = abi.encodeWithSelector(
            IMixedQuoter.quoteMixedExactInputSharedContext.selector, paths, actions, params, firstSwapAmount
        );
        multicallBytes[1] = abi.encodeWithSelector(
            IMixedQuoter.quoteMixedExactInputSharedContext.selector, paths, actions, params, secondSwapAmount
        );
        bytes[] memory results = mixedQuoter.multicall(multicallBytes);

        (uint256 amountOutOfRoute1,) = abi.decode(results[0], (uint256, uint256));
        (uint256 amountOutOfRoute2,) = abi.decode(results[1], (uint256, uint256));

        uint256 route1TokenOutBalanceBefore;
        if (isZeroForOne) {
            route1TokenOutBalanceBefore = token1OfV3.balanceOf(address(this));
        } else {
            route1TokenOutBalanceBefore = token0OfV3.balanceOf(address(this));
        }
        PancakeV3Router.ExactInputSingleParams memory swapParams1 = PancakeV3Router.ExactInputSingleParams({
            tokenIn: isZeroForOne ? address(token0OfV3) : address(token1OfV3),
            tokenOut: isZeroForOne ? address(token1OfV3) : address(token0OfV3),
            fee: fee,
            recipient: address(this),
            deadline: block.timestamp + 1,
            amountIn: firstSwapAmount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        v3Router.exactInputSingle(swapParams1);
        uint256 route1TokenOutBalanceAfter;
        if (isZeroForOne) {
            route1TokenOutBalanceAfter = token1OfV3.balanceOf(address(this));
        } else {
            route1TokenOutBalanceAfter = token0OfV3.balanceOf(address(this));
        }
        assertEq(route1TokenOutBalanceAfter - route1TokenOutBalanceBefore, amountOutOfRoute1);

        uint256 route2TokenOutBalanceBefore;
        if (isZeroForOne) {
            route2TokenOutBalanceBefore = token1OfV3.balanceOf(address(this));
        } else {
            route2TokenOutBalanceBefore = token0OfV3.balanceOf(address(this));
        }
        PancakeV3Router.ExactInputSingleParams memory swapParams2 = PancakeV3Router.ExactInputSingleParams({
            tokenIn: isZeroForOne ? address(token0OfV3) : address(token1OfV3),
            tokenOut: isZeroForOne ? address(token1OfV3) : address(token0OfV3),
            fee: fee,
            recipient: address(this),
            deadline: block.timestamp + 1,
            amountIn: secondSwapAmount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        v3Router.exactInputSingle(swapParams2);
        uint256 route2TokenOutBalanceAfter;
        if (isZeroForOne) {
            route2TokenOutBalanceAfter = token1OfV3.balanceOf(address(this));
        } else {
            route2TokenOutBalanceAfter = token0OfV3.balanceOf(address(this));
        }
        uint256 tokenOutReceived = route2TokenOutBalanceAfter - route2TokenOutBalanceBefore;
        uint256 diff = tokenOutReceived > amountOutOfRoute2
            ? tokenOutReceived - amountOutOfRoute2
            : amountOutOfRoute2 - tokenOutReceived;
        // not exactly equal in some cases , but difference is very small, only 1 wei or 2 wei
        assertLe(diff, 2);
    }

    function testInfiCLquoteExactInputSingle_ZeroForOne() public {
        address[] memory paths = new address[](2);
        paths[0] = address(Currency.unwrap(poolKey.currency0));
        paths[1] = address(Currency.unwrap(poolKey.currency1));

        bytes memory actions = new bytes(1);
        actions[0] = bytes1(uint8(MixedQuoterActions.INFI_CL_EXACT_INPUT_SINGLE));

        bytes[] memory params = new bytes[](1);
        params[0] =
            abi.encode(IMixedQuoter.QuoteMixedInfiExactInputSingleParams({poolKey: poolKey, hookData: ZERO_BYTES}));

        (uint256 amountOut, uint256 gasEstimate) = mixedQuoter.quoteMixedExactInput(paths, actions, params, 1 ether);

        assertEq(amountOut, 996668773744192346);

        (uint256 _amountOut, uint256 _gasEstimate) = clQuoter.quoteExactInputSingle(
            IQuoter.QuoteExactSingleParams({
                poolKey: poolKey, zeroForOne: true, exactAmount: 1 ether, hookData: ZERO_BYTES
            })
        );
        assertEq(_amountOut, amountOut);
        assertEq(_gasEstimate, gasEstimate);
        assertGt(_gasEstimate, 80000);
        assertLt(_gasEstimate, 90000);
    }

    function test_quoteMixedExactInputSharedContext_InfiCL() public {
        address[] memory paths = new address[](2);
        paths[0] = address(token0);
        paths[1] = address(token1);

        bytes memory actions = new bytes(1);
        actions[0] = bytes1(uint8(MixedQuoterActions.INFI_CL_EXACT_INPUT_SINGLE));

        bytes[] memory params = new bytes[](1);
        params[0] =
            abi.encode(IMixedQuoter.QuoteMixedInfiExactInputSingleParams({poolKey: poolKey, hookData: ZERO_BYTES}));
        // swap 0.5 ether
        (uint256 amountOut, uint256 gasEstimate) = mixedQuoter.quoteMixedExactInput(paths, actions, params, 0.5 ether);
        assertEq(amountOut, 498417179678643398);
        uint256 swapPath1Output = amountOut;

        // swap 1 ether
        (amountOut, gasEstimate) = mixedQuoter.quoteMixedExactInput(paths, actions, params, 1 ether);

        assertEq(amountOut, 996668773744192346);
        uint256 swapPath2Output = amountOut - swapPath1Output;

        // path 1: (0.5)token0 -> token1 , tokenOut should be 498417179678643398
        // path 2: (0.5)token0 -> token1, tokenOut should be 996668773744192346 - 498417179678643398 = 498251594065548948

        bytes[] memory multicallBytes = new bytes[](2);
        multicallBytes[0] = abi.encodeWithSelector(
            IMixedQuoter.quoteMixedExactInputSharedContext.selector, paths, actions, params, 0.5 ether
        );
        multicallBytes[1] = abi.encodeWithSelector(
            IMixedQuoter.quoteMixedExactInputSharedContext.selector, paths, actions, params, 0.5 ether
        );
        bytes[] memory results = mixedQuoter.multicall(multicallBytes);

        (uint256 amountOutOfRoute1,) = abi.decode(results[0], (uint256, uint256));
        (uint256 amountOutOfRoute2,) = abi.decode(results[1], (uint256, uint256));
        assertEq(amountOutOfRoute1, swapPath1Output);
        // -1 is due to precision round loss
        assertEq(amountOutOfRoute2, swapPath2Output - 1);

        // swap 0.5 ether in cl pool
        ICLRouterBase.CLSwapExactInputSingleParams memory swapParams1 =
            ICLRouterBase.CLSwapExactInputSingleParams(poolKey, true, 0.5 ether, 0, ZERO_BYTES);

        plan = plan.add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(swapParams1));
        bytes memory swapData1 = plan.finalizeSwap(poolKey.currency0, poolKey.currency1, ActionConstants.MSG_SENDER);
        uint256 route1Token1BalanceBefore = poolKey.currency1.balanceOf(address(this));
        infinityRouter.executeActions(swapData1);
        uint256 route1Token1BalanceAfter = poolKey.currency1.balanceOf(address(this));

        uint256 route1Token1Received = route1Token1BalanceAfter - route1Token1BalanceBefore;
        assertEq(route1Token1Received, swapPath1Output);

        // swap another 0.5 ether in infinity cl pool
        ICLRouterBase.CLSwapExactInputSingleParams memory swapParams2 =
            ICLRouterBase.CLSwapExactInputSingleParams(poolKey, true, 0.5 ether, 0, ZERO_BYTES);
        plan = Planner.init();
        plan = plan.add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(swapParams2));
        bytes memory swapData2 = plan.finalizeSwap(poolKey.currency0, poolKey.currency1, ActionConstants.MSG_SENDER);
        uint256 route2Token1BalanceBefore = poolKey.currency1.balanceOf(address(this));
        infinityRouter.executeActions(swapData2);
        uint256 route2Token1BalanceAfter = poolKey.currency1.balanceOf(address(this));

        uint256 route2Token1Received = route2Token1BalanceAfter - route2Token1BalanceBefore;
        // -1 is due to precision round loss
        assertEq(route2Token1Received, swapPath2Output - 1);
    }

    function testFuzz_quoteMixedExactInputSharedContext_InfiCL(uint8 firstSwapPercent, bool isZeroForOne) public {
        uint256 OneHundredPercent = type(uint8).max;
        vm.assume(firstSwapPercent > 0 && firstSwapPercent < OneHundredPercent);
        uint256 totalSwapAmount = 1 ether;
        uint128 firstSwapAmount = uint128((totalSwapAmount * firstSwapPercent) / OneHundredPercent);
        uint128 secondSwapAmount = uint128(totalSwapAmount - firstSwapAmount);

        address[] memory paths = new address[](2);
        if (isZeroForOne) {
            paths[0] = address(token0);
            paths[1] = address(token1);
        } else {
            paths[0] = address(token1);
            paths[1] = address(token0);
        }

        bytes memory actions = new bytes(1);
        actions[0] = bytes1(uint8(MixedQuoterActions.INFI_CL_EXACT_INPUT_SINGLE));

        bytes[] memory params = new bytes[](1);
        params[0] =
            abi.encode(IMixedQuoter.QuoteMixedInfiExactInputSingleParams({poolKey: poolKey, hookData: ZERO_BYTES}));

        bytes[] memory multicallBytes = new bytes[](2);
        multicallBytes[0] = abi.encodeWithSelector(
            IMixedQuoter.quoteMixedExactInputSharedContext.selector, paths, actions, params, firstSwapAmount
        );
        multicallBytes[1] = abi.encodeWithSelector(
            IMixedQuoter.quoteMixedExactInputSharedContext.selector, paths, actions, params, secondSwapAmount
        );
        bytes[] memory results = mixedQuoter.multicall(multicallBytes);

        (uint256 amountOutOfRoute1,) = abi.decode(results[0], (uint256, uint256));
        (uint256 amountOutOfRoute2,) = abi.decode(results[1], (uint256, uint256));

        // first swap in infinity cl pool
        ICLRouterBase.CLSwapExactInputSingleParams memory swapParams1 =
            ICLRouterBase.CLSwapExactInputSingleParams(poolKey, isZeroForOne, firstSwapAmount, 0, ZERO_BYTES);

        plan = plan.add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(swapParams1));
        bytes memory swapData1;
        if (isZeroForOne) {
            swapData1 = plan.finalizeSwap(poolKey.currency0, poolKey.currency1, ActionConstants.MSG_SENDER);
        } else {
            swapData1 = plan.finalizeSwap(poolKey.currency1, poolKey.currency0, ActionConstants.MSG_SENDER);
        }
        uint256 route1TokenOutBalanceBefore;
        if (isZeroForOne) {
            route1TokenOutBalanceBefore = poolKey.currency1.balanceOf(address(this));
        } else {
            route1TokenOutBalanceBefore = poolKey.currency0.balanceOf(address(this));
        }
        infinityRouter.executeActions(swapData1);
        uint256 route1TokenOutBalanceAfter;
        if (isZeroForOne) {
            route1TokenOutBalanceAfter = poolKey.currency1.balanceOf(address(this));
        } else {
            route1TokenOutBalanceAfter = poolKey.currency0.balanceOf(address(this));
        }

        uint256 route1TokenOutReceived = route1TokenOutBalanceAfter - route1TokenOutBalanceBefore;
        assertEq(route1TokenOutReceived, amountOutOfRoute1);

        // second swap in infinity cl pool
        ICLRouterBase.CLSwapExactInputSingleParams memory swapParams2 =
            ICLRouterBase.CLSwapExactInputSingleParams(poolKey, isZeroForOne, secondSwapAmount, 0, ZERO_BYTES);
        plan = Planner.init();
        plan = plan.add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(swapParams2));
        bytes memory swapData2;
        if (isZeroForOne) {
            swapData2 = plan.finalizeSwap(poolKey.currency0, poolKey.currency1, ActionConstants.MSG_SENDER);
        } else {
            swapData2 = plan.finalizeSwap(poolKey.currency1, poolKey.currency0, ActionConstants.MSG_SENDER);
        }
        uint256 route2TokenOutBalanceBefore;
        if (isZeroForOne) {
            route2TokenOutBalanceBefore = poolKey.currency1.balanceOf(address(this));
        } else {
            route2TokenOutBalanceBefore = poolKey.currency0.balanceOf(address(this));
        }
        infinityRouter.executeActions(swapData2);
        uint256 route2TokenOutBalanceAfter;
        if (isZeroForOne) {
            route2TokenOutBalanceAfter = poolKey.currency1.balanceOf(address(this));
        } else {
            route2TokenOutBalanceAfter = poolKey.currency0.balanceOf(address(this));
        }

        uint256 route2TokenOutReceived = route2TokenOutBalanceAfter - route2TokenOutBalanceBefore;
        assertEq(route2TokenOutReceived, amountOutOfRoute2);
    }

    function testInfiCLquoteExactInputSingle_OneForZero() public {
        address[] memory paths = new address[](2);
        paths[0] = address(Currency.unwrap(poolKey.currency1));
        paths[1] = address(Currency.unwrap(poolKey.currency0));

        bytes memory actions = new bytes(1);
        actions[0] = bytes1(uint8(MixedQuoterActions.INFI_CL_EXACT_INPUT_SINGLE));

        bytes[] memory params = new bytes[](1);
        params[0] =
            abi.encode(IMixedQuoter.QuoteMixedInfiExactInputSingleParams({poolKey: poolKey, hookData: ZERO_BYTES}));

        (uint256 amountOut, uint256 gasEstimate) = mixedQuoter.quoteMixedExactInput(paths, actions, params, 1 ether);

        assertEq(amountOut, 996668773744192346);

        (uint256 _amountOut, uint256 _gasEstimate) = clQuoter.quoteExactInputSingle(
            IQuoter.QuoteExactSingleParams({
                poolKey: poolKey, zeroForOne: false, exactAmount: 1 ether, hookData: ZERO_BYTES
            })
        );
        assertEq(_amountOut, amountOut);
        assertEq(_gasEstimate, gasEstimate);
        assertGt(_gasEstimate, 80000);
        assertLt(_gasEstimate, 90000);
    }

    function testInfiCLquoteExactInputSingle_ZeroForOne_WETHPair() public {
        address[] memory paths = new address[](2);
        if (address(weth) < address(token2)) {
            paths[0] = address(weth);
            paths[1] = address(token2);
        } else {
            paths[0] = address(token2);
            paths[1] = address(weth);
        }

        bytes memory actions = new bytes(1);
        actions[0] = bytes1(uint8(MixedQuoterActions.INFI_CL_EXACT_INPUT_SINGLE));

        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(
            IMixedQuoter.QuoteMixedInfiExactInputSingleParams({poolKey: poolKeyWithWETH, hookData: ZERO_BYTES})
        );

        (uint256 amountOut, uint256 gasEstimate) = mixedQuoter.quoteMixedExactInput(paths, actions, params, 1 ether);

        assertEq(amountOut, 996006981039903216);

        (uint256 _amountOut, uint256 _gasEstimate) = clQuoter.quoteExactInputSingle(
            IQuoter.QuoteExactSingleParams({
                poolKey: poolKeyWithWETH, zeroForOne: true, exactAmount: 1 ether, hookData: ZERO_BYTES
            })
        );
        assertEq(_amountOut, amountOut);
        assertEq(_gasEstimate, gasEstimate);
        assertGt(_gasEstimate, 80000);
        assertLt(_gasEstimate, 90000);
    }

    function testBinQuoteExactInputSingle_ZeroForOne() public {
        address[] memory paths = new address[](2);
        paths[0] = address(token3);
        paths[1] = address(token4);

        bytes memory actions = new bytes(1);
        actions[0] = bytes1(uint8(MixedQuoterActions.INFI_BIN_EXACT_INPUT_SINGLE));

        bytes[] memory params = new bytes[](1);
        params[0] =
            abi.encode(IMixedQuoter.QuoteMixedInfiExactInputSingleParams({poolKey: binPoolKey, hookData: ZERO_BYTES}));

        (uint256 amountOut, uint256 gasEstimate) = mixedQuoter.quoteMixedExactInput(paths, actions, params, 1 ether);

        assertEq(amountOut, 997000000000000000);

        (uint256 _amountOut, uint256 _gasEstimate) = binQuoter.quoteExactInputSingle(
            IQuoter.QuoteExactSingleParams({
                poolKey: binPoolKey, zeroForOne: true, exactAmount: 1 ether, hookData: ZERO_BYTES
            })
        );
        assertEq(_amountOut, amountOut);
        assertEq(_gasEstimate, gasEstimate);
        assertGt(_gasEstimate, 40000);
        assertLt(_gasEstimate, 50000);
    }

    function test_quoteMixedExactInputSharedContext_InfiBin() public {
        address[] memory paths = new address[](2);
        paths[0] = address(token3);
        paths[1] = address(token4);

        bytes memory actions = new bytes(1);
        actions[0] = bytes1(uint8(MixedQuoterActions.INFI_BIN_EXACT_INPUT_SINGLE));

        bytes[] memory params = new bytes[](1);
        params[0] =
            abi.encode(IMixedQuoter.QuoteMixedInfiExactInputSingleParams({poolKey: binPoolKey, hookData: ZERO_BYTES}));
        // swap 0.5 ether
        (uint256 amountOut, uint256 gasEstimate) = mixedQuoter.quoteMixedExactInput(paths, actions, params, 0.5 ether);
        uint256 swapPath1Output = amountOut;

        // swap 1 ether
        (amountOut, gasEstimate) = mixedQuoter.quoteMixedExactInput(paths, actions, params, 1 ether);
        uint256 swapPath2Output = amountOut - swapPath1Output;

        bytes[] memory multicallBytes = new bytes[](2);
        multicallBytes[0] = abi.encodeWithSelector(
            IMixedQuoter.quoteMixedExactInputSharedContext.selector, paths, actions, params, 0.5 ether
        );
        multicallBytes[1] = abi.encodeWithSelector(
            IMixedQuoter.quoteMixedExactInputSharedContext.selector, paths, actions, params, 0.5 ether
        );
        bytes[] memory results = mixedQuoter.multicall(multicallBytes);

        (uint256 amountOutOfRoute1,) = abi.decode(results[0], (uint256, uint256));
        (uint256 amountOutOfRoute2,) = abi.decode(results[1], (uint256, uint256));
        assertEq(amountOutOfRoute1, swapPath1Output);
        assertEq(amountOutOfRoute2, swapPath2Output);

        // swap 0.5 ether in infinity bin pool
        IBinRouterBase.BinSwapExactInputSingleParams memory swapParams1 =
            IBinRouterBase.BinSwapExactInputSingleParams(binPoolKey, true, 0.5 ether, 0, ZERO_BYTES);
        plan = plan.add(Actions.BIN_SWAP_EXACT_IN_SINGLE, abi.encode(swapParams1));
        bytes memory swapData1 =
            plan.finalizeSwap(binPoolKey.currency0, binPoolKey.currency1, ActionConstants.MSG_SENDER);
        uint256 route1TokenOutBalanceBefore = binPoolKey.currency1.balanceOf(address(this));
        infinityRouter.executeActions(swapData1);
        uint256 route1TokenOutBalanceAfter = binPoolKey.currency1.balanceOf(address(this));

        uint256 route1TokenOutReceived = route1TokenOutBalanceAfter - route1TokenOutBalanceBefore;
        assertEq(route1TokenOutReceived, amountOutOfRoute1);

        // swap another 0.5 ether in infinity bin pool
        IBinRouterBase.BinSwapExactInputSingleParams memory swapParams2 =
            IBinRouterBase.BinSwapExactInputSingleParams(binPoolKey, true, 0.5 ether, 0, ZERO_BYTES);
        plan = Planner.init();
        plan = plan.add(Actions.BIN_SWAP_EXACT_IN_SINGLE, abi.encode(swapParams2));
        bytes memory swapData2 =
            plan.finalizeSwap(binPoolKey.currency0, binPoolKey.currency1, ActionConstants.MSG_SENDER);
        uint256 route2TokenOutBalanceBefore = binPoolKey.currency1.balanceOf(address(this));
        infinityRouter.executeActions(swapData2);
        uint256 route2TokenOutBalanceAfter = binPoolKey.currency1.balanceOf(address(this));

        uint256 route2TokenOutReceived = route2TokenOutBalanceAfter - route2TokenOutBalanceBefore;
        assertEq(route2TokenOutReceived, amountOutOfRoute2);
    }

    function testFuzz_quoteMixedExactInputSharedContext_InfiBin(uint8 firstSwapPercent, bool isZeroForOne) public {
        uint256 OneHundredPercent = type(uint8).max;
        vm.assume(firstSwapPercent > 0 && firstSwapPercent < OneHundredPercent);
        uint256 totalSwapAmount = 1 ether;
        uint128 firstSwapAmount = uint128((totalSwapAmount * firstSwapPercent) / OneHundredPercent);
        uint128 secondSwapAmount = uint128(totalSwapAmount - firstSwapAmount);

        address[] memory paths = new address[](2);
        if (isZeroForOne) {
            paths[0] = address(token3);
            paths[1] = address(token4);
        } else {
            paths[0] = address(token4);
            paths[1] = address(token3);
        }

        bytes memory actions = new bytes(1);
        actions[0] = bytes1(uint8(MixedQuoterActions.INFI_BIN_EXACT_INPUT_SINGLE));

        bytes[] memory params = new bytes[](1);
        params[0] =
            abi.encode(IMixedQuoter.QuoteMixedInfiExactInputSingleParams({poolKey: binPoolKey, hookData: ZERO_BYTES}));

        bytes[] memory multicallBytes = new bytes[](2);
        multicallBytes[0] = abi.encodeWithSelector(
            IMixedQuoter.quoteMixedExactInputSharedContext.selector, paths, actions, params, firstSwapAmount
        );
        multicallBytes[1] = abi.encodeWithSelector(
            IMixedQuoter.quoteMixedExactInputSharedContext.selector, paths, actions, params, secondSwapAmount
        );
        bytes[] memory results = mixedQuoter.multicall(multicallBytes);

        (uint256 amountOutOfRoute1,) = abi.decode(results[0], (uint256, uint256));
        (uint256 amountOutOfRoute2,) = abi.decode(results[1], (uint256, uint256));

        // first swap in infinity bin pool
        IBinRouterBase.BinSwapExactInputSingleParams memory swapParams1 =
            IBinRouterBase.BinSwapExactInputSingleParams(binPoolKey, isZeroForOne, firstSwapAmount, 0, ZERO_BYTES);

        plan = plan.add(Actions.BIN_SWAP_EXACT_IN_SINGLE, abi.encode(swapParams1));
        bytes memory swapData1;
        if (isZeroForOne) {
            swapData1 = plan.finalizeSwap(binPoolKey.currency0, binPoolKey.currency1, ActionConstants.MSG_SENDER);
        } else {
            swapData1 = plan.finalizeSwap(binPoolKey.currency1, binPoolKey.currency0, ActionConstants.MSG_SENDER);
        }
        uint256 route1TokenOutBalanceBefore;
        if (isZeroForOne) {
            route1TokenOutBalanceBefore = binPoolKey.currency1.balanceOf(address(this));
        } else {
            route1TokenOutBalanceBefore = binPoolKey.currency0.balanceOf(address(this));
        }
        infinityRouter.executeActions(swapData1);
        uint256 route1TokenOutBalanceAfter;
        if (isZeroForOne) {
            route1TokenOutBalanceAfter = binPoolKey.currency1.balanceOf(address(this));
        } else {
            route1TokenOutBalanceAfter = binPoolKey.currency0.balanceOf(address(this));
        }

        uint256 route1TokenOutReceived = route1TokenOutBalanceAfter - route1TokenOutBalanceBefore;
        assertEq(route1TokenOutReceived, amountOutOfRoute1);

        // second swap in infinity bin pool
        IBinRouterBase.BinSwapExactInputSingleParams memory swapParams2 =
            IBinRouterBase.BinSwapExactInputSingleParams(binPoolKey, isZeroForOne, secondSwapAmount, 0, ZERO_BYTES);
        plan = Planner.init();
        plan = plan.add(Actions.BIN_SWAP_EXACT_IN_SINGLE, abi.encode(swapParams2));
        bytes memory swapData2;
        if (isZeroForOne) {
            swapData2 = plan.finalizeSwap(binPoolKey.currency0, binPoolKey.currency1, ActionConstants.MSG_SENDER);
        } else {
            swapData2 = plan.finalizeSwap(binPoolKey.currency1, binPoolKey.currency0, ActionConstants.MSG_SENDER);
        }
        uint256 route2TokenOutBalanceBefore;
        if (isZeroForOne) {
            route2TokenOutBalanceBefore = binPoolKey.currency1.balanceOf(address(this));
        } else {
            route2TokenOutBalanceBefore = binPoolKey.currency0.balanceOf(address(this));
        }
        infinityRouter.executeActions(swapData2);
        uint256 route2TokenOutBalanceAfter;
        if (isZeroForOne) {
            route2TokenOutBalanceAfter = binPoolKey.currency1.balanceOf(address(this));
        } else {
            route2TokenOutBalanceAfter = binPoolKey.currency0.balanceOf(address(this));
        }

        uint256 route2TokenOutReceived = route2TokenOutBalanceAfter - route2TokenOutBalanceBefore;
        assertEq(route2TokenOutReceived, amountOutOfRoute2);
    }

    function testBinQuoteExactInputSingle_OneForZero() public {
        address[] memory paths = new address[](2);
        paths[0] = address(token4);
        paths[1] = address(token3);

        bytes memory actions = new bytes(1);
        actions[0] = bytes1(uint8(MixedQuoterActions.INFI_BIN_EXACT_INPUT_SINGLE));

        bytes[] memory params = new bytes[](1);
        params[0] =
            abi.encode(IMixedQuoter.QuoteMixedInfiExactInputSingleParams({poolKey: binPoolKey, hookData: ZERO_BYTES}));

        (uint256 amountOut, uint256 gasEstimate) = mixedQuoter.quoteMixedExactInput(paths, actions, params, 1 ether);

        assertEq(amountOut, 997000000000000000);

        (uint256 _amountOut, uint256 _gasEstimate) = binQuoter.quoteExactInputSingle(
            IQuoter.QuoteExactSingleParams({
                poolKey: binPoolKey, zeroForOne: false, exactAmount: 1 ether, hookData: ZERO_BYTES
            })
        );
        assertEq(_amountOut, amountOut);
        assertEq(_gasEstimate, gasEstimate);
        assertGt(_gasEstimate, 40000);
        assertLt(_gasEstimate, 50000);
    }

    // route 1: path 1: token0 -> token1 -> token2 -> weth, cl pool -> ss pool -> v3 pool
    // route 2: path 2:  token0 -> token1 -> token2 -> weth, cl pool -> ss pool -> v2 pool
    // route 2: path 3:  token2 -> weth, v2 pool
    function test_quoteMixedExactInputSharedContext_multi_route() public {
        // path: token0 -> token1 -> token2 -> weth
        address[] memory paths1 = new address[](4);
        paths1[0] = address(token0);
        paths1[1] = address(token1);
        paths1[2] = address(token2);
        paths1[3] = address(weth);
        // cl pool -> ss pool -> v3 pool
        bytes memory actions1 = new bytes(3);
        actions1[0] = bytes1(uint8(MixedQuoterActions.INFI_CL_EXACT_INPUT_SINGLE));
        actions1[1] = bytes1(uint8(MixedQuoterActions.SS_2_EXACT_INPUT_SINGLE));
        actions1[2] = bytes1(uint8(MixedQuoterActions.V3_EXACT_INPUT_SINGLE));
        bytes[] memory params1 = new bytes[](3);
        params1[0] =
            abi.encode(IMixedQuoter.QuoteMixedInfiExactInputSingleParams({poolKey: poolKey, hookData: ZERO_BYTES}));
        params1[1] = new bytes(0);
        uint24 fee = 500;
        params1[2] = abi.encode(fee);

        // path: token0 -> token1 -> token2 -> weth
        address[] memory paths2 = new address[](4);
        paths2[0] = address(token0);
        paths2[1] = address(token1);
        paths2[2] = address(token2);
        paths2[3] = address(weth);
        // cl pool -> ss pool -> v2 pool
        bytes memory actions2 = new bytes(3);
        actions2[0] = bytes1(uint8(MixedQuoterActions.INFI_CL_EXACT_INPUT_SINGLE));
        actions2[1] = bytes1(uint8(MixedQuoterActions.SS_2_EXACT_INPUT_SINGLE));
        actions2[2] = bytes1(uint8(MixedQuoterActions.V2_EXACT_INPUT_SINGLE));

        bytes[] memory params2 = new bytes[](3);
        params2[0] =
            abi.encode(IMixedQuoter.QuoteMixedInfiExactInputSingleParams({poolKey: poolKey, hookData: ZERO_BYTES}));
        params2[1] = new bytes(0);
        params2[2] = new bytes(0);

        // path: token2 -> weth
        address[] memory paths3 = new address[](2);
        paths3[0] = address(token2);
        paths3[1] = address(weth);
        // v2 pool
        bytes memory actions3 = new bytes(1);
        actions3[0] = bytes1(uint8(MixedQuoterActions.V2_EXACT_INPUT_SINGLE));
        bytes[] memory params3 = new bytes[](1);
        params3[0] = new bytes(0);

        bytes[] memory multicallBytes = new bytes[](3);
        multicallBytes[0] = abi.encodeWithSelector(
            IMixedQuoter.quoteMixedExactInputSharedContext.selector, paths1, actions1, params1, 1 ether
        );
        multicallBytes[1] = abi.encodeWithSelector(
            IMixedQuoter.quoteMixedExactInputSharedContext.selector, paths2, actions2, params2, 1 ether
        );
        multicallBytes[2] = abi.encodeWithSelector(
            IMixedQuoter.quoteMixedExactInputSharedContext.selector, paths3, actions3, params3, 1 ether
        );
        bytes[] memory results = mixedQuoter.multicall(multicallBytes);

        (uint256 amountOutOfRoute1,) = abi.decode(results[0], (uint256, uint256));
        (uint256 amountOutOfRoute2,) = abi.decode(results[1], (uint256, uint256));
        (uint256 amountOutOfRoute3,) = abi.decode(results[2], (uint256, uint256));

        // route 1: path 1: token0 -> token1 -> token2 -> weth, cl pool -> ss pool -> v3 pool
        uint256 route1Token1BalanceBefore = token1.balanceOf(address(this));
        // swap 1 ether in infinity cl pool
        ICLRouterBase.CLSwapExactInputSingleParams memory swapParams1 =
            ICLRouterBase.CLSwapExactInputSingleParams(poolKey, true, 1 ether, 0, ZERO_BYTES);
        plan = plan.add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(swapParams1));
        bytes memory swapData1 = plan.finalizeSwap(poolKey.currency0, poolKey.currency1, ActionConstants.MSG_SENDER);
        infinityRouter.executeActions(swapData1);
        uint256 route1Token1BalanceAfter = token1.balanceOf(address(this));
        uint256 route1Token1Received = route1Token1BalanceAfter - route1Token1BalanceBefore;

        // swap route1Token1Received in ss pool
        uint256 route1Token2BalanceBefore = token2.balanceOf(address(this));
        bool isZeroForOneOfRout1SS = address(token1) < address(token2);
        stableSwapPair.exchange(isZeroForOneOfRout1SS ? 0 : 1, isZeroForOneOfRout1SS ? 1 : 0, route1Token1Received, 0);
        uint256 route1Token2BalanceAfter = token2.balanceOf(address(this));
        uint256 route1Token2Received = route1Token2BalanceAfter - route1Token2BalanceBefore;

        // swap route1Token2Received in v3 pool
        uint256 route1WethBalanceBefore = weth.balanceOf(address(this));
        PancakeV3Router.ExactInputSingleParams memory swapParams2 = PancakeV3Router.ExactInputSingleParams({
            tokenIn: address(token2),
            tokenOut: address(weth),
            fee: fee,
            recipient: address(this),
            deadline: block.timestamp + 300,
            amountIn: route1Token2Received,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        v3Router.exactInputSingle(swapParams2);
        uint256 route1WethBalanceAfter = weth.balanceOf(address(this));
        uint256 route1WethReceived = route1WethBalanceAfter - route1WethBalanceBefore;
        assertEq(route1WethReceived, amountOutOfRoute1);

        // route 2: path 2: token0 -> token1 -> token2 -> weth, cl pool -> ss pool -> v2 pool
        uint256 route2Token1BalanceBefore = token1.balanceOf(address(this));
        // swap 1 ether in infinity cl pool
        ICLRouterBase.CLSwapExactInputSingleParams memory swapParams3 =
            ICLRouterBase.CLSwapExactInputSingleParams(poolKey, true, 1 ether, 0, ZERO_BYTES);
        plan = Planner.init();
        plan = plan.add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(swapParams3));
        bytes memory swapData3 = plan.finalizeSwap(poolKey.currency0, poolKey.currency1, ActionConstants.MSG_SENDER);
        infinityRouter.executeActions(swapData3);
        uint256 route2Token1BalanceAfter = token1.balanceOf(address(this));
        uint256 route2Token1Received = route2Token1BalanceAfter - route2Token1BalanceBefore;

        // swap route2Token1Received in ss pool
        uint256 route2Token2BalanceBefore = token2.balanceOf(address(this));
        bool isZeroForOneOfRout2SS = address(token1) < address(token2);
        stableSwapPair.exchange(isZeroForOneOfRout2SS ? 0 : 1, isZeroForOneOfRout2SS ? 1 : 0, route2Token1Received, 0);
        uint256 route2Token2BalanceAfter = token2.balanceOf(address(this));
        uint256 route2Token2Received = route2Token2BalanceAfter - route2Token2BalanceBefore;

        // swap route2Token2Received in v2 pool
        uint256 route2WethBalanceBefore = weth.balanceOf(address(this));
        _swapV2(address(token2), address(weth), route2Token2Received);
        uint256 route2WethBalanceAfter = weth.balanceOf(address(this));
        uint256 route2WethReceived = route2WethBalanceAfter - route2WethBalanceBefore;
        // not exactly equal , but difference is very small, less than 1/1000000
        assertApproxEqRel(route2WethReceived, amountOutOfRoute2, 1e18 / 1000000);

        // route 3: path 3: token2 -> weth, v2 pool
        uint256 route3WethBalanceBefore = weth.balanceOf(address(this));
        _swapV2(address(token2), address(weth), 1 ether);
        uint256 route3WethBalanceAfter = weth.balanceOf(address(this));
        uint256 route3WethReceived = route3WethBalanceAfter - route3WethBalanceBefore;
        // not exactly equal , but difference is very small, less than 1/100000
        assertApproxEqRel(route3WethReceived, amountOutOfRoute3, 1e18 / 100000);
    }

    // token0 -> token1 -> token2
    // infinity CL Pool -> SS Pool
    function testQuoteMixedTwoHops_InfiCl_SS() public {
        address[] memory paths = new address[](3);
        paths[0] = address(token0);
        paths[1] = address(token1);
        paths[2] = address(token2);

        bytes memory actions = new bytes(2);
        actions[0] = bytes1(uint8(MixedQuoterActions.INFI_CL_EXACT_INPUT_SINGLE));
        actions[1] = bytes1(uint8(MixedQuoterActions.SS_2_EXACT_INPUT_SINGLE));

        bytes[] memory params = new bytes[](2);
        params[0] =
            abi.encode(IMixedQuoter.QuoteMixedInfiExactInputSingleParams({poolKey: poolKey, hookData: ZERO_BYTES}));
        params[1] = new bytes(0);

        (uint256 amountOut, uint256 gasEstimate) = mixedQuoter.quoteMixedExactInput(paths, actions, params, 1 ether);

        assertEq(amountOut, 996169927245114903);
        assertGt(gasEstimate, 130000);
        assertLt(gasEstimate, 140000);
    }

    // token0 -> token1 -> token2 -> WETH
    // infinity CL Pool -> SS Pool -> V3 Pool
    function testQuoteMixedThreeHops_InfiCl_SS_V3() public {
        address[] memory paths = new address[](4);
        paths[0] = address(token0);
        paths[1] = address(token1);
        paths[2] = address(token2);
        paths[3] = address(weth);

        bytes memory actions = new bytes(3);
        actions[0] = bytes1(uint8(MixedQuoterActions.INFI_CL_EXACT_INPUT_SINGLE));
        actions[1] = bytes1(uint8(MixedQuoterActions.SS_2_EXACT_INPUT_SINGLE));
        actions[2] = bytes1(uint8(MixedQuoterActions.V3_EXACT_INPUT_SINGLE));

        bytes[] memory params = new bytes[](3);
        params[0] =
            abi.encode(IMixedQuoter.QuoteMixedInfiExactInputSingleParams({poolKey: poolKey, hookData: ZERO_BYTES}));
        params[1] = new bytes(0);
        uint24 fee = 500;
        params[2] = abi.encode(fee);

        (uint256 amountOut, uint256 gasEstimate) = mixedQuoter.quoteMixedExactInput(paths, actions, params, 1 ether);

        assertEq(amountOut, 995177668263126217);
        assertGt(gasEstimate, 260000);
        assertLt(gasEstimate, 270000);
    }

    // token0 -> token1 -> token2 -> token3 -> token4
    // infinity CL Pool -> SS Pool -> V2 Pool -> infinity Bin Pool
    function testQuoteMixedFourHops_InfiCl_SS_V2_InfiBin() public {
        address[] memory paths = new address[](5);
        paths[0] = address(token0);
        paths[1] = address(token1);
        paths[2] = address(token2);
        paths[3] = address(token3);
        paths[4] = address(token4);

        bytes memory actions = new bytes(4);
        actions[0] = bytes1(uint8(MixedQuoterActions.INFI_CL_EXACT_INPUT_SINGLE));
        actions[1] = bytes1(uint8(MixedQuoterActions.SS_2_EXACT_INPUT_SINGLE));
        actions[2] = bytes1(uint8(MixedQuoterActions.V2_EXACT_INPUT_SINGLE));
        actions[3] = bytes1(uint8(MixedQuoterActions.INFI_BIN_EXACT_INPUT_SINGLE));

        bytes[] memory params = new bytes[](4);
        params[0] =
            abi.encode(IMixedQuoter.QuoteMixedInfiExactInputSingleParams({poolKey: poolKey, hookData: ZERO_BYTES}));
        params[1] = new bytes(0);
        params[2] = new bytes(0);
        params[3] =
            abi.encode(IMixedQuoter.QuoteMixedInfiExactInputSingleParams({poolKey: binPoolKey, hookData: ZERO_BYTES}));

        (uint256 amountOut, uint256 gasEstimate) = mixedQuoter.quoteMixedExactInput(paths, actions, params, 1 ether);

        assertEq(amountOut, 901152761185198407);
        assertGt(gasEstimate, 180000);
        assertLt(gasEstimate, 200000);
    }

    // token2 -> WETH -> token1
    // V3 WETH Pool -> infinity Native Pool
    function testQuoteMixed_ConvertWETHToNative_V3WETHPair_InfiCLNativePair() public {
        address[] memory paths = new address[](3);
        paths[0] = address(token2);
        paths[1] = address(weth);
        paths[2] = address(token1);

        bytes memory actions = new bytes(2);
        actions[0] = bytes1(uint8(MixedQuoterActions.V3_EXACT_INPUT_SINGLE));
        actions[1] = bytes1(uint8(MixedQuoterActions.INFI_CL_EXACT_INPUT_SINGLE));

        bytes[] memory params = new bytes[](2);
        uint24 fee = 500;
        params[0] = abi.encode(fee);
        params[1] = abi.encode(
            IMixedQuoter.QuoteMixedInfiExactInputSingleParams({poolKey: poolKeyWithNativeToken, hookData: ZERO_BYTES})
        );

        (uint256 amountOut, uint256 gasEstimate) = mixedQuoter.quoteMixedExactInput(paths, actions, params, 1 ether);

        assertEq(amountOut, 995013974661415835);
        assertGt(gasEstimate, 210000);
        assertLt(gasEstimate, 220000);
    }

    // token1 -> address(0) -> token2
    // infinity CL Native Pool -> V3 WETH Pool
    function testQuoteMixed_ConvertNativeToWETH_InfiCLNativePair_V3WETHPair() public {
        address[] memory paths = new address[](3);
        paths[0] = address(token1);
        paths[1] = address(0);
        paths[2] = address(token2);

        bytes memory actions = new bytes(2);
        actions[0] = bytes1(uint8(MixedQuoterActions.INFI_CL_EXACT_INPUT_SINGLE));
        actions[1] = bytes1(uint8(MixedQuoterActions.V3_EXACT_INPUT_SINGLE));

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            IMixedQuoter.QuoteMixedInfiExactInputSingleParams({poolKey: poolKeyWithNativeToken, hookData: ZERO_BYTES})
        );
        uint24 fee = 500;
        params[1] = abi.encode(fee);

        (uint256 amountOut, uint256 gasEstimate) = mixedQuoter.quoteMixedExactInput(paths, actions, params, 1 ether);

        assertEq(amountOut, 995014965144446181);
        assertGt(gasEstimate, 200000);
        assertLt(gasEstimate, 210000);
    }

    function _mintV3Liquidity(address _token0, address _token1) internal {
        (_token0, _token1) = _token0 < _token1 ? (_token0, _token1) : (_token1, _token0);
        v3Nfpm.createAndInitializePoolIfNecessary(_token0, _token1, 500, INIT_SQRT_PRICE);
        IV3NonfungiblePositionManager.MintParams memory mintParams = IV3NonfungiblePositionManager.MintParams({
            token0: _token0,
            token1: _token1,
            fee: 500,
            tickLower: -100,
            tickUpper: 100,
            amount0Desired: 10 ether,
            amount1Desired: 10 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 100
        });

        v3Nfpm.mint(mintParams);
    }

    function _mintV3Liquidity(address _token0, address _token1, uint256 amount0, uint256 amount1) internal {
        int24 tickLower;
        int24 tickUpper;
        if (_token0 < _token1) {
            tickLower = -100;
            tickUpper = 200;
        } else {
            (_token0, _token1) = (_token1, _token0);
            (amount0, amount1) = (amount1, amount0);
            tickLower = -200;
            tickUpper = 100;
        }
        v3Nfpm.createAndInitializePoolIfNecessary(_token0, _token1, 500, INIT_SQRT_PRICE);

        IV3NonfungiblePositionManager.MintParams memory mintParams = IV3NonfungiblePositionManager.MintParams({
            token0: _token0,
            token1: _token1,
            fee: 500,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: amount0 - 0.1 ether,
            amount1Min: amount1 - 0.1 ether,
            recipient: address(this),
            deadline: block.timestamp + 100
        });

        v3Nfpm.mint(mintParams);
    }

    function _mintV2Liquidity(IPancakePair pair) public {
        IERC20(pair.token0()).transfer(address(pair), 10 ether);
        IERC20(pair.token1()).transfer(address(pair), 10 ether);

        pair.mint(address(this));
    }

    function _mintV2Liquidity(IPancakePair pair, uint256 amount0, uint256 amount1) public {
        IERC20(pair.token0()).transfer(address(pair), amount0);
        IERC20(pair.token1()).transfer(address(pair), amount1);

        pair.mint(address(this));
    }

    function _swapV2(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256) {
        (address v2Token0, address v2Token1) = tokenIn < tokenOut ? (tokenIn, tokenOut) : (tokenOut, tokenIn);
        IPancakePair pair = IPancakePair(v2Factory.getPair(v2Token0, v2Token1));
        require(address(pair) != address(0), "Pair doesn't exist");

        IERC20(tokenIn).transfer(address(pair), amountIn);
        (uint256 reserveIn, uint256 reserveOut) = V3SmartRouterHelper.getReserves(address(v2Factory), tokenIn, tokenOut);
        uint256 amountOut = V3SmartRouterHelper.getAmountOut(amountIn, reserveIn, reserveOut);

        (uint256 amount0Out, uint256 amount1Out) =
            tokenIn == v2Token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));

        pair.swap(amount0Out, amount1Out, address(this), new bytes(0));
        return amountOut;
    }

    function _getBytecodePath() internal pure returns (string memory) {
        // Create a Pancakeswap V2 pair
        // relative to the root of the project
        // https://etherscan.io/address/0x1097053Fd2ea711dad45caCcc45EfF7548fCB362#code
        return "./test/bin/pcsV2Factory.bytecode";
    }

    function _getDeployerBytecodePath() internal pure returns (string memory) {
        // https://etherscan.io/address/0x41ff9AA7e16B8B1a8a8dc4f0eFacd93D02d071c9#code
        return "./test/bin/pcsV3Deployer.bytecode";
    }

    function _getFactoryBytecodePath() internal pure returns (string memory) {
        // https://etherscan.io/address/0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865#code
        return "./test/bin/pcsV3Factory.bytecode";
    }

    function _getNfpmBytecodePath() internal pure returns (string memory) {
        // https://etherscan.io/address/0x46A15B0b27311cedF172AB29E4f4766fbE7F4364#code
        return "./test/bin/pcsV3Nfpm.bytecode";
    }

    receive() external payable {}
}
