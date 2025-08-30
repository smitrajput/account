// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./utils/SoladyTest.sol";
import "./Base.t.sol";
import {MockSampleDelegateCallTarget} from "./utils/mocks/MockSampleDelegateCallTarget.sol";
import {LibEIP7702} from "solady/accounts/LibEIP7702.sol";
import {SimpleFunder} from "../src/SimpleFunder.sol";
import {SimpleSettler} from "../src/SimpleSettler.sol";

import {Escrow} from "../src/Escrow.sol";
import {IEscrow} from "../src/interfaces/IEscrow.sol";

import {IOrchestrator} from "../src/interfaces/IOrchestrator.sol";
import {IIthacaAccount} from "../src/interfaces/IIthacaAccount.sol";
import {MultiSigSigner} from "../src/MultiSigSigner.sol";
import {ICommon} from "../src/interfaces/ICommon.sol";

import {Merkle} from "murky/Merkle.sol";

contract AccountTest is BaseTest {
    struct _TestExecuteWithSignatureTemps {
        TargetFunctionPayload[] targetFunctionPayloads;
        ERC7821.Call[] calls;
        uint256 n;
        uint256 nonce;
        bytes opData;
        bytes executionData;
    }

    function testExecuteWithSignature(bytes32) public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        vm.deal(d.eoa, 100 ether);

        _TestExecuteWithSignatureTemps memory t;
        t.n = _bound(_randomUniform(), 1, 5);
        t.targetFunctionPayloads = new TargetFunctionPayload[](t.n);
        t.calls = new ERC7821.Call[](t.n);
        for (uint256 i; i < t.n; ++i) {
            uint256 value = _random() % 0.1 ether;
            bytes memory data = _truncateBytes(_randomBytes(), 0xff);
            t.calls[i] = _thisTargetFunctionCall(value, data);
            t.targetFunctionPayloads[i].value = value;
            t.targetFunctionPayloads[i].data = data;
        }
        t.nonce = d.d.getNonce(0);
        bytes memory signature = _sig(d, d.d.computeDigest(t.calls, t.nonce));
        t.opData = abi.encodePacked(t.nonce, signature);
        t.executionData = abi.encode(t.calls, t.opData);

        if (_randomChance(32)) {
            signature = _sig(_randomEIP7702DelegatedEOA(), d.d.computeDigest(t.calls, t.nonce));
            t.opData = abi.encodePacked(t.nonce, signature);
            t.executionData = abi.encode(t.calls, t.opData);
            vm.expectRevert(bytes4(keccak256("Unauthorized()")));
            d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, t.executionData);
            return;
        }

        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, t.executionData);

        if (_randomChance(32)) {
            vm.expectRevert(bytes4(keccak256("InvalidNonce()")));
            d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, t.executionData);
        }

        if (_randomChance(32)) {
            t.nonce = d.d.getNonce(0);
            signature = _sig(d, d.d.computeDigest(t.calls, t.nonce));
            t.opData = abi.encodePacked(t.nonce, signature);
            t.executionData = abi.encode(t.calls, t.opData);
            d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, t.executionData);
            return;
        }

        for (uint256 i; i < t.n; ++i) {
            assertEq(targetFunctionPayloads[i].by, d.eoa);
            assertEq(targetFunctionPayloads[i].value, t.targetFunctionPayloads[i].value);
            assertEq(targetFunctionPayloads[i].data, t.targetFunctionPayloads[i].data);
        }
    }

    function testSignatureCheckerApproval(bytes32) public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        PassKey memory k = _randomSecp256k1PassKey();

        k.k.isSuperAdmin = _randomChance(32);

        vm.prank(d.eoa);
        d.d.authorize(k.k);

        address[] memory checkers = new address[](_bound(_random(), 1, 3));
        for (uint256 i; i < checkers.length; ++i) {
            checkers[i] = _randomUniqueHashedAddress();
            vm.prank(d.eoa);
            d.d.setSignatureCheckerApproval(k.keyHash, checkers[i], true);
        }
        assertEq(d.d.approvedSignatureCheckers(k.keyHash).length, checkers.length);

        bytes32 digest = bytes32(_randomUniform());
        bytes memory sig = _sig(k, digest);

        // test that the signature fails without the replay safe wrapper
        assertTrue(d.d.isValidSignature(digest, sig) == 0xFFFFFFFF);

        bytes32 replaySafeDigest = keccak256(abi.encode(d.d.SIGN_TYPEHASH(), digest));

        (, string memory name, string memory version,, address verifyingContract,,) =
            d.d.eip712Domain();
        bytes32 domain = keccak256(
            abi.encode(
                0x035aff83d86937d35b32e04f0ddc6ff469290eef2f1b692d8a815c89404d4749, // DOMAIN_TYPEHASH with only verifyingContract
                verifyingContract
            )
        );
        replaySafeDigest = keccak256(abi.encodePacked("\x19\x01", domain, replaySafeDigest));
        sig = _sig(k, replaySafeDigest);

        assertEq(
            d.d.isValidSignature(digest, sig) == IthacaAccount.isValidSignature.selector,
            k.k.isSuperAdmin
        );

        vm.prank(checkers[_randomUniform() % checkers.length]);
        assertEq(d.d.isValidSignature(digest, sig), IthacaAccount.isValidSignature.selector);

        vm.prank(d.eoa);
        d.d.revoke(_hash(k.k));

        vm.expectRevert(bytes4(keccak256("KeyDoesNotExist()")));
        d.d.isValidSignature(digest, sig);

        if (k.k.isSuperAdmin) k.k.isSuperAdmin = _randomChance(2);
        vm.prank(d.eoa);
        d.d.authorize(k.k);

        assertEq(
            d.d.isValidSignature(digest, sig) == IthacaAccount.isValidSignature.selector,
            k.k.isSuperAdmin
        );
        assertEq(d.d.approvedSignatureCheckers(k.keyHash).length, 0);
    }

    struct _TestUpgradeAccountWithPassKeyTemps {
        uint256 randomVersion;
        address implementation;
        ERC7821.Call[] calls;
        uint256 nonce;
        bytes opData;
        bytes executionData;
    }

    function testUpgradeAccountWithPassKey(bytes32) public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        PassKey memory k = _randomSecp256k1PassKey();

        k.k.isSuperAdmin = true;

        vm.prank(d.eoa);
        d.d.authorize(k.k);

        _TestUpgradeAccountWithPassKeyTemps memory t;
        t.randomVersion = _randomUniform();
        t.implementation = address(new MockSampleDelegateCallTarget(t.randomVersion));

        t.calls = new ERC7821.Call[](1);
        t.calls[0].data = abi.encodeWithSignature("upgradeProxyAccount(address)", t.implementation);

        t.nonce = d.d.getNonce(0);
        bytes memory signature = _sig(d, d.d.computeDigest(t.calls, t.nonce));
        t.opData = abi.encodePacked(t.nonce, signature);
        t.executionData = abi.encode(t.calls, t.opData);

        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, t.executionData);

        assertEq(MockSampleDelegateCallTarget(d.eoa).version(), t.randomVersion);
        assertEq(MockSampleDelegateCallTarget(d.eoa).upgradeHookCounter(), 1);
    }

    function testUpgradeAccountToZeroAddressReverts() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        PassKey memory k = _randomSecp256k1PassKey();

        k.k.isSuperAdmin = true;

        vm.prank(d.eoa);
        d.d.authorize(k.k);

        _TestUpgradeAccountWithPassKeyTemps memory t;
        t.calls = new ERC7821.Call[](1);
        t.calls[0].data = abi.encodeWithSignature("upgradeProxyAccount(address)", address(0));

        t.nonce = d.d.getNonce(0);
        bytes memory signature = _sig(d, d.d.computeDigest(t.calls, t.nonce));
        t.opData = abi.encodePacked(t.nonce, signature);
        t.executionData = abi.encode(t.calls, t.opData);

        vm.expectRevert(IthacaAccount.NewImplementationIsZero.selector);
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, t.executionData);
    }

    function testApproveAndRevokeKey(bytes32) public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        IthacaAccount.Key memory k;
        IthacaAccount.Key memory kRetrieved;

        k.keyType = IthacaAccount.KeyType(_randomUniform() & 1);
        k.expiry = uint40(_bound(_random(), 0, 2 ** 40 - 1));
        k.publicKey = _truncateBytes(_randomBytes(), 0x1ff);

        assertEq(d.d.keyCount(), 0);

        vm.prank(d.eoa);
        d.d.authorize(k);

        assertEq(d.d.keyCount(), 1);

        kRetrieved = d.d.keyAt(0);
        assertEq(uint8(kRetrieved.keyType), uint8(k.keyType));
        assertEq(kRetrieved.expiry, k.expiry);
        assertEq(kRetrieved.publicKey, k.publicKey);

        k.expiry = uint40(_bound(_random(), 0, 2 ** 40 - 1));

        vm.prank(d.eoa);
        d.d.authorize(k);

        assertEq(d.d.keyCount(), 1);

        kRetrieved = d.d.keyAt(0);
        assertEq(uint8(kRetrieved.keyType), uint8(k.keyType));
        assertEq(kRetrieved.expiry, k.expiry);
        assertEq(kRetrieved.publicKey, k.publicKey);

        kRetrieved = d.d.getKey(_hash(k));
        assertEq(uint8(kRetrieved.keyType), uint8(k.keyType));
        assertEq(kRetrieved.expiry, k.expiry);
        assertEq(kRetrieved.publicKey, k.publicKey);

        vm.prank(d.eoa);
        d.d.revoke(_hash(k));

        assertEq(d.d.keyCount(), 0);

        vm.expectRevert(bytes4(keccak256("IndexOutOfBounds()")));
        d.d.keyAt(0);

        vm.expectRevert(bytes4(keccak256("KeyDoesNotExist()")));
        kRetrieved = d.d.getKey(_hash(k));
    }

    function testManyKeys() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        IthacaAccount.Key memory k;
        k.keyType = IthacaAccount.KeyType(_randomUniform() & 1);

        for (uint40 i = 0; i < 20; i++) {
            k.expiry = i;
            k.publicKey = abi.encode(i);
            vm.prank(d.eoa);
            d.d.authorize(k);
        }

        vm.warp(5);

        (IthacaAccount.Key[] memory keys, bytes32[] memory keyHashes) = d.d.getKeys();

        assert(keys.length == keyHashes.length);
        assert(keys.length == 16);

        assert(keys[0].expiry == 0);
        assert(keys[1].expiry == 5);
    }

    function testAddDisallowedSuperAdminKeyTypeReverts() public {
        address orchestrator = address(new Orchestrator(address(this)));
        address accountImplementation = address(new IthacaAccount(address(orchestrator)));
        address accountProxy = address(LibEIP7702.deployProxy(accountImplementation, address(0)));
        account = MockAccount(payable(accountProxy));

        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();

        PassKey memory k = _randomSecp256k1PassKey();
        k.k.isSuperAdmin = true;

        vm.startPrank(d.eoa);

        d.d.authorize(k.k);

        k = _randomSecp256r1PassKey();
        k.k.isSuperAdmin = true;
        vm.expectRevert(bytes4(keccak256("KeyTypeCannotBeSuperAdmin()")));
        d.d.authorize(k.k);

        vm.stopPrank();
    }

    function testPause() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        vm.deal(d.eoa, 100 ether);
        address pauseAuthority = _randomAddress();
        oc.setPauseAuthority(pauseAuthority);

        (address ocPauseAuthority, uint40 lastPaused) = oc.getPauseConfig();
        assertEq(ocPauseAuthority, pauseAuthority);
        assertEq(lastPaused, 0);

        ERC7821.Call[] memory calls = new ERC7821.Call[](1);

        // Pause authority is always the EP
        calls[0].to = address(d.d);
        calls[0].data = abi.encodeWithSignature("setPauseAuthority(address)", pauseAuthority);
        uint256 nonce = d.d.getNonce(0);
        bytes memory opData = abi.encodePacked(nonce, _sig(d, d.d.computeDigest(calls, nonce)));
        bytes memory executionData = abi.encode(calls, opData);

        // Setup a mock call
        calls[0] = _transferCall(address(0), address(0x1234), 1 ether);
        nonce = d.d.getNonce(0);
        bytes32 digest = d.d.computeDigest(calls, nonce);
        bytes memory signature = _sig(d, digest);

        opData = abi.encodePacked(nonce, signature);
        executionData = abi.encode(calls, opData);

        // Check that execution can pass before pause.
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, executionData);

        // The block timestamp needs to be realistic
        vm.warp(6 weeks + 1 days);

        // Only the pause authority can pause.
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        oc.setPauseAuthority(pauseAuthority);

        vm.startPrank(pauseAuthority);
        oc.pause(true);

        assertEq(oc.pauseFlag(), 1);
        (ocPauseAuthority, lastPaused) = oc.getPauseConfig();
        assertEq(ocPauseAuthority, pauseAuthority);
        assertEq(lastPaused, block.timestamp);
        vm.stopPrank();

        // Check that execute fails
        nonce = d.d.getNonce(0);
        digest = d.d.computeDigest(calls, nonce);
        signature = _sig(d, digest);
        opData = abi.encodePacked(nonce, signature);
        executionData = abi.encode(calls, opData);

        vm.expectRevert(bytes4(keccak256("Paused()")));
        d.d.execute(_ERC7821_BATCH_EXECUTION_MODE, executionData);

        // Check that intent fails
        Orchestrator.Intent memory u;
        u.eoa = d.eoa;
        u.nonce = d.d.getNonce(0);
        u.combinedGas = 1000000;
        u.executionData = _transferExecutionData(address(0), address(0xabcd), 1 ether);
        u.signature = _eoaSig(d.privateKey, u);

        assertEq(oc.execute(abi.encode(u)), bytes4(keccak256("VerificationError()")));

        vm.startPrank(pauseAuthority);
        // Try to pause already paused account.
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        oc.pause(true);

        oc.pause(false);
        assertEq(oc.pauseFlag(), 0);
        (ocPauseAuthority, lastPaused) = oc.getPauseConfig();
        assertEq(ocPauseAuthority, pauseAuthority);
        assertEq(lastPaused, block.timestamp);

        // Cannot immediately repause again.
        vm.warp(lastPaused + 4 weeks + 1 days);
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        oc.pause(true);
        vm.stopPrank();

        // Intent should now succeed.
        assertEq(oc.execute(abi.encode(u)), 0);

        // Can pause again, after the cooldown period.
        vm.warp(lastPaused + 5 weeks + 1);
        vm.startPrank(pauseAuthority);
        oc.pause(true);
        vm.stopPrank();

        assertEq(oc.pauseFlag(), 1);
        (ocPauseAuthority, lastPaused) = oc.getPauseConfig();
        assertEq(ocPauseAuthority, pauseAuthority);
        assertEq(lastPaused, block.timestamp);

        // Anyone can unpause after 4 weeks.
        vm.warp(lastPaused + 4 weeks + 1);
        oc.pause(false);
        assertEq(oc.pauseFlag(), 0);
        (ocPauseAuthority, lastPaused) = oc.getPauseConfig();
        assertEq(ocPauseAuthority, pauseAuthority);
        assertEq(lastPaused, block.timestamp - 4 weeks - 1);

        address orchestratorAddress = address(oc);

        // Try setting pauseAuthority with dirty bits.
        assembly ("memory-safe") {
            mstore(0x00, 0x4b90364f) // `setPauseAuthority(address)`
            mstore(0x20, 0xffffffffffffffffffffffffffffffffffffffff)

            let success := call(gas(), orchestratorAddress, 0x00, 0x1c, 0x24, 0x00, 0x00)
            if success { revert(0, 0) }
        }
    }

    function testCrossChainKeyPreCallsAuthorization() public {
        // Setup Keys
        PassKey memory adminKey = _randomSecp256k1PassKey();
        adminKey.k.isSuperAdmin = true;

        PassKey memory newKey = _randomPassKey();
        newKey.k.isSuperAdmin = false;

        // Setup ephemeral EOA (simulates EIP-7702 delegation)
        uint256 ephemeralPK = _randomPrivateKey();
        address payable eoaAddress = payable(vm.addr(ephemeralPK));
        address impl = accountImplementation;

        paymentToken.mint(eoaAddress, 2 ** 128 - 1);

        // === PREPARE CROSS-CHAIN PRE-CALLS ===
        // These pre-calls will be used on multiple chains with multichain nonces

        // Pre-call 1: Initialize admin key using ephemeral EOA signature
        Orchestrator.SignedCall memory pInit;
        {
            ERC7821.Call[] memory initCalls = new ERC7821.Call[](1);
            initCalls[0].data = abi.encodeWithSelector(IthacaAccount.authorize.selector, adminKey.k);

            pInit.eoa = eoaAddress;
            pInit.executionData = abi.encode(initCalls);
            pInit.nonce = (0xc1d0 << 240) | (1 << 64); // Multichain nonce
            pInit.signature = _eoaSig(ephemeralPK, oc.computeDigest(pInit));
        }

        // Pre-call 2: Authorize new key using admin key
        Orchestrator.SignedCall memory pAuth;
        {
            ERC7821.Call[] memory authCalls = new ERC7821.Call[](1);
            authCalls[0].data = abi.encodeWithSelector(IthacaAccount.authorize.selector, newKey.k);

            pAuth.eoa = eoaAddress;
            pAuth.executionData = abi.encode(authCalls);
            pAuth.nonce = (0xc1d0 << 240) | (2 << 64); // Multichain nonce
            pAuth.signature = _sig(adminKey, oc.computeDigest(pAuth));
        }

        // Prepare main Intent structure (will be reused with same pre-calls)
        Orchestrator.Intent memory baseIntent;
        baseIntent.eoa = eoaAddress;
        baseIntent.paymentToken = address(paymentToken);
        baseIntent.paymentAmount = _bound(_random(), 0, 2 ** 32 - 1);
        baseIntent.paymentMaxAmount = baseIntent.paymentAmount;
        baseIntent.combinedGas = 10000000;

        // Encode the pre-calls once (to be reused on both chains)
        baseIntent.encodedPreCalls = new bytes[](2);
        baseIntent.encodedPreCalls[0] = abi.encode(pInit);
        baseIntent.encodedPreCalls[1] = abi.encode(pAuth);

        // Main execution (empty for this test)
        ERC7821.Call[] memory calls = new ERC7821.Call[](0);
        baseIntent.executionData = abi.encode(calls);

        // Take a snapshot before any chain-specific operations
        uint256 initialSnapshot = vm.snapshot();

        // === Chain 1 Execution ===
        vm.chainId(1);
        vm.etch(eoaAddress, abi.encodePacked(hex"ef0100", impl));

        // Use the prepared pre-calls on chain 1
        Orchestrator.Intent memory u1 = baseIntent;
        u1.nonce = (0xc1d0 << 240) | 0; // Multichain nonce for main intent
        u1.signature = _sig(adminKey, u1);

        // Execute on chain 1 - should succeed
        assertEq(oc.execute(abi.encode(u1)), 0, "Execution should succeed on chain 1");

        // Verify keys were added on chain 1
        uint256 keysCount1 = IthacaAccount(eoaAddress).keyCount();
        assertEq(keysCount1, 2, "Both keys should be added on chain 1");

        // === Reset State and Switch to Chain 137 ===
        vm.revertTo(initialSnapshot);
        vm.clearMockedCalls();
        paymentToken.mint(eoaAddress, 2 ** 128 - 1);

        // === Chain 137 Execution ===
        vm.chainId(137);
        vm.etch(eoaAddress, abi.encodePacked(hex"ef0100", impl));

        // Execution should succeed due to multichain nonce in pre-calls
        assertEq(oc.execute(abi.encode(baseIntent)), 0, "Should succeed due to multichain nonce");

        // Verify keys were added on chain 137
        uint256 keysCount137 = IthacaAccount(eoaAddress).keyCount();
        assertEq(keysCount137, 2, "Keys should be added on chain 137");
    }

    function testPayWithFiveCorruptedFieldOffsetsOfIntent() public {
        console.log("Test 1: Main Intent struct offset corruption");
        bytes memory maliciousCalldata = _createIntentOnMainnet();
        assembly {
            let dataPtr := add(maliciousCalldata, 0x20) // Skip bytes length prefix
            // CORRUPT MAIN OFFSET (Bytes 0-31) - Points to Intent struct start
            mstore(dataPtr, 0x10000000000000000) // 2^64 (strictly greater than 2^64-1)
        }
        (bool success, bytes memory returnData) =
            address(oc).call(abi.encodeWithSignature("execute(bytes)", maliciousCalldata));
        assertEq(success, false);

        console.log("Test 2: executionData offset corruption");
        maliciousCalldata = _createIntentOnMainnet();
        assembly {
            let dataPtr := add(maliciousCalldata, 0x20) // Skip bytes length prefix
            let intentPtr := add(dataPtr, 0x20) // Points to start of Intent struct
            // executionData offset (bytes 64-95 relative to start, or 32-63 in Intent struct)
            mstore(add(intentPtr, 32), 0x10000000000000001) // 2^64 + 1
        }
        assertEq(oc.execute(maliciousCalldata), bytes4(keccak256("VerifiedCallError()")));

        console.log("Test 3: encodedPreCalls offset corruption");
        maliciousCalldata = _createIntentOnMainnet();
        assembly {
            let dataPtr := add(maliciousCalldata, 0x20) // Skip bytes length prefix
            let intentPtr := add(dataPtr, 0x20) // Points to start of Intent struct
            // encodedPreCalls offset (bytes 256-287 relative to start, or 224-255 in Intent struct)
            mstore(add(intentPtr, 224), 0x10000000000000002) // 2^64 + 2
        }
        assertEq(oc.execute(maliciousCalldata), bytes4(keccak256("VerifiedCallError()")));

        console.log("Test 4: encodedFundTransfers offset corruption");
        maliciousCalldata = _createIntentOnMainnet();
        assembly {
            let dataPtr := add(maliciousCalldata, 0x20) // Skip bytes length prefix
            let intentPtr := add(dataPtr, 0x20) // Points to start of Intent struct
            // encodedFundTransfers offset (bytes 288-319 relative to start, or 256-287 in Intent struct)
            mstore(add(intentPtr, 256), 0x10000000000000003) // 2^64 + 3
        }
        assertEq(oc.execute(maliciousCalldata), bytes4(keccak256("VerifiedCallError()")));

        console.log("Test 5: funderSignature offset corruption");
        maliciousCalldata = _createIntentOnMainnet();
        assembly {
            let dataPtr := add(maliciousCalldata, 0x20) // Skip bytes length prefix
            let intentPtr := add(dataPtr, 0x20) // Points to start of Intent struct
            // funderSignature offset (bytes 448-479 relative to start, or 416-447 in Intent struct)
            mstore(add(intentPtr, 416), 0x10000000000000004) // 2^64 + 4
        }
        assertEq(oc.execute(maliciousCalldata), bytes4(keccak256("VerifiedCallError()")));

        console.log("Test 6: signature offset corruption");
        maliciousCalldata = _createIntentOnMainnet();
        assembly {
            let dataPtr := add(maliciousCalldata, 0x20) // Skip bytes length prefix
            let intentPtr := add(dataPtr, 0x20) // Points to start of Intent struct
            // signature offset (bytes 576-607 relative to start, or 544-575 in Intent struct)
            mstore(add(intentPtr, 544), 0x10000000000000005) // 2^64 + 5
        }
        assertEq(oc.execute(maliciousCalldata), bytes4(keccak256("VerifiedCallError()")));
    }

    // modified from testCrossChainKeyPreCallsAuthorization()'s intent creation
    function _createIntentOnMainnet() public returns (bytes memory) {
        // Setup Keys
        PassKey memory adminKey = _randomSecp256k1PassKey();
        adminKey.k.isSuperAdmin = true;

        PassKey memory newKey = _randomPassKey();
        newKey.k.isSuperAdmin = false;

        // Setup ephemeral EOA (simulates EIP-7702 delegation)
        uint256 ephemeralPK = _randomPrivateKey();
        address payable eoaAddress = payable(vm.addr(ephemeralPK));
        address impl = accountImplementation;

        paymentToken.mint(eoaAddress, 2 ** 128 - 1);

        // === PREPARE CROSS-CHAIN PRE-CALLS ===
        // These pre-calls will be used on multiple chains with multichain nonces

        // Pre-call 1: Initialize admin key using ephemeral EOA signature
        Orchestrator.SignedCall memory pInit;
        {
            ERC7821.Call[] memory initCalls = new ERC7821.Call[](1);
            initCalls[0].data = abi.encodeWithSelector(IthacaAccount.authorize.selector, adminKey.k);

            pInit.eoa = eoaAddress;
            pInit.executionData = abi.encode(initCalls);
            pInit.nonce = (0xc1d0 << 240) | (1 << 64); // Multichain nonce
            pInit.signature = _eoaSig(ephemeralPK, oc.computeDigest(pInit));
        }

        // Pre-call 2: Authorize new key using admin key
        Orchestrator.SignedCall memory pAuth;
        {
            ERC7821.Call[] memory authCalls = new ERC7821.Call[](1);
            authCalls[0].data = abi.encodeWithSelector(IthacaAccount.authorize.selector, newKey.k);

            pAuth.eoa = eoaAddress;
            pAuth.executionData = abi.encode(authCalls);
            pAuth.nonce = (0xc1d0 << 240) | (2 << 64); // Multichain nonce
            pAuth.signature = _sig(adminKey, oc.computeDigest(pAuth));
        }

        // Prepare main Intent structure (will be reused with same pre-calls)
        Orchestrator.Intent memory baseIntent;
        baseIntent.eoa = eoaAddress;
        baseIntent.paymentToken = address(paymentToken);
        baseIntent.paymentAmount = _bound(_random(), 0, 2 ** 32 - 1);
        baseIntent.paymentMaxAmount = baseIntent.paymentAmount;
        baseIntent.combinedGas = 10000000;

        // Encode the pre-calls once (to be reused on both chains)
        baseIntent.encodedPreCalls = new bytes[](2);
        baseIntent.encodedPreCalls[0] = abi.encode(pInit);
        baseIntent.encodedPreCalls[1] = abi.encode(pAuth);

        // Main execution (empty for this test)
        ERC7821.Call[] memory calls = new ERC7821.Call[](0);
        baseIntent.executionData = abi.encode(calls);

        // Take a snapshot before any chain-specific operations
        uint256 initialSnapshot = vm.snapshot();

        // === Chain 1 Execution ===
        vm.chainId(1);
        vm.etch(eoaAddress, abi.encodePacked(hex"ef0100", impl));

        // Use the prepared pre-calls on chain 1
        Orchestrator.Intent memory u1 = baseIntent;
        u1.nonce = (0xc1d0 << 240) | 0; // Multichain nonce for main intent
        u1.signature = _sig(adminKey, u1);

        return abi.encode(u1);
    }

    // modified from Orchestrator.t.sol's testAccountPaymaster()
    function testPayWithCorruptedPaymentSignatureOffsetOfIntent() public {
        DelegatedEOA memory d = _randomEIP7702DelegatedEOA();
        DelegatedEOA memory payer = _randomEIP7702DelegatedEOA();

        bool isNative = _randomChance(2);

        if (isNative) {
            vm.deal(address(payer.d), type(uint192).max);
        } else {
            _mint(address(paymentToken), address(payer.d), type(uint192).max);
        }

        // 1 ether in the EOA for execution.
        vm.deal(address(d.d), 1 ether);

        Orchestrator.Intent memory u;

        u.eoa = d.eoa;
        u.payer = address(payer.d);

        u.nonce = d.d.getNonce(0);
        u.paymentToken = isNative ? address(0) : address(paymentToken);
        u.paymentAmount = _bound(_random(), 0, 5 ether);
        u.paymentMaxAmount = _bound(_random(), u.paymentAmount, 10 ether);

        u.executionData = _transferExecutionData(address(0), address(0xabcd), 1 ether);
        u.paymentRecipient = address(0x12345);

        bytes32 digest = oc.computeDigest(u);

        uint256 snapshot = vm.snapshotState();
        // To allow paymasters to be used in simulation mode.
        vm.deal(_ORIGIN_ADDRESS, type(uint192).max);
        (uint256 gExecute, uint256 gCombined,) = _estimateGas(u);
        vm.revertToStateAndDelete(snapshot);
        u.combinedGas = gCombined;

        digest = oc.computeDigest(u);
        u.signature = _eoaSig(d.privateKey, digest);
        u.paymentSignature = _eoaSig(payer.privateKey, digest);

        console.log("Test 7: paymentSignature offset corruption");
        bytes memory maliciousCalldata = abi.encode(u);
        assembly {
            let dataPtr := add(maliciousCalldata, 0x20) // Skip bytes length prefix
            let intentPtr := add(dataPtr, 0x20) // Points to start of Intent struct
            // paymentSignature offset (bytes 608-639 relative to start, or 576-607 in Intent struct)
            mstore(add(intentPtr, 576), 0x10000000000000006) // 2^64 + 6
        }

        // custom error 0x00000000: 00000000000000000000000070a08231000000000000000000000000, the
        // uncaught error in case of corrupted paymentSignature
        assertEq(oc.execute(maliciousCalldata), bytes4(0x00000000));
    }

    Merkle merkleHelper;

    struct _TestMultiChainIntentTemps {
        // Core test data
        SimpleFunder funder;
        SimpleSettler settler;
        uint256 funderPrivateKey;
        MockPaymentToken usdcMainnet;
        MockPaymentToken usdcArb;
        MockPaymentToken usdcBase;
        DelegatedEOA d;
        PassKey k;
        // Intent data
        ICommon.Intent baseIntent;
        ICommon.Intent arbIntent;
        ICommon.Intent outputIntent;
        // Merkle data
        bytes32[] leafs;
        bytes32 root;
        bytes rootSig;
        // Common addresses
        address gasWallet;
        address relay;
        address friend;
        address settlementOracle;
        // Escrow contracts
        Escrow escrowBase;
        Escrow escrowArb;
        // Escrow data
        bytes32 settlementId;
        bytes32 escrowIdBase;
        bytes32 escrowIdArb;
        // Other common data
        bytes[] encodedIntents;
        bytes4[] errs;
        uint256 snapshot;
    }

    // modified from Orchestrator.t.sol's testMultiChainIntent()
    function testPayWithCorruptedSettlerContextOffsetOfIntent() public {
        _TestMultiChainIntentTemps memory t;

        // Initialize core test data
        t.funderPrivateKey = _randomPrivateKey();
        t.settlementOracle = makeAddr("SETTLEMENT_ORACLE");
        t.funder = new SimpleFunder(vm.addr(t.funderPrivateKey), address(oc), address(this));
        t.settler = new SimpleSettler(t.settlementOracle);
        t.relay = makeAddr("RELAY");
        t.friend = makeAddr("FRIEND");

        // ------------------------------------------------------------------
        // SimpleFunder ‑ gas wallet set-up & basic functionality checks
        // ------------------------------------------------------------------
        // Setting up the gas wallet and hooking it to the SimpleFunder don't make a difference
        // to this test, so skipping it

        merkleHelper = new Merkle();
        // USDC has different address on all chains
        t.usdcMainnet = new MockPaymentToken();
        t.usdcArb = new MockPaymentToken();
        t.usdcBase = new MockPaymentToken();

        // Deploy Escrow contracts on input chains
        t.escrowBase = new Escrow();
        t.escrowArb = new Escrow();

        // Deploy the account on all chains
        t.d = _randomEIP7702DelegatedEOA();
        vm.deal(t.d.eoa, 10 ether);

        // Authorize the passskey on all chains
        t.k = _randomPassKey();
        t.k.k.isSuperAdmin = true;
        vm.prank(t.d.eoa);
        t.d.d.authorize(t.k.k);

        // Test Scenario:
        // Send 1000 USDC to a friend on Mainnet. By pulling funds from Base and Arb (which are skipped in this test).
        // User has 0 USDC on Mainnet.
        // Relay fees (Bridging + gas on all chains included) is 100 USDC.

        // 1. Prepare the output intent first to get its digest as settlementId
        t.outputIntent.eoa = t.d.eoa;
        t.outputIntent.nonce = t.d.d.getNonce(0);
        t.outputIntent.executionData =
            _transferExecutionData(address(t.usdcMainnet), t.friend, 1000);
        t.outputIntent.combinedGas = 1000000;
        t.outputIntent.settler = address(t.settler);
        t.outputIntent.isMultichain = true;

        {
            bytes[] memory encodedFundTransfers = new bytes[](1);
            encodedFundTransfers[0] =
                abi.encode(ICommon.Transfer({token: address(t.usdcMainnet), amount: 1000}));

            t.outputIntent.encodedFundTransfers = encodedFundTransfers;
            t.outputIntent.funder = address(t.funder);

            // Set settlerContext with input chains
            uint256[] memory _inputChains = new uint256[](2);
            _inputChains[0] = 8453; // Base
            _inputChains[1] = 42161; // Arbitrum
            t.outputIntent.settlerContext = abi.encode(_inputChains);
        }

        // Compute the output intent digest to use as settlementId
        vm.chainId(1); // Mainnet
        t.settlementId = oc.computeDigest(t.outputIntent);

        // Base Intent with escrow execution data
        t.baseIntent.eoa = t.d.eoa;
        t.baseIntent.nonce = t.d.d.getNonce(0);
        t.baseIntent.combinedGas = 1000000;
        t.baseIntent.isMultichain = true;

        // Create Base escrow execution data
        {
            IEscrow.Escrow[] memory escrows = new IEscrow.Escrow[](1);
            escrows[0] = IEscrow.Escrow({
                salt: bytes12(uint96(_random())),
                depositor: t.d.eoa,
                recipient: t.relay,
                token: address(t.usdcBase),
                settler: address(t.settler),
                sender: address(oc), // Orchestrator on output chain (mainnet)
                settlementId: t.settlementId,
                senderChainId: 1, // Mainnet chain ID
                escrowAmount: 600,
                refundAmount: 600, // Full refund if settlement fails
                refundTimestamp: block.timestamp + 1 hours
            });
            t.escrowIdBase = keccak256(abi.encode(escrows[0]));

            ERC7821.Call[] memory calls = new ERC7821.Call[](2);
            // First approve the escrow contract
            calls[0] = ERC7821.Call({
                to: address(t.usdcBase),
                value: 0,
                data: abi.encodeWithSignature("approve(address,uint256)", address(t.escrowBase), 600)
            });
            // Then call escrow function
            calls[1] = ERC7821.Call({
                to: address(t.escrowBase),
                value: 0,
                data: abi.encodeWithSelector(IEscrow.escrow.selector, escrows)
            });
            t.baseIntent.executionData = abi.encode(calls);
        }

        // Arbitrum Intent with escrow execution data
        t.arbIntent.eoa = t.d.eoa;
        t.arbIntent.nonce = t.d.d.getNonce(0);
        t.arbIntent.combinedGas = 1000000;
        t.arbIntent.isMultichain = true;
        // Create Arbitrum escrow execution data
        {
            IEscrow.Escrow[] memory escrows = new IEscrow.Escrow[](1);
            escrows[0] = IEscrow.Escrow({
                salt: bytes12(uint96(_random())),
                depositor: t.d.eoa,
                recipient: t.relay,
                token: address(t.usdcArb),
                settler: address(t.settler),
                sender: address(oc), // Orchestrator on output chain (mainnet)
                settlementId: t.settlementId,
                senderChainId: 1, // Mainnet chain ID
                escrowAmount: 500,
                refundAmount: 500, // Full refund if settlement fails
                refundTimestamp: block.timestamp + 1 hours
            });
            t.escrowIdArb = keccak256(abi.encode(escrows[0]));

            ERC7821.Call[] memory calls = new ERC7821.Call[](2);
            // First approve the escrow contract
            calls[0] = ERC7821.Call({
                to: address(t.usdcArb),
                value: 0,
                data: abi.encodeWithSignature("approve(address,uint256)", address(t.escrowArb), 500)
            });
            // Then call escrow function
            calls[1] = ERC7821.Call({
                to: address(t.escrowArb),
                value: 0,
                data: abi.encodeWithSelector(IEscrow.escrow.selector, escrows)
            });
            t.arbIntent.executionData = abi.encode(calls);
        }

        // Compute merkle tree data
        _computeMerkleData(t);

        t.encodedIntents = new bytes[](1);

        // 3. Action on Base, 4. Action on Arbitrum are irrelevant for this test

        // 5. Action on Mainnet (Destination Chain)
        vm.chainId(1);
        // Relay has funds on mainnet for settlement. User has no funds.
        t.usdcMainnet.mint(t.relay, 1000);

        vm.prank(makeAddr("RANDOM_RELAY_ADDRESS"));
        t.usdcMainnet.mint(address(t.funder), 1000);

        // Relay funds the user account, and the intended execution happens.
        t.encodedIntents[0] = abi.encode(t.outputIntent);

        console.log("Test 8: settlerContext offset corruption");
        bytes memory maliciousCalldata = t.encodedIntents[0];
        assembly {
            let dataPtr := add(maliciousCalldata, 0x20) // Skip bytes length prefix
            let intentPtr := add(dataPtr, 0x20) // Points to start of Intent struct
            // settlerContext offset (bytes 480-511 relative to start, or 448-479 in Intent struct)
            mstore(add(intentPtr, 448), 0x10000000000000007) // 2^64 + 7
        }

        assertEq(oc.execute(maliciousCalldata), bytes4(keccak256("VerifiedCallError()")));
    }

    function _computeMerkleData(_TestMultiChainIntentTemps memory t) internal {
        t.leafs = new bytes32[](3);
        vm.chainId(8453);
        t.leafs[0] = oc.computeDigest(t.baseIntent);
        vm.chainId(42161);
        t.leafs[1] = oc.computeDigest(t.arbIntent);
        vm.chainId(1);
        t.leafs[2] = oc.computeDigest(t.outputIntent);

        t.root = merkleHelper.getRoot(t.leafs);

        // 2. User signs the root in a single click.
        t.rootSig = _sig(t.k, t.root);

        t.outputIntent.funderSignature = _eoaSig(t.funderPrivateKey, t.leafs[2]);

        t.baseIntent.signature = abi.encode(merkleHelper.getProof(t.leafs, 0), t.root, t.rootSig);
        t.arbIntent.signature = abi.encode(merkleHelper.getProof(t.leafs, 1), t.root, t.rootSig);
        t.outputIntent.signature = abi.encode(merkleHelper.getProof(t.leafs, 2), t.root, t.rootSig);
    }
}
