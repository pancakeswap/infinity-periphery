// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";

interface IPoolManager {
    /// @notice Returns the vault contract
    /// @return IVault The address of the vault
    function vault() external view returns (IVault);
}
