// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @title IStableSwap
/// @notice Interface for the StableSwap contract
interface IStableSwap {
    // solium-disable-next-line mixedcase
    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256 dy);

    // solium-disable-next-line mixedcase
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 minDy) external payable;

    // solium-disable-next-line mixedcase
    function coins(uint256 i) external view returns (address);

    // solium-disable-next-line mixedcase
    function balances(uint256 i) external view returns (uint256);

    // solium-disable-next-line mixedcase
    function A() external view returns (uint256);

    // solium-disable-next-line mixedcase
    function fee() external view returns (uint256);

    function add_liquidity(uint256[2] calldata amounts, uint256 min_mint_amount) external;
}
