// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.28;

import {IRitualWallet} from "../wallet/IRitualWallet.sol";
import {IScheduledCallback} from "./interfaces/IScheduledCallback.sol";
import {IScheduledPredicate} from "./interfaces/IScheduledPredicate.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/*//////////////////////////////////////////////////////////////
                            PUBLIC STRUCTS
//////////////////////////////////////////////////////////////*/

/// @notice Call state enum for explicit state management
enum CallState {
    SCHEDULED,
    EXECUTING,
    COMPLETED,
    CANCELLED,
    EXPIRED
}

/// @notice Recoverable predicate outcomes that skip one execution attempt without consuming its index.
/// @dev The call remains scheduled until the index executes or its TTL path consumes/expires it.
///      Appending a reason is a coordinated consensus change because node software validates this enum.
enum PredicateSkipReason {
    /// @notice The predicate returned a well-formed `false` value.
    PredicateFalse,
    /// @notice The predicate reverted, exhausted its gas cap, returned fewer than 32 bytes, or returned a non-boolean word.
    PredicateCheckFailed
}

/// @notice A `Call` is a scheduled contract call with EIP-1559 pricing
/// @dev Tightly-packed struct for gas optimization
struct Call {
    /// @notice Target contract address
    address to;
    /// @notice RitualWallet account sponsoring scheduled execution payment
    address sponsor;
    /// @notice Block number when first execution should occur
    uint32 startBlock;
    /// @notice Fixed number of executions
    uint32 numCalls;
    /// @notice Number of blocks between each execution
    uint32 frequency;
    /// @notice Gas limit per execution
    uint32 gas;
    /// @notice Maximum drift tolerance in blocks (used for implicit expiry)
    uint32 ttl;
    /// @notice Current state of the call
    CallState state;
    /// @notice EIP-1559 max fee per gas
    uint256 maxFeePerGas;
    /// @notice EIP-1559 max priority fee per gas
    uint256 maxPriorityFeePerGas;
    /// @notice ETH value to transfer with each call
    uint256 value;
    /// @notice Opaque scheduling payload delivered verbatim to the target.
    /// @dev On each execution the Scheduler calls
    ///      `IScheduledCallback.onScheduledExecution(executionIndex, data)` on `to`, passing these bytes
    ///      through unchanged. The Scheduler never inspects or mutates `data`; targets decode it to recover
    ///      their own arguments. May be empty.
    bytes data;
    /// @notice Internal: identifier of this call for compaction bookkeeping
    uint256 callId;
}

/// @notice Memory snapshot of a scheduled call used across external execution boundaries.
/// @dev `Call storage` references point into the compactable `slots` array. Never carry
///      them across `call.to.call(...)`, because the target may reenter Scheduler and
///      compact `slots`. Snapshot value data before the boundary, then reacquire by callId.
struct CallExecutionSnapshot {
    address to;
    address sponsor;
    uint32 startBlock;
    uint32 numCalls;
    uint32 frequency;
    uint32 gas;
    uint32 ttl;
    uint256 maxFeePerGas;
    uint256 maxPriorityFeePerGas;
    uint256 value;
    bytes data;
}

