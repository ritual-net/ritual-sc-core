// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AsyncDelivery} from "../src/async/AsyncDelivery.sol";
import {AsyncJobTracker} from "../src/async/AsyncJobTracker.sol";
import {IRitualWallet} from "../src/wallet/IRitualWallet.sol";
import {MockRitualWallet} from "./MockRitualWallet.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract RecordingSchedulerBridge {
    uint256 public callCount;
    uint256 public lastCallId;
    uint256 public lastExecutionIndex;
    bytes32 public lastJobId;

    function markScheduledAsyncInFlight(uint256 callId, uint256 executionIndex, bytes32 jobId) external {
        callCount++;
        lastCallId = callId;
        lastExecutionIndex = executionIndex;
        lastJobId = jobId;
    }
}

contract RevertingAsyncDependency {
    error DependencyTouched();

    fallback() external payable {
        revert DependencyTouched();
    }
}

contract AsyncCoverageGapsTest is Test {
    address internal constant COMMITMENT_CALLER = 0x000000000000000000000000000000000000Fa8e;
    address internal constant ASYNC_DELIVERY_CALLER = address(0xA11D);
    address internal constant EXECUTOR = address(0xBEEF);
    address internal constant SPONSOR = address(0xCAFE);
    address internal constant NON_OWNER = address(0xBAD);
    address internal constant HTTP_CALL_PRECOMPILE = address(0x0801);
    address internal constant UNKNOWN_PRECOMPILE = address(0x9999);
    uint256 internal constant INITIAL_BALANCE = 5 ether;
    uint256 internal constant RESERVE_AMOUNT = 1 ether;

    MockRitualWallet internal wallet;
    RecordingSchedulerBridge internal bridge;
    AsyncJobTracker internal tracker;
    AsyncDelivery internal delivery;

    function setUp() public {
        vm.roll(100);
        vm.warp(1_000);

        wallet = new MockRitualWallet(address(0));
        wallet.setBalance(SPONSOR, INITIAL_BALANCE);
        bridge = new RecordingSchedulerBridge();

        AsyncJobTracker trackerImplementation = new AsyncJobTracker(ASYNC_DELIVERY_CALLER, address(wallet), address(0));
        tracker = AsyncJobTracker(
            address(
                new ERC1967Proxy(
                    address(trackerImplementation), abi.encodeCall(AsyncJobTracker.initialize, (address(this)))
                )
            )
        );

        RevertingAsyncDependency dependency = new RevertingAsyncDependency();
        AsyncDelivery deliveryImplementation = new AsyncDelivery(address(dependency), address(dependency));
        delivery = AsyncDelivery(
            payable(address(
                    new ERC1967Proxy(
                        address(deliveryImplementation), abi.encodeCall(AsyncDelivery.initialize, (address(this)))
                    )
                ))
        );
    }

    function testAddScheduledRejectsSchedulerNotSet() public {
        bytes32 jobId = keccak256("scheduled-no-scheduler");

        _expectScheduledRevert(
            _job(jobId), _schedule(jobId), abi.encodeWithSignature("Error(string)", "scheduler not set")
        );
        _assertNoAdmission(jobId);
    }

    function testAddScheduledRejectsEmptyScheduledOrigin() public {
        tracker.setScheduler(address(bridge));
        bytes32 jobId = keccak256("scheduled-empty-origin");

        _expectScheduledRevert(
            _job(jobId), _schedule(bytes32(0)), abi.encodeWithSignature("Error(string)", "empty scheduled origin")
        );
        _assertNoAdmission(jobId);
    }

    function testAddScheduledRejectsJobOriginMismatch() public {
        tracker.setScheduler(address(bridge));
        bytes32 jobId = keccak256("scheduled-mismatch");

        _expectScheduledRevert(
            _job(jobId),
            _schedule(keccak256("different-job")),
            abi.encodeWithSignature("Error(string)", "scheduled job mismatch")
        );
        _assertNoAdmission(jobId);
    }

    function testAddScheduledRejectsNonzeroTxOrigin() public {
        tracker.setScheduler(address(bridge));
        bytes32 jobId = keccak256("scheduled-tx-origin");
        AsyncJobTracker.AddJobInput memory job = _job(jobId);
        job.txOrigin = address(0x1234);

        _expectScheduledRevert(
            job, _schedule(jobId), abi.encodeWithSignature("Error(string)", "scheduled txOrigin set")
        );
        _assertNoAdmission(jobId);
    }

    function testAddScheduledRejectsNonCommitmentCaller() public {
        tracker.setScheduler(address(bridge));
        bytes32 jobId = keccak256("scheduled-unauthorized");

        vm.expectRevert(abi.encodeWithSignature("Error(string)", "only commitment caller"));
        tracker.addScheduledJobAndReserve(_job(jobId), _reserve(RESERVE_AMOUNT), _schedule(jobId));

        _assertNoAdmission(jobId);
        assertEq(bridge.callCount(), 0);
    }

    function testAddScheduledStoresReservationAndHandsOffToScheduler() public {
        tracker.setScheduler(address(bridge));
        bytes32 jobId = keccak256("scheduled-handoff");
        AsyncJobTracker.ScheduledObligationRef memory schedule =
            AsyncJobTracker.ScheduledObligationRef({callId: 42, executionIndex: 7, scheduledOriginHash: jobId});

        vm.prank(COMMITMENT_CALLER);
        tracker.addScheduledJobAndReserve(_job(jobId), _reserve(RESERVE_AMOUNT), schedule);

        assertEq(tracker.totalPending(), 1);
        assertEq(tracker.getJobCount(EXECUTOR), 1);
        assertEq(wallet.escrows(jobId).sponsor, SPONSOR);
        assertEq(wallet.escrows(jobId).reserved, RESERVE_AMOUNT);
        assertEq(bridge.callCount(), 1);
        assertEq(bridge.lastCallId(), schedule.callId);
        assertEq(bridge.lastExecutionIndex(), schedule.executionIndex);
        assertEq(bridge.lastJobId(), jobId);
    }

    function testAdmissionRejectsInputOver10KBWithoutReservation() public {
        bytes32 jobId = keccak256("oversized-input");
        AsyncJobTracker.AddJobInput memory job = _job(jobId);
        job.input = new bytes(tracker.MAX_INPUT_SIZE() + 1);

        _expectAdmissionRevert(job, abi.encodeWithSignature("Error(string)", ">10KB input"));
        _assertNoAdmission(jobId);
    }

    function testAdmissionRejectsOrigRlpOver10KBWithoutReservation() public {
        bytes32 jobId = keccak256("oversized-rlp");
        AsyncJobTracker.AddJobInput memory job = _job(jobId);
        job.origRlp = new bytes(tracker.MAX_INPUT_SIZE() + 1);

        _expectAdmissionRevert(job, abi.encodeWithSignature("Error(string)", ">10KB rlp"));
        _assertNoAdmission(jobId);
    }

    function testAdmissionRejectsZeroTtlWithoutReservation() public {
        bytes32 jobId = keccak256("zero-ttl");
        AsyncJobTracker.AddJobInput memory job = _job(jobId);
        job.ttl = 0;

        _expectAdmissionRevert(job, abi.encodeWithSignature("Error(string)", "ttl out of range"));
        _assertNoAdmission(jobId);
    }

    function testAdmissionRejectsTtlAboveMaxWithoutReservation() public {
        bytes32 jobId = keccak256("ttl-above-max");
        AsyncJobTracker.AddJobInput memory job = _job(jobId);
        job.ttl = tracker.MAX_TTL_BLOCKS() + 1;

        _expectAdmissionRevert(job, abi.encodeWithSignature("Error(string)", "ttl out of range"));
        _assertNoAdmission(jobId);
    }

    function testAdmissionRejectsActiveDuplicateAndPreservesExistingReservation() public {
        bytes32 jobId = keccak256("active-duplicate");
        _admit(_job(jobId), RESERVE_AMOUNT);

        uint256 balanceBefore = wallet.availableBalance(SPONSOR);
        uint256 reservedBefore = wallet.reservedBalance(SPONSOR);
        IRitualWallet.Escrow memory escrowBefore = wallet.escrows(jobId);

        _expectAdmissionRevert(_job(jobId), abi.encodeWithSignature("Error(string)", "active job exists"));

        assertEq(tracker.totalPending(), 1);
        assertEq(tracker.getJobCount(EXECUTOR), 1);
        assertEq(wallet.availableBalance(SPONSOR), balanceBefore);
        assertEq(wallet.reservedBalance(SPONSOR), reservedBefore);
        assertEq(wallet.escrows(jobId).sponsor, escrowBefore.sponsor);
        assertEq(wallet.escrows(jobId).reserved, escrowBefore.reserved);
        assertEq(wallet.escrows(jobId).expiryBlock, escrowBefore.expiryBlock);
    }

    function testAdmissionRejectsUnknownPrecompileWithInputWithoutReservation() public {
        bytes32 jobId = keccak256("unknown-precompile");
        AsyncJobTracker.AddJobInput memory job = _job(jobId);
        job.precomp = UNKNOWN_PRECOMPILE;
        job.input = hex"01";

        _expectAdmissionRevert(job, abi.encodeWithSignature("Error(string)", "unknown precompile"));
        _assertNoAdmission(jobId);
    }

    function testSetSchedulerRejectsNonOwnerWithExactOwnableError() public {
        assertEq(tracker.scheduler(), address(0));

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, NON_OWNER));
        vm.prank(NON_OWNER);
        tracker.setScheduler(address(bridge));

        assertEq(tracker.scheduler(), address(0));
    }

    function testSettleRejectsNonSystemCallerBeforeDependencies() public {
        vm.expectRevert(AsyncDelivery.OnlySettlementSystem.selector);
        delivery.settle(keccak256("unauthorized-settle"), 1, 2, 3, hex"01");
    }

    function testDeliverRejectsNonSystemCallerBeforeDependencies() public {
        vm.expectRevert(AsyncDelivery.OnlySettlementSystem.selector);
        delivery.deliver(
            keccak256("unauthorized-deliver"), 1, 2, 3, 4, address(0x1234), bytes4(0x11223344), hex"01", hex"02"
        );
    }

    function testRemoveJobRejectsNonAsyncDeliveryCaller() public {
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "only AsyncDelivery"));
        tracker.removeJob(keccak256("unauthorized-remove"), hex"01", true);

        assertEq(tracker.totalPending(), 0);
    }

    function testMarkPhase1SettledRejectsNonAsyncDeliveryCaller() public {
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "only AsyncDelivery"));
        tracker.markPhase1Settled(keccak256("unauthorized-phase-one"), hex"01");

        assertEq(tracker.totalPending(), 0);
    }

    function testMarkDeliveredRejectsNonAsyncDeliveryCaller() public {
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "only AsyncDelivery"));
        tracker.markDelivered(keccak256("unauthorized-delivery"), hex"01", true);

        assertEq(tracker.totalPending(), 0);
    }

    function _job(bytes32 jobId) internal view returns (AsyncJobTracker.AddJobInput memory) {
        return AsyncJobTracker.AddJobInput({
            exec: EXECUTOR,
            id: jobId,
            precomp: HTTP_CALL_PRECOMPILE,
            input: hex"010203",
            ttl: 60,
            prevHash: bytes32(uint256(1)),
            prevNum: block.number - 1,
            prevTime: block.timestamp - 1,
            caller: SPONSOR,
            commitVal: address(0xC0FFEE),
            origHash: keccak256(abi.encodePacked("origin", jobId)),
            origRlp: hex"DEADBEEF",
            txOrigin: address(0)
        });
    }

    function _reserve(uint256 amount) internal pure returns (AsyncJobTracker.ReserveConfig memory) {
        return
            AsyncJobTracker.ReserveConfig({sponsor: SPONSOR, reserveAmount: amount, expiredEscrows: new bytes32[](0)});
    }

    function _schedule(bytes32 scheduledOriginHash)
        internal
        pure
        returns (AsyncJobTracker.ScheduledObligationRef memory)
    {
        return AsyncJobTracker.ScheduledObligationRef({
            callId: 42, executionIndex: 7, scheduledOriginHash: scheduledOriginHash
        });
    }

    function _admit(AsyncJobTracker.AddJobInput memory job, uint256 amount) internal {
        vm.prank(COMMITMENT_CALLER);
        tracker.addJobAndReserve(job, _reserve(amount));
    }

    function _expectAdmissionRevert(AsyncJobTracker.AddJobInput memory job, bytes memory expected) internal {
        vm.expectRevert(expected);
        vm.prank(COMMITMENT_CALLER);
        tracker.addJobAndReserve(job, _reserve(RESERVE_AMOUNT));
    }

    function _expectScheduledRevert(
        AsyncJobTracker.AddJobInput memory job,
        AsyncJobTracker.ScheduledObligationRef memory schedule,
        bytes memory expected
    ) internal {
        vm.expectRevert(expected);
        vm.prank(COMMITMENT_CALLER);
        tracker.addScheduledJobAndReserve(job, _reserve(RESERVE_AMOUNT), schedule);
    }

    function _assertNoAdmission(bytes32 jobId) internal {
        assertEq(tracker.totalPending(), 0);
        assertEq(tracker.getJobCount(EXECUTOR), 0);
        assertEq(wallet.availableBalance(SPONSOR), INITIAL_BALANCE);
        assertEq(wallet.reservedBalance(SPONSOR), 0);
        assertEq(wallet.escrows(jobId).sponsor, address(0));
        assertEq(wallet.escrows(jobId).reserved, 0);

        vm.expectRevert(abi.encodeWithSignature("Error(string)", "not found"));
        tracker.getJob(jobId);
    }
}
