// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {V3SmartRouterHelper} from "../../src/libraries/external/V3SmartRouterHelper.sol";
import {IPancakeV3Factory} from "../../src/interfaces/external/IPancakeV3Factory.sol";
import {IPancakeV3Pool} from "../../src/interfaces/external/IPancakeV3Pool.sol";

/// @dev A mock PancakeV3Router contract that can be used to test v3 swap.
/// @dev Only support exactInputSingle for now.
/// @dev This contract is only used for testing, and should not be deployed in production.
contract PancakeV3Router {
    IPancakeV3Factory public factory;

    constructor(IPancakeV3Factory _factory) {
        factory = _factory;
    }

    /// @dev Returns the pool for the given token pair and fee. The pool contract may or may not exist.
    function getPool(address tokenA, address tokenB, uint24 fee) private view returns (IPancakeV3Pool) {
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
        return IPancakeV3Pool(factory.getPool(tokenA, tokenB, fee));
    }

    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        require(amount0Delta > 0 || amount1Delta > 0); // swaps entirely within 0-liquidity regions are not supported
        (address tokenIn, address tokenOut, uint24 fee, address payer) =
            abi.decode(data, (address, address, uint24, address));
        V3SmartRouterHelper.verifyCallback(address(factory), tokenIn, tokenOut, fee);

        (bool isExactInput, uint256 amountToPay) =
            amount0Delta > 0 ? (tokenIn < tokenOut, uint256(amount0Delta)) : (tokenOut < tokenIn, uint256(amount1Delta));
        if (isExactInput) {
            IERC20(tokenIn).transferFrom(payer, msg.sender, amountToPay);
        }
    }

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut) {
        amountOut = exactInputInternal(
            params.amountIn,
            params.recipient,
            params.sqrtPriceLimitX96,
            abi.encode(params.tokenIn, params.tokenOut, params.fee, msg.sender)
        );
        require(amountOut >= params.amountOutMinimum, "Too little received");
    }

    function exactInputInternal(uint256 amountIn, address recipient, uint160 sqrtPriceLimitX96, bytes memory data)
        private
        returns (uint256 amountOut)
    {
        // allow swapping to the router address with address 0
        if (recipient == address(0)) recipient = address(this);

        (address tokenIn, address tokenOut, uint24 fee,) = abi.decode(data, (address, address, uint24, address));

        bool zeroForOne = tokenIn < tokenOut;

        (int256 amount0, int256 amount1) = getPool(tokenIn, tokenOut, fee)
            .swap(
                recipient,
                zeroForOne,
                int256(amountIn),
                sqrtPriceLimitX96 == 0
                    ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                    : sqrtPriceLimitX96,
                data
            );

        return uint256(-(zeroForOne ? amount1 : amount0));
    }
}
