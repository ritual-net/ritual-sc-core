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
import {CREATE3} from "solady/utils/CREATE3.sol";

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
    uint256 public asyncCallbackCount;
    bytes32 public lastAsyncJobId;
    bytes public lastAsyncResult;
    uint256 public lastAsyncValue;

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

    function onAsyncResult(bytes32 jobId, bytes calldata result) external payable {
        asyncCallbackCount++;
        lastAsyncJobId = jobId;
        lastAsyncResult = result;
        lastAsyncValue = msg.value;
    }

    receive() external payable {}
}

contract ProtocolWalletIntegrationTest is Test {
    address internal constant COMMITMENT_SYSTEM = 0x000000000000000000000000000000000000Fa8e;
    address internal constant SETTLEMENT_SYSTEM = 0x000000000000000000000000000000000000fA9E;
    address internal constant SCHEDULER_SYSTEM = 0x000000000000000000000000000000000000fa7e;
    address internal constant TX_HASH_PRECOMPILE = 0x0000000000000000000000000000000000000830;
    address internal constant HTTP_CALL_PRECOMPILE = 0x0000000000000000000000000000000000000801;
    address internal constant LONG_RUNNING_HTTP_PRECOMPILE = 0x0000000000000000000000000000000000000805;
    address internal constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    event Settled(bytes32 indexed jobId, address indexed sponsor, bool isLongRunning);

    address internal constant TEE_EXECUTOR = address(0xE11);
    address internal constant EXECUTOR_PAYMENT = address(0xE0E);
    address internal constant COMMITMENT_VALIDATOR = address(0xC011);
    address internal constant INCLUSION_RECIPIENT = address(0x1CE);
    address internal constant PROPOSER = address(0xB10C);

    bytes32 internal constant WALLET_IMPLEMENTATION_SALT =
        keccak256("protocol-wallet-integration.wallet-implementation");
    bytes32 internal constant WALLET_PROXY_SALT = keccak256("protocol-wallet-integration.wallet-proxy");
    bytes32 internal constant SCHEDULER_IMPLEMENTATION_SALT =
        keccak256("protocol-wallet-integration.scheduler-implementation");
    bytes32 internal constant SCHEDULER_PROXY_SALT = keccak256("protocol-wallet-integration.scheduler-proxy");
    bytes32 internal constant TRACKER_IMPLEMENTATION_SALT =
        keccak256("protocol-wallet-integration.tracker-implementation");
    bytes32 internal constant TRACKER_PROXY_SALT = keccak256("protocol-wallet-integration.tracker-proxy");
    bytes32 internal constant DELIVERY_IMPLEMENTATION_SALT =
        keccak256("protocol-wallet-integration.delivery-implementation");
    bytes32 internal constant DELIVERY_PROXY_SALT = keccak256("protocol-wallet-integration.delivery-proxy");

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

        address walletImplementationAddress = CREATE3.predictDeterministicAddress(WALLET_IMPLEMENTATION_SALT);
        address walletProxyAddress = CREATE3.predictDeterministicAddress(WALLET_PROXY_SALT);
        address schedulerImplementationAddress = CREATE3.predictDeterministicAddress(SCHEDULER_IMPLEMENTATION_SALT);
        address schedulerProxyAddress = CREATE3.predictDeterministicAddress(SCHEDULER_PROXY_SALT);
        address trackerImplementationAddress = CREATE3.predictDeterministicAddress(TRACKER_IMPLEMENTATION_SALT);
        address trackerProxyAddress = CREATE3.predictDeterministicAddress(TRACKER_PROXY_SALT);
        address deliveryImplementationAddress = CREATE3.predictDeterministicAddress(DELIVERY_IMPLEMENTATION_SALT);
        address deliveryProxyAddress = CREATE3.predictDeterministicAddress(DELIVERY_PROXY_SALT);

        _deploy(
            abi.encodePacked(
                type(RitualWallet).creationCode,
                abi.encode(schedulerProxyAddress, deliveryProxyAddress, trackerProxyAddress)
            ),
            WALLET_IMPLEMENTATION_SALT,
            walletImplementationAddress
        );
        _deploy(
            abi.encodePacked(
                type(ERC1967Proxy).creationCode,
                abi.encode(walletImplementationAddress, abi.encodeCall(RitualWallet.initialize, (address(this))))
            ),
            WALLET_PROXY_SALT,
            walletProxyAddress
        );
        wallet = RitualWallet(payable(walletProxyAddress));

        _deploy(
            abi.encodePacked(type(Scheduler).creationCode, abi.encode(walletProxyAddress, uint32(30))),
            SCHEDULER_IMPLEMENTATION_SALT,
            schedulerImplementationAddress
        );
        _deploy(
            abi.encodePacked(
                type(ERC1967Proxy).creationCode,
                abi.encode(schedulerImplementationAddress, abi.encodeCall(Scheduler.initialize, (address(this))))
            ),
            SCHEDULER_PROXY_SALT,
            schedulerProxyAddress
        );
        scheduler = Scheduler(payable(schedulerProxyAddress));

        _deploy(
            abi.encodePacked(
                type(AsyncJobTracker).creationCode,
                abi.encode(deliveryProxyAddress, walletProxyAddress, address(teeRegistry))
            ),
            TRACKER_IMPLEMENTATION_SALT,
            trackerImplementationAddress
        );
        _deploy(
            abi.encodePacked(
                type(ERC1967Proxy).creationCode,
                abi.encode(trackerImplementationAddress, abi.encodeCall(AsyncJobTracker.initialize, (address(this))))
            ),
            TRACKER_PROXY_SALT,
            trackerProxyAddress
        );
        tracker = AsyncJobTracker(trackerProxyAddress);

        _deploy(
            abi.encodePacked(type(AsyncDelivery).creationCode, abi.encode(walletProxyAddress, trackerProxyAddress)),
            DELIVERY_IMPLEMENTATION_SALT,
            deliveryImplementationAddress
        );
        _deploy(
            abi.encodePacked(
                type(ERC1967Proxy).creationCode,
                abi.encode(deliveryImplementationAddress, abi.encodeCall(AsyncDelivery.initialize, (address(this))))
            ),
            DELIVERY_PROXY_SALT,
            deliveryProxyAddress
        );
        delivery = AsyncDelivery(payable(deliveryProxyAddress));

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

    function _deploy(bytes memory initCode, bytes32 salt, address expectedAddress) internal returns (address deployed) {
        deployed = CREATE3.deployDeterministic(initCode, salt);
        assertEq(deployed, expectedAddress, "CREATE3 address drift");
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

    function _admitScheduledJob(uint256 callId, bytes32 jobId, address precomp, bytes memory input, uint256 amount)
        internal
    {
        AsyncJobTracker.AddJobInput memory job = _job(jobId, address(target), 60);
        job.precomp = precomp;
        job.input = input;
        job.origHash = keccak256("scheduled-execution-transaction");

        vm.prank(COMMITMENT_SYSTEM);
        tracker.addScheduledJobAndReserve(
            job,
            _reserve(address(target), amount),
            AsyncJobTracker.ScheduledObligationRef({callId: callId, executionIndex: 0, scheduledOriginHash: jobId})
        );
    }

    function _assertScheduledObligationUntouched(uint256 callId) internal view {
        assertFalse(scheduler.isExecuted(callId, 0));
        assertEq(uint8(scheduler.getCallState(callId)), uint8(CallState.SCHEDULED));
        assertEq(scheduler.scheduledAsyncCleanupReason(callId, 0), bytes32(0));
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

    function testPartiallySettledTrackerJobExpiresRealWalletEscrow() public {
        bytes32 jobId = keccak256("real-wallet-partial-settlement-expiry");
        uint256 initialDeposit = 2 ether;
        uint256 reserveAmount = 1.5 ether;
        uint256 executorFee = 0.1 ether;
        uint256 commitmentFee = 0.1 ether;
        uint256 inclusionFee = 0.1 ether;
        uint256 totalPaid = executorFee + commitmentFee + inclusionFee;
        uint256 phase2DeadlineOffset = 5;
        bytes memory input = bytes.concat(new bytes(8 * 32), abi.encode(phase2DeadlineOffset));

        wallet.depositFor{value: initialDeposit}(address(this));
        AsyncJobTracker.AddJobInput memory job = _job(jobId, address(this), 60);
        job.precomp = LONG_RUNNING_HTTP_PRECOMPILE;
        job.input = input;
        vm.prank(COMMITMENT_SYSTEM);
        tracker.addJobAndReserve(job, _reserve(address(this), reserveAmount));

        vm.coinbase(INCLUSION_RECIPIENT);
        vm.prank(SETTLEMENT_SYSTEM);
        assertTrue(delivery.settle(jobId, executorFee, commitmentFee, inclusionFee, input));

        IRitualWallet.Escrow memory escrow = wallet.escrows(jobId);
        assertTrue(tracker.isPhase1Settled(jobId));
        assertEq(escrow.sponsor, address(this));
        assertEq(escrow.reserved, reserveAmount - totalPaid);
        assertEq(escrow.paid, totalPaid);
        assertEq(escrow.expiryBlock, uint64(block.number + phase2DeadlineOffset));
        assertEq(wallet.reservedBalance(address(this)), reserveAmount - totalPaid);

        vm.roll(uint256(escrow.expiryBlock) + 1);
        assertEq(tracker.cleanupExpired(TEE_EXECUTOR, 10), 1);

        _assertNoJob(jobId);
        assertEq(tracker.getJobCount(TEE_EXECUTOR), 0);
        assertEq(tracker.totalPending(), 0);
        assertEq(wallet.availableBalance(address(this)), initialDeposit - totalPaid);
        assertEq(wallet.availableBalance(EXECUTOR_PAYMENT), executorFee);
        assertEq(wallet.availableBalance(COMMITMENT_VALIDATOR), commitmentFee);
        assertEq(wallet.availableBalance(INCLUSION_RECIPIENT), inclusionFee);
        assertEq(wallet.reservedBalance(address(this)), 0);
        assertEq(address(wallet).balance, initialDeposit);
        assertEq(
            address(wallet).balance,
            wallet.availableBalance(address(this)) + wallet.availableBalance(EXECUTOR_PAYMENT)
                + wallet.availableBalance(COMMITMENT_VALIDATOR) + wallet.availableBalance(INCLUSION_RECIPIENT)
        );
    }

    function testScheduledAsyncSettlementClosesRealWalletEscrowWithoutConsumingSchedule() public {
        vm.coinbase(INCLUSION_RECIPIENT);
        wallet.depositFor{value: 3 ether}(address(target));

        bytes32 origin = keccak256("real-wallet-scheduled-settlement");
        uint256 callId = _scheduleWithOrigin(origin, 2, 2, 5);
        bytes32 jobId = _scheduledJobId(origin, callId, 0);
        uint256 reserveAmount = 1 ether;
        _admitScheduledJob(callId, jobId, HTTP_CALL_PRECOMPILE, "", reserveAmount);

        uint256 executorFee = 0.2 ether;
        uint256 commitmentFee = 0.15 ether;
        uint256 inclusionFee = 0.1 ether;
        uint256 totalFees = executorFee + commitmentFee + inclusionFee;
        uint256 sponsorAvailableBefore = wallet.availableBalance(address(target));
        uint256 inclusionAvailableBefore = wallet.availableBalance(INCLUSION_RECIPIENT);
        uint256 walletEthBefore = address(wallet).balance;

        vm.expectEmit(true, true, false, true, address(delivery));
        emit Settled(jobId, address(target), false);
        vm.prank(SETTLEMENT_SYSTEM);
        assertTrue(delivery.settle(jobId, executorFee, commitmentFee, inclusionFee, ""));

        assertEq(wallet.availableBalance(address(target)), sponsorAvailableBefore + reserveAmount - totalFees);
        assertEq(wallet.availableBalance(EXECUTOR_PAYMENT), executorFee);
        assertEq(wallet.availableBalance(COMMITMENT_VALIDATOR), commitmentFee);
        assertEq(wallet.availableBalance(INCLUSION_RECIPIENT), inclusionAvailableBefore + inclusionFee);
        assertEq(wallet.reservedBalance(address(target)), 0);
        _assertNoJob(jobId);
        assertEq(tracker.getJobCount(TEE_EXECUTOR), 0);
        assertEq(tracker.totalPending(), 0);
        assertEq(address(wallet).balance, walletEthBefore);
        assertEq(
            address(wallet).balance,
            wallet.availableBalance(address(target)) + wallet.availableBalance(EXECUTOR_PAYMENT)
                + wallet.availableBalance(COMMITMENT_VALIDATOR) + wallet.availableBalance(INCLUSION_RECIPIENT)
        );

        // Settlement must not consume the scheduler obligation: reth suppresses
        // duplicate commitments while the async job is active, so the call stays
        // SCHEDULED with the execution index unconsumed.
        _assertScheduledObligationUntouched(callId);
    }

    function testScheduledLongRunningTwoPhaseDeliveryAgainstRealWallet() public {
        vm.coinbase(INCLUSION_RECIPIENT);
        wallet.depositFor{value: 5 ether}(address(target));

        bytes32 origin = keccak256("real-wallet-scheduled-two-phase");
        uint256 callId = _scheduleWithOrigin(origin, 2, 2, 5);
        bytes32 jobId = _scheduledJobId(origin, callId, 0);

        // Long-running HTTP family input: field 8 carries the Phase 2 deadline offset.
        uint256 phase2DeadlineOffset = 100;
        bytes memory input = bytes.concat(new bytes(8 * 32), abi.encode(phase2DeadlineOffset));
        uint256 reserveAmount = 2 ether;
        _admitScheduledJob(callId, jobId, LONG_RUNNING_HTTP_PRECOMPILE, input, reserveAmount);
        assertTrue(tracker.isLongRunning(jobId));

        uint256 phase1ExecutorFee = 0.1 ether;
        uint256 commitmentFee = 0.05 ether;
        uint256 inclusionFee = 0.05 ether;
        uint256 phase1Fees = phase1ExecutorFee + commitmentFee + inclusionFee;

        vm.expectEmit(true, true, false, true, address(delivery));
        emit Settled(jobId, address(target), true);
        vm.prank(SETTLEMENT_SYSTEM);
        assertTrue(delivery.settle(jobId, phase1ExecutorFee, commitmentFee, inclusionFee, input));

        assertTrue(tracker.isPhase1Settled(jobId));
        assertEq(tracker.jobExecutor(jobId), TEE_EXECUTOR);
        IRitualWallet.Escrow memory escrow = wallet.escrows(jobId);
        assertEq(escrow.sponsor, address(target));
        assertEq(escrow.reserved, reserveAmount - phase1Fees);
        assertEq(escrow.paid, phase1Fees);
        assertEq(escrow.expiryBlock, uint64(block.number + phase2DeadlineOffset));

        uint256 phase2ExecutorFee = 0.1 ether;
        uint256 effectiveFeePerGas = 2 gwei;
        uint256 baseFeePerGas = 1 gwei;
        uint256 callbackGasLimit = 500_000;
        uint256 callbackValue = 0.01 ether;
        uint256 callbackGasBudget = effectiveFeePerGas * callbackGasLimit;
        vm.fee(baseFeePerGas);

        uint256 sponsorAvailableBefore = wallet.availableBalance(address(target));
        uint256 burnBefore = BURN_ADDRESS.balance;
        uint256 proposerAvailableBefore = wallet.availableBalance(INCLUSION_RECIPIENT);

        vm.prank(SETTLEMENT_SYSTEM);
        assertTrue(
            delivery.deliver(
                jobId,
                phase2ExecutorFee,
                effectiveFeePerGas,
                callbackGasLimit,
                callbackValue,
                address(target),
                ProtocolWalletSchedulerTarget.onAsyncResult.selector,
                input,
                hex"C0DE"
            )
        );

        uint256 baseFeeBurned = BURN_ADDRESS.balance - burnBefore;
        uint256 gasConsumed = baseFeeBurned / baseFeePerGas;
        assertGt(gasConsumed, 0);
        assertLe(gasConsumed, callbackGasLimit);

        // Callback delivered against the production wallet's escrowed value.
        assertEq(target.asyncCallbackCount(), 1);
        assertEq(target.lastAsyncJobId(), jobId);
        assertEq(target.lastAsyncResult(), hex"C0DE");
        assertEq(target.lastAsyncValue(), callbackValue);

        // Gas accounting: burn at base fee, capped tip to proposer, unused budget refunded.
        assertEq(baseFeeBurned, gasConsumed * baseFeePerGas);
        uint256 proposerTip = gasConsumed * (effectiveFeePerGas - baseFeePerGas);
        assertEq(INCLUSION_RECIPIENT.balance, 0);
        assertEq(wallet.availableBalance(INCLUSION_RECIPIENT) - proposerAvailableBefore, proposerTip);
        assertEq(address(delivery).balance, 0);

        uint256 gasRefund = (callbackGasLimit - gasConsumed) * effectiveFeePerGas;
        uint256 escrowRemainder = reserveAmount - phase1Fees - phase2ExecutorFee - callbackGasBudget - callbackValue;
        assertEq(wallet.availableBalance(address(target)), sponsorAvailableBefore + escrowRemainder + gasRefund);
        assertEq(wallet.availableBalance(EXECUTOR_PAYMENT), phase1ExecutorFee + phase2ExecutorFee);
        assertEq(wallet.availableBalance(COMMITMENT_VALIDATOR), commitmentFee);
        assertEq(wallet.availableBalance(INCLUSION_RECIPIENT), proposerAvailableBefore + proposerTip);

        // Lifecycle fully closed with wallet solvency intact.
        _assertNoJob(jobId);
        assertEq(tracker.getJobCount(TEE_EXECUTOR), 0);
        assertEq(tracker.totalPending(), 0);
        assertEq(wallet.reservedBalance(address(target)), 0);
        assertEq(
            address(wallet).balance,
            wallet.availableBalance(address(target)) + wallet.availableBalance(EXECUTOR_PAYMENT)
                + wallet.availableBalance(COMMITMENT_VALIDATOR) + wallet.availableBalance(INCLUSION_RECIPIENT)
        );

        // The scheduler obligation survives the entire two-phase delivery.
        _assertScheduledObligationUntouched(callId);
    }
}
