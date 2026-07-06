// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.28;

import {ITEECapabilityPolicy} from "./ITEECapabilityPolicy.sol";

/**
 * @title ITEEServiceRegistry
 * @notice Unified registry interface for all TEE-based services in the Ritual Network
 * @dev Supports Executors, vLLM Proxies, and Streaming Services with mTLS certificate verification.
 *      This contract unifies ExecutorRegistry and StreamingServiceRegistry into a single
 *      registry with consistent patterns for all TEE service types.
 */
interface ITEEServiceRegistry {
    // ============ Types ============

    /// @notice Type of Trusted Execution Environment
    enum TeeType {
        DEBUG,
        TDX
    }

    /// @notice TEE service node data stored on-chain
    /// @dev The capability field identifies what type of service this is:
    ///      - HTTP_CALL, LLM, WORMHOLE_QUERY, ZK_CALL: Executor services
    ///      - STREAMING: Streaming relay service
    ///      - VLLM_PROXY: vLLM inference proxy service
    ///      - DKMS: Distributed Key Management Service
    struct TEEServiceNode {
        address paymentAddress; // Address that receives payments
        address teeAddress; // TEE-controlled address (cryptographic identity from attestation)
        TeeType teeType; // Type of TEE (DEBUG or TDX)
        bytes executorSecretsAuthPublicKey; // Executor-only public key for secrets/auth; empty for other services
        string endpoint; // Service URL (http://, https://, or wss://)
        // SHA256 hash of X.509 SubjectPublicKeyInfo for the TLS certificate public key.
        bytes32 mTlsSpkiHash;
        ITEECapabilityPolicy.Capability capability; // What capability/service type this is
    }

    /// @notice Extended context for service queries
    struct TEEServiceContext {
        TEEServiceNode node;
        bool isValid; // True if attestation is still valid
        bytes32 workloadId; // Derived workload identifier
    }

    // ============ Events ============

    /// @notice Emitted when a TEE service is registered
    event ServiceRegistered(
        address indexed paymentAddress,
        address indexed teeAddress,
        TeeType teeType,
        ITEECapabilityPolicy.Capability capability,
        bytes32 workloadId,
        string endpoint,
        bytes executorSecretsAuthPublicKey,
        bytes32 mTlsSpkiHash
    );

    /// @notice Emitted when a TEE service updates its registration
    event ServiceUpdated(
        address indexed paymentAddress,
        address indexed teeAddress,
        TeeType teeType,
        ITEECapabilityPolicy.Capability capability,
        bytes32 workloadId,
        string endpoint,
        bytes executorSecretsAuthPublicKey,
        bytes32 mTlsSpkiHash
    );

    /// @notice Emitted when a TEE service goes offline
    /// @param teeAddress The TEE address of the service that went offline
    /// @param capability The service capability that was removed from the online set
    event ServiceWentOffline(address indexed teeAddress, ITEECapabilityPolicy.Capability capability);

    /// @notice Emitted when the Flashtestation registry is set
    event FlashtestationRegistrySet(address indexed registry);

    /// @notice Emitted when the capability policy is set
    event CapabilityPolicySet(address indexed policy);

    /// @notice Emitted when the whitelist registry is set
    event WhitelistRegistrySet(address indexed whitelistRegistry);

    // ============ Errors ============

    /// @notice Thrown when a service is not found
    error ServiceNotFound(address addr);

    /// @notice Thrown when a service is already offline
    error ServiceAlreadyOffline(address addr);

    /// @notice Thrown when payment address is invalid (zero) for a service that requires it
    error InvalidPaymentAddress();

    /// @notice Thrown when TEE address is invalid (zero)
    error InvalidTeeAddress();

    /// @notice Thrown when endpoint is invalid (empty or too long) for services that require it
    error InvalidEndpoint();

    /// @notice Thrown when mTLS SPKI hash is invalid (zero) - all services require cert public key hash for mTLS
    error InvalidMTlsSpkiHash();

