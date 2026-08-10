// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AgentHeartbeat} from "../../src/heartbeat/AgentHeartbeat.sol";
import {ITEEServiceRegistry} from "../../src/async/ITEEServiceRegistry.sol";
import {ITEECapabilityPolicy} from "../../src/async/ITEECapabilityPolicy.sol";

contract MockTEEServiceRegistry {
    ITEEServiceRegistry.TEEServiceContext[] private _services;

    function addExecutor(address teeAddr) external {
        addServiceWithCapability(teeAddr, ITEECapabilityPolicy.Capability.HTTP_CALL);
    }

    function addServiceWithCapability(address teeAddr, ITEECapabilityPolicy.Capability capability) public {
        ITEEServiceRegistry.TEEServiceNode memory node = ITEEServiceRegistry.TEEServiceNode({
            paymentAddress: teeAddr,
            teeAddress: teeAddr,
            teeType: ITEEServiceRegistry.TeeType.DEBUG,
            executorSecretsAuthPublicKey: "",
            endpoint: "http://localhost:8080",
            mTlsSpkiHash: bytes32(0),
            capability: capability
        });
        _services.push(ITEEServiceRegistry.TEEServiceContext({node: node, isValid: true, workloadId: bytes32(0)}));
    }

    function removeService(address teeAddr) external {
        for (uint256 i = 0; i < _services.length; i++) {
            if (_services[i].node.teeAddress == teeAddr) {
                _services[i] = _services[_services.length - 1];
                _services.pop();
                return;
            }
        }
    }

    function setServiceCapability(address teeAddr, ITEECapabilityPolicy.Capability capability) external {
        for (uint256 i = 0; i < _services.length; i++) {
            if (_services[i].node.teeAddress == teeAddr) {
                _services[i].node.capability = capability;
                return;
            }
        }
    }

    /// @dev Mirrors the real registry's safe-by-default getter: reverts when the
    ///      service is unknown or its attestation is no longer valid.
    function getService(address addr) external view returns (ITEEServiceRegistry.TEEServiceContext memory) {
        for (uint256 i = 0; i < _services.length; i++) {
            if (_services[i].node.teeAddress == addr) {
                return _services[i];
            }
        }
        revert("service not found");
    }
}

contract MockAgentIdentityRegistry {
    uint256 private _nextId = 1;
    mapping(uint256 => address) private _owners;

    function allocateAgentId(address owner) external returns (uint256 agentId) {
        agentId = _nextId++;
        _owners[agentId] = owner;
    }

    function ownerOf(uint256 agentId) external view returns (address) {
        address owner = _owners[agentId];
        require(owner != address(0), "unknown agentId");
        return owner;
    }
}

