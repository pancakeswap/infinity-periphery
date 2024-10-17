// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.0;

import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";

/// @title Interface for ImmutableState
interface IImmutableState {
    /// @notice The Pancakeswap v4 Vault contract
    function vault() external view returns (IVault);
}
