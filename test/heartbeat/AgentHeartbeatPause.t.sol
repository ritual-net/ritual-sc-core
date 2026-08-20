// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AgentHeartbeat} from "../../src/heartbeat/AgentHeartbeat.sol";
import {IAgentHeartbeat} from "../../src/heartbeat/interfaces/IAgentHeartbeat.sol";
import {ITEEServiceRegistry} from "../../src/async/ITEEServiceRegistry.sol";
import {ITEECapabilityPolicy} from "../../src/async/ITEECapabilityPolicy.sol";
import {MockAgentIdentityRegistry} from "../mocks/MockAgentIdentityRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract AgentHeartbeatPauseRegistry {
    address private immutable _executor;
    address private immutable _paymentAddress;

    constructor(address executor, address paymentAddress) {
        _executor = executor;
        _paymentAddress = paymentAddress;
    }

    function getValidService(address addr) external view returns (ITEEServiceRegistry.TEEServiceContext memory) {
        require(addr == _executor, "service not found");

        ITEEServiceRegistry.TEEServiceNode memory node = ITEEServiceRegistry.TEEServiceNode({
            paymentAddress: _paymentAddress,
            teeAddress: _executor,
            teeType: ITEEServiceRegistry.TeeType.DEBUG,
            executorSecretsAuthPublicKey: "",
            endpoint: "",
            mTlsSpkiHash: bytes32(0),
            capability: ITEECapabilityPolicy.Capability.HTTP_CALL
        });
        return ITEEServiceRegistry.TEEServiceContext({node: node, isValid: true, workloadId: bytes32(0)});
    }
}

contract AgentHeartbeatPauseWallet {
    mapping(address => uint256) public availableBalance;

    function depositFor(address account) external payable {
        availableBalance[account] += msg.value;
    }
}

