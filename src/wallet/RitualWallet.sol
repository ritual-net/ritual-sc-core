// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.28;

import {IRitualWallet} from "./IRitualWallet.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/*//////////////////////////////////////////////////////////////
                            PUBLIC STRUCTS
//////////////////////////////////////////////////////////////*/

/// @title RitualWallet
/// @notice Wallet for scheduled JIT debits and async per-job escrow.
/// @dev Payment V2 is a fresh-deployment-only storage layout. It is not
///      backwards-compatible with prior RitualWallet proxy storage.
contract RitualWallet is IRitualWallet, Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    /// @notice Maximum number of caller-supplied escrow cleanup hints accepted during reservation.
    uint256 public constant MAX_EXPIRED_SWEEP = 8;

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLE
    //////////////////////////////////////////////////////////////*/

    /// @notice Authorized scheduler contract
    address public immutable scheduler;

    /// @notice AsyncDelivery contract authorized for protocol wallet operations.
    /// @dev Escrow settlement is restricted by `onlyAuthorized`, which also includes Scheduler and AsyncJobTracker.
    address public immutable asyncDelivery;

    /// @notice AsyncJobTracker contract — sole authorized caller for async escrow reservation
    address public immutable asyncJobTracker;

    /*//////////////////////////////////////////////////////////////
                                MUTABLE
    //////////////////////////////////////////////////////////////*/

    /// @notice User available balances.
    mapping(address => uint256) private _balances;

    /// @inheritdoc IRitualWallet
    mapping(address => uint256) public reservedBalance;

    /// @inheritdoc IRitualWallet
    mapping(address => mapping(address => uint256)) public allowance;

    /// @notice Per-job escrow state.
    /// @dev Lifecycle is presence-based: an absent record is reusable; a present record is
    ///      live through its expiry block and reclaimable after it. Expiry and final
    ///      settlement both delete the record. Protocol nonce/bitmap state prevents replay.
    mapping(bytes32 => Escrow) private _escrows;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Restrict access to scheduler contract only
    modifier onlyScheduler() {
        if (msg.sender != scheduler) {
            revert UnauthorizedScheduler();
        }
        _;
    }

    /// @notice Restrict access to scheduler or async delivery contracts
    modifier onlySchedulerOrAsyncDelivery() {
        if (msg.sender != scheduler && msg.sender != asyncDelivery) {
            revert UnauthorizedCaller();
        }
        _;
    }

    /// @notice Restrict access to protocol contracts that can reserve or settle escrow.
    modifier onlyAuthorized() {
        if (msg.sender != scheduler && msg.sender != asyncDelivery && msg.sender != asyncJobTracker) {
            revert UnauthorizedCaller();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _scheduler, address _asyncDelivery, address _asyncJobTracker) {
        _disableInitializers();
        scheduler = _scheduler;
        asyncDelivery = _asyncDelivery;
        asyncJobTracker = _asyncJobTracker;
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize the RitualWallet with an owner for upgrade authorization
    /// @param _owner The address that will own the contract (for upgrade authorization only)
    function initialize(address _owner) external initializer {
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
    }

    /// @notice Restricts upgrades to owner only
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRitualWallet
    function availableBalance(address account) external view returns (uint256) {
        return _balances[account];
    }

    /// @inheritdoc IRitualWallet
    function deposit() external payable {
        _depositFor(msg.sender);
    }

    /// @inheritdoc IRitualWallet
    function depositFor(address account) external payable {
        _depositFor(account);
    }

    /// @notice Internal deposit logic
    /// @param account Address to deposit funds for
    function _depositFor(address account) internal {
        if (msg.value == 0) {
            revert InsufficientBalance();
        }

        _balances[account] += msg.value;

        emit Deposit(account, msg.value);
    }

    /// @inheritdoc IRitualWallet
    function withdraw(uint256 amount) external nonReentrant {
        bytes32[] memory expiredEscrows = new bytes32[](0);
        _withdraw(msg.sender, amount, expiredEscrows);
    }

    /// @inheritdoc IRitualWallet
    function withdraw(uint256 amount, bytes32[] calldata expiredEscrows) external nonReentrant {
        _withdraw(msg.sender, amount, expiredEscrows);
    }

    function _withdraw(address account, uint256 amount, bytes32[] memory expiredEscrows) internal {
        _releaseOwned(account, expiredEscrows);

        if (_balances[account] < amount) {
            revert InsufficientBalance();
        }

        _balances[account] -= amount;

        (bool success,) = payable(account).call{value: amount}("");
        if (!success) {
            revert TransferFailed();
        }

        emit Withdrawal(account, amount);
    }

    /// @inheritdoc IRitualWallet
    function escrows(bytes32 escrowId) external view returns (Escrow memory) {
        return _escrows[escrowId];
    }

    /// @inheritdoc IRitualWallet
    function approve(address caller, uint256 amount) external {
        allowance[msg.sender][caller] = amount;
        emit AllowanceUpdated(msg.sender, caller, amount);
    }

    /// @inheritdoc IRitualWallet
    function increaseAllowance(address caller, uint256 amount) external {
        uint256 newAllowance = allowance[msg.sender][caller] + amount;
        allowance[msg.sender][caller] = newAllowance;
        emit AllowanceUpdated(msg.sender, caller, newAllowance);
    }

    /// @inheritdoc IRitualWallet
    function decreaseAllowance(address caller, uint256 amount) external {
        uint256 currentAllowance = allowance[msg.sender][caller];
        if (currentAllowance < amount) {
            revert InsufficientAllowance();
        }
        uint256 newAllowance = currentAllowance - amount;
        allowance[msg.sender][caller] = newAllowance;
        emit AllowanceUpdated(msg.sender, caller, newAllowance);
    }

    /// @inheritdoc IRitualWallet
    /// @dev Protocol trust boundary: these reserve paths are callable only by authorized
    ///      protocol contracts. The wallet intentionally treats `caller` as protocol-supplied
    ///      context and only enforces sponsor balance plus sponsor-to-caller allowance when
    ///      they differ. Scheduler and async commitment/Reth validation own caller
    ///      authentication and sponsor/caller binding before invoking the wallet.
    function reserveFrom(
        address sponsor,
        address caller,
        bytes32 escrowId,
        uint256 amount,
        uint64 expiryBlock,
        bytes32[] calldata expiredEscrows
    ) external onlyAuthorized {
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
        // The target is handled independently so same-ID recommit never depends on hints.
        _release(escrowId);

        uint256 expiredEscrowsLength = expiredEscrows.length;
        if (expiredEscrowsLength > MAX_EXPIRED_SWEEP) {
            revert TooManyExpiredEscrows();
        }
        for (uint256 i; i < expiredEscrowsLength;) {
            bytes32 expiredEscrowId = expiredEscrows[i];
            if (_escrows[expiredEscrowId].sponsor == sponsor) {
                _release(expiredEscrowId);
            }
            unchecked {
                ++i;
            }
        }

        if (_exists(escrowId)) {
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

        _escrows[escrowId] = Escrow({sponsor: sponsor, reserved: amount, paid: 0, expiryBlock: expiryBlock});

        emit EscrowReserved(escrowId, sponsor, amount, expiryBlock);
    }

    /// @inheritdoc IRitualWallet
    function settle(bytes32 escrowId, Payment[] calldata payments, uint256 refund, uint64 newExpiry, bool close)
        external
        onlyAuthorized
        nonReentrant
    {
        _settle(escrowId, payments, refund, newExpiry, close);
    }

    /// @inheritdoc IRitualWallet
    function expire(bytes32 escrowId) external {
        if (!_release(escrowId)) {
            revert EscrowNotExpired();
        }
    }

    /// @inheritdoc IRitualWallet
    function expireMany(bytes32[] calldata escrowIds) external {
        uint256 escrowIdsLength = escrowIds.length;
        for (uint256 i; i < escrowIdsLength;) {
            _release(escrowIds[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc IRitualWallet
    /// @dev Scheduled debits are scheduler-only. The wallet does not independently
    ///      authenticate `caller`; Scheduler binds it to the original scheduled call target
    ///      and passes that value here so sponsor==caller can skip allowance by design.
    function deductScheduledExecutionFeesFrom(
        address sponsor,
        address caller,
        uint256 effectiveFeePerGas,
        uint256 gasLimit,
        uint256 value,
        uint256 fixedFee,
        uint256 callId
    ) external onlyScheduler nonReentrant returns (uint256 actualFee) {
        return _deductScheduledExecutionFees(sponsor, caller, effectiveFeePerGas, gasLimit, value, fixedFee, callId);
    }

    function _deductScheduledExecutionFees(
        address sponsor,
        address caller,
        uint256 effectiveFeePerGas,
        uint256 gasLimit,
        uint256 value,
        uint256 fixedFee,
        uint256 callId
    ) internal returns (uint256 actualFee) {
        actualFee = (effectiveFeePerGas * gasLimit) + value + fixedFee;

        // Return 0 if insufficient balance - don't transfer anything
        if (_balances[sponsor] < actualFee) {
            return 0;
        }

        if (sponsor != caller) {
            uint256 currentAllowance = allowance[sponsor][caller];
            if (currentAllowance < actualFee) {
                return 0;
            }
            if (currentAllowance != type(uint256).max) {
                allowance[sponsor][caller] = currentAllowance - actualFee;
            }
        }

        // Deduct from sponsor's internal balance
        _balances[sponsor] -= actualFee;

        // Transfer actual ETH to the Scheduler contract
        (bool success,) = payable(msg.sender).call{value: actualFee}("");
        if (!success) {
            revert TransferFailed();
        }

        emit FeeDeduction(sponsor, actualFee, callId);

        return actualFee;
    }

    /// @inheritdoc IRitualWallet
    function refundGas(address sponsor, uint256 refundAmount, uint256 callId)
        external
        payable
        onlySchedulerOrAsyncDelivery
    {
        if (msg.value != refundAmount) {
            revert RefundValueMismatch(refundAmount, msg.value);
        }

        _balances[sponsor] += refundAmount;
        emit GasRefund(sponsor, refundAmount, callId);
    }

    /// @inheritdoc IRitualWallet
    function creditProposer(address proposer, uint256 callId) external payable onlySchedulerOrAsyncDelivery {
        if (msg.value == 0) {
            return;
        }

        _balances[proposer] += msg.value;
        emit ProposerPayment(proposer, msg.value, callId);
    }

    function _settle(bytes32 escrowId, Payment[] memory payments, uint256 refund, uint64 newExpiry, bool close)
        internal
    {
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.sponsor == address(0)) {
            revert EscrowNotActive();
        }
        if (block.number > escrow.expiryBlock) {
            revert InvalidEscrowExpiry();
        }

        uint256 paymentsLength = payments.length;
        uint256 totalPayments;
        for (uint256 i; i < paymentsLength;) {
            totalPayments += payments[i].amount;
            unchecked {
                ++i;
            }
        }

        uint256 totalDebit = totalPayments + refund;
        if (totalDebit > escrow.reserved) {
            revert SettlementExceedsReserve();
        }

        address sponsor = escrow.sponsor;
        escrow.reserved -= totalDebit;
        escrow.paid += totalPayments;
        reservedBalance[sponsor] -= totalDebit;
        if (refund > 0) {
            _balances[sponsor] += refund;
        }

        uint256 closedRefund;
        if (close) {
            closedRefund = escrow.reserved;
            if (closedRefund > 0) {
                reservedBalance[sponsor] -= closedRefund;
                _balances[sponsor] += closedRefund;
            }
            delete _escrows[escrowId];
        } else {
            if (newExpiry != 0) {
                if (newExpiry <= block.number) {
                    revert InvalidEscrowExpiry();
                }
                escrow.expiryBlock = newExpiry;
            }
        }

        for (uint256 i; i < paymentsLength;) {
            uint256 amount = payments[i].amount;
            if (amount != 0) {
                address payable recipient = payments[i].to;
                _balances[recipient] += amount;
                emit EscrowPaymentCredited(escrowId, recipient, amount);
            }
            unchecked {
                ++i;
            }
        }

        emit EscrowSettled(escrowId, sponsor, totalPayments, refund + closedRefund, close);
    }

    function _exists(bytes32 escrowId) internal view returns (bool) {
        return _escrows[escrowId].sponsor != address(0);
    }

    /// @dev Release an escrow only when present and strictly past its deadline.
    function _release(bytes32 escrowId) internal returns (bool) {
        Escrow storage escrow = _escrows[escrowId];
        if (escrow.sponsor == address(0) || block.number <= escrow.expiryBlock) {
            return false;
        }

        address sponsor = escrow.sponsor;
        uint256 remaining = escrow.reserved;
        if (remaining > 0) {
            reservedBalance[sponsor] -= remaining;
            _balances[sponsor] += remaining;
        }

        emit EscrowExpired(escrowId, sponsor, remaining);
        delete _escrows[escrowId];
        return true;
    }

    function _releaseOwned(address sponsor, bytes32[] memory escrowIds) internal {
        uint256 escrowIdsLength = escrowIds.length;
        for (uint256 i; i < escrowIdsLength;) {
            bytes32 escrowId = escrowIds[i];
            if (_escrows[escrowId].sponsor == sponsor) {
                _release(escrowId);
            }
            unchecked {
                ++i;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                FALLBACK
    //////////////////////////////////////////////////////////////*/

    /// @notice Allow direct ETH deposits.
    receive() external payable {
        _balances[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    /*//////////////////////////////////////////////////////////////
                            STORAGE GAP
    //////////////////////////////////////////////////////////////*/

    /// @dev Reserved storage space for future upgrades
    uint256[44] private __gap;
}