    /// @notice Thrown when executor secrets/auth key is not 65-byte uncompressed secp256k1 public key bytes
    error InvalidExecutorSecretsAuthPublicKey();

    /// @notice Thrown when Flashtestation registry is not set
    error FlashtestationRegistryNotSet();

    /// @notice Thrown when signature deadline has passed
    error InvalidSignatureDeadline(uint256 deadline);

    /// @notice Thrown when permit registration fails
    error PermitRegistrationFailed();

    /// @notice Thrown when recovered TEE address doesn't match provided address
    error TeeAddressMismatch(address expected, address actual);

    /// @notice Thrown when msg.sender is not the TEE address being registered
    /// @dev The TEE must register itself - third parties cannot register on behalf of a TEE
    error SenderNotTeeAddress(address sender, address teeAddress);

    /// @notice Thrown when msg.sender is not the payment address for the service being taken offline
    error UnauthorizedPaymentAddress(address sender, address teeAddress);

    /// @notice Thrown when maximum number of services is reached
    error MaxServicesReached();

    /// @notice Thrown when workload is not approved by capability policy (executors only)
    error WorkloadNotApproved();

    /// @notice Thrown when capability doesn't match expected capability for an operation
    error InvalidCapability(ITEECapabilityPolicy.Capability expected, ITEECapabilityPolicy.Capability actual);

    /// @notice Thrown when the caller is not whitelisted for executor registration
    error NotWhitelisted(address addr);

    /// @notice Thrown when attestation is invalid or expired according to flashtestation registry
    /// @dev The flashtestation registry is the anchor of trust for all attestation validity checks
    error AttestationInvalid(address teeAddress);

    /// @notice Thrown when an unknown capability value is provided during registration
    error UnknownCapabilityValue(uint8 value);
    /// @notice Thrown when capability indexing has already been finalized
    error CapabilityIndexAlreadyFinalized();
    /// @notice Thrown when capability indexing has not been finalized
    error CapabilityIndexNotFinalized();
    /// @notice Thrown when reindex chunk size is zero
    error InvalidReindexChunkSize();
    /// @notice Thrown when finalization is attempted before full reindex completion
    error CapabilityIndexIncomplete(uint256 cursor, uint256 total);
    /// @notice Thrown when indexed capability access uses an out-of-range index
    error InvalidIndexedServiceIndex(uint256 index, uint256 length);

    // ============ External Functions ============

    /// @notice Set the Flashtestation registry address (owner only)
    /// @param _registry The address of the Flashtestation registry contract
    function setFlashtestationRegistry(address _registry) external;

    /// @notice Set the capability policy address (owner only)
    /// @param _policy The address of the TEECapabilityPolicy contract
    function setCapabilityPolicy(address _policy) external;

    /// @notice Set the whitelist registry address (owner only)
    /// @param _whitelistRegistry The address of the TeeServiceWhitelist contract
    /// @dev Set to address(0) to disable whitelist checks
    function setWhitelistRegistry(address _whitelistRegistry) external;

    /// @notice Register a TDX executor using EIP-712 permit signature
    /// @param teeAddress The attested TEE address (derived from the quote)
    /// @param paymentAddress The address where the executor receives payments
    /// @param executorSecretsAuthPublicKey Executor-only 65-byte uncompressed secp256k1 public key used for job secrets/auth
    /// @param endpoint The HTTP endpoint URL (e.g., "http://executor.example.com:3000") - can be empty
    /// @param mTlsSpkiHash SHA256 hash of the X.509 SPKI / TLS certificate public key for mTLS
    /// @param tdxQuote The TDX quote data containing the TEE attestation
    /// @param nonce The nonce for replay protection
    /// @param deadline The timestamp after which the signature expires
    /// @param teeSignature The EIP-712 signature from the TEE address
    function registerTdxExecutorWithPermit(
        address teeAddress,
        address paymentAddress,
        bytes calldata executorSecretsAuthPublicKey,
        string calldata endpoint,
        bytes32 mTlsSpkiHash,
        bytes calldata tdxQuote,
        uint256 nonce,
        uint256 deadline,
        bytes calldata teeSignature
    ) external payable;

