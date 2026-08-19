// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IRitualWallet} from "../src/wallet/IRitualWallet.sol";
import {RitualWallet} from "../src/wallet/RitualWallet.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract RejectingWalletReceiver {
    RitualWallet internal immutable wallet;

    constructor(RitualWallet _wallet) {
        wallet = _wallet;
    }

    function withdraw(uint256 amount) external {
        wallet.withdraw(amount);
    }

    receive() external payable {
        revert("reject ETH");
    }
}

contract RejectingScheduler {
    function deduct(RitualWallet wallet, address sponsor, address caller, uint256 fixedFee, uint256 callId)
        external
        returns (uint256)
    {
        return wallet.deductScheduledExecutionFeesFrom(sponsor, caller, 0, 0, 0, fixedFee, callId);
    }

    receive() external payable {
        revert("reject ETH");
    }
}

contract RitualWalletTest is Test {
    event FeeDeduction(address indexed sponsor, uint256 amount, uint256 callId);
    event GasRefund(address indexed sponsor, uint256 amount, uint256 callId);

    RitualWallet public wallet;

    address public scheduler = address(0x1000);
    address public asyncDelivery = address(0x2000);
    address public asyncTracker = address(0x3000);
    address public sponsor = address(0xA11CE);
    address public caller = address(0xB0B);
    address payable public executor = payable(address(0xE0E));
    address payable public validator = payable(address(0xF0F));

    function setUp() public {
        RitualWallet implementation = new RitualWallet(scheduler, asyncDelivery, asyncTracker);
        bytes memory initData = abi.encodeWithSelector(RitualWallet.initialize.selector, address(this));
        wallet = RitualWallet(payable(address(new ERC1967Proxy(address(implementation), initData))));

        vm.deal(address(this), 100 ether);
    }

    function _deployWallet(address localScheduler) internal returns (RitualWallet deployedWallet) {
        RitualWallet implementation = new RitualWallet(localScheduler, asyncDelivery, asyncTracker);
        bytes memory initData = abi.encodeWithSelector(RitualWallet.initialize.selector, address(this));
        deployedWallet = RitualWallet(payable(address(new ERC1967Proxy(address(implementation), initData))));
    }

    function _reserveForSponsor(bytes32 escrowId, uint256 amount, uint64 expiryBlock) internal {
        vm.prank(asyncTracker);
        wallet.reserveFrom(sponsor, sponsor, escrowId, amount, expiryBlock, new bytes32[](0));
    }

    function _singlePayment(address payable recipient, uint256 amount)
        internal
        pure
        returns (IRitualWallet.Payment[] memory payments)
    {
        payments = new IRitualWallet.Payment[](1);
        payments[0] = IRitualWallet.Payment({to: recipient, amount: amount});
    }

    function _assertEscrow(
        bytes32 escrowId,
        address expectedSponsor,
        uint256 expectedReserved,
        uint256 expectedPaid,
        uint64 expectedExpiry
    ) internal view {
        IRitualWallet.Escrow memory escrow = wallet.escrows(escrowId);
        assertEq(escrow.sponsor, expectedSponsor);
        assertEq(escrow.reserved, expectedReserved);
        assertEq(escrow.paid, expectedPaid);
        assertEq(escrow.expiryBlock, expectedExpiry);
    }

    function _assertScheduledSoftFailure(uint256 available, uint256 delegatedAllowance, uint256 fee, uint256 callId)
        internal
    {
        wallet.depositFor{value: available}(sponsor);
        vm.prank(sponsor);
        wallet.approve(caller, delegatedAllowance);

        uint256 walletEthBefore = address(wallet).balance;
        uint256 schedulerEthBefore = scheduler.balance;
        vm.recordLogs();

        vm.prank(scheduler);
        uint256 actualFee = wallet.deductScheduledExecutionFeesFrom(sponsor, caller, 0, 0, 0, fee, callId);

        assertEq(actualFee, 0);
        assertEq(wallet.availableBalance(sponsor), available);
        assertEq(wallet.reservedBalance(sponsor), 0);
        assertEq(wallet.allowance(sponsor, caller), delegatedAllowance);
        assertEq(address(wallet).balance, walletEthBefore);
        assertEq(scheduler.balance, schedulerEthBefore);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testDepositCreditsMsgSender() public {
        vm.deal(sponsor, 2 ether);

        vm.prank(sponsor);
        wallet.deposit{value: 1.25 ether}();

        assertEq(wallet.availableBalance(sponsor), 1.25 ether);
        assertEq(wallet.reservedBalance(sponsor), 0);
        assertEq(address(wallet).balance, 1.25 ether);
    }

    function testZeroValueDepositAndDepositForRevertInsufficientBalance() public {
        vm.expectRevert(IRitualWallet.InsufficientBalance.selector);
        wallet.deposit();

        vm.expectRevert(IRitualWallet.InsufficientBalance.selector);
        wallet.depositFor(sponsor);

        assertEq(wallet.availableBalance(address(this)), 0);
        assertEq(wallet.availableBalance(sponsor), 0);
        assertEq(address(wallet).balance, 0);
    }

    function testDirectReceiveCreditsSender() public {
        vm.deal(caller, 1 ether);

        vm.prank(caller);
        (bool success,) = address(wallet).call{value: 0.75 ether}("");

        assertTrue(success);
        assertEq(wallet.availableBalance(caller), 0.75 ether);
        assertEq(wallet.reservedBalance(caller), 0);
        assertEq(address(wallet).balance, 0.75 ether);
    }

    function testAllowanceApproveIncreaseDecreaseHappyPath() public {
        vm.startPrank(sponsor);
        wallet.approve(caller, 1 ether);
        assertEq(wallet.allowance(sponsor, caller), 1 ether);

        wallet.increaseAllowance(caller, 0.5 ether);
        assertEq(wallet.allowance(sponsor, caller), 1.5 ether);

        wallet.decreaseAllowance(caller, 0.25 ether);
        vm.stopPrank();

        assertEq(wallet.allowance(sponsor, caller), 1.25 ether);
    }

    function testDecreaseAllowanceInsufficientRevertsWithoutMutation() public {
        vm.startPrank(sponsor);
        wallet.approve(caller, 0.5 ether);

        vm.expectRevert(IRitualWallet.InsufficientAllowance.selector);
        wallet.decreaseAllowance(caller, 0.75 ether);
        vm.stopPrank();

        assertEq(wallet.allowance(sponsor, caller), 0.5 ether);
    }

    function testDepositCreditsAvailableWithoutLock() public {
        wallet.depositFor{value: 2 ether}(sponsor);

        assertEq(wallet.availableBalance(sponsor), 2 ether);
        assertEq(wallet.reservedBalance(sponsor), 0);
    }

    function testReserveMovesAvailableToReserved() public {
        wallet.depositFor{value: 2 ether}(sponsor);

        vm.prank(asyncTracker);
        wallet.reserveFrom(sponsor, sponsor, bytes32("job-1"), 1 ether, uint64(block.number + 10), new bytes32[](0));

        assertEq(wallet.availableBalance(sponsor), 1 ether);
        assertEq(wallet.reservedBalance(sponsor), 1 ether);

        IRitualWallet.Escrow memory escrow = wallet.escrows(bytes32("job-1"));
        assertEq(escrow.sponsor, sponsor);
        assertEq(escrow.reserved, 1 ether);
        assertEq(escrow.paid, 0);
    }

    function testOnlyImmutableProtocolCallersCanReserve() public {
        wallet.depositFor{value: 2 ether}(sponsor);

        vm.prank(address(0xBAD));
        vm.expectRevert(IRitualWallet.UnauthorizedCaller.selector);
        wallet.reserveFrom(sponsor, sponsor, bytes32("job-1"), 1 ether, uint64(block.number + 10), new bytes32[](0));
    }

    function testActiveEscrowPreventsDoubleSpend() public {
        wallet.depositFor{value: 1 ether}(sponsor);

        vm.prank(asyncTracker);
        wallet.reserveFrom(sponsor, sponsor, bytes32("job-1"), 1 ether, uint64(block.number + 10), new bytes32[](0));

        vm.prank(asyncTracker);
        vm.expectRevert();
        wallet.reserveFrom(sponsor, sponsor, bytes32("job-2"), 1 ether, uint64(block.number + 10), new bytes32[](0));
    }

    function testAllowanceIsConsumedForDelegatedReserve() public {
        wallet.depositFor{value: 2 ether}(sponsor);

        vm.prank(sponsor);
        wallet.approve(caller, 1 ether);

        vm.prank(asyncTracker);
        wallet.reserveFrom(sponsor, caller, bytes32("job-1"), 0.75 ether, uint64(block.number + 10), new bytes32[](0));

        assertEq(wallet.allowance(sponsor, caller), 0.25 ether);
        assertEq(wallet.availableBalance(sponsor), 1.25 ether);
        assertEq(wallet.reservedBalance(sponsor), 0.75 ether);
    }

    function testInfiniteAllowanceIsNotConsumedForDelegatedReserve() public {
        wallet.depositFor{value: 2 ether}(sponsor);

        vm.prank(sponsor);
        wallet.approve(caller, type(uint256).max);

        vm.prank(asyncTracker);
        wallet.reserveFrom(sponsor, caller, bytes32("job-1"), 0.75 ether, uint64(block.number + 10), new bytes32[](0));

        assertEq(wallet.allowance(sponsor, caller), type(uint256).max);
        assertEq(wallet.availableBalance(sponsor), 1.25 ether);
        assertEq(wallet.reservedBalance(sponsor), 0.75 ether);
    }

    function testInfiniteAllowanceIsNotConsumedForScheduledDebit() public {
        wallet.depositFor{value: 2 ether}(sponsor);

        vm.prank(sponsor);
        wallet.approve(caller, type(uint256).max);

        uint256 fee = 1 gwei * 100_000;
        vm.prank(scheduler);
        uint256 actualFee = wallet.deductScheduledExecutionFeesFrom(sponsor, caller, 1 gwei, 100_000, 0, 0, 1);

        assertEq(actualFee, fee);
        assertEq(wallet.allowance(sponsor, caller), type(uint256).max);
        assertEq(wallet.availableBalance(sponsor), 2 ether - fee);
    }

    function testRefundGasRevertsOnValueMismatch() public {
        vm.deal(scheduler, 1 ether);

        vm.prank(scheduler);
        vm.expectRevert(abi.encodeWithSelector(IRitualWallet.RefundValueMismatch.selector, 1 ether, 0.5 ether));
        wallet.refundGas{value: 0.5 ether}(sponsor, 1 ether, 1);
    }

    function testExpiredEscrowCanBeSweptDuringWithdraw() public {
        wallet.depositFor{value: 2 ether}(sponsor);

        bytes32 escrowId = bytes32("job-1");
        vm.prank(asyncTracker);
        wallet.reserveFrom(sponsor, sponsor, escrowId, 1 ether, uint64(block.number + 2), new bytes32[](0));

        vm.roll(block.number + 3);
        bytes32[] memory expired = new bytes32[](1);
        expired[0] = escrowId;

        vm.prank(sponsor);
        wallet.withdraw(2 ether, expired);

        assertEq(wallet.availableBalance(sponsor), 0);
        assertEq(wallet.reservedBalance(sponsor), 0);
        assertEq(sponsor.balance, 2 ether);
        assertEq(wallet.escrows(escrowId).sponsor, address(0));
    }

    function testWithdrawRevertsWithoutManualBalanceRestore() public {
        RejectingWalletReceiver receiver = new RejectingWalletReceiver(wallet);
        wallet.depositFor{value: 1 ether}(address(receiver));

        vm.expectRevert(IRitualWallet.TransferFailed.selector);
        receiver.withdraw(1 ether);

        assertEq(wallet.availableBalance(address(receiver)), 1 ether);
    }

    function testSettleCreditsPaymentsAndRefundsFromReserve() public {
        wallet.depositFor{value: 2 ether}(sponsor);

        bytes32 escrowId = bytes32("job-1");
        vm.prank(asyncTracker);
        wallet.reserveFrom(sponsor, sponsor, escrowId, 2 ether, uint64(block.number + 10), new bytes32[](0));

        IRitualWallet.Payment[] memory payments = new IRitualWallet.Payment[](2);
        payments[0] = IRitualWallet.Payment({to: executor, amount: 0.5 ether});
        payments[1] = IRitualWallet.Payment({to: validator, amount: 0.25 ether});

        vm.prank(asyncTracker);
        wallet.settle(escrowId, payments, 0.25 ether, 0, true);

        assertEq(wallet.availableBalance(executor), 0.5 ether);
        assertEq(wallet.availableBalance(validator), 0.25 ether);
        assertEq(wallet.availableBalance(sponsor), 1.25 ether);
        assertEq(wallet.reservedBalance(sponsor), 0);
        assertEq(wallet.escrows(escrowId).sponsor, address(0));

        vm.prank(executor);
        wallet.withdraw(0.5 ether);

        assertEq(wallet.availableBalance(executor), 0);
        assertEq(executor.balance, 0.5 ether);
    }

    function testSettleCreditsRejectingRecipientWithoutReverting() public {
        RejectingWalletReceiver receiver = new RejectingWalletReceiver(wallet);
        wallet.depositFor{value: 1 ether}(sponsor);

        bytes32 escrowId = bytes32("job-rejecting");
        vm.prank(asyncTracker);
        wallet.reserveFrom(sponsor, sponsor, escrowId, 1 ether, uint64(block.number + 10), new bytes32[](0));

        IRitualWallet.Payment[] memory payments = new IRitualWallet.Payment[](1);
        payments[0] = IRitualWallet.Payment({to: payable(address(receiver)), amount: 0.5 ether});

        vm.prank(asyncTracker);
        wallet.settle(escrowId, payments, 0, 0, true);

        assertEq(address(receiver).balance, 0);
        assertEq(wallet.availableBalance(address(receiver)), 0.5 ether);
        assertEq(wallet.escrows(escrowId).sponsor, address(0));
    }

    function testSettleCanKeepExistingExpiryForOpenEscrow() public {
        wallet.depositFor{value: 2 ether}(sponsor);

        bytes32 escrowId = bytes32("job-open");
        uint64 originalExpiry = uint64(block.number + 100);
        vm.prank(asyncTracker);
        wallet.reserveFrom(sponsor, sponsor, escrowId, 2 ether, originalExpiry, new bytes32[](0));

        IRitualWallet.Payment[] memory payments = new IRitualWallet.Payment[](1);
        payments[0] = IRitualWallet.Payment({to: executor, amount: 0.5 ether});

        vm.prank(asyncTracker);
        wallet.settle(escrowId, payments, 0, 0, false);

        IRitualWallet.Escrow memory escrow = wallet.escrows(escrowId);
        assertEq(escrow.expiryBlock, originalExpiry);
        assertEq(escrow.reserved, 1.5 ether);
        assertEq(escrow.paid, 0.5 ether);
        assertEq(wallet.reservedBalance(sponsor), 1.5 ether);
        assertEq(escrow.sponsor, sponsor);
    }

    function testStrictExpireRevertsForAbsentLiveAndExpiryBlockThenDeletesAfterDeadline() public {
        bytes32 escrowId = bytes32("strict-expire");

        vm.expectRevert(IRitualWallet.EscrowNotExpired.selector);
        wallet.expire(escrowId);

        wallet.depositFor{value: 1 ether}(sponsor);
        uint64 deadline = uint64(block.number + 2);
        vm.prank(asyncTracker);
        wallet.reserveFrom(sponsor, sponsor, escrowId, 1 ether, deadline, new bytes32[](0));

        vm.expectRevert(IRitualWallet.EscrowNotExpired.selector);
        wallet.expire(escrowId);

        vm.roll(deadline);
        vm.expectRevert(IRitualWallet.EscrowNotExpired.selector);
        wallet.expire(escrowId);

        vm.roll(uint256(deadline) + 1);
        wallet.expire(escrowId);

        assertEq(wallet.escrows(escrowId).sponsor, address(0));
        assertEq(wallet.availableBalance(sponsor), 1 ether);
        assertEq(wallet.reservedBalance(sponsor), 0);

        vm.expectRevert(IRitualWallet.EscrowNotExpired.selector);
        wallet.expire(escrowId);
    }

    function testExpireManyBestEffortIgnoresAbsentAndLiveIds() public {
        bytes32 expiredId = bytes32("expired");
        bytes32 liveId = bytes32("live");
        wallet.depositFor{value: 2 ether}(sponsor);

        vm.startPrank(asyncTracker);
        wallet.reserveFrom(sponsor, sponsor, expiredId, 1 ether, uint64(block.number + 1), new bytes32[](0));
        wallet.reserveFrom(sponsor, sponsor, liveId, 1 ether, uint64(block.number + 100), new bytes32[](0));
        vm.stopPrank();

        vm.roll(block.number + 2);
        bytes32[] memory ids = new bytes32[](3);
        ids[0] = bytes32("absent");
        ids[1] = liveId;
        ids[2] = expiredId;
        wallet.expireMany(ids);

        assertEq(wallet.escrows(expiredId).sponsor, address(0));
        assertEq(wallet.escrows(liveId).sponsor, sponsor);
        assertEq(wallet.availableBalance(sponsor), 1 ether);
        assertEq(wallet.reservedBalance(sponsor), 1 ether);
    }

    function testExpiredTargetIsLazilyReleasedForSameIdRecommit() public {
        bytes32 escrowId = bytes32("same-id");
        wallet.depositFor{value: 2 ether}(sponsor);

        vm.prank(asyncTracker);
        wallet.reserveFrom(sponsor, sponsor, escrowId, 1 ether, uint64(block.number + 1), new bytes32[](0));
        vm.roll(block.number + 2);

        vm.prank(asyncTracker);
        wallet.reserveFrom(sponsor, sponsor, escrowId, 1.5 ether, uint64(block.number + 10), new bytes32[](0));

        IRitualWallet.Escrow memory escrow = wallet.escrows(escrowId);
        assertEq(escrow.sponsor, sponsor);
        assertEq(escrow.reserved, 1.5 ether);
        assertEq(escrow.paid, 0);
        assertEq(wallet.availableBalance(sponsor), 0.5 ether);
        assertEq(wallet.reservedBalance(sponsor), 1.5 ether);
    }

    function testLegacyTerminalStatusBytesDoNotBlockExpiredSameIdRecommit() public {
        bytes32 settledId = bytes32("legacy-settled");
        bytes32 expiredId = bytes32("legacy-expired");
        wallet.depositFor{value: 2 ether}(sponsor);

        uint64 deadline = uint64(block.number + 1);
        vm.startPrank(asyncTracker);
        wallet.reserveFrom(sponsor, sponsor, settledId, 0.5 ether, deadline, new bytes32[](0));
        wallet.reserveFrom(sponsor, sponsor, expiredId, 0.5 ether, deadline, new bytes32[](0));
        vm.stopPrank();

        bytes32 settledBase = keccak256(abi.encode(settledId, uint256(3)));
        bytes32 expiredBase = keccak256(abi.encode(expiredId, uint256(3)));
        vm.store(address(wallet), bytes32(uint256(settledBase) + 3), bytes32(uint256(deadline) | (uint256(2) << 64)));
        vm.store(address(wallet), bytes32(uint256(expiredBase) + 3), bytes32(uint256(deadline) | (uint256(3) << 64)));

        vm.roll(uint256(deadline) + 1);
        vm.startPrank(asyncTracker);
        wallet.reserveFrom(sponsor, sponsor, settledId, 0.75 ether, uint64(block.number + 10), new bytes32[](0));
        wallet.reserveFrom(sponsor, sponsor, expiredId, 0.75 ether, uint64(block.number + 10), new bytes32[](0));
        vm.stopPrank();

        assertEq(wallet.escrows(settledId).reserved, 0.75 ether);
        assertEq(wallet.escrows(expiredId).reserved, 0.75 ether);
        assertEq(wallet.availableBalance(sponsor), 0.5 ether);
        assertEq(wallet.reservedBalance(sponsor), 1.5 ether);
    }

    function testLiveTargetRejectsRecommit() public {
        bytes32 escrowId = bytes32("live-target");
        wallet.depositFor{value: 2 ether}(sponsor);

        vm.prank(asyncTracker);
        wallet.reserveFrom(sponsor, sponsor, escrowId, 1 ether, uint64(block.number + 10), new bytes32[](0));

        vm.prank(asyncTracker);
        vm.expectRevert(IRitualWallet.EscrowAlreadyExists.selector);
        wallet.reserveFrom(sponsor, sponsor, escrowId, 1 ether, uint64(block.number + 20), new bytes32[](0));

        assertEq(wallet.reservedBalance(sponsor), 1 ether);
    }

    function testReserveIgnoresInvalidHintsAndReleasesValidHintsOnce() public {
        address otherSponsor = address(0xCAFE);
        bytes32 target = bytes32("hint-target");
        bytes32 valid = bytes32("hint-valid");
        bytes32 live = bytes32("hint-live");
        bytes32 foreign = bytes32("hint-foreign");
        wallet.depositFor{value: 6 ether}(sponsor);
        wallet.depositFor{value: 1 ether}(otherSponsor);

        uint64 shortDeadline = uint64(block.number + 2);
        vm.startPrank(asyncTracker);
        wallet.reserveFrom(sponsor, sponsor, target, 1 ether, shortDeadline, new bytes32[](0));
        wallet.reserveFrom(sponsor, sponsor, valid, 1 ether, shortDeadline, new bytes32[](0));
        wallet.reserveFrom(sponsor, sponsor, live, 1 ether, uint64(block.number + 100), new bytes32[](0));
        wallet.reserveFrom(otherSponsor, otherSponsor, foreign, 1 ether, shortDeadline, new bytes32[](0));
        vm.stopPrank();
        vm.roll(uint256(shortDeadline) + 1);

        bytes32[] memory hints = new bytes32[](8);
        hints[0] = bytes32("absent");
        hints[1] = foreign;
        hints[2] = live;
        hints[3] = valid;
        hints[4] = valid;
        hints[5] = target;
        hints[6] = target;
        hints[7] = bytes32("also-absent");

        vm.prank(asyncTracker);
        wallet.reserveFrom(sponsor, sponsor, target, 4.5 ether, uint64(block.number + 10), hints);

        assertEq(wallet.MAX_EXPIRED_SWEEP(), 8);
        assertEq(wallet.escrows(valid).sponsor, address(0));
        assertEq(wallet.escrows(live).sponsor, sponsor);
        assertEq(wallet.escrows(foreign).sponsor, otherSponsor);
        assertEq(wallet.escrows(target).reserved, 4.5 ether);
        assertEq(wallet.availableBalance(sponsor), 0.5 ether);
        assertEq(wallet.reservedBalance(sponsor), 5.5 ether);
        assertEq(wallet.availableBalance(otherSponsor), 0);
        assertEq(wallet.reservedBalance(otherSponsor), 1 ether);
    }

    function testOverCapHintsRevert() public {
        bytes32 target = bytes32("over-cap-target");
        wallet.depositFor{value: 1 ether}(sponsor);
        vm.prank(asyncTracker);
        wallet.reserveFrom(sponsor, sponsor, target, 1 ether, uint64(block.number + 1), new bytes32[](0));
        vm.roll(block.number + 2);

        bytes32[] memory hints = new bytes32[](9);
        vm.prank(asyncTracker);
        vm.expectRevert(IRitualWallet.TooManyExpiredEscrows.selector);
        wallet.reserveFrom(sponsor, sponsor, target, 1 ether, uint64(block.number + 10), hints);

        assertEq(wallet.escrows(target).sponsor, sponsor, "revert must roll back target release");
        assertEq(wallet.availableBalance(sponsor), 0);
        assertEq(wallet.reservedBalance(sponsor), 1 ether);
    }

    function testReserveKeepsFiniteAllowanceOnInsufficientBalance() public {
        wallet.depositFor{value: 0.5 ether}(sponsor);
        vm.prank(sponsor);
        wallet.approve(caller, 1 ether);

        vm.prank(asyncTracker);
        vm.expectRevert(IRitualWallet.InsufficientBalance.selector);
        wallet.reserveFrom(
            sponsor, caller, bytes32("allowance-rollback"), 1 ether, uint64(block.number + 10), new bytes32[](0)
        );

        assertEq(wallet.allowance(sponsor, caller), 1 ether);
        assertEq(wallet.availableBalance(sponsor), 0.5 ether);
        assertEq(wallet.reservedBalance(sponsor), 0);
    }

    function testReserveInvalidExpiryRevertsWithoutMutation() public {
        wallet.depositFor{value: 1 ether}(sponsor);
        bytes32 escrowId = bytes32("invalid-expiry");
        uint256 walletEthBefore = address(wallet).balance;

        vm.prank(asyncTracker);
        vm.expectRevert(IRitualWallet.InvalidEscrowExpiry.selector);
        wallet.reserveFrom(sponsor, sponsor, escrowId, 0.75 ether, uint64(block.number), new bytes32[](0));

        assertEq(wallet.availableBalance(sponsor), 1 ether);
        assertEq(wallet.reservedBalance(sponsor), 0);
        assertEq(address(wallet).balance, walletEthBefore);
        _assertEscrow(escrowId, address(0), 0, 0, 0);
    }

    function testReserveInsufficientDelegatedAllowanceRevertsWithoutMutation() public {
        wallet.depositFor{value: 2 ether}(sponsor);
        vm.prank(sponsor);
        wallet.approve(caller, 0.5 ether);
        bytes32 escrowId = bytes32("insufficient-allowance");
        uint256 walletEthBefore = address(wallet).balance;

        vm.prank(asyncTracker);
        vm.expectRevert(IRitualWallet.InsufficientAllowance.selector);
        wallet.reserveFrom(sponsor, caller, escrowId, 1 ether, uint64(block.number + 10), new bytes32[](0));

        assertEq(wallet.availableBalance(sponsor), 2 ether);
        assertEq(wallet.reservedBalance(sponsor), 0);
        assertEq(wallet.allowance(sponsor, caller), 0.5 ether);
        assertEq(address(wallet).balance, walletEthBefore);
        _assertEscrow(escrowId, address(0), 0, 0, 0);
    }

    function testScheduledDebitSucceedsWithFiniteAllowanceAndTransfersEth() public {
        uint256 effectiveFeePerGas = 2 gwei;
        uint256 gasLimit = 100_000;
        uint256 value = 0.1 ether;
        uint256 fixedFee = 0.01 ether;
        uint256 fee = (effectiveFeePerGas * gasLimit) + value + fixedFee;
        uint256 callId = 41;

        wallet.depositFor{value: 2 ether}(sponsor);
        vm.prank(sponsor);
        wallet.approve(caller, 1 ether);

        uint256 schedulerEthBefore = scheduler.balance;
        vm.expectEmit(true, false, false, true, address(wallet));
        emit FeeDeduction(sponsor, fee, callId);

        vm.prank(scheduler);
        uint256 actualFee = wallet.deductScheduledExecutionFeesFrom(
            sponsor, caller, effectiveFeePerGas, gasLimit, value, fixedFee, callId
        );

        assertEq(actualFee, fee);
        assertEq(wallet.availableBalance(sponsor), 2 ether - fee);
        assertEq(wallet.allowance(sponsor, caller), 1 ether - fee);
        assertEq(address(wallet).balance, 2 ether - fee);
        assertEq(scheduler.balance, schedulerEthBefore + fee);
    }

    function testScheduledDebitInsufficientBalanceReturnsZeroWithoutMutation() public {
        uint256 fee = 1 ether;
        _assertScheduledSoftFailure(fee - 1, fee, fee, 42);
    }

    function testScheduledDebitInsufficientAllowanceReturnsZeroWithoutMutation() public {
        uint256 fee = 1 ether;
        _assertScheduledSoftFailure(fee + 1, fee - 1, fee, 43);
    }

    function testScheduledDebitRejectsNonScheduler() public {
        vm.prank(caller);
        vm.expectRevert(IRitualWallet.UnauthorizedScheduler.selector);
        wallet.deductScheduledExecutionFeesFrom(sponsor, caller, 0, 0, 0, 1 ether, 44);
    }

    function testScheduledDebitRejectingSchedulerReceiveRevertsAndRollsBack() public {
        RejectingScheduler rejectingScheduler = new RejectingScheduler();
        RitualWallet localWallet = _deployWallet(address(rejectingScheduler));
        localWallet.depositFor{value: 2 ether}(sponsor);
        vm.prank(sponsor);
        localWallet.approve(caller, 1 ether);

        vm.expectRevert(IRitualWallet.TransferFailed.selector);
        rejectingScheduler.deduct(localWallet, sponsor, caller, 0.75 ether, 45);

        assertEq(localWallet.availableBalance(sponsor), 2 ether);
        assertEq(localWallet.reservedBalance(sponsor), 0);
        assertEq(localWallet.allowance(sponsor, caller), 1 ether);
        assertEq(address(localWallet).balance, 2 ether);
        assertEq(address(rejectingScheduler).balance, 0);
    }

    function testSettleUnauthorizedCallerRevertsWithoutMutation() public {
        bytes32 escrowId = bytes32("settle-unauthorized");
        uint64 expiry = uint64(block.number + 10);
        wallet.depositFor{value: 2 ether}(sponsor);
        _reserveForSponsor(escrowId, 2 ether, expiry);
        IRitualWallet.Payment[] memory payments = _singlePayment(executor, 0.5 ether);

        vm.prank(caller);
        vm.expectRevert(IRitualWallet.UnauthorizedCaller.selector);
        wallet.settle(escrowId, payments, 0.25 ether, 0, true);

        assertEq(wallet.availableBalance(sponsor), 0);
        assertEq(wallet.reservedBalance(sponsor), 2 ether);
        assertEq(wallet.availableBalance(executor), 0);
        assertEq(address(wallet).balance, 2 ether);
        _assertEscrow(escrowId, sponsor, 2 ether, 0, expiry);
    }

    function testSettleExpiredEscrowRevertsWithoutMutation() public {
        bytes32 escrowId = bytes32("settle-expired");
        uint64 expiry = uint64(block.number + 2);
        wallet.depositFor{value: 2 ether}(sponsor);
        _reserveForSponsor(escrowId, 2 ether, expiry);
        IRitualWallet.Payment[] memory payments = _singlePayment(executor, 0.5 ether);
        vm.roll(uint256(expiry) + 1);

        vm.prank(asyncDelivery);
        vm.expectRevert(IRitualWallet.InvalidEscrowExpiry.selector);
        wallet.settle(escrowId, payments, 0.25 ether, 0, true);

        assertEq(wallet.availableBalance(sponsor), 0);
        assertEq(wallet.reservedBalance(sponsor), 2 ether);
        assertEq(wallet.availableBalance(executor), 0);
        assertEq(address(wallet).balance, 2 ether);
        _assertEscrow(escrowId, sponsor, 2 ether, 0, expiry);
    }

    function testSettleDebitAboveReserveRevertsWithoutMutation() public {
        bytes32 escrowId = bytes32("settle-over-reserve");
        uint64 expiry = uint64(block.number + 10);
        wallet.depositFor{value: 1 ether}(sponsor);
        _reserveForSponsor(escrowId, 1 ether, expiry);
        IRitualWallet.Payment[] memory payments = _singlePayment(executor, 0.75 ether);

        vm.prank(asyncTracker);
        vm.expectRevert(IRitualWallet.SettlementExceedsReserve.selector);
        wallet.settle(escrowId, payments, 0.5 ether, 0, true);

        assertEq(wallet.availableBalance(sponsor), 0);
        assertEq(wallet.reservedBalance(sponsor), 1 ether);
        assertEq(wallet.availableBalance(executor), 0);
        assertEq(address(wallet).balance, 1 ether);
        _assertEscrow(escrowId, sponsor, 1 ether, 0, expiry);
    }

    function testSettleInvalidOpenExpiryRevertsAndRollsBackAccounting() public {
        bytes32 escrowId = bytes32("settle-invalid-expiry");
        uint64 expiry = uint64(block.number + 10);
        wallet.depositFor{value: 2 ether}(sponsor);
        _reserveForSponsor(escrowId, 2 ether, expiry);
        IRitualWallet.Payment[] memory payments = _singlePayment(executor, 0.5 ether);

        vm.prank(asyncDelivery);
        vm.expectRevert(IRitualWallet.InvalidEscrowExpiry.selector);
        wallet.settle(escrowId, payments, 0.25 ether, uint64(block.number), false);

        assertEq(wallet.availableBalance(sponsor), 0);
        assertEq(wallet.reservedBalance(sponsor), 2 ether);
        assertEq(wallet.availableBalance(executor), 0);
        assertEq(address(wallet).balance, 2 ether);
        _assertEscrow(escrowId, sponsor, 2 ether, 0, expiry);
    }

    function testRefundGasExactValueSucceedsFromSchedulerAndAsyncDelivery() public {
        uint256 schedulerRefund = 0.25 ether;
        uint256 deliveryRefund = 0.5 ether;
        vm.deal(scheduler, schedulerRefund);
        vm.deal(asyncDelivery, deliveryRefund);

        vm.expectEmit(true, false, false, true, address(wallet));
        emit GasRefund(sponsor, schedulerRefund, 51);
        vm.prank(scheduler);
        wallet.refundGas{value: schedulerRefund}(sponsor, schedulerRefund, 51);

        vm.expectEmit(true, false, false, true, address(wallet));
        emit GasRefund(sponsor, deliveryRefund, 52);
        vm.prank(asyncDelivery);
        wallet.refundGas{value: deliveryRefund}(sponsor, deliveryRefund, 52);

        assertEq(wallet.availableBalance(sponsor), schedulerRefund + deliveryRefund);
        assertEq(address(wallet).balance, schedulerRefund + deliveryRefund);
    }

    function testRefundGasUnauthorizedCallerRevertsWithoutMutation() public {
        uint256 refund = 0.5 ether;
        vm.deal(caller, refund);

        vm.prank(caller);
        vm.expectRevert(IRitualWallet.UnauthorizedCaller.selector);
        wallet.refundGas{value: refund}(sponsor, refund, 53);

        assertEq(wallet.availableBalance(sponsor), 0);
        assertEq(address(wallet).balance, 0);
    }

    function testWithdrawInsufficientBalanceRevertsWithoutMutation() public {
        wallet.depositFor{value: 1 ether}(sponsor);

        vm.prank(sponsor);
        vm.expectRevert(IRitualWallet.InsufficientBalance.selector);
        wallet.withdraw(1 ether + 1);

        assertEq(wallet.availableBalance(sponsor), 1 ether);
        assertEq(wallet.reservedBalance(sponsor), 0);
        assertEq(address(wallet).balance, 1 ether);
    }

    function testFuzzScheduledSoftFailuresNeverMutateState(uint96 feeSeed, uint96 deltaSeed, bool insufficientBalance)
        public
    {
        uint256 fee = bound(uint256(feeSeed), 2, 10 ether);
        uint256 delta = bound(uint256(deltaSeed), 1, fee - 1);

        if (insufficientBalance) {
            _assertScheduledSoftFailure(fee - delta, fee, fee, 61);
        } else {
            _assertScheduledSoftFailure(fee + delta, fee - delta, fee, 62);
        }
    }

    function testFuzzReservePartialSettleExpireConservesAccounting(
        uint96 depositSeed,
        uint96 reserveSeed,
        uint96 executorPaymentSeed,
        uint96 validatorPaymentSeed,
        uint96 refundSeed
    ) public {
        uint256 depositAmount = bound(uint256(depositSeed), 3, 50 ether);
        uint256 reserveAmount = bound(uint256(reserveSeed), 3, depositAmount);
        uint256 executorPayment = bound(uint256(executorPaymentSeed), 1, reserveAmount - 2);
        uint256 validatorPayment = bound(uint256(validatorPaymentSeed), 1, reserveAmount - executorPayment - 1);
        uint256 refund = bound(uint256(refundSeed), 0, reserveAmount - executorPayment - validatorPayment - 1);
        uint256 remainingReserve = reserveAmount - executorPayment - validatorPayment - refund;

        bytes32 escrowId = bytes32("fuzz-conservation");
        uint64 expiry = uint64(block.number + 10);
        wallet.depositFor{value: depositAmount}(sponsor);
        _reserveForSponsor(escrowId, reserveAmount, expiry);

        IRitualWallet.Payment[] memory payments = new IRitualWallet.Payment[](2);
        payments[0] = IRitualWallet.Payment({to: executor, amount: executorPayment});
        payments[1] = IRitualWallet.Payment({to: validator, amount: validatorPayment});
        vm.prank(asyncDelivery);
        wallet.settle(escrowId, payments, refund, 0, false);

        uint256 trackedAvailable =
            wallet.availableBalance(sponsor) + wallet.availableBalance(executor) + wallet.availableBalance(validator);
        assertEq(address(wallet).balance, trackedAvailable + wallet.reservedBalance(sponsor));
        assertEq(wallet.reservedBalance(sponsor), remainingReserve);
        _assertEscrow(escrowId, sponsor, remainingReserve, executorPayment + validatorPayment, expiry);

        vm.roll(uint256(expiry) + 1);
        wallet.expire(escrowId);

        trackedAvailable =
            wallet.availableBalance(sponsor) + wallet.availableBalance(executor) + wallet.availableBalance(validator);
        assertEq(address(wallet).balance, trackedAvailable + wallet.reservedBalance(sponsor));
        assertEq(address(wallet).balance, depositAmount);
        assertEq(wallet.reservedBalance(sponsor), 0);
        _assertEscrow(escrowId, address(0), 0, 0, 0);
    }

    function testTwoPhaseSettlementPreservesPaidExtendsThenDeletes() public {
        bytes32 escrowId = bytes32("two-phase");
        wallet.depositFor{value: 3 ether}(sponsor);
        vm.prank(asyncTracker);
        wallet.reserveFrom(sponsor, sponsor, escrowId, 3 ether, uint64(block.number + 10), new bytes32[](0));

        IRitualWallet.Payment[] memory phase1 = new IRitualWallet.Payment[](1);
        phase1[0] = IRitualWallet.Payment({to: executor, amount: 0.5 ether});
        uint64 phase2Deadline = uint64(block.number + 100);
        vm.prank(asyncDelivery);
        wallet.settle(escrowId, phase1, 0.25 ether, phase2Deadline, false);

        IRitualWallet.Escrow memory escrow = wallet.escrows(escrowId);
        assertEq(escrow.paid, 0.5 ether);
        assertEq(escrow.reserved, 2.25 ether);
        assertEq(escrow.expiryBlock, phase2Deadline);
        assertEq(wallet.availableBalance(sponsor), 0.25 ether);
        assertEq(wallet.reservedBalance(sponsor), 2.25 ether);

        IRitualWallet.Payment[] memory phase2 = new IRitualWallet.Payment[](1);
        phase2[0] = IRitualWallet.Payment({to: validator, amount: 0.75 ether});
        vm.prank(asyncDelivery);
        wallet.settle(escrowId, phase2, 0.25 ether, 0, true);

        assertEq(wallet.escrows(escrowId).sponsor, address(0));
        assertEq(wallet.availableBalance(sponsor), 1.75 ether);
        assertEq(wallet.availableBalance(executor), 0.5 ether);
        assertEq(wallet.availableBalance(validator), 0.75 ether);
        assertEq(wallet.reservedBalance(sponsor), 0);

        vm.prank(asyncDelivery);
        vm.expectRevert(IRitualWallet.EscrowNotActive.selector);
        wallet.settle(escrowId, phase2, 0, 0, true);
    }
}
