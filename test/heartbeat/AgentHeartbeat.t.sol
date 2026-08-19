// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AgentHeartbeat} from "../../src/heartbeat/AgentHeartbeat.sol";
import {IAgentHeartbeat} from "../../src/heartbeat/interfaces/IAgentHeartbeat.sol";
import {ITEEServiceRegistry} from "../../src/async/ITEEServiceRegistry.sol";
import {ITEECapabilityPolicy} from "../../src/async/ITEECapabilityPolicy.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockRitualWallet} from "../MockRitualWallet.sol";
import {MockAgentIdentityRegistry} from "../mocks/MockAgentIdentityRegistry.sol";

contract CallCapture {
    bytes public lastCalldata;

    fallback() external {
        lastCalldata = msg.data;
    }
}

contract CallReverter {
    fallback() external {
        revert("boom");
    }
}

struct RevivalCalldataStorageRef {
    string platform;
    string path;
    string keyRef;
}

contract MockTEEServiceRegistry {
    ITEEServiceRegistry.TEEServiceContext[] private _services;

    function addExecutor(address teeAddr) external {
        addServiceWithCapability(teeAddr, ITEECapabilityPolicy.Capability.HTTP_CALL);
    }

    function addServiceWithCapability(address teeAddr, ITEECapabilityPolicy.Capability capability) public {
        addService(teeAddr, teeAddr, capability);
    }

    function addExecutorWithPaymentAddress(address teeAddr, address paymentAddress) external {
        addService(teeAddr, paymentAddress, ITEECapabilityPolicy.Capability.HTTP_CALL);
    }

    function addService(address teeAddr, address paymentAddress, ITEECapabilityPolicy.Capability capability) public {
        ITEEServiceRegistry.TEEServiceNode memory node = ITEEServiceRegistry.TEEServiceNode({
            paymentAddress: paymentAddress,
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

    function getValidService(address addr) external view returns (ITEEServiceRegistry.TEEServiceContext memory) {
        for (uint256 i = 0; i < _services.length; i++) {
            if (_services[i].node.teeAddress == addr) {
                return _services[i];
            }
        }
        revert("service not found");
    }

    function getService(address addr, bool) external view returns (ITEEServiceRegistry.TEEServiceContext memory) {
        return this.getValidService(addr);
    }

    function getServicesByCapability(ITEECapabilityPolicy.Capability, bool)
        external
        view
        returns (ITEEServiceRegistry.TEEServiceContext[] memory)
    {
        return _services;
    }

    function getServicesByCapability(ITEECapabilityPolicy.Capability cap)
        external
        view
        returns (ITEEServiceRegistry.TEEServiceContext[] memory)
    {
        return this.getServicesByCapability(cap, true);
    }
}

contract AgentHeartbeatTest is Test {
    AgentHeartbeat public heartbeat;
    MockTEEServiceRegistry public teeRegistry;
    MockAgentIdentityRegistry public identityRegistry;
    MockRitualWallet public wallet;

    address constant SYSTEM_SENDER = 0x000000000000000000000000000000000000fa7e;
    uint64 constant DEFAULT_TIMEOUT = 134;
    uint64 constant REVIVAL_COOLDOWN = 400;
    uint64 constant MAX_REVIVAL_ATTEMPTS = 3;

    uint256 executorKey;
    address executorAddr;
    uint256 executor2Key;
    address executor2Addr;
    uint256 agentKey;
    address agentAddr;
    address ownerAddr;

    function setUp() public {
        vm.roll(100);

        executorKey = 0xA11CE;
        executorAddr = vm.addr(executorKey);
        executor2Key = 0xB22CE;
        executor2Addr = vm.addr(executor2Key);
        agentKey = 0xBEEF;
        agentAddr = vm.addr(agentKey);
        ownerAddr = vm.addr(0xC0C0);

        identityRegistry = new MockAgentIdentityRegistry();

        teeRegistry = new MockTEEServiceRegistry();
        teeRegistry.addExecutor(executorAddr);
        teeRegistry.addExecutor(executor2Addr);
        wallet = new MockRitualWallet(address(0));

        AgentHeartbeat impl =
            new AgentHeartbeat(address(teeRegistry), address(identityRegistry), address(wallet), MAX_REVIVAL_ATTEMPTS);
        bytes memory initData = abi.encodeWithSelector(
            AgentHeartbeat.initialize.selector, address(this), DEFAULT_TIMEOUT, REVIVAL_COOLDOWN
        );
        heartbeat = AgentHeartbeat(address(new ERC1967Proxy(address(impl), initData)));
    }

    function _allocateAndClaim(bytes32 holderKey, bytes memory encryptedCfg) internal returns (uint256 agentId) {
        return _allocateAndClaim(ownerAddr, agentAddr, holderKey, executorAddr, executorKey, encryptedCfg);
    }

    function _allocateAndClaim(
        address identityOwner,
        address agent,
        bytes32 holderKey,
        address executor,
        uint256 executorSigningKey,
        bytes memory encryptedCfg
    ) internal returns (uint256 agentId) {
        vm.deal(agent, 1 ether);

        vm.prank(identityOwner);
        agentId = identityRegistry.allocateAgentId(identityOwner);

        bytes memory sig = _signClaimWithKey(executorSigningKey, agentId, holderKey, executor, agent);
        vm.prank(agent);
        heartbeat.claim(agentId, holderKey, executor, sig, encryptedCfg);
    }

    function _signClaim(uint256 agentId, bytes32 holderKey, address executor, address agent)
        internal
        view
        returns (bytes memory)
    {
        return _signClaimWithKey(executorKey, agentId, holderKey, executor, agent);
    }

    function _signClaimWithKey(uint256 signingKey, uint256 agentId, bytes32 holderKey, address executor, address agent)
        internal
        view
        returns (bytes memory)
    {
        uint256 nonce = heartbeat.slotNonce(agentId);
        bytes32 digest = _claimDigest(agentId, holderKey, executor, agent, nonce, address(heartbeat), block.chainid);
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signingKey, ethHash);
        return abi.encodePacked(r, s, v);
    }

    function _signSlotHeartbeat(uint256 agentId, string memory manifestCID) internal view returns (bytes memory) {
        return _signSlotHeartbeatWithKey(executorKey, agentId, manifestCID, heartbeat.slotNonce(agentId));
    }

    function _signSlotHeartbeatWithKey(uint256 signingKey, uint256 agentId, string memory manifestCID, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = _slotHeartbeatDigest(agentId, manifestCID, nonce, address(heartbeat), block.chainid);
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signingKey, ethHash);
        return abi.encodePacked(r, s, v);
    }

    function _heartbeat(uint256 agentId, address agent, string memory manifestCID) internal {
        bytes memory sig = _signSlotHeartbeat(agentId, manifestCID);
        uint256 fee = heartbeat.HEARTBEAT_FEE_WEI();
        vm.prank(agent);
        heartbeat.heartbeat{value: fee}(agentId, manifestCID, sig);
    }

    function _claimDigest(
        uint256 agentId,
        bytes32 holderKey,
        address executor,
        address agent,
        uint256 nonce,
        address domainContract,
        uint256 domainChainId
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked("claim", domainChainId, domainContract, agentId, holderKey, executor, agent, nonce)
        );
    }

    function _slotHeartbeatDigest(
        uint256 agentId,
        string memory manifestCID,
        uint256 nonce,
        address domainContract,
        uint256 domainChainId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("slot_heartbeat", domainChainId, domainContract, agentId, manifestCID, nonce));
    }

    function _buildPreparedRevivalInput(
        uint256 agentId,
        address executor,
        string memory manifestCID,
        bytes memory encryptedDAConfig
    ) internal pure returns (bytes memory) {
        RevivalCalldataStorageRef memory emptyRef = RevivalCalldataStorageRef("", "", "");
        RevivalCalldataStorageRef memory daConfigRef = RevivalCalldataStorageRef("", string(encryptedDAConfig), "");
        address[] memory secretOwners = new address[](0);

        return abi.encode(
            executor,
            address(0),
            secretOwners,
            new bytes[](0),
            uint256(500),
            new bytes[](0),
            bytes(""),
            uint64(6000),
            address(0),
            bytes4(0),
            uint256(0),
            uint256(0),
            uint256(0),
            uint256(0),
            uint8(0),
            "",
            "",
            daConfigRef,
            emptyRef,
            emptyRef,
            emptyRef,
            emptyRef,
            emptyRef,
            emptyRef,
            emptyRef,
            manifestCID,
            "",
            uint16(2),
            agentId
        );
    }

    function test_claim_sets_active_assignment() public {
        bytes32 hk = bytes32(uint256(1));
        bytes memory cfg = hex"abcd";
        uint256 agentId = _allocateAndClaim(hk, cfg);

        assertEq(uint256(heartbeat.getAssignmentState(agentId)), uint256(IAgentHeartbeat.SlotState.ACTIVE));

        IAgentHeartbeat.SlotAssignment memory asg = heartbeat.getAssignment(agentId);
        assertEq(uint256(asg.revivalStatus), uint256(IAgentHeartbeat.RevivalStatus.NONE));
        assertEq(asg.agentAddress, agentAddr);
        assertEq(asg.boundHolderKey, hk);
        assertEq(asg.boundExecutor, executorAddr);
        assertEq(asg.encryptedDAConfig, cfg);
        assertEq(heartbeat.slotNonce(agentId), 1);
        assertEq(heartbeat.trackedAgentCount(), 1);
        assertTrue(heartbeat.shouldCheck());
    }

    function test_claim_rejects_oversized_encrypted_da_config() public {
        bytes memory cfg = new bytes(heartbeat.MAX_ENCRYPTED_DA_CONFIG_LENGTH() + 1);
        vm.deal(agentAddr, 1 ether);
        vm.prank(ownerAddr);
        uint256 agentId = identityRegistry.allocateAgentId(ownerAddr);
        bytes32 holderKey = bytes32(uint256(1));
        bytes memory sig = _signClaim(agentId, holderKey, executorAddr, agentAddr);

        vm.prank(agentAddr);
        vm.expectRevert(AgentHeartbeat.EncryptedDAConfigTooLarge.selector);
        heartbeat.claim(agentId, holderKey, executorAddr, sig, cfg);
    }

    function test_claim_accepts_maximum_encrypted_da_config() public {
        bytes memory cfg = new bytes(heartbeat.MAX_ENCRYPTED_DA_CONFIG_LENGTH());
        uint256 agentId = _allocateAndClaim(bytes32(uint256(1)), cfg);

        assertEq(heartbeat.getAssignment(agentId).encryptedDAConfig.length, cfg.length);
    }

    function test_claim_revert_slot_active() public {
        bytes32 hk = bytes32(uint256(1));
        uint256 agentId = _allocateAndClaim(hk, "");

        bytes memory sig = _signClaim(agentId, hk, executorAddr, agentAddr);
        vm.prank(agentAddr);
        vm.expectRevert(bytes("slot not vacant"));
        heartbeat.claim(agentId, hk, executorAddr, sig, "");
    }

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

    function test_claim_accepts_active_expired_slot_and_archives_metadata() public {
        bytes32 hk = bytes32(uint256(1));
        bytes memory cfg = hex"deadbeef";
        uint256 agentId = _allocateAndClaim(hk, cfg);
        string memory manifestCID = "QmLazyVacancyManifest";
        _heartbeat(agentId, agentAddr, manifestCID);

        address replacementAgent = vm.addr(0xDAD);
        vm.deal(replacementAgent, 1 ether);
        bytes32 replacementHolderKey = bytes32(uint256(2));
        bytes memory reclaimSig =
            _signClaimWithKey(executor2Key, agentId, replacementHolderKey, executor2Addr, replacementAgent);

        uint256 staleNonce = heartbeat.slotNonce(agentId);
        vm.roll(block.number + uint256(DEFAULT_TIMEOUT) + 1);

        vm.expectEmit(true, true, true, true);
        emit IAgentHeartbeat.SlotVacated(agentId, agentAddr, "timeout");
        vm.expectEmit(true, true, true, true);
        emit IAgentHeartbeat.SlotReplaced(
            agentId,
            agentAddr,
            replacementAgent,
            executorAddr,
            uint64(block.number - uint256(DEFAULT_TIMEOUT) - 1),
            uint64(block.number),
            manifestCID,
            cfg,
            "timeout"
        );
        vm.prank(replacementAgent);
        heartbeat.claim(agentId, replacementHolderKey, executor2Addr, reclaimSig, hex"cafe");

        IAgentHeartbeat.SlotAssignment memory asg = heartbeat.getAssignment(agentId);
        assertEq(uint256(asg.state), uint256(IAgentHeartbeat.SlotState.ACTIVE));
        assertEq(uint256(asg.revivalStatus), uint256(IAgentHeartbeat.RevivalStatus.NONE));
        assertEq(asg.agentAddress, replacementAgent);
        assertEq(asg.boundHolderKey, replacementHolderKey);
        assertEq(asg.boundExecutor, executor2Addr);
        assertEq(asg.lastHeartbeat, uint64(block.number));
        assertEq(asg.heartbeatTimeout, DEFAULT_TIMEOUT);
        assertEq(asg.cooldownEnd, 0);
        assertEq(bytes(asg.latestManifestCID).length, 0);
        assertEq(asg.encryptedDAConfig, hex"cafe");
        assertEq(heartbeat.slotNonce(agentId), staleNonce + 1);
        assertEq(heartbeat.getAgentIdsNeedingRevival().length, 0);
        assertFalse(heartbeat.hasActionableAgents());
    }

    function test_claim_active_expired_rejects_stale_signature_after_lazy_reclaim() public {
        uint256 agentId = _allocateAndClaim(bytes32(uint256(1)), "");
        bytes memory staleHeartbeatSig = _signSlotHeartbeat(agentId, "QmStaleAfterLazy");

        address replacementAgent = vm.addr(0xDAD);
        vm.deal(replacementAgent, 1 ether);
        bytes memory reclaimSig =
            _signClaimWithKey(executor2Key, agentId, bytes32(uint256(2)), executor2Addr, replacementAgent);

        vm.roll(block.number + uint256(DEFAULT_TIMEOUT) + 1);
        vm.prank(replacementAgent);
        heartbeat.claim(agentId, bytes32(uint256(2)), executor2Addr, reclaimSig, "");

        vm.prank(agentAddr);
        vm.expectRevert(bytes("not bound agent"));
        heartbeat.heartbeat(agentId, "QmStaleAfterLazy", staleHeartbeatSig);
    }

    function test_claim_does_not_require_registry_agent_binding() public {
        vm.prank(ownerAddr);
        uint256 agentId = identityRegistry.allocateAgentId(ownerAddr);

        address other = vm.addr(0xD00D);
        vm.deal(other, 1 ether);
        bytes memory sig = _signClaim(agentId, bytes32(uint256(1)), executorAddr, other);

        vm.prank(other);
        heartbeat.claim(agentId, bytes32(uint256(1)), executorAddr, sig, "");

        IAgentHeartbeat.SlotAssignment memory asg = heartbeat.getAssignment(agentId);
        assertEq(asg.agentAddress, other);
    }

    function test_recall_uses_registry_owner_not_bound_agent() public {
        address boundAgent = vm.addr(0xD00D);
        uint256 agentId = _allocateAndClaim(ownerAddr, boundAgent, bytes32(uint256(1)), executorAddr, executorKey, "");

        vm.prank(boundAgent);
        vm.expectRevert(bytes("not identity owner"));
        heartbeat.recall(agentId);

        vm.prank(ownerAddr);
        heartbeat.recall(agentId);

        assertEq(uint256(heartbeat.getAssignmentState(agentId)), uint256(IAgentHeartbeat.SlotState.VACANT));
    }

    function test_heartbeat_updates_active_assignment() public {
        uint256 agentId = _allocateAndClaim(bytes32(uint256(1)), "");

        vm.roll(block.number + 5);
        string memory cid = "QmSlotHB";
        _heartbeat(agentId, agentAddr, cid);
        assertEq(heartbeat.slotNonce(agentId), 2);

        vm.roll(block.number + 3);
        string memory cid2 = "QmSlotHB2";
        _heartbeat(agentId, agentAddr, cid2);
        assertEq(heartbeat.slotNonce(agentId), 3);

        IAgentHeartbeat.SlotAssignment memory asg = heartbeat.getAssignment(agentId);
        assertEq(asg.lastHeartbeat, uint64(block.number));
        assertEq(keccak256(bytes(asg.latestManifestCID)), keccak256(bytes(cid2)));
        assertEq(uint256(asg.revivalStatus), uint256(IAgentHeartbeat.RevivalStatus.NONE));
    }

    function test_heartbeat_rejects_oversized_manifest_cid() public {
        uint256 agentId = _allocateAndClaim(bytes32(uint256(1)), "");
        string memory manifestCID = string(new bytes(heartbeat.MAX_MANIFEST_CID_LENGTH() + 1));
        bytes memory sig = _signSlotHeartbeat(agentId, manifestCID);
        uint256 fee = heartbeat.HEARTBEAT_FEE_WEI();

        vm.prank(agentAddr);
        vm.expectRevert(AgentHeartbeat.ManifestCIDTooLarge.selector);
        heartbeat.heartbeat{value: fee}(agentId, manifestCID, sig);
    }

    function test_heartbeat_accepts_maximum_manifest_cid() public {
        uint256 agentId = _allocateAndClaim(bytes32(uint256(1)), "");
        string memory manifestCID = string(new bytes(heartbeat.MAX_MANIFEST_CID_LENGTH()));

        _heartbeat(agentId, agentAddr, manifestCID);

        assertEq(bytes(heartbeat.getAssignment(agentId).latestManifestCID).length, bytes(manifestCID).length);
    }

    function test_heartbeat_credits_executor_payment_address_in_wallet() public {
        address paymentAddress = address(0xFEE);
        teeRegistry.removeService(executorAddr);
        teeRegistry.addExecutorWithPaymentAddress(executorAddr, paymentAddress);
        uint256 agentId = _allocateAndClaim(bytes32(uint256(1)), "");
        uint256 fee = heartbeat.HEARTBEAT_FEE_WEI();
        uint256 balanceBefore = address(heartbeat).balance;

        _heartbeat(agentId, agentAddr, "QmNativeFee");

        assertEq(address(heartbeat).balance, balanceBefore);
        assertEq(wallet.availableBalance(paymentAddress), fee);
        assertEq(wallet.availableBalance(executorAddr), 0);
    }

    function test_heartbeat_reverts_for_incorrect_native_fee() public {
        uint256 agentId = _allocateAndClaim(bytes32(uint256(1)), "");
        bytes memory sig = _signSlotHeartbeat(agentId, "QmWrongFee");
        uint256 fee = heartbeat.HEARTBEAT_FEE_WEI();
        uint256 nonceBefore = heartbeat.slotNonce(agentId);
        uint256 balanceBefore = address(heartbeat).balance;

        vm.prank(agentAddr);
        vm.expectRevert(bytes("incorrect heartbeat fee"));
        heartbeat.heartbeat{value: fee - 1}(agentId, "QmWrongFee", sig);

        assertEq(heartbeat.slotNonce(agentId), nonceBefore);
        assertEq(address(heartbeat).balance, balanceBefore);
    }

    function test_heartbeat_reverts_and_rolls_back_when_wallet_deposit_fails() public {
        uint256 agentId = _allocateAndClaim(bytes32(uint256(1)), "");
        string memory manifestCID = "QmDepositFailure";
        bytes memory sig = _signSlotHeartbeat(agentId, manifestCID);
        uint256 nonceBefore = heartbeat.slotNonce(agentId);
        uint256 fee = heartbeat.HEARTBEAT_FEE_WEI();

        wallet.setFailDeposit(true);
        vm.prank(agentAddr);
        vm.expectRevert(bytes("deposit failed"));
        heartbeat.heartbeat{value: fee}(agentId, manifestCID, sig);

        assertEq(heartbeat.slotNonce(agentId), nonceBefore);
        assertEq(bytes(heartbeat.getAssignment(agentId).latestManifestCID).length, 0);
    }

    function test_heartbeat_revert_non_bound_executor_signature() public {
        uint256 agentId = _allocateAndClaim(bytes32(uint256(1)), "");
        string memory cid = "QmX";
        bytes memory badSig = _signSlotHeartbeatWithKey(executor2Key, agentId, cid, heartbeat.slotNonce(agentId));

        vm.prank(agentAddr);
        vm.expectRevert(bytes("executor mismatch"));
        heartbeat.heartbeat(agentId, cid, badSig);
    }

    function test_heartbeat_reverts_after_executor_revoked() public {
        uint256 agentId = _allocateAndClaim(bytes32(uint256(1)), "");
        _heartbeat(agentId, agentAddr, "QmBeforeRevoke");

        teeRegistry.removeService(executorAddr);

        string memory cid = "QmAfterRevoke";
        bytes memory sig = _signSlotHeartbeat(agentId, cid);
        uint256 fee = heartbeat.HEARTBEAT_FEE_WEI();
        vm.prank(agentAddr);
        vm.expectRevert(bytes("executor not registered"));
        heartbeat.heartbeat{value: fee}(agentId, cid, sig);

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
        uint256 fee = heartbeat.HEARTBEAT_FEE_WEI();
        vm.prank(agentAddr);
        vm.expectRevert(bytes("executor not registered"));
        heartbeat.heartbeat{value: fee}(agentId, cid, sig);
    }

    function test_timeout_vacates_slot_and_queues_revival_by_agentId() public {
        bytes memory cfg = hex"deadbeef";
        uint256 agentId = _allocateAndClaim(bytes32(uint256(1)), cfg);

        string memory cid = "QmBeforeFail";
        _heartbeat(agentId, agentAddr, cid);

        vm.roll(block.number + uint256(DEFAULT_TIMEOUT) + 1);
        vm.prank(SYSTEM_SENDER);
        heartbeat.checkAndRevive();

        IAgentHeartbeat.SlotAssignment memory asg = heartbeat.getAssignment(agentId);
        assertEq(uint256(asg.state), uint256(IAgentHeartbeat.SlotState.VACANT));
        assertEq(uint256(asg.revivalStatus), uint256(IAgentHeartbeat.RevivalStatus.FAILED));
        assertEq(asg.boundExecutor, executorAddr);
        assertEq(asg.boundHolderKey, bytes32(0));
        assertEq(keccak256(bytes(asg.latestManifestCID)), keccak256(bytes(cid)));
        assertEq(asg.encryptedDAConfig, cfg);

        uint256[] memory need = heartbeat.getAgentIdsNeedingRevival();
        assertEq(need.length, 1);
        assertEq(need[0], agentId);
        assertFalse(heartbeat.hasActionableAgents());
    }

    function test_recall_vacates_binding_without_revival_queue() public {
        uint256 agentId = _allocateAndClaim(bytes32(uint256(1)), "");

        vm.prank(ownerAddr);
        heartbeat.recall(agentId);

        IAgentHeartbeat.SlotAssignment memory asg = heartbeat.getAssignment(agentId);
        assertEq(uint256(asg.state), uint256(IAgentHeartbeat.SlotState.VACANT));
        assertEq(uint256(asg.revivalStatus), uint256(IAgentHeartbeat.RevivalStatus.NONE));
        assertEq(asg.boundExecutor, executorAddr);
        assertEq(asg.boundHolderKey, bytes32(0));
        assertEq(heartbeat.getAgentIdsNeedingRevival().length, 0);
    }

    function test_heartbeat_after_recall_reverts_until_reclaim() public {
        uint256 agentId = _allocateAndClaim(bytes32(uint256(1)), "");

        vm.prank(ownerAddr);
        heartbeat.recall(agentId);

        bytes memory staleHeartbeatSig = _signSlotHeartbeat(agentId, "QmY");
        vm.prank(agentAddr);
        vm.expectRevert(bytes("slot not active"));
        heartbeat.heartbeat(agentId, "QmY", staleHeartbeatSig);

        bytes memory sig = _signClaim(agentId, bytes32(uint256(2)), executorAddr, agentAddr);
        vm.prank(agentAddr);
        heartbeat.claim(agentId, bytes32(uint256(2)), executorAddr, sig, "");

        assertEq(uint256(heartbeat.getAssignmentState(agentId)), uint256(IAgentHeartbeat.SlotState.ACTIVE));
        _heartbeat(agentId, agentAddr, "QmZ");
    }

    function test_stale_holder_cannot_heartbeat_after_reclaim() public {
        uint256 agentId = _allocateAndClaim(bytes32(uint256(1)), "");

        vm.prank(ownerAddr);
        heartbeat.recall(agentId);

        address replacementAgent = vm.addr(0xDAD);
        vm.deal(replacementAgent, 1 ether);
        bytes32 replacementHolderKey = bytes32(uint256(2));
        bytes memory reclaimSig = _signClaim(agentId, replacementHolderKey, executorAddr, replacementAgent);
        vm.prank(replacementAgent);
        heartbeat.claim(agentId, replacementHolderKey, executorAddr, reclaimSig, "");

        bytes memory heartbeatSig = _signSlotHeartbeat(agentId, "QmStaleHolder");
        vm.prank(agentAddr);
        vm.expectRevert(bytes("not bound agent"));
        heartbeat.heartbeat(agentId, "QmStaleHolder", heartbeatSig);
    }

    function test_claim_recall_replay_reverts_and_fresh_reclaim_succeeds() public {
        bytes32 hk = bytes32(uint256(1));
        uint256 agentId = _allocateAndClaim(hk, "");
        assertEq(heartbeat.slotNonce(agentId), 1);

        bytes memory preRecallSig = _signClaim(agentId, hk, executorAddr, agentAddr);
        vm.prank(ownerAddr);
        heartbeat.recall(agentId);
        assertEq(heartbeat.slotNonce(agentId), 2);

        vm.prank(agentAddr);
        vm.expectRevert(bytes("signature not from claimed executor"));
        heartbeat.claim(agentId, hk, executorAddr, preRecallSig, "");

        bytes memory freshSig = _signClaim(agentId, hk, executorAddr, agentAddr);
        vm.prank(agentAddr);
        heartbeat.claim(agentId, hk, executorAddr, freshSig, "");

        assertEq(heartbeat.slotNonce(agentId), 3);
        assertEq(uint256(heartbeat.getAssignmentState(agentId)), uint256(IAgentHeartbeat.SlotState.ACTIVE));
    }

    function test_claim_after_failed_timeout_clears_revival_queue() public {
        uint256 agentId = _allocateAndClaim(bytes32(uint256(1)), "");

        _heartbeat(agentId, agentAddr, "QmBeforeTimeout");

        vm.roll(block.number + uint256(DEFAULT_TIMEOUT) + 1);
        vm.prank(SYSTEM_SENDER);
        heartbeat.checkAndRevive();

        assertEq(heartbeat.getAgentIdsNeedingRevival().length, 1);

        bytes memory reclaimSig = _signClaim(agentId, bytes32(uint256(2)), executorAddr, agentAddr);
        vm.prank(agentAddr);
        heartbeat.claim(agentId, bytes32(uint256(2)), executorAddr, reclaimSig, "");

        IAgentHeartbeat.SlotAssignment memory asg = heartbeat.getAssignment(agentId);
        assertEq(uint256(asg.state), uint256(IAgentHeartbeat.SlotState.ACTIVE));
        assertEq(uint256(asg.revivalStatus), uint256(IAgentHeartbeat.RevivalStatus.NONE));
        assertEq(bytes(asg.latestManifestCID).length, 0);
        assertEq(heartbeat.getAgentIdsNeedingRevival().length, 0);
    }

    function test_reviveAgent_marks_slot_reviving_until_fresh_claim() public {
        uint256 agentId = _allocateAndClaim(bytes32(uint256(1)), "");
        string memory manifestCID = "QmReviveManifest";
        _heartbeat(agentId, agentAddr, manifestCID);

        vm.roll(block.number + uint256(DEFAULT_TIMEOUT) + 1);
        vm.prank(SYSTEM_SENDER);
        heartbeat.checkAndRevive();

        bytes memory precompileInput = _buildPreparedRevivalInput(agentId, executor2Addr, manifestCID, "");
        vm.prank(SYSTEM_SENDER);
        heartbeat.reviveAgent(agentId, precompileInput);

        IAgentHeartbeat.SlotAssignment memory asg = heartbeat.getAssignment(agentId);
        assertEq(uint256(asg.state), uint256(IAgentHeartbeat.SlotState.VACANT));
        assertEq(uint256(asg.revivalStatus), uint256(IAgentHeartbeat.RevivalStatus.REVIVING));
        assertEq(asg.boundExecutor, executor2Addr);
        assertGt(asg.cooldownEnd, block.number);
        assertEq(heartbeat.revivalAttempts(agentId), 1);
        assertFalse(heartbeat.hasActionableAgents());

        bytes memory staleSig = _signSlotHeartbeat(agentId, "QmPostRevive");
        vm.prank(agentAddr);
        vm.expectRevert(bytes("slot not active"));
        heartbeat.heartbeat(agentId, "QmPostRevive", staleSig);

        address replacementAgent = vm.addr(0xDAD);
        vm.deal(replacementAgent, 1 ether);
        bytes memory reclaimSig =
            _signClaimWithKey(executor2Key, agentId, bytes32(uint256(2)), executor2Addr, replacementAgent);
        vm.prank(replacementAgent);
        heartbeat.claim(agentId, bytes32(uint256(2)), executor2Addr, reclaimSig, "");

        asg = heartbeat.getAssignment(agentId);
        assertEq(uint256(asg.state), uint256(IAgentHeartbeat.SlotState.ACTIVE));
        assertEq(uint256(asg.revivalStatus), uint256(IAgentHeartbeat.RevivalStatus.NONE));
        assertEq(asg.agentAddress, replacementAgent);
        assertEq(asg.boundExecutor, executor2Addr);
        assertEq(asg.cooldownEnd, 0);
        assertEq(bytes(asg.latestManifestCID).length, 0);
        assertEq(heartbeat.revivalAttempts(agentId), 0);
    }

    function test_reviveAgent_evicts_after_max_cooldown_failures() public {
        uint256 agentId = _allocateAndClaim(bytes32(uint256(1)), "");
        string memory manifestCID = "QmRetryManifest";
        _heartbeat(agentId, agentAddr, manifestCID);

        vm.roll(block.number + uint256(DEFAULT_TIMEOUT) + 1);
        vm.prank(SYSTEM_SENDER);
        heartbeat.checkAndRevive();

        bytes memory precompileInput = _buildPreparedRevivalInput(agentId, executor2Addr, manifestCID, "");

        for (uint64 attempt = 1; attempt < MAX_REVIVAL_ATTEMPTS; attempt++) {
            vm.prank(SYSTEM_SENDER);
            heartbeat.reviveAgent(agentId, precompileInput);
            assertEq(heartbeat.revivalAttempts(agentId), attempt);

            vm.roll(block.number + uint256(REVIVAL_COOLDOWN) + 1);
            vm.prank(SYSTEM_SENDER);
            heartbeat.checkAndRevive();

            IAgentHeartbeat.SlotAssignment memory asg = heartbeat.getAssignment(agentId);
            assertEq(uint256(asg.state), uint256(IAgentHeartbeat.SlotState.VACANT));
            assertEq(uint256(asg.revivalStatus), uint256(IAgentHeartbeat.RevivalStatus.FAILED));
            assertEq(heartbeat.trackedAgentCount(), 1);
        }

        vm.prank(SYSTEM_SENDER);
        heartbeat.reviveAgent(agentId, precompileInput);
        assertEq(heartbeat.revivalAttempts(agentId), MAX_REVIVAL_ATTEMPTS);

        vm.roll(block.number + uint256(REVIVAL_COOLDOWN) + 1);
        vm.expectEmit(true, true, true, true);
        emit IAgentHeartbeat.SlotRemoved(agentId, agentAddr, "revival attempts exceeded");
        vm.prank(SYSTEM_SENDER);
        heartbeat.checkAndRevive();

        assertEq(heartbeat.trackedAgentCount(), 0);
        assertEq(heartbeat.revivalAttempts(agentId), 0);
        assertEq(heartbeat.getAgentIdsNeedingRevival().length, 0);
        assertFalse(heartbeat.hasActionableAgents());
        assertEq(heartbeat.getAssignment(agentId).agentAddress, address(0));
    }

    function test_reviveAgent_precompile_failure_evicts_after_cooldown_cap() public {
        address PRECOMPILE = 0x0000000000000000000000000000000000000820;
        CallReverter reverter = new CallReverter();
        vm.etch(PRECOMPILE, address(reverter).code);

        uint256 agentId = _allocateAndClaim(bytes32(uint256(1)), "");
        string memory manifestCID = "QmRetryRevert";
        _heartbeat(agentId, agentAddr, manifestCID);

        vm.roll(block.number + uint256(DEFAULT_TIMEOUT) + 1);
        vm.prank(SYSTEM_SENDER);
        heartbeat.checkAndRevive();

        bytes memory precompileInput = _buildPreparedRevivalInput(agentId, executor2Addr, manifestCID, "");

        for (uint64 attempt = 1; attempt < MAX_REVIVAL_ATTEMPTS; attempt++) {
            vm.prank(SYSTEM_SENDER);
            heartbeat.reviveAgent(agentId, precompileInput);
            assertEq(heartbeat.revivalAttempts(agentId), attempt);
            assertEq(heartbeat.trackedAgentCount(), 1);
            assertEq(
                uint256(heartbeat.getAssignment(agentId).revivalStatus), uint256(IAgentHeartbeat.RevivalStatus.REVIVING)
            );

            vm.roll(block.number + uint256(REVIVAL_COOLDOWN) + 1);
            vm.prank(SYSTEM_SENDER);
            heartbeat.checkAndRevive();
            assertEq(
                uint256(heartbeat.getAssignment(agentId).revivalStatus), uint256(IAgentHeartbeat.RevivalStatus.FAILED)
            );
        }

        vm.prank(SYSTEM_SENDER);
        heartbeat.reviveAgent(agentId, precompileInput);
        assertEq(heartbeat.revivalAttempts(agentId), MAX_REVIVAL_ATTEMPTS);

        vm.roll(block.number + uint256(REVIVAL_COOLDOWN) + 1);
        vm.expectEmit(true, true, true, true);
        emit IAgentHeartbeat.SlotRemoved(agentId, agentAddr, "revival attempts exceeded");
        vm.prank(SYSTEM_SENDER);
        heartbeat.checkAndRevive();

        assertEq(heartbeat.trackedAgentCount(), 0);
        assertEq(heartbeat.revivalAttempts(agentId), 0);
        assertEq(heartbeat.getAssignment(agentId).agentAddress, address(0));
    }

    function test_claim_after_failed_revivals_resets_revival_attempts() public {
        uint256 agentId = _allocateAndClaim(bytes32(uint256(1)), "");
        string memory manifestCID = "QmRetryThenClaim";
        _heartbeat(agentId, agentAddr, manifestCID);

        vm.roll(block.number + uint256(DEFAULT_TIMEOUT) + 1);
        vm.prank(SYSTEM_SENDER);
        heartbeat.checkAndRevive();

        bytes memory precompileInput = _buildPreparedRevivalInput(agentId, executor2Addr, manifestCID, "");
        vm.prank(SYSTEM_SENDER);
        heartbeat.reviveAgent(agentId, precompileInput);
        assertEq(heartbeat.revivalAttempts(agentId), 1);

        vm.roll(block.number + uint256(REVIVAL_COOLDOWN) + 1);
        vm.prank(SYSTEM_SENDER);
        heartbeat.checkAndRevive();
        assertEq(heartbeat.revivalAttempts(agentId), 1);

        address replacementAgent = vm.addr(0xDAD);
        vm.deal(replacementAgent, 1 ether);
        bytes memory reclaimSig =
            _signClaimWithKey(executor2Key, agentId, bytes32(uint256(2)), executor2Addr, replacementAgent);
        vm.prank(replacementAgent);
        heartbeat.claim(agentId, bytes32(uint256(2)), executor2Addr, reclaimSig, "");

        assertEq(heartbeat.revivalAttempts(agentId), 0);
        assertEq(uint256(heartbeat.getAssignment(agentId).state), uint256(IAgentHeartbeat.SlotState.ACTIVE));
    }

    function test_reviveAgent_keeps_reviving_until_cooldown_on_precompile_failure() public {
        address PRECOMPILE = 0x0000000000000000000000000000000000000820;
        CallReverter reverter = new CallReverter();
        vm.etch(PRECOMPILE, address(reverter).code);

        uint256 agentId = _allocateAndClaim(bytes32(uint256(1)), "");
        string memory manifestCID = "QmReviveManifest";
        _heartbeat(agentId, agentAddr, manifestCID);

        vm.roll(block.number + uint256(DEFAULT_TIMEOUT) + 1);
        vm.prank(SYSTEM_SENDER);
        heartbeat.checkAndRevive();

        bytes memory precompileInput = _buildPreparedRevivalInput(agentId, executor2Addr, manifestCID, "");
        vm.prank(SYSTEM_SENDER);
        heartbeat.reviveAgent(agentId, precompileInput);

        IAgentHeartbeat.SlotAssignment memory asg = heartbeat.getAssignment(agentId);
        assertEq(uint256(asg.state), uint256(IAgentHeartbeat.SlotState.VACANT));
        assertEq(uint256(asg.revivalStatus), uint256(IAgentHeartbeat.RevivalStatus.REVIVING));
        assertEq(asg.boundExecutor, executorAddr);
        assertGt(asg.cooldownEnd, block.number);
        assertEq(heartbeat.revivalAttempts(agentId), 1);

        vm.roll(block.number + uint256(REVIVAL_COOLDOWN) + 1);
        vm.prank(SYSTEM_SENDER);
        heartbeat.checkAndRevive();

        asg = heartbeat.getAssignment(agentId);
        assertEq(uint256(asg.revivalStatus), uint256(IAgentHeartbeat.RevivalStatus.FAILED));
        assertEq(asg.cooldownEnd, 0);
    }

    function test_reviveAgent_same_executor_failure_waits_for_cooldown() public {
        address PRECOMPILE = 0x0000000000000000000000000000000000000820;
        CallReverter reverter = new CallReverter();
        vm.etch(PRECOMPILE, address(reverter).code);

        uint256 agentId = _allocateAndClaim(bytes32(uint256(1)), "");
        string memory manifestCID = "QmSameExecutorReviveManifest";
        _heartbeat(agentId, agentAddr, manifestCID);

        vm.roll(block.number + uint256(DEFAULT_TIMEOUT) + 1);
        vm.prank(SYSTEM_SENDER);
        heartbeat.checkAndRevive();

        bytes memory precompileInput = _buildPreparedRevivalInput(agentId, executorAddr, manifestCID, "");
        vm.prank(SYSTEM_SENDER);
        heartbeat.reviveAgent(agentId, precompileInput);

        IAgentHeartbeat.SlotAssignment memory asg = heartbeat.getAssignment(agentId);
        assertEq(uint256(asg.state), uint256(IAgentHeartbeat.SlotState.VACANT));
        assertEq(uint256(asg.revivalStatus), uint256(IAgentHeartbeat.RevivalStatus.REVIVING));
        assertEq(asg.boundExecutor, executorAddr);
        assertGt(asg.cooldownEnd, block.number);
        assertEq(heartbeat.revivalAttempts(agentId), 1);

        vm.roll(block.number + uint256(REVIVAL_COOLDOWN) + 1);
        vm.expectEmit(true, true, true, true);
        emit IAgentHeartbeat.SlotRevivalFailed(agentId, agentAddr, "revival cooldown elapsed");
        vm.prank(SYSTEM_SENDER);
        heartbeat.checkAndRevive();

        asg = heartbeat.getAssignment(agentId);
        assertEq(uint256(asg.revivalStatus), uint256(IAgentHeartbeat.RevivalStatus.FAILED));
        assertEq(asg.cooldownEnd, 0);
    }

    function test_checkAndRevive_cursor_wraps_static_batch() public {
        uint256[] memory agentIds = new uint256[](101);
        address[] memory agents = new address[](101);

        for (uint256 i = 0; i < 101; i++) {
            agents[i] = vm.addr(0xBEEF00 + i + 1);
            agentIds[i] = _allocateAndClaim(ownerAddr, agents[i], bytes32(i + 1), executorAddr, executorKey, "");
        }
        assertEq(heartbeat.trackedAgentCount(), 101);

        vm.roll(block.number + uint256(DEFAULT_TIMEOUT) + 1);

        vm.prank(SYSTEM_SENDER);
        heartbeat.checkAndRevive();

        for (uint256 i = 0; i < 100; i++) {
            IAgentHeartbeat.SlotAssignment memory asg = heartbeat.getAssignment(agentIds[i]);
            assertEq(uint256(asg.state), uint256(IAgentHeartbeat.SlotState.VACANT));
            assertEq(uint256(asg.revivalStatus), uint256(IAgentHeartbeat.RevivalStatus.FAILED));
        }
        assertEq(uint256(heartbeat.getAssignment(agentIds[100]).state), uint256(IAgentHeartbeat.SlotState.ACTIVE));
        assertEq(heartbeat.nextCheckIndex(), 100);

        vm.prank(SYSTEM_SENDER);
        heartbeat.checkAndRevive();

        IAgentHeartbeat.SlotAssignment memory tail = heartbeat.getAssignment(agentIds[100]);
        assertEq(uint256(tail.state), uint256(IAgentHeartbeat.SlotState.VACANT));
        assertEq(uint256(tail.revivalStatus), uint256(IAgentHeartbeat.RevivalStatus.FAILED));
        assertEq(heartbeat.nextCheckIndex(), 99);
        assertEq(heartbeat.getAgentIdsNeedingRevival().length, 101);
    }

    function test_checkAndRevive_removal_does_not_skip_swapped_agent() public {
        uint256[] memory agentIds = new uint256[](101);
        address[] memory agents = new address[](101);

        for (uint256 i = 0; i < 101; i++) {
            agents[i] = vm.addr(0xCAFE00 + i + 1);
            agentIds[i] = _allocateAndClaim(ownerAddr, agents[i], bytes32(i + 1), executorAddr, executorKey, "");
        }
        assertEq(heartbeat.trackedAgentCount(), 101);

        vm.roll(block.number + uint256(DEFAULT_TIMEOUT) + 1);
        address removedAgent = agents[1];
        uint256 removedAgentId = agentIds[1];
        uint256 tailAgentId = agentIds[100];
        vm.deal(removedAgent, 0);

        vm.prank(SYSTEM_SENDER);
        heartbeat.checkAndRevive();

        assertEq(heartbeat.trackedAgentCount(), 100);
        assertEq(heartbeat.getAssignment(removedAgentId).agentAddress, address(0));
        assertEq(
            uint256(heartbeat.getAssignment(tailAgentId).revivalStatus), uint256(IAgentHeartbeat.RevivalStatus.FAILED)
        );
        assertEq(heartbeat.nextCheckIndex(), 99);

        vm.prank(SYSTEM_SENDER);
        heartbeat.checkAndRevive();
        assertEq(
            uint256(heartbeat.getAssignment(agentIds[99]).revivalStatus), uint256(IAgentHeartbeat.RevivalStatus.FAILED)
        );
        assertEq(heartbeat.nextCheckIndex(), 99);
    }

    function test_shouldCheck_and_getAgentIdsNeedingRevival() public {
        assertFalse(heartbeat.shouldCheck());
        uint256 agentId = _allocateAndClaim(bytes32(uint256(1)), "");
        assertTrue(heartbeat.shouldCheck());
        assertEq(heartbeat.getAgentIdsNeedingRevival().length, 0);

        vm.roll(block.number + uint256(DEFAULT_TIMEOUT) + 1);
        assertTrue(heartbeat.hasActionableAgents());
        vm.prank(SYSTEM_SENDER);
        heartbeat.checkAndRevive();

        uint256[] memory needingRevival = heartbeat.getAgentIdsNeedingRevival();
        assertEq(needingRevival.length, 1);
        assertEq(needingRevival[0], agentId);
        assertFalse(heartbeat.hasActionableAgents());
    }

    function test_checkAndRevive_only_system() public {
        vm.expectRevert(bytes("only system"));
        heartbeat.checkAndRevive();
    }

    function test_reviveAgent_only_system() public {
        uint256 agentId = _allocateAndClaim(bytes32(uint256(1)), "");
        vm.roll(block.number + uint256(DEFAULT_TIMEOUT) + 1);
        vm.prank(SYSTEM_SENDER);
        heartbeat.checkAndRevive();

        vm.expectRevert(bytes("only system"));
        heartbeat.reviveAgent(agentId, bytes(""));
    }

    function test_set_default_timeout_and_cooldown() public {
        heartbeat.setDefaultTimeout(268);
        assertEq(heartbeat.defaultTimeout(), 268);
        heartbeat.setRevivalCooldown(800);
        assertEq(heartbeat.revivalCooldown(), 800);
    }

    function test_heartbeatIntervalDivisor_defaults_to_two() public view {
        assertEq(heartbeat.heartbeatIntervalDivisor(), 2);
        assertEq(heartbeat.heartbeatIntervalBlocks(), DEFAULT_TIMEOUT / 2);
    }

    function test_setHeartbeatIntervalDivisor() public {
        heartbeat.setDefaultTimeout(5000);
        heartbeat.setHeartbeatIntervalDivisor(5);
        assertEq(heartbeat.heartbeatIntervalDivisor(), 5);
        assertEq(heartbeat.heartbeatIntervalBlocks(), 1000);
    }

    function test_admin_only_owner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        heartbeat.setDefaultTimeout(268);
    }

    function test_revivalCalldata_roundTrip() public {
        address PRECOMPILE = 0x0000000000000000000000000000000000000820;

        CallCapture capture = new CallCapture();
        vm.etch(PRECOMPILE, address(capture).code);

        uint256 agentId = _allocateAndClaim(bytes32(uint256(1)), "");

        string memory manifestCID = "QmRevivalTestManifestCID123";
        _heartbeat(agentId, agentAddr, manifestCID);

        vm.roll(block.number + uint256(DEFAULT_TIMEOUT) + 1);
        vm.prank(SYSTEM_SENDER);
        heartbeat.checkAndRevive();

        IAgentHeartbeat.SlotAssignment memory asg = heartbeat.getAssignment(agentId);
        assertEq(uint256(asg.revivalStatus), uint256(IAgentHeartbeat.RevivalStatus.FAILED));
        assertEq(asg.latestManifestCID, manifestCID);

        vm.expectEmit(true, true, true, true);
        emit IAgentHeartbeat.SlotRevivalInitiated(
            agentId, agentAddr, manifestCID, executorAddr, uint64(block.number) + REVIVAL_COOLDOWN
        );
        bytes memory precompileInput = _buildPreparedRevivalInput(agentId, executorAddr, manifestCID, "");
        vm.prank(SYSTEM_SENDER);
        heartbeat.reviveAgent(agentId, precompileInput);

        asg = heartbeat.getAssignment(agentId);
        assertEq(uint256(asg.revivalStatus), uint256(IAgentHeartbeat.RevivalStatus.REVIVING));

        bytes memory calldata_ = CallCapture(PRECOMPILE).lastCalldata();
        assertTrue(calldata_.length > 0, "revival calldata should be non-empty");

        (
            address field0_executor,
            address field1_sponsor,
            address[] memory field2_secret_owners,
            bytes[] memory field3_encrypted_secrets,
            uint256 field4_ttl,
            bytes[] memory field5_secret_signature,
            bytes memory field6_user_public_key,
            uint64 field7_max_spawn_block,
            address field8_delivery_target,
            bytes4 field9_delivery_selector,
            uint256 field10_delivery_gas_limit,
            uint256 field11_delivery_max_fee_per_gas,
            uint256 field12_delivery_max_priority_fee_per_gas,
            uint256 field13_delivery_value,
            uint8 field14_provider,
            string memory field15_model,
            string memory field16_owner_hint,
            RevivalCalldataStorageRef memory field17_da_config,
            RevivalCalldataStorageRef memory field18_soul_ref,
            RevivalCalldataStorageRef memory field19_agents_ref,
            RevivalCalldataStorageRef memory field20_user_ref,
            RevivalCalldataStorageRef memory field21_memory_ref,
            RevivalCalldataStorageRef memory field22_identity_ref,
            RevivalCalldataStorageRef memory field23_tools_ref,
            RevivalCalldataStorageRef memory field24_openclaw_config_ref,
            string memory field25_restore_from_cid,
            string memory field26_rpc_urls,
            uint16 field27_agent_runtime,
            uint256 field28_agent_id
        ) = abi.decode(
            calldata_,
            (
                address,
                address,
                address[],
                bytes[],
                uint256,
                bytes[],
                bytes,
                uint64,
                address,
                bytes4,
                uint256,
                uint256,
                uint256,
                uint256,
                uint8,
                string,
                string,
                RevivalCalldataStorageRef,
                RevivalCalldataStorageRef,
                RevivalCalldataStorageRef,
                RevivalCalldataStorageRef,
                RevivalCalldataStorageRef,
                RevivalCalldataStorageRef,
                RevivalCalldataStorageRef,
                RevivalCalldataStorageRef,
                string,
                string,
                uint16,
                uint256
            )
        );

        assertTrue(field0_executor != address(0), "field 0: executor must be non-zero");
        assertEq(field1_sponsor, address(0), "field 1: sponsor defaults to zero");
        assertEq(field2_secret_owners.length, 0, "field 2: secret owners default empty");
        assertEq(field3_encrypted_secrets.length, 0, "field 3: encrypted secrets default empty");
        assertEq(field4_ttl, 500, "field 4: ttl must match revival request");
        assertEq(field5_secret_signature.length, 0, "field 5: secret signature default empty");
        assertEq(field6_user_public_key, bytes(""), "field 6: user public key default empty");
        assertEq(field7_max_spawn_block, 6000, "field 7: max spawn block must match revival request");
        assertEq(field8_delivery_target, address(0), "field 8: delivery target default zero");
        assertEq(field9_delivery_selector, bytes4(0), "field 9: delivery selector default zero");
        assertEq(field10_delivery_gas_limit, 0, "field 10: delivery gas limit default zero");
        assertEq(field11_delivery_max_fee_per_gas, 0, "field 11: delivery max fee default zero");
        assertEq(field12_delivery_max_priority_fee_per_gas, 0, "field 12: delivery priority fee default zero");
        assertEq(field13_delivery_value, 0, "field 13: delivery value default zero");
        assertEq(field14_provider, 0, "field 14: provider must be 0");
        assertEq(field15_model, "", "field 15: model must be empty");
        assertEq(field16_owner_hint, "", "field 16: llm_api_key_ref must be empty");
        assertEq(field17_da_config.path, "", "field 17: da config path default empty");
        assertEq(field18_soul_ref.path, "", "field 18: soul ref path default empty");
        assertEq(field19_agents_ref.path, "", "field 19: agents ref path default empty");
        assertEq(field20_user_ref.path, "", "field 20: user ref path default empty");
        assertEq(field21_memory_ref.path, "", "field 21: memory ref path default empty");
        assertEq(field22_identity_ref.path, "", "field 22: identity ref path default empty");
        assertEq(field23_tools_ref.path, "", "field 23: tools ref path default empty");
        assertEq(field24_openclaw_config_ref.path, "", "field 24: openclaw ref path default empty");
        assertEq(field25_restore_from_cid, manifestCID, "field 25: restore_from_cid must match latestManifestCID");
        assertEq(field26_rpc_urls, "", "field 26: rpc_urls must be empty");
        assertEq(field27_agent_runtime, 2, "field 27: agent_runtime must default to Hermes");
        assertEq(field28_agent_id, agentId, "field 28: agent_id must match revived agentId");
    }
}