    /// @notice Register a TDX streaming service using EIP-712 permit signature
    /// @param teeAddress The attested TEE address (derived from the quote)
    /// @param paymentAddress The address where the service receives payments
    /// @param endpoint The WebSocket endpoint URL (e.g., "wss://streaming.example.com:8443")
    /// @param mTlsSpkiHash SHA256 hash of the X.509 SPKI / TLS certificate public key for mTLS
    /// @param tdxQuote The TDX quote data containing the TEE attestation
    /// @param nonce The nonce for replay protection
    /// @param deadline The timestamp after which the signature expires
    /// @param teeSignature The EIP-712 signature from the TEE address
    function registerTdxStreamingServiceWithPermit(
        address teeAddress,
        address paymentAddress,
        string calldata endpoint,
        bytes32 mTlsSpkiHash,
        bytes calldata tdxQuote,
        uint256 nonce,
        uint256 deadline,
        bytes calldata teeSignature
    ) external payable;

    /// @notice Register a TDX vLLM proxy using EIP-712 permit signature
    /// @param teeAddress The attested TEE address (derived from the quote)
    /// @param paymentAddress The address where the service receives payments
    /// @param endpoint The HTTPS endpoint URL (e.g., "https://vllm.example.com:8443")
    /// @param mTlsSpkiHash SHA256 hash of the X.509 SPKI / TLS certificate public key for mTLS
    /// @param tdxQuote The TDX quote data containing the TEE attestation
    /// @param nonce The nonce for replay protection
    /// @param deadline The timestamp after which the signature expires
    /// @param teeSignature The EIP-712 signature from the TEE address
    function registerTdxVllmProxyWithPermit(
        address teeAddress,
        address paymentAddress,
        string calldata endpoint,
        bytes32 mTlsSpkiHash,
        bytes calldata tdxQuote,
        uint256 nonce,
        uint256 deadline,
        bytes calldata teeSignature
    ) external payable;

    /// @notice Register a TDX dKMS (Distributed Key Management Service) using EIP-712 permit signature
    /// @param teeAddress The attested TEE address (derived from the quote)
    /// @param paymentAddress The address where the dKMS receives payments
    /// @param endpoint The HTTPS endpoint URL (e.g., "https://dkms.example.com:8443")
    /// @param mTlsSpkiHash SHA256 hash of the X.509 SPKI / TLS certificate public key for mTLS
    /// @param tdxQuote The TDX quote data containing the TEE attestation
    /// @param nonce The nonce for replay protection
    /// @param deadline The timestamp after which the signature expires
    /// @param teeSignature The EIP-712 signature from the TEE address
    function registerTdxDkmsWithPermit(
        address teeAddress,
        address paymentAddress,
        string calldata endpoint,
        bytes32 mTlsSpkiHash,
        bytes calldata tdxQuote,
        uint256 nonce,
        uint256 deadline,
        bytes calldata teeSignature
    ) external payable;

    /// @notice Register a TDX agent telemetry service using EIP-712 permit signature
    /// @param teeAddress The attested TEE address (derived from the quote)
    /// @param paymentAddress The address where the service receives payments
    /// @param endpoint The HTTP endpoint URL (e.g., "http://telemetry.example.com:8088")
    /// @param mTlsSpkiHash SHA256 hash of the X.509 SPKI / TLS certificate public key for mTLS
    /// @param tdxQuote The TDX quote data containing the TEE attestation
    /// @param nonce The nonce for replay protection
    /// @param deadline The timestamp after which the signature expires
    /// @param teeSignature The EIP-712 signature from the TEE address
    function registerTdxTelemetryServiceWithPermit(
        address teeAddress,
        address paymentAddress,
        string calldata endpoint,
        bytes32 mTlsSpkiHash,
        bytes calldata tdxQuote,
        uint256 nonce,
        uint256 deadline,
        bytes calldata teeSignature
    ) external payable;

