// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.28;

import {IRitualWallet} from "../src/wallet/IRitualWallet.sol";

/// @title MockRitualWallet
/// @notice Mock implementation of RitualWallet for testing
contract MockRitualWallet is IRitualWallet {
    uint256 public constant MAX_EXPIRED_SWEEP = 8;

    mapping(address => uint256) private _balances;
    mapping(address => uint256) public reservedBalance;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(bytes32 => Escrow) private _escrows;

    address public scheduler;
    address public asyncDelivery;
    bool public failRefund;
    bool public failDeposit;
    bool private transferFullScheduledFee;

    modifier onlyScheduler() {
        require(msg.sender == scheduler, "Only scheduler");
        _;
    }

    modifier onlySchedulerOrAsyncDelivery() {
        require(msg.sender == scheduler || msg.sender == asyncDelivery, "Only scheduler or async delivery");
        _;
    }

    constructor(address _scheduler) {
        scheduler = _scheduler;
    }

    function setScheduler(address _scheduler) external {
        scheduler = _scheduler;
    }

    function setAsyncDelivery(address _asyncDelivery) external {
        asyncDelivery = _asyncDelivery;
    }

    function setTransferFullScheduledFee(bool enabled) external {
        transferFullScheduledFee = enabled;
    }

    /// @notice Test hook: force refundGas to revert, simulating a misconfigured/upgraded wallet.
    function setFailRefund(bool _failRefund) external {
        failRefund = _failRefund;
    }

    function setFailDeposit(bool _failDeposit) external {
        failDeposit = _failDeposit;
    }

    function deposit() external payable {
        _balances[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    function depositFor(address user) external payable {
        require(!failDeposit, "deposit failed");
        _balances[user] += msg.value;
        emit Deposit(user, msg.value);
    }

    function availableBalance(address account) external view returns (uint256) {
        return _balances[account];
    }

    function escrows(bytes32 escrowId) external view returns (Escrow memory) {
        return _escrows[escrowId];
    }

    function canCoverExecution(address user, uint256 maxFeePerGas, uint256 gasLimit, uint256 value)
        external
        view
        returns (bool)
    {
        uint256 totalCost = (maxFeePerGas * gasLimit) + value;
        return _balances[user] >= totalCost;
    }

    function withdraw(uint256 amount) external {
        require(_balances[msg.sender] >= amount, "Insufficient balance");

        _balances[msg.sender] -= amount;
        (bool sent,) = payable(msg.sender).call{value: amount}("");
        require(sent, "transfer failed");
        emit Withdrawal(msg.sender, amount);
    }

    function withdraw(uint256 amount, bytes32[] calldata expiredEscrows) external {
        for (uint256 i; i < expiredEscrows.length; i++) {
            if (_escrows[expiredEscrows[i]].sponsor == msg.sender) {
                _release(expiredEscrows[i]);
            }
        }
        require(_balances[msg.sender] >= amount, "Insufficient balance");
        _balances[msg.sender] -= amount;
        (bool sent,) = payable(msg.sender).call{value: amount}("");
        require(sent, "transfer failed");
        emit Withdrawal(msg.sender, amount);
    }

    function approve(address caller, uint256 amount) external {
        allowance[msg.sender][caller] = amount;
        emit AllowanceUpdated(msg.sender, caller, amount);
    }

    function increaseAllowance(address caller, uint256 amount) external {
        allowance[msg.sender][caller] += amount;
        emit AllowanceUpdated(msg.sender, caller, allowance[msg.sender][caller]);
    }

    function decreaseAllowance(address caller, uint256 amount) external {
        require(allowance[msg.sender][caller] >= amount, "insufficient allowance");
        allowance[msg.sender][caller] -= amount;
        emit AllowanceUpdated(msg.sender, caller, allowance[msg.sender][caller]);
    }

    function reserveFrom(
        address sponsor,
        address caller,
        bytes32 escrowId,
        uint256 amount,
        uint64 expiryBlock,
        bytes32[] calldata expiredEscrows
    ) external {
        _reserve(sponsor, caller, escrowId, amount, expiryBlock, expiredEscrows);
    }

    function _reserve(
        address sponsor,
        address caller,
        bytes32 escrowId,
        uint256 amount,
        uint64 expiryBlock,
        bytes32[] calldata expiredEscrows
    ) internal {
        _release(escrowId);
        if (expiredEscrows.length > MAX_EXPIRED_SWEEP) {
            revert TooManyExpiredEscrows();
        }
        for (uint256 i; i < expiredEscrows.length; i++) {
            if (_escrows[expiredEscrows[i]].sponsor == sponsor) {
                _release(expiredEscrows[i]);
            }
        }
        if (_escrows[escrowId].sponsor != address(0)) {
            revert EscrowAlreadyExists();
        }
        if (expiryBlock <= block.number) {
            revert InvalidEscrowExpiry();
        }

        uint256 currentAllowance;
        if (sponsor != caller) {
            currentAllowance = allowance[sponsor][caller];
            if (currentAllowance < amount) {
                revert InsufficientAllowance();
            }
        }
        if (_balances[sponsor] < amount) {
            revert InsufficientBalance();
        }
        if (sponsor != caller && currentAllowance != type(uint256).max) {
            allowance[sponsor][caller] = currentAllowance - amount;
        }

        _balances[sponsor] -= amount;
        reservedBalance[sponsor] += amount;
        _escrows[escrowId] = Escrow(sponsor, amount, 0, expiryBlock);
        emit EscrowReserved(escrowId, sponsor, amount, expiryBlock);
    }

    function settle(bytes32 escrowId, Payment[] calldata payments, uint256 refund, uint64 newExpiry, bool close)
        external
    {
        Escrow storage escrow = _escrows[escrowId];
        require(escrow.sponsor != address(0), "not active");
        require(block.number <= escrow.expiryBlock, "expired");
        uint256 total;
        for (uint256 i; i < payments.length; i++) {
            total += payments[i].amount;
        }
        require(total + refund <= escrow.reserved, "too much");
        escrow.reserved -= total + refund;
        escrow.paid += total;
        address sponsor = escrow.sponsor;
        reservedBalance[sponsor] -= total + refund;
        _balances[sponsor] += refund;
        uint256 closedRefund;
        if (close) {
            closedRefund = escrow.reserved;
            reservedBalance[sponsor] -= closedRefund;
            _balances[sponsor] += closedRefund;
            delete _escrows[escrowId];
        } else if (newExpiry != 0) {
            require(newExpiry > block.number, "bad expiry");
            escrow.expiryBlock = newExpiry;
        }
        for (uint256 i; i < payments.length; i++) {
            if (payments[i].amount > 0) {
                _balances[payments[i].to] += payments[i].amount;
                emit EscrowPaymentCredited(escrowId, payments[i].to, payments[i].amount);
            }
        }
        emit EscrowSettled(escrowId, sponsor, total, refund + closedRefund, close);
    }

    function expire(bytes32 escrowId) external {
        if (!_release(escrowId)) {
            revert EscrowNotExpired();
        }
    }

    function expireMany(bytes32[] calldata escrowIds) external {
        for (uint256 i; i < escrowIds.length; i++) {
            _release(escrowIds[i]);
        }
    }

    function deductScheduledExecutionFeesFrom(
        address sponsor,
        address caller,
        uint256 maxFeePerGas,
        uint256 gasLimit,
        uint256 value,
        uint256 fixedFee,
        uint256 callId
    ) external onlyScheduler returns (uint256 actualFee) {
        return _deductScheduledExecutionFees(sponsor, caller, maxFeePerGas, gasLimit, value, fixedFee, callId);
    }

    function _deductScheduledExecutionFees(
        address sponsor,
        address caller,
        uint256 maxFeePerGas,
        uint256 gasLimit,
        uint256 value,
        uint256 fixedFee,
        uint256 callId
    ) internal returns (uint256 actualFee) {
        uint256 totalCost = (maxFeePerGas * gasLimit) + value + fixedFee;

        if (_balances[sponsor] < totalCost) {
            return 0; // Insufficient funds
        }

        if (sponsor != caller) {
            if (allowance[sponsor][caller] < totalCost) {
                return 0;
            }
            if (allowance[sponsor][caller] != type(uint256).max) {
                allowance[sponsor][caller] -= totalCost;
            }
        }

        _balances[sponsor] -= totalCost;
        actualFee = totalCost;

        uint256 transferAmount = transferFullScheduledFee ? totalCost : value;
        if (transferAmount > 0) {
            (bool sent,) = payable(msg.sender).call{value: transferAmount}("");
            require(sent, "transfer failed");
        }

        emit FeeDeduction(sponsor, actualFee, callId);
    }

    function refundGas(address sponsor, uint256 refundAmount, uint256 callId)
        external
        payable
        onlySchedulerOrAsyncDelivery
    {
        require(!failRefund, "refund failed");
        // In the mock, we just credit the sponsor's balance
        // The scheduler may or may not send ETH with the call
        if (msg.value > 0) {
            _balances[sponsor] += msg.value;
        } else {
            _balances[sponsor] += refundAmount;
        }
        emit GasRefund(sponsor, refundAmount, callId);
    }

    // Helper function for testing
    function setBalance(address user, uint256 amount) external {
        _balances[user] = amount;
    }

    function _release(bytes32 escrowId) internal returns (bool) {
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.sponsor == address(0) || block.number <= escrow.expiryBlock) {
            return false;
        }
        address sponsor = escrow.sponsor;
        uint256 remaining = escrow.reserved;
        reservedBalance[sponsor] -= remaining;
        _balances[sponsor] += remaining;
        emit EscrowExpired(escrowId, sponsor, remaining);
        delete _escrows[escrowId];
        return true;
    }

    receive() external payable {
        _balances[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }
}
