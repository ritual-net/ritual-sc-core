// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {AsyncDelivery} from "../src/async/AsyncDelivery.sol";
import {AsyncJobTracker} from "../src/async/AsyncJobTracker.sol";
import {ITEECapabilityPolicy} from "../src/async/ITEECapabilityPolicy.sol";
import {ITEEServiceRegistry} from "../src/async/ITEEServiceRegistry.sol";
import {Scheduler, CallState} from "../src/scheduler/Scheduler.sol";
import {IRitualWallet} from "../src/wallet/IRitualWallet.sol";
import {RitualWallet} from "../src/wallet/RitualWallet.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ProtocolWalletTeeRegistry {
    address internal immutable teeExecutor;
    address internal immutable paymentRecipient;

    constructor(address _teeExecutor, address _paymentRecipient) {
        teeExecutor = _teeExecutor;
        paymentRecipient = _paymentRecipient;
    }

    function getValidService(address executor)
        external
        view
        returns (ITEEServiceRegistry.TEEServiceContext memory context)
    {
        if (executor != teeExecutor) {
            revert ITEEServiceRegistry.ServiceNotFound(executor);
        }

        context.node = ITEEServiceRegistry.TEEServiceNode({
            paymentAddress: paymentRecipient,
            teeAddress: teeExecutor,
            teeType: ITEEServiceRegistry.TeeType.DEBUG,
            executorSecretsAuthPublicKey: "",
            endpoint: "http://executor.test",
            mTlsSpkiHash: bytes32(uint256(1)),
            capability: ITEECapabilityPolicy.Capability.HTTP_CALL
        });
        context.isValid = true;
        context.workloadId = keccak256("protocol-wallet-http-executor");
    }
}

contract ProtocolWalletSchedulerTarget {
    uint256 public callbackCount;
    uint256 public lastExecutionIndex;

    function schedule(Scheduler scheduler, uint32 numCalls, uint32 frequency, uint32 ttl, uint256 maxFeePerGas)
        external
        returns (uint256)
    {
        return scheduler.schedule("", 100_000, numCalls, frequency, ttl, maxFeePerGas, 0, 0);
    }

    function withdrawAvailable(RitualWallet wallet) external {
        wallet.withdraw(wallet.availableBalance(address(this)));
    }

    function onScheduledExecution(uint256 executionIndex, bytes calldata) external payable {
        callbackCount++;
        lastExecutionIndex = executionIndex;
    }

    receive() external payable {}
}

