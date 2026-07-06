// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.28;

/// @title IAgentIdentityRegistry
/// @notice Minimal read surface for contracts that depend on canonical agent identity.
interface IAgentIdentityRegistry {
    struct AgentIdentity {
        uint256 agentId;
        address owner;
    }

    function getIdentity(uint256 agentId) external view returns (AgentIdentity memory);

    function ownerOf(uint256 agentId) external view returns (address);
}
