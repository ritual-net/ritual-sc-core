// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.28;

/**
 * @title IAsyncJobTracker - Interface for AsyncJobTracker contract
 * @notice Interface for managing pending async jobs
 * @dev SC-2: Functions now require precompile input to be passed via calldata
 */
interface IAsyncJobTracker {
    /// @notice Canonical on-chain context needed by AsyncDelivery for Phase 1 settlement payments.
    /// @param executorPaymentAddress Payment recipient derived from the job executor's registry entry
    /// @param commitmentValidator Validator that included the async commitment
    function getSettlementContext(bytes32 jobId)
        external
        view
        returns (address executorPaymentAddress, address commitmentValidator);

    /// @notice Remove a job (called by settlement transactions)
    /// @param jobId The job ID to remove
    /// @param input The precompile input (SC-2: passed via calldata, verified by hash)
    /// @param completed Whether the job was completed successfully
    /// @return success True if the job was found and removed
    function removeJob(bytes32 jobId, bytes calldata input, bool completed) external returns (bool success);

    /// @notice Get the number of pending jobs for an executor
    /// @param executor The executor address
    /// @return count Number of pending jobs
    function getJobCount(address executor) external view returns (uint256 count);

    /// @notice Check if job uses a two-phase precompile (0x0805, 0x0806, 0x0807, 0x080C, 0x0818, 0x0819, 0x081A, 0x0820)
    /// @param jobId The job identifier
    /// @return True if job is long-running
    function isLongRunning(bytes32 jobId) external view returns (bool);

    /// @notice Check if Phase 1 is settled for a long-running job
    /// @param jobId The job identifier
    /// @return True if Phase 1 settlement is complete
    function isPhase1Settled(bytes32 jobId) external view returns (bool);

    /// @notice Compute the Phase 2 deadline that will be applied when Phase 1 settles
    /// @param jobId The job identifier
    /// @param input The precompile input (SC-2: passed via calldata, verified by hash)
    /// @return phase2Deadline Absolute block deadline for Phase 2 delivery
    function computePhase2Deadline(bytes32 jobId, bytes calldata input) external view returns (uint64 phase2Deadline);

    /// @notice Mark a long-running job as Phase 1 settled
    /// @param jobId The job identifier
    /// @param input The precompile input (SC-2: passed via calldata, verified by hash)
    /// @return phase2Deadline Absolute block deadline for Phase 2 delivery
    function markPhase1Settled(bytes32 jobId, bytes calldata input) external returns (uint64 phase2Deadline);

    /// @notice Mark job as delivered and remove it (AsyncDelivery contract only)
    /// @dev Called by AsyncDelivery after executing callback with proper gas accounting
    /// @param jobId The job identifier
    /// @param input The precompile input (SC-2: passed via calldata, verified by hash)
    /// @param success Whether the callback execution succeeded
    function markDelivered(bytes32 jobId, bytes calldata input, bool success) external;

    /// @notice Get input hash and size for a job (SC-2)
    /// @param jobId The job identifier
    /// @return hash The keccak256 hash of the input
    /// @return size The size in bytes of the input
    function getInputHash(bytes32 jobId) external view returns (bytes32 hash, uint256 size);

    /// @notice Get txRlp hash and size for a job (SC-2)
    /// @param jobId The job identifier
    /// @return hash The keccak256 hash of the txRlp
    /// @return size The size in bytes of the txRlp
    function getTxRlpHash(bytes32 jobId) external view returns (bytes32 hash, uint256 size);
}
