// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {AsyncJobTracker} from "../src/async/AsyncJobTracker.sol";
import {Scheduler, CallState} from "../src/scheduler/Scheduler.sol";
import {IRitualWallet} from "../src/wallet/IRitualWallet.sol";
import {ITEECapabilityPolicy} from "../src/async/ITEECapabilityPolicy.sol";
import {ITEEServiceRegistry} from "../src/async/ITEEServiceRegistry.sol";
import {MockRitualWallet} from "./MockRitualWallet.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockTEEServiceRegistryForTracker {
    mapping(address => bool) internal serviceExists;
    mapping(address => bool) internal serviceValid;
    mapping(address => ITEECapabilityPolicy.Capability) internal serviceCapability;

    function setService(address executor, ITEECapabilityPolicy.Capability capability, bool valid) external {
        serviceExists[executor] = true;
        serviceValid[executor] = valid;
        serviceCapability[executor] = capability;
    }

    function getValidService(address executor)
        external
        view
        returns (ITEEServiceRegistry.TEEServiceContext memory context)
    {
        if (!serviceExists[executor]) {
            revert ITEEServiceRegistry.ServiceNotFound(executor);
        }
        if (!serviceValid[executor]) {
            revert ITEEServiceRegistry.AttestationInvalid(executor);
        }

        context.node.teeAddress = executor;
        context.node.paymentAddress = executor;
        context.node.capability = serviceCapability[executor];
        context.isValid = true;
        context.workloadId = bytes32(uint256(uint160(executor)));
    }
}

