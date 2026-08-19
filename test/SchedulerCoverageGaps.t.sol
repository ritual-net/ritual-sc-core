// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Scheduler, CallState} from "../src/scheduler/Scheduler.sol";
import {IScheduledPredicate} from "../src/scheduler/interfaces/IScheduledPredicate.sol";
import {MockRitualWallet} from "./MockRitualWallet.sol";

struct SchedulerCoverageParams {
    bytes data;
    uint32 gasLimit;
    uint32 startBlock;
    uint32 numCalls;
    uint32 frequency;
    uint32 ttl;
    uint256 maxFeePerGas;
    uint256 maxPriorityFeePerGas;
    uint256 value;
    address sponsor;
}

struct SchedulerCoverageStoredCall {
    address to;
    address sponsor;
    uint32 startBlock;
    uint32 numCalls;
    uint32 frequency;
    uint32 gasLimit;
    uint32 ttl;
    CallState state;
    uint256 maxFeePerGas;
    uint256 maxPriorityFeePerGas;
    uint256 value;
    bytes data;
}

contract SchedulerCoveragePredicate is IScheduledPredicate {
    function shouldExecute(address, uint256, uint256) external pure returns (bool) {
        return true;
    }
}

contract SchedulerCoverageCaller {
    Scheduler internal immutable SCHEDULER;

    bool public probeEnabled;
    uint256 public probeCallId;
    bytes32 public probeJobId;
    bool public probeSucceeded;
    bytes4 public probeRevertSelector;

    constructor(Scheduler scheduler) {
        SCHEDULER = scheduler;
    }

    function scheduleExplicitStartAndSponsor(SchedulerCoverageParams calldata params) external returns (uint256) {
        return SCHEDULER.schedule(
            params.data,
            params.gasLimit,
            params.startBlock,
            params.numCalls,
            params.frequency,
            params.ttl,
            params.maxFeePerGas,
            params.maxPriorityFeePerGas,
            params.value,
            params.sponsor
        );
    }

    function scheduleAutoStartSelfSponsor(SchedulerCoverageParams calldata params) external returns (uint256) {
        return SCHEDULER.schedule(
            params.data,
            params.gasLimit,
            params.numCalls,
            params.frequency,
            params.ttl,
            params.maxFeePerGas,
            params.maxPriorityFeePerGas,
            params.value
        );
    }

    function scheduleAutoStartExplicitSponsor(SchedulerCoverageParams calldata params) external returns (uint256) {
        return SCHEDULER.schedule(
            params.data,
            params.gasLimit,
            params.numCalls,
            params.frequency,
            params.ttl,
            params.maxFeePerGas,
            params.maxPriorityFeePerGas,
            params.value,
            params.sponsor
        );
    }

    function scheduleMinimal(SchedulerCoverageParams calldata params) external returns (uint256) {
        return SCHEDULER.schedule(params.data, params.gasLimit, params.numCalls, params.frequency);
    }

    function scheduleExplicitStartSponsorAndPredicate(SchedulerCoverageParams calldata params, address predicate)
        external
        returns (uint256)
    {
        return SCHEDULER.schedule(
            params.data,
            params.gasLimit,
            params.startBlock,
            params.numCalls,
            params.frequency,
            params.ttl,
            params.maxFeePerGas,
            params.maxPriorityFeePerGas,
            params.value,
            params.sponsor,
            predicate
        );
    }

    function scheduleAutoStartSponsorAndPredicate(SchedulerCoverageParams calldata params, address predicate)
        external
        returns (uint256)
    {
        return SCHEDULER.schedule(
            params.data,
            params.gasLimit,
            params.numCalls,
            params.frequency,
            params.ttl,
            params.maxFeePerGas,
            params.maxPriorityFeePerGas,
            params.value,
            params.sponsor,
            predicate
        );
    }

    function scheduleMinimalAndPredicate(SchedulerCoverageParams calldata params, address predicate)
        external
        returns (uint256)
    {
        return SCHEDULER.schedule(params.data, params.gasLimit, params.numCalls, params.frequency, predicate);
    }

    function configureInFlightProbe(uint256 callId, bytes32 jobId) external {
        probeEnabled = true;
        probeCallId = callId;
        probeJobId = jobId;
    }

    function onScheduledExecution(uint256 executionIndex, bytes calldata) external payable {
        if (!probeEnabled) {
            return;
        }

        (bool success, bytes memory revertData) = address(SCHEDULER)
            .call(abi.encodeCall(Scheduler.markScheduledAsyncInFlight, (probeCallId, executionIndex, probeJobId)));
        probeSucceeded = success;
        if (!success && revertData.length >= 4) {
            bytes4 selector;
            assembly {
                selector := mload(add(revertData, 0x20))
            }
            probeRevertSelector = selector;
        }
    }
}

