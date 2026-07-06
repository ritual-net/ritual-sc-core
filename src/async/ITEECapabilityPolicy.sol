// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFlashtestationRegistry} from "flashtestations/interfaces/IFlashtestationRegistry.sol";
import {TD10ReportBody} from "automata-dcap-attestation/contracts/types/TDXStruct.sol";
import {IBasePolicy} from "flashtestations/interfaces/IBasePolicy.sol";
import {IPolicyCommon, WorkloadId} from "flashtestations/interfaces/IPolicyCommon.sol";

/**
 * @title ITEECapabilityPolicy
 * @dev Interface for managing TEE service capabilities and workload policies.
 *      This policy defines what capabilities each TEE workload is authorized to provide.
 *      A single workload can have MULTIPLE capabilities bound to it.
 *      Extends IBasePolicy for shared policy surface (WorkloadMetadata, add/remove workload, etc.)
 */
interface ITEECapabilityPolicy is IBasePolicy {
    // ============ Types ============

    /// @notice Enumerates the capabilities/service types supported by TEE services
    /// @dev This enum identifies what type of service a TEE provides:
    ///      - HTTP_CALL (0): Executor with HTTP call capability
    ///      - LLM (1): Executor with LLM inference capability.
    ///      - WORMHOLE_QUERY (2): Executor with Wormhole query capability
    ///      - STREAMING (3): Streaming relay service
    ///      - VLLM_PROXY (4): vLLM inference proxy service
    ///      - ZK_CALL (5): Executor with ZK two-phase computation capability
    ///      - DKMS (6): Distributed Key Management Service
    ///      - IMAGE_CALL (7): Executor with image generation capability (0x0818 precompile)
    ///      - AUDIO_CALL (8): Executor with audio generation capability (0x0819 precompile)
    ///      - VIDEO_CALL (9): Executor with video generation capability (0x081A precompile)
    ///      - FHE (10): Executor with FHE (CKKS) homomorphic encryption inference capability (0x0807 precompile)
    ///      - TELEMETRY (11): Agent telemetry ingestion/query service
    /// @notice Sovereign Agent calls (0x080C) can route through HTTP or LLM executors.
    enum Capability {
        HTTP_CALL,
        LLM,
        WORMHOLE_QUERY,
        STREAMING,
        VLLM_PROXY,
        ZK_CALL,
        DKMS,
        IMAGE_CALL,
        AUDIO_CALL,
        VIDEO_CALL,
        FHE,
        TELEMETRY
    }

    /**
     * @notice Capability binding metadata for multi-capability support
     * @dev A workload can have multiple capabilities bound to it
     */
    struct CapabilityInfo {
        Capability[] capabilities;
        bool exists;
    }

    // ============ Events ============
    // WorkloadAddedToPolicy, WorkloadRemovedFromPolicy, RegistrySet inherited from IBasePolicy

    /// @notice Emitted when a capability is bound to a workload
    /// @param workloadId The workload identifier
    /// @param capability The capability assigned to the workload
    event WorkloadCapabilitySet(bytes32 indexed workloadId, Capability indexed capability);
    /// @notice Emitted when a capability binding is cleared
    /// @param workloadId The workload identifier that lost its capability binding
    /// @param capability The capability that is now unassigned
    event WorkloadCapabilityCleared(bytes32 indexed workloadId, Capability indexed capability);

    // ============ Errors ============
    // InvalidRegistry, WorkloadAlreadyInPolicy, WorkloadNotInPolicy, EmptyCommitHash, EmptySourceLocators inherited from IPolicyCommon

    /// @notice Emitted when a TEE-controlled address is not authorized under any approved workload
    error TEEServiceNotApproved(address teeAddress); // 0xe741f071
    /// @notice Emitted when the nonce is invalid
    error InvalidNonce(uint256 expected, uint256 provided); // 0x06427aeb
    /// @notice Emitted when attempting to assign a capability to an unknown workload
    error WorkloadNotApproved(bytes32 workloadId); // 0x4e405a25
    /// @notice Emitted when attempting to approve or bind the reserved zero workload ID
    error InvalidWorkloadId();
    /// @notice Emitted when the capability requested is already bound to a different workload
    error CapabilityAlreadyAssigned(); // 0x301e34c5
    /// @notice Emitted when the workload already has this specific capability bound
    error CapabilityAlreadyBoundToWorkload(); // 0xeede596e
    /// @notice Emitted when clearing a workload capability that is not set
    error WorkloadCapabilityNotFound(); // 0xaf2f078c
    /// @notice The workload deriver is missing the required workloadIdForReportBody method
    error DeriverMissingWorkloadIdForReportBody();

    // ============ Functions ============

    /// @notice Initializer to set the FlashtestationRegistry contract which verifies TEE quotes and the initial owner of the contract
    /// @param _initialOwner The address of the initial owner of the contract
    /// @param _registry The address of the registry contract
    /// @param _workloadDeriver The address of the workload deriver contract (e.g. TDXWorkloadDeriver)
    function initialize(address _initialOwner, address _registry, address _workloadDeriver) external;

