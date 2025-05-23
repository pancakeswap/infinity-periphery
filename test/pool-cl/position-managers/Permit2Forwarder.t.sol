// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {Currency} from "infinity-core/src/types/Currency.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";

import {PosmTestSetup} from "../shared/PosmTestSetup.sol";
import {Permit2Forwarder} from "../../../src/base/Permit2Forwarder.sol";
import {Permit2SignatureHelpers} from "../../shared/Permit2SignatureHelpers.sol";

contract Permit2ForwarderTest is Test, PosmTestSetup, Permit2SignatureHelpers {
    Permit2Forwarder permit2Forwarder;

    IVault vault;
    ICLPoolManager manager;

    PoolId poolId;
    PoolKey key;

    uint160 amount0 = 10e18;
    // the expiration of the allowance is large
    uint48 expiration = uint48(block.timestamp + 10e18);
    uint48 nonce = 0;

    bytes32 PERMIT2_DOMAIN_SEPARATOR;

    uint256 alicePrivateKey;
    address alice;

    function setUp() public {
        // This is needed to receive return deltas from modifyLiquidity calls.
        deployPosmHookSavesDelta();

        (vault, manager, key, poolId) = createFreshPool(IHooks(address(hook)), 3000, SQRT_RATIO_1_1);
        currency0 = key.currency0;
        currency1 = key.currency1;

        deployAndApproveRouter(vault, manager);
        // also deploys permit2
        deployPosm(vault, manager);
        permit2Forwarder = new Permit2Forwarder(permit2);
        PERMIT2_DOMAIN_SEPARATOR = permit2.DOMAIN_SEPARATOR();

        alicePrivateKey = 0x12341234;
        alice = vm.addr(alicePrivateKey);
    }

    function test_permit_single_succeeds() public {
        IAllowanceTransfer.PermitSingle memory permit =
            defaultERC20PermitAllowance(Currency.unwrap(currency0), amount0, expiration, nonce);
        bytes memory sig = getPermitSignature(permit, alicePrivateKey, PERMIT2_DOMAIN_SEPARATOR);

        permit2Forwarder.permit(alice, permit, sig);

        (uint160 _amount, uint48 _expiration, uint48 _nonce) =
            permit2.allowance(alice, Currency.unwrap(currency0), address(this));
        assertEq(_amount, amount0);
        assertEq(_expiration, expiration);
        assertEq(_nonce, nonce + 1); // the nonce was incremented
    }

    function test_permit_batch_succeeds() public {
        address[] memory tokens = new address[](2);
        tokens[0] = Currency.unwrap(currency0);
        tokens[1] = Currency.unwrap(currency1);

        IAllowanceTransfer.PermitBatch memory permit =
            defaultERC20PermitBatchAllowance(tokens, amount0, expiration, nonce);
        bytes memory sig = getPermitBatchSignature(permit, alicePrivateKey, PERMIT2_DOMAIN_SEPARATOR);

        permit2Forwarder.permitBatch(alice, permit, sig);

        (uint160 _amount, uint48 _expiration, uint48 _nonce) =
            permit2.allowance(alice, Currency.unwrap(currency0), address(this));
        assertEq(_amount, amount0);
        assertEq(_expiration, expiration);
        assertEq(_nonce, nonce + 1);
        (uint160 _amount1, uint48 _expiration1, uint48 _nonce1) =
            permit2.allowance(alice, Currency.unwrap(currency1), address(this));
        assertEq(_amount1, amount0);
        assertEq(_expiration1, expiration);
        assertEq(_nonce1, nonce + 1);
    }
}
