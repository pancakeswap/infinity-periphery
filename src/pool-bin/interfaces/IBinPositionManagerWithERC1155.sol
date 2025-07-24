// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IBinPositionManager} from "./IBinPositionManager.sol";

interface IBinPositionManagerWithERC1155 is IBinPositionManager {
    function balanceOfBatch(address[] calldata owners, uint256[] calldata ids)
        external
        returns (uint256[] memory balances);
}
