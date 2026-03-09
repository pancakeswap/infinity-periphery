// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity 0.8.26;

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {Tick} from "infinity-core/src/pool-cl/libraries/Tick.sol";
import {ITickLens} from "../interfaces/ITickLens.sol";

/// @title Tick Lens contract
contract TickLens is ITickLens {
    using CLPoolParametersHelper for bytes32;

    ICLPoolManager public immutable poolManager;

    constructor(ICLPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /// @inheritdoc ITickLens
    function getPopulatedTicksInWord(PoolKey memory key, int16 tickBitmapIndex)
        external
        view
        override
        returns (PopulatedTick[] memory populatedTicks)
    {
        return getPopulatedTicksInWord(key.toId(), tickBitmapIndex);
    }

    /// @inheritdoc ITickLens
    function getPopulatedTicksInWord(PoolId id, int16 tickBitmapIndex)
        public
        view
        override
        returns (PopulatedTick[] memory populatedTicks)
    {
        // retrieve tickSpacing
        (,,,,, bytes32 poolParams) = poolManager.poolIdToPoolKey(id);
        int24 tickSpacing = poolParams.getTickSpacing();

        // check if pool is initialized
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();
        // fetch bitmap
        uint256 bitmap = poolManager.getPoolBitmapInfo(id, tickBitmapIndex);

        // calculate the number of populated ticks
        uint256 numberOfPopulatedTicks;
        for (uint256 i = 0; i < 256; i++) {
            if (bitmap & (1 << i) > 0) numberOfPopulatedTicks++;
        }

        // fetch populated tick data
        populatedTicks = new PopulatedTick[](numberOfPopulatedTicks);
        for (uint256 i = 0; i < 256; i++) {
            if (bitmap & (1 << i) > 0) {
                int24 populatedTick = ((int24(tickBitmapIndex) << 8) + int24(int256(i))) * tickSpacing;
                Tick.Info memory tickInfo = poolManager.getPoolTickInfo(id, populatedTick);
                populatedTicks[--numberOfPopulatedTicks] = PopulatedTick({
                    tick: populatedTick, liquidityNet: tickInfo.liquidityNet, liquidityGross: tickInfo.liquidityGross
                });
            }
        }
    }
}
