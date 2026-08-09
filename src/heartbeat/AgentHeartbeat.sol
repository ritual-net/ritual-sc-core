// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IAgentHeartbeat} from "./interfaces/IAgentHeartbeat.sol";
import {ITEEServiceRegistry} from "../async/ITEEServiceRegistry.sol";
import {IAgentIdentityRegistry} from "../identity/IAgentIdentityRegistry.sol";

/// @title AgentHeartbeat
/// @notice System contract for monitoring persistent-agent liveness and agentId-keyed revival.
/// @dev All timing is in block numbers. Step 3 is authoritative here: lifecycle, timeout,
///      and revival state live in the `agentId`-keyed `SlotAssignment`; ownership is resolved
///      from `IDENTITY_REGISTRY.ownerOf(agentId)`. In this contract, "slot" means the
///      active holder assignment for an agentId, not executor capacity. `claim` accepts
///      explicitly vacant assignments, including failed/reviving recovery assignments, and
///      active assignments whose heartbeat timeout has elapsed. Expired active assignments
///      are lazily vacated and replaced atomically by the claim.
contract AgentHeartbeat is IAgentHeartbeat, Initializable, UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    address private constant SYSTEM_SENDER = 0x000000000000000000000000000000000000fa7e;
    address private constant PERSISTENT_AGENT_PRECOMPILE = 0x0000000000000000000000000000000000000820;

    uint256 public constant MIN_BALANCE = 0.1 ether;
    uint256 public constant MAX_CHECK_BATCH = 100;
    uint256 private constant MAX_TRACKED_AGENTS = 10_000;
    uint256 public constant HEARTBEAT_FEE_WEI = 347_000_000_000_000;
    uint256 public constant MAX_ENCRYPTED_DA_CONFIG_LENGTH = 10 * 1024;
    uint256 public constant MAX_MANIFEST_CID_LENGTH = 256;

    error EncryptedDAConfigTooLarge();
    error ManifestCIDTooLarge();

    ITEEServiceRegistry public immutable TEE_REGISTRY;
    IAgentIdentityRegistry public immutable IDENTITY_REGISTRY;
    uint64 public immutable MAX_REVIVAL_ATTEMPTS;

    uint64 public defaultTimeout;
    uint64 public revivalCooldown;
    uint64 public heartbeatIntervalDivisor;

    mapping(uint256 => SlotAssignment) private _assignments;
    uint256[] private _trackedAgentIds;
    mapping(uint256 => uint256) private _trackedAgentIndexPlusOne;
    mapping(uint256 => uint256) public slotNonce;
    uint256 public nextCheckIndex;
    mapping(uint256 => uint64) public revivalAttempts;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address teeRegistry, address identityRegistry, uint64 maxRevivalAttempts) {
        require(maxRevivalAttempts > 0, "max revival attempts zero");
        _disableInitializers();
        TEE_REGISTRY = ITEEServiceRegistry(teeRegistry);
        IDENTITY_REGISTRY = IAgentIdentityRegistry(identityRegistry);
        MAX_REVIVAL_ATTEMPTS = maxRevivalAttempts;
    }

    function initialize(address _owner, uint64 _defaultTimeout, uint64 _revivalCooldown) external initializer {
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();

        defaultTimeout = _defaultTimeout;
        revivalCooldown = _revivalCooldown;
        heartbeatIntervalDivisor = 2;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // =========================================================================
    // Step 3 views
    // =========================================================================

    function getAssignment(uint256 agentId) external view returns (SlotAssignment memory) {
        return _assignments[agentId];
    }

    function getAssignmentState(uint256 agentId) external view returns (SlotState) {
        return _assignments[agentId].state;
    }

    function trackedAgentCount() external view returns (uint256) {
        return _trackedAgentIds.length;
    }

    function trackedAgentIdAt(uint256 index) external view returns (uint256) {
        return _trackedAgentIds[index];
    }

    // =========================================================================
    // Step 3 lifecycle (authoritative)
    // =========================================================================

    function claim(
        uint256 agentId,
        bytes32 holderKey,
        address executor,
        bytes calldata executorSignature,
        bytes calldata encryptedDAConfig
    ) external {
        require(msg.sender.balance >= MIN_BALANCE, "insufficient balance");

        if (encryptedDAConfig.length > MAX_ENCRYPTED_DA_CONFIG_LENGTH) {
            revert EncryptedDAConfigTooLarge();
        }

        address identityOwner = IDENTITY_REGISTRY.ownerOf(agentId);

        SlotAssignment storage slot = _assignments[agentId];
        if (slot.state == SlotState.ACTIVE) {
            require(_isExpired(slot), "slot not vacant");
        } else {
            require(slot.state == SlotState.VACANT, "slot not vacant");
        }

        uint256 nonce = slotNonce[agentId];
        bytes32 digest = _claimDigest(agentId, holderKey, executor, msg.sender, nonce);
        address signer = digest.toEthSignedMessageHash().recover(executorSignature);
        require(signer == executor, "signature not from claimed executor");
        require(_isRegisteredExecutor(executor), "executor not registered");

        _clearPreviousAssignmentForClaim(agentId, slot, msg.sender);

        slotNonce[agentId] = nonce + 1;
        _trackAgentId(agentId);

        slot.state = SlotState.ACTIVE;
        slot.revivalStatus = RevivalStatus.NONE;
        slot.agentAddress = msg.sender;
        slot.boundHolderKey = holderKey;
        slot.boundExecutor = executor;
        slot.lastHeartbeat = uint64(block.number);
        slot.heartbeatTimeout = defaultTimeout;
        slot.cooldownEnd = 0;
        slot.encryptedDAConfig = encryptedDAConfig;
        delete revivalAttempts[agentId];

        emit SlotClaimed(agentId, msg.sender, executor, holderKey, identityOwner);
    }

    function heartbeat(uint256 agentId, string calldata manifestCID, bytes calldata executorSignature)
        external
        payable
    {
        uint256 manifestCIDLength = bytes(manifestCID).length;
        require(manifestCIDLength > 0, "manifest CID required");
        if (manifestCIDLength > MAX_MANIFEST_CID_LENGTH) {
            revert ManifestCIDTooLarge();
        }

        SlotAssignment storage slot = _assignments[agentId];
        require(slot.state == SlotState.ACTIVE, "slot not active");
        require(slot.agentAddress == msg.sender, "not bound agent");

        uint256 nonce = slotNonce[agentId];
        bytes32 digest = _slotHeartbeatDigest(agentId, manifestCID, nonce);
        address signer = digest.toEthSignedMessageHash().recover(executorSignature);
        require(signer == slot.boundExecutor, "executor mismatch");
        require(msg.value == HEARTBEAT_FEE_WEI, "incorrect heartbeat fee");

        slotNonce[agentId] = nonce + 1;
        slot.lastHeartbeat = uint64(block.number);
        slot.latestManifestCID = manifestCID;
        slot.revivalStatus = RevivalStatus.NONE;
        slot.cooldownEnd = 0;

        emit SlotHeartbeat(agentId, msg.sender, uint64(block.number), manifestCID);
    }

    function recall(uint256 agentId) external {
        address identityOwner = IDENTITY_REGISTRY.ownerOf(agentId);
        require(identityOwner == msg.sender, "not identity owner");

        SlotAssignment storage slot = _assignments[agentId];
        require(slot.state == SlotState.ACTIVE, "slot not active");

        address agentAddr = slot.agentAddress;
        _vacateSlot(agentId, "recall", RevivalStatus.NONE);

        emit SlotRecalled(agentId, agentAddr, msg.sender);
    }

    // =========================================================================
    // Protocol operations (SYSTEM_SENDER only)
    // =========================================================================

    function shouldCheck() external view returns (bool) {
        return _trackedAgentIds.length > 0;
    }

    function getAgentIdsNeedingRevival() external view returns (uint256[] memory) {
        uint256 len = _trackedAgentIds.length;
        uint256 count = 0;
        for (uint256 i = 0; i < len; i++) {
            SlotAssignment storage slot = _assignments[_trackedAgentIds[i]];
            if (_isPendingRevival(slot)) {
                count++;
            }
        }

        uint256[] memory result = new uint256[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < len; i++) {
            uint256 agentId = _trackedAgentIds[i];
            SlotAssignment storage slot = _assignments[agentId];
            if (_isPendingRevival(slot)) {
                result[idx++] = agentId;
            }
        }

        return result;
    }

    function checkAndRevive() external whenNotPaused {
        _checkAndReviveBatch();
    }

    /// @notice Minimal revival path: the precompile input is assembled off-chain.
    /// @dev `precompileInput` must match the persistent-agent precompile ABI.
    ///      Revival remains a launch/recovery action; the slot stays VACANT until a fresh claim succeeds.
    function reviveAgent(uint256 agentId, bytes calldata precompileInput) external whenNotPaused {
        require(msg.sender == SYSTEM_SENDER, "only system");

        SlotAssignment storage slot = _assignments[agentId];
        if (slot.state != SlotState.VACANT || slot.revivalStatus != RevivalStatus.FAILED) {
            return;
        }
        if (bytes(slot.latestManifestCID).length == 0) {
            emit SlotRemoved(agentId, slot.agentAddress, "missing manifest CID");
            _removeAgent(agentId);
            return;
        }

        _attemptRevival(agentId, slot, precompileInput);
    }

    // =========================================================================
    // Views
    // =========================================================================

    function hasActionableAgents() external view returns (bool) {
        uint256 len = _trackedAgentIds.length;
        for (uint256 i = 0; i < len; i++) {
            SlotAssignment storage slot = _assignments[_trackedAgentIds[i]];
            if (_needsCheckAndRevive(slot)) {
                return true;
            }
        }

        return false;
    }

    function heartbeatIntervalBlocks() external view returns (uint64) {
        return defaultTimeout / _effectiveHeartbeatIntervalDivisor();
    }

    // =========================================================================
    // Admin
    // =========================================================================

    function setDefaultTimeout(uint64 timeout) external onlyOwner {
        require(timeout >= 10 && timeout <= 100_000, "timeout out of bounds");
        require(timeout / _effectiveHeartbeatIntervalDivisor() > 0, "timeout below interval divisor");
        defaultTimeout = timeout;
    }

    function setHeartbeatIntervalDivisor(uint64 divisor) external onlyOwner {
        require(divisor >= 1 && divisor <= 1000, "divisor out of bounds");
        require(defaultTimeout / divisor > 0, "divisor too large for timeout");
        heartbeatIntervalDivisor = divisor;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setRevivalCooldown(uint64 cooldown) external onlyOwner {
        revivalCooldown = cooldown;
    }

    function adminRemoveAgent(uint256 agentId) external onlyOwner {
        require(_trackedAgentIndexPlusOne[agentId] != 0, "not tracked");
        emit SlotRemoved(agentId, _assignments[agentId].agentAddress, "admin");
        _removeAgent(agentId);
    }

    // =========================================================================
    // Internal — Step 3
    // =========================================================================

    function _checkAndReviveBatch() internal {
        require(msg.sender == SYSTEM_SENDER, "only system");

        uint256 len = _trackedAgentIds.length;
        if (len == 0) {
            nextCheckIndex = 0;
            return;
        }

        uint256 toProcess = MAX_CHECK_BATCH;
        if (toProcess > len) {
            toProcess = len;
        }

        uint256 i = nextCheckIndex;
        if (i >= len) {
            i = 0;
        }

        uint256 processed = 0;
        while (processed < toProcess && _trackedAgentIds.length > 0) {
            if (i >= _trackedAgentIds.length) {
                i = 0;
            }

            uint256 agentId = _trackedAgentIds[i];
            SlotAssignment storage slot = _assignments[agentId];
            bool removed = false;

            if (_isBelowMinimumBalance(slot)) {
                emit SlotRemoved(agentId, slot.agentAddress, "below minimum balance");
                _removeAgent(agentId);
                removed = true;
            } else if (_isActiveExpired(slot)) {
                _vacateSlot(agentId, "timeout", RevivalStatus.FAILED);
                emit SlotRevivalQueued(agentId, slot.agentAddress, slot.lastHeartbeat, uint64(block.number));
            } else if (_isRevivalCooldownElapsed(slot)) {
                slot.revivalStatus = RevivalStatus.FAILED;
                slot.cooldownEnd = 0;
                emit SlotRevivalFailed(agentId, slot.agentAddress, "revival cooldown elapsed");
                if (revivalAttempts[agentId] >= MAX_REVIVAL_ATTEMPTS) {
                    emit SlotRemoved(agentId, slot.agentAddress, "revival attempts exceeded");
                    _removeAgent(agentId);
                    removed = true;
                }
            }

            if (!removed) {
                unchecked {
                    ++i;
                }
            }

            unchecked {
                ++processed;
            }
        }

        if (_trackedAgentIds.length == 0) {
            nextCheckIndex = 0;
        } else {
            if (i >= _trackedAgentIds.length) {
                i = 0;
            }
            nextCheckIndex = i;
        }
    }

    function _vacateSlot(uint256 agentId, string memory reason, RevivalStatus revivalStatus) internal {
        SlotAssignment storage slot = _assignments[agentId];
        require(slot.state == SlotState.ACTIVE, "slot not active");

        address agentAddr = slot.agentAddress;
        slotNonce[agentId] += 1;

        slot.state = SlotState.VACANT;
        slot.revivalStatus = revivalStatus;
        slot.boundHolderKey = bytes32(0);
        slot.cooldownEnd = 0;

        emit SlotVacated(agentId, agentAddr, reason);
    }

    function _isExpired(SlotAssignment storage slot) internal view returns (bool) {
        return block.number > uint256(slot.lastHeartbeat) + uint256(slot.heartbeatTimeout);
    }

    function _isBelowMinimumBalance(SlotAssignment storage slot) internal view returns (bool) {
        return slot.agentAddress.balance < MIN_BALANCE;
    }

    function _isActiveExpired(SlotAssignment storage slot) internal view returns (bool) {
        return slot.state == SlotState.ACTIVE && _isExpired(slot);
    }

    function _isPendingRevival(SlotAssignment storage slot) internal view returns (bool) {
        return slot.state == SlotState.VACANT && slot.revivalStatus == RevivalStatus.FAILED;
    }

    function _isRevivalCooldownElapsed(SlotAssignment storage slot) internal view returns (bool) {
        return slot.revivalStatus == RevivalStatus.REVIVING && block.number > slot.cooldownEnd;
    }

    function _needsCheckAndRevive(SlotAssignment storage slot) internal view returns (bool) {
        return _isBelowMinimumBalance(slot) || _isActiveExpired(slot) || _isRevivalCooldownElapsed(slot);
    }

    function _clearPreviousAssignmentForClaim(uint256 agentId, SlotAssignment storage slot, address replacementAgent)
        internal
    {
        bool hasPreviousAssignment = slot.agentAddress != address(0) || slot.boundExecutor != address(0)
            || bytes(slot.latestManifestCID).length != 0 || slot.encryptedDAConfig.length != 0;
        if (!hasPreviousAssignment) {
            return;
        }

        address previousAgent = slot.agentAddress;
        string memory reason = slot.state == SlotState.ACTIVE ? "timeout" : "claim";
        if (slot.state == SlotState.ACTIVE) {
            emit SlotVacated(agentId, previousAgent, reason);
        }
        emit SlotReplaced(
            agentId,
            previousAgent,
            replacementAgent,
            slot.boundExecutor,
            slot.lastHeartbeat,
            uint64(block.number),
            slot.latestManifestCID,
            slot.encryptedDAConfig,
            reason
        );

        _wipeDynamicBytes(slot.latestManifestCID);
        _wipeDynamicBytes(slot.encryptedDAConfig);
        slot.state = SlotState.VACANT;
        slot.revivalStatus = RevivalStatus.NONE;
        slot.agentAddress = address(0);
        slot.boundHolderKey = bytes32(0);
        slot.boundExecutor = address(0);
        slot.lastHeartbeat = 0;
        slot.heartbeatTimeout = 0;
        slot.cooldownEnd = 0;
        slot.latestManifestCID = "";
        slot.encryptedDAConfig = "";
    }

    // =========================================================================
    // Internal
    // =========================================================================

    function _trackAgentId(uint256 agentId) internal {
        if (_trackedAgentIndexPlusOne[agentId] != 0) {
            return;
        }

        require(_trackedAgentIds.length < MAX_TRACKED_AGENTS, "max agents reached");
        _trackedAgentIds.push(agentId);
        _trackedAgentIndexPlusOne[agentId] = _trackedAgentIds.length;
    }

    function _removeAgent(uint256 agentId) internal {
        uint256 indexPlusOne = _trackedAgentIndexPlusOne[agentId];
        if (indexPlusOne == 0) {
            return;
        }

        uint256 idx = indexPlusOne - 1;
        uint256 lastIdx = _trackedAgentIds.length - 1;
        if (idx != lastIdx) {
            uint256 lastAgentId = _trackedAgentIds[lastIdx];
            _trackedAgentIds[idx] = lastAgentId;
            _trackedAgentIndexPlusOne[lastAgentId] = idx + 1;
        }
        _trackedAgentIds.pop();
        delete _trackedAgentIndexPlusOne[agentId];

        _wipeDynamicBytes(_assignments[agentId].latestManifestCID);
        _wipeDynamicBytes(_assignments[agentId].encryptedDAConfig);
        delete _assignments[agentId];
        delete revivalAttempts[agentId];
        if (_trackedAgentIds.length == 0) {
            nextCheckIndex = 0;
        } else if (nextCheckIndex >= _trackedAgentIds.length) {
            nextCheckIndex = 0;
        }
    }

    /// @dev Zero all child storage slots of a dynamic bytes/string field before struct delete.
    ///      Solidity's `delete` only zeroes the head slot (setting length to 0) but leaves
    ///      child content slots at keccak256(headSlot)+i non-zero for values > 31 bytes.
    function _wipeDynamicBytes(bytes storage s) internal {
        uint256 len = s.length;
        if (len <= 31) {
            return;
        }

        uint256 valueSlot;
        assembly {
            valueSlot := s.slot
        }

        bytes32 contentBase;
        assembly {
            mstore(0x00, valueSlot)
            contentBase := keccak256(0x00, 0x20)
        }

        uint256 words = (len + 31) >> 5;
        for (uint256 i = 0; i < words;) {
            assembly {
                sstore(add(contentBase, i), 0)
            }
            unchecked {
                ++i;
            }
        }
    }

    function _wipeDynamicBytes(string storage s) internal {
        _wipeDynamicBytes(bytes(s));
    }

    function _attemptRevival(uint256 agentId, SlotAssignment storage slot, bytes calldata precompileInput) internal {
        revivalAttempts[agentId] += 1;

        address executor = _extractExecutorFromInput(precompileInput);
        bytes memory precompilePayload = precompileInput;
        _applyRevivalPrecompileCall(agentId, slot, executor, precompilePayload);
    }

    function _extractExecutorFromInput(bytes calldata precompileInput) internal pure returns (address executor) {
        if (precompileInput.length < 32) {
            return address(0);
        }

        assembly {
            executor := calldataload(precompileInput.offset)
        }
    }

    function _applyRevivalPrecompileCall(
        uint256 agentId,
        SlotAssignment storage slot,
        address executor,
        bytes memory precompileInput
    ) internal {
        address previousExecutor = slot.boundExecutor;
        slot.boundExecutor = executor;
        slot.revivalStatus = RevivalStatus.REVIVING;
        slot.cooldownEnd = uint64(block.number) + revivalCooldown;

        emit SlotRevivalInitiated(agentId, slot.agentAddress, slot.latestManifestCID, executor, slot.cooldownEnd);

        // Fire-and-forget: revival success is proven by a later fresh claim, not
        // by this low-level call result. A synchronous call failure still counts
        // as an attempt and is failed by the generic cooldown path.
        (bool success,) = PERSISTENT_AGENT_PRECOMPILE.call(precompileInput);
        if (!success && previousExecutor != executor) {
            slot.boundExecutor = previousExecutor;
        }
    }

    function _isRegisteredExecutor(address addr) internal view returns (bool) {
        try TEE_REGISTRY.getValidService(addr) returns (ITEEServiceRegistry.TEEServiceContext memory ctx) {
            return ctx.isValid;
        } catch {
            return false;
        }
    }

    function _claimDigest(uint256 agentId, bytes32 holderKey, address executor, address agent, uint256 nonce)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked("claim", block.chainid, address(this), agentId, holderKey, executor, agent, nonce)
        );
    }

    function _slotHeartbeatDigest(uint256 agentId, string calldata manifestCID, uint256 nonce)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encodePacked("slot_heartbeat", block.chainid, address(this), agentId, manifestCID, nonce));
    }

    function _effectiveHeartbeatIntervalDivisor() internal view returns (uint64) {
        return heartbeatIntervalDivisor == 0 ? 2 : heartbeatIntervalDivisor;
    }

    uint256[35] private __gap;
}
