// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Scheduler, Call, CallState} from "../src/scheduler/Scheduler.sol";
import {MockRitualWallet} from "./MockRitualWallet.sol";

contract TestableScheduler is Scheduler {
    constructor(address ritualWallet, uint32 maxTTL) Scheduler(ritualWallet, maxTTL) {}

    function setCallStateForTest(uint256 callId, CallState state) external {
        Call storage call = _getCall(callId);
        call.state = state;
    }
}

contract SchedulerForceCancelTest is Test {
    Scheduler public scheduler;
    MockRitualWallet public wallet;
    address public attacker = address(0xBEEF);

    function setUp() public {
        wallet = new MockRitualWallet(address(0));

        Scheduler implementation = new Scheduler(address(wallet), 30);
        bytes memory initData = abi.encodeCall(Scheduler.initialize, (address(this)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        scheduler = Scheduler(payable(address(proxy)));

        wallet.setScheduler(address(scheduler));
        wallet.setTransferFullScheduledFee(true);
        wallet.setBalance(address(this), 10 ether);
        vm.deal(address(wallet), 10 ether);
    }

    function _scheduleCall() internal returns (uint256) {
        bytes memory payload = hex"01020304";
        uint32 gasLimit = 100_000;
        uint32 numCalls = 2;
        uint32 frequency = 10;
        uint32 ttl = 5;
        uint256 maxFeePerGas = 20 gwei;
        uint256 maxPriorityFeePerGas = 2 gwei;
        uint256 value = 0;

        return
            scheduler.schedule(payload, gasLimit, numCalls, frequency, ttl, maxFeePerGas, maxPriorityFeePerGas, value);
    }

    function testForceCancelByOwnerWipesCall() public {
        uint256 callId = _scheduleCall();

        assertEq(uint8(scheduler.getCallState(callId)), uint8(CallState.SCHEDULED));
        scheduler.forceCancel(callId);

        vm.expectRevert(Scheduler.CallNotFound.selector);
        scheduler.getCallState(callId);

        assertEq(scheduler.callToSlot(callId), 0, "callToSlot not cleaned");
        assertEq(scheduler.originHash(callId), bytes32(0), "originHash not cleaned");
        assertEq(scheduler.callPredicates(callId), address(0), "callPredicates not cleaned");
    }

    function testForceCancelCanRecoverStaleExecutingCall() public {
        TestableScheduler implementation = new TestableScheduler(address(wallet), 30);
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(implementation), abi.encodeCall(Scheduler.initialize, (address(this))));
        TestableScheduler recoveryScheduler = TestableScheduler(payable(address(proxy)));
        wallet.setScheduler(address(recoveryScheduler));
        wallet.setBalance(address(this), 10 ether);

        bytes memory payload = hex"01020304";
        uint256 callId = recoveryScheduler.schedule(payload, 100_000, 2, 10, 5, 20 gwei, 2 gwei, 0);

        recoveryScheduler.setCallStateForTest(callId, CallState.EXECUTING);
        assertEq(uint8(recoveryScheduler.getCallState(callId)), uint8(CallState.EXECUTING));

        recoveryScheduler.forceCancel(callId);

        vm.expectRevert(Scheduler.CallNotFound.selector);
        recoveryScheduler.getCallState(callId);

        assertEq(recoveryScheduler.callToSlot(callId), 0, "callToSlot not cleaned");
        assertEq(recoveryScheduler.originHash(callId), bytes32(0), "originHash not cleaned");
        assertEq(recoveryScheduler.callPredicates(callId), address(0), "callPredicates not cleaned");

        wallet.setScheduler(address(scheduler));
    }

    function testForceCancelNonOwnerReverts() public {
        uint256 callId = _scheduleCall();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        scheduler.forceCancel(callId);
    }
}
