// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.28;

/// @title IScheduledCallback
/// @notice The single ABI contract the Scheduler uses to invoke a scheduled call's target.
/// @dev Every scheduled execution is delivered as a call to `onScheduledExecution(executionIndex, payload)`.
///      The Scheduler passes the caller-provided scheduling `data` through verbatim as `payload`; it never
///      inspects or mutates those bytes. The execution index is delivered as an explicit, typed argument
///      rather than being injected into the payload, so the Scheduler is provably non-corrupting for any
///      payload (including empty). Targets decode `payload` themselves to recover their own arguments.
///
///      Targets MUST restrict `onScheduledExecution` to calls originating from the Scheduler
///      (e.g. `require(msg.sender == scheduler)`); the Scheduler does not authenticate targets.
interface IScheduledCallback {
    /// @notice Invoked by the Scheduler for each scheduled execution.
    /// @param executionIndex The 0-based index of this execution within the schedule.
    /// @param payload The opaque, verbatim scheduling data provided to `Scheduler.schedule(...)`.
    function onScheduledExecution(uint256 executionIndex, bytes calldata payload) external payable;
}
