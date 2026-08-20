// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.28;

import {Test, stdError} from "forge-std/Test.sol";
import {AsyncDelivery} from "../src/async/AsyncDelivery.sol";
import {IAsyncJobTracker} from "../src/async/IAsyncJobTracker.sol";
import {IRitualWallet} from "../src/wallet/IRitualWallet.sol";
import {MockRitualWallet} from "./MockRitualWallet.sol";

contract MockAsyncJobTrackerForDelivery is IAsyncJobTracker {
    struct JobState {
        bool exists;
        bool longRunning;
        bool phase1Settled;
        bytes32 inputHash;
        uint256 inputSize;
        address executorPaymentAddress;
        address commitmentValidator;
    }

    mapping(bytes32 => JobState) internal jobs;
    mapping(bytes32 => bool) public delivered;
    mapping(bytes32 => bool) public deliverySuccess;

    function setJob(bytes32 jobId, bytes calldata input, bool phase1Settled) external {
        jobs[jobId] = JobState({
            exists: true,
            longRunning: true,
            phase1Settled: phase1Settled,
            inputHash: keccak256(input),
            inputSize: input.length,
            executorPaymentAddress: address(0xE0E),
            commitmentValidator: address(0xC0FFEE)
        });
        delivered[jobId] = false;
        deliverySuccess[jobId] = false;
    }

    function setSettlementContext(bytes32 jobId, address executorPaymentAddress, address commitmentValidator) external {
        jobs[jobId].executorPaymentAddress = executorPaymentAddress;
        jobs[jobId].commitmentValidator = commitmentValidator;
    }

    function getSettlementContext(bytes32 jobId)
        external
        view
        returns (address executorPaymentAddress, address commitmentValidator)
    {
        JobState storage job = jobs[jobId];
        require(job.exists, "not found");
        return (job.executorPaymentAddress, job.commitmentValidator);
    }

    function removeJob(bytes32 jobId, bytes calldata input, bool success) external returns (bool) {
        JobState storage job = jobs[jobId];
        require(job.exists, "not found");
        require(keccak256(input) == job.inputHash, "input hash mismatch");
        delivered[jobId] = true;
        deliverySuccess[jobId] = success;
        delete jobs[jobId];
        return true;
    }

    function getJobCount(address) external pure returns (uint256) {
        return 0;
    }

    function isLongRunning(bytes32 jobId) external view returns (bool) {
        return jobs[jobId].longRunning;
    }

    function isPhase1Settled(bytes32 jobId) external view returns (bool) {
        return jobs[jobId].phase1Settled;
    }

    function markPhase1Settled(bytes32 jobId, bytes calldata input) external returns (uint64) {
        JobState storage job = jobs[jobId];
        require(job.exists, "not found");
        require(keccak256(input) == job.inputHash, "input hash mismatch");
        require(!job.phase1Settled, "already settled");
        job.phase1Settled = true;
        return uint64(block.number + 10);
    }

    function computePhase2Deadline(bytes32 jobId, bytes calldata input) external view returns (uint64) {
        JobState storage job = jobs[jobId];
        require(job.exists, "not found");
        require(keccak256(input) == job.inputHash, "input hash mismatch");
        require(!job.phase1Settled, "already settled");
        return uint64(block.number + 10);
    }

    function markDelivered(bytes32 jobId, bytes calldata input, bool success) external {
        JobState storage job = jobs[jobId];
        require(job.exists, "not found");
        require(keccak256(input) == job.inputHash, "input hash mismatch");
        require(job.phase1Settled, "phase1 not settled");
        delivered[jobId] = true;
        deliverySuccess[jobId] = success;
        delete jobs[jobId];
    }

    function getInputHash(bytes32 jobId) external view returns (bytes32 hash, uint256 size) {
        JobState storage job = jobs[jobId];
        require(job.exists, "not found");
        return (job.inputHash, job.inputSize);
    }

    function getTxRlpHash(bytes32) external pure returns (bytes32 hash, uint256 size) {
        return (bytes32(0), 0);
    }
}

