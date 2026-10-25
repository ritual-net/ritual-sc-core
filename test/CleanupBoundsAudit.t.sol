// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {AsyncJobTracker} from "../src/async/AsyncJobTracker.sol";
import {Scheduler, CallState} from "../src/scheduler/Scheduler.sol";
import {MockRitualWallet} from "./MockRitualWallet.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title Cleanup Bounds Audit Tests
 * @notice Comprehensive edge case coverage for cleanup bound changes
 * @dev Tests follow FSM model:
 *      S0: No cleanup needed
 *      S1: Cleanup triggered, items > MAX_CLEANUP
 *      S2: Cleanup triggered, items <= MAX_CLEANUP
 *      S3: Cleanup complete
 */
contract CleanupBoundsAuditTest is Test {
    AsyncJobTracker public tracker;
    Scheduler public scheduler;
    MockRitualWallet public wallet;

    address constant SYSTEM_SENDER = 0x000000000000000000000000000000000000Fa8e;
    address constant SCHEDULER_SYSTEM = 0x000000000000000000000000000000000000fa7e;
    address constant EXECUTOR = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    uint256 constant MAX_CLEANUP = 25; // Expected bound

    function setUp() public {
        wallet = new MockRitualWallet(address(0));
        AsyncJobTracker implementation = new AsyncJobTracker(address(0xDEAD), address(wallet), address(0)); // dummy AsyncDelivery addr for tests
        bytes memory initData = abi.encodeWithSelector(AsyncJobTracker.initialize.selector, address(this));
        tracker = AsyncJobTracker(address(new ERC1967Proxy(address(implementation), initData)));
        scheduler = new Scheduler(address(wallet), 30);
        wallet.setScheduler(address(scheduler));

        vm.deal(address(this), 1000 ether);
        vm.deal(address(wallet), 1000 ether);
        vm.deal(address(scheduler), 1000 ether);
        wallet.setBalance(address(this), 100 ether);
        wallet.setBalance(EXECUTOR, 100 ether);
        wallet.setBalance(0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38, 100 ether);
    }

    function _addJobCompat(
        address exec,
        bytes32 id,
        address precomp,
        bytes memory input,
        uint256 ttl,
        bytes32 prevHash,
        uint256 prevNum,
        uint256 prevTime,
        address sender,
        address commitVal,
        bytes32 origHash,
        bytes memory origRlp,
        address txOrigin
    ) internal {
        bytes32[] memory expiredEscrows = new bytes32[](0);
        tracker.addJobAndReserve(
            AsyncJobTracker.AddJobInput({
                exec: exec,
                id: id,
                precomp: precomp,
                input: input,
                ttl: ttl,
                prevHash: prevHash,
                prevNum: prevNum,
                prevTime: prevTime,
                caller: sender,
                commitVal: commitVal,
                origHash: origHash,
                origRlp: origRlp,
                txOrigin: txOrigin
            }),
            AsyncJobTracker.ReserveConfig({sponsor: sender, reserveAmount: 0, expiredEscrows: expiredEscrows})
        );
    }

    function _addJobCompat(
        address exec,
        bytes32 id,
        address precomp,
        bytes memory input,
        uint256 ttl,
        bytes32 prevHash,
        uint256 prevNum,
        uint256 prevTime,
        address sender,
        address commitVal,
        bytes32 origHash,
        bytes memory origRlp
    ) internal {
        _addJobCompat(
            exec, id, precomp, input, ttl, prevHash, prevNum, prevTime, sender, commitVal, origHash, origRlp, sender
        );
    }

    /*//////////////////////////////////////////////////////////////
                    SECTION 1: CONSTANT VERIFICATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Verify MAX_CLEANUP_PER_CALL constant is 25
    function test_AsyncJobTracker_ConstantValue() public view {
        assertEq(tracker.MAX_CLEANUP_PER_CALL(), 25, "MAX_CLEANUP_PER_CALL should be 25");
    }

    /// @notice Verify related constants are unchanged
    function test_AsyncJobTracker_RelatedConstants() public view {
        assertEq(tracker.MAX_PENDING_JOBS(), 10_000, "MAX_PENDING_JOBS unchanged");
        assertEq(tracker.CLEANUP_TRIGGER(), 5000, "CLEANUP_TRIGGER unchanged");
        assertEq(tracker.CLEANUP_INTERVAL(), 30, "CLEANUP_INTERVAL unchanged");
        assertEq(tracker.MAX_CLEANUP_BUCKETS(), 64, "MAX_CLEANUP_BUCKETS unchanged");
        assertEq(tracker.MAX_INPUT_SIZE(), 10 * 1024, "MAX_INPUT_SIZE unchanged");
    }

    /*//////////////////////////////////////////////////////////////
                    SECTION 2: FSM STATE S0 - NO CLEANUP NEEDED
    //////////////////////////////////////////////////////////////*/

    /// @notice S0: Below threshold, no cleanup triggered
    function test_S0_BelowThreshold_NoCleanup() public {
        // Add jobs below CLEANUP_TRIGGER (5000)
        uint256 jobCount = 100;

        vm.startPrank(SYSTEM_SENDER);
        for (uint256 i = 0; i < jobCount; i++) {
            _addJobCompat(
                EXECUTOR,
                _jobId(i),
                address(0x0805),
                hex"01",
                100,
                bytes32(0),
                0,
                0,
                EXECUTOR,
                address(0),
                bytes32(0),
                hex""
            );
        }
        vm.stopPrank();

        // No cleanup should have occurred
        assertEq(tracker.totalPending(), jobCount, "All jobs should remain");
    }

    /// @notice S0: Within cleanup interval, no cleanup triggered
    function test_S0_WithinInterval_NoCleanup() public {
        // Add jobs
        vm.startPrank(SYSTEM_SENDER);
        for (uint256 i = 0; i < 50; i++) {
            _addJobCompat(
                EXECUTOR,
                _jobId(i),
                address(0x0805),
                hex"01",
                100,
                bytes32(0),
                0,
                0,
                EXECUTOR,
                address(0),
                bytes32(0),
                hex""
            );
        }
        vm.stopPrank();

        // Roll forward less than CLEANUP_INTERVAL (30)
        vm.roll(block.number + 20);

        // Add one more job - should NOT trigger cleanup
        vm.prank(SYSTEM_SENDER);
        _addJobCompat(
            EXECUTOR,
            _jobId(999),
            address(0x0805),
            hex"01",
            100,
            bytes32(0),
            0,
            0,
            EXECUTOR,
            address(0),
            bytes32(0),
            hex""
        );

        assertEq(tracker.totalPending(), 51, "No cleanup should have occurred");
    }

    /*//////////////////////////////////////////////////////////////
                    SECTION 3: FSM STATE S1 - CLEANUP, ITEMS > MAX
    //////////////////////////////////////////////////////////////*/

    /// @notice S1: Many expired items, cleanup bounded at MAX_CLEANUP
    function test_S1_ManyExpired_BoundedCleanup() public {
        uint256 jobCount = 100;

        // Add jobs with TTL=1
        vm.startPrank(SYSTEM_SENDER);
        for (uint256 i = 0; i < jobCount; i++) {
            _addJobCompat(
                EXECUTOR,
                _jobId(i),
                address(0x0805),
                hex"01",
                1, // TTL=1 expires next block
                bytes32(0),
                0,
                0,
                EXECUTOR,
                address(0),
                bytes32(0),
                hex""
            );
        }
        vm.stopPrank();

        assertEq(tracker.totalPending(), jobCount, "All jobs added");

        // Roll past TTL and past CLEANUP_INTERVAL
        vm.roll(block.number + 35);

        // Trigger cleanup by adding one more job
        vm.prank(SYSTEM_SENDER);
        _addJobCompat(
            EXECUTOR,
            _jobId(999),
            address(0x0805),
            hex"01",
            100,
            bytes32(0),
            0,
            0,
            EXECUTOR,
            address(0),
            bytes32(0),
            hex""
        );

        // Should have cleaned exactly MAX_CLEANUP (25) + added 1 new
        // 100 - 25 + 1 = 76
        uint256 remaining = tracker.totalPending();
        assertEq(remaining, 76, "Should clean exactly 25, then add 1");
    }

    /// @notice S1→S1: Multiple cleanup cycles needed
    function test_S1_MultipleCleanupCycles() public {
        uint256 jobCount = 100;

        // Add jobs with TTL=1
        vm.startPrank(SYSTEM_SENDER);
        for (uint256 i = 0; i < jobCount; i++) {
            _addJobCompat(
                EXECUTOR,
                _jobId(i),
                address(0x0805),
                hex"01",
                1,
                bytes32(0),
                0,
                0,
                EXECUTOR,
                address(0),
                bytes32(0),
                hex""
            );
        }
        vm.stopPrank();

        // Roll past TTL and CLEANUP_INTERVAL
        vm.roll(block.number + 35);

        // First cleanup: 100 - 25 + 1 = 76
        vm.prank(SYSTEM_SENDER);
        _addJobCompat(
            EXECUTOR,
            _jobId(1000),
            address(0x0805),
            hex"01",
            100,
            bytes32(0),
            0,
            0,
            EXECUTOR,
            address(0),
            bytes32(0),
            hex""
        );
        assertEq(tracker.totalPending(), 76, "After 1st cleanup");

        // Roll again for next cleanup
        vm.roll(block.number + 35);

        // Second cleanup: 76 - 25 + 1 = 52
        vm.prank(SYSTEM_SENDER);
        _addJobCompat(
            EXECUTOR,
            _jobId(1001),
            address(0x0805),
            hex"01",
            100,
            bytes32(0),
            0,
            0,
            EXECUTOR,
            address(0),
            bytes32(0),
            hex""
        );
        assertEq(tracker.totalPending(), 52, "After 2nd cleanup");

        // Roll again
        vm.roll(block.number + 35);

        // Third cleanup: 52 - 25 + 1 = 28
        vm.prank(SYSTEM_SENDER);
        _addJobCompat(
            EXECUTOR,
            _jobId(1002),
            address(0x0805),
            hex"01",
            100,
            bytes32(0),
            0,
            0,
            EXECUTOR,
            address(0),
            bytes32(0),
            hex""
        );
        assertEq(tracker.totalPending(), 28, "After 3rd cleanup");

        // Roll again
        vm.roll(block.number + 35);

        // Fourth cleanup: 28 - 25 + 1 = 4 (now in S2 territory)
        vm.prank(SYSTEM_SENDER);
        _addJobCompat(
            EXECUTOR,
            _jobId(1003),
            address(0x0805),
            hex"01",
            100,
            bytes32(0),
            0,
            0,
            EXECUTOR,
            address(0),
            bytes32(0),
            hex""
        );
        assertEq(tracker.totalPending(), 4, "After 4th cleanup - all expired cleaned");
    }

    /*//////////////////////////////////////////////////////////////
                    SECTION 4: FSM STATE S2 - CLEANUP, ITEMS <= MAX
    //////////////////////////////////////////////////////////////*/

    /// @notice S2: Exactly MAX_CLEANUP expired items
    function test_S2_ExactlyMaxExpired() public {
        // Add exactly 25 jobs with TTL=1
        vm.startPrank(SYSTEM_SENDER);
        for (uint256 i = 0; i < MAX_CLEANUP; i++) {
            _addJobCompat(
                EXECUTOR,
                _jobId(i),
                address(0x0805),
                hex"01",
                1,
                bytes32(0),
                0,
                0,
                EXECUTOR,
                address(0),
                bytes32(0),
                hex""
            );
        }
        vm.stopPrank();

        vm.roll(block.number + 35);

        // Trigger cleanup - should clean all 25
        vm.prank(SYSTEM_SENDER);
        _addJobCompat(
            EXECUTOR,
            _jobId(999),
            address(0x0805),
            hex"01",
            100,
            bytes32(0),
            0,
            0,
            EXECUTOR,
            address(0),
            bytes32(0),
            hex""
        );

        assertEq(tracker.totalPending(), 1, "Should clean all 25, have 1 new");
    }

    /// @notice S2: Fewer than MAX_CLEANUP expired items
    function test_S2_FewerThanMaxExpired() public {
        uint256 expiredCount = 10;

        // Add jobs with TTL=1
        vm.startPrank(SYSTEM_SENDER);
        for (uint256 i = 0; i < expiredCount; i++) {
            _addJobCompat(
                EXECUTOR,
                _jobId(i),
                address(0x0805),
                hex"01",
                1,
                bytes32(0),
                0,
                0,
                EXECUTOR,
                address(0),
                bytes32(0),
                hex""
            );
        }
        vm.stopPrank();

        vm.roll(block.number + 35);

        // Trigger cleanup - should clean all 10
        vm.prank(SYSTEM_SENDER);
        _addJobCompat(
            EXECUTOR,
            _jobId(999),
            address(0x0805),
            hex"01",
            100,
            bytes32(0),
            0,
            0,
            EXECUTOR,
            address(0),
            bytes32(0),
            hex""
        );

        assertEq(tracker.totalPending(), 1, "Should clean all 10, have 1 new");
    }

    /*//////////////////////////////////////////////////////////////
                    SECTION 5: FSM STATE S3 - CLEANUP COMPLETE
    //////////////////////////////////////////////////////////////*/

    /// @notice S3: No expired items, no cleanup occurs
    function test_S3_NoExpiredItems() public {
        // Add jobs with long TTL (capped at MAX_TTL_BLOCKS = 500)
        vm.startPrank(SYSTEM_SENDER);
        for (uint256 i = 0; i < 50; i++) {
            _addJobCompat(
                EXECUTOR,
                _jobId(i),
                address(0x0805),
                hex"01",
                500, // MAX_TTL_BLOCKS
                bytes32(0),
                0,
                0,
                EXECUTOR,
                address(0),
                bytes32(0),
                hex""
            );
        }
        vm.stopPrank();

        // Roll past CLEANUP_INTERVAL but not past TTL
        vm.roll(block.number + 35);

        // Trigger cleanup - nothing should be cleaned
        vm.prank(SYSTEM_SENDER);
        _addJobCompat(
            EXECUTOR,
            _jobId(999),
            address(0x0805),
            hex"01",
            100,
            bytes32(0),
            0,
            0,
            EXECUTOR,
            address(0),
            bytes32(0),
            hex""
        );

        assertEq(tracker.totalPending(), 51, "No jobs should be cleaned");
    }

    /*//////////////////////////////////////////////////////////////
                    SECTION 6: EDGE CASES
    //////////////////////////////////////////////////////////////*/

    /// @notice Edge: Zero expired items
    function test_Edge_ZeroExpiredItems() public {
        vm.roll(block.number + 35);

        // Just add a job - cleanup runs but finds nothing
        vm.prank(SYSTEM_SENDER);
        _addJobCompat(
            EXECUTOR,
            _jobId(0),
            address(0x0805),
            hex"01",
            100,
            bytes32(0),
            0,
            0,
            EXECUTOR,
            address(0),
            bytes32(0),
            hex""
        );

        assertEq(tracker.totalPending(), 1, "Should have exactly 1 job");
    }

    /// @notice Edge: Exactly one expired item
    function test_Edge_OneExpiredItem() public {
        vm.prank(SYSTEM_SENDER);
        _addJobCompat(
            EXECUTOR, _jobId(0), address(0x0805), hex"01", 1, bytes32(0), 0, 0, EXECUTOR, address(0), bytes32(0), hex""
        );

        vm.roll(block.number + 35);

        vm.prank(SYSTEM_SENDER);
        _addJobCompat(
            EXECUTOR,
            _jobId(1),
            address(0x0805),
            hex"01",
            100,
            bytes32(0),
            0,
            0,
            EXECUTOR,
            address(0),
            bytes32(0),
            hex""
        );

        assertEq(tracker.totalPending(), 1, "Should clean 1, have 1 new");
    }

    /// @notice Edge: MAX_CLEANUP - 1 expired items
    function test_Edge_MaxMinusOneExpired() public {
        vm.startPrank(SYSTEM_SENDER);
        for (uint256 i = 0; i < MAX_CLEANUP - 1; i++) {
            _addJobCompat(
                EXECUTOR,
                _jobId(i),
                address(0x0805),
                hex"01",
                1,
                bytes32(0),
                0,
                0,
                EXECUTOR,
                address(0),
                bytes32(0),
                hex""
            );
        }
        vm.stopPrank();

        vm.roll(block.number + 35);

        vm.prank(SYSTEM_SENDER);
        _addJobCompat(
            EXECUTOR,
            _jobId(999),
            address(0x0805),
            hex"01",
            100,
            bytes32(0),
            0,
            0,
            EXECUTOR,
            address(0),
            bytes32(0),
            hex""
        );

        assertEq(tracker.totalPending(), 1, "Should clean 24, have 1 new");
    }

    /// @notice Edge: MAX_CLEANUP + 1 expired items
    function test_Edge_MaxPlusOneExpired() public {
        vm.startPrank(SYSTEM_SENDER);
        for (uint256 i = 0; i < MAX_CLEANUP + 1; i++) {
            _addJobCompat(
                EXECUTOR,
                _jobId(i),
                address(0x0805),
                hex"01",
                1,
                bytes32(0),
                0,
                0,
                EXECUTOR,
                address(0),
                bytes32(0),
                hex""
            );
        }
        vm.stopPrank();

        vm.roll(block.number + 35);

        vm.prank(SYSTEM_SENDER);
        _addJobCompat(
            EXECUTOR,
            _jobId(999),
            address(0x0805),
            hex"01",
            100,
            bytes32(0),
            0,
            0,
            EXECUTOR,
            address(0),
            bytes32(0),
            hex""
        );

        // 26 - 25 + 1 = 2
        assertEq(tracker.totalPending(), 2, "Should clean 25, leave 1 expired + 1 new");
    }

    /*//////////////////////////////////////////////////////////////
                    SECTION 7: GAS BOUNDS VERIFICATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Gas: Cleanup with MAX_CLEANUP items should use bounded gas
    function test_Gas_CleanupBounded() public {
        // Add 100 jobs
        vm.startPrank(SYSTEM_SENDER);
        for (uint256 i = 0; i < 100; i++) {
            _addJobCompat(
                EXECUTOR,
                _jobId(i),
                address(0x0805),
                hex"01",
                1,
                bytes32(0),
                0,
                0,
                EXECUTOR,
                address(0),
                bytes32(0),
                hex""
            );
        }
        vm.stopPrank();

        vm.roll(block.number + 35);

        // Measure gas for cleanup
        uint256 gasBefore = gasleft();

        vm.prank(SYSTEM_SENDER);
        _addJobCompat(
            EXECUTOR,
            _jobId(999),
            address(0x0805),
            hex"01",
            100,
            bytes32(0),
            0,
            0,
            EXECUTOR,
            address(0),
            bytes32(0),
            hex""
        );

        uint256 gasUsed = gasBefore - gasleft();

        // Should be bounded - less than 2M gas for cleanup
        assertLt(gasUsed, 2_000_000, "Cleanup gas should be bounded");

        console.log("Gas used for addJob + cleanup(25):", gasUsed);
    }

    /// @notice Gas: External cleanupBatch - verify bounded behavior
    /// @dev After fix, cleanupBatch respects MAX_CLEANUP_PER_CALL bound
    function test_Gas_ExternalCleanupBatchBehavior() public {
        uint256 startBlock = block.number;

        // Add 100 jobs all expiring at same block (same bucket)
        vm.startPrank(SYSTEM_SENDER);
        for (uint256 i = 0; i < 100; i++) {
            _addJobCompat(
                EXECUTOR,
                _jobId(i),
                address(0x0805),
                hex"01",
                1, // TTL=1, expiry = startBlock + 1
                bytes32(0),
                0,
                0,
                EXECUTOR,
                address(0),
                bytes32(0),
                hex""
            );
        }
        vm.stopPrank();

        // Jobs expire at bucket (startBlock + 1)
        uint256 expiryBucket = startBlock + 1;

        vm.roll(block.number + 35);

        uint256 lastCleanupBefore = tracker.lastCleanup();
        console.log("lastCleanup:", lastCleanupBefore);
        console.log("expiryBucket:", expiryBucket);

        // First cleanupBatch - bounded at 25
        (uint256 cleaned1, uint256 buckets1) = tracker.cleanupBatch(expiryBucket);

        console.log("cleaned (batch 1):", cleaned1);
        console.log("buckets (batch 1):", buckets1);
        console.log("pending after batch 1:", tracker.totalPending());

        // NOW BOUNDED: Only cleans 25
        assertEq(cleaned1, 25, "Bounded at 25");
        assertEq(tracker.totalPending(), 75, "75 remain after first batch");

        // Need multiple batches to clean all 100
        (uint256 cleaned2,) = tracker.cleanupBatch(expiryBucket);
        (uint256 cleaned3,) = tracker.cleanupBatch(expiryBucket);
        (uint256 cleaned4,) = tracker.cleanupBatch(expiryBucket);

        assertEq(cleaned2 + cleaned3 + cleaned4, 75, "Remaining 75 cleaned in 3 more batches");
        assertEq(tracker.totalPending(), 0, "All cleaned");
    }

    /// @notice Verify cleanupBatch is now bounded at MAX_CLEANUP_PER_CALL
    /// @dev After fix, inner while loop respects MAX_CLEANUP_PER_CALL = 25
    function test_CleanupBatchNowBounded() public {
        // Put many jobs in ONE bucket
        uint256 startBlock = block.number;

        vm.startPrank(SYSTEM_SENDER);
        for (uint256 i = 0; i < 50; i++) {
            _addJobCompat(
                EXECUTOR,
                _jobId(i),
                address(0x0805),
                hex"01",
                1, // All in same bucket
                bytes32(0),
                0,
                0,
                EXECUTOR,
                address(0),
                bytes32(0),
                hex""
            );
        }
        vm.stopPrank();

        uint256 expiryBucket = startBlock + 1;
        vm.roll(block.number + 5);

        // First cleanupBatch - should clean exactly 25 (bounded)
        uint256 gasBefore = gasleft();
        (uint256 cleaned1,) = tracker.cleanupBatch(expiryBucket);
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Gas for cleanupBatch (25 of 50):", gasUsed);

        // NOW BOUNDED: Only cleans MAX_CLEANUP_PER_CALL = 25
        assertEq(cleaned1, 25, "Should clean exactly 25 (bounded)");
        assertEq(tracker.totalPending(), 25, "25 should remain");

        // Second cleanupBatch - cleans remaining 25
        (uint256 cleaned2,) = tracker.cleanupBatch(expiryBucket);
        assertEq(cleaned2, 25, "Should clean remaining 25");
        assertEq(tracker.totalPending(), 0, "All cleaned after 2 batches");
    }

    /*//////////////////////////////////////////////////////////////
                    SECTION 8: PROGRESS TRACKING (lastCleanup)
    //////////////////////////////////////////////////////////////*/

    /// @notice Progress: lastCleanup updates correctly for full bucket
    function test_Progress_LastCleanupUpdates() public {
        // Add jobs
        vm.startPrank(SYSTEM_SENDER);
        for (uint256 i = 0; i < 10; i++) {
            _addJobCompat(
                EXECUTOR,
                _jobId(i),
                address(0x0805),
                hex"01",
                1,
                bytes32(0),
                0,
                0,
                EXECUTOR,
                address(0),
                bytes32(0),
                hex""
            );
        }
        vm.stopPrank();

        uint256 lastCleanupBefore = tracker.lastCleanup();

        vm.roll(block.number + 35);

        // Trigger cleanup
        vm.prank(SYSTEM_SENDER);
        _addJobCompat(
            EXECUTOR,
            _jobId(999),
            address(0x0805),
            hex"01",
            100,
            bytes32(0),
            0,
            0,
            EXECUTOR,
            address(0),
            bytes32(0),
            hex""
        );

        uint256 lastCleanupAfter = tracker.lastCleanup();

        // lastCleanup should have advanced
        assertGt(lastCleanupAfter, lastCleanupBefore, "lastCleanup should advance");
    }

    /*//////////////////////////////////////////////////////////////
                    SECTION 9: SCHEDULER CLEANUP TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Scheduler: Verify scheduled execute cleanup bound constant
    function test_Scheduler_ExecuteCleanupBoundConstant() public view {
        assertEq(scheduler.MAX_CLEANUP_BATCH(), 25, "scheduled execute cleanup must remain bounded");
    }

    /// @notice Scheduler explicit cleanup observes the strict expiry boundary
    function test_Scheduler_ExplicitCleanupExpiresOnlyAfterDeadline() public {
        uint256 callId = scheduler.schedule(hex"01020304", 150_000, 1, 1, 5, 20 gwei, 2 gwei, 0);
        uint256[] memory callIds = new uint256[](1);
        callIds[0] = callId;
        uint256 expiryBlock = block.number + 6;

        vm.roll(expiryBlock);
        scheduler.cleanupExpiredCalls(callIds);
        assertEq(
            uint256(scheduler.getCallState(callId)),
            uint256(CallState.SCHEDULED),
            "call must remain scheduled at its expiry block"
        );

        vm.roll(expiryBlock + 1);
        scheduler.cleanupExpiredCalls(callIds);
        vm.expectRevert(Scheduler.CallNotFound.selector);
        scheduler.getCallState(callId);
    }

    /*//////////////////////////////////////////////////////////////
                    SECTION 10: FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz: Cleanup never exceeds MAX_CLEANUP
    function testFuzz_CleanupNeverExceedsMax(uint8 jobCount) public {
        // Bound to reasonable range
        uint256 count = bound(jobCount, 1, 100);

        // Add jobs
        vm.startPrank(SYSTEM_SENDER);
        for (uint256 i = 0; i < count; i++) {
            _addJobCompat(
                EXECUTOR,
                keccak256(abi.encodePacked("fuzz", block.number, i)),
                address(0x0805),
                hex"01",
                1,
                bytes32(0),
                0,
                0,
                EXECUTOR,
                address(0),
                bytes32(0),
                hex""
            );
        }
        vm.stopPrank();

        uint256 pendingBefore = tracker.totalPending();
        assertEq(pendingBefore, count, "All jobs added");

        vm.roll(block.number + 35);

        // Trigger cleanup
        vm.prank(SYSTEM_SENDER);
        _addJobCompat(
            EXECUTOR,
            keccak256(abi.encodePacked("trigger", block.number)),
            address(0x0805),
            hex"01",
            100,
            bytes32(0),
            0,
            0,
            EXECUTOR,
            address(0),
            bytes32(0),
            hex""
        );

        uint256 pendingAfter = tracker.totalPending();

        // Calculate how many were cleaned
        // cleaned = pendingBefore - pendingAfter + 1 (for new job)
        uint256 cleaned = pendingBefore - pendingAfter + 1;

        // Verify cleanup was bounded
        assertLe(cleaned, MAX_CLEANUP, "Should never clean more than MAX_CLEANUP");
    }

    /// @notice Fuzz: All jobs eventually cleaned
    function testFuzz_AllJobsEventuallyCleaned(uint8 seed) public {
        uint256 count = bound(seed, 10, 50);

        // Add jobs
        vm.startPrank(SYSTEM_SENDER);
        for (uint256 i = 0; i < count; i++) {
            _addJobCompat(
                EXECUTOR,
                keccak256(abi.encodePacked("fuzz2", i)),
                address(0x0805),
                hex"01",
                1,
                bytes32(0),
                0,
                0,
                EXECUTOR,
                address(0),
                bytes32(0),
                hex""
            );
        }
        vm.stopPrank();

        vm.roll(block.number + 35);

        // Keep triggering cleanup until all cleaned
        uint256 iterations = 0;
        uint256 maxIterations = (count / MAX_CLEANUP) + 5; // Upper bound on iterations needed

        while (tracker.totalPending() > 0 && iterations < maxIterations) {
            vm.roll(block.number + 35);
            vm.prank(SYSTEM_SENDER);
            _addJobCompat(
                EXECUTOR,
                keccak256(abi.encodePacked("iter", iterations)),
                address(0x0805),
                hex"01",
                1,
                bytes32(0),
                0,
                0,
                EXECUTOR,
                address(0),
                bytes32(0),
                hex""
            );
            iterations++;
        }

        // All original jobs should be cleaned (may have some trigger jobs remaining)
        assertLt(tracker.totalPending(), maxIterations + 1, "Most jobs should be cleaned");
    }

    /*//////////////////////////////////////////////////////////////
                    SECTION 11: SCHEDULER CLEANUP EDGE CASES
    //////////////////////////////////////////////////////////////*/

    /// @notice Scheduler: cleanupExpiredCalls requires explicit IDs
    function test_Scheduler_CleanupRejectsEmptyBatch() public {
        for (uint256 i = 0; i < 5; i++) {
            scheduler.schedule(
                hex"01020304", 150_000, uint32(block.number + i + 1), 1, 5, 20 gwei, 2 gwei, 0, address(this)
            );
        }

        vm.roll(block.number + 200);

        uint256[] memory emptyIds = new uint256[](0);
        vm.expectRevert(Scheduler.InvalidCleanupBatchSize.selector);
        scheduler.cleanupExpiredCalls(emptyIds);
    }

    /// @notice Scheduler: cleanupExpiredCalls with explicit IDs
    function test_Scheduler_CleanupExplicitIds() public {
        uint256[] memory callIds = new uint256[](5);

        // Schedule calls and track IDs
        for (uint256 i = 0; i < 5; i++) {
            callIds[i] = scheduler.schedule(
                hex"01020304", 150_000, uint32(block.number + i + 1), 1, 5, 20 gwei, 2 gwei, 0, address(this)
            );
        }

        // Verify calls exist
        for (uint256 i = 0; i < 5; i++) {
            CallState state = scheduler.getCallState(callIds[i]);
            assertEq(uint256(state), uint256(CallState.SCHEDULED), "Call should be scheduled");
        }

        // Roll past expiry
        vm.roll(block.number + 200);

        // Cleanup the caller-supplied explicit IDs
        scheduler.cleanupExpiredCalls(callIds);

        // All calls should be deleted (getCallState reverts for non-existent)
        for (uint256 i = 0; i < 5; i++) {
            vm.expectRevert();
            scheduler.getCallState(callIds[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    SECTION 12: INVARIANT TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Invariant: totalPending always accurate
    function test_Invariant_TotalPendingAccurate() public {
        uint256 added = 0;
        uint256 cleaned = 0;

        vm.startPrank(SYSTEM_SENDER);

        // Add 30 jobs
        for (uint256 i = 0; i < 30; i++) {
            _addJobCompat(
                EXECUTOR,
                _jobId(i),
                address(0x0805),
                hex"01",
                1,
                bytes32(0),
                0,
                0,
                EXECUTOR,
                address(0),
                bytes32(0),
                hex""
            );
            added++;
        }

        assertEq(tracker.totalPending(), added, "After adding 30");

        vm.stopPrank();

        // Roll and trigger cleanup
        vm.roll(block.number + 35);

        vm.prank(SYSTEM_SENDER);
        _addJobCompat(
            EXECUTOR,
            _jobId(100),
            address(0x0805),
            hex"01",
            100,
            bytes32(0),
            0,
            0,
            EXECUTOR,
            address(0),
            bytes32(0),
            hex""
        );
        added++;
        cleaned = 25; // MAX_CLEANUP

        assertEq(tracker.totalPending(), added - cleaned, "After cleanup");
    }

    /// @notice Invariant: Cleanup never cleans non-expired jobs
    function test_Invariant_NeverCleansNonExpired() public {
        // Add mix of short and long TTL jobs
        vm.startPrank(SYSTEM_SENDER);

        // 10 short TTL (will expire)
        for (uint256 i = 0; i < 10; i++) {
            _addJobCompat(
                EXECUTOR,
                keccak256(abi.encodePacked("short", i)),
                address(0x0805),
                hex"01",
                1,
                bytes32(0),
                0,
                0,
                EXECUTOR,
                address(0),
                bytes32(0),
                hex""
            );
        }

        // 10 long TTL (won't expire, capped at MAX_TTL_BLOCKS = 500)
        for (uint256 i = 0; i < 10; i++) {
            _addJobCompat(
                EXECUTOR,
                keccak256(abi.encodePacked("long", i)),
                address(0x0805),
                hex"01",
                500,
                bytes32(0),
                0,
                0,
                EXECUTOR,
                address(0),
                bytes32(0),
                hex""
            );
        }

        vm.stopPrank();

        assertEq(tracker.totalPending(), 20, "20 jobs added");

        // Roll past short TTL but not long TTL
        vm.roll(block.number + 35);

        // Trigger cleanup
        vm.prank(SYSTEM_SENDER);
        _addJobCompat(
            EXECUTOR,
            keccak256("trigger"),
            address(0x0805),
            hex"01",
            100,
            bytes32(0),
            0,
            0,
            EXECUTOR,
            address(0),
            bytes32(0),
            hex""
        );

        // Should have: 10 long TTL + 1 trigger = 11
        assertEq(tracker.totalPending(), 11, "Only expired jobs cleaned");
    }

    /*//////////////////////////////////////////////////////////////
                    SECTION 13: DOCUMENTED FINDINGS
    //////////////////////////////////////////////////////////////*/

    /// @notice Verify cleanupBatch fix is complete
    /// @dev Both _cleanup() and cleanupBatch() now bounded at MAX_CLEANUP_PER_CALL
    function test_AllCleanupPathsBounded() public view {
        // Verify the constant exists and is set correctly
        assertEq(tracker.MAX_CLEANUP_PER_CALL(), 25, "MAX_CLEANUP_PER_CALL should be 25");

        // Both cleanup paths are now bounded:
        // 1. _cleanup() - internal, triggered by addJob
        // 2. cleanupBatch() - external, called directly
    }

    /*//////////////////////////////////////////////////////////////
                    HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _jobId(uint256 i) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("job", block.number, i, block.timestamp));
    }
}