/// @title Scheduler
/// @notice Scheduler allows contracts to schedule callbacks (`Call`)
/// @dev You cannot schedule a callback via Scheduler within the `constructor` of a smart contract.
///      Payment V2 is a fresh-deployment-only storage layout. It is not
///      backwards-compatible with prior Scheduler proxy storage.
contract Scheduler is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a scheduled call is executed successfully
    event CallExecuted(
        uint256 indexed callId,
        address indexed to,
        address indexed sponsor,
        uint32 startBlock,
        uint32 numCalls,
        uint32 frequency,
        uint256 executionIndex,
        uint256 gasUsed,
        uint256 feesPaid
    );

    /// @notice Emitted when a scheduled call execution fails
    event CallExecutionFailed(
        uint256 indexed callId,
        address indexed to,
        address indexed sponsor,
        uint32 startBlock,
        uint32 numCalls,
        uint32 frequency,
        uint256 executionIndex,
        uint256 gasUsed,
        string reason
    );

    /// @notice Emitted when the live predicate prevents an otherwise-due execution.
    event CallExecutionSkipped(uint256 indexed callId, uint256 indexed executionIndex, PredicateSkipReason reason);

    /// @notice Emitted when a call is cancelled with complete metadata
    event CallCancelled(
        uint256 indexed callId,
        address indexed to,
        address indexed sponsor,
        uint32 startBlock,
        uint32 numCalls,
        uint32 frequency
    );

    /// @notice Emitted when owner force-cancels a call
    /// @param callId The cancelled call ID
    /// @param operator The owner account that triggered force-cancel
    /// @param previousState The call state before force-cancel cleanup
    event CallForceCancelled(uint256 indexed callId, address indexed operator, CallState previousState);

    /// @notice Emitted when a call is skipped due to insufficient funds
    event CallSkippedInsufficientFunds(
        uint256 indexed callId,
        address indexed to,
        address indexed sponsor,
        uint256 requiredAmount,
        uint256 availableAmount
    );

    /// @notice Emitted when a scheduled call is evicted because its sponsor cannot cover execution.
    event CallEvictedInsufficientFunds(
        uint256 indexed callId,
        address indexed to,
        address indexed sponsor,
        uint256 requiredAmount,
        uint256 availableAmount
    );

    /// @notice Emitted when a specific execution is skipped due to TTL expiry
    event CallSkippedTTLExpired(
        uint256 indexed callId,
        address indexed to,
        address indexed sponsor,
        uint256 expectedBlock,
        uint256 currentBlock,
        uint32 ttl
    );

    /// @notice Emitted when a call completes all executions
    /// @dev Terminal marker only. Consumed indices always equal `numCalls` here, and TTL-skipped
    ///      indices count toward completion; count `CallExecuted` events for actual executions.
    event CallCompleted(
        uint256 indexed callId,
        address indexed to,
        address indexed sponsor,
        uint32 startBlock,
        uint32 numCalls,
        uint32 frequency
    );

    /// @notice Emitted when a call expires
    event CallExpired(
        uint256 indexed callId,
        address indexed to,
        address indexed sponsor,
        uint32 startBlock,
        uint32 expiryBlock,
        uint256 expiredAtBlock
    );

    /// @notice Emitted when call state changes
    event CallStateChanged(uint256 indexed callId, address indexed to, CallState oldState, CallState newState);

    event AsyncJobTrackerUpdated(address indexed asyncJobTracker);
    event ScheduledAsyncInFlight(uint256 indexed callId, uint256 indexed executionIndex, bytes32 indexed jobId);
    event ScheduledAsyncEvicted(
        uint256 indexed callId, uint256 indexed executionIndex, bytes32 indexed jobId, bytes32 reason
    );

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLE
    //////////////////////////////////////////////////////////////*/

    /// @notice System account permissioned to call `execute()`
    address private immutable SYSTEM_ACCOUNT = 0x000000000000000000000000000000000000fa7e;

    /// @notice Async commitment system account allowed to finalize scheduled async cleanup.
    address private immutable ASYNC_COMMITMENT_SYSTEM_ACCOUNT = 0x000000000000000000000000000000000000Fa8e;

    /// @notice System-wide RitualWallet contract for all payments
    IRitualWallet public immutable RITUAL_WALLET;

    /// @notice Maximum allowed TTL (time-to-live) in blocks for scheduled transactions
    uint32 public immutable MAX_TTL;

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice TX_HASH precompile address — returns the hash of the currently executing transaction
    address private constant TX_HASH_PRECOMPILE = 0x0000000000000000000000000000000000000830;

    /// @notice Maximum number of explicit cleanup IDs assigned to one scheduled execution.
    uint256 public constant MAX_CLEANUP_BATCH = 25;

    /// @notice Maximum opaque callback payload stored for one scheduled call.
    uint256 public constant MAX_CALL_DATA_LENGTH = 12 * 1024;

    /// @notice Maximum number of executions per scheduled call.
    /// @dev The scheduler tracks consumed execution indices in one 256-bit bitmap. `MAX_LIFESPAN`
    ///      independently bounds total call residency; this cap keeps replay/completion accounting single-slot.
    uint32 private constant MAX_NUM_CALLS = 256;

    /// @notice Maximum gas forwarded to the contract-side predicate backstop.
    uint256 private constant MAX_PREDICATE_GAS = 100_000;

    /// @notice Maximum total lifespan of a scheduled call in blocks
    /// @dev Bounds slot residency so long-lived calls cannot accumulate for years.
    uint256 public constant MAX_LIFESPAN = 10_000;

    address private constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Minimum maxFeePerGas accepted for newly scheduled calls.
    /// @dev Public Ritual chain base fee has held at 7 wei; this rejects zero-fee griefing without
    ///      forcing callers to overpay on a low-base-fee chain.
    uint256 public constant MIN_SCHEDULED_MAX_FEE_PER_GAS = 7;

    /*//////////////////////////////////////////////////////////////
                               MUTABLE
    //////////////////////////////////////////////////////////////*/

    /// @notice Current highest call ID
    uint256 public id = 0;

    /// @notice Dynamic storage for active calls (dense head region [0..activeCount-1])
    Call[] public slots;

    /// @notice Mapping from call ID to slot index
    mapping(uint256 => uint256) public callToSlot;

    /// @notice Bitmap tracking consumed execution indices per callId.
    /// @dev `numCalls <= 256`, so bit i in this single word records whether index i has been consumed.
    mapping(uint256 => uint256) public executedBitmap;

    /// @notice Mapping from call ID to predicate contract address
    /// @dev Zero address means "no custom predicate" (always execute).
    ///      Stored separately from Call struct to preserve storage layout compatibility.
    ///      Reth still enforces predicate gating before scheduled transactions become canonical, and
    ///      `execute()` mirrors the same cheap local predicate check as a contract backstop.
    mapping(uint256 => address) public callPredicates;

    /// @notice Mapping from call ID to the hash of the transaction that created the job
    /// @dev Populated at schedule time via the TX_HASH precompile (0x0830).
    ///      Enables the block builder to reconstruct TxScheduled without event processing.
    mapping(uint256 => bytes32) public originHash;

    /// @notice AsyncJobTracker authorized to mark successful scheduled async admission.
    address public asyncJobTracker;

    /// @notice Replay-proven terminal cleanup reasons for scheduled async obligations.
    mapping(bytes32 => bytes32) public scheduledAsyncCleanupReasons;

    /*//////////////////////////////////////////////////////////////
                          PREDICATE CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a predicate is set for a scheduled call
    /// @param callId The call ID
    /// @param predicate The predicate contract address
    event PredicateSet(uint256 indexed callId, address indexed predicate);

    /// @notice Emitted when a new call is scheduled with complete metadata
    event CallScheduled(
        uint256 indexed callId,
        address indexed to,
        address indexed sponsor,
        uint32 startBlock,
        uint32 numCalls,
        uint32 frequency,
        uint32 gas,
        uint32 ttl,
        uint256 maxFeePerGas,
        uint256 maxPriorityFeePerGas,
        uint256 value,
        bytes data
    );

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown by `schedule()` if a non-contract address tries to schedule a `Call`
    /// @dev 4-byte signature: `0xbe541de4`
    error SenderNotContract();

    /// @notice Thrown by `cancel()` if the address attempting to cancel a `Call` is not the `to` address (`Call` creator)
    /// @dev 4-byte signature: `0x08094908`
    error UnauthorizedSender();

    /// @notice Thrown by `execute()` if an address other than `SYSTEM_ACCOUNT` attempts to call the function
    /// @dev 4-byte signature: `0x71a63c44`
    error SenderNotSystemAccount();

    /// @notice Thrown by `schedule()` if wallet has insufficient funds
    /// @dev 4-byte signature: `0x13a6fe64`
    error InsufficientWalletFunds();

    /// @notice Thrown when sponsor is not msg.sender and has not approved msg.sender to schedule on their behalf
    error UnauthorizedSponsor();

    /// @notice Thrown by `execute()` if call does not exist
    /// @dev 4-byte signature: `0x69bf78e6`
    error CallNotFound();

    /// @notice Thrown when trying to operate on a call in wrong state
    /// @dev 4-byte signature: `0x6bafafcb`
    error InvalidCallState();

    /// @notice Thrown when frequency is invalid (must be >= 1)
    /// @dev 4-byte signature: `0xe3c2448f`
    error InvalidFrequency();

    /// @notice Thrown when the callback gas limit is zero
    /// @dev 4-byte signature: `0x98bdb2e0`
    error InvalidGasLimit();

    /// @notice Thrown when TTL exceeds the maximum allowed value
    /// @dev 4-byte signature: `0x31d2f2b7`
    error InvalidTTL();

    /// @notice Thrown when numCalls is invalid (must be >= 1)
    /// @dev 4-byte signature: `0x12345678`
    error InvalidNumCalls();

    /// @notice Thrown when startBlock is in the past
    /// @dev 4-byte signature: `0x87654321`
    error StartBlockInPast();

    /// @notice Thrown when execution index is invalid
    /// @dev 4-byte signature: `0xabcdef12`
    error InvalidExecutionIndex();

    /// @notice Thrown when call has expired
    /// @dev 4-byte signature: `0x34cdef56`
    error CallHasExpired();

    /// @notice Thrown when attempting to execute an already-executed index
    error AlreadyExecuted();

    /// @notice Thrown when a scheduled execution is submitted before its expected block
    error ExecutionNotDue(uint256 expectedBlock, uint256 currentBlock);

    /// @notice Thrown when predicate contract is invalid (doesn't implement IScheduledPredicate)
    /// @dev 4-byte signature: TBD
    error InvalidPredicate();

    /// @notice Thrown when maxFeePerGas or maxPriorityFeePerGas exceeds uint128 range
    /// @dev EIP-1559 fee fields are u128 in the execution layer; values above u128::MAX
    ///      would cause overflow in downstream fee arithmetic.
    error FeeExceedsU128();

    /// @notice Thrown when schedule horizon cannot be represented in uint32 block space
    error ScheduleHorizonOverflow();

    /// @notice Thrown when a schedule would remain resident longer than MAX_LIFESPAN
    error ScheduleLifespanExceeded();

    /// @notice Thrown when a scheduled callback payload exceeds MAX_CALL_DATA_LENGTH
    error CallDataTooLarge();

    /// @notice Thrown when an explicit cleanup batch has an invalid size
    error InvalidCleanupBatchSize();

    /// @notice Thrown when maxFeePerGas is below the network floor for scheduled calls
    error MaxFeePerGasBelowFloor();

    error UnauthorizedAsyncJobTracker();
    error InvalidAsyncJobTracker();
    error ScheduledAsyncOriginMismatch();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address ritualWallet, uint32 maxTTL) {
        _disableInitializers();
        RITUAL_WALLET = IRitualWallet(ritualWallet);
        MAX_TTL = maxTTL;
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize the Scheduler with an owner for upgrade authorization
    /// @param _owner The address that will own the contract (for upgrade authorization only)
    function initialize(address _owner) external initializer {
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
        SCHEDULED_RESIDENCY_FEE_PER_BLOCK = 10_000_000_000_000_000;
    }

    /// @notice Restricts upgrades to owner only
    function _authorizeUpgrade(address) internal override onlyOwner {}

    function setScheduledResidencyFeePerBlock(uint256 newFee) external onlyOwner {
        SCHEDULED_RESIDENCY_FEE_PER_BLOCK = newFee;
    }

    function setAsyncJobTracker(address _asyncJobTracker) external onlyOwner {
        if (_asyncJobTracker == address(0)) {
            revert InvalidAsyncJobTracker();
        }
        asyncJobTracker = _asyncJobTracker;
        emit AsyncJobTrackerUpdated(_asyncJobTracker);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Allocate a new slot at the end of the dynamic array
    /// @return slotIndex The allocated slot index
    function _allocateSlot() internal returns (uint256 slotIndex) {
        slotIndex = slots.length;
        slots.push();
    }

    /// @notice Free a slot back to the free slots stack
    /// @param slotIndex The slot index to free
    function _freeSlot(uint256 slotIndex) internal {
        uint256 lastIndex = slots.length - 1;
        if (slotIndex != lastIndex) {
            // Wipe destination slot's dynamic bytes to avoid orphaned storage
            _wipeBytes(slots[slotIndex].data);
            // Capture moved callId, move struct, and update mapping
            uint256 movedCallId = slots[lastIndex].callId;
            slots[slotIndex] = slots[lastIndex];
            callToSlot[movedCallId] = slotIndex;
        }
        // Deep-wipe the last slot's dynamic bytes (child storage), then truncate. `pop()` implicitly
        // `delete`s the removed element, which zeroes the struct's head fields, so an explicit
        // `delete slots[lastIndex]` here would just clear those head fields a second time. We keep the
        // explicit `_wipeBytes` because it is what guarantees the bytes' child (content) slots are
        // reclaimed; `pop()` then sees a zero-length `data` head and has nothing left to clear.
        _wipeBytes(slots[lastIndex].data);
        slots.pop();
    }

    /// @notice Get a call by ID using the dense slots array
    /// @param callId The call ID to retrieve
    /// @return call The call data
    function _getCall(uint256 callId) internal view returns (Call storage call) {
        uint256 slotIndex = callToSlot[callId];
        if (slotIndex >= slots.length) {
            revert CallNotFound();
        }
        call = slots[slotIndex];
        if (call.callId != callId || call.to == address(0) || call.state == CallState.EXPIRED) {
            revert CallNotFound();
        }
    }

    /// @notice Checks if `target` address is an EOA
    /// @dev This will return `true` if calling from within a contracts `constructor`
    /// @param target address to check
    /// @return `true` if `target` is an EOA, else `false`
    function _isEOA(address target) internal view returns (bool) {
        return target.code.length == 0;
    }

    /// @notice Calculate expected execution block for TTL validation
    /// @param startBlock The first execution block
    /// @param frequency Block delta between executions
    /// @param executionIndex Which execution this is (0-based)
    /// @return expectedBlock The block number when this execution should occur
    function _calculateExpectedBlock(uint32 startBlock, uint32 frequency, uint256 executionIndex)
        internal
        pure
        returns (uint256)
    {
        return uint256(startBlock) + (uint256(frequency) * executionIndex);
    }

    /// @notice Calculate implicit expiry block
    /// @param startBlock The first execution block
    /// @param frequency Block delta between executions
    /// @param numCalls Number of scheduled executions
    /// @param ttl Per-execution drift tolerance in blocks
    /// @return expiryBlock The block number when the call expires
    function _calculateExpiryBlock(uint32 startBlock, uint32 frequency, uint32 numCalls, uint32 ttl)
        internal
        pure
        returns (uint256)
    {
        // numCalls is validated on schedule and guaranteed > 0
        return _calculateExpectedBlock(startBlock, frequency, uint256(numCalls - 1)) + uint256(ttl);
    }

    /// @notice Cast expiry block for the uint32 CallExpired event field
    function _eventExpiryBlock(uint256 expiryBlock) internal pure returns (uint32) {
        if (expiryBlock > type(uint32).max) {
            return type(uint32).max;
        }
        return uint32(expiryBlock);
    }

    /// @notice Check if (callId, index) has been consumed.
    /// @param callId The call ID
    /// @param index The execution index to check
    /// @return True if already consumed
    function isExecuted(uint256 callId, uint256 index) public view returns (bool) {
        if (index >= MAX_NUM_CALLS) {
            return false;
        }
        return (executedBitmap[callId] & (uint256(1) << index)) != 0;
    }

    /// @notice Mark (callId, index) as consumed.
    /// @param callId The call ID
    /// @param index The execution index to mark
    function _markExecuted(uint256 callId, uint256 index) internal {
        executedBitmap[callId] |= (uint256(1) << index);
    }

    /// @notice Clear consumed-index bitmap for a callId.
    /// @param callId The call ID to clear
    function _clearBitmap(uint256 callId) internal {
        delete executedBitmap[callId];
    }

    /// @dev Deeply wipe a bytes storage variable, zeroing both head and child slots
    function _wipeBytes(bytes storage s) internal {
        uint256 len = s.length;
        if (len == 0) {
            return;
        }
        uint256 valueSlot;
        assembly {
            valueSlot := s.slot
        }
        if (len <= 31) {
            assembly {
                sstore(valueSlot, 0)
            }
            return;
        }
        bytes32 contentBase;
        assembly {
            mstore(0x00, valueSlot)
            contentBase := keccak256(0x00, 0x20)
        }
        uint256 words = (len + 31) >> 5; // ceil(len/32)
        for (uint256 i = 0; i < words;) {
            assembly {
                sstore(add(contentBase, i), 0)
            }
            unchecked {
                ++i;
            }
        }
        assembly {
            sstore(valueSlot, 0)
        }
    }

    function _allExecutionIndicesConsumed(uint256 callId, uint32 numCalls) internal view returns (bool) {
        uint256 requiredMask = numCalls == MAX_NUM_CALLS ? type(uint256).max : ((uint256(1) << numCalls) - 1);
        return (executedBitmap[callId] & requiredMask) == requiredMask;
    }

    /// @notice Handle post-execution state transitions
    /// @param callId The call ID
    /// @param call The call data
    function _handlePostExecution(
        uint256 callId,
        Call storage call,
        uint256,
        bool /* success */
    )
        internal
    {
        // Recurring schedules can have overlapping validity windows, so indices may be
        // handled out of order. Complete only when every index has been consumed.
        bool shouldComplete = _allExecutionIndicesConsumed(callId, call.numCalls);

        if (shouldComplete) {
            _completeCall(callId, call, CallState.EXECUTING);
        } else {
            // Return to scheduled state for next execution
            call.state = CallState.SCHEDULED;
            emit CallStateChanged(callId, call.to, CallState.EXECUTING, CallState.SCHEDULED);
        }
    }

    /// @notice Terminal COMPLETED transition: tear down a call whose every execution index
    ///         has been consumed.
    /// @dev Shared by the post-execution path (previousState EXECUTING) and the TTL-skip
    ///      path (previousState SCHEDULED), so both consumers of the last index perform the
    ///      identical teardown. `call` is a storage pointer into the compactable `slots`
    ///      array and `_freeSlot` moves slots; the caller must not touch `call` after this
    ///      returns.
    /// @param callId The call ID
    /// @param call The call data
    /// @param previousState The state the call held immediately before completion
    function _completeCall(uint256 callId, Call storage call, CallState previousState) internal {
        _clearBitmap(callId);

        // Mark as completed and clean up
        call.state = CallState.COMPLETED;
        emit CallStateChanged(callId, call.to, previousState, CallState.COMPLETED);
        emit CallCompleted(callId, call.to, call.sponsor, call.startBlock, call.numCalls, call.frequency);

        // Free the slot back to the available pool
        uint256 slotIndex = callToSlot[callId];
        _freeSlot(slotIndex);

        // Remove the call ID mapping and auxiliary storage
        delete callToSlot[callId];
        delete originHash[callId];
        delete callPredicates[callId];
    }

    function _snapshotCall(Call storage call) internal view returns (CallExecutionSnapshot memory snap) {
        snap = CallExecutionSnapshot({
            to: call.to,
            sponsor: call.sponsor,
            startBlock: call.startBlock,
            numCalls: call.numCalls,
            frequency: call.frequency,
            gas: call.gas,
            ttl: call.ttl,
            maxFeePerGas: call.maxFeePerGas,
            maxPriorityFeePerGas: call.maxPriorityFeePerGas,
            value: call.value,
            data: call.data
        });
    }

    function _getExecutingCall(uint256 callId) internal view returns (Call storage call) {
        call = _getCall(callId);
        if (call.state != CallState.EXECUTING) {
            revert InvalidCallState();
        }
    }

    function _validateScheduledAsyncPending(uint256 callId, Call storage call, uint256 executionIndex, bytes32 jobId)
        internal
        view
    {
        _validateScheduledAsyncOrigin(callId, executionIndex, jobId);
        if (call.state != CallState.SCHEDULED) {
            revert InvalidCallState();
        }
        if (executionIndex >= call.numCalls) {
            revert InvalidExecutionIndex();
        }
        if (isExecuted(callId, executionIndex)) {
            revert AlreadyExecuted();
        }
    }

    function _scheduledAsyncJobId(uint256 callId, uint256 executionIndex) internal view returns (bytes32) {
        bytes32 origin = originHash[callId];
        if (origin == bytes32(0)) {
            revert ScheduledAsyncOriginMismatch();
        }
        return keccak256(abi.encodePacked(origin, callId, executionIndex));
    }

    function _validateScheduledAsyncOrigin(uint256 callId, uint256 executionIndex, bytes32 jobId) internal view {
        if (_scheduledAsyncJobId(callId, executionIndex) != jobId) {
            revert ScheduledAsyncOriginMismatch();
        }
    }

    function _onlyAsyncJobTracker() internal view {
        if (msg.sender != asyncJobTracker) {
            revert UnauthorizedAsyncJobTracker();
        }
    }

    function _scheduledAsyncKey(uint256 callId, uint256 executionIndex) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(callId, executionIndex));
    }

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Internal function to schedule a call (preserves msg.sender correctly)
    /// @dev This is the core scheduling logic used by all public schedule() overloads.
    ///      `data` is an opaque payload: on each execution the Scheduler delivers it verbatim via
    ///      `IScheduledCallback.onScheduledExecution(executionIndex, data)` on the target. The Scheduler
    ///      never inspects or mutates `data`; it may be empty but cannot exceed MAX_CALL_DATA_LENGTH. The
    ///      caller does not encode the execution index into it — the index is delivered separately.
    function _schedule(
        bytes memory data,
        uint32 gas,
        uint32 startBlock,
        uint32 numCalls,
        uint32 frequency,
        uint32 ttl,
        uint256 maxFeePerGas,
        uint256 maxPriorityFeePerGas,
        uint256 value,
        address sponsor
    ) internal returns (uint256) {
        // Require caller to be a smart contract
        // This will fail if calling `schedule` from within a contracts `constructor`
        if (_isEOA(msg.sender)) {
            revert SenderNotContract();
        }

        // Add frequency validation - frequency must be >= 1
        if (frequency == 0) {
            revert InvalidFrequency();
        }

        // A zero callback budget can never execute the target; reject it at admission rather
        // than admit a schedule that only ever burns slot residency and proposer bookkeeping.
        if (gas == 0) {
            revert InvalidGasLimit();
        }

        // Validate numCalls - must be in [1, MAX_NUM_CALLS] to keep consumed-index accounting
        // inside the single executedBitmap word.
        if (numCalls == 0 || numCalls > MAX_NUM_CALLS) {
            revert InvalidNumCalls();
        }

        // Validate TTL against maximum allowed value
        if (ttl > MAX_TTL) {
            revert InvalidTTL();
        }

        if (data.length > MAX_CALL_DATA_LENGTH) {
            revert CallDataTooLarge();
        }

        // Reject start blocks in the past
        if (startBlock <= uint32(block.number)) {
            revert StartBlockInPast();
        }

        // Reject schedules whose horizon cannot fit uint32 block space.
        // This avoids downstream overflow panics during execute()/cleanup.
        uint256 expiryBlock = _calculateExpiryBlock(startBlock, frequency, numCalls, ttl);
        if (expiryBlock > type(uint32).max) {
            revert ScheduleHorizonOverflow();
        }

        // Bound total schedule residency so slots do not accumulate calls for years.
        uint256 lifespan = expiryBlock - uint256(startBlock);
        if (lifespan > MAX_LIFESPAN) {
            revert ScheduleLifespanExceeded();
        }

        // EIP-1559 fee fields are u128 in the execution layer; reject values that would overflow
        if (maxFeePerGas > type(uint128).max || maxPriorityFeePerGas > type(uint128).max) {
            revert FeeExceedsU128();
        }

        if (maxFeePerGas < MIN_SCHEDULED_MAX_FEE_PER_GAS) {
            revert MaxFeePerGasBelowFloor();
        }

        // Charge slot residency up front, then prove one execution remains affordable.
        uint256 maxExecutionCost = (maxFeePerGas * gas) + value;
        uint256 residencyFee = SCHEDULED_RESIDENCY_FEE_PER_BLOCK * (expiryBlock - block.number);
        if (
            RITUAL_WALLET.deductScheduledExecutionFeesFrom(sponsor, msg.sender, 0, 0, 0, residencyFee, id)
                != residencyFee
        ) {
            revert InsufficientWalletFunds();
        }
        if (sponsor != msg.sender && RITUAL_WALLET.allowance(sponsor, msg.sender) < maxExecutionCost) {
            revert UnauthorizedSponsor();
        }

        // Validate sponsor has sufficient funds in system wallet
        if (RITUAL_WALLET.availableBalance(sponsor) < maxExecutionCost) {
            revert InsufficientWalletFunds();
        }

        // Allocate a slot at the end of dynamic storage
        uint256 slotIndex = _allocateSlot();

        // Create and store `Call` in the allocated slot
        slots[slotIndex] = Call({
            to: msg.sender,
            sponsor: sponsor,
            startBlock: startBlock,
            numCalls: numCalls,
            frequency: frequency,
            gas: gas,
            ttl: ttl,
            state: CallState.SCHEDULED,
            maxFeePerGas: maxFeePerGas,
            maxPriorityFeePerGas: maxPriorityFeePerGas,
            value: value,
            data: data,
            callId: id
        });

        // Map call ID to slot index
        callToSlot[id] = slotIndex;
        // callId is stored inside the struct; reverse lookup not needed

        // Capture origin transaction hash via precompile for contract-state augmentation.
        // This allows the block builder to reconstruct TxScheduled without event processing.
        (bool hashOk, bytes memory hashResult) = TX_HASH_PRECOMPILE.staticcall("");
        if (hashOk && hashResult.length == 32) {
            originHash[id] = bytes32(hashResult);
        }

        // Emit enriched creation event with complete metadata
        // Use sponsor (not msg.sender) to match storage and ensure consistent FSM
        emit CallScheduled(
            id,
            msg.sender,
            sponsor,
            startBlock,
            numCalls,
            frequency,
            gas,
            ttl,
            maxFeePerGas,
            maxPriorityFeePerGas,
            value,
            data
        );

        // Pay the proposer their residency fee via the wallet's pull-model credit rather than a
        // direct push to block.coinbase. schedule() is a user transaction, so a contract coinbase
        // that reverts or burns gas on receipt could otherwise grief every caller at their expense
        // (and farm their gas). Crediting the wallet runs no proposer-controlled code; the proposer
        // withdraws later. This mirrors how AsyncDelivery pays block.coinbase through the wallet.
        uint256 callId = id++;
        RITUAL_WALLET.creditProposer{value: residencyFee}(block.coinbase, callId);
        return callId;
    }

    /// @notice Allows a smart contract to schedule a (optionally, repeating) callback
    /// @dev Cannot be called from within a calling contracts `constructor`
    /// @param data function input data
    /// @param gas gasLimit per call
    /// @param startBlock block number when first execution should occur
    /// @param numCalls fixed number of executions
    /// @param frequency number of blocks between each subsequent call
    /// @param ttl maximum drift tolerance in blocks (used for implicit expiry)
    /// @param maxFeePerGas EIP-1559 max fee per gas
    /// @param maxPriorityFeePerGas EIP-1559 max priority fee per gas
    /// @param value ETH value to transfer with each call
    /// @param sponsor Address whose RitualWallet balance sponsors the call. Must be msg.sender or have sufficient RitualWallet allowance for msg.sender.
    /// @dev Multi-call schedules are not fully escrowed up front. The sponsor only needs
    ///      enough balance/allowance for one max-cost execution when scheduling; each
    ///      execution is charged just in time, and insolvency evicts the remaining schedule.
    /// @return scheduler `Call` ID
    function schedule(
        bytes memory data,
        uint32 gas,
        uint32 startBlock,
        uint32 numCalls,
        uint32 frequency,
        uint32 ttl,
        uint256 maxFeePerGas,
        uint256 maxPriorityFeePerGas,
        uint256 value,
        address sponsor
    ) external returns (uint256) {
        return _schedule(
            data, gas, startBlock, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, value, sponsor
        );
    }

    /// @notice Schedule with auto-calculated start block (startBlock = currentBlock + frequency)
    /// @dev sponsor defaults to msg.sender (self-pay)
    /// @param data function input data
    /// @param gas gasLimit per call
    /// @param numCalls fixed number of executions
    /// @param frequency number of blocks between each subsequent call
    /// @param ttl maximum drift tolerance in blocks
    /// @param maxFeePerGas EIP-1559 max fee per gas
    /// @param maxPriorityFeePerGas EIP-1559 max priority fee per gas
    /// @param value ETH value to transfer with each call
    /// @dev Multi-call schedules are not fully escrowed up front. The sponsor only needs
    ///      enough balance for one max-cost execution when scheduling; each execution is
    ///      charged just in time, and insolvency evicts the remaining schedule.
    /// @return scheduler `Call` ID
    function schedule(
        bytes memory data,
        uint32 gas,
        uint32 numCalls,
        uint32 frequency,
        uint32 ttl,
        uint256 maxFeePerGas,
        uint256 maxPriorityFeePerGas,
        uint256 value
    ) external returns (uint256) {
        uint32 startBlock = uint32(block.number) + frequency;
        return _schedule(
            data, gas, startBlock, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, value, msg.sender
        );
    }

    /// @notice Schedule with auto-calculated start block and explicit sponsor
    /// @param data function input data
    /// @param gas gasLimit per call
    /// @param numCalls fixed number of executions
    /// @param frequency number of blocks between each subsequent call
    /// @param ttl maximum drift tolerance in blocks
    /// @param maxFeePerGas EIP-1559 max fee per gas
    /// @param maxPriorityFeePerGas EIP-1559 max priority fee per gas
    /// @param value ETH value to transfer with each call
    /// @param sponsor Address whose RitualWallet balance sponsors the call. Must be msg.sender or have sufficient RitualWallet allowance for msg.sender.
    /// @dev Multi-call schedules are not fully escrowed up front. The sponsor only needs
    ///      enough balance/allowance for one max-cost execution when scheduling; each
    ///      execution is charged just in time, and insolvency evicts the remaining schedule.
    /// @return scheduler `Call` ID
    function schedule(
        bytes memory data,
        uint32 gas,
        uint32 numCalls,
        uint32 frequency,
        uint32 ttl,
        uint256 maxFeePerGas,
        uint256 maxPriorityFeePerGas,
        uint256 value,
        address sponsor
    ) external returns (uint256) {
        uint32 startBlock = uint32(block.number) + frequency;
        return
            _schedule(
                data, gas, startBlock, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, value, sponsor
            );
    }

    /// @notice Schedule with minimal parameters (defaults for common cases)
    /// @dev sponsor defaults to msg.sender (self-pay)
    /// @param data function input data
    /// @param gas gasLimit per call
    /// @param numCalls fixed number of executions
    /// @param frequency number of blocks between each subsequent call
    /// @return scheduler `Call` ID
    function schedule(bytes memory data, uint32 gas, uint32 numCalls, uint32 frequency) external returns (uint256) {
        uint32 startBlock = uint32(block.number) + frequency;
        return _schedule(data, gas, startBlock, numCalls, frequency, 0, uint256(block.basefee), 0, 0, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                        SCHEDULE WITH PREDICATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Internal function to validate and set a predicate for a call
    /// @param callId The call ID to set the predicate for
    /// @param predicate The predicate contract address (0 = use default)
    function _setCallPredicate(uint256 callId, address predicate) internal {
        if (predicate == address(0)) {
            // Zero address means use default - no need to store
            return;
        }

        // Validate that the predicate implements IScheduledPredicate
        // We do a try-catch call to shouldExecute to verify the interface
        try IScheduledPredicate(predicate).shouldExecute(address(this), 0, 0) returns (
            bool
        ) {
        // Interface is valid
        }
        catch {
            revert InvalidPredicate();
        }

        // Store the predicate
        callPredicates[callId] = predicate;
        emit PredicateSet(callId, predicate);
    }

    /// @notice Schedule a call with a custom predicate (full parameters with startBlock)
    /// @dev sponsor defaults to msg.sender (self-pay)
    /// @param data function input data
    /// @param gas gasLimit per call
    /// @param startBlock block number when first execution should occur
    /// @param numCalls fixed number of executions
    /// @param frequency number of blocks between each subsequent call
    /// @param ttl maximum drift tolerance in blocks
    /// @param maxFeePerGas EIP-1559 max fee per gas
    /// @param maxPriorityFeePerGas EIP-1559 max priority fee per gas
    /// @param value ETH value to transfer with each call
    /// @param sponsor Address whose RitualWallet balance sponsors the call. Must be msg.sender or have sufficient RitualWallet allowance for msg.sender.
    /// @param predicate address of predicate contract (0 = always true)
    /// @return scheduler `Call` ID
    function schedule(
        bytes memory data,
        uint32 gas,
        uint32 startBlock,
        uint32 numCalls,
        uint32 frequency,
        uint32 ttl,
        uint256 maxFeePerGas,
        uint256 maxPriorityFeePerGas,
        uint256 value,
        address sponsor,
        address predicate
    ) external returns (uint256) {
        uint256 callId = _schedule(
            data, gas, startBlock, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, value, sponsor
        );
        _setCallPredicate(callId, predicate);
        return callId;
    }

    /// @notice Schedule with auto-calculated start block and custom predicate
    /// @param data function input data
    /// @param gas gasLimit per call
    /// @param numCalls fixed number of executions
    /// @param frequency number of blocks between each subsequent call
    /// @param ttl maximum drift tolerance in blocks
    /// @param maxFeePerGas EIP-1559 max fee per gas
    /// @param maxPriorityFeePerGas EIP-1559 max priority fee per gas
    /// @param value ETH value to transfer with each call
    /// @param sponsor Address whose RitualWallet balance sponsors the call. Must be msg.sender or have sufficient RitualWallet allowance for msg.sender.
    /// @param predicate address of predicate contract (0 = always true)
    /// @return scheduler `Call` ID
    function schedule(
        bytes memory data,
        uint32 gas,
        uint32 numCalls,
        uint32 frequency,
        uint32 ttl,
        uint256 maxFeePerGas,
        uint256 maxPriorityFeePerGas,
        uint256 value,
        address sponsor,
        address predicate
    ) external returns (uint256) {
        uint32 startBlock = uint32(block.number) + frequency;
        uint256 callId = _schedule(
            data, gas, startBlock, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, value, sponsor
        );
        _setCallPredicate(callId, predicate);
        return callId;
    }

    /// @notice Schedule with minimal parameters and custom predicate
    /// @dev sponsor defaults to msg.sender (self-pay)
    /// @param data function input data
    /// @param gas gasLimit per call
    /// @param numCalls fixed number of executions
    /// @param frequency number of blocks between each subsequent call
    /// @param predicate address of predicate contract (0 = always true)
    /// @return scheduler `Call` ID
    function schedule(bytes memory data, uint32 gas, uint32 numCalls, uint32 frequency, address predicate)
        external
        returns (uint256)
    {
        uint32 startBlock = uint32(block.number) + frequency;
        uint256 callId =
            _schedule(data, gas, startBlock, numCalls, frequency, 0, uint256(block.basefee), 0, 0, msg.sender);
        _setCallPredicate(callId, predicate);
        return callId;
    }

    /// @notice Get the predicate for a call
    /// @param callId The call ID
    /// @return The predicate address (address(0) means no custom predicate / always execute)
    function getCallPredicate(uint256 callId) external view returns (address) {
        return callPredicates[callId];
    }

    /// @notice Allows cancelling a scheduled `Call`
    /// @dev Refunds remainder of payment deposit
    /// @param callId scheduler `Call` ID
    function cancel(uint256 callId) external {
        // Get the call from circular buffer
        Call storage call = _getCall(callId);

        // Ensure `msg.sender` owns ID
        if (msg.sender != call.to) {
            revert UnauthorizedSender();
        }

        // Check if call is in a cancellable state
        if (call.state != CallState.SCHEDULED) {
            revert InvalidCallState();
        }

        // Update state and emit state change event
        CallState oldState = call.state;
        call.state = CallState.CANCELLED;
        emit CallStateChanged(callId, call.to, oldState, CallState.CANCELLED);

        // Emit enriched cancellation event with metadata
        emit CallCancelled(callId, call.to, call.sponsor, call.startBlock, call.numCalls, call.frequency);

        _clearBitmap(callId);

        // Free the slot back to the available pool
        uint256 slotIndex = callToSlot[callId];
        _freeSlot(slotIndex);

        // Remove the call ID mapping and auxiliary storage
        delete callToSlot[callId];
        delete originHash[callId];
        delete callPredicates[callId];

        // No refund calculation needed - wallet-based system handles this
        // Wallet funds remain available for sponsor to withdraw normally
    }

    /// @notice Owner-only emergency path to wipe a specific call by ID
    /// @dev This bypasses the `call.to` ownership check in `cancel()` and is intended
    ///      for operational recovery when a call cannot be cancelled by its scheduler contract.
    ///
    ///      Reverts `CallNotFound` when the call has already terminated
    ///      (COMPLETED/CANCELLED/EXPIRED free the slot, so `_getCall` fails first).
    ///      Unlike `cancel()`, this intentionally permits non-SCHEDULED live states.
    ///      It is the owner recovery path for stale/corrupted scheduler records,
    ///      including durable `EXECUTING` calls left behind by earlier bugs.
    /// @param callId scheduler `Call` ID
    function forceCancel(uint256 callId) external onlyOwner {
        // Get the call from circular buffer
        Call storage call = _getCall(callId);

        // Capture the previous state for operator observability.
        CallState previousState = call.state;

        // Mark as cancelled and emit both generic and privileged cancellation signals.
        call.state = CallState.CANCELLED;
        emit CallStateChanged(callId, call.to, previousState, CallState.CANCELLED);
        emit CallCancelled(callId, call.to, call.sponsor, call.startBlock, call.numCalls, call.frequency);
        emit CallForceCancelled(callId, msg.sender, previousState);

        _clearBitmap(callId);

        // Free the slot back to the available pool
        uint256 slotIndex = callToSlot[callId];
        _freeSlot(slotIndex);

        // Remove the call ID mapping and auxiliary storage
        delete callToSlot[callId];
        delete originHash[callId];
        delete callPredicates[callId];
    }

    function _evictInsufficientFunds(uint256 callId, Call storage call, uint256 requiredAmount, uint256 availableAmount)
        internal
    {
        address to = call.to;
        address sponsor = call.sponsor;
        _cancelScheduledCall(callId, call);
        emit CallEvictedInsufficientFunds(callId, to, sponsor, requiredAmount, availableAmount);
    }

    function _cancelScheduledCall(uint256 callId, Call storage call) internal {
        address to = call.to;
        address sponsor = call.sponsor;
        uint32 startBlock = call.startBlock;
        uint32 numCalls = call.numCalls;
        uint32 frequency = call.frequency;
        CallState oldState = call.state;

        call.state = CallState.CANCELLED;
        emit CallStateChanged(callId, to, oldState, CallState.CANCELLED);
        emit CallCancelled(callId, to, sponsor, startBlock, numCalls, frequency);

        _clearBitmap(callId);

        uint256 slotIndex = callToSlot[callId];
        _freeSlot(slotIndex);

        delete callToSlot[callId];
        delete originHash[callId];
        delete callPredicates[callId];
    }

    /// @notice Allows `SYSTEM_ACCOUNT` to execute a `Call`
    /// @param callId `Call` to execute
    /// @param executionIndex Which execution this is (0-based for recurring calls)
    /// @dev Enforces contract-local invariants (system caller, SCHEDULED state, index bounds, replay,
    ///      earliest block, TTL/expiry, predicate gating, and JIT solvency). It intentionally does not
    ///      enforce strict monotonic index ordering: overlapping execution windows may complete out of
    ///      order, especially when scheduled callbacks start asynchronous work whose results settle at
    ///      variable times. Reth owns canonical scheduled transaction body matching and duplicate/window
    ///      validity, but does not require index `n - 1` to complete before index `n`.
    function execute(uint256 callId, uint256 executionIndex) external payable {
        _execute(callId, executionIndex);
    }

    /// @notice Executes a call after reclaiming a bounded batch of explicitly selected expired slots.
    /// @param callId `Call` to execute
    /// @param executionIndex Which execution this is (0-based for recurring calls)
    /// @param cleanupCallIds Explicit call IDs to check for expiry before executing `callId`
    /// @dev An empty batch is valid. Cleanup completes before `_execute` resolves `callId`,
    ///      because dense slot compaction may move the target call.
    function execute(uint256 callId, uint256 executionIndex, uint256[] calldata cleanupCallIds) external payable {
        if (cleanupCallIds.length > MAX_CLEANUP_BATCH) {
            revert InvalidCleanupBatchSize();
        }
        // The target must remain available for `_execute`, which owns its normal
        // expiry and execution semantics.
        _cleanupExpiredCallsByIds(cleanupCallIds, callId, true);
        _execute(callId, executionIndex);
    }

    function _execute(uint256 callId, uint256 executionIndex) internal {
        // Any cleanup above rolls back atomically if the caller is unauthorized.
        if (msg.sender != SYSTEM_ACCOUNT) {
            revert SenderNotSystemAccount();
        }

        // Resolve only the requested call. Scheduled execution must never scan
        // unrelated slots.
        Call storage call = _getCall(callId);
        // Snapshot fields used after target-controlled execution. The storage
        // reference may be stale after reentrant Scheduler calls move slots.
        CallExecutionSnapshot memory callSnapshot = _snapshotCall(call);

        // Check if call is in executable state
        if (call.state != CallState.SCHEDULED) {
            revert InvalidCallState();
        }

        // Check if execution index is valid
        if (executionIndex >= callSnapshot.numCalls) {
            revert InvalidExecutionIndex();
        }

        // Cross-block replay protection: revert if this index was already executed
        if (isExecuted(callId, executionIndex)) {
            revert AlreadyExecuted();
        }

        // Calculate expected block for this execution
        uint256 expectedBlock = _calculateExpectedBlock(callSnapshot.startBlock, callSnapshot.frequency, executionIndex);

        if (block.number < expectedBlock) {
            revert ExecutionNotDue(expectedBlock, block.number);
        }

        // Check if the overall call has expired (last execution + TTL)
        // This must be checked first, as it's the definitive expiry for the entire call
        uint256 overallExpiryBlock = _calculateExpiryBlock(
            callSnapshot.startBlock, callSnapshot.frequency, callSnapshot.numCalls, callSnapshot.ttl
        );
        if (block.number > overallExpiryBlock) {
            // Overall call has expired - clean up instead of reverting (RAII compliance)
            _clearBitmap(callId);
            uint256 slotIndex = callToSlot[callId];
            call.state = CallState.EXPIRED;
            emit CallStateChanged(callId, callSnapshot.to, CallState.SCHEDULED, CallState.EXPIRED);
            emit CallExpired(
                callId,
                callSnapshot.to,
                callSnapshot.sponsor,
                callSnapshot.startBlock,
                _eventExpiryBlock(overallExpiryBlock),
                block.number
            );

            // Free the slot back to the available pool
            _freeSlot(slotIndex);

            // Remove the call ID mapping and auxiliary storage
            delete callToSlot[callId];
            delete originHash[callId];
            delete callPredicates[callId];
            return;
        }

        // Check if this specific execution's TTL window has expired
        // For the last execution, this check is redundant (already checked overallExpiryBlock above)
        // For earlier executions, skip this execution but keep call alive for later executions
        uint256 executionExpiryBlock = expectedBlock + uint256(callSnapshot.ttl);
        if (block.number > executionExpiryBlock) {
            // This specific execution's TTL has expired - skip it but keep the call in SCHEDULED
            // state so later executions can still proceed if their TTL windows haven't expired.
            //
            // Record the index as consumed before returning. A TTL-expired execution can never
            // become valid again (its window only recedes further into the past), so marking it
            // here makes the skip idempotent: any later attempt to run the same index reverts with
            // AlreadyExecuted instead of re-emitting the skip and re-running this no-op path, which
            // the privileged system execution path could otherwise do every block until the whole
            // schedule expired. Reth reads this same bitmap for its C10 (already-executed) filter,
            // so the builder/verifier also stop reconsidering the index. The skip stays
            // distinguishable from a real execution via the CallSkippedTTLExpired event, and the bit
            // is reclaimed by _clearBitmap on completion/expiry/cancellation.
            _markExecuted(callId, executionIndex);
            emit CallSkippedTTLExpired(
                callId, callSnapshot.to, callSnapshot.sponsor, expectedBlock, block.number, callSnapshot.ttl
            );

            // Indices may be consumed out of order, so this skip can fill the LAST outstanding
            // bit. Run the same completion transition the execution path performs; otherwise the
            // call would sit SCHEDULED with a full bitmap forever, every index rejecting as
            // AlreadyExecuted, never reaching a terminal state (Zellic 3.8). Nothing was
            // executed and no fee was charged: this branch returns before any fee arithmetic,
            // so completion here records zero gas and zero payment for the skipped index.
            // No statement may follow: _completeCall frees the slot, invalidating `call`.
            if (_allExecutionIndicesConsumed(callId, callSnapshot.numCalls)) {
                _completeCall(callId, call, CallState.SCHEDULED);
            }
            return;
        }

        // Calculate proper EIP-1559 effective fee for deduction
        uint256 baseFee = block.basefee;
        if (baseFee > callSnapshot.maxFeePerGas) {
            uint256 requiredAmount = (baseFee * callSnapshot.gas) + callSnapshot.value;
            uint256 availableAmount = RITUAL_WALLET.availableBalance(callSnapshot.sponsor);
            emit CallSkippedInsufficientFunds(
                callId, callSnapshot.to, callSnapshot.sponsor, requiredAmount, availableAmount
            );
            // A base-fee spike is a temporary market condition, not sponsor insolvency.
            // Keep the job scheduled so it can execute in a later block when baseFee falls.
            return;
        }

        address predicate = callPredicates[callId];
        if (predicate != address(0)) {
            bytes memory predicateCalldata =
                abi.encodeCall(IScheduledPredicate.shouldExecute, (callSnapshot.to, callId, executionIndex));
            bool predicateOk;
            uint256 predicateResultSize;
            uint256 predicateValue;
            uint256 predicateGasLimit = MAX_PREDICATE_GAS;
            assembly ("memory-safe") {
                predicateOk := staticcall(
                    predicateGasLimit,
                    predicate,
                    add(predicateCalldata, 0x20),
                    mload(predicateCalldata),
                    0,
                    0x20
                )
                predicateResultSize := returndatasize()
                predicateValue := mload(0)
            }
            if (!predicateOk || predicateResultSize < 32 || predicateValue != 1) {
                PredicateSkipReason reason = predicateOk && predicateResultSize >= 32 && predicateValue == 0
                    ? PredicateSkipReason.PredicateFalse
                    : PredicateSkipReason.PredicateCheckFailed;
                // Builder and verifier pre-filter predicates against parent state. This uncharged
                // contract path is only the backstop for a predicate changing later in the block;
                // it must not replace that pre-filter. The index remains pending for a later attempt.
                emit CallExecutionSkipped(callId, executionIndex, reason);
                return;
            }
        }

        // NOW set executing after validation passes
        call.state = CallState.EXECUTING;
        emit CallStateChanged(callId, callSnapshot.to, CallState.SCHEDULED, CallState.EXECUTING);

        uint256 priorityFee = callSnapshot.maxPriorityFeePerGas;

        // Cap priority fee if it would exceed maxFeePerGas
        if (baseFee + priorityFee > callSnapshot.maxFeePerGas) {
            priorityFee = callSnapshot.maxFeePerGas - baseFee;
        }

        uint256 effectiveFeePerGas = baseFee + priorityFee;

        // Deduct execution fees from sponsor's account in system wallet.
        uint256 feesPaid = RITUAL_WALLET.deductScheduledExecutionFeesFrom(
            callSnapshot.sponsor, callSnapshot.to, effectiveFeePerGas, callSnapshot.gas, callSnapshot.value, 0, callId
        );

        // If wallet deduction failed (insufficient funds), emit event and skip execution
        if (feesPaid == 0) {
            Call storage currentCall = _getExecutingCall(callId);
            // Insufficient funds for this execution attempt - return to scheduled for retry
            currentCall.state = CallState.SCHEDULED;
            emit CallStateChanged(callId, callSnapshot.to, CallState.EXECUTING, CallState.SCHEDULED);
            uint256 requiredAmount = (effectiveFeePerGas * callSnapshot.gas) + callSnapshot.value;
            uint256 availableAmount = RITUAL_WALLET.availableBalance(callSnapshot.sponsor);
            emit CallSkippedInsufficientFunds(
                callId, callSnapshot.to, callSnapshot.sponsor, requiredAmount, availableAmount
            );
            _evictInsufficientFunds(callId, currentCall, requiredAmount, availableAmount);
            return;
        }

        // Build the scheduled callback dispatch. The Scheduler never mutates the caller-provided scheduling
        // data: it is passed through verbatim as the `payload` argument of `onScheduledExecution`, and the
        // execution index is delivered as a separate, explicit, typed argument. This makes the Scheduler
        // provably non-corrupting for any payload (including empty) and removes the implicit "first calldata
        // word is the execution index" convention. See IScheduledCallback for the full ABI contract.
        bytes memory callbackData =
            abi.encodeCall(IScheduledCallback.onScheduledExecution, (executionIndex, callSnapshot.data));

        // Mark this (callId, index) as executed before the call (CEI: effect before interaction)
        _markExecuted(callId, executionIndex);

        // Measure gas only for the actual call
        uint256 startGas = gasleft();
        (bool success,) = callSnapshot.to.call{gas: callSnapshot.gas, value: callSnapshot.value}(callbackData);
        uint256 gasUsed = startGas - gasleft();

        // The measured window also contains the CALL opcode envelope (cold access, value surcharge,
        // stipend), which is not part of the sponsor's callback budget. Clamp so `gasUsed <= gas`
        // holds for the fee math, the emitted events (which Reth uses as this system tx's block gas
        // contribution) and the burn/tip split below — otherwise a reverted callback that carried
        // value would be under-refunded by the envelope and that amount stranded here.
        if (gasUsed > callSnapshot.gas) {
            gasUsed = callSnapshot.gas;
        }

        // The scheduled target may have re-entered Scheduler and moved this call
        // by cancelling another slot. Reload by callId before any post-call state
        // transition and discard pre-call storage references.
        Call storage postCall = _getExecutingCall(callId);

        if (!success) {
            // Calculate actual fee using the same effective fee per gas (no value on failure)
            uint256 actualFailedCallFee = effectiveFeePerGas * gasUsed;

            // Refund only the value portion and any excess gas fees. A refund failure is a
            // protocol accounting invariant violation for scheduled system transactions, so
            // it must revert execute() and make the scheduled transaction block-invalid.
            if (feesPaid > actualFailedCallFee) {
                uint256 refundAmount = feesPaid - actualFailedCallFee;
                RITUAL_WALLET.refundGas{value: refundAmount}(callSnapshot.sponsor, refundAmount, callId);
            }

            // Handle state transition after failed execution
            _handlePostExecution(callId, postCall, executionIndex, false);

            emit CallExecutionFailed(
                callId,
                callSnapshot.to,
                callSnapshot.sponsor,
                callSnapshot.startBlock,
                callSnapshot.numCalls,
                callSnapshot.frequency,
                executionIndex,
                gasUsed,
                "Execution reverted"
            );

            _distributeGasFees(callId, priorityFee, gasUsed, effectiveFeePerGas * callSnapshot.gas);
            return; // User pays for gas consumed, but value is refunded
        }

        // Calculate actual fee using the same effective fee per gas
        uint256 actualCallFee = (effectiveFeePerGas * gasUsed) + callSnapshot.value;

        // Refund the difference - sponsor only pays for the actual call. A refund failure is
        // block-invalid for the same protocol-accounting reason as the failure path above.
        if (feesPaid > actualCallFee) {
            uint256 refundAmount = feesPaid - actualCallFee;
            RITUAL_WALLET.refundGas{value: refundAmount}(callSnapshot.sponsor, refundAmount, callId);
        }

        // Handle state transition after successful execution
        _handlePostExecution(callId, postCall, executionIndex, true);

        // Emit successful execution event with complete metadata
        emit CallExecuted(
            callId,
            callSnapshot.to,
            callSnapshot.sponsor,
            callSnapshot.startBlock,
            callSnapshot.numCalls,
            callSnapshot.frequency,
            executionIndex,
            gasUsed,
            feesPaid
        );

        _distributeGasFees(callId, priorityFee, gasUsed, effectiveFeePerGas * callSnapshot.gas);
    }

    /// @dev Pay the burn address the base fee and the block proposer the priority-fee tip for gas
    ///      consumed, funded from the fees already collected from the sponsor and held by this
    ///      contract. Scheduled transactions are excluded from the execution layer's default
    ///      EIP-1559 beneficiary reward (see ritual-revm `reward_beneficiary`), so all proposer
    ///      payment for them is performed here. The combined payout is capped at `gasFeeBudget` so a scheduled
    ///      call can never pay out more than the sponsor-funded callback gas budget — it can never
    ///      mint. `priorityFee * gasUsed` is the same tip the default reward would have paid, but
    ///      metered on the target call's gas rather than the whole system transaction.
    ///      The tip is credited to the proposer's wallet balance (pull model) rather than pushed
    ///      to `block.coinbase`, so no proposer-controlled code runs and every proposer payout in
    ///      the protocol goes through the same wallet mechanism.
    function _distributeGasFees(uint256 callId, uint256 priorityFee, uint256 gasUsed, uint256 gasFeeBudget) private {
        uint256 baseFee = block.basefee * gasUsed;
        if (baseFee > gasFeeBudget) {
            baseFee = gasFeeBudget;
        }
        payable(BURN_ADDRESS).transfer(baseFee);
        uint256 tip = priorityFee * gasUsed;
        if (tip > gasFeeBudget - baseFee) {
            tip = gasFeeBudget - baseFee;
        }
        if (tip != 0) {
            RITUAL_WALLET.creditProposer{value: tip}(block.coinbase, callId);
        }
    }

    /// @dev Validates and records AsyncJobTracker admission without consuming the Scheduler bitmap.
    ///      Reth suppresses duplicate commitments while the async job is active.
    function markScheduledAsyncInFlight(uint256 callId, uint256 executionIndex, bytes32 jobId) external {
        _onlyAsyncJobTracker();
        Call storage call = _getCall(callId);
        _validateScheduledAsyncPending(callId, call, executionIndex, jobId);
        emit ScheduledAsyncInFlight(callId, executionIndex, jobId);
    }

    function cleanupInvalidScheduledAsync(uint256 callId, uint256 executionIndex, bytes32 jobId, bytes32 reason)
        external
    {
        if (msg.sender != ASYNC_COMMITMENT_SYSTEM_ACCOUNT) {
            revert UnauthorizedSender();
        }
        Call storage call = _getCall(callId);
        _validateScheduledAsyncPending(callId, call, executionIndex, jobId);
        scheduledAsyncCleanupReasons[_scheduledAsyncKey(callId, executionIndex)] = reason;
        _cancelScheduledCall(callId, call);
        emit ScheduledAsyncEvicted(callId, executionIndex, jobId, reason);
    }

    function scheduledAsyncCleanupReason(uint256 callId, uint256 executionIndex) external view returns (bytes32) {
        return scheduledAsyncCleanupReasons[_scheduledAsyncKey(callId, executionIndex)];
    }

    /// @notice Expire a single SCHEDULED call and release all of its storage
    /// @dev Assumes the caller has already confirmed the call is expired.
    function _expireCall(uint256 callId, uint256 slotIndex, Call storage call, uint256 expiryBlock) internal {
        _clearBitmap(callId);

        // Mark as expired and clean up
        call.state = CallState.EXPIRED;
        emit CallStateChanged(callId, call.to, CallState.SCHEDULED, CallState.EXPIRED);
        emit CallExpired(callId, call.to, call.sponsor, call.startBlock, _eventExpiryBlock(expiryBlock), block.number);

        // Free the slot back to the available pool
        _freeSlot(slotIndex);

        // Remove the call ID mapping and auxiliary storage
        delete callToSlot[callId];
        delete originHash[callId];
        delete callPredicates[callId];
    }

    /// @notice Expire one explicitly selected call if it is past its implicit expiry.
    /// @dev Missing, terminal, unexpired, and non-SCHEDULED call IDs are idempotent no-ops.
    function _cleanupExpiredCallById(uint256 callId) internal {
        uint256 slotIndex = callToSlot[callId];
        if (slotIndex < slots.length) {
            Call storage call = slots[slotIndex];
            if (call.callId == callId && call.to != address(0)) {
                uint256 expiryBlock = _calculateExpiryBlock(call.startBlock, call.frequency, call.numCalls, call.ttl);
                if (block.number > expiryBlock && call.state == CallState.SCHEDULED) {
                    _expireCall(callId, slotIndex, call, expiryBlock);
                }
            }
        }
    }

    /// @notice Expire the given call IDs if they are past their implicit expiry.
    /// @param protectedCallId Call ID to skip when `protectCallId` is true.
    /// @param protectCallId Whether to leave `protectedCallId` for subsequent execution.
    function _cleanupExpiredCallsByIds(uint256[] calldata callIds, uint256 protectedCallId, bool protectCallId)
        internal
    {
        uint256 n = callIds.length;
        for (uint256 i = 0; i < n;) {
            uint256 cleanupCallId = callIds[i];
            if (!protectCallId || cleanupCallId != protectedCallId) {
                _cleanupExpiredCallById(cleanupCallId);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Clean up caller-supplied expired calls by explicit ID
    /// @param callIds Explicit call IDs to check and clean up if expired
    function cleanupExpiredCalls(uint256[] calldata callIds) external {
        if (callIds.length == 0) {
            revert InvalidCleanupBatchSize();
        }
        _cleanupExpiredCallsByIds(callIds, 0, false);
    }

    /// @notice Get the current state of a call
    /// @param callId The call ID to check
    /// @return The current state of the call
    /// @dev Reverts if call doesn't exist (was never created or was deleted after completion)
    function getCallState(uint256 callId) external view returns (CallState) {
        Call storage call = _getCall(callId);
        return call.state;
    }

    /// @notice Get call details by ID (replacement for calls mapping)
    /// @param callId The call ID to retrieve
    function calls(uint256 callId)
        external
        view
        returns (
            address to,
            address sponsor,
            uint32 startBlock,
            uint32 numCalls,
            uint32 frequency,
            uint32 gas,
            uint32 ttl,
            CallState state,
            uint256 maxFeePerGas,
            uint256 maxPriorityFeePerGas,
            uint256 value,
            bytes memory data
        )
    {
        Call storage call = _getCall(callId);
        return (
            call.to,
            call.sponsor,
            call.startBlock,
            call.numCalls,
            call.frequency,
            call.gas,
            call.ttl,
            call.state,
            call.maxFeePerGas,
            call.maxPriorityFeePerGas,
            call.value,
            call.data
        );
    }

    /*//////////////////////////////////////////////////////////////
                                 FALLBACK
    //////////////////////////////////////////////////////////////*/

    /// @notice Allow ETH deposits to `Scheduler`
    receive() external payable {}

    /// @notice Non-refundable admission fee charged per block of scheduled slot residency.
    uint256 public SCHEDULED_RESIDENCY_FEE_PER_BLOCK = 10_000_000_000_000_000;

    /*//////////////////////////////////////////////////////////////
                            STORAGE GAP
    //////////////////////////////////////////////////////////////*/

    /// @dev Reserved storage space for future upgrades
    uint256[45] private __gap;
}