    /// @notice Mark a specific service as offline
    /// @dev Callable only by the payment address registered for the provided TEE address
    /// @param teeAddress The TEE address of the service to remove
    function markServiceOffline(address teeAddress) external;

    /// @notice Owner-only function to forcibly remove a dead/stale service
    /// @dev Used to clean up orphaned registrations when executors crash and lose their attestations expire.
    ///      Go executors generate registration keys at runtime and cannot recover them after restart.
    /// @param teeAddress The TEE address of the service to remove
    function forceServiceOffline(address teeAddress) external;

    /// @notice Reset capability indexes before running reindex migration (owner only)
    function resetCapabilityIndex() external;

    /// @notice Reindex existing services into capability indexes in bounded chunks (owner only)
    /// @param maxItems Maximum number of canonical services to process in this call
    /// @return processed Number of items processed in this chunk
    /// @return done True when reindex cursor has reached the canonical service count
    function reindexCapabilityIndex(uint256 maxItems) external returns (uint256 processed, bool done);

    /// @notice Finalize capability indexing once reindex is complete (owner only)
    function finalizeCapabilityIndex() external;

    // ============ View Functions ============
    //
    // ⚠️  ATTESTATION VALIDITY: SAFE BY DEFAULT
    //
    // All getters have an optional `checkValidity` flag that defaults to true (secure).
    // - When checkValidity=true (default): reverts with AttestationInvalid if attestation is invalid
    // - When checkValidity=false: returns service regardless of validity, caller must check isValid field
    //
    // Use checkValidity=false only for debugging, monitoring, or inspecting invalid services.

    // ============ Generic Service Queries ============

    /// @notice Get service context for an address (checks validity by default)
    /// @dev Reverts with AttestationInvalid if the service's attestation is no longer valid
    /// @param addr The TEE address of the service
    /// @return context The service context (guaranteed valid attestation)
    function getService(address addr) external view returns (TEEServiceContext memory context);

    /// @notice Get service context for an address with explicit validity check control
    /// @dev When checkValidity=false, returns service even if attestation is invalid - caller must check isValid!
    /// @param addr The TEE address of the service
    /// @param checkValidity If true, reverts on invalid attestation; if false, returns with isValid=false
    /// @return context The service context
    function getService(address addr, bool checkValidity) external view returns (TEEServiceContext memory context);

    /// @notice Get all services with a specific capability (with valid attestations by default)
    /// @param capability The capability to filter by
    /// @return contexts Array of service contexts (all with valid attestations)
    function getServicesByCapability(ITEECapabilityPolicy.Capability capability)
        external
        view
        returns (TEEServiceContext[] memory contexts);

    /// @notice Get all services with a specific capability with explicit validity check control
    /// @param capability The capability to filter by
    /// @param checkValidity If true, only returns valid services; if false, returns all online services
    /// @return contexts Array of service contexts
    function getServicesByCapability(ITEECapabilityPolicy.Capability capability, bool checkValidity)
        external
        view
        returns (TEEServiceContext[] memory contexts);

    /// @notice Returns migration state for capability indexing
    /// @return cursor Current reindex cursor in canonical service array
    /// @return total Total canonical service count
    /// @return initialized Whether capability index state has been initialized/reset
    /// @return finalized Whether capability indexing is finalized for production lookups
    function getCapabilityIndexStatus()
        external
        view
        returns (uint256 cursor, uint256 total, bool initialized, bool finalized);

    /// @notice Get indexed service count for a capability (requires finalized index)
    function getIndexedServiceCountByCapability(ITEECapabilityPolicy.Capability capability)
        external
        view
        returns (uint256 count);

