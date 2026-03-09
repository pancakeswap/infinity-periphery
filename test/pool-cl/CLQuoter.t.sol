// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IQuoter} from "../../src/interfaces/IQuoter.sol";
import {ICLQuoter} from "../../src/pool-cl/interfaces/ICLQuoter.sol";
import {CLQuoter} from "../../src/pool-cl/lens/CLQuoter.sol";
import {LiquidityAmounts} from "../../src/pool-cl/libraries/LiquidityAmounts.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {SafeCast} from "infinity-core/src/libraries/SafeCast.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolModifyPositionTest} from "./shared/PoolModifyPositionTest.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {PathKey} from "../../src/libraries/PathKey.sol";
import {QuoterRevert} from "../../src/libraries/QuoterRevert.sol";

contract CLQuoterTest is Test, Deployers {
    using SafeCast for *;

    error ContractSizeTooLarge(uint256 diff);

    // Min tick for full range with tick spacing of 60
    int24 internal constant MIN_TICK = -887220;
    // Max tick for full range with tick spacing of 60
    int24 internal constant MAX_TICK = -MIN_TICK;

    uint160 internal constant SQRT_RATIO_100_102 = 78447570448055484695608110440;
    uint160 internal constant SQRT_RATIO_102_100 = 80016521857016594389520272648;

    uint256 internal constant CONTROLLER_GAS_LIMIT = 500000;

    IVault public vault;
    CLPoolManager public manager;

    CLQuoter quoter;

    PoolModifyPositionTest positionManager;

    MockERC20 token0;
    MockERC20 token1;
    MockERC20 token2;

    PoolKey key01;
    PoolKey key02;
    PoolKey key12;

    MockERC20[] tokenPath;

    function setUp() public {
        (vault, manager) = createFreshManager();
        quoter = new CLQuoter(address(manager));
        positionManager = new PoolModifyPositionTest(vault, manager);

        // salts are chosen so that address(token0) < address(token1) && address(token1) < address(token2)
        token0 = new MockERC20("Test0", "0", 18);
        vm.etch(address(0x1111), address(token0).code);
        token0 = MockERC20(address(0x1111));
        token0.mint(address(this), 2 ** 128);

        vm.etch(address(0x2222), address(token0).code);
        token1 = MockERC20(address(0x2222));
        token1.mint(address(this), 2 ** 128);

        vm.etch(address(0x3333), address(token0).code);
        token2 = MockERC20(address(0x3333));
        token2.mint(address(this), 2 ** 128);

        key01 = createPoolKey(token0, token1, address(0));
        key02 = createPoolKey(token0, token2, address(0));
        key12 = createPoolKey(token1, token2, address(0));
        setupPool(key01);
        setupPool(key12);
        setupPoolMultiplePositions(key02);
    }

    function testCLQuoter_quoteExactInputSingle_ZeroForOne_MultiplePositions() public {
        uint256 amountIn = 10000;
        uint256 expectedAmountOut = 9871;

        (uint256 _amountOut, uint256 _gasEstimate) = quoter.quoteExactInputSingle(
            IQuoter.QuoteExactSingleParams({
                poolKey: key02, zeroForOne: true, exactAmount: uint128(amountIn), hookData: ZERO_BYTES
            })
        );

        assertEq(_amountOut, expectedAmountOut);
        assertGt(_gasEstimate, 140000);
        assertLt(_gasEstimate, 150000);
    }

    function test_bytecodeSize() public {
        vm.snapshotValue("CLQuoterBytecode size", address(quoter).code.length);

        // forge coverage will run with '--ir-minimum' which set optimizer run to min
        // thus we do not want to revert for forge coverage case
        if (vm.envExists("FOUNDRY_PROFILE") && address(quoter).code.length > 24576) {
            revert ContractSizeTooLarge(address(quoter).code.length - 24576);
        }
    }

    function testCLQuoter_quoteExactInputSingle_OneForZero_MultiplePositions() public {
        uint256 amountIn = 10000;
        uint256 expectedAmountOut = 9871;

        (uint256 _amountOut, uint256 _gasEstimate) = quoter.quoteExactInputSingle(
            IQuoter.QuoteExactSingleParams({
                poolKey: key02, zeroForOne: false, exactAmount: uint128(amountIn), hookData: ZERO_BYTES
            })
        );

        assertEq(_amountOut, expectedAmountOut);
        assertGt(_gasEstimate, 140000);
        assertLt(_gasEstimate, 150000);
    }

    // nested self-call into lockAcquired reverts
    function testCLQuoter_callLockAcquired_reverts() public {
        vm.expectRevert();
        vm.prank(address(vault));
        quoter.lockAcquired(abi.encodeWithSelector(quoter.lockAcquired.selector, address(this), "0x"));
    }

    function testCLQuoter_quoteExactInput_0to2_2TicksLoaded() public {
        tokenPath.push(token0);
        tokenPath.push(token2);
        ICLQuoter.QuoteExactParams memory params = getExactInputParams(tokenPath, 10000);

        (uint256 _amountOut, uint256 _gasEstimate) = quoter.quoteExactInput(params);

        assertEq(_amountOut, 9871);
        assertGt(_gasEstimate, 140000);
        assertLt(_gasEstimate, 150000);
    }

    function testCLQuoter_quoteExactInput_0to2_2TicksLoaded_initialiedAfter() public {
        tokenPath.push(token0);
        tokenPath.push(token2);

        // The swap amount is set such that the active tick after the swap is -120.
        // -120 is an initialized tick for this pool. We check that we don't count it.
        ICLQuoter.QuoteExactParams memory params = getExactInputParams(tokenPath, 6200);

        (uint256 _amountOut, uint256 _gasEstimate) = quoter.quoteExactInput(params);

        assertEq(_amountOut, 6143);
        assertGt(_gasEstimate, 110000);
        assertLt(_gasEstimate, 120000);
    }

    function testCLQuoter_quoteExactInput_0to2_1TickLoaded() public {
        tokenPath.push(token0);
        tokenPath.push(token2);

        // The swap amount is set such that the active tick after the swap is -60.
        // -60 is an initialized tick for this pool. We check that we don't count it.
        ICLQuoter.QuoteExactParams memory params = getExactInputParams(tokenPath, 4000);

        (uint256 _amountOut, uint256 _gasEstimate) = quoter.quoteExactInput(params);

        assertEq(_amountOut, 3971);
        assertGt(_gasEstimate, 110000);
        assertLt(_gasEstimate, 120000);
    }

    function testCLQuoter_quoteExactInput_0to2_0TickLoaded_startingNotInitialized() public {
        tokenPath.push(token0);
        tokenPath.push(token2);
        ICLQuoter.QuoteExactParams memory params = getExactInputParams(tokenPath, 10);

        (uint256 _amountOut, uint256 _gasEstimate) = quoter.quoteExactInput(params);

        assertEq(_amountOut, 8);
        assertGt(_gasEstimate, 80000);
        assertLt(_gasEstimate, 90000);
    }

    function testCLQuoter_quoteExactInput_0to2_0TickLoaded_startingInitialized() public {
        setupPoolWithZeroTickInitialized(key02);
        tokenPath.push(token0);
        tokenPath.push(token2);
        ICLQuoter.QuoteExactParams memory params = getExactInputParams(tokenPath, 10);

        (uint256 _amountOut, uint256 _gasEstimate) = quoter.quoteExactInput(params);

        assertEq(_amountOut, 8);
        assertGt(_gasEstimate, 90000);
        assertLt(_gasEstimate, 100000);
    }

    function testCLQuoter_quoteExactInput_2to0_2TicksLoaded() public {
        tokenPath.push(token2);
        tokenPath.push(token0);
        ICLQuoter.QuoteExactParams memory params = getExactInputParams(tokenPath, 10000);

        (uint256 _amountOut, uint256 _gasEstimate) = quoter.quoteExactInput(params);

        assertEq(_amountOut, 9871);
        assertGt(_gasEstimate, 140000);
        assertLt(_gasEstimate, 150000);
    }

    function testCLQuoter_quoteExactInput_2to0_2TicksLoaded_initialiedAfter() public {
        tokenPath.push(token2);
        tokenPath.push(token0);

        // The swap amount is set such that the active tick after the swap is 120.
        // 120 is an initialized tick for this pool. We check that we don't count it.
        ICLQuoter.QuoteExactParams memory params = getExactInputParams(tokenPath, 6250);

        (uint256 _amountOut, uint256 _gasEstimate) = quoter.quoteExactInput(params);

        assertEq(_amountOut, 6190);
        assertGt(_gasEstimate, 140000);
        assertLt(_gasEstimate, 150000);
    }

    function testCLQuoter_quoteExactInput_2to0_0TickLoaded_startingInitialized() public {
        setupPoolWithZeroTickInitialized(key02);
        tokenPath.push(token2);
        tokenPath.push(token0);
        ICLQuoter.QuoteExactParams memory params = getExactInputParams(tokenPath, 200);

        (uint256 _amountOut, uint256 _gasEstimate) = quoter.quoteExactInput(params);

        assertEq(_amountOut, 198);
        assertGt(_gasEstimate, 70000);
        assertLt(_gasEstimate, 80000);
    }

    // 2->0 starting not initialized
    function testCLQuoter_quoteExactInput_2to0_0TickLoaded_startingNotInitialized() public {
        tokenPath.push(token2);
        tokenPath.push(token0);
        ICLQuoter.QuoteExactParams memory params = getExactInputParams(tokenPath, 103);

        (uint256 _amountOut, uint256 _gasEstimate) = quoter.quoteExactInput(params);

        assertEq(_amountOut, 101);
        assertGt(_gasEstimate, 70000);
        assertLt(_gasEstimate, 80000);
    }

    function testCLQuoter_quoteExactInput_2to1() public {
        tokenPath.push(token2);
        tokenPath.push(token1);
        ICLQuoter.QuoteExactParams memory params = getExactInputParams(tokenPath, 10000);

        (uint256 _amountOut, uint256 _gasEstimate) = quoter.quoteExactInput(params);

        assertEq(_amountOut, 9871);
        assertGt(_gasEstimate, 70000);
        assertLt(_gasEstimate, 80000);
    }

    function testCLQuoter_quoteExactInput_0to2to1() public {
        tokenPath.push(token0);
        tokenPath.push(token2);
        tokenPath.push(token1);
        ICLQuoter.QuoteExactParams memory params = getExactInputParams(tokenPath, 10000);

        (uint256 _amountOut, uint256 _gasEstimate) = quoter.quoteExactInput(params);

        assertEq(_amountOut, 9745);
        assertGt(_gasEstimate, 200000);
        assertLt(_gasEstimate, 210000);
    }

    function testCLQuoter_revert_UnexpectedRevertBytes() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                QuoterRevert.UnexpectedRevertBytes.selector,
                abi.encodeWithSelector(IQuoter.NotEnoughLiquidity.selector, key01.toId())
            )
        );
        quoter.quoteExactOutputSingle(
            IQuoter.QuoteExactSingleParams({
                poolKey: key01, zeroForOne: true, exactAmount: type(uint128).max, hookData: ZERO_BYTES
            })
        );
    }

    function testCLQuoter_quoteExactOutput_0to2_2TicksLoaded() public {
        tokenPath.push(token0);
        tokenPath.push(token2);
        ICLQuoter.QuoteExactParams memory params = getExactOutputParams(tokenPath, 15000);

        (uint256 _amountIn, uint256 _gasEstimate) = quoter.quoteExactOutput(params);

        assertEq(_amountIn, 15273);
        assertGt(_gasEstimate, 140000);
        assertLt(_gasEstimate, 150000);
    }

    function testCLQuoter_quoteExactOutput_0to2_1TickLoaded_initialiedAfter() public {
        tokenPath.push(token0);
        tokenPath.push(token2);

        ICLQuoter.QuoteExactParams memory params = getExactOutputParams(tokenPath, 6143);

        (uint256 _amountIn, uint256 _gasEstimate) = quoter.quoteExactOutput(params);

        assertEq(_amountIn, 6200);
        assertGt(_gasEstimate, 110000);
        assertLt(_gasEstimate, 120000);
    }

    function testCLQuoter_quoteExactOutput_0to2_1TickLoaded() public {
        tokenPath.push(token0);
        tokenPath.push(token2);

        ICLQuoter.QuoteExactParams memory params = getExactOutputParams(tokenPath, 4000);

        (uint256 _amountIn, uint256 _gasEstimate) = quoter.quoteExactOutput(params);

        assertEq(_amountIn, 4029);
        assertGt(_gasEstimate, 110000);
        assertLt(_gasEstimate, 120000);
    }

    function testCLQuoter_quoteExactOutput_0to2_0TickLoaded_startingInitialized() public {
        setupPoolWithZeroTickInitialized(key02);
        tokenPath.push(token0);
        tokenPath.push(token2);

        ICLQuoter.QuoteExactParams memory params = getExactOutputParams(tokenPath, 100);

        (uint256 _amountIn, uint256 _gasEstimate) = quoter.quoteExactOutput(params);

        assertEq(_amountIn, 102);
        assertGt(_gasEstimate, 90000);
        assertLt(_gasEstimate, 100000);
    }

    function testCLQuoter_quoteExactOutput_0to2_0TickLoaded_startingNotInitialized() public {
        tokenPath.push(token0);
        tokenPath.push(token2);

        ICLQuoter.QuoteExactParams memory params = getExactOutputParams(tokenPath, 10);

        (uint256 _amountIn, uint256 _gasEstimate) = quoter.quoteExactOutput(params);

        assertEq(_amountIn, 12);
        assertGt(_gasEstimate, 80000);
        assertLt(_gasEstimate, 90000);
    }

    function testCLQuoter_quoteExactOutput_2to0_2TicksLoaded() public {
        tokenPath.push(token2);
        tokenPath.push(token0);
        ICLQuoter.QuoteExactParams memory params = getExactOutputParams(tokenPath, 15000);

        (uint256 _amountIn, uint256 _gasEstimate) = quoter.quoteExactOutput(params);

        assertEq(_amountIn, 15273);
        assertGt(_gasEstimate, 140000);
        assertLt(_gasEstimate, 150000);
    }

    function testCLQuoter_quoteExactOutput_2to0_2TicksLoaded_initialiedAfter() public {
        tokenPath.push(token2);
        tokenPath.push(token0);

        ICLQuoter.QuoteExactParams memory params = getExactOutputParams(tokenPath, 6223);

        (uint256 _amountIn, uint256 _gasEstimate) = quoter.quoteExactOutput(params);

        assertEq(_amountIn, 6283);
        assertGt(_gasEstimate, 140000);
        assertLt(_gasEstimate, 150000);
    }

    function testCLQuoter_quoteExactOutput_2to0_1TickLoaded() public {
        tokenPath.push(token2);
        tokenPath.push(token0);

        ICLQuoter.QuoteExactParams memory params = getExactOutputParams(tokenPath, 6000);
        (uint256 _amountIn, uint256 _gasEstimate) = quoter.quoteExactOutput(params);

        assertEq(_amountIn, 6055);
        assertGt(_gasEstimate, 110000);
        assertLt(_gasEstimate, 120000);
    }

    function testCLQuoter_quoteExactOutput_2to1() public {
        tokenPath.push(token2);
        tokenPath.push(token1);

        ICLQuoter.QuoteExactParams memory params = getExactOutputParams(tokenPath, 9871);
        (uint256 _amountIn, uint256 _gasEstimate) = quoter.quoteExactOutput(params);

        assertEq(_amountIn, 10000);
        assertGt(_gasEstimate, 70000);
        assertLt(_gasEstimate, 80000);
    }

    function testCLQuoter_quoteExactOutput_0to2to1() public {
        tokenPath.push(token0);
        tokenPath.push(token2);
        tokenPath.push(token1);

        ICLQuoter.QuoteExactParams memory params = getExactOutputParams(tokenPath, 9745);
        (uint256 _amountIn, uint256 _gasEstimate) = quoter.quoteExactOutput(params);

        assertEq(_amountIn, 10000);
        assertGt(_gasEstimate, 205000);
        assertLt(_gasEstimate, 215000);
    }

    function createPoolKey(MockERC20 tokenA, MockERC20 tokenB, address hookAddr)
        internal
        view
        returns (PoolKey memory)
    {
        if (address(tokenA) > address(tokenB)) (tokenA, tokenB) = (tokenB, tokenA);
        return PoolKey({
            currency0: Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(tokenB)),
            hooks: IHooks(hookAddr),
            poolManager: manager,
            fee: uint24(3000),
            parameters: bytes32(uint256(0x3c0000))
        });
    }

    function setupPool(PoolKey memory poolKey) internal {
        manager.initialize(poolKey, SQRT_RATIO_1_1);
        MockERC20(Currency.unwrap(poolKey.currency0)).approve(address(positionManager), type(uint256).max);
        MockERC20(Currency.unwrap(poolKey.currency1)).approve(address(positionManager), type(uint256).max);
        positionManager.modifyPosition(
            poolKey,
            ICLPoolManager.ModifyLiquidityParams(
                MIN_TICK,
                MAX_TICK,
                calculateLiquidityFromAmounts(SQRT_RATIO_1_1, MIN_TICK, MAX_TICK, 1000000, 1000000).toInt256(),
                bytes32(0)
            ),
            ZERO_BYTES
        );
    }

    function setupPoolMultiplePositions(PoolKey memory poolKey) internal {
        manager.initialize(poolKey, SQRT_RATIO_1_1);
        MockERC20(Currency.unwrap(poolKey.currency0)).approve(address(positionManager), type(uint256).max);
        MockERC20(Currency.unwrap(poolKey.currency1)).approve(address(positionManager), type(uint256).max);
        positionManager.modifyPosition(
            poolKey,
            ICLPoolManager.ModifyLiquidityParams(
                MIN_TICK,
                MAX_TICK,
                calculateLiquidityFromAmounts(SQRT_RATIO_1_1, MIN_TICK, MAX_TICK, 1000000, 1000000).toInt256(),
                bytes32(0)
            ),
            ZERO_BYTES
        );
        positionManager.modifyPosition(
            poolKey,
            ICLPoolManager.ModifyLiquidityParams(
                -60, 60, calculateLiquidityFromAmounts(SQRT_RATIO_1_1, -60, 60, 100, 100).toInt256(), bytes32(0)
            ),
            ZERO_BYTES
        );
        positionManager.modifyPosition(
            poolKey,
            ICLPoolManager.ModifyLiquidityParams(
                -120, 120, calculateLiquidityFromAmounts(SQRT_RATIO_1_1, -120, 120, 100, 100).toInt256(), bytes32(0)
            ),
            ZERO_BYTES
        );
    }

    function setupPoolWithZeroTickInitialized(PoolKey memory poolKey) internal {
        PoolId poolId = poolKey.toId();
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) {
            manager.initialize(poolKey, SQRT_RATIO_1_1);
        }

        MockERC20(Currency.unwrap(poolKey.currency0)).approve(address(positionManager), type(uint256).max);
        MockERC20(Currency.unwrap(poolKey.currency1)).approve(address(positionManager), type(uint256).max);
        positionManager.modifyPosition(
            poolKey,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: calculateLiquidityFromAmounts(SQRT_RATIO_1_1, MIN_TICK, MAX_TICK, 1000000, 1000000)
                    .toInt256(),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        positionManager.modifyPosition(
            poolKey,
            ICLPoolManager.ModifyLiquidityParams(
                0, 60, calculateLiquidityFromAmounts(SQRT_RATIO_1_1, 0, 60, 100, 100).toInt256(), bytes32(0)
            ),
            ZERO_BYTES
        );
        positionManager.modifyPosition(
            poolKey,
            ICLPoolManager.ModifyLiquidityParams(
                -120, 0, calculateLiquidityFromAmounts(SQRT_RATIO_1_1, -120, 0, 100, 100).toInt256(), bytes32(0)
            ),
            ZERO_BYTES
        );
    }

    function calculateLiquidityFromAmounts(
        uint160 sqrtRatioX96,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);
        liquidity =
            LiquidityAmounts.getLiquidityForAmounts(sqrtRatioX96, sqrtRatioAX96, sqrtRatioBX96, amount0, amount1);
    }

    function getExactInputParams(MockERC20[] memory _tokenPath, uint256 amountIn)
        internal
        view
        returns (ICLQuoter.QuoteExactParams memory params)
    {
        PathKey[] memory path = new PathKey[](_tokenPath.length - 1);
        for (uint256 i = 0; i < _tokenPath.length - 1; i++) {
            path[i] = PathKey(
                Currency.wrap(address(_tokenPath[i + 1])),
                3000,
                IHooks(address(0)),
                ICLPoolManager(manager),
                bytes(""),
                bytes32(uint256(0x3c0000))
            );
        }

        params.exactCurrency = Currency.wrap(address(_tokenPath[0]));
        params.path = path;
        params.exactAmount = uint128(amountIn);
    }

    function getExactOutputParams(MockERC20[] memory _tokenPath, uint256 amountOut)
        internal
        view
        returns (ICLQuoter.QuoteExactParams memory params)
    {
        PathKey[] memory path = new PathKey[](_tokenPath.length - 1);
        for (uint256 i = _tokenPath.length - 1; i > 0; i--) {
            path[i - 1] = PathKey(
                Currency.wrap(address(_tokenPath[i - 1])),
                3000,
                IHooks(address(0)),
                ICLPoolManager(manager),
                bytes(""),
                bytes32(uint256(0x3c0000))
            );
        }

        params.exactCurrency = Currency.wrap(address(_tokenPath[_tokenPath.length - 1]));
        params.path = path;
        params.exactAmount = uint128(amountOut);
    }
}