contract DeliveryTarget {
    bool public shouldRevert;
    uint256 public callCount;
    uint256 public lastValue;
    bytes32 public lastJobId;
    bytes public lastResult;

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function onResult(bytes32 jobId, bytes calldata result) external payable {
        if (shouldRevert) {
            revert("delivery failed");
        }
        callCount++;
        lastValue = msg.value;
        lastJobId = jobId;
        lastResult = result;
    }
}

contract RejectingAsyncProposer {
    receive() external payable {
        revert("reject payment");
    }
}

contract AsyncDeliveryTest is Test {
    address internal constant SYSTEM_ACCOUNT = 0x000000000000000000000000000000000000fA9E;
    address internal constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    MockRitualWallet internal wallet;
    MockAsyncJobTrackerForDelivery internal tracker;
    AsyncDelivery internal delivery;
    DeliveryTarget internal target;

    address internal sponsor = address(0xA11CE);
    address internal user = address(0xB0B);
    address payable internal executor = payable(address(0xE0E));

    function setUp() public {
        wallet = new MockRitualWallet(address(0x5150));
        tracker = new MockAsyncJobTrackerForDelivery();
        delivery = new AsyncDelivery(address(wallet), address(tracker));
        target = new DeliveryTarget();
        wallet.setAsyncDelivery(address(delivery));
        vm.deal(address(this), 100 ether);
    }

    function _reserve(bytes32 jobId, uint256 reserveAmount) internal {
        _reserveUntil(jobId, reserveAmount, uint64(block.number + 20));
    }

    function _reserveUntil(bytes32 jobId, uint256 reserveAmount, uint64 expiryBlock) internal {
        wallet.depositFor{value: reserveAmount}(sponsor);
        wallet.reserveFrom(sponsor, sponsor, jobId, reserveAmount, expiryBlock, new bytes32[](0));
        assertEq(wallet.availableBalance(sponsor), 0);
    }

    function testSettleRejectsNonSystemCaller() public {
        vm.expectRevert(AsyncDelivery.OnlySettlementSystem.selector);
        delivery.settle(keccak256("unauthorized-settle"), 1, 2, 3, hex"01");
    }

    function testDeliverRejectsNonSystemCaller() public {
        vm.expectRevert(AsyncDelivery.OnlySettlementSystem.selector);
        delivery.deliver(
            keccak256("unauthorized-deliver"), 1, 2, 3, 4, address(0x1234), bytes4(0x11223344), hex"01", hex"02"
        );
    }

    function testSettleRejectsMissingJobContext() public {
        bytes32 jobId = keccak256("phase-one-missing-job");
        _reserve(jobId, 1 ether);

        vm.expectRevert(bytes("not found"));
        vm.prank(SYSTEM_ACCOUNT);
        delivery.settle(jobId, 0.2 ether, 0.1 ether, 0.1 ether, hex"1234");
    }

    function testSettlePaysDerivedRecipientsFromEscrowSponsor() public {
        bytes32 jobId = keccak256("phase-one-canonical-sponsor");
        address payable commitmentValidator = payable(address(0xC0FFEE));
        address payable inclusionValidator = payable(address(0x1CE));
        uint256 executorFee = 0.2 ether;
        uint256 commitmentFee = 0.1 ether;
        uint256 inclusionFee = 0.1 ether;
        _reserve(jobId, executorFee + commitmentFee + inclusionFee);
        tracker.setJob(jobId, hex"1234", false);
        tracker.setSettlementContext(jobId, executor, commitmentValidator);
        vm.coinbase(inclusionValidator);

        vm.prank(SYSTEM_ACCOUNT);
        bool success = delivery.settle(jobId, executorFee, commitmentFee, inclusionFee, hex"1234");

        assertTrue(success);
        assertEq(wallet.availableBalance(executor), executorFee);
        assertEq(wallet.availableBalance(commitmentValidator), commitmentFee);
        assertEq(wallet.availableBalance(inclusionValidator), inclusionFee);
        assertEq(wallet.reservedBalance(sponsor), 0);
        assertEq(wallet.availableBalance(user), 0, "settlement must use escrow sponsor funds");
    }

    function testLongRunningSettleExtendsEscrowThroughPhase2Deadline() public {
        bytes32 jobId = keccak256("phase-two-escrow-extension");
        uint64 originalExpiry = uint64(block.number + 2);
        uint256 phase1ExecutorFee = 0.1 ether;
        uint256 phase2ExecutorFee = 0.2 ether;
        uint256 effectiveFeePerGas = 1 gwei;
        uint256 callbackGasLimit = 1_000_000;
        uint256 callbackValue = 0.1 ether;
        uint256 reserveAmount =
            phase1ExecutorFee + phase2ExecutorFee + callbackValue + (effectiveFeePerGas * callbackGasLimit);
        _reserveUntil(jobId, reserveAmount, originalExpiry);
        tracker.setJob(jobId, hex"1234", false);

        vm.prank(SYSTEM_ACCOUNT);
        bool settled = delivery.settle(jobId, phase1ExecutorFee, 0, 0, hex"1234");
        assertTrue(settled);
        uint64 phase2Deadline = uint64(block.number + 10);
        assertEq(wallet.escrows(jobId).expiryBlock, phase2Deadline);

        vm.roll(originalExpiry + 1);
        vm.expectRevert(IRitualWallet.EscrowNotExpired.selector);
        wallet.expire(jobId);
        assertEq(wallet.escrows(jobId).sponsor, sponsor);

        vm.prank(SYSTEM_ACCOUNT);
        bool delivered = delivery.deliver(
            jobId,
            phase2ExecutorFee,
            effectiveFeePerGas,
            callbackGasLimit,
            callbackValue,
            address(target),
            target.onResult.selector,
            hex"1234",
            hex"BEEF"
        );

        assertTrue(delivered);
        assertEq(wallet.availableBalance(executor), phase1ExecutorFee + phase2ExecutorFee);
        assertTrue(tracker.delivered(jobId));
        assertEq(wallet.escrows(jobId).sponsor, address(0));
    }

    function testDeliverPaysDerivedRecipientFromEscrowSponsor() public {
        bytes32 jobId = keccak256("phase-two-derived-recipient");
        address payable paymentRecipient = payable(address(0xFEE));
        uint256 executorFee = 0.2 ether;
        uint256 effectiveFeePerGas = 1 gwei;
        uint256 callbackGasLimit = 1_000_000;
        uint256 callbackValue = 0.1 ether;
        uint256 callbackGasBudget = effectiveFeePerGas * callbackGasLimit;
        _reserve(jobId, executorFee + callbackValue + callbackGasBudget);
        tracker.setJob(jobId, hex"1234", true);
        tracker.setSettlementContext(jobId, paymentRecipient, address(0xC0FFEE));

        vm.prank(SYSTEM_ACCOUNT);
        bool success = delivery.deliver(
            jobId,
            executorFee,
            effectiveFeePerGas,
            callbackGasLimit,
            callbackValue,
            address(target),
            target.onResult.selector,
            hex"1234",
            hex"BEEF"
        );

        assertTrue(success);
        assertEq(wallet.availableBalance(paymentRecipient), executorFee);
        assertEq(wallet.availableBalance(executor), 0);
        assertEq(wallet.availableBalance(user), 0, "delivery must use escrow sponsor for refunds");
    }

    function testDeliverRejectsAbsentJobBeforeCallback() public {
        bytes32 jobId = keccak256("phase-two-absent-job");
        uint256 executorFee = 0.2 ether;
        uint256 effectiveFeePerGas = 1 gwei;
        uint256 callbackGasLimit = 1_000_000;
        uint256 callbackValue = 0.1 ether;
        uint256 callbackGasBudget = effectiveFeePerGas * callbackGasLimit;
        _reserve(jobId, executorFee + callbackValue + callbackGasBudget);

        vm.expectRevert(bytes("not found"));
        vm.prank(SYSTEM_ACCOUNT);
        delivery.deliver(
            jobId,
            executorFee,
            effectiveFeePerGas,
            callbackGasLimit,
            callbackValue,
            address(target),
            target.onResult.selector,
            hex"1234",
            hex"BEEF"
        );

        assertEq(target.callCount(), 0);
    }

    function testDeliverRejectsNotPhaseOneSettledBeforeCallback() public {
        bytes32 jobId = keccak256("phase-two-not-settled");
        uint256 executorFee = 0.2 ether;
        uint256 effectiveFeePerGas = 1 gwei;
        uint256 callbackGasLimit = 1_000_000;
        uint256 callbackValue = 0.1 ether;
        uint256 callbackGasBudget = effectiveFeePerGas * callbackGasLimit;
        _reserve(jobId, executorFee + callbackValue + callbackGasBudget);
        tracker.setJob(jobId, hex"1234", false);

        vm.expectRevert(bytes("phase1 not settled"));
        vm.prank(SYSTEM_ACCOUNT);
        delivery.deliver(
            jobId,
            executorFee,
            effectiveFeePerGas,
            callbackGasLimit,
            callbackValue,
            address(target),
            target.onResult.selector,
            hex"1234",
            hex"BEEF"
        );

        assertEq(target.callCount(), 0);
    }

    function testDeliverRejectsInputMismatchBeforeCallback() public {
        bytes32 jobId = keccak256("phase-two-input-mismatch");
        uint256 executorFee = 0.2 ether;
        uint256 effectiveFeePerGas = 1 gwei;
        uint256 callbackGasLimit = 1_000_000;
        uint256 callbackValue = 0.1 ether;
        uint256 callbackGasBudget = effectiveFeePerGas * callbackGasLimit;
        _reserve(jobId, executorFee + callbackValue + callbackGasBudget);
        tracker.setJob(jobId, hex"1234", true);

        vm.expectRevert(bytes("input hash mismatch"));
        vm.prank(SYSTEM_ACCOUNT);
        delivery.deliver(
            jobId,
            executorFee,
            effectiveFeePerGas,
            callbackGasLimit,
            callbackValue,
            address(target),
            target.onResult.selector,
            hex"9999",
            hex"BEEF"
        );

        assertEq(target.callCount(), 0);
    }

    function testDeliverRefundsUnusedCallbackGasToEscrowSponsor() public {
        bytes32 jobId = keccak256("phase-two-success");
        uint256 executorFee = 0.2 ether;
        uint256 effectiveFeePerGas = 1 gwei;
        uint256 callbackGasLimit = 1_000_000;
        uint256 callbackValue = 0.1 ether;
        uint256 callbackGasBudget = effectiveFeePerGas * callbackGasLimit;
        _reserve(jobId, executorFee + callbackValue + callbackGasBudget);
        tracker.setJob(jobId, hex"1234", true);

        vm.prank(SYSTEM_ACCOUNT);
        bool success = delivery.deliver(
            jobId,
            executorFee,
            effectiveFeePerGas,
            callbackGasLimit,
            callbackValue,
            address(target),
            target.onResult.selector,
            hex"1234",
            hex"BEEF"
        );

        assertTrue(success);
        assertEq(wallet.availableBalance(executor), executorFee);
        assertEq(target.callCount(), 1);
        assertEq(target.lastValue(), callbackValue);
        assertEq(target.lastJobId(), jobId);
        assertGt(wallet.availableBalance(sponsor), 0, "unused callback gas should refund sponsor");
        assertEq(wallet.availableBalance(user), 0, "only escrow sponsor should receive delivery refunds");
        assertTrue(tracker.delivered(jobId));
        assertTrue(tracker.deliverySuccess(jobId));
    }

    function testDeliverSettlesExactEip1559MoneyFlow() public {
        bytes32 jobId = keccak256("phase-two-eip1559-distribution");
        uint256 executorFee = 0.2 ether;
        uint256 baseFeePerGas = 2 gwei;
        uint256 priorityFeePerGas = 3 gwei;
        uint256 effectiveFeePerGas = baseFeePerGas + priorityFeePerGas;
        uint256 callbackGasLimit = 1_000_000;
        uint256 callbackValue = 0.1 ether;
        uint256 callbackGasBudget = effectiveFeePerGas * callbackGasLimit;
        uint256 callbackUpfront = callbackGasBudget + callbackValue;
        uint256 reserveAmount = executorFee + callbackUpfront;
        address payable proposer = payable(address(0xBEEF));
        address burnAddress = BURN_ADDRESS;

        vm.fee(baseFeePerGas);
        vm.coinbase(proposer);
        vm.deal(proposer, 0);
        _reserve(jobId, reserveAmount);
        tracker.setJob(jobId, hex"1234", true);

        uint256 targetBefore = address(target).balance;
        // Pull model: the tip accrues to the proposer's wallet balance, not their raw ETH balance.
        uint256 proposerBefore = wallet.availableBalance(proposer);
        uint256 burnBefore = burnAddress.balance;
        uint256 walletNativeBefore = address(wallet).balance;

        vm.prank(SYSTEM_ACCOUNT);
        bool success = delivery.deliver(
            jobId,
            executorFee,
            effectiveFeePerGas,
            callbackGasLimit,
            callbackValue,
            address(target),
            target.onResult.selector,
            hex"1234",
            hex"BEEF"
        );

        uint256 baseFeeBurned = burnAddress.balance - burnBefore;
        uint256 proposerTip = wallet.availableBalance(proposer) - proposerBefore;
        assertEq(proposer.balance, 0);
        uint256 gasUsed = baseFeeBurned / baseFeePerGas;
        assertGt(gasUsed, 0);
        assertLe(gasUsed, callbackGasLimit);

        uint256 refund = (callbackGasLimit - gasUsed) * effectiveFeePerGas;
        uint256 sponsorRefund = wallet.availableBalance(sponsor);
        uint256 sponsorDebit = reserveAmount - wallet.availableBalance(sponsor);
        uint256 targetCredit = address(target).balance - targetBefore;
        uint256 walletNativeDebit = walletNativeBefore - address(wallet).balance;

        assertTrue(success);
        assertEq(sponsorRefund, refund);
        assertEq(baseFeeBurned, gasUsed * baseFeePerGas);
        assertEq(proposerTip, gasUsed * priorityFeePerGas);
        assertEq(targetCredit, callbackValue);
        assertEq(address(delivery).balance, 0);
        assertEq(wallet.availableBalance(executor), executorFee);
        assertEq(wallet.reservedBalance(sponsor), 0);
        // The tip ETH flows back into the wallet as the proposer's credited balance.
        assertEq(walletNativeDebit, callbackUpfront - refund - proposerTip);
        assertEq(sponsorDebit, executorFee + gasUsed * effectiveFeePerGas + callbackValue);
        assertEq(callbackUpfront, refund + targetCredit + proposerTip + baseFeeBurned);
        assertEq(sponsorDebit, executorFee + targetCredit + proposerTip + baseFeeBurned);
    }

    function testDeliverPaysNoTipWhenBaseFeeEqualsSettledEffectiveFee() public {
        bytes32 jobId = keccak256("phase-two-basefee-consumes-effective-fee");
        uint256 executorFee = 0.2 ether;
        uint256 effectiveFeePerGas = 5 gwei;
        uint256 callbackGasLimit = 1_000_000;
        uint256 callbackValue = 0.1 ether;
        uint256 callbackGasBudget = effectiveFeePerGas * callbackGasLimit;
        _reserve(jobId, executorFee + callbackGasBudget + callbackValue);
        tracker.setJob(jobId, hex"1234", true);

        vm.fee(effectiveFeePerGas);
        RejectingAsyncProposer proposer = new RejectingAsyncProposer();
        vm.coinbase(address(proposer));

        uint256 proposerBefore = wallet.availableBalance(address(proposer));
        uint256 burnBefore = BURN_ADDRESS.balance;

        vm.prank(SYSTEM_ACCOUNT);
        bool success = delivery.deliver(
            jobId,
            executorFee,
            effectiveFeePerGas,
            callbackGasLimit,
            callbackValue,
            address(target),
            target.onResult.selector,
            hex"1234",
            hex"BEEF"
        );

        uint256 baseFeeBurned = BURN_ADDRESS.balance - burnBefore;
        uint256 gasUsed = baseFeeBurned / effectiveFeePerGas;

        assertTrue(success);
        assertGt(gasUsed, 0);
        assertLe(gasUsed, callbackGasLimit);
        assertEq(address(proposer).balance, 0);
        assertEq(wallet.availableBalance(address(proposer)), proposerBefore);
        assertEq(baseFeeBurned, gasUsed * effectiveFeePerGas);
        assertEq(wallet.availableBalance(sponsor), (callbackGasLimit - gasUsed) * effectiveFeePerGas);
        assertEq(wallet.availableBalance(executor), executorFee);
        assertEq(target.lastValue(), callbackValue);
        assertTrue(tracker.delivered(jobId));
    }

    function testDeliverRevertsWhenBaseFeeSpikesAboveSettledEffectiveFee() public {
        bytes32 jobId = keccak256("phase-two-basefee-spike");
        uint256 executorFee = 0.2 ether;
        uint256 effectiveFeePerGas = 5 gwei;
        uint256 callbackGasLimit = 1_000_000;
        uint256 callbackGasBudget = effectiveFeePerGas * callbackGasLimit;
        _reserve(jobId, executorFee + callbackGasBudget);
        tracker.setJob(jobId, hex"1234", true);
        vm.deal(address(delivery), callbackGasBudget);

        vm.fee(effectiveFeePerGas + 1 gwei);

        vm.expectRevert(stdError.arithmeticError);
        vm.prank(SYSTEM_ACCOUNT);
        delivery.deliver(
            jobId,
            executorFee,
            effectiveFeePerGas,
            callbackGasLimit,
            0,
            address(target),
            target.onResult.selector,
            hex"1234",
            hex"BEEF"
        );

        assertEq(target.callCount(), 0);
        assertFalse(tracker.delivered(jobId));
        assertEq(wallet.availableBalance(executor), 0);
        assertEq(wallet.escrows(jobId).sponsor, sponsor);
        assertEq(wallet.reservedBalance(sponsor), executorFee + callbackGasBudget);
        assertEq(address(delivery).balance, callbackGasBudget);
    }

    function testDeliverWithZeroBaseFeeBurnsNothingAndStillTipsProposer() public {
        bytes32 jobId = keccak256("phase-two-zero-basefee");
        uint256 executorFee = 0.2 ether;
        uint256 priorityFeePerGas = 3 gwei;
        uint256 effectiveFeePerGas = priorityFeePerGas; // basefee 0
        uint256 callbackGasLimit = 1_000_000;
        uint256 callbackValue = 0.1 ether;
        uint256 callbackUpfront = effectiveFeePerGas * callbackGasLimit + callbackValue;
        uint256 reserveAmount = executorFee + callbackUpfront;
        address payable proposer = payable(address(0xBEEF));

        vm.fee(0);
        vm.coinbase(proposer);
        vm.deal(proposer, 0);
        _reserve(jobId, reserveAmount);
        tracker.setJob(jobId, hex"1234", true);

        uint256 burnBefore = BURN_ADDRESS.balance;
        uint256 targetBefore = address(target).balance;
        uint256 proposerBefore = wallet.availableBalance(proposer);

        vm.prank(SYSTEM_ACCOUNT);
        bool success = delivery.deliver(
            jobId,
            executorFee,
            effectiveFeePerGas,
            callbackGasLimit,
            callbackValue,
            address(target),
            target.onResult.selector,
            hex"1234",
            hex"BEEF"
        );

        uint256 proposerTip = wallet.availableBalance(proposer) - proposerBefore;
        assertTrue(success);
        // Zero base fee: nothing burned, and the zero-amount burn must not revert delivery.
        assertEq(BURN_ADDRESS.balance, burnBefore);
        assertGt(proposerTip, 0);
        assertEq(proposer.balance, 0);
        assertEq(address(target).balance - targetBefore, callbackValue);
        assertEq(address(delivery).balance, 0);
        assertEq(wallet.availableBalance(executor), executorFee);
        assertEq(callbackUpfront, wallet.availableBalance(sponsor) + callbackValue + proposerTip);
    }

    function testDeliverCreditsTipToContractProposerThatRejectsEth() public {
        // Pull model: a contract coinbase whose receive() reverts can no longer invalidate the
        // deliver() system transaction. The tip is credited to its wallet balance instead.
        bytes32 jobId = keccak256("phase-two-proposer-pull-credit");
        uint256 executorFee = 0.2 ether;
        uint256 baseFeePerGas = 2 gwei;
        uint256 effectiveFeePerGas = 3 gwei;
        uint256 callbackGasLimit = 1_000_000;
        uint256 callbackGasBudget = effectiveFeePerGas * callbackGasLimit;
        _reserve(jobId, executorFee + callbackGasBudget);
        tracker.setJob(jobId, hex"1234", true);
        vm.fee(baseFeePerGas);
        RejectingAsyncProposer proposer = new RejectingAsyncProposer();
        vm.coinbase(address(proposer));
        uint256 burnBefore = BURN_ADDRESS.balance;

        vm.prank(SYSTEM_ACCOUNT);
        bool success = delivery.deliver(
            jobId,
            executorFee,
            effectiveFeePerGas,
            callbackGasLimit,
            0,
            address(target),
            target.onResult.selector,
            hex"1234",
            hex"BEEF"
        );

        assertTrue(success);
        assertEq(target.callCount(), 1);
        assertTrue(tracker.delivered(jobId));
        assertEq(wallet.availableBalance(executor), executorFee);
        assertEq(address(proposer).balance, 0);
        uint256 gasUsed = (BURN_ADDRESS.balance - burnBefore) / baseFeePerGas;
        assertGt(gasUsed, 0);
        uint256 expectedTip = (effectiveFeePerGas - baseFeePerGas) * gasUsed;
        assertEq(wallet.availableBalance(address(proposer)), expectedTip);
    }

    function testDeliverRefundFailureRevertsAndRollsBackSuccessfulCallback() public {
        bytes32 jobId = keccak256("phase-two-refund-failure-success");
        uint256 executorFee = 0.2 ether;
        uint256 effectiveFeePerGas = 1 gwei;
        uint256 callbackGasLimit = 1_000_000;
        uint256 callbackValue = 0.1 ether;
        uint256 callbackGasBudget = effectiveFeePerGas * callbackGasLimit;
        _reserve(jobId, executorFee + callbackValue + callbackGasBudget);
        tracker.setJob(jobId, hex"1234", true);
        wallet.setFailRefund(true);

        vm.expectRevert(bytes("refund failed"));
        vm.prank(SYSTEM_ACCOUNT);
        delivery.deliver(
            jobId,
            executorFee,
            effectiveFeePerGas,
            callbackGasLimit,
            callbackValue,
            address(target),
            target.onResult.selector,
            hex"1234",
            hex"BEEF"
        );

        assertEq(target.callCount(), 0, "callback side effects must roll back");
        assertEq(wallet.availableBalance(executor), 0, "executor payment must roll back");
        assertFalse(tracker.delivered(jobId), "job must remain undelivered after reverted settlement");
    }

    function testDeliverRejectsDoubleDelivery() public {
        bytes32 jobId = keccak256("phase-two-double-delivery");
        uint256 executorFee = 0.2 ether;
        uint256 effectiveFeePerGas = 1 gwei;
        uint256 callbackGasLimit = 1_000_000;
        uint256 callbackValue = 0.1 ether;
        uint256 callbackGasBudget = effectiveFeePerGas * callbackGasLimit;
        _reserve(jobId, (executorFee + callbackValue + callbackGasBudget) * 2);
        tracker.setJob(jobId, hex"1234", true);

        vm.prank(SYSTEM_ACCOUNT);
        assertTrue(
            delivery.deliver(
                jobId,
                executorFee,
                effectiveFeePerGas,
                callbackGasLimit,
                callbackValue,
                address(target),
                target.onResult.selector,
                hex"1234",
                hex"BEEF"
            )
        );

        vm.expectRevert(bytes("not found"));
        vm.prank(SYSTEM_ACCOUNT);
        delivery.deliver(
            jobId,
            executorFee,
            effectiveFeePerGas,
            callbackGasLimit,
            callbackValue,
            address(target),
            target.onResult.selector,
            hex"1234",
            hex"BEEF"
        );
    }

    function testDeliverRefundsRevertedCallbackValueToEscrowSponsor() public {
        bytes32 jobId = keccak256("phase-two-revert");
        uint256 executorFee = 0.2 ether;
        uint256 effectiveFeePerGas = 1 gwei;
        uint256 callbackGasLimit = 1_000_000;
        uint256 callbackValue = 0.1 ether;
        uint256 callbackGasBudget = effectiveFeePerGas * callbackGasLimit;
        _reserve(jobId, executorFee + callbackValue + callbackGasBudget);
        tracker.setJob(jobId, hex"1234", true);

        target.setShouldRevert(true);

        vm.prank(SYSTEM_ACCOUNT);
        bool success = delivery.deliver(
            jobId,
            executorFee,
            effectiveFeePerGas,
            callbackGasLimit,
            callbackValue,
            address(target),
            target.onResult.selector,
            hex"1234",
            hex"BEEF"
        );

        assertFalse(success);
        assertEq(wallet.availableBalance(executor), executorFee);
        assertEq(target.callCount(), 0);
        assertGe(wallet.availableBalance(sponsor), callbackValue, "reverted callback value should refund sponsor");
        assertEq(wallet.availableBalance(user), 0, "only escrow sponsor should receive delivery refunds");
        assertTrue(tracker.delivered(jobId));
        assertFalse(tracker.deliverySuccess(jobId));
    }

    function testDeliverRefundFailureRevertsAndRollsBackRevertedCallback() public {
        bytes32 jobId = keccak256("phase-two-refund-failure-revert");
        uint256 executorFee = 0.2 ether;
        uint256 effectiveFeePerGas = 1 gwei;
        uint256 callbackGasLimit = 1_000_000;
        uint256 callbackValue = 0.1 ether;
        uint256 callbackGasBudget = effectiveFeePerGas * callbackGasLimit;
        _reserve(jobId, executorFee + callbackValue + callbackGasBudget);
        tracker.setJob(jobId, hex"1234", true);
        target.setShouldRevert(true);
        wallet.setFailRefund(true);

        vm.expectRevert(bytes("refund failed"));
        vm.prank(SYSTEM_ACCOUNT);
        delivery.deliver(
            jobId,
            executorFee,
            effectiveFeePerGas,
            callbackGasLimit,
            callbackValue,
            address(target),
            target.onResult.selector,
            hex"1234",
            hex"BEEF"
        );

        assertEq(wallet.availableBalance(executor), 0, "executor payment must roll back");
        assertFalse(tracker.delivered(jobId), "job must remain undelivered after reverted settlement");
    }
}
