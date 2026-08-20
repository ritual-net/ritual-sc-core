// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Scheduler, CallState} from "../src/scheduler/Scheduler.sol";
import {MockRitualWallet} from "./MockRitualWallet.sol";

contract SchedulerTargetedCleanupTarget {
    uint256 public callbackCount;

    function scheduleAt(Scheduler scheduler, uint32 startBlock, uint32 numCalls, uint32 frequency, uint32 ttl)
        external
        returns (uint256)
    {
        return scheduler.schedule("", 500_000, startBlock, numCalls, frequency, ttl, 20 gwei, 2 gwei, 0, address(this));
    }

    function onScheduledExecution(uint256, bytes calldata) external {
        ++callbackCount;
    }
}

contract SchedulerTargetedCleanupTest is Test {
    address internal constant SYSTEM_ACCOUNT = 0x000000000000000000000000000000000000fa7e;
    bytes4 internal constant FIXED_EXECUTE_SELECTOR = 0x59db9615;
    bytes32 internal constant CALL_EXPIRED_TOPIC =
        keccak256("CallExpired(uint256,address,address,uint32,uint32,uint256)");

    Scheduler internal scheduler;
    SchedulerTargetedCleanupTarget internal target;
    MockRitualWallet internal wallet;

    function setUp() public {
        wallet = new MockRitualWallet(address(0));
        scheduler = new Scheduler(address(wallet), 30);
        target = new SchedulerTargetedCleanupTarget();

        wallet.setScheduler(address(scheduler));
        wallet.setBalance(address(target), 10_000 ether);
        vm.deal(address(wallet), 10_000 ether);
        vm.deal(address(scheduler), 10_000 ether);
    }

    function _scheduleExpired() internal returns (uint256) {
        return target.scheduleAt(scheduler, uint32(block.number + 1), 1, 1, 0);
    }

    function _scheduleTarget(uint32 numCalls) internal returns (uint256) {
        return target.scheduleAt(scheduler, uint32(block.number + 2), numCalls, 10, 0);
    }

    function _executeDynamic(uint256 callId, uint256[] memory cleanupCallIds) internal {
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 0, cleanupCallIds);
    }

    function _assertScheduled(uint256 callId) internal view {
        assertEq(uint8(scheduler.getCallState(callId)), uint8(CallState.SCHEDULED));
    }

    function _assertMissing(uint256 callId) internal {
        vm.expectRevert(Scheduler.CallNotFound.selector);
        scheduler.getCallState(callId);
    }

    function testRuntimeBytecodeRemainsEip170Compliant() public view {
        assertLt(address(scheduler).code.length, 24_576);
    }

    function testLegacyTwoArgumentExecuteStillWorks() public {
        uint256 targetCallId = _scheduleTarget(1);
        vm.roll(block.number + 2);

        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(targetCallId, 0);

        assertEq(target.callbackCount(), 1);
    }

    function testFixedArrayExecuteOverloadDoesNotExist() public {
        uint256[1] memory cleanupCallIds;
        bytes memory input = abi.encodeWithSelector(FIXED_EXECUTE_SELECTOR, uint256(0), uint256(0), cleanupCallIds);

        vm.prank(SYSTEM_ACCOUNT);
        (bool success,) = address(scheduler).call(input);

        assertFalse(success);
    }

    function testDynamicCleanupBatchLengthZeroExecutesTarget() public {
        uint256 targetCallId = _scheduleTarget(1);
        uint256[] memory cleanupCallIds = new uint256[](0);
        vm.roll(block.number + 2);

        _executeDynamic(targetCallId, cleanupCallIds);

        assertEq(target.callbackCount(), 1);
    }

    function testDynamicCleanupBatchLengthOneCleansBeforeExecuting() public {
        uint256 expiredCallId = _scheduleExpired();
        uint256 targetCallId = _scheduleTarget(1);
        uint256[] memory cleanupCallIds = new uint256[](1);
        cleanupCallIds[0] = expiredCallId;
        vm.roll(block.number + 2);

        _executeDynamic(targetCallId, cleanupCallIds);

        _assertMissing(expiredCallId);
        assertEq(target.callbackCount(), 1);
    }

    function testDynamicCleanupBatchLengthTwentyFiveStaysWithinGasBudget() public {
        uint256[] memory cleanupCallIds = new uint256[](scheduler.MAX_CLEANUP_BATCH());
        for (uint256 i; i < cleanupCallIds.length; ++i) {
            cleanupCallIds[i] = _scheduleExpired();
        }
        uint256 targetCallId = _scheduleTarget(1);
        vm.roll(block.number + 2);

        uint256 gasBefore = gasleft();
        _executeDynamic(targetCallId, cleanupCallIds);
        uint256 gasUsed = gasBefore - gasleft();

        for (uint256 i; i < cleanupCallIds.length; ++i) {
            _assertMissing(cleanupCallIds[i]);
        }
        assertEq(target.callbackCount(), 1);
        assertLt(gasUsed, 8_000_000, "targeted cleanup batch exceeded gas budget");
    }

    function testDynamicCleanupBatchLengthTwentySixRevertsWithoutCleanup() public {
        uint256 expiredCallId = _scheduleExpired();
        uint256 targetCallId = _scheduleTarget(1);
        uint256[] memory cleanupCallIds = new uint256[](scheduler.MAX_CLEANUP_BATCH() + 1);
        cleanupCallIds[0] = expiredCallId;
        vm.roll(block.number + 2);

        vm.expectRevert(Scheduler.InvalidCleanupBatchSize.selector);
        _executeDynamic(targetCallId, cleanupCallIds);

        _assertScheduled(expiredCallId);
        _assertScheduled(targetCallId);
        assertEq(target.callbackCount(), 0);
    }

    function testStandaloneCleanupCleansExplicitIdAndAcceptsTwentyFive() public {
        uint256 oneCallId = _scheduleExpired();
        uint256[] memory oneCallIdBatch = new uint256[](1);
        oneCallIdBatch[0] = oneCallId;

        uint256[] memory maxBatch = new uint256[](scheduler.MAX_CLEANUP_BATCH());
        for (uint256 i; i < maxBatch.length; ++i) {
            maxBatch[i] = _scheduleExpired();
        }
        vm.roll(block.number + 2);

        scheduler.cleanupExpiredCalls(oneCallIdBatch);
        scheduler.cleanupExpiredCalls(maxBatch);

        _assertMissing(oneCallId);
        for (uint256 i; i < maxBatch.length; ++i) {
            _assertMissing(maxBatch[i]);
        }
    }

    function testStandaloneCleanupRejectsEmptyBatch() public {
        uint256[] memory emptyBatch = new uint256[](0);
        vm.expectRevert(Scheduler.InvalidCleanupBatchSize.selector);
        scheduler.cleanupExpiredCalls(emptyBatch);
    }

    function testStandaloneCleanupAcceptsMoreThanDynamicCap() public {
        uint256[] memory cleanupCallIds = new uint256[](scheduler.MAX_CLEANUP_BATCH() + 1);
        for (uint256 i; i < cleanupCallIds.length; ++i) {
            cleanupCallIds[i] = _scheduleExpired();
        }
        vm.roll(block.number + 2);

        scheduler.cleanupExpiredCalls(cleanupCallIds);

        for (uint256 i; i < cleanupCallIds.length; ++i) {
            _assertMissing(cleanupCallIds[i]);
        }
    }

    function testMissingUnexpiredAndDuplicateCleanupIdsAreNoOps() public {
        uint256 expiredCallId = _scheduleExpired();
        uint256 unexpiredCallId = target.scheduleAt(scheduler, uint32(block.number + 100), 1, 1, 0);
        uint256[] memory cleanupCallIds = new uint256[](4);
        cleanupCallIds[0] = expiredCallId;
        cleanupCallIds[1] = expiredCallId;
        cleanupCallIds[2] = type(uint256).max;
        cleanupCallIds[3] = unexpiredCallId;
        vm.roll(block.number + 2);

        scheduler.cleanupExpiredCalls(cleanupCallIds);

        _assertMissing(expiredCallId);
        _assertScheduled(unexpiredCallId);
    }

    function testUnexpiredTargetInBatchSurvivesCleanupAndCompaction() public {
        uint256[] memory cleanupCallIds = new uint256[](4);
        cleanupCallIds[0] = _scheduleExpired();
        cleanupCallIds[2] = _scheduleExpired();
        cleanupCallIds[3] = _scheduleExpired();
        uint256 targetCallId = _scheduleTarget(2);
        cleanupCallIds[1] = targetCallId;
        assertEq(scheduler.callToSlot(targetCallId), 3);
        vm.roll(block.number + 2);

        _executeDynamic(targetCallId, cleanupCallIds);

        assertEq(target.callbackCount(), 1);
        _assertScheduled(targetCallId);
        assertEq(scheduler.callToSlot(targetCallId), 0);
        _assertMissing(cleanupCallIds[0]);
        _assertMissing(cleanupCallIds[2]);
        _assertMissing(cleanupCallIds[3]);
    }

    function testExpiredTargetInBatchIsHandledByExecute() public {
        uint256 targetCallId = _scheduleExpired();
        uint256 otherExpiredCallId = _scheduleExpired();
        uint256[] memory cleanupCallIds = new uint256[](2);
        cleanupCallIds[0] = targetCallId;
        cleanupCallIds[1] = otherExpiredCallId;
        vm.roll(block.number + 2);

        _executeDynamic(targetCallId, cleanupCallIds);

        _assertMissing(targetCallId);
        _assertMissing(otherExpiredCallId);
        assertEq(target.callbackCount(), 0);
    }

    function testStandaloneCleanupStillCleansTargetId() public {
        uint256 targetCallId = _scheduleExpired();
        uint256[] memory cleanupCallIds = new uint256[](1);
        cleanupCallIds[0] = targetCallId;
        vm.roll(block.number + 2);

        scheduler.cleanupExpiredCalls(cleanupCallIds);

        _assertMissing(targetCallId);
    }

    function testUnauthorizedExecuteWithTargetInBatchRollsBackCleanup() public {
        uint256 expiredCallId = _scheduleExpired();
        uint256 targetCallId = _scheduleTarget(1);
        uint256[] memory cleanupCallIds = new uint256[](2);
        cleanupCallIds[0] = expiredCallId;
        cleanupCallIds[1] = targetCallId;
        vm.roll(block.number + 2);

        vm.expectRevert(Scheduler.SenderNotSystemAccount.selector);
        scheduler.execute(targetCallId, 0, cleanupCallIds);

        _assertScheduled(expiredCallId);
        _assertScheduled(targetCallId);
        assertEq(target.callbackCount(), 0);
    }

    function testHardExecutionRevertWithTargetInBatchRollsBackCleanup() public {
        uint256[] memory cleanupCallIds = new uint256[](4);
        for (uint256 i; i < 3; ++i) {
            cleanupCallIds[i] = _scheduleExpired();
        }
        uint256 targetCallId = _scheduleTarget(1);
        cleanupCallIds[3] = targetCallId;
        wallet.setFailRefund(true);
        vm.roll(block.number + 2);

        vm.expectRevert(bytes("refund failed"));
        _executeDynamic(targetCallId, cleanupCallIds);

        for (uint256 i; i < 3; ++i) {
            _assertScheduled(cleanupCallIds[i]);
        }
        _assertScheduled(targetCallId);
        assertEq(target.callbackCount(), 0);
    }

    function testEachSuccessfulCleanupEmitsOneCallExpired() public {
        uint256[] memory cleanupCallIds = new uint256[](3);
        for (uint256 i; i < cleanupCallIds.length; ++i) {
            cleanupCallIds[i] = _scheduleExpired();
        }
        uint256 targetCallId = _scheduleTarget(1);
        vm.roll(block.number + 2);

        vm.recordLogs();
        _executeDynamic(targetCallId, cleanupCallIds);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        uint256 expiredEvents;
        for (uint256 i; i < entries.length; ++i) {
            if (
                entries[i].emitter == address(scheduler) && entries[i].topics.length != 0
                    && entries[i].topics[0] == CALL_EXPIRED_TOPIC
            ) {
                assertEq(uint256(entries[i].topics[1]), cleanupCallIds[expiredEvents]);
                ++expiredEvents;
            }
        }
        assertEq(expiredEvents, cleanupCallIds.length);
    }

    function testLegacyExecuteDoesNotScanUnrelatedExpiredSlots() public {
        uint256 unrelatedExpiredCallId = _scheduleExpired();
        uint32 futureStartBlock = uint32(block.number + 100);
        for (uint256 i; i < 999; ++i) {
            target.scheduleAt(scheduler, futureStartBlock, 1, 1, 0);
        }
        uint256 targetCallId = _scheduleTarget(1);
        vm.roll(block.number + 2);

        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(targetCallId, 0);

        _assertScheduled(unrelatedExpiredCallId);
        assertEq(target.callbackCount(), 1);
    }
}
