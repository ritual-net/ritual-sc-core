// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AsyncDelivery} from "../src/async/AsyncDelivery.sol";
import {AsyncJobTracker} from "../src/async/AsyncJobTracker.sol";
import {AgentHeartbeat} from "../src/heartbeat/AgentHeartbeat.sol";
import {Scheduler} from "../src/scheduler/Scheduler.sol";
import {RitualWallet} from "../src/wallet/RitualWallet.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

interface IUUPSProxy {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

contract UpgradeAuthorizationTest is Test {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address internal constant NON_OWNER = address(0xBEEF);
    address internal constant SCHEDULER_DEPENDENCY = address(0x1001);
    address internal constant ASYNC_DELIVERY_DEPENDENCY = address(0x1002);
    address internal constant ASYNC_JOB_TRACKER_DEPENDENCY = address(0x1003);
    address internal constant RITUAL_WALLET_DEPENDENCY = address(0x1004);
    address internal constant TEE_REGISTRY_DEPENDENCY = address(0x1005);
    address internal constant IDENTITY_REGISTRY_DEPENDENCY = address(0x1006);

    uint32 internal constant MAX_TTL = 30;
    uint64 internal constant DEFAULT_TIMEOUT = 100;
    uint64 internal constant REVIVAL_COOLDOWN = 20;
    uint64 internal constant MAX_REVIVAL_ATTEMPTS = 3;

    address internal schedulerProxy;
    address internal ritualWalletProxy;
    address internal asyncJobTrackerProxy;
    address internal asyncDeliveryProxy;
    address internal agentHeartbeatProxy;

    function setUp() public {
        Scheduler schedulerImplementation = new Scheduler(RITUAL_WALLET_DEPENDENCY, MAX_TTL);
        schedulerProxy =
            _deployProxy(address(schedulerImplementation), abi.encodeCall(Scheduler.initialize, (address(this))));

        RitualWallet ritualWalletImplementation =
            new RitualWallet(SCHEDULER_DEPENDENCY, ASYNC_DELIVERY_DEPENDENCY, ASYNC_JOB_TRACKER_DEPENDENCY);
        ritualWalletProxy =
            _deployProxy(address(ritualWalletImplementation), abi.encodeCall(RitualWallet.initialize, (address(this))));

        AsyncJobTracker asyncJobTrackerImplementation =
            new AsyncJobTracker(ASYNC_DELIVERY_DEPENDENCY, RITUAL_WALLET_DEPENDENCY, TEE_REGISTRY_DEPENDENCY);
        asyncJobTrackerProxy = _deployProxy(
            address(asyncJobTrackerImplementation), abi.encodeCall(AsyncJobTracker.initialize, (address(this)))
        );

        AsyncDelivery asyncDeliveryImplementation =
            new AsyncDelivery(RITUAL_WALLET_DEPENDENCY, ASYNC_JOB_TRACKER_DEPENDENCY);
        asyncDeliveryProxy = _deployProxy(
            address(asyncDeliveryImplementation), abi.encodeCall(AsyncDelivery.initialize, (address(this)))
        );

        AgentHeartbeat agentHeartbeatImplementation = new AgentHeartbeat(
            TEE_REGISTRY_DEPENDENCY, IDENTITY_REGISTRY_DEPENDENCY, RITUAL_WALLET_DEPENDENCY, MAX_REVIVAL_ATTEMPTS
        );
        agentHeartbeatProxy = _deployProxy(
            address(agentHeartbeatImplementation),
            abi.encodeCall(AgentHeartbeat.initialize, (address(this), DEFAULT_TIMEOUT, REVIVAL_COOLDOWN))
        );
    }

    function test_schedulerUpgradeAuthorization() public {
        Scheduler replacement = new Scheduler(RITUAL_WALLET_DEPENDENCY, MAX_TTL);
        _assertUpgradeAuthorization(schedulerProxy, address(replacement));
    }

    function test_ritualWalletUpgradeAuthorization() public {
        RitualWallet replacement =
            new RitualWallet(SCHEDULER_DEPENDENCY, ASYNC_DELIVERY_DEPENDENCY, ASYNC_JOB_TRACKER_DEPENDENCY);
        _assertUpgradeAuthorization(ritualWalletProxy, address(replacement));
    }

    function test_asyncJobTrackerUpgradeAuthorization() public {
        AsyncJobTracker replacement =
            new AsyncJobTracker(ASYNC_DELIVERY_DEPENDENCY, RITUAL_WALLET_DEPENDENCY, TEE_REGISTRY_DEPENDENCY);
        _assertUpgradeAuthorization(asyncJobTrackerProxy, address(replacement));
    }

    function test_asyncDeliveryUpgradeAuthorization() public {
        AsyncDelivery replacement = new AsyncDelivery(RITUAL_WALLET_DEPENDENCY, ASYNC_JOB_TRACKER_DEPENDENCY);
        _assertUpgradeAuthorization(asyncDeliveryProxy, address(replacement));
    }

    function test_agentHeartbeatUpgradeAuthorization() public {
        AgentHeartbeat replacement = new AgentHeartbeat(
            TEE_REGISTRY_DEPENDENCY, IDENTITY_REGISTRY_DEPENDENCY, RITUAL_WALLET_DEPENDENCY, MAX_REVIVAL_ATTEMPTS
        );
        _assertUpgradeAuthorization(agentHeartbeatProxy, address(replacement));
    }

    function _deployProxy(address implementation, bytes memory initData) internal returns (address) {
        return address(new ERC1967Proxy(implementation, initData));
    }

    function _assertUpgradeAuthorization(address proxy, address replacement) internal {
        bytes32 implementationBefore = vm.load(proxy, IMPLEMENTATION_SLOT);

        vm.startPrank(NON_OWNER);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, NON_OWNER));
        IUUPSProxy(proxy).upgradeToAndCall(replacement, "");
        vm.stopPrank();

        assertEq(vm.load(proxy, IMPLEMENTATION_SLOT), implementationBefore);

        IUUPSProxy(proxy).upgradeToAndCall(replacement, "");

        bytes32 implementationAfter = vm.load(proxy, IMPLEMENTATION_SLOT);
        assertNotEq(implementationAfter, implementationBefore);
        assertEq(implementationAfter, bytes32(uint256(uint160(replacement))));
    }
}