contract AsyncJobTrackerTest is Test {
    AsyncJobTracker internal tracker;
    MockRitualWallet internal wallet;
    Scheduler internal scheduler;

    address internal constant COMMITMENT = 0x000000000000000000000000000000000000Fa8e;
    /// @dev Used as the mock AsyncDelivery address for the tracker constructor
    address internal constant MOCK_ASYNC_DELIVERY = 0x000000000000000000000000000000000000fA9E;
    address internal constant TX_HASH_PRECOMPILE = 0x0000000000000000000000000000000000000830;
    address internal constant SYSTEM_ACCOUNT = 0x000000000000000000000000000000000000fa7e;

    address internal constant EXECUTOR = address(0xBEEF);
    address internal constant HTTP_CALL = address(0x0801);
    address internal constant PERSISTENT_AGENT = address(0x0820);
    address internal constant DKMS_KEY = address(0x081B);
    address internal constant LONG_RUNNING_HTTP = address(0x0805);
    address internal constant ZK_TWO_PHASE = address(0x0806);
    address internal constant FHE = address(0x0807);
    address internal constant SOVEREIGN = address(0x080C);
    address internal constant IMAGE = address(0x0818);
    address internal constant AUDIO = address(0x0819);
    address internal constant VIDEO = address(0x081A);
    address internal constant PERSISTENT = address(0x0820);

    function setUp() public {
        wallet = new MockRitualWallet(address(0));
        AsyncJobTracker implementation = new AsyncJobTracker(MOCK_ASYNC_DELIVERY, address(wallet), address(0));
        bytes memory initData = abi.encodeWithSelector(AsyncJobTracker.initialize.selector, address(this));
        tracker = AsyncJobTracker(address(new ERC1967Proxy(address(implementation), initData)));
        Scheduler schedulerImplementation = new Scheduler(address(wallet), 30);
        scheduler = Scheduler(
            payable(address(
                    new ERC1967Proxy(
                        address(schedulerImplementation),
                        abi.encodeWithSelector(Scheduler.initialize.selector, address(this))
                    )
                ))
        );
        scheduler.setAsyncJobTracker(address(tracker));
        tracker.setScheduler(address(scheduler));
        wallet.setScheduler(address(scheduler));
        wallet.setTransferFullScheduledFee(true);
        vm.deal(address(wallet), 100 ether);
    }

    function _addJobCompat(
        address exec,
        bytes32 id,
        address precomp,
        bytes memory input,
        uint256 ttl,
        bytes32 prevHash,
        uint256 prevNum,
        uint256 prevTime,
        address sender,
        address commitVal,
        bytes32 origHash,
        bytes memory origRlp,
        address txOrigin
    ) internal {
        bytes32[] memory expiredEscrows = new bytes32[](0);
        tracker.addJobAndReserve(
            AsyncJobTracker.AddJobInput({
                exec: exec,
                id: id,
                precomp: precomp,
                input: input,
                ttl: ttl,
                prevHash: prevHash,
                prevNum: prevNum,
                prevTime: prevTime,
                caller: sender,
                commitVal: commitVal,
                origHash: origHash,
                origRlp: origRlp,
                txOrigin: txOrigin
            }),
            AsyncJobTracker.ReserveConfig({sponsor: sender, reserveAmount: 0, expiredEscrows: expiredEscrows})
        );
    }

    function _addJobCompat(
        address exec,
        bytes32 id,
        address precomp,
        bytes memory input,
        uint256 ttl,
        bytes32 prevHash,
        uint256 prevNum,
        uint256 prevTime,
        address sender,
        address commitVal,
        bytes32 origHash,
        bytes memory origRlp
    ) internal {
        _addJobCompat(
            exec, id, precomp, input, ttl, prevHash, prevNum, prevTime, sender, commitVal, origHash, origRlp, sender
        );
    }

    function _addJob(bytes32 jobId, uint256 ttl) internal {
        address precompileAddress = address(0x0805); // HTTP precompile
        bytes memory precompileInput = hex"010203";
        bytes32 previousBlockHash = bytes32(0);
        uint256 previousBlockNumber = block.number - 1;
        uint256 previousBlockTimestamp = block.timestamp - 1;
        address senderAddress = address(0x1234);
        address commitmentValidator = address(0x5678);
        bytes32 originHash = keccak256(abi.encodePacked("origin"));
        bytes memory originRlp = hex"DEADBEEF";

        vm.prank(COMMITMENT);
        _addJobCompat(
            EXECUTOR,
            jobId,
            precompileAddress,
            precompileInput,
            ttl,
            previousBlockHash,
            previousBlockNumber,
            previousBlockTimestamp,
            senderAddress,
            commitmentValidator,
            originHash,
            originRlp,
            senderAddress
        );
    }

    function _job(bytes32 jobId, address caller, uint256 ttl)
        internal
        view
        returns (AsyncJobTracker.AddJobInput memory)
    {
        return AsyncJobTracker.AddJobInput({
            exec: EXECUTOR,
            id: jobId,
            precomp: address(0x0805),
            input: hex"010203",
            ttl: ttl,
            prevHash: bytes32(0),
            prevNum: block.number - 1,
            prevTime: block.timestamp - 1,
            caller: caller,
            commitVal: address(0x5678),
            origHash: jobId,
            origRlp: hex"DEADBEEF",
            txOrigin: address(0)
        });
    }

    function _reserve(address sponsor, uint256 amount, uint256)
        internal
        pure
        returns (AsyncJobTracker.ReserveConfig memory)
    {
        bytes32[] memory expiredEscrows = new bytes32[](0);
        return AsyncJobTracker.ReserveConfig({sponsor: sponsor, reserveAmount: amount, expiredEscrows: expiredEscrows});
    }

    function _scheduleTwoCall() internal returns (uint256 callId) {
        wallet.setBalance(address(this), 2 ether);
        callId = scheduler.schedule(hex"01020304", 100_000, 2, 1, 10, 20 gwei, 1 gwei, 0);
    }

    function _scheduleCallWithOrigin(bytes32 origin) internal returns (uint256 callId) {
        bytes memory emptyCalldata = new bytes(0);
        vm.mockCall(TX_HASH_PRECOMPILE, emptyCalldata, abi.encode(origin));
        callId = scheduler.schedule(hex"01020304", 100_000, 2, 1, 10, 20 gwei, 1 gwei, 0);
        vm.clearMockedCalls();
        assertEq(scheduler.originHash(callId), origin);
    }

    function _scheduledJobId(bytes32 origin, uint256 callId, uint256 executionIndex) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(origin, callId, executionIndex));
    }

    function _addJobWithInput(bytes32 jobId, uint256 ttl, bytes memory precompileInput) internal {
        address precompileAddress = address(0x0805); // HTTP precompile
        bytes32 previousBlockHash = bytes32(0);
        uint256 previousBlockNumber = block.number - 1;
        uint256 previousBlockTimestamp = block.timestamp - 1;
        address senderAddress = address(0x1234);
        address commitmentValidator = address(0x5678);
        bytes32 originHash = keccak256(abi.encodePacked("origin"));
        bytes memory originRlp = hex"DEADBEEF";

        vm.prank(COMMITMENT);
        _addJobCompat(
            EXECUTOR,
            jobId,
            precompileAddress,
            precompileInput,
            ttl,
            previousBlockHash,
            previousBlockNumber,
            previousBlockTimestamp,
            senderAddress,
            commitmentValidator,
            originHash,
            originRlp,
            senderAddress
        );
    }

    function _closeEscrow(bytes32 jobId) internal {
        wallet.settle(jobId, new IRitualWallet.Payment[](0), 0, 0, true);
    }

    function testAddJobAndGet() public {
        bytes32 jobId = keccak256(abi.encodePacked("job1"));
        bytes memory expectedInput = hex"010203";
        _addJob(jobId, 60);

        // getJob returns (Job, bytes, bytes) - SC-2: bytes are empty
        (AsyncJobTracker.Job memory j, bytes memory input, bytes memory rlp) = tracker.getJob(jobId);
        assertEq(j.id, jobId);
        assertEq(j.executor, EXECUTOR);
        assertEq(j.ttl, 60);
        assertEq(j.precompile, address(0x0805));
        assertEq(j.commitBlock, block.number);
        // SC-2: getJob returns empty bytes
        assertEq(input, "");
        assertEq(rlp, "");

        // SC-2: Use getInputHash to verify the hash was stored correctly
        (bytes32 inputHash, uint256 inputSize) = tracker.getInputHash(jobId);
        assertEq(inputHash, keccak256(expectedInput));
        assertEq(inputSize, expectedInput.length);

        // getPendingJobs returns (Job[], bytes[], bytes[]) - SC-2: bytes are empty
        (AsyncJobTracker.Job[] memory jobs, bytes[] memory inputs, bytes[] memory rlps) =
            tracker.getPendingJobs(EXECUTOR);
        assertEq(jobs.length, 1);
        assertEq(jobs[0].id, jobId);
        assertEq(inputs[0], ""); // SC-2: empty
        assertEq(rlps[0], ""); // SC-2: empty

        // getJobCount
        assertEq(tracker.getJobCount(EXECUTOR), 1);
    }

    function testAddJobAndReserveStoresAfterReserveSuccess() public {
        bytes32 jobId = keccak256("normal-reserved-job");
        wallet.setBalance(address(this), 2 ether);

        vm.prank(COMMITMENT);
        tracker.addJobAndReserve(_job(jobId, address(this), 60), _reserve(address(this), 1 ether, 60));

        (AsyncJobTracker.Job memory j,,) = tracker.getJob(jobId);
        assertEq(j.id, jobId);
        assertEq(tracker.getJobCount(EXECUTOR), 1);
        assertEq(wallet.escrows(jobId).sponsor, address(this));
    }

    function testScheduledAddJobSuccessStoresWithoutConsumingSchedulerIndex() public {
        bytes32 origin = keccak256("scheduled-success");
        wallet.setBalance(address(this), 2 ether);
        uint256 callId = _scheduleCallWithOrigin(origin);
        bytes32 jobId = _scheduledJobId(origin, callId, 0);
        bytes32 originatingTxHash = keccak256("scheduled-execution-tx");
        AsyncJobTracker.AddJobInput memory job = _job(jobId, address(this), 60);
        job.origHash = originatingTxHash;

        vm.prank(COMMITMENT);
        tracker.addScheduledJobAndReserve(
            job,
            _reserve(address(this), 1 ether, 60),
            AsyncJobTracker.ScheduledObligationRef({callId: callId, executionIndex: 0, scheduledOriginHash: jobId})
        );

        (AsyncJobTracker.Job memory j,,) = tracker.getJob(jobId);
        assertEq(j.id, jobId);
        assertEq(j.originHash, originatingTxHash);
        assertFalse(scheduler.isExecuted(callId, 0));
        assertEq(uint8(scheduler.getCallState(callId)), uint8(CallState.SCHEDULED));

        vm.deal(address(scheduler), 1 ether);
        vm.roll(block.number + 1);
        vm.prank(SYSTEM_ACCOUNT);
        scheduler.execute(callId, 0);
        assertTrue(scheduler.isExecuted(callId, 0));
        assertEq(uint8(scheduler.getCallState(callId)), uint8(CallState.SCHEDULED));
    }

    function testRecurringScheduledAsyncUsesDistinctJobIdsPerExecution() public {
        bytes32 origin = keccak256("scheduled-recurring");
        wallet.setBalance(address(this), 4 ether);
        uint256 callId = _scheduleCallWithOrigin(origin);
        bytes32 job0 = _scheduledJobId(origin, callId, 0);
        bytes32 job1 = _scheduledJobId(origin, callId, 1);
        assertTrue(job0 != job1);

        vm.prank(COMMITMENT);
        tracker.addScheduledJobAndReserve(
            _job(job0, address(this), 60),
            _reserve(address(this), 1 ether, 60),
            AsyncJobTracker.ScheduledObligationRef({callId: callId, executionIndex: 0, scheduledOriginHash: job0})
        );

        vm.prank(COMMITMENT);
        tracker.addScheduledJobAndReserve(
            _job(job1, address(this), 60),
            _reserve(address(this), 1 ether, 60),
            AsyncJobTracker.ScheduledObligationRef({callId: callId, executionIndex: 1, scheduledOriginHash: job1})
        );

        (AsyncJobTracker.Job memory first,,) = tracker.getJob(job0);
        (AsyncJobTracker.Job memory second,,) = tracker.getJob(job1);
        assertEq(first.id, job0);
        assertEq(second.id, job1);
        assertEq(tracker.getJobCount(EXECUTOR), 2);
    }

    function testScheduledReserveEconomicFailureRevertsWithoutEviction() public {
        bytes32 origin = keccak256("scheduled-economic-failure");
        wallet.setBalance(address(this), 0.14 ether);
        bytes memory emptyCalldata = new bytes(0);
        vm.mockCall(TX_HASH_PRECOMPILE, emptyCalldata, abi.encode(origin));
        uint256 callId = scheduler.schedule(hex"01020304", 100_000, 2, 1, 10, 20 gwei, 1 gwei, 0);
        vm.clearMockedCalls();
        assertEq(scheduler.originHash(callId), origin);
        bytes32 jobId = _scheduledJobId(origin, callId, 0);

        vm.prank(COMMITMENT);
        vm.expectRevert(IRitualWallet.InsufficientBalance.selector);
        tracker.addScheduledJobAndReserve(
            _job(jobId, address(this), 60),
            _reserve(address(this), 1 ether, 60),
            AsyncJobTracker.ScheduledObligationRef({callId: callId, executionIndex: 0, scheduledOriginHash: jobId})
        );

        assertEq(tracker.getJobCount(EXECUTOR), 0);
        assertEq(scheduler.scheduledAsyncCleanupReason(callId, 0), bytes32(0));
        vm.expectRevert("not found");
        tracker.getJob(jobId);
        assertEq(uint8(scheduler.getCallState(callId)), uint8(CallState.SCHEDULED));
    }

    function testScheduledMalformedReferenceReverts() public {
        bytes32 origin = keccak256("scheduled-malformed-reference");
        wallet.setBalance(address(this), 2 ether);
        uint256 callId = _scheduleCallWithOrigin(origin);
        bytes32 jobId = _scheduledJobId(origin, callId, 0);

        vm.prank(COMMITMENT);
        vm.expectRevert("scheduled job mismatch");
        tracker.addScheduledJobAndReserve(
            _job(jobId, address(this), 60),
            _reserve(address(this), 1 ether, 60),
            AsyncJobTracker.ScheduledObligationRef({
                callId: callId, executionIndex: 0, scheduledOriginHash: keccak256("wrong")
            })
        );
    }

    function testScheduledUnauthorizedCallerReverts() public {
        bytes32 origin = keccak256("scheduled-unauthorized-caller");
        wallet.setBalance(address(this), 2 ether);
        uint256 callId = _scheduleCallWithOrigin(origin);
        bytes32 jobId = _scheduledJobId(origin, callId, 0);

        vm.expectRevert("only commitment caller");
        tracker.addScheduledJobAndReserve(
            _job(jobId, address(this), 60),
            _reserve(address(this), 1 ether, 60),
            AsyncJobTracker.ScheduledObligationRef({callId: callId, executionIndex: 0, scheduledOriginHash: jobId})
        );
    }

    function testScheduledWrongSchedulerOriginReverts() public {
        bytes32 origin = keccak256("scheduled-origin-mismatch");
        wallet.setBalance(address(this), 2 ether);
        uint256 callId = _scheduleCallWithOrigin(keccak256("stored-origin"));
        bytes32 jobId = _scheduledJobId(origin, callId, 0);

        vm.prank(COMMITMENT);
        vm.expectRevert(Scheduler.ScheduledAsyncOriginMismatch.selector);
        tracker.addScheduledJobAndReserve(
            _job(jobId, address(this), 60),
            _reserve(address(this), 1 ether, 60),
            AsyncJobTracker.ScheduledObligationRef({callId: callId, executionIndex: 0, scheduledOriginHash: jobId})
        );
    }

    function testPreventDuplicateJobId() public {
        bytes32 jobId = keccak256(abi.encodePacked("job-dup"));
        _addJob(jobId, 60);

        address precompileAddress = address(0x0805); // HTTP precompile
        bytes memory precompileInput = hex"010203";
        bytes32 previousBlockHash = bytes32(0);
        uint256 previousBlockNumber = block.number - 1;
        uint256 previousBlockTimestamp = block.timestamp - 1;

        vm.prank(COMMITMENT);
        vm.expectRevert(bytes("active job exists"));
        _addJobCompat(
            EXECUTOR,
            jobId,
            precompileAddress,
            precompileInput,
            60,
            previousBlockHash,
            previousBlockNumber,
            previousBlockTimestamp,
            address(0x1234), // Test sender address
            address(0x5678), // commitmentValidator
            keccak256(abi.encodePacked("origin")), // originHash
            hex"DEADBEEF", // originRlp
            address(0x1234) // txOrigin
        );
    }

    function testRejectsUnregisteredExecutorBeforeReserve() public {
        MockTEEServiceRegistryForTracker teeRegistry = new MockTEEServiceRegistryForTracker();
        AsyncJobTracker implementation = new AsyncJobTracker(MOCK_ASYNC_DELIVERY, address(wallet), address(teeRegistry));
        bytes memory initData = abi.encodeWithSelector(AsyncJobTracker.initialize.selector, address(this));
        AsyncJobTracker validatingTracker =
            AsyncJobTracker(address(new ERC1967Proxy(address(implementation), initData)));

        bytes32 jobId = keccak256("missing-executor");
        bytes32[] memory expiredEscrows = new bytes32[](0);

        vm.prank(COMMITMENT);
        vm.expectRevert(abi.encodeWithSelector(AsyncJobTracker.InvalidExecutor.selector, EXECUTOR));
        validatingTracker.addJobAndReserve(
            AsyncJobTracker.AddJobInput({
                exec: EXECUTOR,
                id: jobId,
                precomp: HTTP_CALL,
                input: hex"010203",
                ttl: 60,
                prevHash: bytes32(0),
                prevNum: block.number - 1,
                prevTime: block.timestamp - 1,
                caller: address(0x1234),
                commitVal: address(0x5678),
                origHash: keccak256("origin"),
                origRlp: hex"DEADBEEF",
                txOrigin: address(0x1234)
            }),
            AsyncJobTracker.ReserveConfig({sponsor: address(0x1234), reserveAmount: 0, expiredEscrows: expiredEscrows})
        );

        assertEq(validatingTracker.getJobCount(EXECUTOR), 0);
    }

    function testScheduledUnregisteredExecutorRevertsWithoutEviction() public {
        MockTEEServiceRegistryForTracker teeRegistry = new MockTEEServiceRegistryForTracker();
        AsyncJobTracker implementation = new AsyncJobTracker(MOCK_ASYNC_DELIVERY, address(wallet), address(teeRegistry));
        bytes memory initData = abi.encodeWithSelector(AsyncJobTracker.initialize.selector, address(this));
        AsyncJobTracker validatingTracker =
            AsyncJobTracker(address(new ERC1967Proxy(address(implementation), initData)));

        validatingTracker.setScheduler(address(scheduler));
        scheduler.setAsyncJobTracker(address(validatingTracker));

        bytes32 origin = keccak256("scheduled-missing-executor");
        wallet.setBalance(address(this), 2 ether);
        uint256 callId = _scheduleCallWithOrigin(origin);
        bytes32 jobId = _scheduledJobId(origin, callId, 0);

        vm.prank(COMMITMENT);
        vm.expectRevert(abi.encodeWithSelector(AsyncJobTracker.InvalidExecutor.selector, EXECUTOR));
        validatingTracker.addScheduledJobAndReserve(
            _job(jobId, address(this), 60),
            _reserve(address(this), 1 ether, 60),
            AsyncJobTracker.ScheduledObligationRef({callId: callId, executionIndex: 0, scheduledOriginHash: jobId})
        );

        assertEq(validatingTracker.getJobCount(EXECUTOR), 0);
        assertEq(scheduler.scheduledAsyncCleanupReason(callId, 0), bytes32(0));
        vm.expectRevert("not found");
        validatingTracker.getJob(jobId);
        assertEq(uint8(scheduler.getCallState(callId)), uint8(CallState.SCHEDULED));
    }

    function testScheduledCleanupRecordsReasonWithoutInsufficientFundsEvent() public {
        bytes32 origin = keccak256("scheduled-cleanup");
        wallet.setBalance(address(this), 2 ether);
        uint256 callId = _scheduleCallWithOrigin(origin);
        bytes32 jobId = _scheduledJobId(origin, callId, 0);
        bytes32 reason = bytes32(uint256(4));

        vm.recordLogs();
        vm.prank(COMMITMENT);
        scheduler.cleanupInvalidScheduledAsync(callId, 0, jobId, reason);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 insufficientFundsTopic =
            keccak256("CallEvictedInsufficientFunds(uint256,address,address,uint256,uint256)");
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != insufficientFundsTopic);
        }
        assertEq(scheduler.scheduledAsyncCleanupReason(callId, 0), reason);
        vm.expectRevert(Scheduler.CallNotFound.selector);
        scheduler.getCallState(callId);
    }

    function testScheduledCleanupRejectsUnauthorizedCaller() public {
        vm.expectRevert(Scheduler.UnauthorizedSender.selector);
        scheduler.cleanupInvalidScheduledAsync(0, 0, bytes32(0), bytes32(uint256(4)));
    }

    function testRejectsExecutorWithWrongCapability() public {
        MockTEEServiceRegistryForTracker teeRegistry = new MockTEEServiceRegistryForTracker();
        teeRegistry.setService(EXECUTOR, ITEECapabilityPolicy.Capability.LLM, true);
        AsyncJobTracker implementation = new AsyncJobTracker(MOCK_ASYNC_DELIVERY, address(wallet), address(teeRegistry));
        bytes memory initData = abi.encodeWithSelector(AsyncJobTracker.initialize.selector, address(this));
        AsyncJobTracker validatingTracker =
            AsyncJobTracker(address(new ERC1967Proxy(address(implementation), initData)));

        bytes32[] memory expiredEscrows = new bytes32[](0);

        vm.prank(COMMITMENT);
        vm.expectRevert(
            abi.encodeWithSelector(
                AsyncJobTracker.InvalidExecutorCapability.selector,
                EXECUTOR,
                HTTP_CALL,
                ITEECapabilityPolicy.Capability.LLM
            )
        );
        validatingTracker.addJobAndReserve(
            AsyncJobTracker.AddJobInput({
                exec: EXECUTOR,
                id: keccak256("wrong-capability"),
                precomp: HTTP_CALL,
                input: hex"010203",
                ttl: 60,
                prevHash: bytes32(0),
                prevNum: block.number - 1,
                prevTime: block.timestamp - 1,
                caller: address(0x1234),
                commitVal: address(0x5678),
                origHash: keccak256("origin"),
                origRlp: hex"DEADBEEF",
                txOrigin: address(0x1234)
            }),
            AsyncJobTracker.ReserveConfig({sponsor: address(0x1234), reserveAmount: 0, expiredEscrows: expiredEscrows})
        );
    }

    function testAllowsRegisteredExecutorWithMatchingCapability() public {
        MockTEEServiceRegistryForTracker teeRegistry = new MockTEEServiceRegistryForTracker();
        teeRegistry.setService(EXECUTOR, ITEECapabilityPolicy.Capability.HTTP_CALL, true);
        AsyncJobTracker implementation = new AsyncJobTracker(MOCK_ASYNC_DELIVERY, address(wallet), address(teeRegistry));
        bytes memory initData = abi.encodeWithSelector(AsyncJobTracker.initialize.selector, address(this));
        AsyncJobTracker validatingTracker =
            AsyncJobTracker(address(new ERC1967Proxy(address(implementation), initData)));

        bytes32 jobId = keccak256("valid-executor");
        bytes32[] memory expiredEscrows = new bytes32[](0);

        vm.prank(COMMITMENT);
        validatingTracker.addJobAndReserve(
            AsyncJobTracker.AddJobInput({
                exec: EXECUTOR,
                id: jobId,
                precomp: HTTP_CALL,
                input: hex"010203",
                ttl: 60,
                prevHash: bytes32(0),
                prevNum: block.number - 1,
                prevTime: block.timestamp - 1,
                caller: address(0x1234),
                commitVal: address(0x5678),
                origHash: keccak256("origin"),
                origRlp: hex"DEADBEEF",
                txOrigin: address(0x1234)
            }),
            AsyncJobTracker.ReserveConfig({sponsor: address(0x1234), reserveAmount: 0, expiredEscrows: expiredEscrows})
        );

        assertEq(validatingTracker.getJobCount(EXECUTOR), 1);
    }

    function testSettlementContextRejectsExecutorInvalidatedAfterAdmission() public {
        MockTEEServiceRegistryForTracker teeRegistry = new MockTEEServiceRegistryForTracker();
        teeRegistry.setService(EXECUTOR, ITEECapabilityPolicy.Capability.HTTP_CALL, true);
        AsyncJobTracker implementation = new AsyncJobTracker(MOCK_ASYNC_DELIVERY, address(wallet), address(teeRegistry));
        bytes memory initData = abi.encodeWithSelector(AsyncJobTracker.initialize.selector, address(this));
        AsyncJobTracker validatingTracker =
            AsyncJobTracker(address(new ERC1967Proxy(address(implementation), initData)));

        bytes32 jobId = keccak256("invalidated-settlement-executor");
        vm.prank(COMMITMENT);
        validatingTracker.addJobAndReserve(_job(jobId, address(0x1234), 60), _reserve(address(0x1234), 0, 60));

        teeRegistry.setService(EXECUTOR, ITEECapabilityPolicy.Capability.HTTP_CALL, false);

        vm.expectRevert(abi.encodeWithSelector(ITEEServiceRegistry.AttestationInvalid.selector, EXECUTOR));
        validatingTracker.getSettlementContext(jobId);
    }

    function testAllowsDkmsKeyPrecompileWithHttpExecutorCapability() public {
        MockTEEServiceRegistryForTracker teeRegistry = new MockTEEServiceRegistryForTracker();
        teeRegistry.setService(EXECUTOR, ITEECapabilityPolicy.Capability.HTTP_CALL, true);
        AsyncJobTracker implementation = new AsyncJobTracker(MOCK_ASYNC_DELIVERY, address(wallet), address(teeRegistry));
        bytes memory initData = abi.encodeWithSelector(AsyncJobTracker.initialize.selector, address(this));
        AsyncJobTracker validatingTracker =
            AsyncJobTracker(address(new ERC1967Proxy(address(implementation), initData)));

        bytes32 jobId = keccak256("dkms-http-executor");
        bytes32[] memory expiredEscrows = new bytes32[](0);

        vm.prank(COMMITMENT);
        validatingTracker.addJobAndReserve(
            AsyncJobTracker.AddJobInput({
                exec: EXECUTOR,
                id: jobId,
                precomp: DKMS_KEY,
                input: hex"010203",
                ttl: 60,
                prevHash: bytes32(0),
                prevNum: block.number - 1,
                prevTime: block.timestamp - 1,
                caller: address(0x1234),
                commitVal: address(0x5678),
                origHash: keccak256("origin"),
                origRlp: hex"DEADBEEF",
                txOrigin: address(0x1234)
            }),
            AsyncJobTracker.ReserveConfig({sponsor: address(0x1234), reserveAmount: 0, expiredEscrows: expiredEscrows})
        );

        assertEq(validatingTracker.getJobCount(EXECUTOR), 1);
    }

    function testAllowsPersistentAgentPrecompileWithHttpExecutorCapability() public {
        MockTEEServiceRegistryForTracker teeRegistry = new MockTEEServiceRegistryForTracker();
        teeRegistry.setService(EXECUTOR, ITEECapabilityPolicy.Capability.HTTP_CALL, true);
        AsyncJobTracker implementation = new AsyncJobTracker(MOCK_ASYNC_DELIVERY, address(wallet), address(teeRegistry));
        bytes memory initData = abi.encodeWithSelector(AsyncJobTracker.initialize.selector, address(this));
        AsyncJobTracker validatingTracker =
            AsyncJobTracker(address(new ERC1967Proxy(address(implementation), initData)));

        bytes32 jobId = keccak256("persistent-agent-http-executor");
        bytes32[] memory expiredEscrows = new bytes32[](0);

        vm.prank(COMMITMENT);
        validatingTracker.addJobAndReserve(
            AsyncJobTracker.AddJobInput({
                exec: EXECUTOR,
                id: jobId,
                precomp: PERSISTENT_AGENT,
                input: hex"010203",
                ttl: 60,
                prevHash: bytes32(0),
                prevNum: block.number - 1,
                prevTime: block.timestamp - 1,
                caller: address(0x1234),
                commitVal: address(0x5678),
                origHash: keccak256("origin"),
                origRlp: hex"DEADBEEF",
                txOrigin: address(0x1234)
            }),
            AsyncJobTracker.ReserveConfig({sponsor: address(0x1234), reserveAmount: 0, expiredEscrows: expiredEscrows})
        );

        assertEq(validatingTracker.getJobCount(EXECUTOR), 1);
    }

    function testRejectsDkmsKeyPrecompileWithDkmsServiceCapability() public {
        MockTEEServiceRegistryForTracker teeRegistry = new MockTEEServiceRegistryForTracker();
        teeRegistry.setService(EXECUTOR, ITEECapabilityPolicy.Capability.DKMS, true);
        AsyncJobTracker implementation = new AsyncJobTracker(MOCK_ASYNC_DELIVERY, address(wallet), address(teeRegistry));
        bytes memory initData = abi.encodeWithSelector(AsyncJobTracker.initialize.selector, address(this));
        AsyncJobTracker validatingTracker =
            AsyncJobTracker(address(new ERC1967Proxy(address(implementation), initData)));

        bytes32[] memory expiredEscrows = new bytes32[](0);

        vm.prank(COMMITMENT);
        vm.expectRevert(
            abi.encodeWithSelector(
                AsyncJobTracker.InvalidExecutorCapability.selector,
                EXECUTOR,
                DKMS_KEY,
                ITEECapabilityPolicy.Capability.DKMS
            )
        );
        validatingTracker.addJobAndReserve(
            AsyncJobTracker.AddJobInput({
                exec: EXECUTOR,
                id: keccak256("dkms-service-capability"),
                precomp: DKMS_KEY,
                input: hex"010203",
                ttl: 60,
                prevHash: bytes32(0),
                prevNum: block.number - 1,
                prevTime: block.timestamp - 1,
                caller: address(0x1234),
                commitVal: address(0x5678),
                origHash: keccak256("origin"),
                origRlp: hex"DEADBEEF",
                txOrigin: address(0x1234)
            }),
            AsyncJobTracker.ReserveConfig({sponsor: address(0x1234), reserveAmount: 0, expiredEscrows: expiredEscrows})
        );
    }

    function testRemoveJobSuccess() public {
        bytes32 jobId = keccak256(abi.encodePacked("job-rm"));
        bytes memory precompileInput = hex"010203"; // Same as _addJob uses
        _addJob(jobId, 60);
        _closeEscrow(jobId);

        // remove requires msg.sender = MOCK_ASYNC_DELIVERY
        vm.prank(MOCK_ASYNC_DELIVERY);
        bool ok = tracker.removeJob(jobId, precompileInput, true);
        assertTrue(ok);

        // mapping cleared
        assertEq(tracker.getJobCount(EXECUTOR), 0);

        // After removal, getJob should revert with "not found"
        vm.expectRevert("not found");
        tracker.getJob(jobId);
    }

    function testCleanupExpiredJobs() public {
        bytes32 job1 = keccak256(abi.encodePacked("exp-1"));
        bytes32 job2 = keccak256(abi.encodePacked("exp-2"));
        bytes32 job3 = keccak256(abi.encodePacked("exp-3"));

        _addJob(job1, 1); // expires soon (block 1 + 1 = 2)
        _addJob(job2, 100); // long ttl (block 1 + 100 = 101)
        _addJob(job3, 1); // expires soon (block 1 + 1 = 2)

        // advance block number beyond expiry of job1 and job3
        vm.roll(block.number + 2); // Now at block 3, job1/job3 expired at block 2

        uint256 cleaned = tracker.cleanupExpired(EXECUTOR, 10);
        assertEq(cleaned, 2);
        assertEq(tracker.getJobCount(EXECUTOR), 1);

        // remaining job should be job2
        (AsyncJobTracker.Job[] memory jobs,,) = tracker.getPendingJobs(EXECUTOR);
        assertEq(jobs.length, 1);
        assertEq(jobs[0].id, job2);
    }

    function testCleanupAllowsJobThroughExpiryBlock() public {
        bytes32 jobId = keccak256("expiry-boundary");
        _addJob(jobId, 1); // expires at block 2

        vm.roll(2);
        assertEq(tracker.cleanupExpired(EXECUTOR, 10), 0, "job must remain valid at expiry block");
        assertEq(tracker.getJobCount(EXECUTOR), 1);

        vm.roll(3);
        assertEq(tracker.cleanupExpired(EXECUTOR, 10), 1, "job expires after expiry block");
        assertEq(tracker.getJobCount(EXECUTOR), 0);
    }

    function testInitialEscrowDeadlineMatchesJobDeadlineForOneAndTwoPhaseJobs() public {
        wallet.setBalance(address(this), 3 ether);
        uint256 ttl = 40;
        bytes32 onePhaseId = keccak256("deadline-one-phase");
        bytes32 twoPhaseId = keccak256("deadline-two-phase");

        AsyncJobTracker.AddJobInput memory onePhase = _job(onePhaseId, address(this), ttl);
        onePhase.precomp = HTTP_CALL;
        vm.prank(COMMITMENT);
        tracker.addJobAndReserve(onePhase, _reserve(address(this), 1 ether, ttl));

        vm.prank(COMMITMENT);
        tracker.addJobAndReserve(_job(twoPhaseId, address(this), ttl), _reserve(address(this), 1 ether, ttl));

        (AsyncJobTracker.Job memory onePhaseJob,,) = tracker.getJob(onePhaseId);
        (AsyncJobTracker.Job memory twoPhaseJob,,) = tracker.getJob(twoPhaseId);
        assertEq(wallet.escrows(onePhaseId).expiryBlock, onePhaseJob.commitBlock + ttl);
        assertEq(wallet.escrows(twoPhaseId).expiryBlock, twoPhaseJob.commitBlock + ttl);
    }

    function testCleanupExpiredAtomicallyReleasesEscrow() public {
        bytes32 jobId = keccak256("cleanup-expired-funded");
        wallet.setBalance(address(this), 2 ether);
        vm.prank(COMMITMENT);
        tracker.addJobAndReserve(_job(jobId, address(this), 1), _reserve(address(this), 1 ether, 1));
        vm.roll(block.number + 2);

        assertEq(tracker.cleanupExpired(EXECUTOR, 10), 1);
        assertEq(wallet.escrows(jobId).sponsor, address(0));
        assertEq(wallet.availableBalance(address(this)), 2 ether);
        assertEq(wallet.reservedBalance(address(this)), 0);
    }

    function testCleanupBatchAtomicallyReleasesEscrow() public {
        bytes32 jobId = keccak256("cleanup-batch-funded");
        wallet.setBalance(address(this), 2 ether);
        vm.prank(COMMITMENT);
        tracker.addJobAndReserve(_job(jobId, address(this), 1), _reserve(address(this), 1 ether, 1));
        vm.roll(block.number + 2);

        (uint256 removed,) = tracker.cleanupBatch(10);
        assertEq(removed, 1);
        assertEq(wallet.escrows(jobId).sponsor, address(0));
        assertEq(wallet.availableBalance(address(this)), 2 ether);
        assertEq(wallet.reservedBalance(address(this)), 0);
    }

    function testOpportunisticCleanupAtomicallyReleasesEscrow() public {
        bytes32 expiredId = keccak256("opportunistic-expired");
        bytes32 triggerId = keccak256("opportunistic-trigger");
        wallet.setBalance(address(this), 2 ether);
        vm.prank(COMMITMENT);
        tracker.addJobAndReserve(_job(expiredId, address(this), 1), _reserve(address(this), 1 ether, 1));
        vm.roll(block.number + tracker.CLEANUP_INTERVAL() + 1);

        vm.prank(COMMITMENT);
        tracker.addJobAndReserve(_job(triggerId, address(this), 100), _reserve(address(this), 0, 100));

        assertEq(wallet.escrows(expiredId).sponsor, address(0));
        assertEq(wallet.availableBalance(address(this)), 2 ether);
        assertEq(wallet.reservedBalance(address(this)), 0);
        assertEq(tracker.getJobCount(EXECUTOR), 1);
    }

    function testNormalSameIdRecommitReleasesExpiredEscrow() public {
        bytes32 jobId = keccak256("normal-same-id");
        wallet.setBalance(address(this), 2 ether);
        vm.prank(COMMITMENT);
        tracker.addJobAndReserve(_job(jobId, address(this), 1), _reserve(address(this), 1 ether, 1));
        vm.roll(block.number + 2);

        vm.prank(COMMITMENT);
        tracker.addJobAndReserve(_job(jobId, address(this), 20), _reserve(address(this), 1.5 ether, 20));

        assertEq(tracker.getJobCount(EXECUTOR), 1);
        assertEq(wallet.escrows(jobId).reserved, 1.5 ether);
        assertEq(wallet.availableBalance(address(this)), 0.5 ether);
        assertEq(wallet.reservedBalance(address(this)), 1.5 ether);
    }

    function testScheduledSameIdRecommitDoesNotEvict() public {
        bytes32 origin = keccak256("scheduled-same-id");
        wallet.setBalance(address(this), 4 ether);
        uint256 callId = _scheduleCallWithOrigin(origin);
        bytes32 jobId = _scheduledJobId(origin, callId, 0);
        AsyncJobTracker.ScheduledObligationRef memory obligation =
            AsyncJobTracker.ScheduledObligationRef({callId: callId, executionIndex: 0, scheduledOriginHash: jobId});

        vm.prank(COMMITMENT);
        tracker.addScheduledJobAndReserve(
            _job(jobId, address(this), 1), _reserve(address(this), 1 ether, 1), obligation
        );
        vm.roll(block.number + 2);

        vm.prank(COMMITMENT);
        tracker.addScheduledJobAndReserve(
            _job(jobId, address(this), 20), _reserve(address(this), 1.5 ether, 20), obligation
        );

        assertEq(tracker.getJobCount(EXECUTOR), 1);
        assertEq(wallet.escrows(jobId).reserved, 1.5 ether);
        assertEq(scheduler.scheduledAsyncCleanupReason(callId, 0), bytes32(0));
        assertEq(uint8(scheduler.getCallState(callId)), uint8(CallState.SCHEDULED));
    }

    function testCleanupContinuesWhenEscrowWasAlreadyPermissionlesslyExpired() public {
        bytes32 jobId = keccak256("already-expired-wallet");
        wallet.setBalance(address(this), 1 ether);
        vm.prank(COMMITMENT);
        tracker.addJobAndReserve(_job(jobId, address(this), 1), _reserve(address(this), 1 ether, 1));
        vm.roll(block.number + 2);
        wallet.expire(jobId);

        assertEq(tracker.cleanupExpired(EXECUTOR, 10), 1);
        assertEq(tracker.getJobCount(EXECUTOR), 0);
    }

    function testCleanupRevertsWhenTrackerExpiredButEscrowStillLive() public {
        bytes32 jobId = keccak256("deadline-divergence");
        wallet.setBalance(address(this), 1 ether);
        vm.prank(COMMITMENT);
        tracker.addJobAndReserve(_job(jobId, address(this), 1), _reserve(address(this), 1 ether, 1));
        wallet.settle(jobId, new IRitualWallet.Payment[](0), 0, uint64(block.number + 100), false);
        vm.roll(block.number + 2);

        vm.expectRevert(IRitualWallet.EscrowNotExpired.selector);
        tracker.cleanupExpired(EXECUTOR, 10);
        assertEq(tracker.getJobCount(EXECUTOR), 1);
        assertEq(wallet.escrows(jobId).sponsor, address(this));
    }

    function testRemoveJobWithLargePayload() public {
        // 2KB payload
        bytes memory payload = new bytes(2048);
        // Fill a few bytes to avoid optimizer elision
        payload[0] = 0xAA;
        payload[2047] = 0xBB;

        bytes32 jobId = keccak256(abi.encodePacked("job-large"));
        _addJobWithInput(jobId, 60, payload);
        _closeEscrow(jobId);

        vm.prank(MOCK_ASYNC_DELIVERY);
        bool ok = tracker.removeJob(jobId, payload, true);
        assertTrue(ok);
        assertEq(tracker.getJobCount(EXECUTOR), 0);
        // Ensure job is gone
    }

    function testRemoveMiddleJobPreservesParallelIndexes() public {
        bytes memory precompileInput = hex"010203";
        bytes32 job1 = keccak256("parallel-index-1");
        bytes32 job2 = keccak256("parallel-index-2");
        bytes32 job3 = keccak256("parallel-index-3");

        _addJob(job1, 60);
        _addJob(job2, 60);
        _addJob(job3, 60);

        _closeEscrow(job2);
        vm.prank(MOCK_ASYNC_DELIVERY);
        assertTrue(tracker.removeJob(job2, precompileInput, true));

        (bytes32[] memory jobIds,,) = tracker.getPendingJobHashes(EXECUTOR);
        assertEq(jobIds.length, 2);
        assertEq(tracker.getJobCount(EXECUTOR), 2);
        assertEq(tracker.getTxOriginJobCount(address(0x1234)), 2);

        bool sawJob1;
        bool sawJob3;
        for (uint256 i; i < jobIds.length; i++) {
            sawJob1 = sawJob1 || jobIds[i] == job1;
            sawJob3 = sawJob3 || jobIds[i] == job3;
        }
        assertTrue(sawJob1, "job1 missing after middle removal");
        assertTrue(sawJob3, "job3 missing after middle removal");

        _closeEscrow(job1);
        vm.prank(MOCK_ASYNC_DELIVERY);
        assertTrue(tracker.removeJob(job1, precompileInput, true));
        _closeEscrow(job3);
        vm.prank(MOCK_ASYNC_DELIVERY);
        assertTrue(tracker.removeJob(job3, precompileInput, true));

        assertEq(tracker.getJobCount(EXECUTOR), 0);
        assertEq(tracker.getTxOriginJobCount(address(0x1234)), 0);
    }

    function testCleanupExpiredJobsLargePayload() public {
        // Two large payload jobs that expire quickly
        bytes32 job1 = keccak256(abi.encodePacked("exp-large-1"));
        bytes32 job2 = keccak256(abi.encodePacked("exp-large-2"));
        bytes memory payload = new bytes(3072); // 3KB
        payload[0] = 0x11;
        payload[3071] = 0x22;

        _addJobWithInput(job1, 1, payload);
        _addJobWithInput(job2, 1, payload);

        // advance block number beyond expiry
        vm.roll(block.number + 2);
        uint256 cleaned = tracker.cleanupExpired(EXECUTOR, 10);
        assertEq(cleaned, 2);
        assertEq(tracker.getJobCount(EXECUTOR), 0);
        // Jobs should be deleted
        vm.expectRevert("not found");
        tracker.getJob(job1);
        vm.expectRevert("not found");
        tracker.getJob(job2);
    }

    //     function testGetExpiringJobs() public {
    //         bytes32 job1 = keccak256(abi.encodePacked("near-1"));
    //         bytes32 job2 = keccak256(abi.encodePacked("near-2"));
    //         bytes32 job3 = keccak256(abi.encodePacked("far"));
    //
    //         _addJob(job1, 3);
    //         _addJob(job2, 4);
    //         _addJob(job3, 100);
    //
    //         // timeBuffer 5s from now -> job1 and job2 should be expiring
    //         bytes32[] memory expiring = tracker.getExpiringJobs(EXECUTOR, 5);
    //         assertEq(expiring.length, 2);
    //         // order not guaranteed; check membership
    //         bool seen1;
    //         bool seen2;
    //         for (uint256 i; i < expiring.length; ++i) {
    //             if (expiring[i] == job1) {
    //                 seen1 = true;
    //             }
    //             if (expiring[i] == job2) {
    //                 seen2 = true;
    //             }
    //         }
    //         assertTrue(seen1 && seen2);
    //     }

    function _zkInput(uint256 maxProofBlock) internal pure returns (bytes memory precompileInput) {
        // Field 8 = max_proof_block. Build minimal ABI: 9 fields * 32 bytes = 288 bytes.
        precompileInput = new bytes(288);
        assembly {
            // Store max_proof_block at offset 256 (field 8)
            mstore(add(add(precompileInput, 32), 256), maxProofBlock)
        }
    }

    /// @dev Add a ZK job (0x0806) with max_proof_block at field 8
    function _addZKJob(bytes32 jobId, uint256 ttl, uint256 maxProofBlock) internal {
        bytes memory precompileInput = _zkInput(maxProofBlock);

        vm.prank(COMMITMENT);
        _addJobCompat(
            EXECUTOR,
            jobId,
            address(0x0806),
            precompileInput,
            ttl,
            bytes32(0),
            block.number - 1,
            block.timestamp - 1,
            address(0x1234),
            address(0x5678),
            keccak256("origin"),
            hex"DEADBEEF",
            address(0x1234)
        );
    }

    /// @dev Add a Sovereign Agent job (0x080C) with max_poll_block at field 8
    function _addSovereignJob(bytes32 jobId, uint256 ttl, uint256 maxPollBlock) internal {
        // Field 8 = max_poll_block after the canonical 7-field ExecutorRequest base.
        bytes memory precompileInput = new bytes(288);
        assembly {
            mstore(add(add(precompileInput, 32), 256), maxPollBlock)
        }

        vm.prank(COMMITMENT);
        _addJobCompat(
            EXECUTOR,
            jobId,
            address(0x080C),
            precompileInput,
            ttl,
            bytes32(0),
            block.number - 1,
            block.timestamp - 1,
            address(0x1234),
            address(0x5678),
            keccak256("origin"),
            hex"DEADBEEF",
            address(0x1234)
        );
    }

    function _phase2Input(uint256 deadlineField, uint256 offset) internal pure returns (bytes memory input) {
        input = new bytes((deadlineField + 1) * 32);
        assembly {
            mstore(add(add(input, 32), mul(deadlineField, 32)), offset)
        }
    }

    function _addTwoPhaseJob(bytes32 jobId, address precompile, bytes memory precompileInput, uint256 ttl) internal {
        vm.prank(COMMITMENT);
        _addJobCompat(
            EXECUTOR,
            jobId,
            precompile,
            precompileInput,
            ttl,
            bytes32(0),
            block.number - 1,
            block.timestamp - 1,
            address(0x1234),
            address(0x5678),
            keccak256(abi.encodePacked("origin", jobId)),
            hex"DEADBEEF",
            address(0x1234)
        );
    }

    function _assertTwoPhaseDeadlineLifecycle(address precompile, uint256 deadlineField, uint256 offset) internal {
        bytes32 jobId = keccak256(abi.encodePacked("phase2-lifecycle", precompile, block.number));
        uint256 ttl = offset + 100;
        bytes memory precompileInput = _phase2Input(deadlineField, offset);

        _addTwoPhaseJob(jobId, precompile, precompileInput, ttl);
        assertTrue(tracker.isLongRunning(jobId), "precompile must be classified as long-running");
        assertEq(tracker.computePhase2Deadline(jobId, precompileInput), uint64(block.number + offset));

        uint64 expectedPhase2Deadline = uint64(block.number + offset);
        wallet.settle(jobId, new IRitualWallet.Payment[](0), 0, expectedPhase2Deadline, false);
        vm.prank(MOCK_ASYNC_DELIVERY);
        uint64 phase2Deadline = tracker.markPhase1Settled(jobId, precompileInput);
        assertEq(phase2Deadline, uint64(block.number + offset));

        vm.roll(uint256(phase2Deadline) + 1);
        uint256 cleaned = tracker.cleanupExpired(EXECUTOR, 10);
        assertEq(cleaned, 1, "job must clean up after its Phase 2 deadline");
        assertEq(tracker.getJobCount(EXECUTOR), 0);

        vm.roll(block.number + 1);
    }

    function testAllTwoPhasePrecompilesUseSettlementRelativePhase2Deadline() public {
        _assertTwoPhaseDeadlineLifecycle(LONG_RUNNING_HTTP, 8, 40);
        _assertTwoPhaseDeadlineLifecycle(ZK_TWO_PHASE, 8, 41);
        _assertTwoPhaseDeadlineLifecycle(FHE, 12, 42);
        _assertTwoPhaseDeadlineLifecycle(SOVEREIGN, 8, 43);
        _assertTwoPhaseDeadlineLifecycle(IMAGE, 8, 44);
        _assertTwoPhaseDeadlineLifecycle(AUDIO, 8, 45);
        _assertTwoPhaseDeadlineLifecycle(VIDEO, 8, 46);
        _assertTwoPhaseDeadlineLifecycle(PERSISTENT, 7, 47);
    }

    function testMarkPhase1SettledRejectsOversizedPhase2Offset() public {
        bytes32 jobId = keccak256("oversized-phase2-offset");
        bytes memory precompileInput = _phase2Input(8, tracker.MAX_PHASE2_DEADLINE_OFFSET() + 1);
        _addTwoPhaseJob(jobId, ZK_TWO_PHASE, precompileInput, 100);

        vm.expectRevert("phase2 offset too large");
        vm.prank(MOCK_ASYNC_DELIVERY);
        tracker.markPhase1Settled(jobId, precompileInput);
    }

    function testMarkPhase1SettledRejectsMissingPhase2Deadline() public {
        bytes32 jobId = keccak256("missing-phase2-deadline");
        bytes memory precompileInput = new bytes(8 * 32);
        _addTwoPhaseJob(jobId, ZK_TWO_PHASE, precompileInput, 100);

        vm.expectRevert("phase2 deadline missing");
        vm.prank(MOCK_ASYNC_DELIVERY);
        tracker.markPhase1Settled(jobId, precompileInput);
    }

    function testMarkPhase1SettledMovesJobToPhase2Bucket() public {
        bytes32 jobId = keccak256("zk-phase2");
        uint256 initialBlock = block.number;
        uint256 ttl = 30;
        uint256 maxProofBlock = 200; // Phase 2 offset from settlement block

        bytes memory precompileInput = _zkInput(maxProofBlock);

        _addZKJob(jobId, ttl, maxProofBlock);
        assertEq(tracker.getJobCount(EXECUTOR), 1);

        // Mark Phase 1 settled - this should move job to settlement block + offset
        wallet.settle(jobId, new IRitualWallet.Payment[](0), 0, uint64(block.number + maxProofBlock), false);
        vm.prank(MOCK_ASYNC_DELIVERY);
        tracker.markPhase1Settled(jobId, precompileInput);
        uint256 phase2Deadline = block.number + maxProofBlock;

        // Advance past original TTL (30) but before Phase 2 deadline
        vm.roll(initialBlock + 50);

        // Job should NOT be cleaned up - it's now in block 200 bucket
        uint256 cleaned = tracker.cleanupExpired(EXECUTOR, 10);
        assertEq(cleaned, 0);
        assertEq(tracker.getJobCount(EXECUTOR), 1);

        // Advance past Phase 2 deadline
        vm.roll(phase2Deadline + 1);

        // NOW cleanup should remove it
        cleaned = tracker.cleanupExpired(EXECUTOR, 10);
        assertEq(cleaned, 1);
        assertEq(tracker.getJobCount(EXECUTOR), 0);
    }

    function testMarkPhase1SettledShortensJobToEarlierPhase2Deadline() public {
        bytes32 jobId = keccak256("zk-short-phase2");
        uint256 initialBlock = block.number;
        uint256 ttl = 100;
        uint256 maxProofBlock = 5;

        bytes memory precompileInput = new bytes(288);
        assembly {
            mstore(add(add(precompileInput, 32), 256), maxProofBlock)
        }

        _addZKJob(jobId, ttl, maxProofBlock);

        wallet.settle(jobId, new IRitualWallet.Payment[](0), 0, uint64(block.number + maxProofBlock), false);
        vm.prank(MOCK_ASYNC_DELIVERY);
        tracker.markPhase1Settled(jobId, precompileInput);
        uint256 phase2Deadline = block.number + maxProofBlock;

        vm.roll(phase2Deadline + 1);
        uint256 cleaned = tracker.cleanupExpired(EXECUTOR, 10);
        assertEq(cleaned, 1);
        assertEq(tracker.getJobCount(EXECUTOR), 0);

        assertLt(phase2Deadline, initialBlock + ttl);
    }

    function testMarkSovereignPhase1SettledReadsMaxPollBlockFromField8() public {
        bytes32 jobId = keccak256("sovereign-phase2");
        uint256 initialBlock = block.number;
        uint256 ttl = 30;
        uint256 maxPollBlock = 200;

        bytes memory precompileInput = new bytes(288);
        assembly {
            mstore(add(add(precompileInput, 32), 256), maxPollBlock)
        }

        _addSovereignJob(jobId, ttl, maxPollBlock);

        wallet.settle(jobId, new IRitualWallet.Payment[](0), 0, uint64(block.number + maxPollBlock), false);
        vm.prank(MOCK_ASYNC_DELIVERY);
        tracker.markPhase1Settled(jobId, precompileInput);
        uint256 phase2Deadline = block.number + maxPollBlock;

        vm.roll(initialBlock + 50);
        uint256 cleaned = tracker.cleanupExpired(EXECUTOR, 10);
        assertEq(cleaned, 0);
        assertEq(tracker.getJobCount(EXECUTOR), 1);

        vm.roll(phase2Deadline + 1);
        cleaned = tracker.cleanupExpired(EXECUTOR, 10);
        assertEq(cleaned, 1);
        assertEq(tracker.getJobCount(EXECUTOR), 0);
    }

    function testMarkDeliveredRejectsAbsentJob() public {
        bytes32 jobId = keccak256("deliver-absent-job");
        bytes memory precompileInput = _zkInput(200);

        vm.expectRevert("job not found");
        vm.prank(MOCK_ASYNC_DELIVERY);
        tracker.markDelivered(jobId, precompileInput, true);
    }

    function testMarkDeliveredRejectsNotPhaseOneSettled() public {
        bytes32 jobId = keccak256("deliver-not-phase-one");
        bytes memory precompileInput = _zkInput(200);
        _addZKJob(jobId, 60, 200);

        vm.expectRevert("phase1 not settled");
        vm.prank(MOCK_ASYNC_DELIVERY);
        tracker.markDelivered(jobId, precompileInput, true);
    }

    function testMarkDeliveredRejectsInputMismatch() public {
        bytes32 jobId = keccak256("deliver-input-mismatch");
        bytes memory precompileInput = _zkInput(200);
        _addZKJob(jobId, 60, 200);

        vm.prank(MOCK_ASYNC_DELIVERY);
        tracker.markPhase1Settled(jobId, precompileInput);

        vm.expectRevert("input hash mismatch");
        vm.prank(MOCK_ASYNC_DELIVERY);
        tracker.markDelivered(jobId, _zkInput(201), true);
    }

    function testMarkDeliveredRemovesJobExactlyOnce() public {
        bytes32 jobId = keccak256("deliver-once");
        bytes memory precompileInput = _zkInput(200);
        _addZKJob(jobId, 60, 200);

        vm.prank(MOCK_ASYNC_DELIVERY);
        tracker.markPhase1Settled(jobId, precompileInput);

        _closeEscrow(jobId);
        vm.prank(MOCK_ASYNC_DELIVERY);
        tracker.markDelivered(jobId, precompileInput, true);

        assertEq(tracker.getJobCount(EXECUTOR), 0);
        vm.expectRevert("not found");
        tracker.getJob(jobId);

        vm.expectRevert("job not found");
        vm.prank(MOCK_ASYNC_DELIVERY);
        tracker.markDelivered(jobId, precompileInput, true);
    }
}