    /// @notice Add a workload to a policy (governance only)
    /// @notice Only the owner of this contract can add workloads to the policy
    /// and it is the responsibility of the owner to ensure that the workload is valid
    /// otherwise the address associated with this workload has full power to do anything
    /// who's authorization is based on this policy
    /// @dev The commitHash metadata solves the following problem; The only way for a smart contract like BlockBuilderPolicy
    /// to verify that a TEE (identified by its workloadId) is running a specific piece of code (for instance,
    /// op-rbuilder) is to reproducibly build that workload onchain. This is prohibitively expensive, so instead
    /// we rely on a permissioned multisig (the owner of this contract) to add a commit hash to the policy whenever
    /// it adds a new workloadId. We're already relying on the owner to verify that the workloadId is valid, so
    /// we can also assume the owner will not add a commit hash that is not associated with the workloadId. If
    /// the owner did act maliciously, this can easily be determined offchain by an honest actor building the
    /// TEE image from the given commit hash, deriving the image's workloadId, and then comparing it to the
    /// workloadId stored on the policy that is associated with the commit hash. If the workloadId is different,
    /// this can be used to prove that the owner acted maliciously. In the honest case, this Policy serves as a
    /// source of truth for which source code of build software (i.e. the commit hash) is used to build the TEE image
    /// identified by the workloadId.
    /// @param workloadId The workload identifier
    /// @param commitHash The 40-character hexadecimal commit hash of the git repository
    /// whose source code is used to build the TEE image identified by the workloadId
    /// @param sourceLocators An array of URIs pointing to the source code
    function addWorkloadToPolicy(WorkloadId workloadId, string calldata commitHash, string[] calldata sourceLocators)
        external;

    /// @notice Remove a workload from a policy (governance only)
    /// @param workloadId The workload identifier
    function removeWorkloadFromPolicy(WorkloadId workloadId) external;

    /// @notice Bind a capability to a workload (governance only)
    /// @dev This can be called multiple times to add multiple capabilities to a workload
    /// @param workloadId The workload identifier to bind
    /// @param capability The capability to associate with the workload
    function setCapabilityForWorkload(WorkloadId workloadId, Capability capability) external;

    /// @notice Clear a specific capability binding for a workload (governance only)
    /// @param workloadId The workload identifier whose capability binding should be removed
    /// @param capability The specific capability to remove
    function clearCapabilityForWorkload(WorkloadId workloadId, Capability capability) external;

    // ============ View Functions ============

    /// @notice Check if this TEE-controlled address is approved to provide a specific capability
    /// @param teeAddress The TEE-controlled address
    /// @param capability The capability being requested
    /// @return allowed True if the TEE is running an approved workload bound to the capability
    /// @return workloadId The workloadId associated with the TEE, or 0 if the capability is not allowed
    function isAllowedPolicy(address teeAddress, Capability capability)
        external
        view
        returns (bool, WorkloadId workloadId);

    /// @notice State-changing policy check that uses cache for gas savings.
    /// @dev Use in state-changing contexts (e.g. registration). For view contexts, use isAllowedPolicy instead.
    /// @param teeAddress The TEE-controlled address
    /// @param capability The capability being requested
    /// @return allowed True if the TEE is running an approved workload bound to the capability
    /// @return workloadId The workloadId associated with the TEE, or 0 if the capability is not allowed
    function checkPolicyAndCache(address teeAddress, Capability capability)
        external
        returns (bool, WorkloadId workloadId);

    /// @notice Check if a workload has a specific capability bound
    /// @param workloadId The workload identifier
    /// @param capability The capability to check
    /// @return True if the workload has this capability bound
    function hasCapability(WorkloadId workloadId, Capability capability) external view returns (bool);

    /// @notice Calculates the mapping of registration data to a workload identifier
    /// @dev Think of the workload identifier as the version of the application for governance.
    /// The workloadId verifiably maps to a version of source code that builds the TEE VM image
    /// @param registration The registration data from a TEE device
    /// @return workloadId The computed workload identifier
    function workloadIdForTDRegistration(IFlashtestationRegistry.RegisteredTEE memory registration)
        external
        view
        returns (WorkloadId);

    /// @notice Calculates the workload identifier directly from a parsed TD10 report body
    /// @param body The parsed report body produced by Flashtestations quote parsing utilities
    /// @return workloadId The computed workload identifier
    function workloadIdForReportBody(TD10ReportBody memory body) external view returns (WorkloadId);

    /// @notice Returns all capabilities associated with a workload
    /// @param workloadId The workload identifier being queried
    /// @return info Struct containing the capabilities array and existence flag
    function getCapabilityForWorkload(WorkloadId workloadId) external view returns (CapabilityInfo memory info);

    /// @notice Returns all workloads bound to a capability
    /// @param capability The capability being queried
    /// @return workloadIds Array of workload identifiers bound to the capability
    function getWorkloadsForCapability(Capability capability) external view returns (WorkloadId[] memory workloadIds);

    // registry() inherited from IBasePolicy
}