/// @notice Regression tests for Zellic 3.7: executor registration and capability are
///         re-validated on every heartbeat, not just at claim time.
contract AgentHeartbeatExecutorRevalidationTest is Test {
    AgentHeartbeat public heartbeat;
    MockTEEServiceRegistry public teeRegistry;
    MockAgentIdentityRegistry public identityRegistry;

    uint64 constant DEFAULT_TIMEOUT = 134;
    uint64 constant REVIVAL_COOLDOWN = 400;
    uint64 constant MAX_REVIVAL_ATTEMPTS = 3;

    uint256 executorKey;
    address executorAddr;
    uint256 agentKey;
    address agentAddr;
    address ownerAddr;

    function setUp() public {
        vm.roll(100);

        executorKey = 0xA11CE;
        executorAddr = vm.addr(executorKey);
        agentKey = 0xBEEF;
        agentAddr = vm.addr(agentKey);
        ownerAddr = vm.addr(0xC0C0);

        identityRegistry = new MockAgentIdentityRegistry();
        teeRegistry = new MockTEEServiceRegistry();
        teeRegistry.addExecutor(executorAddr);

        AgentHeartbeat impl = new AgentHeartbeat(address(teeRegistry), address(identityRegistry), MAX_REVIVAL_ATTEMPTS);
        bytes memory initData = abi.encodeWithSelector(
            AgentHeartbeat.initialize.selector, address(this), DEFAULT_TIMEOUT, REVIVAL_COOLDOWN
        );
        heartbeat = AgentHeartbeat(address(new ERC1967Proxy(address(impl), initData)));
    }

    // =========================================================================
    // Tests
    // =========================================================================

    function test_claim_reverts_for_executor_without_http_call_capability() public {
        uint256 streamingKey = 0xD44DE;
        address streamingAddr = vm.addr(streamingKey);
        teeRegistry.addServiceWithCapability(streamingAddr, ITEECapabilityPolicy.Capability.STREAMING);

        vm.deal(agentAddr, 1 ether);
        vm.prank(ownerAddr);
        uint256 agentId = identityRegistry.allocateAgentId(ownerAddr);

        bytes32 hk = bytes32(uint256(1));
        bytes memory sig = _signClaimWithKey(streamingKey, agentId, hk, streamingAddr, agentAddr);
        vm.prank(agentAddr);
        vm.expectRevert(bytes("executor not registered"));
        heartbeat.claim(agentId, hk, streamingAddr, sig, "");
    }

    function test_heartbeat_reverts_after_executor_revoked() public {
        uint256 agentId = _allocateAndClaim(bytes32(uint256(1)), "");
        _heartbeat(agentId, agentAddr, "QmBeforeRevoke");

        teeRegistry.removeService(executorAddr);

        string memory cid = "QmAfterRevoke";
        bytes memory sig = _signSlotHeartbeat(agentId, cid);
        vm.prank(agentAddr);
        vm.expectRevert(bytes("executor not registered"));
        heartbeat.heartbeat(agentId, cid, sig);

        // Re-registration restores heartbeat authority (check is live, not sticky).
        teeRegistry.addExecutor(executorAddr);
        _heartbeat(agentId, agentAddr, cid);
        assertEq(heartbeat.slotNonce(agentId), 3);
    }

    function test_heartbeat_reverts_after_executor_capability_changed() public {
        uint256 agentId = _allocateAndClaim(bytes32(uint256(1)), "");
        _heartbeat(agentId, agentAddr, "QmBeforeCapChange");

        teeRegistry.setServiceCapability(executorAddr, ITEECapabilityPolicy.Capability.STREAMING);

        string memory cid = "QmAfterCapChange";
        bytes memory sig = _signSlotHeartbeat(agentId, cid);
        vm.prank(agentAddr);
        vm.expectRevert(bytes("executor not registered"));
        heartbeat.heartbeat(agentId, cid, sig);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _allocateAndClaim(bytes32 holderKey, bytes memory encryptedCfg) internal returns (uint256 agentId) {
        vm.deal(agentAddr, 1 ether);

        vm.prank(ownerAddr);
        agentId = identityRegistry.allocateAgentId(ownerAddr);

        bytes memory sig = _signClaimWithKey(executorKey, agentId, holderKey, executorAddr, agentAddr);
        vm.prank(agentAddr);
        heartbeat.claim(agentId, holderKey, executorAddr, sig, encryptedCfg);
    }

    function _signClaimWithKey(uint256 signingKey, uint256 agentId, bytes32 holderKey, address executor, address agent)
        internal
        view
        returns (bytes memory)
    {
        uint256 nonce = heartbeat.slotNonce(agentId);
        bytes32 digest = keccak256(
            abi.encodePacked("claim", block.chainid, address(heartbeat), agentId, holderKey, executor, agent, nonce)
        );
        return _ethSign(signingKey, digest);
    }

    function _signSlotHeartbeat(uint256 agentId, string memory manifestCID) internal view returns (bytes memory) {
        uint256 nonce = heartbeat.slotNonce(agentId);
        bytes32 digest = keccak256(
            abi.encodePacked("slot_heartbeat", block.chainid, address(heartbeat), agentId, manifestCID, nonce)
        );
        return _ethSign(executorKey, digest);
    }

    function _ethSign(uint256 signingKey, bytes32 digest) internal pure returns (bytes memory) {
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signingKey, ethHash);
        return abi.encodePacked(r, s, v);
    }

    function _heartbeat(uint256 agentId, address agent, string memory manifestCID) internal {
        bytes memory sig = _signSlotHeartbeat(agentId, manifestCID);
        vm.prank(agent);
        heartbeat.heartbeat(agentId, manifestCID, sig);
    }
}
