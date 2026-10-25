// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.28;

import {IAgentIdentityRegistry} from "../../src/identity/IAgentIdentityRegistry.sol";

/// @notice Minimal identity registry used by AgentHeartbeat tests.
contract MockAgentIdentityRegistry is IAgentIdentityRegistry {
    uint256 private _nextAgentId;
    mapping(uint256 => AgentIdentity) private _identities;

    function allocateAgentId(address owner) external returns (uint256 agentId) {
        agentId = ++_nextAgentId;
        _identities[agentId] = AgentIdentity({agentId: agentId, owner: owner});
    }

    function getIdentity(uint256 agentId) external view returns (AgentIdentity memory) {
        AgentIdentity memory identity = _identities[agentId];
        require(identity.owner != address(0), "identity not found");
        return identity;
    }

    function ownerOf(uint256 agentId) external view returns (address) {
        address identityOwner = _identities[agentId].owner;
        require(identityOwner != address(0), "identity not found");
        return identityOwner;
    }
}
