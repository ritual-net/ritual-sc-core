// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.28;

interface IAgentHeartbeat {
    // ============ Types ============

    enum SlotState {
        VACANT,
        ACTIVE
    }

    enum RevivalStatus {
        NONE,
        FAILED,
        REVIVING
    }

    /// @notice AgentId-keyed holder assignment for one persistent-agent runtime.
    /// @dev "Slot" means `agentId -> active holder assignment` in this contract.
    ///      It is not an executor-capacity slot. `SlotAssignment` is retained as
    ///      the stable ABI name; protocol docs may describe the same record as an
    ///      agent holder assignment or active agent binding.
    struct SlotAssignment {
        SlotState state;
        RevivalStatus revivalStatus;
        address agentAddress;
        bytes32 boundHolderKey;
        address boundExecutor;
        uint64 lastHeartbeat;
        uint64 heartbeatTimeout;
        uint64 cooldownEnd;
        string latestManifestCID;
        bytes encryptedDAConfig;
    }

    // ============ Events ============

    event SlotClaimed(
        uint256 indexed agentId,
        address indexed agentAddress,
        address indexed executor,
        bytes32 holderKey,
        address identityOwner
    );
    event SlotHeartbeat(uint256 indexed agentId, address indexed agentAddress, uint64 blockNumber, string manifestCID);
    event SlotRecalled(uint256 indexed agentId, address indexed agentAddress, address indexed recalledBy);
    event SlotVacated(uint256 indexed agentId, address indexed agentAddress, string reason);
    event SlotReplaced(
        uint256 indexed agentId,
        address indexed previousAgentAddress,
        address indexed replacementAgentAddress,
        address previousExecutor,
        uint64 lastHeartbeat,
        uint64 detectedAt,
        string latestManifestCID,
        bytes encryptedDAConfig,
        string reason
    );
    event SlotRevivalQueued(
        uint256 indexed agentId, address indexed agentAddress, uint64 lastHeartbeat, uint64 detectedAt
    );
    event SlotRevivalInitiated(
        uint256 indexed agentId, address indexed agentAddress, string manifestCID, address executor, uint64 cooldownEnd
    );
    event SlotRevivalFailed(uint256 indexed agentId, address indexed agentAddress, string reason);
    event SlotRemoved(uint256 indexed agentId, address indexed agentAddress, string reason);

    // ============ Step 3: agentId-keyed lifecycle (authoritative holder assignment) ============

    function claim(
        uint256 agentId,
        bytes32 holderKey,
        address executor,
        bytes calldata executorSignature,
        bytes calldata encryptedDAConfig
    ) external;

    function heartbeat(uint256 agentId, string calldata manifestCID, bytes calldata executorSignature) external payable;

    function recall(uint256 agentId) external;

    function getAssignment(uint256 agentId) external view returns (SlotAssignment memory);

    function getAssignmentState(uint256 agentId) external view returns (SlotState);

    // ============ Protocol operations (SYSTEM_SENDER only) ============

    function shouldCheck() external view returns (bool);
    function checkAndRevive() external;
    function reviveAgent(uint256 agentId, bytes calldata precompileInput) external;
    function getAgentIdsNeedingRevival() external view returns (uint256[] memory);

    // ============ Views ============

    function trackedAgentCount() external view returns (uint256);
    function trackedAgentIdAt(uint256 index) external view returns (uint256);
    function hasActionableAgents() external view returns (bool);
    function slotNonce(uint256 agentId) external view returns (uint256);
    function revivalAttempts(uint256 agentId) external view returns (uint64);
    function MAX_REVIVAL_ATTEMPTS() external view returns (uint64);
    function heartbeatIntervalDivisor() external view returns (uint64);
    function heartbeatIntervalBlocks() external view returns (uint64);

    // ============ Admin ============

    function setDefaultTimeout(uint64 timeout) external;
    function setHeartbeatIntervalDivisor(uint64 divisor) external;
    function setRevivalCooldown(uint64 cooldown) external;
    function adminRemoveAgent(uint256 agentId) external;
}