    /// @notice Get indexed service by capability and index (requires finalized index)
    function getIndexedServiceByCapabilityAt(ITEECapabilityPolicy.Capability capability, uint256 index)
        external
        view
        returns (address teeAddress);

    /// @notice Pick a capability-matched service using a bounded probe window over indexed storage
    /// @param capability Capability to match
    /// @param checkValidity Whether to require attestation/policy validity
    /// @param seed Selection seed used to pick start index
    /// @param maxProbes Maximum number of probes
    /// @return teeAddress Picked TEE address, or zero when no match found in probe window
    /// @return found True when a matching service is found
    function pickServiceByCapability(
        ITEECapabilityPolicy.Capability capability,
        bool checkValidity,
        uint256 seed,
        uint256 maxProbes
    ) external view returns (address teeAddress, bool found);

    // ============ mTLS SPKI Hash Queries ============

    /// @notice Get mTLS SPKI hash for a TEE address (checks validity by default)
    /// @dev Reverts with AttestationInvalid if the service's attestation is no longer valid
    /// @param teeAddress The TEE address to query
    /// @return The SHA256 hash of the X.509 SPKI / TLS certificate public key
    function getMTlsSpkiHashForAddress(address teeAddress) external view returns (bytes32);

    /// @notice Get mTLS SPKI hash for a TEE address with explicit validity check control
    /// @param teeAddress The TEE address to query
    /// @param checkValidity If true, reverts on invalid attestation; if false, returns regardless
    /// @return The SHA256 hash of the X.509 SPKI / TLS certificate public key
    function getMTlsSpkiHashForAddress(address teeAddress, bool checkValidity) external view returns (bytes32);

    // ============ Flashtestation Helper Functions ============

    /// @notice Get the current nonce for a TEE address
    /// @param teeAddress The TEE address to query
    /// @return The current nonce for EIP-712 signatures
    function getFlashtestationTeeNonce(address teeAddress) external view returns (uint256);

    /// @notice Get the domain separator from Flashtestation registry
    /// @return The EIP-712 domain separator
    function getFlashtestationDomainSeparator() external view returns (bytes32);

    /// @notice Get the EIP-712 type hash from Flashtestation registry
    /// @return The REGISTER_TYPEHASH for permit signatures
    function getFlashtestationRegisterTypehash() external view returns (bytes32);

    /// @notice Compute the struct hash for EIP-712 permit signature
    /// @param tdxQuote The TDX quote data
    /// @param extendedRegistrationData Additional registration data
    /// @param nonce The nonce for replay protection
    /// @param deadline The signature expiration timestamp
    /// @return The computed struct hash
    function computeFlashtestationPermitStructHash(
        bytes calldata tdxQuote,
        bytes calldata extendedRegistrationData,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32);

    /// @notice Compute the full EIP-712 digest for permit signature
    /// @param tdxQuote The TDX quote data
    /// @param extendedRegistrationData Additional registration data
    /// @param nonce The nonce for replay protection
    /// @param deadline The signature expiration timestamp
    /// @return The computed EIP-712 digest
    function computeFlashtestationPermitDigest(
        bytes calldata tdxQuote,
        bytes calldata extendedRegistrationData,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32);

    // ============ Payment Address Lookup ============

    /// @notice Get payment address for a TEE address
    /// @dev Used by EL node to route payments to the correct address
    ///      Returns zero if attestation is no longer valid (does not revert)
    /// @param teeAddress The TEE (registration) address
    /// @return paymentAddress The payment address for this service (or zero if not found or attestation invalid)
    function getPaymentAddressForTeeAddress(address teeAddress) external view returns (address paymentAddress);

    /// @notice Get payment address for a TEE address with explicit validity check control
    /// @param teeAddress The TEE (registration) address
    /// @param checkValidity If true, returns zero on invalid attestation; if false, returns regardless
    /// @return paymentAddress The payment address for this service
    function getPaymentAddressForTeeAddress(address teeAddress, bool checkValidity)
        external
        view
        returns (address paymentAddress);
}
