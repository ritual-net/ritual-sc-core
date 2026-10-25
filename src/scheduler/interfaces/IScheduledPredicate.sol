// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.28;

/// @title IScheduledPredicate
/// @notice Interface for scheduled transaction predicates
/// @dev Predicates determine whether a scheduled call should be included in a block.
///      The block proposer evaluates the predicate before including the transaction.
///      Predicates MUST be view functions (no state changes) for deterministic consensus.
interface IScheduledPredicate {
    /// @notice Determines if the scheduled call should be included in the current block
    /// @dev Called via staticcall by the block proposer. Must not modify state.
    ///      The predicate can access block.number directly via the EVM opcode.
    /// @param target The scheduled callback target (stored in Call.to)
    /// @param callId The unique identifier for this scheduled call
    /// @param executionIndex The current execution index (0-based, increments each execution)
    /// @return True if the call should be included in this block, false to skip
    function shouldExecute(address target, uint256 callId, uint256 executionIndex) external view returns (bool);
}