contract SchedulerCoverageGapsTest is Test {
    address internal constant ASYNC_COMMITMENT_SYSTEM_ACCOUNT = 0x000000000000000000000000000000000000Fa8e;
    address internal constant SYSTEM_ACCOUNT = 0x000000000000000000000000000000000000fa7e;
    address internal constant TX_HASH_PRECOMPILE = 0x0000000000000000000000000000000000000830;
    address internal constant SPONSOR = address(0xA11CE);
    address internal constant TRACKER = address(0xBEEF);
    address internal constant ATTACKER = address(0xBAD);
    address internal constant PROPOSER = address(0xCAFE);

    Scheduler internal scheduler;
    MockRitualWallet internal wallet;
    SchedulerCoverageCaller internal caller;
    SchedulerCoveragePredicate internal predicate;

    function setUp() public {
        wallet = new MockRitualWallet(address(0));
        Scheduler implementation = new Scheduler(address(wallet), 30);
        scheduler = Scheduler(
            payable(address(
                    new ERC1967Proxy(address(implementation), abi.encodeCall(Scheduler.initialize, (address(this))))
                ))
        );
        caller = new SchedulerCoverageCaller(scheduler);
        predicate = new SchedulerCoveragePredicate();

        wallet.setScheduler(address(scheduler));
        wallet.setTransferFullScheduledFee(true);
        wallet.setBalance(address(caller), 1_000 ether);
        wallet.setBalance(SPONSOR, 1_000 ether);

        vm.prank(SPONSOR);
        wallet.approve(address(caller), type(uint256).max);

        vm.fee(scheduler.MIN_SCHEDULED_MAX_FEE_PER_GAS());
        vm.coinbase(PROPOSER);
        vm.deal(address(wallet), 10_000 ether);
        vm.deal(address(scheduler), 100 ether);
        vm.deal(PROPOSER, 0);
    }

    function _params() internal view returns (SchedulerCoverageParams memory params) {
        params = SchedulerCoverageParams({
            data: hex"01020304",
            gasLimit: 500_000,
            startBlock: uint32(block.number + 20),
            numCalls: 2,
            frequency: 4,
            ttl: 3,
            maxFeePerGas: 20 gwei,
            maxPriorityFeePerGas: 2 gwei,
            value: 0.01 ether,
            sponsor: SPONSOR
        });
    }

    function _loadCall(uint256 callId) internal view returns (SchedulerCoverageStoredCall memory stored) {
        (bool success, bytes memory result) =
            address(scheduler).staticcall(abi.encodeWithSelector(Scheduler.calls.selector, callId));
        assertTrue(success, "calls getter reverted");
        (
            stored.to,
            stored.sponsor,
            stored.startBlock,
            stored.numCalls,
            stored.frequency,
            stored.gasLimit,
            stored.ttl,
            stored.state,
            stored.maxFeePerGas,
            stored.maxPriorityFeePerGas,
            stored.value,
            stored.data
        ) =
            abi.decode(
                result,
                (address, address, uint32, uint32, uint32, uint32, uint32, CallState, uint256, uint256, uint256, bytes)
            );
    }

    function _assertStoredCall(
        uint256 callId,
        SchedulerCoverageParams memory params,
        uint32 expectedStartBlock,
        address expectedSponsor,
        address expectedPredicate,
        bool usesMinimalDefaults
    ) internal view {
        SchedulerCoverageStoredCall memory stored = _loadCall(callId);

        assertEq(stored.to, address(caller), "target");
        assertEq(stored.sponsor, expectedSponsor, "sponsor");
        assertEq(stored.startBlock, expectedStartBlock, "start block");
        assertEq(stored.numCalls, params.numCalls, "number of calls");
        assertEq(stored.frequency, params.frequency, "frequency");
        assertEq(stored.gasLimit, params.gasLimit, "gas limit");
        assertEq(stored.ttl, usesMinimalDefaults ? 0 : params.ttl, "ttl");
        assertEq(uint8(stored.state), uint8(CallState.SCHEDULED), "state");
        assertEq(stored.maxFeePerGas, usesMinimalDefaults ? block.basefee : params.maxFeePerGas, "max fee per gas");
        assertEq(
            stored.maxPriorityFeePerGas,
            usesMinimalDefaults ? 0 : params.maxPriorityFeePerGas,
            "max priority fee per gas"
        );
        assertEq(stored.value, usesMinimalDefaults ? 0 : params.value, "value");
        assertEq(stored.data, params.data, "data");
        assertEq(scheduler.callPredicates(callId), expectedPredicate, "predicate");
    }

    function _scheduleAsync(bytes32 origin) internal returns (uint256 callId) {
        SchedulerCoverageParams memory params = _params();
        params.frequency = 1;
        params.ttl = 10;
        params.value = 0;

        bytes memory emptyCalldata = new bytes(0);
        vm.mockCall(TX_HASH_PRECOMPILE, emptyCalldata, abi.encode(origin));
        callId = caller.scheduleAutoStartSelfSponsor(params);
        vm.clearMockedCalls();

        assertEq(scheduler.originHash(callId), origin, "origin hash");
    }

    function _scheduledJobId(bytes32 origin, uint256 callId, uint256 executionIndex) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(origin, callId, executionIndex));
    }

    function _assertScheduled(uint256 callId) internal view {
        assertEq(uint8(scheduler.getCallState(callId)), uint8(CallState.SCHEDULED));
    }

    function testScheduleExplicitStartAndSponsorOverload() public {
        SchedulerCoverageParams memory params = _params();
        uint256 callId = caller.scheduleExplicitStartAndSponsor(params);

        assertEq(callId, 0);
        _assertStoredCall(callId, params, params.startBlock, SPONSOR, address(0), false);
    }

    function testScheduleAutoStartSelfSponsorOverload() public {
        SchedulerCoverageParams memory params = _params();
        uint32 expectedStartBlock = uint32(block.number) + params.frequency;
        uint256 callId = caller.scheduleAutoStartSelfSponsor(params);

        assertEq(callId, 0);
        _assertStoredCall(callId, params, expectedStartBlock, address(caller), address(0), false);
    }

    function testScheduleAutoStartExplicitSponsorOverload() public {
        SchedulerCoverageParams memory params = _params();
        uint32 expectedStartBlock = uint32(block.number) + params.frequency;
        uint256 callId = caller.scheduleAutoStartExplicitSponsor(params);

        assertEq(callId, 0);
        _assertStoredCall(callId, params, expectedStartBlock, SPONSOR, address(0), false);
    }

    function testScheduleMinimalFourArgumentOverload() public {
        SchedulerCoverageParams memory params = _params();
        uint32 expectedStartBlock = uint32(block.number) + params.frequency;
        uint256 callId = caller.scheduleMinimal(params);

        assertEq(callId, 0);
        _assertStoredCall(callId, params, expectedStartBlock, address(caller), address(0), true);
    }

    function testScheduleExplicitStartSponsorAndPredicateOverload() public {
        SchedulerCoverageParams memory params = _params();
        uint256 callId = caller.scheduleExplicitStartSponsorAndPredicate(params, address(predicate));

        assertEq(callId, 0);
        _assertStoredCall(callId, params, params.startBlock, SPONSOR, address(predicate), false);
    }

    function testScheduleAutoStartSponsorAndPredicateOverload() public {
        SchedulerCoverageParams memory params = _params();
        uint32 expectedStartBlock = uint32(block.number) + params.frequency;
        uint256 callId = caller.scheduleAutoStartSponsorAndPredicate(params, address(predicate));

        assertEq(callId, 0);
        _assertStoredCall(callId, params, expectedStartBlock, SPONSOR, address(predicate), false);
    }

    function testScheduleMinimalAndPredicateOverload() public {
        SchedulerCoverageParams memory params = _params();
        uint32 expectedStartBlock = uint32(block.number) + params.frequency;
        uint256 callId = caller.scheduleMinimalAndPredicate(params, address(predicate));

        assertEq(callId, 0);
        _assertStoredCall(callId, params, expectedStartBlock, address(caller), address(predicate), true);
    }

    function testCleanupInvalidScheduledAsyncRejectsWrongJobIdOriginMismatch() public {
        bytes32 origin = keccak256("cleanup-origin-mismatch");
        uint256 callId = _scheduleAsync(origin);
        bytes32 wrongJobId = _scheduledJobId(keccak256("wrong-origin"), callId, 0);

        vm.prank(ASYNC_COMMITMENT_SYSTEM_ACCOUNT);
        vm.expectRevert(Scheduler.ScheduledAsyncOriginMismatch.selector);
        scheduler.cleanupInvalidScheduledAsync(callId, 0, wrongJobId, bytes32(uint256(1)));

        _assertScheduled(callId);
    }

    function testCleanupInvalidScheduledAsyncRejectsInvalidExecutionIndex() public {
        bytes32 origin = keccak256("cleanup-invalid-index");
        uint256 callId = _scheduleAsync(origin);
        uint256 invalidExecutionIndex = 2;
        bytes32 jobId = _scheduledJobId(origin, callId, invalidExecutionIndex);

        vm.prank(ASYNC_COMMITMENT_SYSTEM_ACCOUNT);
        vm.expectRevert(Scheduler.InvalidExecutionIndex.selector);
        scheduler.cleanupInvalidScheduledAsync(callId, invalidExecutionIndex, jobId, bytes32(uint256(2)));

        _assertScheduled(callId);
    }

    function testCleanupInvalidScheduledAsyncRejectsUnknownCallId() public {
        uint256 unknownCallId = 777;

        vm.prank(ASYNC_COMMITMENT_SYSTEM_ACCOUNT);
        vm.expectRevert(Scheduler.CallNotFound.selector);
        scheduler.cleanupInvalidScheduledAsync(unknownCallId, 0, keccak256("unknown-job"), bytes32(uint256(3)));
    }

    function testCleanupInvalidScheduledAsyncRecordsReasonAndRemovesCall() public {
        bytes32 origin = keccak256("cleanup-success");
        uint256 callId = _scheduleAsync(origin);
        bytes32 jobId = _scheduledJobId(origin, callId, 0);
        bytes32 reason = keccak256("invalid scheduled async");

        vm.prank(ASYNC_COMMITMENT_SYSTEM_ACCOUNT);
        scheduler.cleanupInvalidScheduledAsync(callId, 0, jobId, reason);

        assertEq(scheduler.scheduledAsyncCleanupReason(callId, 0), reason);
        assertEq(scheduler.originHash(callId), bytes32(0), "origin hash not cleared");
        assertEq(scheduler.executedBitmap(callId), 0, "execution bitmap not cleared");
        assertEq(scheduler.callPredicates(callId), address(0), "predicate not cleared");
        vm.expectRevert(Scheduler.CallNotFound.selector);
        scheduler.getCallState(callId);
    }

    function testMarkScheduledAsyncInFlightRejectsNonTracker() public {
        bytes32 origin = keccak256("mark-non-tracker");
        uint256 callId = _scheduleAsync(origin);
        bytes32 jobId = _scheduledJobId(origin, callId, 0);
        scheduler.setAsyncJobTracker(TRACKER);

        vm.expectRevert(Scheduler.UnauthorizedAsyncJobTracker.selector);
        scheduler.markScheduledAsyncInFlight(callId, 0, jobId);

        _assertScheduled(callId);
    }

    function testMarkScheduledAsyncInFlightRejectsAlreadyExecutedIndex() public {
        bytes32 origin = keccak256("mark-already-executed");
        uint256 callId = _scheduleAsync(origin);
        bytes32 jobId = _scheduledJobId(origin, callId, 0);
        scheduler.setAsyncJobTracker(TRACKER);

        SchedulerCoverageStoredCall memory stored = _loadCall(callId);
        vm.roll(stored.startBlock);
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 0);

        vm.prank(TRACKER);
        vm.expectRevert(Scheduler.AlreadyExecuted.selector);
        scheduler.markScheduledAsyncInFlight(callId, 0, jobId);
    }

    function testMarkScheduledAsyncInFlightRejectsExecutingCallState() public {
        bytes32 origin = keccak256("mark-executing");
        uint256 callId = _scheduleAsync(origin);
        bytes32 jobId = _scheduledJobId(origin, callId, 0);
        scheduler.setAsyncJobTracker(address(caller));
        caller.configureInFlightProbe(callId, jobId);

        SchedulerCoverageStoredCall memory stored = _loadCall(callId);
        vm.roll(stored.startBlock);
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 0);

        assertFalse(caller.probeSucceeded(), "in-flight mark unexpectedly succeeded");
        assertEq(caller.probeRevertSelector(), Scheduler.InvalidCallState.selector);
        _assertScheduled(callId);
    }

    function testSetAsyncJobTrackerRejectsNonOwnerWithExactError() public {
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, ATTACKER));
        scheduler.setAsyncJobTracker(TRACKER);
    }

    function testSetAsyncJobTrackerRejectsZeroAddress() public {
        vm.expectRevert(Scheduler.InvalidAsyncJobTracker.selector);
        scheduler.setAsyncJobTracker(address(0));
    }
}
