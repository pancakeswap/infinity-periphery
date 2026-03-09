// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IStableSwapFactory} from "../../interfaces/external/IStableSwapFactory.sol";
import {IPancakePair} from "../../interfaces/external/IPancakePair.sol";
import {IPancakeV3Pool} from "../../interfaces/external/IPancakeV3Pool.sol";
import {IPancakeFactory} from "../../interfaces/external/IPancakeFactory.sol";
import {IPancakeV3Factory} from "../../interfaces/external/IPancakeV3Factory.sol";

/// @dev Copy from https://github.com/pancakeswap/pancake-v3-contracts/blob/main/projects/router/contracts/libraries/SmartRouterHelper.sol
library V3SmartRouterHelper {
    /**
     * Stable *************************************************
     */
    // get the pool info in stable swap
    function getStableInfo(address stableSwapFactory, address input, address output, uint256 flag)
        internal
        view
        returns (uint256 i, uint256 j, address swapContract)
    {
        if (flag == 2) {
            IStableSwapFactory.StableSwapPairInfo memory info =
                IStableSwapFactory(stableSwapFactory).getPairInfo(input, output);
            i = input == info.token0 ? 0 : 1;
            j = (i == 0) ? 1 : 0;
            swapContract = info.swapContract;
        } else if (flag == 3) {
            IStableSwapFactory.StableSwapThreePoolPairInfo memory info =
                IStableSwapFactory(stableSwapFactory).getThreePoolPairInfo(input, output);

            if (input == info.token0) i = 0;
            else if (input == info.token1) i = 1;
            else if (input == info.token2) i = 2;

            if (output == info.token0) j = 0;
            else if (output == info.token1) j = 1;
            else if (output == info.token2) j = 2;

            swapContract = info.swapContract;
        }

        require(swapContract != address(0), "getStableInfo: invalid pool address");
    }

    /**
     * V2 *************************************************
     */

    // returns sorted token addresses, used to handle return values from pairs sorted in this order
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB);
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0));
    }

    /// @dev PancakeSwap is a multichain DEX, we have different factories on different chains.
    /// If we use the CREATE2 rule to calculate the pool address, we need to update the INIT_CODE_HASH for each chain.
    /// And quoter functions are not gas efficient and should _not_ be called on chain.
    function pairFor(address factory, address tokenA, address tokenB) internal view returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        return IPancakeFactory(factory).getPair(token0, token1);
    }

    // fetches and sorts the reserves for a pair
    function getReserves(address factory, address tokenA, address tokenB)
        internal
        view
        returns (uint256 reserveA, uint256 reserveB)
    {
        (address token0,) = sortTokens(tokenA, tokenB);
        (uint256 reserve0, uint256 reserve1,) = IPancakePair(pairFor(factory, tokenA, tokenB)).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0);
        uint256 amountInWithFee = amountIn * 9975;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 10000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountIn)
    {
        require(amountOut > 0, "INSUFFICIENT_OUTPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0);
        uint256 numerator = reserveIn * amountOut * 10000;
        uint256 denominator = (reserveOut - amountOut) * 9975;
        amountIn = (numerator / denominator) + 1;
    }

    // performs chained getAmountIn calculations on any number of pairs
    function getAmountsIn(address factory, uint256 amountOut, address[] memory path)
        internal
        view
        returns (uint256[] memory amounts)
    {
        require(path.length >= 2);
        amounts = new uint256[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint256 i = path.length - 1; i > 0; i--) {
            (uint256 reserveIn, uint256 reserveOut) = getReserves(factory, path[i - 1], path[i]);
            amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut);
        }
    }

    /**
     * V3 *************************************************
     */

    /// @notice Returns the pool for the given token pair and fee. The pool contract may or may not exist.
    /// @dev PancakeSwap is a multichain DEX, we have different factories on different chains.
    /// If we use the CREATE2 rule to calculate the pool address, we need to update the INIT_CODE_HASH for each chain.
    /// And quoter functions are not gas efficient and should _not_ be called on chain.
    function getPool(address factory, address tokenA, address tokenB, uint24 fee)
        internal
        view
        returns (IPancakeV3Pool)
    {
        if (tokenA > tokenB) (tokenA, tokenB) = (tokenB, tokenA);
        return IPancakeV3Pool(IPancakeV3Factory(factory).getPool(tokenA, tokenB, fee));
    }

    /// @notice Returns the address of a valid PancakeSwap V3 Pool
    /// @param factory The contract address of the PancakeSwap V3 factory
    /// @param tokenA The contract address of either token0 or token1
    /// @param tokenB The contract address of the other token
    /// @param fee The fee collected upon every swap in the pool, denominated in hundredths of a bip
    /// @return pool The V3 pool contract address
    function verifyCallback(address factory, address tokenA, address tokenB, uint24 fee)
        internal
        view
        returns (IPancakeV3Pool pool)
    {
        pool = getPool(factory, tokenA, tokenB, fee);
        require(msg.sender == address(pool));
    }
}