contract AdminRemoveAgentTest is Test {
    AgentHeartbeat public heartbeat;
    MockTEEServiceRegistry public teeRegistry;
    MockAgentIdentityRegistry public identityRegistry;
    MockRitualWallet public wallet;

    uint64 constant DEFAULT_TIMEOUT = 134;
    uint64 constant REVIVAL_COOLDOWN = 400;
    uint64 constant MAX_REVIVAL_ATTEMPTS = 3;

    uint256 executorKey;
    address executorAddr;
    address ownerAddr;
    address agentAddr;

    function setUp() public {
        vm.roll(100);

        executorKey = 0xA11CE;
        executorAddr = vm.addr(executorKey);
        ownerAddr = vm.addr(0x1234);
        agentAddr = vm.addr(0xBEEF);

        identityRegistry = new MockAgentIdentityRegistry();

        teeRegistry = new MockTEEServiceRegistry();
        teeRegistry.addExecutor(executorAddr);
        wallet = new MockRitualWallet(address(0));

        AgentHeartbeat impl =
            new AgentHeartbeat(address(teeRegistry), address(identityRegistry), address(wallet), MAX_REVIVAL_ATTEMPTS);
        bytes memory initData = abi.encodeWithSelector(
            AgentHeartbeat.initialize.selector, address(this), DEFAULT_TIMEOUT, REVIVAL_COOLDOWN
        );
        heartbeat = AgentHeartbeat(address(new ERC1967Proxy(address(impl), initData)));
    }

    function _claimAgent() internal returns (uint256 agentId) {
        vm.deal(agentAddr, 1 ether);

        vm.prank(ownerAddr);
        agentId = identityRegistry.allocateAgentId(ownerAddr);

        uint256 nonce = heartbeat.slotNonce(agentId);
        bytes32 digest = keccak256(
            abi.encodePacked(
                "claim", block.chainid, address(heartbeat), agentId, bytes32(uint256(1)), executorAddr, agentAddr, nonce
            )
        );
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(executorKey, ethHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(agentAddr);
        heartbeat.claim(agentId, bytes32(uint256(1)), executorAddr, sig, "");
    }

    function test_adminRemoveAgent_succeeds() public {
        uint256 agentId = _claimAgent();
        assertEq(heartbeat.trackedAgentCount(), 1);
        assertEq(heartbeat.trackedAgentIdAt(0), agentId);
        heartbeat.adminRemoveAgent(agentId);
        assertEq(heartbeat.trackedAgentCount(), 0);
    }

    function test_adminRemoveAgent_reverts_nonOwner() public {
        uint256 agentId = _claimAgent();
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        heartbeat.adminRemoveAgent(agentId);
    }

    function test_adminRemoveAgent_agentRemovedFromGetter() public {
        uint256 agentId = _claimAgent();
        heartbeat.adminRemoveAgent(agentId);
        IAgentHeartbeat.SlotAssignment memory asg = heartbeat.getAssignment(agentId);
        assertEq(asg.agentAddress, address(0));
    }

    function test_adminRemoveAgent_emitsEvent() public {
        uint256 agentId = _claimAgent();
        vm.expectEmit(true, true, true, true);
        emit IAgentHeartbeat.SlotRemoved(agentId, agentAddr, "admin");
        heartbeat.adminRemoveAgent(agentId);
    }

    function test_adminRemoveAgent_keeps_slot_nonce_monotonic() public {
        bytes32 holderKey = bytes32(uint256(1));
        vm.deal(agentAddr, 1 ether);

        vm.prank(ownerAddr);
        uint256 agentId = identityRegistry.allocateAgentId(ownerAddr);

        uint256 nonce = heartbeat.slotNonce(agentId);
        bytes32 digest = keccak256(
            abi.encodePacked(
                "claim", block.chainid, address(heartbeat), agentId, holderKey, executorAddr, agentAddr, nonce
            )
        );
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(executorKey, ethHash);
        bytes memory initialSig = abi.encodePacked(r, s, v);

        vm.prank(agentAddr);
        heartbeat.claim(agentId, holderKey, executorAddr, initialSig, "");
        assertEq(heartbeat.slotNonce(agentId), 1);

        heartbeat.adminRemoveAgent(agentId);
        assertEq(heartbeat.slotNonce(agentId), 1);

        vm.prank(agentAddr);
        vm.expectRevert(bytes("signature not from claimed executor"));
        heartbeat.claim(agentId, holderKey, executorAddr, initialSig, "");

        uint256 freshNonce = heartbeat.slotNonce(agentId);
        bytes32 freshDigest = keccak256(
            abi.encodePacked(
                "claim", block.chainid, address(heartbeat), agentId, holderKey, executorAddr, agentAddr, freshNonce
            )
        );
        bytes32 freshEthHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", freshDigest));
        (v, r, s) = vm.sign(executorKey, freshEthHash);
        bytes memory freshSig = abi.encodePacked(r, s, v);

        vm.prank(agentAddr);
        heartbeat.claim(agentId, holderKey, executorAddr, freshSig, "");
        assertEq(heartbeat.slotNonce(agentId), 2);
    }
}
