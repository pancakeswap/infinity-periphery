// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";

/// @title Immutable State
/// @notice A collection of immutable state variables, commonly used across multiple contracts
contract ImmutableState {
    /// @notice The Pancakeswap v4 Vault contract
    IVault public immutable vault;

    constructor(IVault _vault) {
        vault = _vault;
    }
}