contract ProtocolWalletIntegrationTest is Test {
    address internal constant COMMITMENT_SYSTEM = 0x000000000000000000000000000000000000Fa8e;
    address internal constant SETTLEMENT_SYSTEM = 0x000000000000000000000000000000000000fA9E;
    address internal constant SCHEDULER_SYSTEM = 0x000000000000000000000000000000000000fa7e;
    address internal constant TX_HASH_PRECOMPILE = 0x0000000000000000000000000000000000000830;
    address internal constant HTTP_CALL_PRECOMPILE = 0x0000000000000000000000000000000000000801;

    address internal constant TEE_EXECUTOR = address(0xE11);
    address internal constant EXECUTOR_PAYMENT = address(0xE0E);
    address internal constant COMMITMENT_VALIDATOR = address(0xC011);
    address internal constant INCLUSION_RECIPIENT = address(0x1CE);
    address internal constant PROPOSER = address(0xB10C);

    RitualWallet internal wallet;
    Scheduler internal scheduler;
    AsyncJobTracker internal tracker;
    AsyncDelivery internal delivery;
    ProtocolWalletTeeRegistry internal teeRegistry;
    ProtocolWalletSchedulerTarget internal target;

    function setUp() public {
        vm.deal(address(this), 100 ether);
        teeRegistry = new ProtocolWalletTeeRegistry(TEE_EXECUTOR, EXECUTOR_PAYMENT);
        target = new ProtocolWalletSchedulerTarget();

        uint256 nextNonce = vm.getNonce(address(this));
        address predictedWalletImplementation = vm.computeCreateAddress(address(this), nextNonce);
        address predictedWalletProxy = vm.computeCreateAddress(address(this), nextNonce + 1);
        address predictedSchedulerImplementation = vm.computeCreateAddress(address(this), nextNonce + 2);
        address predictedSchedulerProxy = vm.computeCreateAddress(address(this), nextNonce + 3);
        address predictedTrackerImplementation = vm.computeCreateAddress(address(this), nextNonce + 4);
        address predictedTrackerProxy = vm.computeCreateAddress(address(this), nextNonce + 5);
        address predictedDeliveryImplementation = vm.computeCreateAddress(address(this), nextNonce + 6);
        address predictedDeliveryProxy = vm.computeCreateAddress(address(this), nextNonce + 7);

        RitualWallet walletImplementation =
            new RitualWallet(predictedSchedulerProxy, predictedDeliveryProxy, predictedTrackerProxy);
        assertEq(address(walletImplementation), predictedWalletImplementation, "wallet implementation CREATE drift");
        ERC1967Proxy walletProxy =
            new ERC1967Proxy(address(walletImplementation), abi.encodeCall(RitualWallet.initialize, (address(this))));
        assertEq(address(walletProxy), predictedWalletProxy, "wallet proxy CREATE drift");
        wallet = RitualWallet(payable(address(walletProxy)));

        Scheduler schedulerImplementation = new Scheduler(predictedWalletProxy, 30);
        assertEq(
            address(schedulerImplementation), predictedSchedulerImplementation, "scheduler implementation CREATE drift"
        );
        ERC1967Proxy schedulerProxy =
            new ERC1967Proxy(address(schedulerImplementation), abi.encodeCall(Scheduler.initialize, (address(this))));
        assertEq(address(schedulerProxy), predictedSchedulerProxy, "scheduler proxy CREATE drift");
        scheduler = Scheduler(payable(address(schedulerProxy)));

        AsyncJobTracker trackerImplementation =
            new AsyncJobTracker(predictedDeliveryProxy, predictedWalletProxy, address(teeRegistry));
        assertEq(address(trackerImplementation), predictedTrackerImplementation, "tracker implementation CREATE drift");
        ERC1967Proxy trackerProxy = new ERC1967Proxy(
            address(trackerImplementation), abi.encodeCall(AsyncJobTracker.initialize, (address(this)))
        );
        assertEq(address(trackerProxy), predictedTrackerProxy, "tracker proxy CREATE drift");
        tracker = AsyncJobTracker(address(trackerProxy));

        AsyncDelivery deliveryImplementation = new AsyncDelivery(predictedWalletProxy, predictedTrackerProxy);
        assertEq(
            address(deliveryImplementation), predictedDeliveryImplementation, "delivery implementation CREATE drift"
        );
        ERC1967Proxy deliveryProxy = new ERC1967Proxy(
            address(deliveryImplementation), abi.encodeCall(AsyncDelivery.initialize, (address(this)))
        );
        assertEq(address(deliveryProxy), predictedDeliveryProxy, "delivery proxy CREATE drift");
        delivery = AsyncDelivery(payable(address(deliveryProxy)));

        scheduler.setAsyncJobTracker(address(tracker));
        tracker.setScheduler(address(scheduler));

        assertEq(wallet.scheduler(), address(scheduler));
        assertEq(wallet.asyncDelivery(), address(delivery));
        assertEq(wallet.asyncJobTracker(), address(tracker));
        assertEq(address(scheduler.RITUAL_WALLET()), address(wallet));
        assertEq(address(tracker.ritualWallet()), address(wallet));
        assertEq(tracker.ASYNC_DELIVERY(), address(delivery));
        assertEq(address(tracker.TEE_SERVICE_REGISTRY()), address(teeRegistry));
        assertEq(address(delivery.RITUAL_WALLET()), address(wallet));
        assertEq(address(delivery.ASYNC_JOB_TRACKER()), address(tracker));
    }

    function _job(bytes32 jobId, address caller, uint256 ttl)
        internal
        view
        returns (AsyncJobTracker.AddJobInput memory)
    {
        return AsyncJobTracker.AddJobInput({
            exec: TEE_EXECUTOR,
            id: jobId,
            precomp: HTTP_CALL_PRECOMPILE,
            input: "",
            ttl: ttl,
            prevHash: bytes32(0),
            prevNum: block.number - 1,
            prevTime: block.timestamp - 1,
            caller: caller,
            commitVal: COMMITMENT_VALIDATOR,
            origHash: jobId,
            origRlp: "",
            txOrigin: address(0)
        });
    }

    function _reserve(address sponsor, uint256 amount) internal pure returns (AsyncJobTracker.ReserveConfig memory) {
        return
            AsyncJobTracker.ReserveConfig({sponsor: sponsor, reserveAmount: amount, expiredEscrows: new bytes32[](0)});
    }

    function _addJob(bytes32 jobId, address sponsor, address caller, uint256 amount, uint256 ttl) internal {
        vm.prank(COMMITMENT_SYSTEM);
        tracker.addJobAndReserve(_job(jobId, caller, ttl), _reserve(sponsor, amount));
    }

    function _scheduleWithOrigin(bytes32 origin, uint32 numCalls, uint32 frequency, uint32 ttl)
        internal
        returns (uint256 callId)
    {
        bytes memory emptyInput = new bytes(0);
        vm.mockCall(TX_HASH_PRECOMPILE, emptyInput, abi.encode(origin));
        callId = target.schedule(scheduler, numCalls, frequency, ttl, scheduler.MIN_SCHEDULED_MAX_FEE_PER_GAS());
        vm.clearMockedCalls();
        assertEq(scheduler.originHash(callId), origin);
    }

    function _scheduledJobId(bytes32 origin, uint256 callId, uint256 executionIndex) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(origin, callId, executionIndex));
    }

    function _assertNoJob(bytes32 jobId) internal view {
        assertEq(tracker.jobExecutor(jobId), address(0));
        assertEq(wallet.escrows(jobId).sponsor, address(0));
    }

    function testRealWalletReserveAndSettleConservesEth() public {
        bytes32 jobId = keccak256("real-wallet-settlement");
        uint256 initialDeposit = 2 ether;
        uint256 reserveAmount = 1.2 ether;
        uint256 executorFee = 0.2 ether;
        uint256 commitmentFee = 0.15 ether;
        uint256 inclusionFee = 0.25 ether;

        wallet.depositFor{value: initialDeposit}(address(this));
        uint256 walletEthBefore = address(wallet).balance;

        _addJob(jobId, address(this), address(this), reserveAmount, 60);

        IRitualWallet.Escrow memory escrow = wallet.escrows(jobId);
        assertEq(escrow.sponsor, address(this));
        assertEq(escrow.reserved, reserveAmount);
        assertEq(escrow.paid, 0);
        assertEq(wallet.availableBalance(address(this)), initialDeposit - reserveAmount);
        assertEq(wallet.reservedBalance(address(this)), reserveAmount);
        assertEq(tracker.getJobCount(TEE_EXECUTOR), 1);

        vm.coinbase(INCLUSION_RECIPIENT);
        vm.prank(SETTLEMENT_SYSTEM);
        assertTrue(delivery.settle(jobId, executorFee, commitmentFee, inclusionFee, ""));

        uint256 totalPaid = executorFee + commitmentFee + inclusionFee;
        assertEq(wallet.availableBalance(address(this)), initialDeposit - totalPaid);
        assertEq(wallet.availableBalance(EXECUTOR_PAYMENT), executorFee);
        assertEq(wallet.availableBalance(COMMITMENT_VALIDATOR), commitmentFee);
        assertEq(wallet.availableBalance(INCLUSION_RECIPIENT), inclusionFee);
        assertEq(wallet.reservedBalance(address(this)), 0);
        assertEq(wallet.escrows(jobId).sponsor, address(0));
        assertEq(tracker.getJobCount(TEE_EXECUTOR), 0);
        assertEq(tracker.totalPending(), 0);
        assertEq(tracker.jobExecutor(jobId), address(0));
        assertEq(address(wallet).balance, walletEthBefore);
        assertEq(
            wallet.availableBalance(address(this)) + wallet.availableBalance(EXECUTOR_PAYMENT)
                + wallet.availableBalance(COMMITMENT_VALIDATOR) + wallet.availableBalance(INCLUSION_RECIPIENT),
            address(wallet).balance
        );
    }

    function testRealWalletUnderfundedReserveRollsBack() public {
        bytes32 jobId = keccak256("real-wallet-underfunded");
        uint256 funded = 0.5 ether;
        wallet.depositFor{value: funded}(address(this));

        vm.expectRevert(IRitualWallet.InsufficientBalance.selector);
        vm.prank(COMMITMENT_SYSTEM);
        tracker.addJobAndReserve(_job(jobId, address(this), 60), _reserve(address(this), 1 ether));

        _assertNoJob(jobId);
        assertEq(tracker.getJobCount(TEE_EXECUTOR), 0);
        assertEq(tracker.totalPending(), 0);
        assertEq(wallet.availableBalance(address(this)), funded);
        assertEq(wallet.reservedBalance(address(this)), 0);
        assertEq(address(wallet).balance, funded);
    }

    function testRealWalletDelegatedAllowanceRollsBackAndConsumesFiniteApproval() public {
        bytes32 jobId = keccak256("real-wallet-delegated");
        address sponsor = address(0xA11CE);
        address delegatedCaller = address(target);
        uint256 reserveAmount = 1 ether;
        uint256 insufficientAllowance = 0.4 ether;
        uint256 finiteAllowance = 1.25 ether;

        wallet.depositFor{value: 2 ether}(sponsor);
        vm.prank(sponsor);
        wallet.approve(delegatedCaller, insufficientAllowance);

        vm.expectRevert(IRitualWallet.InsufficientAllowance.selector);
        vm.prank(COMMITMENT_SYSTEM);
        tracker.addJobAndReserve(_job(jobId, delegatedCaller, 60), _reserve(sponsor, reserveAmount));

        _assertNoJob(jobId);
        assertEq(tracker.totalPending(), 0);
        assertEq(wallet.availableBalance(sponsor), 2 ether);
        assertEq(wallet.reservedBalance(sponsor), 0);
        assertEq(wallet.allowance(sponsor, delegatedCaller), insufficientAllowance);

        vm.prank(sponsor);
        wallet.approve(delegatedCaller, finiteAllowance);
        _addJob(jobId, sponsor, delegatedCaller, reserveAmount, 60);

        assertEq(wallet.allowance(sponsor, delegatedCaller), finiteAllowance - reserveAmount);
        assertEq(wallet.availableBalance(sponsor), 1 ether);
        assertEq(wallet.reservedBalance(sponsor), reserveAmount);
        assertEq(wallet.escrows(jobId).sponsor, sponsor);
        assertEq(wallet.escrows(jobId).reserved, reserveAmount);
        assertEq(tracker.getJobCount(TEE_EXECUTOR), 1);
    }

    function testScheduledAsyncRealWalletReservationAndFailureAtomicity() public {
        vm.coinbase(PROPOSER);
        wallet.depositFor{value: 3 ether}(address(target));

        bytes32 successOrigin = keccak256("real-wallet-scheduled-success");
        uint256 successCallId = _scheduleWithOrigin(successOrigin, 2, 2, 5);
        bytes32 successJobId = _scheduledJobId(successOrigin, successCallId, 0);
        AsyncJobTracker.AddJobInput memory successJob = _job(successJobId, address(target), 60);
        successJob.origHash = keccak256("scheduled-execution-transaction");

        vm.recordLogs();
        vm.prank(COMMITMENT_SYSTEM);
        tracker.addScheduledJobAndReserve(
            successJob,
            _reserve(address(target), 1 ether),
            AsyncJobTracker.ScheduledObligationRef({
                callId: successCallId, executionIndex: 0, scheduledOriginHash: successJobId
            })
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 inFlightTopic = keccak256("ScheduledAsyncInFlight(uint256,uint256,bytes32)");
        bool sawInFlight;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(scheduler) && logs[i].topics.length == 4
                    && logs[i].topics[0] == inFlightTopic && logs[i].topics[1] == bytes32(successCallId)
                    && logs[i].topics[2] == bytes32(uint256(0)) && logs[i].topics[3] == successJobId
            ) {
                sawInFlight = true;
            }
        }

        assertTrue(sawInFlight, "ScheduledAsyncInFlight not emitted");
        assertEq(wallet.escrows(successJobId).sponsor, address(target));
        assertEq(wallet.escrows(successJobId).reserved, 1 ether);
        assertEq(wallet.reservedBalance(address(target)), 1 ether);
        assertEq(tracker.jobExecutor(successJobId), TEE_EXECUTOR);
        assertFalse(scheduler.isExecuted(successCallId, 0));
        assertEq(uint8(scheduler.getCallState(successCallId)), uint8(CallState.SCHEDULED));

        bytes32 failedOrigin = keccak256("real-wallet-scheduled-reserve-failure");
        uint256 failedCallId = _scheduleWithOrigin(failedOrigin, 2, 2, 5);
        bytes32 failedJobId = _scheduledJobId(failedOrigin, failedCallId, 0);
        uint256 balanceBeforeFailure = wallet.availableBalance(address(target));
        uint256 reservedBeforeFailure = wallet.reservedBalance(address(target));
        uint256 pendingBeforeFailure = tracker.totalPending();

        vm.expectRevert(IRitualWallet.InsufficientBalance.selector);
        vm.prank(COMMITMENT_SYSTEM);
        tracker.addScheduledJobAndReserve(
            _job(failedJobId, address(target), 60),
            _reserve(address(target), 100 ether),
            AsyncJobTracker.ScheduledObligationRef({
                callId: failedCallId, executionIndex: 0, scheduledOriginHash: failedJobId
            })
        );

        _assertNoJob(failedJobId);
        assertEq(wallet.availableBalance(address(target)), balanceBeforeFailure);
        assertEq(wallet.reservedBalance(address(target)), reservedBeforeFailure);
        assertEq(tracker.totalPending(), pendingBeforeFailure);
        assertFalse(scheduler.isExecuted(failedCallId, 0));
        assertEq(uint8(scheduler.getCallState(failedCallId)), uint8(CallState.SCHEDULED));
        assertEq(scheduler.scheduledAsyncCleanupReason(failedCallId, 0), bytes32(0));
    }

    function testSchedulerRealWalletJitDebitSoftFailureEvictsWithoutCallback() public {
        vm.fee(1);
        vm.coinbase(PROPOSER);
        wallet.depositFor{value: 1 ether}(address(target));

        bytes32 origin = keccak256("real-wallet-jit-soft-failure");
        uint32 frequency = 2;
        uint256 callId = _scheduleWithOrigin(origin, 1, frequency, 5);
        assertGt(wallet.availableBalance(address(target)), 0);

        target.withdrawAvailable(wallet);
        assertEq(wallet.availableBalance(address(target)), 0);
        assertEq(wallet.reservedBalance(address(target)), 0);

        vm.roll(block.number + frequency);
        vm.prank(SCHEDULER_SYSTEM);
        scheduler.execute(callId, 0);

        assertEq(target.callbackCount(), 0);
        assertFalse(scheduler.isExecuted(callId, 0));
        assertEq(wallet.availableBalance(address(target)), 0);
        vm.expectRevert(Scheduler.CallNotFound.selector);
        scheduler.getCallState(callId);
    }

    function testExpiredTrackerJobReleasesRealWalletEscrow() public {
        bytes32 jobId = keccak256("real-wallet-expiry");
        uint256 initialDeposit = 2 ether;
        uint256 reserveAmount = 1 ether;
        wallet.depositFor{value: initialDeposit}(address(this));
        _addJob(jobId, address(this), address(this), reserveAmount, 2);

        uint64 expiryBlock = wallet.escrows(jobId).expiryBlock;
        assertEq(wallet.availableBalance(address(this)), initialDeposit - reserveAmount);
        assertEq(wallet.reservedBalance(address(this)), reserveAmount);

        vm.roll(expiryBlock);
        assertEq(tracker.cleanupExpired(TEE_EXECUTOR, 10), 0);
        assertEq(wallet.escrows(jobId).sponsor, address(this));

        vm.roll(uint256(expiryBlock) + 1);
        assertEq(tracker.cleanupExpired(TEE_EXECUTOR, 10), 1);

        _assertNoJob(jobId);
        assertEq(tracker.getJobCount(TEE_EXECUTOR), 0);
        assertEq(tracker.totalPending(), 0);
        assertEq(wallet.availableBalance(address(this)), initialDeposit);
        assertEq(wallet.reservedBalance(address(this)), 0);
        assertEq(address(wallet).balance, initialDeposit);
    }
}
