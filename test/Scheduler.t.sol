// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Scheduler, Call, CallState} from "../src/scheduler/Scheduler.sol";
import {IScheduledPredicate} from "../src/scheduler/interfaces/IScheduledPredicate.sol";
import {MockRitualWallet} from "./MockRitualWallet.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title MockCallee
/// @notice Mock contract for testing scheduled calls
contract MockCallee {
    uint256 public callCount;
    bytes public lastCallData;
    uint256 public lastValue;
    uint256 public lastExecutionIndex;
    bool public shouldRevert;

    event Called(bytes data, uint256 value);
    event Received(uint256 amount);
    event ExecutionIndexReceived(uint256 executionIndex, uint256 param);

    // Add receive function to accept ETH refunds
    receive() external payable {
        emit Received(msg.value);
    }

    // Add fallback function to accept ETH refunds with calldata
    fallback() external payable {
        emit Received(msg.value);
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    /// @notice Scheduler callback entrypoint (Option D). payload is unused for this mock.
    function onScheduledExecution(uint256 executionIndex, bytes calldata) external payable {
        if (shouldRevert) {
            revert("MockCallee: reverted");
        }
        callCount++;
        lastCallData = msg.data;
        lastValue = msg.value;
        lastExecutionIndex = executionIndex;
        emit Called(msg.data, msg.value);
        emit ExecutionIndexReceived(executionIndex, 0);
    }

    function schedule(
        Scheduler scheduler,
        uint32 gas,
        uint32 numCalls,
        uint32 frequency,
        uint32 ttl,
        uint256 maxFeePerGas,
        uint256 maxPriorityFeePerGas,
        uint256 value
    ) external returns (uint256) {
        // Empty opaque payload; the Scheduler delivers the execution index explicitly.
        return scheduler.schedule("", gas, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, value);
    }

    function scheduleAt(
        Scheduler scheduler,
        uint32 gas,
        uint32 startBlock,
        uint32 numCalls,
        uint32 frequency,
        uint32 ttl,
        uint256 maxFeePerGas,
        uint256 maxPriorityFeePerGas,
        uint256 value
    ) external returns (uint256) {
        return scheduler.schedule(
            "", gas, startBlock, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, value, address(this)
        );
    }
}

contract RejectingSchedulerProposer {
    receive() external payable {
        revert("reject payment");
    }
}

contract ReentrantCancelCallee {
    Scheduler public scheduler;
    uint256 public callCount;
    uint256 public lastExecutionIndex;

    constructor(Scheduler _scheduler) {
        scheduler = _scheduler;
    }

    function scheduleNoop(
        uint32 gas,
        uint32 numCalls,
        uint32 frequency,
        uint32 ttl,
        uint256 maxFeePerGas,
        uint256 maxPriorityFeePerGas
    ) external returns (uint256) {
        // mode 0 = noop; no target id needed.
        return scheduler.schedule(
            abi.encode(uint8(0), uint256(0)), gas, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, 0
        );
    }

    function scheduleCancelDuringExecute(
        uint256 cancelCallId,
        uint32 gas,
        uint32 numCalls,
        uint32 frequency,
        uint32 ttl,
        uint256 maxFeePerGas,
        uint256 maxPriorityFeePerGas
    ) external returns (uint256) {
        // mode 1 = cancel target call id during execution.
        return scheduler.schedule(
            abi.encode(uint8(1), cancelCallId), gas, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, 0
        );
    }

    function scheduleCleanupDuringExecute(
        uint256 cleanupCallId,
        uint32 gas,
        uint32 numCalls,
        uint32 frequency,
        uint32 ttl,
        uint256 maxFeePerGas,
        uint256 maxPriorityFeePerGas
    ) external returns (uint256) {
        // mode 2 = cleanup target call id during execution.
        return scheduler.schedule(
            abi.encode(uint8(2), cleanupCallId), gas, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, 0
        );
    }

    /// @notice Scheduler callback entrypoint (Option D). Dispatches on the mode tag in payload.
    function onScheduledExecution(uint256 executionIndex, bytes calldata payload) external payable {
        (uint8 mode, uint256 target) = abi.decode(payload, (uint8, uint256));
        if (mode == 0) {
            lastExecutionIndex = executionIndex;
        } else if (mode == 1) {
            callCount++;
            lastExecutionIndex = executionIndex;
            scheduler.cancel(target);
        } else {
            callCount++;
            lastExecutionIndex = executionIndex;
            uint256[] memory ids = new uint256[](1);
            ids[0] = target;
            scheduler.cleanupExpiredCalls(ids);
        }
    }
}

/// @notice Re-enters Scheduler during execution to move the active call's slot.
contract ReentrantSlotMover {
    Scheduler public scheduler;
    uint256 public retiredCallId;
    uint256 public activeCallId;
    uint256 public successorCallId;
    uint256 public wakeCount;
    bool public hasRetiredCall;

    uint32 internal gasLimit;
    uint32 internal numCalls;
    uint32 internal frequency;
    uint32 internal ttl;
    uint256 internal maxFeePerGas;
    uint256 internal maxPriorityFeePerGas;

    constructor(Scheduler _scheduler) {
        scheduler = _scheduler;
    }

    function arm(
        uint32 _gasLimit,
        uint32 _numCalls,
        uint32 _frequency,
        uint32 _ttl,
        uint256 _maxFeePerGas,
        uint256 _maxPriorityFeePerGas
    ) external returns (uint256 retired, uint256 active) {
        gasLimit = _gasLimit;
        numCalls = _numCalls;
        frequency = _frequency;
        ttl = _ttl;
        maxFeePerGas = _maxFeePerGas;
        maxPriorityFeePerGas = _maxPriorityFeePerGas;

        retired = scheduler.schedule("", gasLimit, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, 0);
        active = scheduler.schedule("", gasLimit, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, 0);

        retiredCallId = retired;
        activeCallId = active;
        hasRetiredCall = true;
    }

    /// @notice Scheduler callback entrypoint (Option D). payload is unused.
    function onScheduledExecution(uint256, bytes calldata) external payable {
        wakeCount++;

        if (hasRetiredCall) {
            uint256 retired = retiredCallId;
            hasRetiredCall = false;
            scheduler.cancel(retired);
        }

        successorCallId =
            scheduler.schedule("", gasLimit, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, 0);
    }
}

/// @notice Records the exact payload and execution index delivered by the Scheduler.
/// @dev Used to prove the Scheduler passes scheduling data through verbatim (Option D non-mutation).
contract PayloadEchoCallee {
    bytes public lastPayload;
    uint256 public lastExecutionIndex;
    uint256 public callCount;

    function onScheduledExecution(uint256 executionIndex, bytes calldata payload) external payable {
        callCount++;
        lastExecutionIndex = executionIndex;
        lastPayload = payload;
    }

    function scheduleWith(
        Scheduler scheduler,
        bytes memory payload,
        uint32 gas,
        uint32 numCalls,
        uint32 frequency,
        uint32 ttl,
        uint256 maxFeePerGas,
        uint256 maxPriorityFeePerGas
    ) external returns (uint256) {
        return scheduler.schedule(payload, gas, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, 0);
    }
}

contract MutableScheduledPredicate is IScheduledPredicate {
    bool public shouldAllow = true;
    bool public shouldRevert;

    function setShouldAllow(bool value) external {
        shouldAllow = value;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function shouldExecute(address, uint256, uint256) external view override returns (bool) {
        if (shouldRevert) {
            revert("predicate failed");
        }
        return shouldAllow;
    }
}

/// @title SchedulerTest
/// @notice Test contract for Scheduler
contract SchedulerTest is Test {
    Scheduler public scheduler;
    MockCallee public callee;
    MockRitualWallet public wallet;
    address public constant SYSTEM_ACCOUNT = 0x000000000000000000000000000000000000fa7e;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        wallet = new MockRitualWallet(address(0));
        scheduler = new Scheduler(address(wallet), 30);
        wallet.setScheduler(address(scheduler)); // Set correct scheduler address
        wallet.setTransferFullScheduledFee(true);
        callee = new MockCallee();

        vm.deal(address(this), 100 ether);
        vm.deal(address(callee), 100 ether);
        vm.deal(address(wallet), 1000 ether);
        vm.deal(address(scheduler), 100 ether); // Give Scheduler ETH for refunds

        // Fund wallet for callee (msg.sender) and test contract (msg.sender)
        wallet.setBalance(address(callee), 1000 ether);
        wallet.setBalance(address(this), 1000 ether);
        // Also fund the default sender address used by Foundry
        wallet.setBalance(0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38, 1000 ether);
    }

    function _autoResidencyFee(uint32 numCalls, uint32 frequency, uint32 ttl) internal view returns (uint256) {
        return scheduler.SCHEDULED_RESIDENCY_FEE_PER_BLOCK() * ((uint256(numCalls) * frequency) + ttl);
    }

    function testSchedule() public {
        uint32 gas = 100_000;
        uint32 numCalls = 100;
        uint32 frequency = 10;
        uint32 ttl = 5;
        uint256 maxFeePerGas = 20 gwei;
        uint256 maxPriorityFeePerGas = 2 gwei;
        uint256 value = 0.1 ether;

        // Schedule call (uses auto-calculated startBlock = block.number + frequency)
        uint256 callId =
            callee.schedule(scheduler, gas, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, value);

        // Verify call was scheduled
        assertEq(callId, 0);

        // Verify call details
        (
            address to,
            address caller,
            uint32 startBlock,
            uint32 storedNumCalls,
            uint32 freq,
            uint32 gasLimit,
            uint32 ttlValue,
            CallState state,
            uint256 maxFee,
            uint256 maxPriorityFee,
            uint256 val,
        ) = scheduler.calls(callId);
        assertEq(to, address(callee));
        // Skip caller assertion - msg.sender varies in test environment
        // startBlock is auto-calculated as block.number + frequency
        assertEq(startBlock, uint32(block.number) + frequency);
        assertEq(storedNumCalls, numCalls);
        assertEq(freq, frequency);
        assertEq(gasLimit, gas);
        assertEq(ttlValue, ttl);
        assertEq(maxFee, maxFeePerGas);
        assertEq(maxPriorityFee, maxPriorityFeePerGas);
        assertEq(val, value);
    }

    function _executeAt(uint256 callId, uint32 frequency, uint256 index) internal {
        vm.roll(block.number + uint256(frequency) * (index + 1));
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, index);
    }

    function testExecuteRejectsTooEarlyExecution() public {
        uint32 frequency = 10;
        uint256 callId = callee.schedule(scheduler, 500_000, 1, frequency, 5, 20 gwei, 2 gwei, 0);
        (,, uint32 startBlock,,,,,,,,,) = scheduler.calls(callId);

        vm.roll(uint256(startBlock) - 1);
        vm.expectRevert(abi.encodeWithSelector(Scheduler.ExecutionNotDue.selector, uint256(startBlock), block.number));
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 0);

        assertEq(callee.callCount(), 0);
        assertFalse(scheduler.isExecuted(callId, 0));
    }

    function testExecuteRejectsPredicateFalse() public {
        MutableScheduledPredicate predicate = new MutableScheduledPredicate();
        predicate.setShouldAllow(false);

        uint32 frequency = 10;
        uint32 startBlock = uint32(block.number) + frequency;
        uint256 callId = scheduler.schedule(
            "", 500_000, startBlock, 1, frequency, 5, 20 gwei, 2 gwei, 0, address(this), address(predicate)
        );

        vm.roll(startBlock);
        vm.expectRevert(
            abi.encodeWithSelector(Scheduler.PredicateReturnedFalse.selector, callId, uint256(0), address(predicate))
        );
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 0);

        assertEq(callee.callCount(), 0);
        assertFalse(scheduler.isExecuted(callId, 0));
    }

    function testExecuteRejectsPredicateRevert() public {
        MutableScheduledPredicate predicate = new MutableScheduledPredicate();

        uint32 frequency = 10;
        uint32 startBlock = uint32(block.number) + frequency;
        uint256 callId = scheduler.schedule(
            "", 500_000, startBlock, 1, frequency, 5, 20 gwei, 2 gwei, 0, address(this), address(predicate)
        );
        predicate.setShouldRevert(true);

        vm.roll(startBlock);
        vm.expectRevert(
            abi.encodeWithSelector(Scheduler.PredicateCheckFailed.selector, callId, uint256(0), address(predicate))
        );
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 0);

        assertEq(callee.callCount(), 0);
        assertFalse(scheduler.isExecuted(callId, 0));
    }

    /// @notice Option D: the Scheduler must deliver the scheduling data to the target verbatim, with the
    ///         execution index supplied as a separate argument. This payload is the exact shape the old
    ///         in-place injection corrupted (a 36-byte selector + leading word), so an unmodified payload
    ///         proves the Scheduler no longer mutates caller calldata.
    function testSchedulerPassesPayloadVerbatim() public {
        PayloadEchoCallee echoCallee = new PayloadEchoCallee();
        wallet.setBalance(address(echoCallee), 10 ether);

        uint32 gas = 200_000;
        uint32 frequency = 10;
        bytes memory payload = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(42));

        uint256 callId = echoCallee.scheduleWith(scheduler, payload, gas, 3, frequency, 5, 20 gwei, 2 gwei);

        _executeAt(callId, frequency, 2);

        assertEq(echoCallee.callCount(), 1, "callback not invoked");
        assertEq(echoCallee.lastExecutionIndex(), 2, "execution index not delivered as explicit argument");
        assertEq(echoCallee.lastPayload(), payload, "payload was mutated; scheduler must pass it verbatim");
    }

    /// @notice Option D removes the >=36-byte calldata constraint: an empty payload is valid and executes.
    function testSchedulerExecutesEmptyPayload() public {
        PayloadEchoCallee echoCallee = new PayloadEchoCallee();
        wallet.setBalance(address(echoCallee), 10 ether);

        uint32 frequency = 10;
        uint256 callId = echoCallee.scheduleWith(scheduler, "", 200_000, 1, frequency, 5, 20 gwei, 2 gwei);

        _executeAt(callId, frequency, 0);

        assertEq(echoCallee.callCount(), 1, "empty-payload callback not invoked");
        assertEq(echoCallee.lastExecutionIndex(), 0);
        assertEq(echoCallee.lastPayload().length, 0, "empty payload should round-trip empty");
    }

    /// @notice A TTL-expired execution index must be recorded as consumed so the privileged execution
    ///         path cannot resubmit it indefinitely. With numCalls = 2, index 0 expires while index 1
    ///         stays valid: the first attempt at index 0 is skipped and marked, a second attempt at
    ///         index 0 reverts AlreadyExecuted, and index 1 still executes and completes the call.
    function testSkippedTTLExpiredIndexIsConsumed() public {
        uint32 gas = 500_000;
        uint32 numCalls = 2;
        uint32 frequency = 10;
        uint32 ttl = 5;
        uint256 maxFeePerGas = 20 gwei;
        uint256 maxPriorityFeePerGas = 2 gwei;

        uint256 callId =
            callee.schedule(scheduler, gas, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, 0);

        (,, uint32 startBlock,,,,,,,,,) = scheduler.calls(callId);

        // Move just past index 0's TTL window. The overall call (last index at startBlock + frequency,
        // TTL window closing at startBlock + frequency + ttl) is still live and index 1 stays valid.
        vm.roll(uint256(startBlock) + ttl + 1);

        // First attempt at index 0: skipped as TTL-expired and recorded as consumed.
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 0);
        assertEq(callee.callCount(), 0, "TTL-expired index must not execute");
        assertTrue(scheduler.isExecuted(callId, 0), "skipped TTL-expired index must be marked consumed");
        assertEq(uint8(scheduler.getCallState(callId)), uint8(CallState.SCHEDULED), "call must stay scheduled");

        // Second attempt at the same expired index must revert instead of re-skipping.
        vm.prank(SYSTEM_ACCOUNT);
        vm.expectRevert(Scheduler.AlreadyExecuted.selector);
        scheduler.execute(callId, 0);

        // Index 1 is still within its TTL window and must execute, completing the call.
        vm.roll(uint256(startBlock) + frequency);
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 1);
        assertEq(callee.callCount(), 1, "later valid index should still execute");
        // Completing the last index tears the call down (RAII), clearing the bitmap including the
        // previously skipped index 0.
        assertEq(scheduler.executedBitmap(callId), 0, "bitmap must be cleared once the call completes");
    }

    /// @notice Zellic 3.8: mirror of testSkippedTTLExpiredIndexIsConsumed with the acts swapped.
    ///         There the skip lands first and the real execution of index 1 completes the call via
    ///         _handlePostExecution; here index 1 executes first (out of order) and the TTL skip of
    ///         index 0 fills the FINAL outstanding bit. The skip must then perform the same terminal
    ///         transition, not leave the call SCHEDULED with a full bitmap where every index rejects
    ///         as AlreadyExecuted. In production this ordering arises when the executor is down for
    ///         all of index 0's window and recovers in time for index 1's.
    function testFinalTTLSkipCompletesCall() public {
        uint32 gas = 500_000;
        uint32 numCalls = 2;
        uint32 frequency = 10;
        uint32 ttl = 5;
        uint256 maxFeePerGas = 20 gwei;
        uint256 maxPriorityFeePerGas = 2 gwei;

        uint256 callId =
            callee.schedule(scheduler, gas, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, 0);

        (,, uint32 startBlock,,,,,,,,,) = scheduler.calls(callId);

        // At startBlock + frequency all three window conditions hold at once: index 0's TTL
        // window (closes startBlock + ttl) has lapsed, index 1's window is open, and the
        // overall expiry (startBlock + frequency + ttl) has not passed.
        vm.roll(uint256(startBlock) + frequency);

        // Index 1 executes for real, out of order. Bit 1 set; call stays SCHEDULED (bit 0 unset).
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 1);
        assertEq(callee.callCount(), 1, "index 1 must execute");
        assertEq(uint8(scheduler.getCallState(callId)), uint8(CallState.SCHEDULED), "call must stay scheduled");

        // The TTL skip of index 0 fills the final bit. Nothing executes and nothing is charged:
        // the skip path returns before any fee arithmetic, so completion records zero gas paid.
        uint256 sponsorBalanceBefore = wallet.availableBalance(address(callee));
        vm.expectEmit(true, true, false, true);
        emit Scheduler.CallStateChanged(callId, address(callee), CallState.SCHEDULED, CallState.COMPLETED);
        vm.expectEmit(true, true, true, true);
        emit Scheduler.CallCompleted(callId, address(callee), address(callee), startBlock, numCalls, frequency);
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 0);

        // Terminal teardown: record gone, bitmap cleared, no extra callback, no charge.
        vm.expectRevert(Scheduler.CallNotFound.selector);
        scheduler.getCallState(callId);
        assertEq(scheduler.executedBitmap(callId), 0, "bitmap must be cleared on skip-completion");
        assertEq(callee.callCount(), 1, "TTL-expired index must not execute");
        assertEq(wallet.availableBalance(address(callee)), sponsorBalanceBefore, "skip-completion must charge nothing");
    }

    /// @notice Zellic 3.8, ordering variant: with numCalls = 3, the MIDDLE index is the last one
    ///         consumed, via a skip. Guards against the completion check assuming the final bit
    ///         belongs to index 0 or to the positionally last index.
    function testFinalTTLSkipCompletesCallMiddleIndexLast() public {
        uint32 gas = 500_000;
        uint32 numCalls = 3;
        uint32 frequency = 10;
        uint32 ttl = 5;
        uint256 maxFeePerGas = 20 gwei;
        uint256 maxPriorityFeePerGas = 2 gwei;

        uint256 callId =
            callee.schedule(scheduler, gas, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, 0);

        (,, uint32 startBlock,,,,,,,,,) = scheduler.calls(callId);

        // Index 0 executes inside its own window.
        vm.roll(uint256(startBlock));
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 0);

        // At startBlock + 2*frequency: index 1's window (closes startBlock + frequency + ttl) has
        // lapsed, index 2's is open, overall expiry (startBlock + 2*frequency + ttl) has not passed.
        vm.roll(uint256(startBlock) + 2 * uint256(frequency));

        // Index 2 executes for real, out of order.
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 2);
        assertEq(callee.callCount(), 2, "indices 0 and 2 must execute");
        assertEq(uint8(scheduler.getCallState(callId)), uint8(CallState.SCHEDULED), "call must stay scheduled");

        // The TTL skip of MIDDLE index 1 fills the final bit and must complete the call.
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 1);

        vm.expectRevert(Scheduler.CallNotFound.selector);
        scheduler.getCallState(callId);
        assertEq(scheduler.executedBitmap(callId), 0, "bitmap must be cleared on skip-completion");
        assertEq(callee.callCount(), 2, "TTL-expired middle index must not execute");
    }

    /// @notice Sponsor refunds are protocol accounting. A reverting RITUAL_WALLET.refundGas must revert
    ///         execute(), so the scheduled transaction receipt fails and Reth rejects the block.
    function testRefundFailureRevertsScheduledExecution() public {
        uint32 gas = 500_000;
        uint32 numCalls = 1;
        uint32 frequency = 10;
        uint32 ttl = 5;
        uint256 maxFeePerGas = 20 gwei;
        uint256 maxPriorityFeePerGas = 2 gwei;

        uint256 callId =
            callee.schedule(scheduler, gas, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, 0);

        // Force the wallet to reject the refund. feesPaid is reserved at maxFeePerGas/gasLimit, while the
        // actual fee is based on gasUsed, so a refund is always due and refundGas will be invoked.
        wallet.setFailRefund(true);

        vm.expectRevert(bytes("refund failed"));
        _executeAt(callId, frequency, 0);

        assertEq(callee.callCount(), 0, "reverted scheduled tx must roll back callback side effects");
        assertEq(uint8(scheduler.getCallState(callId)), uint8(CallState.SCHEDULED));
        assertFalse(scheduler.isExecuted(callId, 0), "reverted scheduled tx must not consume the index");
    }

    function testScheduleRequiresResidencyFeeAndOneExecution() public {
        uint32 gas = 100_000;
        uint32 numCalls = 100;
        uint32 frequency = 10;
        uint32 ttl = 5;
        uint256 maxFeePerGas = 20 gwei;
        uint256 maxPriorityFeePerGas = 2 gwei;
        uint256 value = 0.1 ether;
        uint256 maxExecutionCost = (maxFeePerGas * gas) + value;
        uint256 residencyFee = _autoResidencyFee(numCalls, frequency, ttl);

        wallet.setBalance(address(callee), maxExecutionCost + residencyFee - 1);
        vm.expectRevert(Scheduler.InsufficientWalletFunds.selector);
        callee.schedule(scheduler, gas, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, value);

        wallet.setBalance(address(callee), maxExecutionCost + residencyFee);
        uint256 callId =
            callee.schedule(scheduler, gas, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, value);
        assertEq(callId, 0);
    }

    function testScheduleChargesResidencyLinearlyAndDoesNotRefundOnCancel() public {
        uint32 gas = 100_000;
        uint256 maxFeePerGas = scheduler.MIN_SCHEDULED_MAX_FEE_PER_GAS();
        uint256 balanceBefore = wallet.availableBalance(address(callee));

        uint32 nearFrequency = 10;
        uint32 ttl = 5;
        uint256 nearCallId = callee.schedule(scheduler, gas, 1, nearFrequency, ttl, maxFeePerGas, 0, 0);
        uint256 nearFee = balanceBefore - wallet.availableBalance(address(callee));
        assertEq(nearFee, _autoResidencyFee(1, nearFrequency, ttl));

        uint32 farStartBlock = uint32(block.number + 1500);
        uint256 beforeFar = wallet.availableBalance(address(callee));
        uint256 farCallId = callee.scheduleAt(scheduler, gas, farStartBlock, 1, 1, 0, maxFeePerGas, 0, 0);
        uint256 farFee = beforeFar - wallet.availableBalance(address(callee));
        assertEq(farFee, scheduler.SCHEDULED_RESIDENCY_FEE_PER_BLOCK() * 1500);
        assertEq(farFee, nearFee * 100);

        vm.prank(address(callee));
        scheduler.cancel(farCallId);
        assertEq(wallet.availableBalance(address(callee)), beforeFar - farFee);

        vm.prank(address(callee));
        scheduler.cancel(nearCallId);
    }

    function testSchedulePaysResidencyFeeToBlockProposer() public {
        address payable proposer = payable(address(0xBEEF));
        vm.coinbase(proposer);
        vm.deal(proposer, 0);

        uint32 frequency = 10;
        uint32 ttl = 5;
        uint256 expectedFee = _autoResidencyFee(1, frequency, ttl);
        callee.schedule(scheduler, 100_000, 1, frequency, ttl, scheduler.MIN_SCHEDULED_MAX_FEE_PER_GAS(), 0, 0);

        assertEq(proposer.balance, expectedFee);
        assertEq(wallet.availableBalance(proposer), 0);
    }

    function testScheduleRevertsWhenContractProposerRejectsEth() public {
        RejectingSchedulerProposer proposer = new RejectingSchedulerProposer();
        vm.coinbase(address(proposer));
        uint256 sponsorBalanceBefore = wallet.availableBalance(address(callee));
        uint256 maxFeePerGas = scheduler.MIN_SCHEDULED_MAX_FEE_PER_GAS();
        uint32 frequency = 10;
        uint32 ttl = 5;

        vm.expectRevert(Scheduler.ProposerPaymentFailed.selector);
        callee.schedule(scheduler, 100_000, 1, frequency, ttl, maxFeePerGas, 0, 0);

        assertEq(scheduler.id(), 0);
        assertEq(address(proposer).balance, 0);
        assertEq(wallet.availableBalance(address(proposer)), 0);
        assertEq(wallet.availableBalance(address(callee)), sponsorBalanceBefore);
    }

    function testPaidResidencyPreventsReusingOneExecutionBalanceAcrossSchedules() public {
        uint32 gas = 100_000;
        uint32 frequency = 10_000;
        uint256 maxFeePerGas = scheduler.MIN_SCHEDULED_MAX_FEE_PER_GAS();
        uint256 maxExecutionCost = maxFeePerGas * gas;
        uint256 residencyFee = _autoResidencyFee(1, frequency, 0);
        wallet.setBalance(address(callee), maxExecutionCost + residencyFee);

        callee.schedule(scheduler, gas, 1, frequency, 0, maxFeePerGas, 0, 0);
        assertEq(wallet.availableBalance(address(callee)), maxExecutionCost);

        vm.expectRevert(Scheduler.InsufficientWalletFunds.selector);
        callee.schedule(scheduler, gas, 1, frequency, 0, maxFeePerGas, 0, 0);
        assertEq(wallet.availableBalance(address(callee)), maxExecutionCost);
    }

    function testMultiCallScheduleEvictsOnLaterMissedJitPayment() public {
        vm.fee(1);

        uint32 gas = 500_000;
        uint32 numCalls = 2;
        uint32 frequency = 10;
        uint32 ttl = 5;
        uint256 maxFeePerGas = scheduler.MIN_SCHEDULED_MAX_FEE_PER_GAS();
        uint256 maxPriorityFeePerGas = 0;
        uint256 value = 0;

        uint256 oneMaxExecutionCost = (maxFeePerGas * gas) + value;
        wallet.setBalance(address(callee), oneMaxExecutionCost + _autoResidencyFee(numCalls, frequency, ttl));

        uint256 callId =
            callee.schedule(scheduler, gas, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, value);

        vm.roll(block.number + frequency);
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 0);

        assertEq(callee.callCount(), 1);
        assertEq(uint8(scheduler.getCallState(callId)), uint8(CallState.SCHEDULED));

        wallet.setBalance(address(callee), 0);

        vm.roll(block.number + frequency);
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 1);

        assertEq(callee.callCount(), 1, "second execution should not run after missed payment");
        vm.expectRevert(Scheduler.CallNotFound.selector);
        scheduler.getCallState(callId);
    }

    function testOwnerCanUpdateScheduledResidencyFeePerBlock() public {
        Scheduler impl = new Scheduler(address(wallet), 30);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(Scheduler.initialize, (address(this))));
        Scheduler ownedScheduler = Scheduler(payable(address(proxy)));

        assertEq(ownedScheduler.SCHEDULED_RESIDENCY_FEE_PER_BLOCK(), 0.01 ether);
        ownedScheduler.setScheduledResidencyFeePerBlock(0.02 ether);
        assertEq(ownedScheduler.SCHEDULED_RESIDENCY_FEE_PER_BLOCK(), 0.02 ether);

        vm.prank(address(0xBEEF));
        vm.expectRevert();
        ownedScheduler.setScheduledResidencyFeePerBlock(0.03 ether);
    }

    function testExecuteSettlesExactEip1559MoneyFlow() public {
        uint256 baseFeePerGas = 2 gwei;
        uint256 priorityFeePerGas = 3 gwei;
        uint256 effectiveFeePerGas = baseFeePerGas + priorityFeePerGas;
        uint32 gasLimit = 500_000;
        uint32 frequency = 10;
        uint256 value = 0.1 ether;
        address payable proposer = payable(address(0xBEEF));
        address burnAddress = BURN_ADDRESS;

        vm.fee(baseFeePerGas);
        vm.coinbase(proposer);
        vm.deal(proposer, 0);

        uint256 callId =
            callee.schedule(scheduler, gasLimit, 1, frequency, 5, effectiveFeePerGas, priorityFeePerGas, value);

        uint256 sponsorBefore = wallet.availableBalance(address(callee));
        uint256 targetBefore = address(callee).balance;
        uint256 schedulerBefore = address(scheduler).balance;
        uint256 proposerBefore = proposer.balance;
        uint256 burnBefore = burnAddress.balance;
        uint256 upfront = uint256(gasLimit) * effectiveFeePerGas + value;

        _executeAt(callId, frequency, 0);

        uint256 baseFeeBurned = burnAddress.balance - burnBefore;
        uint256 proposerTip = proposer.balance - proposerBefore;
        uint256 gasUsed = baseFeeBurned / baseFeePerGas;
        assertGt(gasUsed, 0);
        assertLe(gasUsed, gasLimit);

        uint256 refund = (uint256(gasLimit) - gasUsed) * effectiveFeePerGas;
        uint256 sponsorAfter = wallet.availableBalance(address(callee));
        uint256 sponsorDebit = sponsorBefore - sponsorAfter;
        uint256 targetCredit = address(callee).balance - targetBefore;
        uint256 schedulerResidual = address(scheduler).balance - schedulerBefore;

        assertEq(sponsorAfter, sponsorBefore - upfront + refund);
        assertEq(sponsorDebit, upfront - refund);
        assertEq(baseFeeBurned, gasUsed * baseFeePerGas);
        assertEq(proposerTip, gasUsed * priorityFeePerGas);
        assertEq(targetCredit, value);
        assertEq(schedulerResidual, 0);
        assertEq(sponsorDebit, gasUsed * effectiveFeePerGas + value);
        assertEq(upfront, refund + targetCredit + proposerTip + baseFeeBurned + schedulerResidual);
    }

    /// @notice Covers the priority-fee cap branch in execute(): when the base fee has risen
    ///         since scheduling so that `basefee + maxPriorityFeePerGas > maxFeePerGas`, the
    ///         tip must be metered at `maxFeePerGas - basefee`, and the sponsor must never be
    ///         charged more than `maxFeePerGas` per unit of gas.
    function testExecuteCapsPriorityTipWhenBaseFeeRisesAfterScheduling() public {
        uint256 scheduleBaseFee = 2 gwei;
        uint256 executionBaseFee = 5 gwei;
        uint256 maxFeePerGas = 6 gwei;
        uint256 maxPriorityFeePerGas = 3 gwei; // basefee + priority = 8 gwei > maxFeePerGas at execution
        uint256 cappedPriorityFee = maxFeePerGas - executionBaseFee; // 1 gwei
        uint32 gasLimit = 500_000;
        uint32 frequency = 10;
        uint256 value = 0.1 ether;
        address payable proposer = payable(address(0xBEEF));

        vm.fee(scheduleBaseFee);
        vm.coinbase(proposer);
        vm.deal(proposer, 0);

        uint256 callId =
            callee.schedule(scheduler, gasLimit, 1, frequency, 5, maxFeePerGas, maxPriorityFeePerGas, value);

        uint256 sponsorBefore = wallet.availableBalance(address(callee));
        uint256 targetBefore = address(callee).balance;
        uint256 schedulerBefore = address(scheduler).balance;
        uint256 proposerBefore = proposer.balance;
        uint256 burnBefore = BURN_ADDRESS.balance;
        // With the cap binding, the effective fee is exactly maxFeePerGas.
        uint256 upfront = uint256(gasLimit) * maxFeePerGas + value;

        vm.fee(executionBaseFee);
        _executeAt(callId, frequency, 0);

        uint256 baseFeeBurned = BURN_ADDRESS.balance - burnBefore;
        uint256 proposerTip = proposer.balance - proposerBefore;
        uint256 gasUsed = baseFeeBurned / executionBaseFee;
        assertGt(gasUsed, 0);
        assertLe(gasUsed, gasLimit);

        uint256 refund = (uint256(gasLimit) - gasUsed) * maxFeePerGas;
        uint256 sponsorDebit = sponsorBefore - wallet.availableBalance(address(callee));
        uint256 targetCredit = address(callee).balance - targetBefore;

        assertEq(callee.callCount(), 1);
        assertEq(baseFeeBurned, gasUsed * executionBaseFee);
        assertEq(proposerTip, gasUsed * cappedPriorityFee, "tip must be metered at maxFeePerGas - basefee");
        assertEq(targetCredit, value);
        assertEq(address(scheduler).balance - schedulerBefore, 0);
        assertEq(sponsorDebit, gasUsed * maxFeePerGas + value, "sponsor must never pay above maxFeePerGas");
        assertEq(upfront, refund + targetCredit + proposerTip + baseFeeBurned);
    }

    /// @notice Boundary of the base-fee skip: at `basefee == maxFeePerGas` the call must
    ///         execute (the skip requires a strictly greater base fee), the whole per-gas
    ///         fee burns, and the proposer tip is zero. The rejecting coinbase proves the
    ///         zero-tip path never attempts a payment: any nonzero tip would revert with
    ///         ProposerPaymentFailed.
    function testExecuteAtBaseFeeEqualToMaxFeeBurnsAllGasFeesAndPaysNoTip() public {
        uint256 maxFeePerGas = 6 gwei;
        uint32 gasLimit = 500_000;
        uint32 frequency = 10;

        uint256 callId = callee.schedule(scheduler, gasLimit, 1, frequency, 5, maxFeePerGas, 3 gwei, 0);

        RejectingSchedulerProposer proposer = new RejectingSchedulerProposer();
        vm.coinbase(address(proposer));
        vm.fee(maxFeePerGas);

        uint256 sponsorBefore = wallet.availableBalance(address(callee));
        uint256 burnBefore = BURN_ADDRESS.balance;

        _executeAt(callId, frequency, 0);

        uint256 baseFeeBurned = BURN_ADDRESS.balance - burnBefore;
        uint256 gasUsed = baseFeeBurned / maxFeePerGas;

        assertEq(callee.callCount(), 1, "equal base fee must execute, not skip");
        assertGt(gasUsed, 0);
        assertEq(address(proposer).balance, 0);
        assertEq(baseFeeBurned, gasUsed * maxFeePerGas);
        assertEq(sponsorBefore - wallet.availableBalance(address(callee)), gasUsed * maxFeePerGas);
    }

    function testExecuteRevertsWhenContractProposerRejectsEth() public {
        uint256 baseFeePerGas = 2 gwei;
        uint256 priorityFeePerGas = 1 gwei;
        uint32 frequency = 10;
        vm.fee(baseFeePerGas);

        uint256 callId = callee.schedule(
            scheduler, 500_000, 1, frequency, 5, baseFeePerGas + priorityFeePerGas, priorityFeePerGas, 0
        );
        RejectingSchedulerProposer proposer = new RejectingSchedulerProposer();
        vm.coinbase(address(proposer));

        vm.expectRevert(Scheduler.ProposerPaymentFailed.selector);
        _executeAt(callId, frequency, 0);

        assertEq(callee.callCount(), 0);
        assertEq(uint8(scheduler.getCallState(callId)), uint8(CallState.SCHEDULED));
        assertFalse(scheduler.isExecuted(callId, 0));
        assertEq(address(proposer).balance, 0);
        assertEq(wallet.availableBalance(address(proposer)), 0);
    }

    function testExecuteSkipsWithoutEvictingWhenBaseFeeExceedsMaxFeePerGas() public {
        uint32 gas = 500_000;
        uint32 numCalls = 1;
        uint32 frequency = 10;
        uint32 ttl = 5;
        uint256 maxFeePerGas = scheduler.MIN_SCHEDULED_MAX_FEE_PER_GAS();
        uint256 maxPriorityFeePerGas = 0;
        uint256 value = 0;

        wallet.setBalance(address(callee), 10 ether);
        uint256 callId =
            callee.schedule(scheduler, gas, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, value);

        vm.fee(maxFeePerGas + 1);
        vm.roll(block.number + frequency);
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 0);

        assertEq(callee.callCount(), 0);
        assertEq(uint8(scheduler.getCallState(callId)), uint8(CallState.SCHEDULED));
        assertFalse(scheduler.isExecuted(callId, 0));
    }

    function testExecuteEvictsWhenWalletCannotPayGas() public {
        vm.fee(1);

        uint32 gas = 500_000;
        uint32 numCalls = 1;
        uint32 frequency = 10;
        uint32 ttl = 5;
        uint256 maxFeePerGas = scheduler.MIN_SCHEDULED_MAX_FEE_PER_GAS();
        uint256 maxPriorityFeePerGas = 0;
        uint256 value = 0;

        wallet.setBalance(address(callee), (maxFeePerGas * gas) + _autoResidencyFee(numCalls, frequency, ttl));
        uint256 callId =
            callee.schedule(scheduler, gas, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, value);

        wallet.setBalance(address(callee), 0);

        vm.roll(block.number + frequency);
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 0);

        assertEq(callee.callCount(), 0);
        vm.expectRevert(Scheduler.CallNotFound.selector);
        scheduler.getCallState(callId);
    }

    function testScheduleRejectsMaxFeeBelowFloor() public {
        uint32 gas = 100_000;
        uint32 numCalls = 1;
        uint32 frequency = 10;
        uint32 ttl = 5;
        uint256 maxPriorityFeePerGas = 0;
        uint256 value = 0;
        uint256 belowFloor = scheduler.MIN_SCHEDULED_MAX_FEE_PER_GAS() - 1;

        vm.expectRevert(Scheduler.MaxFeePerGasBelowFloor.selector);
        callee.schedule(scheduler, gas, numCalls, frequency, ttl, belowFloor, maxPriorityFeePerGas, value);
    }

    function testScheduleAllowsMaxFeeAtFloor() public {
        uint32 gas = 100_000;
        uint32 numCalls = 1;
        uint32 frequency = 10;
        uint32 ttl = 5;
        uint256 maxFeePerGas = scheduler.MIN_SCHEDULED_MAX_FEE_PER_GAS();
        uint256 maxPriorityFeePerGas = 0;
        uint256 value = 0;

        uint256 callId =
            callee.schedule(scheduler, gas, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, value);

        assertEq(uint8(scheduler.getCallState(callId)), uint8(CallState.SCHEDULED));
    }

    function testExecute() public {
        uint32 gas = 500_000;
        uint32 numCalls = 100;
        uint32 frequency = 10;
        uint32 ttl = 5;
        uint256 maxFeePerGas = 20 gwei;
        uint256 maxPriorityFeePerGas = 2 gwei;
        uint256 value = 0.1 ether;

        // Schedule call
        uint256 callId =
            callee.schedule(scheduler, gas, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, value);

        // Roll to next block for execution
        vm.roll(block.number + frequency);

        // Execute call with executionIndex
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 0); // First execution (index 0)

        // Verify call was executed
        assertEq(callee.callCount(), 1);
        assertEq(callee.lastValue(), value);
        assertEq(callee.lastExecutionIndex(), 0); // First execution should have index 0
    }

    function testExecuteReacquiresCallAfterReentrantCancelCompactsSlots() public {
        ReentrantCancelCallee reentrant = new ReentrantCancelCallee(scheduler);
        wallet.setBalance(address(reentrant), 10 ether);

        uint32 gas = 500_000;
        uint32 numCalls = 2;
        uint32 frequency = 1;
        uint32 ttl = 5;
        uint256 maxFeePerGas = 20 gwei;
        uint256 maxPriorityFeePerGas = 2 gwei;

        // victim occupies an earlier slot; active occupies the last slot.
        uint256 victimCallId = reentrant.scheduleNoop(gas, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas);
        uint256 activeCallId = reentrant.scheduleCancelDuringExecute(
            victimCallId, gas, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas
        );

        assertEq(victimCallId, 0);
        assertEq(activeCallId, 1);

        vm.roll(block.number + frequency);
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(activeCallId, 0);

        assertEq(reentrant.callCount(), 1);
        assertEq(reentrant.lastExecutionIndex(), 0);

        vm.expectRevert(Scheduler.CallNotFound.selector);
        scheduler.getCallState(victimCallId);

        assertEq(
            uint8(scheduler.getCallState(activeCallId)),
            uint8(CallState.SCHEDULED),
            "active call should return to scheduled after reentrant compaction"
        );
        assertFalse(scheduler.isExecuted(activeCallId, 1), "future execution index should remain pending");
    }

    function testExecuteReacquiresCallAfterReentrantCleanupCompactsSlots() public {
        ReentrantCancelCallee reentrant = new ReentrantCancelCallee(scheduler);
        wallet.setBalance(address(reentrant), 10 ether);

        uint256 expiredCallId = reentrant.scheduleNoop(500_000, 1, 1, 0, 20 gwei, 2 gwei);
        uint256 activeCallId = reentrant.scheduleCleanupDuringExecute(expiredCallId, 500_000, 2, 10, 5, 20 gwei, 2 gwei);

        assertEq(expiredCallId, 0);
        assertEq(activeCallId, 1);

        vm.roll(block.number + 10);
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(activeCallId, 0);

        assertEq(reentrant.callCount(), 1);
        assertEq(reentrant.lastExecutionIndex(), 0);

        vm.expectRevert(Scheduler.CallNotFound.selector);
        scheduler.getCallState(expiredCallId);

        assertEq(
            uint8(scheduler.getCallState(activeCallId)),
            uint8(CallState.SCHEDULED),
            "active call should return to scheduled after reentrant cleanup compaction"
        );
    }

    function testCancel() public {
        uint32 gas = 100_000;
        uint32 numCalls = 100;
        uint32 frequency = 10;
        uint32 ttl = 5;
        uint256 maxFeePerGas = 20 gwei;
        uint256 maxPriorityFeePerGas = 2 gwei;
        uint256 value = 0.1 ether;

        // Schedule call
        uint256 callId =
            callee.schedule(scheduler, gas, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, value);

        // Cancel call
        vm.prank(address(callee));
        scheduler.cancel(callId);

        // Events array was removed - now using event logs for monitoring
        // Test should verify event logs instead of events array
    }

    function testExecuteFail() public {
        uint32 gas = 500_000;
        uint32 numCalls = 100;
        uint32 frequency = 10;
        uint32 ttl = 5;
        uint256 maxFeePerGas = 20 gwei;
        uint256 maxPriorityFeePerGas = 2 gwei;
        uint256 value = 0.1 ether;

        // Schedule call
        uint256 callId =
            callee.schedule(scheduler, gas, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, value);

        // Set callee to revert
        callee.setShouldRevert(true);

        // Roll to next block for execution
        vm.roll(block.number + frequency);

        // Execute call should not revert (graceful failure)
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 0);

        // Verify call was not executed (graceful failure)
        assertEq(callee.callCount(), 0);
    }

    function testExecutionIndexMultipleExecutions() public {
        uint32 gas = 500_000;
        uint32 numCalls = 100;
        uint32 frequency = 10;
        uint32 ttl = 5;
        uint256 maxFeePerGas = 20 gwei;
        uint256 maxPriorityFeePerGas = 2 gwei;
        uint256 value = 0.1 ether;

        // Schedule call
        uint256 callId =
            callee.schedule(scheduler, gas, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, value);

        // Execute first call (index 0)
        vm.roll(block.number + frequency);
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 0);
        assertEq(callee.lastExecutionIndex(), 0);

        // Execute second call (index 1)
        vm.roll(block.number + frequency);
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 1);
        assertEq(callee.lastExecutionIndex(), 1);

        // Execute third call (index 2)
        vm.roll(block.number + frequency);
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 2);
        assertEq(callee.lastExecutionIndex(), 2);

        // Verify total executions
        assertEq(callee.callCount(), 3);
    }

    function testOverlappingWindowsAllowOutOfOrderExecution() public {
        uint32 gas = 500_000;
        uint32 numCalls = 3;
        uint32 frequency = 1;
        uint32 ttl = 25;
        uint256 maxFeePerGas = 20 gwei;
        uint256 maxPriorityFeePerGas = 2 gwei;

        uint256 callId =
            callee.schedule(scheduler, gas, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, 0);
        (,, uint32 startBlock,,,,,,,,,) = scheduler.calls(callId);

        // At startBlock + 2, indices 0, 1, and 2 are all individually valid because
        // the long TTL creates overlapping execution windows. The Scheduler
        // intentionally allows the later index to execute first; it enforces
        // per-index validity, not strict monotonic ordering.
        vm.roll(uint256(startBlock) + 2);
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 2);
        assertEq(callee.lastExecutionIndex(), 2);
        assertTrue(scheduler.isExecuted(callId, 2));
        assertFalse(scheduler.isExecuted(callId, 0));
        assertFalse(scheduler.isExecuted(callId, 1));

        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 0);
        assertEq(callee.lastExecutionIndex(), 0);

        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 1);
        assertEq(callee.lastExecutionIndex(), 1);
        assertEq(scheduler.executedBitmap(callId), 0, "completion clears per-index bitmap");
    }

    function testExecuteSurvivesReentrantCancelMovingActiveTailSlot() public {
        vm.fee(1);

        ReentrantSlotMover mover = new ReentrantSlotMover(scheduler);
        wallet.setBalance(address(mover), 100 ether);

        uint32 gasLimit = 2_000_000;
        uint32 numCalls = 2;
        uint32 frequency = 10;
        uint32 ttl = 20;
        uint256 maxFeePerGas = 20 gwei;
        uint256 maxPriorityFeePerGas = 1 gwei;

        (uint256 retiredCallId, uint256 activeCallId) =
            mover.arm(gasLimit, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas);

        assertEq(scheduler.callToSlot(retiredCallId), 0, "retired call should be in first slot");
        assertEq(scheduler.callToSlot(activeCallId), 1, "active call should start at tail slot");

        vm.roll(block.number + frequency);
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(activeCallId, 0);

        uint256 successorCallId = mover.successorCallId();
        assertEq(mover.wakeCount(), 1, "active call target did not execute");
        assertEq(scheduler.callToSlot(activeCallId), 0, "active call should have moved into retired slot");
        assertEq(scheduler.callToSlot(successorCallId), 1, "successor should reuse old tail slot");
        assertEq(uint8(scheduler.getCallState(activeCallId)), uint8(CallState.SCHEDULED), "active call wedged");
        assertEq(uint8(scheduler.getCallState(successorCallId)), uint8(CallState.SCHEDULED), "successor corrupted");
        assertTrue(scheduler.isExecuted(activeCallId, 0), "active execution bitmap not marked");
        assertFalse(scheduler.isExecuted(activeCallId, 1), "future execution marked unexpectedly");

        vm.expectRevert(Scheduler.CallNotFound.selector);
        scheduler.getCallState(retiredCallId);
    }

    function _makeBytes(uint256 size, bytes1 head, bytes1 tail) internal pure returns (bytes memory b) {
        b = new bytes(size);
        if (size > 0) {
            b[0] = head;
            b[size - 1] = tail;
        }
    }

    function testCancelLargePayload() public {
        // 2KB payload scheduled by this contract
        bytes memory payload = _makeBytes(2048, 0xAA, 0xBB);
        uint32 gasLimit = 100_000;
        uint32 freq = 10;
        uint32 ttl = 5;
        uint32 numCalls = 5;
        uint256 maxFeePerGas = 20 gwei;
        uint256 maxPriorityFeePerGas = 2 gwei;
        uint256 value = 0.01 ether;

        uint256 callId =
            scheduler.schedule(payload, gasLimit, numCalls, freq, ttl, maxFeePerGas, maxPriorityFeePerGas, value);

        // Cancel from owner (to == address(this))
        scheduler.cancel(callId);

        vm.expectRevert(Scheduler.CallNotFound.selector);
        scheduler.getCallState(callId);
    }

    function testScheduleRejectsOversizedPayload() public {
        bytes memory payload = _makeBytes(scheduler.MAX_CALL_DATA_LENGTH() + 1, 0xAA, 0xBB);

        vm.expectRevert(Scheduler.CallDataTooLarge.selector);
        scheduler.schedule(payload, 100_000, 1, 10, 5, 20 gwei, 2 gwei, 0);
    }

    function testCancelMovesMaximumPayloadTail() public {
        bytes memory payload = new bytes(scheduler.MAX_CALL_DATA_LENGTH());
        for (uint256 i = 0; i < payload.length; ++i) {
            payload[i] = 0xFF;
        }

        uint256 firstCallId = scheduler.schedule("", 100_000, 1, 10, 5, 20 gwei, 2 gwei, 0);
        uint256 tailCallId = scheduler.schedule(payload, 100_000, 1, 10, 5, 20 gwei, 2 gwei, 0);

        uint256 gasBefore = gasleft();
        scheduler.cancel(firstCallId);
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(scheduler.callToSlot(tailCallId), 0);
        assertEq(uint8(scheduler.getCallState(tailCallId)), uint8(CallState.SCHEDULED));
        assertLt(gasUsed, 15_000_000);
        vm.expectRevert(Scheduler.CallNotFound.selector);
        scheduler.getCallState(firstCallId);
    }

    function testExecuteCompletesLargePayload() public {
        // 3KB payload; set numCalls=1 to complete after first execution
        bytes memory payload = _makeBytes(3072, 0x11, 0x22);
        uint32 gasLimit = 500_000;
        uint32 freq = 1;
        uint32 ttl = 5;
        uint32 numCalls = 1;
        uint256 maxFeePerGas = 20 gwei;
        uint256 maxPriorityFeePerGas = 2 gwei;
        uint256 value = 0.01 ether;

        uint256 callId =
            scheduler.schedule(payload, gasLimit, numCalls, freq, ttl, maxFeePerGas, maxPriorityFeePerGas, value);

        vm.roll(block.number + freq);
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 0);

        vm.expectRevert(Scheduler.CallNotFound.selector);
        scheduler.getCallState(callId);
    }

    function testCleanupExpiredCallsLargePayload() public {
        bytes memory payload = _makeBytes(1024, 0x01, 0xFF);
        uint32 gasLimit = 100_000;
        uint32 freq = 10;
        uint32 ttl = 5;
        // Set numCalls=1 so it will expire after missing the first execution window
        uint32 numCalls = 1;
        uint256 maxFeePerGas = 20 gwei;
        uint256 maxPriorityFeePerGas = 2 gwei;
        uint256 value = 0;

        uint256 callId =
            scheduler.schedule(payload, gasLimit, numCalls, freq, ttl, maxFeePerGas, maxPriorityFeePerGas, value);
        // Roll past expiry (startBlock + ttl)
        // startBlock = block.number + freq = 1 + 10 = 11, expiry = 11 + 5 = 16
        vm.roll(20);

        uint256[] memory ids = new uint256[](1);
        ids[0] = callId;
        scheduler.cleanupExpiredCalls(ids);

        vm.expectRevert(Scheduler.CallNotFound.selector);
        scheduler.getCallState(callId);
    }

    function testOriginHashAndPredicatesCleanedOnCompletion() public {
        uint32 gas = 500_000;
        uint32 numCalls = 1;
        uint32 freq = 1;
        uint32 ttl = 5;
        uint256 maxFeePerGas = 20 gwei;
        uint256 maxPriorityFeePerGas = 2 gwei;

        uint256 callId = callee.schedule(scheduler, gas, numCalls, freq, ttl, maxFeePerGas, maxPriorityFeePerGas, 0);

        // originHash is populated at schedule time (via TX_HASH precompile, which is
        // a no-op in Foundry, so the hash may be zero — but the mapping slot is still
        // written). Verify the mapping entries exist by confirming callToSlot is set.
        assertEq(uint8(scheduler.getCallState(callId)), uint8(CallState.SCHEDULED));

        // Execute to completion (numCalls=1, single execution completes the call)
        vm.roll(block.number + freq);
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 0);

        // After completion, all auxiliary mappings must be zeroed
        assertEq(scheduler.originHash(callId), bytes32(0), "originHash not cleaned on completion");
        assertEq(scheduler.callPredicates(callId), address(0), "callPredicates not cleaned on completion");
        assertEq(scheduler.callToSlot(callId), 0, "callToSlot not cleaned on completion");
        assertEq(scheduler.executedBitmap(callId), 0, "executedBitmap not cleaned on completion");
    }

    function testOriginHashAndPredicatesCleanedOnCancel() public {
        uint32 gas = 100_000;
        uint32 numCalls = 10;
        uint32 freq = 10;
        uint32 ttl = 5;
        uint256 maxFeePerGas = 20 gwei;
        uint256 maxPriorityFeePerGas = 2 gwei;

        uint256 callId = callee.schedule(scheduler, gas, numCalls, freq, ttl, maxFeePerGas, maxPriorityFeePerGas, 0);

        vm.prank(address(callee));
        scheduler.cancel(callId);

        assertEq(scheduler.originHash(callId), bytes32(0), "originHash not cleaned on cancel");
        assertEq(scheduler.callPredicates(callId), address(0), "callPredicates not cleaned on cancel");
        assertEq(scheduler.callToSlot(callId), 0, "callToSlot not cleaned on cancel");
    }

    function testOriginHashAndPredicatesCleanedOnExpiry() public {
        bytes memory payload = _makeBytes(64, 0xAA, 0xBB);
        uint32 gasLimit = 100_000;
        uint32 freq = 10;
        uint32 ttl = 5;
        uint32 numCalls = 1;
        uint256 maxFeePerGas = 20 gwei;
        uint256 maxPriorityFeePerGas = 2 gwei;

        uint256 callId =
            scheduler.schedule(payload, gasLimit, numCalls, freq, ttl, maxFeePerGas, maxPriorityFeePerGas, 0);

        // Roll past expiry
        vm.roll(30);

        uint256[] memory ids = new uint256[](1);
        ids[0] = callId;
        scheduler.cleanupExpiredCalls(ids);

        assertEq(scheduler.originHash(callId), bytes32(0), "originHash not cleaned on expiry");
        assertEq(scheduler.callPredicates(callId), address(0), "callPredicates not cleaned on expiry");
        assertEq(scheduler.callToSlot(callId), 0, "callToSlot not cleaned on expiry");
    }

    function testOriginHashAndPredicatesCleanedOnExecuteExpiry() public {
        uint32 gas = 500_000;
        uint32 numCalls = 1;
        uint32 freq = 10;
        uint32 ttl = 5;
        uint256 maxFeePerGas = 20 gwei;
        uint256 maxPriorityFeePerGas = 2 gwei;

        uint256 callId = callee.schedule(scheduler, gas, numCalls, freq, ttl, maxFeePerGas, maxPriorityFeePerGas, 0);

        // Roll past the overall expiry (startBlock + ttl)
        vm.roll(30);

        // execute() on an expired call triggers the in-execute expiry path
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 0);

        assertEq(scheduler.originHash(callId), bytes32(0), "originHash not cleaned on execute-expiry");
        assertEq(scheduler.callPredicates(callId), address(0), "callPredicates not cleaned on execute-expiry");
        assertEq(scheduler.callToSlot(callId), 0, "callToSlot not cleaned on execute-expiry");
    }

    function testFeeExceedsU128_maxFeePerGas() public {
        uint256 badFee = uint256(type(uint128).max) + 1;
        vm.expectRevert(Scheduler.FeeExceedsU128.selector);
        callee.schedule(scheduler, 100_000, 1, 10, 5, badFee, 2 gwei, 0);
    }

    function testFeeExceedsU128_maxPriorityFeePerGas() public {
        uint256 badPriority = uint256(type(uint128).max) + 1;
        vm.expectRevert(Scheduler.FeeExceedsU128.selector);
        callee.schedule(scheduler, 100_000, 1, 10, 5, 20 gwei, badPriority, 0);
    }

    function testFeeExceedsU128_bothFields() public {
        uint256 badFee = type(uint256).max;
        vm.expectRevert(Scheduler.FeeExceedsU128.selector);
        callee.schedule(scheduler, 100_000, 1, 10, 5, badFee, badFee, 0);
    }

    function testFeeAtU128Max_succeeds() public {
        uint256 maxU128 = uint256(type(uint128).max);
        wallet.setBalance(address(callee), maxU128 + _autoResidencyFee(1, 10, 5));
        uint256 callId = callee.schedule(scheduler, 1, 1, 10, 5, maxU128, maxU128, 0);
        assertEq(uint256(scheduler.getCallState(callId)), uint256(CallState.SCHEDULED));
    }

    function testScheduleRevertsWhenHorizonOverflowsUint32() public {
        uint32 gas = 500_000;
        uint32 startBlock = type(uint32).max - 10;
        uint32 frequency = 1;
        uint32 numCalls = 1;
        uint32 ttl = 20;
        uint256 maxFeePerGas = 20 gwei;
        uint256 maxPriorityFeePerGas = 2 gwei;

        vm.expectRevert(Scheduler.ScheduleHorizonOverflow.selector);
        callee.scheduleAt(scheduler, gas, startBlock, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, 0);
    }

    function testScheduleRevertsWhenLifespanExceedsBound() public {
        uint32 gas = 500_000;
        uint32 frequency = 500;
        uint32 ttl = 20;
        uint32 numCalls = 21;
        uint256 maxFeePerGas = 20 gwei;
        uint256 maxPriorityFeePerGas = 2 gwei;

        vm.expectRevert(Scheduler.ScheduleLifespanExceeded.selector);
        callee.schedule(scheduler, gas, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, 0);
    }

    function testScheduleRevertsWhenNumCallsExceedsBitmapCapacity() public {
        uint32 gas = 500_000;
        uint32 numCalls = 257;
        uint32 frequency = 1;
        uint32 ttl = 0;
        uint256 maxFeePerGas = 20 gwei;
        uint256 maxPriorityFeePerGas = 2 gwei;

        vm.expectRevert(Scheduler.InvalidNumCalls.selector);
        callee.schedule(scheduler, gas, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, 0);
    }

    function testScheduleMaxBitmapCapacityCompletesAfterBit255() public {
        uint32 gas = 500_000;
        uint32 numCalls = 256;
        uint32 frequency = 1;
        uint32 ttl = 30;
        uint256 maxFeePerGas = 20 gwei;
        uint256 maxPriorityFeePerGas = 2 gwei;

        uint256 callId =
            callee.schedule(scheduler, gas, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, 0);
        (,, uint32 startBlock,,,,,,,,,) = scheduler.calls(callId);

        assertEq(uint8(scheduler.getCallState(callId)), uint8(CallState.SCHEDULED));
        assertFalse(scheduler.isExecuted(callId, 256), "indices above the bitmap capacity are never representable");

        for (uint256 i; i < 255; i++) {
            vm.roll(uint256(startBlock) + i);
            vm.prank(SYSTEM_ACCOUNT);
            scheduler.execute(callId, i);
        }

        assertEq(uint8(scheduler.getCallState(callId)), uint8(CallState.SCHEDULED));
        assertTrue(scheduler.isExecuted(callId, 254));
        assertFalse(scheduler.isExecuted(callId, 255));

        vm.roll(uint256(startBlock) + 255);
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 255);

        assertEq(callee.callCount(), 256);
        assertEq(callee.lastExecutionIndex(), 255);
        assertEq(scheduler.executedBitmap(callId), 0, "full bitmap must be cleared after completion");
        vm.expectRevert(Scheduler.CallNotFound.selector);
        scheduler.getCallState(callId);
    }

    function testScheduleAtUint32HorizonBoundarySucceedsAndExecutes() public {
        uint32 gas = 500_000;
        uint32 startBlock = type(uint32).max - 20;
        uint32 frequency = 1;
        uint32 numCalls = 1;
        uint32 ttl = 20;
        uint256 maxFeePerGas = 20 gwei;
        uint256 maxPriorityFeePerGas = 2 gwei;
        uint256 residency = uint256(startBlock) + ttl - block.number;
        uint256 residencyFee = scheduler.SCHEDULED_RESIDENCY_FEE_PER_BLOCK() * residency;
        uint256 maxExecutionCost = maxFeePerGas * gas;
        wallet.setBalance(address(callee), residencyFee + maxExecutionCost);
        vm.deal(address(wallet), residencyFee + maxExecutionCost);

        uint256 callId = callee.scheduleAt(
            scheduler, gas, startBlock, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, 0
        );

        vm.roll(startBlock);
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 0);

        assertEq(callee.callCount(), 1);
        assertEq(callee.lastExecutionIndex(), 0);
    }

    function testScheduleAtLifespanBoundarySucceedsAndExecutes() public {
        uint32 gas = 500_000;
        uint32 frequency = 500;
        uint32 ttl = 0;
        uint32 numCalls = 21;
        uint256 maxFeePerGas = 20 gwei;
        uint256 maxPriorityFeePerGas = 2 gwei;

        uint256 callId =
            callee.schedule(scheduler, gas, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, 0);

        vm.roll(block.number + frequency);
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 0);

        assertEq(callee.callCount(), 1);
        assertEq(callee.lastExecutionIndex(), 0);
        assertEq(scheduler.MAX_LIFESPAN(), 10_000);
    }
}
