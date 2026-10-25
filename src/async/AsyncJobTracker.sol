// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.28;

import {IRitualWallet} from "../wallet/IRitualWallet.sol";
import {ISchedulerAsyncBridge} from "../scheduler/interfaces/ISchedulerAsyncBridge.sol";
import {ITEECapabilityPolicy} from "./ITEECapabilityPolicy.sol";
import {ITEEServiceRegistry} from "./ITEEServiceRegistry.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/**
 * @title AsyncJobTracker - Optimized Async Transaction Job Management
 * @notice Manages pending jobs with O(1) operations and batch expiry cleanup
 * @dev Requirements: 10k cap, 10KB limit, expiry buckets, O(1) ops, threshold cleanup
 *      Payment V2 is a fresh-deployment-only storage layout. It is not
 *      backwards-compatible with prior AsyncJobTracker proxy storage.
 */
contract AsyncJobTracker is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    address public constant ASYNC_COMMITMENT_SYSTEM_CALLER = 0x000000000000000000000000000000000000Fa8e;

    // REQUIREMENT: 10,000 hard cap
    uint256 public constant MAX_PENDING_JOBS = 10_000;
    uint256 public constant CLEANUP_TRIGGER = 5000;
    uint256 public constant CLEANUP_INTERVAL = 30;
    uint256 public constant MAX_CLEANUP_BUCKETS = 64;

    /// @dev Caps the number of jobs removed per cleanup call to bound gas usage.
    uint256 public constant MAX_CLEANUP_PER_CALL = 25;

    // REQUIREMENT: 10KB input limit (FHE with DA layer requires ~7KB for encrypted storage credentials)
    uint256 public constant MAX_INPUT_SIZE = 10 * 1024;

    // HTTP Call precompile (0x0801) - single-phase, no delivery fee fields
    address public constant HTTP_CALL_PRECOMPILE = 0x0000000000000000000000000000000000000801;

    // LLM Call precompile (0x0802) - single-phase, no delivery fee fields
    address public constant LLM_CALL_PRECOMPILE = 0x0000000000000000000000000000000000000802;

    // Long-running HTTP precompile (0x0805) - two-phase with delivery fee fields
    address public constant LONG_RUNNING_HTTP_PRECOMPILE = 0x0000000000000000000000000000000000000805;

    // ZK Two-Phase precompile (0x0806)
    address public constant ZK_TWO_PHASE_PRECOMPILE = 0x0000000000000000000000000000000000000806;

    // FHE precompile (0x0807) - long-running, Phase 1 returns job_id, Phase 2 delivers encrypted result
    address public constant FHE_PRECOMPILE = 0x0000000000000000000000000000000000000807;

    // Sovereign Agent precompile (0x080C) - long-running Sovereign Agent, Phase 1 returns task_id
    address public constant SOVEREIGN_AGENT_PRECOMPILE = 0x000000000000000000000000000000000000080C;

    // Image call precompile (0x0818) - long-running T2I, Phase 1 returns job_id
    address public constant IMAGE_CALL_PRECOMPILE = 0x0000000000000000000000000000000000000818;

    // Audio call precompile (0x0819) - long-running T2A, Phase 1 returns job_id
    address public constant AUDIO_CALL_PRECOMPILE = 0x0000000000000000000000000000000000000819;

    // Video call precompile (0x081A) - long-running T2V, Phase 1 returns job_id
    address public constant VIDEO_CALL_PRECOMPILE = 0x000000000000000000000000000000000000081A;

    // DKMS Key precompile (0x081B) - single-phase, no delivery fee fields
    address public constant DKMS_KEY_PRECOMPILE = 0x000000000000000000000000000000000000081B;

    // Persistent Agent precompile (0x0820) - spawns OpenClaw AI agent instances via claw-spawner
    address public constant PERSISTENT_AGENT_PRECOMPILE = 0x0000000000000000000000000000000000000820;

    /// @dev Maximum TTL (time-to-live) allowed for async commitments in blocks.
    /// Must match the reth-side DEFAULT_MAX_TTL_BLOCKS in ritual-async-inspector.
    uint256 public constant MAX_TTL_BLOCKS = 500;

    /// @dev Maximum offset (in blocks) allowed for Phase 2 deadline.
    /// Prevents users from setting unreasonably far future deadlines.
    /// 70,000 blocks ≈ 4 hours at 200ms block time.
    uint256 public constant MAX_PHASE2_DEADLINE_OFFSET = 70_000;

    uint256 private constant ABI_WORD_SIZE = 32;
    uint256 private constant DELIVERY_CONFIG_SIZE = 3 * ABI_WORD_SIZE;
    uint256 private constant DELIVERY_MAX_FEE_FIELD_OFFSET_FROM_TARGET = 3;

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLE
    //////////////////////////////////////////////////////////////*/

    /// @notice AsyncDelivery contract — sole authorized caller for settlement state transitions
    address public immutable ASYNC_DELIVERY;

    /// @notice RitualWallet used for atomic per-job escrow reservation.
    IRitualWallet public immutable ritualWallet;

    /// @notice TEE registry used to validate selected async executors before job admission.
    ITEEServiceRegistry public immutable TEE_SERVICE_REGISTRY;

    error InvalidExecutor(address executor);
    error InvalidExecutorCapability(address executor, address precompile, ITEECapabilityPolicy.Capability capability);

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyCommitmentCaller() {
        require(msg.sender == ASYNC_COMMITMENT_SYSTEM_CALLER, "only commitment caller");
        _;
    }

    modifier onlyAsyncDelivery() {
        require(msg.sender == ASYNC_DELIVERY, "only AsyncDelivery");
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _asyncDelivery, address _ritualWallet, address _teeServiceRegistry) {
        _disableInitializers();
        ASYNC_DELIVERY = _asyncDelivery;
        ritualWallet = IRitualWallet(_ritualWallet);
        TEE_SERVICE_REGISTRY = ITEEServiceRegistry(_teeServiceRegistry);
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize the AsyncJobTracker with an owner
    /// @param _owner The address that will own the contract (for upgrade authorization)
    function initialize(address _owner) external initializer {
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
    }

    /// @notice Restricts upgrades to owner only
    /// @param newImplementation The address of the new implementation contract
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /*//////////////////////////////////////////////////////////////
                            STORAGE (OPTIMIZED)
    //////////////////////////////////////////////////////////////*/

    // Expiry bucket system (REQUIREMENT)
    mapping(uint256 => bytes32[]) private expiryBuckets;
    mapping(bytes32 => uint256) private bucketIndex;
    mapping(bytes32 => uint256) private expiryBlock;

    // Primary storage
    mapping(bytes32 => Job) private jobs;
    mapping(bytes32 => address) public jobExecutor;

    // Executor index
    mapping(address => bytes32[]) private executorJobs;
    mapping(bytes32 => uint256) private execIndex;

    // SC-2: Store hashes and sizes instead of full bytes
    // Full data passed via calldata during settlement
    mapping(bytes32 => bytes32) private inputHashes;
    mapping(bytes32 => uint256) private inputSizes;
    mapping(bytes32 => bytes32) private txRlpHashes;
    mapping(bytes32 => uint256) private txRlpSizes;

    // Accounting
    uint256 public totalPending;
    uint256 public lastCleanup;

    // txOrigin index (for nonce-locking non-system origin transactions)
    // Reuses the previous caller-index storage slots. `caller` remains the wallet allowance actor.
    mapping(address => bytes32[]) private txOriginJobs;
    mapping(bytes32 => uint256) private txOriginIndex;

    /// @notice Scheduler bridge used only by scheduled-origin async commitments.
    address public scheduler;

    /*//////////////////////////////////////////////////////////////
                            JOB STRUCT
    //////////////////////////////////////////////////////////////*/

    struct Job {
        bytes32 id;
        address precompile;
        uint256 commitBlock;
        bytes32 prevHash;
        uint256 prevNumber;
        uint256 prevTimestamp;
        address executor;
        address commitValidator;
        address caller;
        bytes32 originHash;
        uint256 ttl;
        uint256 created;
        bool phase1Settled; // true after Phase 1 settlement for long-running jobs (0x0805, 0x0806, 0x0807, 0x080C, 0x0818, 0x0819, 0x081A, 0x0820)
        address txOrigin; // non-system origin address used only for nonce locking; zero disables locking
    }

    struct ReserveConfig {
        address sponsor;
        uint256 reserveAmount;
        bytes32[] expiredEscrows;
    }

    struct AddJobInput {
        address exec;
        bytes32 id;
        address precomp;
        bytes input;
        uint256 ttl;
        bytes32 prevHash;
        uint256 prevNum;
        uint256 prevTime;
        address caller;
        address commitVal;
        bytes32 origHash;
        bytes origRlp;
        address txOrigin;
    }

    struct ScheduledObligationRef {
        uint256 callId;
        uint256 executionIndex;
        bytes32 scheduledOriginHash;
    }

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event JobAdded(
        address indexed executor,
        bytes32 indexed jobId,
        address indexed precompileAddress,
        uint256 commitBlock,
        bytes precompileInput,
        address callerAddress,
        address txOrigin,
        bytes32 previousBlockHash,
        uint256 previousBlockNumber,
        uint256 previousBlockTimestamp,
        uint256 ttl,
        uint256 createdAt
    );

    event JobRemoved(address indexed executor, bytes32 indexed jobId, bool indexed completed);
    event Cleanup(uint256 start, uint256 end, uint256 removed);
    event SchedulerUpdated(address indexed scheduler);
    event ScheduledAsyncCommitted(
        uint256 indexed callId, uint256 indexed executionIndex, bytes32 indexed jobId, address sponsor, address caller
    );
    // Long-running job events
    event Phase1Settled(bytes32 indexed jobId, address indexed executor, uint256 settledBlock);
    event ResultDelivered(bytes32 indexed jobId, address indexed target, bool success);

    /*//////////////////////////////////////////////////////////////
                            CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function addJobAndReserve(AddJobInput calldata job, ReserveConfig calldata reserve) external onlyCommitmentCaller {
        _prepareJob(job);
        _validateExecutor(job.exec, job.precomp);

        require(address(ritualWallet) != address(0), "wallet not set");
        uint64 exp = uint64(block.number + job.ttl);
        ritualWallet.reserveFrom(
            reserve.sponsor, job.caller, job.id, reserve.reserveAmount, exp, reserve.expiredEscrows
        );

        _storeReservedJob(job, exp);
    }

    function addScheduledJobAndReserve(
        AddJobInput calldata job,
        ReserveConfig calldata reserve,
        ScheduledObligationRef calldata schedule
    ) external onlyCommitmentCaller {
        require(scheduler != address(0), "scheduler not set");
        require(schedule.scheduledOriginHash != bytes32(0), "empty scheduled origin");
        require(schedule.scheduledOriginHash == job.id, "scheduled job mismatch");
        require(job.txOrigin == address(0), "scheduled txOrigin set");

        _prepareJob(job);
        _validateExecutor(job.exec, job.precomp);

        require(address(ritualWallet) != address(0), "wallet not set");
        uint64 exp = uint64(block.number + job.ttl);
        ritualWallet.reserveFrom(
            reserve.sponsor, job.caller, job.id, reserve.reserveAmount, exp, reserve.expiredEscrows
        );

        _storeReservedJob(job, exp);
        ISchedulerAsyncBridge(scheduler).markScheduledAsyncInFlight(schedule.callId, schedule.executionIndex, job.id);
        emit ScheduledAsyncCommitted(schedule.callId, schedule.executionIndex, job.id, reserve.sponsor, job.caller);
    }

    function setScheduler(address _scheduler) external onlyOwner {
        scheduler = _scheduler;
        emit SchedulerUpdated(_scheduler);
    }

    function _prepareJob(AddJobInput calldata job) internal {
        if (jobExecutor[job.id] != address(0)) {
            require(expiryBlock[job.id] < block.number, "active job exists");
            _remove(job.id, false);
        }

        require(job.input.length <= MAX_INPUT_SIZE, ">10KB input");
        require(job.origRlp.length <= MAX_INPUT_SIZE, ">10KB rlp");
        require(job.ttl >= 1 && job.ttl <= MAX_TTL_BLOCKS, "ttl out of range");

        if (totalPending >= CLEANUP_TRIGGER || (block.number - lastCleanup) >= CLEANUP_INTERVAL) {
            _cleanup();
        }

        require(totalPending < MAX_PENDING_JOBS, "at capacity");
        _validateDeliveryFees(job.input, job.precomp);
    }

    function _storeReservedJob(AddJobInput calldata job, uint64 exp) internal {
        uint256 createdAt = block.timestamp;

        Job storage j = jobs[job.id];
        j.id = job.id;
        j.precompile = job.precomp;
        j.commitBlock = block.number;
        j.prevHash = job.prevHash;
        j.prevNumber = job.prevNum;
        j.prevTimestamp = job.prevTime;
        j.executor = job.exec;
        j.commitValidator = job.commitVal;
        j.caller = job.caller;
        j.originHash = job.origHash;
        j.ttl = job.ttl;
        j.created = createdAt;
        j.txOrigin = job.txOrigin;

        inputHashes[job.id] = keccak256(job.input);
        inputSizes[job.id] = job.input.length;
        txRlpHashes[job.id] = keccak256(job.origRlp);
        txRlpSizes[job.id] = job.origRlp.length;

        expiryBuckets[exp].push(job.id);
        bucketIndex[job.id] = expiryBuckets[exp].length - 1;
        expiryBlock[job.id] = exp;

        executorJobs[job.exec].push(job.id);
        execIndex[job.id] = executorJobs[job.exec].length - 1;

        if (job.txOrigin != address(0)) {
            txOriginJobs[job.txOrigin].push(job.id);
            txOriginIndex[job.id] = txOriginJobs[job.txOrigin].length - 1;
        }

        jobExecutor[job.id] = job.exec;
        totalPending++;

        emit JobAdded(
            job.exec,
            job.id,
            job.precomp,
            block.number,
            job.input,
            job.caller,
            job.txOrigin,
            job.prevHash,
            job.prevNum,
            job.prevTime,
            job.ttl,
            createdAt
        );
    }

    function _validateExecutor(address executor, address precompile) internal view {
        if (address(TEE_SERVICE_REGISTRY) == address(0) || !_isKnownAsyncPrecompile(precompile)) {
            return;
        }

        // getValidService reverts unless the attestation is valid, so a successful
        // return already guarantees context.isValid; only capability needs checking.
        ITEEServiceRegistry.TEEServiceContext memory context;
        try TEE_SERVICE_REGISTRY.getValidService(executor) returns (
            ITEEServiceRegistry.TEEServiceContext memory result
        ) {
            context = result;
        } catch {
            revert InvalidExecutor(executor);
        }

        if (!_capabilityMatchesPrecompile(precompile, context.node.capability)) {
            revert InvalidExecutorCapability(executor, precompile, context.node.capability);
        }
    }

    /// @notice Remove a job after settlement
    /// @param id The job identifier
    /// @param input The precompile input (SC-2: passed via calldata, verified by hash)
    /// @param done Whether the job completed successfully
    function removeJob(bytes32 id, bytes calldata input, bool done) external onlyAsyncDelivery returns (bool) {
        require(jobExecutor[id] != address(0), "job not found");
        require(keccak256(input) == inputHashes[id], "input hash mismatch");
        return _remove(id, done);
    }

    /// @notice Get job data. SC-2: Returns empty bytes for input/rlp (use getInputHash/getTxRlpHash)
    function getJob(bytes32 id) external view returns (Job memory job, bytes memory input, bytes memory rlp) {
        require(jobExecutor[id] != address(0), "not found");
        // SC-2: Full bytes no longer stored, return empty
        return (jobs[id], "", "");
    }

    function getSettlementContext(bytes32 id)
        external
        view
        returns (address executorPaymentAddress, address commitmentValidator)
    {
        require(jobExecutor[id] != address(0), "not found");
        Job storage job = jobs[id];
        address executorTeeAddress = job.executor;
        commitmentValidator = job.commitValidator;

        require(address(TEE_SERVICE_REGISTRY) != address(0), "TEE registry required");
        // Use the default validity-checking lookup.
        // `context.isValid` indicates whether the Flashtestation registry currently considers
        // the executor attestation and capability policy valid.
        // Ritual reth checks the executor is valid at job commitment, but we conservatively
        // do not allow settlement if the executor became invalid in the interim.
        ITEEServiceRegistry.TEEServiceContext memory context = TEE_SERVICE_REGISTRY.getValidService(executorTeeAddress);
        executorPaymentAddress = context.node.paymentAddress;
        require(executorPaymentAddress != address(0), "executor payment not found");
    }

    /// @notice Get input hash and size for a job (SC-2)
    function getInputHash(bytes32 id) external view returns (bytes32 hash, uint256 size) {
        require(jobExecutor[id] != address(0), "not found");
        return (inputHashes[id], inputSizes[id]);
    }

    /// @notice Get txRlp hash and size for a job (SC-2)
    function getTxRlpHash(bytes32 id) external view returns (bytes32 hash, uint256 size) {
        require(jobExecutor[id] != address(0), "not found");
        return (txRlpHashes[id], txRlpSizes[id]);
    }

    /// @notice Get pending jobs. SC-2: Returns empty bytes arrays (use getPendingJobHashes)
    function getPendingJobs(address exec)
        external
        view
        returns (Job[] memory result, bytes[] memory inputList, bytes[] memory rlpList)
    {
        bytes32[] storage ids = executorJobs[exec];
        uint256 n = ids.length;
        result = new Job[](n);
        inputList = new bytes[](n);
        rlpList = new bytes[](n);

        for (uint256 i; i < n; i++) {
            result[i] = jobs[ids[i]];
            // SC-2: Return empty bytes
            inputList[i] = "";
            rlpList[i] = "";
        }
    }

    /// @notice Get pending job hashes (SC-2)
    function getPendingJobHashes(address exec)
        external
        view
        returns (bytes32[] memory jobIds, bytes32[] memory inputHashList, uint256[] memory inputSizeList)
    {
        bytes32[] storage ids = executorJobs[exec];
        uint256 n = ids.length;
        jobIds = new bytes32[](n);
        inputHashList = new bytes32[](n);
        inputSizeList = new uint256[](n);

        for (uint256 i; i < n; i++) {
            jobIds[i] = ids[i];
            inputHashList[i] = inputHashes[ids[i]];
            inputSizeList[i] = inputSizes[ids[i]];
        }
    }

    function getJobCount(address exec) external view returns (uint256) {
        return executorJobs[exec].length;
    }

    /*//////////////////////////////////////////////////////////////
                    NONCE-LOCK HELPERS (TX ORIGIN INDEX)
    //////////////////////////////////////////////////////////////*/

    /// @notice Check if a non-system tx origin has any pending async jobs.
    /// @dev Used only for nonce-lock validity constraint verification.
    function hasPendingJobForTxOrigin(address txOrigin) external view returns (bool) {
        return txOriginJobs[txOrigin].length > 0;
    }

    /// @notice Get pending async-job count for a non-system tx origin.
    /// @dev Used only for nonce-lock validity constraint verification.
    function getTxOriginJobCount(address txOrigin) external view returns (uint256) {
        return txOriginJobs[txOrigin].length;
    }

    /*//////////////////////////////////////////////////////////////
                    LONG-RUNNING JOB HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Check if job uses a two-phase precompile (0x0805 HTTP, 0x0806 ZK, 0x0807 FHE, 0x080C Sovereign Agent, 0x0818 Image, 0x0819 Audio, 0x081A Video, or 0x0820 Persistent Agent)
    /// @param jobId The job identifier
    /// @return true if job requires Phase 2 delivery
    function isLongRunning(bytes32 jobId) external view returns (bool) {
        address precompile = jobs[jobId].precompile;
        return precompile == LONG_RUNNING_HTTP_PRECOMPILE || precompile == ZK_TWO_PHASE_PRECOMPILE
            || precompile == FHE_PRECOMPILE || precompile == SOVEREIGN_AGENT_PRECOMPILE
            || precompile == IMAGE_CALL_PRECOMPILE || precompile == AUDIO_CALL_PRECOMPILE
            || precompile == VIDEO_CALL_PRECOMPILE || precompile == PERSISTENT_AGENT_PRECOMPILE;
    }

    /// @notice Check if Phase 1 is settled for a long-running job
    /// @param jobId The job identifier
    /// @return true if Phase 1 settlement is complete
    function isPhase1Settled(bytes32 jobId) external view returns (bool) {
        return jobs[jobId].phase1Settled;
    }

    /// @notice Compute the Phase 2 deadline without mutating tracker state.
    /// @dev AsyncDelivery uses this to settle wallet escrow first while still applying
    ///      the exact same deadline that markPhase1Settled will commit.
    function computePhase2Deadline(bytes32 jobId, bytes calldata input) external view returns (uint64 phase2Deadline) {
        Job storage job = jobs[jobId];
        return _computePhase2Deadline(job, input);
    }

    /// @notice Mark a long-running job as Phase 1 settled
    /// @dev Called by settlement TX instead of removeJob() for two-phase precompiles.
    ///      Computes Phase 2 deadline from offset: phase2Deadline = block.number + offset.
    ///      This mirrors how Phase 1 TTL works: expiryBlock = commitBlock + ttl.
    ///      The offset is extracted from the precompile-family deadline field.
    /// @param jobId The job identifier
    /// @param input The precompile input (SC-2: passed via calldata, verified by hash)
    /// @return phase2Deadline Absolute block deadline for Phase 2 delivery.
    function markPhase1Settled(bytes32 jobId, bytes calldata input)
        external
        onlyAsyncDelivery
        returns (uint64 phase2Deadline)
    {
        Job storage job = jobs[jobId];
        phase2Deadline = _computePhase2Deadline(job, input);

        job.phase1Settled = true;

        uint256 computedDeadline = uint256(phase2Deadline);

        // Phase 1 settlement replaces the active job deadline with the Phase 2 deadline.
        uint256 currentExp = expiryBlock[jobId];
        if (computedDeadline != currentExp) {
            _moveToBucket(jobId, currentExp, computedDeadline);
        }

        emit Phase1Settled(jobId, job.executor, block.number);
    }

    function _computePhase2Deadline(Job storage job, bytes calldata input)
        internal
        view
        returns (uint64 phase2Deadline)
    {
        require(job.executor != address(0), "job not found");
        require(keccak256(input) == inputHashes[job.id], "input hash mismatch");
        require(
            job.precompile == LONG_RUNNING_HTTP_PRECOMPILE || job.precompile == ZK_TWO_PHASE_PRECOMPILE
                || job.precompile == FHE_PRECOMPILE || job.precompile == SOVEREIGN_AGENT_PRECOMPILE
                || job.precompile == IMAGE_CALL_PRECOMPILE || job.precompile == AUDIO_CALL_PRECOMPILE
                || job.precompile == VIDEO_CALL_PRECOMPILE || job.precompile == PERSISTENT_AGENT_PRECOMPILE,
            "not two-phase precompile"
        );
        require(!job.phase1Settled, "already settled");

        // Extract Phase 2 deadline OFFSET from input.
        // Field location varies by precompile family; the offset is relative to
        // this settlement block, not an absolute block number.
        uint256 phase2DeadlineOffset = _extractPhase2Deadline(input, job.precompile);
        require(phase2DeadlineOffset <= MAX_PHASE2_DEADLINE_OFFSET, "phase2 offset too large");

        // Compute absolute Phase 2 deadline from offset (same pattern as Phase 1 TTL)
        // Formula: phase2Deadline = settlementBlock + offset
        uint256 computedDeadline = block.number + phase2DeadlineOffset;
        phase2Deadline = uint64(computedDeadline);
    }

    /// @notice Mark job as delivered and remove it (called by AsyncDelivery contract)
    /// @dev AsyncDelivery handles the actual callback execution with proper gas accounting
    ///      This function just marks the job as complete and removes it
    /// @param jobId The job identifier
    /// @param input The precompile input (SC-2: passed via calldata, verified by hash)
    /// @param success Whether the callback execution succeeded
    function markDelivered(bytes32 jobId, bytes calldata input, bool success) external onlyAsyncDelivery {
        Job storage job = jobs[jobId];
        require(job.executor != address(0), "job not found");
        require(keccak256(input) == inputHashes[jobId], "input hash mismatch");
        require(job.phase1Settled, "phase1 not settled");

        // Get delivery target for event (from provided input)
        (address target,,) = _decodeDeliveryConfig(input, job.precompile);

        emit ResultDelivered(jobId, target, success);

        // Remove job
        _remove(jobId, success);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Decode delivery config from precompile input (SC-2: input passed as param)
    /// @param input The precompile input bytes
    /// @param precompile The precompile address (to determine ABI layout)
    /// @return target The delivery target contract address
    /// @return selector The function selector to call
    /// @return gasLimit The max gas for the delivery call
    function _decodeDeliveryConfig(bytes memory input, address precompile)
        internal
        pure
        returns (address target, bytes4 selector, uint256 gasLimit)
    {
        if (input.length == 0) {
            return (address(0), bytes4(0), 0);
        }

        uint256 startOffset = _deliveryStartOffset(precompile);
        if (input.length < startOffset + DELIVERY_CONFIG_SIZE) {
            return (address(0), bytes4(0), 0);
        }

        bytes memory deliverySlice = new bytes(DELIVERY_CONFIG_SIZE);
        for (uint256 i = 0; i < DELIVERY_CONFIG_SIZE; i++) {
            deliverySlice[i] = input[startOffset + i];
        }

        (target, selector, gasLimit) = abi.decode(deliverySlice, (address, bytes4, uint256));
    }

    /// @dev Return the byte offset where the delivery config block starts
    ///      (target field) for a given precompile. Used by both _decodeDeliveryConfig
    ///      and the fee offset constants.
    function _deliveryStartOffset(address precompile) private pure returns (uint256) {
        if (precompile == ZK_TWO_PHASE_PRECOMPILE) {
            return ZK_FEE_OFFSET - DELIVERY_CONFIG_SIZE;
        } else if (precompile == SOVEREIGN_AGENT_PRECOMPILE) {
            return SOVEREIGN_AGENT_DELIVERY_START_OFFSET;
        } else if (precompile == PERSISTENT_AGENT_PRECOMPILE) {
            return PERSISTENT_AGENT_FEE_OFFSET - DELIVERY_CONFIG_SIZE;
        } else if (precompile == FHE_PRECOMPILE) {
            return FHE_FEE_OFFSET - DELIVERY_CONFIG_SIZE;
        } else {
            return HTTP_FAMILY_FEE_OFFSET - DELIVERY_CONFIG_SIZE;
        }
    }

    /*//////////////////////////////////////////////////////////////
                    DELIVERY FEE VALIDATION
    //////////////////////////////////////////////////////////////*/

    // Per-family byte offset of max_fee_per_gas within the precompile input.
    // max_priority_fee_per_gas is always the next ABI word.

    /// ZK Two-Phase (0x0806): delivery fields [9..14], max_fee at field 12
    uint256 private constant ZK_FEE_OFFSET = 12 * ABI_WORD_SIZE;

    /// Sovereign Agent (0x080C): canonical 26-field request, delivery fields [10..14].
    uint256 private constant SOVEREIGN_AGENT_PHASE2_DEADLINE_FIELD = 8;
    uint256 private constant SOVEREIGN_AGENT_DELIVERY_TARGET_FIELD = 10;
    uint256 private constant SOVEREIGN_AGENT_DELIVERY_MAX_FEE_FIELD =
        SOVEREIGN_AGENT_DELIVERY_TARGET_FIELD + DELIVERY_MAX_FEE_FIELD_OFFSET_FROM_TARGET;
    uint256 private constant SOVEREIGN_AGENT_PHASE2_DEADLINE_OFFSET =
        SOVEREIGN_AGENT_PHASE2_DEADLINE_FIELD * ABI_WORD_SIZE;
    uint256 private constant SOVEREIGN_AGENT_PHASE2_DEADLINE_MIN_LENGTH =
        (SOVEREIGN_AGENT_PHASE2_DEADLINE_FIELD + 1) * ABI_WORD_SIZE;
    uint256 private constant SOVEREIGN_AGENT_DELIVERY_START_OFFSET =
        SOVEREIGN_AGENT_DELIVERY_TARGET_FIELD * ABI_WORD_SIZE;
    uint256 private constant SOVEREIGN_AGENT_FEE_OFFSET = SOVEREIGN_AGENT_DELIVERY_MAX_FEE_FIELD * ABI_WORD_SIZE;

    /// Persistent Agent (0x0820): delivery fields [8..13], max_fee at field 11
    uint256 private constant PERSISTENT_AGENT_FEE_OFFSET = 11 * ABI_WORD_SIZE;

    /// FHE (0x0807): delivery fields [13..18], max_fee at field 16
    uint256 private constant FHE_FEE_OFFSET = 16 * ABI_WORD_SIZE;

    /// HTTP / Image / Audio / Video (0x0805, 0x0818-081A):
    /// delivery fields [10..15], max_fee at field 13
    uint256 private constant HTTP_FAMILY_FEE_OFFSET = 13 * ABI_WORD_SIZE;

    /// @dev Dispatch fee validation to the correct per-family offset.
    ///      Reverts for unknown precompile addresses.
    function _validateDeliveryFees(bytes calldata input, address precompile) internal pure {
        if (input.length == 0) {
            return;
        }

        if (precompile == ZK_TWO_PHASE_PRECOMPILE) {
            _requireFeesU128(input, ZK_FEE_OFFSET);
        } else if (precompile == SOVEREIGN_AGENT_PRECOMPILE) {
            _requireFeesU128(input, SOVEREIGN_AGENT_FEE_OFFSET);
        } else if (precompile == PERSISTENT_AGENT_PRECOMPILE) {
            _requireFeesU128(input, PERSISTENT_AGENT_FEE_OFFSET);
        } else if (precompile == FHE_PRECOMPILE) {
            _requireFeesU128(input, FHE_FEE_OFFSET);
        } else if (
            precompile == LONG_RUNNING_HTTP_PRECOMPILE || precompile == IMAGE_CALL_PRECOMPILE
                || precompile == AUDIO_CALL_PRECOMPILE || precompile == VIDEO_CALL_PRECOMPILE
        ) {
            _requireFeesU128(input, HTTP_FAMILY_FEE_OFFSET);
        } else if (
            precompile == DKMS_KEY_PRECOMPILE || precompile == HTTP_CALL_PRECOMPILE || precompile == LLM_CALL_PRECOMPILE
        ) {
            return; // single-phase, no delivery fee fields
        } else {
            revert("unknown precompile");
        }
    }

    function _isKnownAsyncPrecompile(address precompile) private pure returns (bool) {
        return precompile == HTTP_CALL_PRECOMPILE || precompile == LLM_CALL_PRECOMPILE
            || precompile == LONG_RUNNING_HTTP_PRECOMPILE || precompile == ZK_TWO_PHASE_PRECOMPILE
            || precompile == FHE_PRECOMPILE || precompile == SOVEREIGN_AGENT_PRECOMPILE
            || precompile == IMAGE_CALL_PRECOMPILE || precompile == AUDIO_CALL_PRECOMPILE
            || precompile == VIDEO_CALL_PRECOMPILE || precompile == DKMS_KEY_PRECOMPILE
            || precompile == PERSISTENT_AGENT_PRECOMPILE;
    }

    function _capabilityMatchesPrecompile(address precompile, ITEECapabilityPolicy.Capability capability)
        private
        pure
        returns (bool)
    {
        if (precompile == HTTP_CALL_PRECOMPILE || precompile == LONG_RUNNING_HTTP_PRECOMPILE) {
            return capability == ITEECapabilityPolicy.Capability.HTTP_CALL;
        }
        if (precompile == LLM_CALL_PRECOMPILE) {
            return capability == ITEECapabilityPolicy.Capability.LLM;
        }
        if (precompile == ZK_TWO_PHASE_PRECOMPILE) {
            return capability == ITEECapabilityPolicy.Capability.ZK_CALL;
        }
        if (precompile == FHE_PRECOMPILE) {
            return capability == ITEECapabilityPolicy.Capability.FHE;
        }
        if (precompile == SOVEREIGN_AGENT_PRECOMPILE) {
            return capability == ITEECapabilityPolicy.Capability.HTTP_CALL
                || capability == ITEECapabilityPolicy.Capability.LLM;
        }
        if (precompile == IMAGE_CALL_PRECOMPILE) {
            return capability == ITEECapabilityPolicy.Capability.IMAGE_CALL;
        }
        if (precompile == AUDIO_CALL_PRECOMPILE) {
            return capability == ITEECapabilityPolicy.Capability.AUDIO_CALL;
        }
        if (precompile == VIDEO_CALL_PRECOMPILE) {
            return capability == ITEECapabilityPolicy.Capability.VIDEO_CALL;
        }
        if (precompile == DKMS_KEY_PRECOMPILE) {
            return capability == ITEECapabilityPolicy.Capability.HTTP_CALL;
        }
        if (precompile == PERSISTENT_AGENT_PRECOMPILE) {
            return capability == ITEECapabilityPolicy.Capability.HTTP_CALL;
        }
        return false;
    }

    /// @dev Validate delivery fields at `feeOffset` from calldata `input`.
    ///      gas_limit sits in the preceding ABI word (cast to u64 in reth).
    ///      max_fee_per_gas is at feeOffset, max_priority_fee_per_gas is in the next ABI word (u128 in reth).
    ///      Silently returns if input is too short to contain the fields.
    function _requireFeesU128(bytes calldata input, uint256 feeOffset) private pure {
        if (input.length < feeOffset + 2 * ABI_WORD_SIZE) {
            return;
        }

        uint256 gasLimitOffset = feeOffset - ABI_WORD_SIZE;
        uint256 maxPriorityFeeOffset = feeOffset + ABI_WORD_SIZE;
        uint256 gasLimit;
        uint256 maxFee;
        uint256 maxPriorityFee;
        assembly {
            gasLimit := calldataload(add(input.offset, gasLimitOffset))
            maxFee := calldataload(add(input.offset, feeOffset))
            maxPriorityFee := calldataload(add(input.offset, maxPriorityFeeOffset))
        }

        require(gasLimit > 0, "delivery gasLimit is zero");
        require(gasLimit <= type(uint64).max, "delivery gasLimit exceeds u64");
        require(maxFee <= type(uint128).max, "maxFeePerGas exceeds u128");
        require(maxPriorityFee <= type(uint128).max, "maxPriorityFeePerGas exceeds u128");
    }

    /// @dev Extract Phase 2 deadline OFFSET from precompile input.
    ///      Each family stores the deadline as an ABI field containing an offset from settlement block.
    /// @param input The precompile input bytes (SC-2: passed as param)
    /// @param precompile The precompile address (to determine field offset)
    /// @return The offset value (NOT an absolute block number)
    function _extractPhase2Deadline(bytes memory input, address precompile) internal pure returns (uint256) {
        uint256 fieldOffset;
        uint256 minLength;

        if (precompile == SOVEREIGN_AGENT_PRECOMPILE) {
            fieldOffset = SOVEREIGN_AGENT_PHASE2_DEADLINE_OFFSET;
            minLength = SOVEREIGN_AGENT_PHASE2_DEADLINE_MIN_LENGTH;
        } else if (precompile == PERSISTENT_AGENT_PRECOMPILE) {
            // Persistent Agent ABI: field 7 = max_spawn_block
            fieldOffset = 7 * ABI_WORD_SIZE;
            minLength = 8 * ABI_WORD_SIZE;
        } else if (precompile == FHE_PRECOMPILE) {
            // FHE ABI: field 12 = max_inference_block
            fieldOffset = 12 * ABI_WORD_SIZE;
            minLength = 13 * ABI_WORD_SIZE;
        } else {
            // HTTP/ZK/Image/Audio/Video: field 8 = max_poll_block/max_proof_block
            fieldOffset = 8 * ABI_WORD_SIZE;
            minLength = 9 * ABI_WORD_SIZE;
        }

        require(input.length >= minLength, "phase2 deadline missing");

        bytes32 slot;
        assembly {
            slot := mload(add(add(input, 32), fieldOffset))
        }
        return uint256(slot);
    }

    /// @dev Move job from one expiry bucket to another (swap-and-pop + append).
    function _moveToBucket(bytes32 jobId, uint256 oldExp, uint256 newExp) internal {
        bytes32[] storage oldBucket = expiryBuckets[oldExp];
        uint256 idx = _requireIndexedJob(oldBucket, bucketIndex, jobId, "bucket index mismatch");
        uint256 last = oldBucket.length - 1;
        if (idx != last) {
            oldBucket[idx] = oldBucket[last];
            bucketIndex[oldBucket[idx]] = idx;
        }
        oldBucket.pop();

        expiryBuckets[newExp].push(jobId);
        bucketIndex[jobId] = expiryBuckets[newExp].length - 1;
        expiryBlock[jobId] = newExp;
    }

    function _requireIndexedJob(
        bytes32[] storage ids,
        mapping(bytes32 => uint256) storage indexOf,
        bytes32 id,
        string memory reason
    ) internal view returns (uint256 idx) {
        idx = indexOf[id];
        require(idx < ids.length && ids[idx] == id, reason);
    }

    function _remove(bytes32 id, bool done) internal returns (bool) {
        address exec = jobExecutor[id];
        if (exec == address(0)) {
            return false;
        }

        // Settlement and prior permissionless cleanup legitimately leave no escrow.
        // Any escrow still present must be expired; strict expiry exposes deadline drift.
        if (ritualWallet.escrows(id).sponsor != address(0)) {
            ritualWallet.expire(id);
        }

        // Remove from expiry bucket (swap-and-pop)
        uint256 exp = expiryBlock[id];
        bytes32[] storage bucket = expiryBuckets[exp];
        uint256 idx = _requireIndexedJob(bucket, bucketIndex, id, "bucket index mismatch");
        uint256 last = bucket.length - 1;
        if (idx != last) {
            bucket[idx] = bucket[last];
            bucketIndex[bucket[idx]] = idx;
        }
        bucket.pop();

        // Remove from executor index (swap-and-pop)
        bytes32[] storage exJobs = executorJobs[exec];
        idx = _requireIndexedJob(exJobs, execIndex, id, "executor index mismatch");
        last = exJobs.length - 1;
        if (idx != last) {
            exJobs[idx] = exJobs[last];
            execIndex[exJobs[idx]] = idx;
        }
        exJobs.pop();

        // Remove from txOrigin index (swap-and-pop) for nonce-lock, if this was a non-system tx.
        address txOrigin = jobs[id].txOrigin;
        if (txOrigin != address(0)) {
            bytes32[] storage oJobs = txOriginJobs[txOrigin];
            idx = _requireIndexedJob(oJobs, txOriginIndex, id, "txOrigin index mismatch");
            last = oJobs.length - 1;
            if (idx != last) {
                oJobs[idx] = oJobs[last];
                txOriginIndex[oJobs[idx]] = idx;
            }
            oJobs.pop();
        }

        // SC-2: Delete hash/size mappings (no longer have bytes to wipe)
        delete inputHashes[id];
        delete inputSizes[id];
        delete txRlpHashes[id];
        delete txRlpSizes[id];
        delete jobs[id];
        delete jobExecutor[id];
        delete bucketIndex[id];
        delete expiryBlock[id];
        delete execIndex[id];
        delete txOriginIndex[id];

        if (totalPending > 0) {
            totalPending--;
        }

        emit JobRemoved(exec, id, done);
        return true;
    }

    function _cleanup() internal {
        uint256 current = block.number;
        uint256 start = lastCleanup + 1;
        if (start == 0) {
            start = 1;
        }

        if (current == 0) {
            return;
        }

        uint256 end = current - 1;
        if (end > start + MAX_CLEANUP_BUCKETS - 1) {
            end = start + MAX_CLEANUP_BUCKETS - 1;
        }
        if (start > end) {
            return;
        }

        uint256 removed = 0;
        uint256 lastProcessedBucket = start - 1;

        for (uint256 b = start; b <= end; b++) {
            if (b >= current) {
                break;
            }
            if (removed >= MAX_CLEANUP_PER_CALL) {
                break; // Gas bound
            }

            bytes32[] storage bucket = expiryBuckets[b];
            if (bucket.length > 0) {
                while (bucket.length > 0 && removed < MAX_CLEANUP_PER_CALL) {
                    // Gas bound
                    _remove(bucket[bucket.length - 1], false);
                    removed++;
                }
                if (bucket.length == 0) {
                    delete expiryBuckets[b];
                    lastProcessedBucket = b;
                }
            } else {
                lastProcessedBucket = b;
            }
        }

        // Only advance lastCleanup to fully processed buckets
        if (lastProcessedBucket >= start) {
            lastCleanup = lastProcessedBucket;
        }
        if (removed > 0) {
            emit Cleanup(start, lastProcessedBucket, removed);
        }
    }

    // SC-2: _wipe function removed - no longer storing bytes

    /*//////////////////////////////////////////////////////////////
                            CLEANUP HELPERS
    //////////////////////////////////////////////////////////////*/

    function cleanupExpired(address exec, uint256 max) external returns (uint256) {
        bytes32[] storage ids = executorJobs[exec];
        uint256 current = block.number;
        uint256 cleaned = 0;
        uint256 checked = 0;

        for (uint256 i = ids.length; i > 0 && checked < max; i--) {
            bytes32 id = ids[i - 1];
            if (expiryBlock[id] < current) {
                _remove(id, false);
                cleaned++;
            }
            checked++;
        }
        return cleaned;
    }

    function cleanupBatch(uint256 max) external returns (uint256, uint256) {
        uint256 current = block.number;
        uint256 start = lastCleanup + 1;
        if (start == 0) {
            start = current;
        }

        if (current == 0) {
            return (0, 0);
        }

        uint256 end = current - 1;
        if (max > 0 && end > start + max - 1) {
            end = start + max - 1;
        }
        if (start > end) {
            return (0, 0);
        }

        uint256 removed = 0;
        uint256 lastProcessedBucket = start - 1;

        for (uint256 b = start; b <= end; b++) {
            if (b >= current) {
                break;
            }
            if (removed >= MAX_CLEANUP_PER_CALL) {
                break; // Gas bound
            }

            bytes32[] storage bucket = expiryBuckets[b];
            if (bucket.length > 0) {
                while (bucket.length > 0 && removed < MAX_CLEANUP_PER_CALL) {
                    // Gas bound
                    _remove(bucket[bucket.length - 1], false);
                    removed++;
                }
                if (bucket.length == 0) {
                    delete expiryBuckets[b];
                    lastProcessedBucket = b;
                }
            } else {
                lastProcessedBucket = b;
            }
        }

        // Only advance lastCleanup to fully processed buckets
        if (lastProcessedBucket >= start) {
            lastCleanup = lastProcessedBucket;
        }
        return (removed, lastProcessedBucket >= start ? lastProcessedBucket - start + 1 : 0);
    }

    /*//////////////////////////////////////////////////////////////
                            STORAGE GAP
    //////////////////////////////////////////////////////////////*/

    /// @dev Reserved storage space for future upgrades
    uint256[35] private __gap;
}