contract AgentHeartbeatPauseTest is Test {
    address private constant SYSTEM_SENDER = 0x000000000000000000000000000000000000fa7e;
    address private constant NON_OWNER = address(0xBAD);
    address private constant IDENTITY_OWNER = address(0xA11);
    address private constant AGENT = address(0xA6E17);
    address private constant PAYMENT_ADDRESS = address(0xFEE);

    uint256 private constant EXECUTOR_KEY = 0xE11EC;
    uint64 private constant DEFAULT_TIMEOUT = 134;
    uint64 private constant REVIVAL_COOLDOWN = 400;
    uint64 private constant MAX_REVIVAL_ATTEMPTS = 3;

    AgentHeartbeat private heartbeatContract;
    MockAgentIdentityRegistry private identityRegistry;
    AgentHeartbeatPauseWallet private wallet;
    address private executor;

    function setUp() public {
        vm.roll(100);
        executor = vm.addr(EXECUTOR_KEY);

        identityRegistry = new MockAgentIdentityRegistry();
        AgentHeartbeatPauseRegistry teeRegistry = new AgentHeartbeatPauseRegistry(executor, PAYMENT_ADDRESS);
        wallet = new AgentHeartbeatPauseWallet();

        AgentHeartbeat implementation =
            new AgentHeartbeat(address(teeRegistry), address(identityRegistry), address(wallet), MAX_REVIVAL_ATTEMPTS);
        bytes memory initData = abi.encodeWithSelector(
            AgentHeartbeat.initialize.selector, address(this), DEFAULT_TIMEOUT, REVIVAL_COOLDOWN
        );
        heartbeatContract = AgentHeartbeat(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function test_owner_pause_and_unpause_update_paused_state() public {
        assertFalse(heartbeatContract.paused());

        heartbeatContract.pause();
        assertTrue(heartbeatContract.paused());

        heartbeatContract.unpause();
        assertFalse(heartbeatContract.paused());
    }

    function test_non_owner_pause_and_unpause_revert_exactly() public {
        vm.prank(NON_OWNER);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, NON_OWNER));
        heartbeatContract.pause();

        heartbeatContract.pause();

        vm.prank(NON_OWNER);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, NON_OWNER));
        heartbeatContract.unpause();
    }

    function test_paused_checkAndRevive_reverts_for_system_sender() public {
        heartbeatContract.pause();

        vm.prank(SYSTEM_SENDER);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        heartbeatContract.checkAndRevive();
    }

    function test_paused_reviveAgent_reverts_for_system_sender() public {
        heartbeatContract.pause();

        vm.prank(SYSTEM_SENDER);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        heartbeatContract.reviveAgent(1, "");
    }

    function test_unpause_restores_checkAndRevive_for_system_sender() public {
        uint256 agentId = _claimAgent();
        vm.roll(block.number + uint256(DEFAULT_TIMEOUT) + 1);

        heartbeatContract.pause();
        vm.prank(SYSTEM_SENDER);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        heartbeatContract.checkAndRevive();

        heartbeatContract.unpause();
        vm.prank(SYSTEM_SENDER);
        heartbeatContract.checkAndRevive();

        IAgentHeartbeat.SlotAssignment memory assignment = heartbeatContract.getAssignment(agentId);
        assertEq(uint256(assignment.state), uint256(IAgentHeartbeat.SlotState.VACANT));
        assertEq(uint256(assignment.revivalStatus), uint256(IAgentHeartbeat.RevivalStatus.FAILED));
    }

    function test_pause_scope_allows_claim_and_valid_heartbeat() public {
        heartbeatContract.pause();

        uint256 agentId = _claimAgent();
        assertEq(uint256(heartbeatContract.getAssignmentState(agentId)), uint256(IAgentHeartbeat.SlotState.ACTIVE));

        vm.roll(block.number + 1);
        string memory manifestCID = "QmPausedButLive";
        bytes memory signature = _signHeartbeat(agentId, manifestCID);
        uint256 fee = heartbeatContract.HEARTBEAT_FEE_WEI();

        vm.prank(AGENT);
        heartbeatContract.heartbeat{value: fee}(agentId, manifestCID, signature);

        IAgentHeartbeat.SlotAssignment memory assignment = heartbeatContract.getAssignment(agentId);
        assertEq(assignment.lastHeartbeat, uint64(block.number));
        assertEq(assignment.latestManifestCID, manifestCID);
        assertEq(heartbeatContract.slotNonce(agentId), 2);
        assertEq(wallet.availableBalance(PAYMENT_ADDRESS), fee);
        assertTrue(heartbeatContract.paused());
    }

    function test_non_owner_admin_calls_revert_exactly() public {
        bytes memory expectedError =
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, NON_OWNER);

        vm.prank(NON_OWNER);
        vm.expectRevert(expectedError);
        heartbeatContract.setDefaultTimeout(268);

        vm.prank(NON_OWNER);
        vm.expectRevert(expectedError);
        heartbeatContract.setHeartbeatIntervalDivisor(4);

        vm.prank(NON_OWNER);
        vm.expectRevert(expectedError);
        heartbeatContract.setRevivalCooldown(800);

        vm.prank(NON_OWNER);
        vm.expectRevert(expectedError);
        heartbeatContract.adminRemoveAgent(1);
    }

    function test_setDefaultTimeout_rejects_values_out_of_bounds() public {
        vm.expectRevert(bytes("timeout out of bounds"));
        heartbeatContract.setDefaultTimeout(9);

        vm.expectRevert(bytes("timeout out of bounds"));
        heartbeatContract.setDefaultTimeout(100_001);
    }

    function test_setDefaultTimeout_rejects_timeout_below_interval_divisor() public {
        heartbeatContract.setHeartbeatIntervalDivisor(DEFAULT_TIMEOUT);

        vm.expectRevert(bytes("timeout below interval divisor"));
        heartbeatContract.setDefaultTimeout(10);
    }

    function test_setDefaultTimeout_accepts_inclusive_bounds() public {
        heartbeatContract.setDefaultTimeout(10);
        assertEq(heartbeatContract.defaultTimeout(), 10);

        heartbeatContract.setDefaultTimeout(100_000);
        assertEq(heartbeatContract.defaultTimeout(), 100_000);
    }

    function test_setHeartbeatIntervalDivisor_rejects_values_out_of_bounds() public {
        vm.expectRevert(bytes("divisor out of bounds"));
        heartbeatContract.setHeartbeatIntervalDivisor(0);

        vm.expectRevert(bytes("divisor out of bounds"));
        heartbeatContract.setHeartbeatIntervalDivisor(1001);
    }

    function test_setHeartbeatIntervalDivisor_rejects_divisor_larger_than_timeout() public {
        vm.expectRevert(bytes("divisor too large for timeout"));
        heartbeatContract.setHeartbeatIntervalDivisor(DEFAULT_TIMEOUT + 1);
    }

    function test_setHeartbeatIntervalDivisor_accepts_inclusive_bounds() public {
        heartbeatContract.setDefaultTimeout(100_000);

        heartbeatContract.setHeartbeatIntervalDivisor(1);
        assertEq(heartbeatContract.heartbeatIntervalDivisor(), 1);
        assertEq(heartbeatContract.heartbeatIntervalBlocks(), 100_000);

        heartbeatContract.setHeartbeatIntervalDivisor(1000);
        assertEq(heartbeatContract.heartbeatIntervalDivisor(), 1000);
        assertEq(heartbeatContract.heartbeatIntervalBlocks(), 100);
    }

    function test_adminRemoveAgent_reverts_for_untracked_agent_id() public {
        vm.expectRevert(bytes("not tracked"));
        heartbeatContract.adminRemoveAgent(999);
    }

    function _claimAgent() private returns (uint256 agentId) {
        vm.deal(AGENT, 1 ether);
        vm.prank(IDENTITY_OWNER);
        agentId = identityRegistry.allocateAgentId(IDENTITY_OWNER);

        bytes32 holderKey = bytes32(uint256(1));
        bytes memory signature = _signClaim(agentId, holderKey);
        vm.prank(AGENT);
        heartbeatContract.claim(agentId, holderKey, executor, signature, "");
    }

    function _signClaim(uint256 agentId, bytes32 holderKey) private view returns (bytes memory) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "claim",
                block.chainid,
                address(heartbeatContract),
                agentId,
                holderKey,
                executor,
                AGENT,
                heartbeatContract.slotNonce(agentId)
            )
        );
        return _signDigest(digest);
    }

    function _signHeartbeat(uint256 agentId, string memory manifestCID) private view returns (bytes memory) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "slot_heartbeat",
                block.chainid,
                address(heartbeatContract),
                agentId,
                manifestCID,
                heartbeatContract.slotNonce(agentId)
            )
        );
        return _signDigest(digest);
    }

    function _signDigest(bytes32 digest) private pure returns (bytes memory) {
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(EXECUTOR_KEY, ethHash);
        return abi.encodePacked(r, s, v);
    }
}
