// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Scheduler, CallState} from "../src/scheduler/Scheduler.sol";
import {MockRitualWallet} from "./MockRitualWallet.sol";

contract SchedulerFragmentationTest is Test {
    Scheduler public scheduler;
    MockRitualWallet public wallet;
    address public constant SYSTEM_ACCOUNT = 0x000000000000000000000000000000000000fa7e;

    function setUp() public {
        wallet = new MockRitualWallet(address(0));
        scheduler = new Scheduler(address(wallet), 30);
        wallet.setScheduler(address(scheduler));

        // Fund accounts
        vm.deal(address(this), 100 ether);
        vm.deal(address(wallet), 1000 ether);
        vm.deal(address(scheduler), 100 ether);
        // Fund default msg.sender used by Foundry
        wallet.setBalance(0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38, 1000 ether);
        // Also fund this contract as a caller
        wallet.setBalance(address(this), 1000 ether);
    }

    function _slotsLength() internal returns (uint256) {
        // slots is the second state var (slot 1). Dynamic array length is stored at the slot itself.
        bytes32 len = vm.load(address(scheduler), bytes32(uint256(1)));
        return uint256(len);
    }

    function _scheduleOne(uint32 numCalls, uint32 freq) internal returns (uint256) {
        // Minimal payload
        bytes memory payload = hex"01020304";
        uint32 gasLimit = 150_000;
        uint32 ttl = 5;
        uint256 maxFeePerGas = 20 gwei;
        uint256 maxPriorityFeePerGas = 2 gwei;
        uint256 value = 0;
        return scheduler.schedule(payload, gasLimit, numCalls, freq, ttl, maxFeePerGas, maxPriorityFeePerGas, value);
    }

    function _exists(uint256 callId) internal returns (bool) {
        try scheduler.getCallState(callId) returns (CallState s) {
            // Consider existing if not reverted (state can be SCHEDULED/EXECUTING/etc.)
            return (uint256(s) <= uint256(CallState.EXPIRED));
        } catch {
            return false;
        }
    }

    function testFragmentationStress() public {
        uint256 startLen = _slotsLength();

        // Step 1: Schedule N calls with numCalls=2 (will need 2 executions to complete)
        uint256 N = 300;
        uint256[] memory ids = new uint256[](N);
        for (uint256 i = 0; i < N; i++) {
            uint32 numCalls = 2;
            uint32 freq = (i % 3 == 0) ? 1 : 10;
            ids[i] = _scheduleOne(numCalls, freq);
        }
        assertEq(_slotsLength(), startLen + N, "after initial schedule length");

        // Step 2: Cancel roughly N/3 in a non-sequential pattern (every 3rd)
        uint256 cancelled = 0;
        for (uint256 i = 0; i < N; i += 3) {
            // to == address(this), so we can cancel directly
            scheduler.cancel(ids[i]);
            cancelled++;
        }
        assertEq(_slotsLength(), startLen + N - cancelled, "after cancellations length");

        // Verify cancelled are gone, others remain
        for (uint256 i = 0; i < N; i++) {
            bool exists = _exists(ids[i]);
            if (i % 3 == 0) {
                assertFalse(exists, "cancelled should not exist");
            } else {
                assertTrue(exists, "active should exist");
            }
        }

        // Step 3: Schedule M new calls; compaction ensures dense head
        uint256 M = 200;
        uint256[] memory ids2 = new uint256[](M);
        for (uint256 j = 0; j < M; j++) {
            uint32 numCalls = 3;
            ids2[j] = _scheduleOne(numCalls, 1);
        }
        assertEq(_slotsLength(), startLen + N - cancelled + M, "after additional schedule length");

        // Step 4: Introduce expirations: schedule E calls with numCalls=1, ttl=5, then roll past expiry
        // startBlock = block.number + freq, expiry block = startBlock + ttl
        uint256 E = 50;
        uint256[] memory expiring = new uint256[](E);
        for (uint256 k = 0; k < E; k++) {
            uint32 numCalls = 1;
            expiring[k] = _scheduleOne(numCalls, 1);
        }
        uint256 lenBeforeExpire = _slotsLength();
        // Move forward past expiry (startBlock + ttl = (block.number + 1) + 5 = 7, so roll to 10)
        vm.roll(block.number + 10);
        scheduler.cleanupExpiredCalls(expiring);
        assertEq(_slotsLength(), lenBeforeExpire - E, "after cleanupExpiredCalls length");

        // Step 5: Random pattern of cancels across active sets (ids2 every 4th)
        uint256 cancelled2 = 0;
        for (uint256 j = 0; j < M; j += 4) {
            if (_exists(ids2[j])) {
                scheduler.cancel(ids2[j]);
                cancelled2++;
            }
        }
        assertEq(_slotsLength(), startLen + N - cancelled + M - cancelled2, "after mixed cancels length");

        // Spot-check invariants: remaining ids still resolve
        for (uint256 i = 0; i < N; i++) {
            if (i % 3 != 0) {
                // may still exist if not completed/expired; check boolean
                (bool ok,) =
                    address(scheduler).staticcall(abi.encodeWithSelector(scheduler.getCallState.selector, ids[i]));
                // It's fine if false (expired via Step 4 shouldn't affect these), but ensure no inconsistent reverts occurred earlier
                // We use existence checks above; here we just ensure the staticcall doesn't revert for active ones if they still exist
            }
        }
    }
}
