// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.28;

interface ISchedulerAsyncBridge {
    function markScheduledAsyncInFlight(uint256 callId, uint256 executionIndex, bytes32 jobId) external;
}