/// @dev Tests for delivery fee u128 validation across all 5 async ABI families.
contract AsyncJobTrackerFeeValidationTest is Test {
    AsyncJobTracker internal tracker;
    MockRitualWallet internal wallet;

    address internal constant COMMITMENT = 0x000000000000000000000000000000000000Fa8e;
    address internal constant MOCK_ASYNC_DELIVERY = 0x000000000000000000000000000000000000fA9E;
    address internal constant EXECUTOR = address(0xBEEF);

    // Precompile addresses (must match AsyncJobTracker constants)
    address internal constant ZK = 0x0000000000000000000000000000000000000806;
    address internal constant SOVEREIGN = 0x000000000000000000000000000000000000080C;
    address internal constant PERSISTENT = 0x0000000000000000000000000000000000000820;
    address internal constant FHE = 0x0000000000000000000000000000000000000807;
    address internal constant HTTP = 0x0000000000000000000000000000000000000805;
    address internal constant DKMS = 0x000000000000000000000000000000000000081B;

    // Per-family byte offset of max_fee_per_gas (must match AsyncJobTracker constants)
    uint256 internal constant ZK_FEE = 12 * 32;
    uint256 internal constant SOVEREIGN_FEE = 13 * 32;
    uint256 internal constant PERSISTENT_FEE = 11 * 32;
    uint256 internal constant FHE_FEE = 16 * 32;
    uint256 internal constant HTTP_FEE = 13 * 32;

    uint256 internal constant VALID_FEE = 20 gwei;
    uint256 internal constant VALID_GAS = 100_000;
    uint256 internal constant OVERFLOW_FEE = uint256(type(uint128).max) + 1;
    uint256 internal constant OVERFLOW_GAS = uint256(type(uint64).max) + 1;

    function setUp() public {
        wallet = new MockRitualWallet(address(0));
        AsyncJobTracker implementation = new AsyncJobTracker(MOCK_ASYNC_DELIVERY, address(wallet), address(0));
        bytes memory initData = abi.encodeWithSelector(AsyncJobTracker.initialize.selector, address(this));
        tracker = AsyncJobTracker(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _addJobCompat(
        address exec,
        bytes32 id,
        address precomp,
        bytes memory input,
        uint256 ttl,
        bytes32 prevHash,
        uint256 prevNum,
        uint256 prevTime,
        address sender,
        address commitVal,
        bytes32 origHash,
        bytes memory origRlp,
        address txOrigin
    ) internal {
        bytes32[] memory expiredEscrows = new bytes32[](0);
        tracker.addJobAndReserve(
            AsyncJobTracker.AddJobInput({
                exec: exec,
                id: id,
                precomp: precomp,
                input: input,
                ttl: ttl,
                prevHash: prevHash,
                prevNum: prevNum,
                prevTime: prevTime,
                caller: sender,
                commitVal: commitVal,
                origHash: origHash,
                origRlp: origRlp,
                txOrigin: txOrigin
            }),
            AsyncJobTracker.ReserveConfig({sponsor: sender, reserveAmount: 0, expiredEscrows: expiredEscrows})
        );
    }

    function _addJobCompat(
        address exec,
        bytes32 id,
        address precomp,
        bytes memory input,
        uint256 ttl,
        bytes32 prevHash,
        uint256 prevNum,
        uint256 prevTime,
        address sender,
        address commitVal,
        bytes32 origHash,
        bytes memory origRlp
    ) internal {
        _addJobCompat(
            exec, id, precomp, input, ttl, prevHash, prevNum, prevTime, sender, commitVal, origHash, origRlp, sender
        );
    }

    /// @dev Build a precompile input with delivery fields at the given fee offset.
    ///      gas_limit is at feeOffset - 32, max_fee at feeOffset, max_priority at feeOffset + 32.
    function _buildInput(uint256 feeOffset, uint256 maxFee, uint256 maxPriorityFee)
        internal
        pure
        returns (bytes memory)
    {
        return _buildInputFull(feeOffset, VALID_GAS, maxFee, maxPriorityFee);
    }

    function _buildInputFull(uint256 feeOffset, uint256 gasLimit, uint256 maxFee, uint256 maxPriorityFee)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory input = new bytes(feeOffset + 64);
        assembly {
            let dataStart := add(input, 32)
            mstore(add(dataStart, sub(feeOffset, 32)), gasLimit)
            mstore(add(dataStart, feeOffset), maxFee)
            mstore(add(dataStart, add(feeOffset, 32)), maxPriorityFee)
        }
        return input;
    }

    function _buildHttpInputWithSelectorWord(bytes4 selector) internal pure returns (bytes memory) {
        bytes memory input = _buildInput(HTTP_FEE, VALID_FEE, VALID_FEE);
        assembly {
            let dataStart := add(input, 32)
            mstore(add(dataStart, sub(HTTP_FEE, 64)), selector)
        }
        return input;
    }

    function _addJobWith(address precompile, bytes memory input) internal {
        vm.prank(COMMITMENT);
        _addJobCompat(
            EXECUTOR,
            keccak256(abi.encodePacked(block.number, precompile, input.length)),
            precompile,
            input,
            60,
            bytes32(0),
            block.number - 1,
            block.timestamp - 1,
            address(0x1234),
            address(0x5678),
            keccak256("origin"),
            hex"DEADBEEF",
            address(0x1234)
        );
    }

    // =====================================================================
    //  ZK Two-Phase (0x0806) — max_fee at field 12
    // =====================================================================

    function testZkValidFees() public {
        _addJobWith(ZK, _buildInput(ZK_FEE, VALID_FEE, VALID_FEE));
        assertEq(tracker.getJobCount(EXECUTOR), 1);
    }

    function testZkRejectsOverflowMaxFee() public {
        vm.expectRevert("maxFeePerGas exceeds u128");
        _addJobWith(ZK, _buildInput(ZK_FEE, OVERFLOW_FEE, VALID_FEE));
    }

    function testZkRejectsOverflowMaxPriorityFee() public {
        vm.expectRevert("maxPriorityFeePerGas exceeds u128");
        _addJobWith(ZK, _buildInput(ZK_FEE, VALID_FEE, OVERFLOW_FEE));
    }

    // =====================================================================
    //  Sovereign Agent (0x080C) — max_fee at field 13
    // =====================================================================

    function testSovereignValidFees() public {
        _addJobWith(SOVEREIGN, _buildInput(SOVEREIGN_FEE, VALID_FEE, VALID_FEE));
        assertEq(tracker.getJobCount(EXECUTOR), 1);
    }

    function testSovereignRejectsOverflowMaxFee() public {
        vm.expectRevert("maxFeePerGas exceeds u128");
        _addJobWith(SOVEREIGN, _buildInput(SOVEREIGN_FEE, OVERFLOW_FEE, VALID_FEE));
    }

    function testSovereignRejectsOverflowMaxPriorityFee() public {
        vm.expectRevert("maxPriorityFeePerGas exceeds u128");
        _addJobWith(SOVEREIGN, _buildInput(SOVEREIGN_FEE, VALID_FEE, OVERFLOW_FEE));
    }

    // =====================================================================
    //  Persistent Agent (0x0820) — max_fee at field 11
    // =====================================================================

    function testPersistentValidFees() public {
        _addJobWith(PERSISTENT, _buildInput(PERSISTENT_FEE, VALID_FEE, VALID_FEE));
        assertEq(tracker.getJobCount(EXECUTOR), 1);
    }

    function testPersistentRejectsOverflowMaxFee() public {
        vm.expectRevert("maxFeePerGas exceeds u128");
        _addJobWith(PERSISTENT, _buildInput(PERSISTENT_FEE, OVERFLOW_FEE, VALID_FEE));
    }

    function testPersistentRejectsOverflowMaxPriorityFee() public {
        vm.expectRevert("maxPriorityFeePerGas exceeds u128");
        _addJobWith(PERSISTENT, _buildInput(PERSISTENT_FEE, VALID_FEE, OVERFLOW_FEE));
    }

    // =====================================================================
    //  FHE (0x0807) — max_fee at field 16
    // =====================================================================

    function testFheValidFees() public {
        _addJobWith(FHE, _buildInput(FHE_FEE, VALID_FEE, VALID_FEE));
        assertEq(tracker.getJobCount(EXECUTOR), 1);
    }

    function testFheRejectsOverflowMaxFee() public {
        vm.expectRevert("maxFeePerGas exceeds u128");
        _addJobWith(FHE, _buildInput(FHE_FEE, OVERFLOW_FEE, VALID_FEE));
    }

    function testFheRejectsOverflowMaxPriorityFee() public {
        vm.expectRevert("maxPriorityFeePerGas exceeds u128");
        _addJobWith(FHE, _buildInput(FHE_FEE, VALID_FEE, OVERFLOW_FEE));
    }

    // =====================================================================
    //  HTTP / Agent / Image / Audio / Video (0x0805) — max_fee at field 13
    // =====================================================================

    function testHttpFamilyValidFees() public {
        _addJobWith(HTTP, _buildInput(HTTP_FEE, VALID_FEE, VALID_FEE));
        assertEq(tracker.getJobCount(EXECUTOR), 1);
    }

    function testHttpFamilyValidFeesWithNonzeroSelectorWord() public {
        _addJobWith(HTTP, _buildHttpInputWithSelectorWord(bytes4(0x6dc9dbef)));
        assertEq(tracker.getJobCount(EXECUTOR), 1);
    }

    function testHttpFamilyRejectsOverflowMaxFee() public {
        vm.expectRevert("maxFeePerGas exceeds u128");
        _addJobWith(HTTP, _buildInput(HTTP_FEE, OVERFLOW_FEE, VALID_FEE));
    }

    function testHttpFamilyRejectsOverflowMaxPriorityFee() public {
        vm.expectRevert("maxPriorityFeePerGas exceeds u128");
        _addJobWith(HTTP, _buildInput(HTTP_FEE, VALID_FEE, OVERFLOW_FEE));
    }

    // =====================================================================
    //  delivery_gas_limit overflow (u64 in reth) — one per family
    // =====================================================================

    function testZkRejectsOverflowGasLimit() public {
        vm.expectRevert("delivery gasLimit exceeds u64");
        _addJobWith(ZK, _buildInputFull(ZK_FEE, OVERFLOW_GAS, VALID_FEE, VALID_FEE));
    }

    function testSovereignRejectsOverflowGasLimit() public {
        vm.expectRevert("delivery gasLimit exceeds u64");
        _addJobWith(SOVEREIGN, _buildInputFull(SOVEREIGN_FEE, OVERFLOW_GAS, VALID_FEE, VALID_FEE));
    }

    function testPersistentRejectsOverflowGasLimit() public {
        vm.expectRevert("delivery gasLimit exceeds u64");
        _addJobWith(PERSISTENT, _buildInputFull(PERSISTENT_FEE, OVERFLOW_GAS, VALID_FEE, VALID_FEE));
    }

    function testFheRejectsOverflowGasLimit() public {
        vm.expectRevert("delivery gasLimit exceeds u64");
        _addJobWith(FHE, _buildInputFull(FHE_FEE, OVERFLOW_GAS, VALID_FEE, VALID_FEE));
    }

    function testHttpFamilyRejectsOverflowGasLimit() public {
        vm.expectRevert("delivery gasLimit exceeds u64");
        _addJobWith(HTTP, _buildInputFull(HTTP_FEE, OVERFLOW_GAS, VALID_FEE, VALID_FEE));
    }

    function testGasLimitExactlyU64MaxPasses() public {
        uint256 maxU64 = type(uint64).max;
        _addJobWith(ZK, _buildInputFull(ZK_FEE, maxU64, VALID_FEE, VALID_FEE));
        assertEq(tracker.getJobCount(EXECUTOR), 1);
    }

    // =====================================================================
    //  DKMS (0x081B) — single-phase, no delivery fee fields, should pass
    // =====================================================================

    function testDkmsRegistersNormally() public {
        _addJobWith(DKMS, hex"010203");
        assertEq(tracker.getJobCount(EXECUTOR), 1);
    }

    // =====================================================================
    //  Unknown precompile — must revert
    // =====================================================================

    function testUnknownPrecompileReverts() public {
        address unknown = address(0x9999);
        vm.expectRevert("unknown precompile");
        _addJobWith(unknown, hex"010203");
    }

    // =====================================================================
    //  Boundary: exactly type(uint128).max should pass
    // =====================================================================

    function testMaxU128ExactlyPasses() public {
        uint256 maxU128 = type(uint128).max;
        _addJobWith(ZK, _buildInput(ZK_FEE, maxU128, maxU128));
        assertEq(tracker.getJobCount(EXECUTOR), 1);
    }
}
