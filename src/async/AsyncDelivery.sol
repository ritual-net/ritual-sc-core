// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.28;

import {IRitualWallet} from "../wallet/IRitualWallet.sol";
import {IAsyncJobTracker} from "./IAsyncJobTracker.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/**
 * @title AsyncDelivery - Async Settlement Coordinator
 * @notice Single entry point for all async settlement: Phase 1 (regular and long-running) and Phase 2 delivery.
 * @dev Hierarchy: reth → AsyncDelivery → {RitualWallet, AsyncJobTracker}
 *      AsyncJobTracker and RitualWallet are pure leaf contracts; only AsyncDelivery calls their
 *      state-mutating settlement methods.
 *
 *      Phase 1 (settle):     settle escrow → update job state (remove or markPhase1Settled)
 *      Phase 2 (deliver):    settle escrow → execute callback → refund unused callback budget → markDelivered
 *
 * Design Doc: projects-wiki/designs/08-zk-two-phase-delivery-design.md
 */
contract AsyncDelivery is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Async settlement system sender address
    address public constant ASYNC_SETTLEMENT_SYSTEM_SENDER = 0x000000000000000000000000000000000000fA9E;
    address private constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLE
    //////////////////////////////////////////////////////////////*/

    /// @notice RitualWallet contract for fee deduction and refunds
    IRitualWallet public immutable RITUAL_WALLET;

    /// @notice AsyncJobTracker contract for job lifecycle management
    IAsyncJobTracker public immutable ASYNC_JOB_TRACKER;

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when Phase 1 settlement completes (regular or long-running)
    /// @param jobId The job identifier
    /// @param sponsor The canonical escrow sponsor that funded the async job
    /// @param isLongRunning True if job has a Phase 2 delivery pending
    event Settled(bytes32 indexed jobId, address indexed sponsor, bool isLongRunning);

    /// @notice Emitted when a Phase 2 result is delivered
    /// @param jobId The job identifier
    /// @param sponsor The escrow sponsor refunded for unused callback gas/value
    /// @param target The target contract that received the callback
    /// @param success Whether the callback succeeded
    /// @param gasConsumed Gas consumed by the callback call envelope
    /// @param gasRefunded Gas refunded to sponsor
    /// @param valueRefunded Value refunded to sponsor (only if callback reverted)
    event Delivered(
        bytes32 indexed jobId,
        address indexed sponsor,
        address indexed target,
        bool success,
        uint256 gasConsumed,
        uint256 gasRefunded,
        uint256 valueRefunded
    );

    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Only settlement system can call this
    error OnlySettlementSystem();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlySettlementSystem() {
        if (msg.sender != ASYNC_SETTLEMENT_SYSTEM_SENDER) {
            revert OnlySettlementSystem();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _ritualWallet, address _asyncJobTracker) {
        _disableInitializers();
        RITUAL_WALLET = IRitualWallet(_ritualWallet);
        ASYNC_JOB_TRACKER = IAsyncJobTracker(_asyncJobTracker);
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize the AsyncDelivery contract with an owner
    /// @param _owner The address that will own the contract (for upgrade authorization)
    function initialize(address _owner) external initializer {
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
    }

    /// @notice Restricts upgrades to owner only
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Settle a Phase 1 async job: distribute fees and update job state
    /// @dev Called by reth's settlement transaction for both regular async and Phase 1 of long-running jobs.
    ///      Determines job type from tracker, pays fees via RitualWallet, then updates tracker state:
    ///        - Regular async: removeJob (job is complete)
    ///        - Long-running Phase 1: markPhase1Settled (job stays open for Phase 2)
    ///      Both paths settle wallet escrow before changing tracker lifecycle state.
    ///      Settlement fee fields are currently checked in reth rather than in this
    ///      contract; see ritual-reth-internal/crates/ritual/block-verification/src/lib.rs.
    ///
    /// @param jobId The job identifier (async transaction hash)
    /// @param executorFee Fee for executor
    /// @param commitmentFee Fee for commitment validator
    /// @param inclusionFee Fee for inclusion validator
    /// @param precompileInput The precompile input (SC-2: for hash verification in tracker)
    /// @return success True if settlement completed successfully
    function settle(
        bytes32 jobId,
        uint256 executorFee,
        uint256 commitmentFee,
        uint256 inclusionFee,
        bytes calldata precompileInput
    ) external onlySettlementSystem returns (bool success) {
        address escrowSponsor = RITUAL_WALLET.escrows(jobId).sponsor;
        (address executorPaymentAddress, address commitmentValidator) = ASYNC_JOB_TRACKER.getSettlementContext(jobId);

        bool isLongRunning = ASYNC_JOB_TRACKER.isLongRunning(jobId);

        IRitualWallet.Payment[] memory payments = new IRitualWallet.Payment[](3);
        payments[0] = IRitualWallet.Payment({to: payable(executorPaymentAddress), amount: executorFee});
        payments[1] = IRitualWallet.Payment({to: payable(commitmentValidator), amount: commitmentFee});
        payments[2] = IRitualWallet.Payment({to: payable(block.coinbase), amount: inclusionFee});

        if (isLongRunning) {
            uint64 phase2Deadline = ASYNC_JOB_TRACKER.computePhase2Deadline(jobId, precompileInput);
            RITUAL_WALLET.settle(jobId, payments, 0, phase2Deadline, false);
            ASYNC_JOB_TRACKER.markPhase1Settled(jobId, precompileInput);
        } else {
            RITUAL_WALLET.settle(jobId, payments, 0, 0, true);
            ASYNC_JOB_TRACKER.removeJob(jobId, precompileInput, true);
        }

        emit Settled(jobId, escrowSponsor, isLongRunning);
        return true;
    }

    /// @notice Deliver Phase 2 result with Scheduler-style gas accounting.
    /// @dev Reserves callback value plus max callback gas from the job escrow, executes
    ///      the callback, then refunds unused gas and reverted callback value to the
    ///      original escrow sponsor.
    ///      This function is called by the settlement transaction for Phase 2
    ///      The sponsor-funded callback budget intentionally covers the measured
    ///      callback call envelope, not every unit of gas spent by this coordinator.
    ///      Ritual-Reth treats AsyncSettlement wrapper execution as protocol/system work and
    ///      accounts Phase 2 block gas from Delivered.gasConsumed.
    ///      Delivery fee, callback, and result fields are currently checked in reth
    ///      rather than in this contract; see ritual-reth-internal/crates/ritual/block-verification/src/lib.rs.
    ///
    /// @param jobId The job identifier (async transaction hash)
    /// @param executorFee Fee for executor (ZK proof generation or polling)
    /// @param effectiveFeePerGas Fee per gas for callback (baseFee + priorityFee)
    /// @param callbackGasLimit Max gas for callback
    /// @param callbackValue ETH value to send with callback
    /// @param target Target contract for callback
    /// @param selector Function selector for callback
    /// @param precompileInput The precompile input (SC-2: for hash verification)
    /// @param result The result bytes to deliver
    /// @return success Whether the callback execution succeeded
    function deliver(
        bytes32 jobId,
        uint256 executorFee,
        uint256 effectiveFeePerGas,
        uint256 callbackGasLimit,
        uint256 callbackValue,
        address target,
        bytes4 selector,
        bytes calldata precompileInput, // SC-2: for hash verification
        bytes calldata result
    ) external onlySettlementSystem returns (bool success) {
        address sponsor = RITUAL_WALLET.escrows(jobId).sponsor;
        (address executorPaymentAddress,) = ASYNC_JOB_TRACKER.getSettlementContext(jobId);
        _requireDeliverable(jobId, precompileInput);

        uint256 callbackGasBudget = effectiveFeePerGas * callbackGasLimit;
        uint256 callbackBudget = callbackGasBudget + callbackValue;

        IRitualWallet.Payment[] memory payments = new IRitualWallet.Payment[](2);
        payments[0] = IRitualWallet.Payment({to: payable(executorPaymentAddress), amount: executorFee});
        payments[1] = IRitualWallet.Payment({to: payable(address(this)), amount: callbackBudget});
        RITUAL_WALLET.settle(jobId, payments, 0, 0, true);
        if (callbackBudget > 0) {
            // Escrow settlement credits wallet balances; delivery pulls its own budget to fund the callback.
            RITUAL_WALLET.withdraw(callbackBudget);
        }

        // STEP 2: Execute callback with gas limit and value (like Scheduler).
        // This measures the callback call envelope, including call setup overhead,
        // and is the value Reth uses for Phase 2 AsyncSettlement block gas accounting.
        // Outer deliver() coordinator gas is protocol/system overhead.
        uint256 gasBefore = gasleft();
        (success,) =
            target.call{gas: callbackGasLimit, value: callbackValue}(abi.encodeWithSelector(selector, jobId, result));
        uint256 gasConsumed = gasBefore - gasleft();

        // Cap at callbackGasLimit to prevent underflow
        // gasBefore - gasAfter includes CALL opcode overhead (~700 gas)
        // which can exceed callbackGasLimit when subcall uses all its gas
        if (gasConsumed > callbackGasLimit) {
            gasConsumed = callbackGasLimit;
        }

        // STEP 3: Calculate refund based on success/failure.
        // Refund accounting is part of the Phase 2 async system transaction invariant:
        // the escrow reserved callback gas/value up front, and the coordinator must
        // either refund the unused amount or revert the settlement transaction. A
        // refund failure is not an expected liveness branch; it indicates a protocol
        // accounting/configuration violation and must make the async settlement
        // receipt fail so Reth rejects the block.
        uint256 unusedGas = callbackGasLimit - gasConsumed;
        uint256 gasRefund = unusedGas * effectiveFeePerGas;
        uint256 valueRefund = 0;
        uint256 gasRefunded = 0;
        uint256 valueRefunded = 0;

        if (!success) {
            // Callback reverted - refund BOTH unused gas AND value
            // Value was returned to this contract by EVM when call reverted
            valueRefund = callbackValue;
            uint256 totalRefund = gasRefund + valueRefund;
            if (totalRefund > 0) {
                _refundGas(jobId, sponsor, totalRefund);
                gasRefunded = gasRefund;
                valueRefunded = valueRefund;
            }
        } else {
            // Callback succeeded - only refund unused gas (value was consumed)
            if (gasRefund > 0) {
                _refundGas(jobId, sponsor, gasRefund);
                gasRefunded = gasRefund;
            }
        }

        // STEP 4: Mark job as delivered in tracker (SC-2: pass precompileInput for hash verification)
        ASYNC_JOB_TRACKER.markDelivered(jobId, precompileInput, success);

        uint256 baseFee = block.basefee * gasConsumed;
        if (baseFee > callbackGasBudget) {
            baseFee = callbackGasBudget;
        }
        payable(BURN_ADDRESS).transfer(baseFee);
        uint256 tip = (effectiveFeePerGas - block.basefee) * gasConsumed;
        if (tip > callbackGasBudget - baseFee) {
            tip = callbackGasBudget - baseFee;
        }
        if (tip != 0) {
            // Pull-model proposer payout: credit the tip to the proposer's wallet balance rather
            // than pushing to block.coinbase, so no proposer-controlled code runs here and all
            // proposer payments (schedule residency, settle inclusion fee, tips) use one mechanism.
            RITUAL_WALLET.creditProposer{value: tip}(block.coinbase, uint256(jobId));
        }
        emit Delivered(jobId, sponsor, target, success, gasConsumed, gasRefunded, valueRefunded);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Refund unused Phase 2 callback budget. Reverts on failure so the async
    /// settlement transaction is block-invalid instead of canonicalizing broken
    /// protocol accounting.
    function _refundGas(bytes32 jobId, address sponsor, uint256 amount) internal {
        RITUAL_WALLET.refundGas{value: amount}(sponsor, amount, uint256(jobId));
    }

    function _requireDeliverable(bytes32 jobId, bytes calldata precompileInput) internal view {
        (bytes32 expectedInputHash,) = ASYNC_JOB_TRACKER.getInputHash(jobId);
        require(keccak256(precompileInput) == expectedInputHash, "input hash mismatch");
        require(ASYNC_JOB_TRACKER.isPhase1Settled(jobId), "phase1 not settled");
    }

    /*//////////////////////////////////////////////////////////////
                                FALLBACK
    //////////////////////////////////////////////////////////////*/

    /// @notice Accept ETH from RitualWallet escrow settlement for callback value.
    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                            STORAGE GAP
    //////////////////////////////////////////////////////////////*/

    /// @dev Reserved storage space for future upgrades
    uint256[50] private __gap;
}
