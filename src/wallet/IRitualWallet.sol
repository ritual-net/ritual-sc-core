// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.28;

/*//////////////////////////////////////////////////////////////
                            PUBLIC STRUCTS
//////////////////////////////////////////////////////////////*/

/// @title IRitualWallet
/// @notice Interface for ritual wallet escrow system
interface IRitualWallet {
    /// @dev Lifecycle is derived from presence and `block.number`: absent is reusable,
    ///      present through `expiryBlock` is live, and present after it is reclaimable.
    ///      Expiry and final settlement delete the record.
    struct Escrow {
        address sponsor;
        uint256 reserved;
        uint256 paid;
        uint64 expiryBlock;
    }

    struct Payment {
        address payable to;
        uint256 amount;
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when an account deposits funds
    event Deposit(address indexed account, uint256 amount);

    /// @notice Emitted when an account withdraws funds
    event Withdrawal(address indexed account, uint256 amount);

    /// @notice Emitted when scheduler deducts fees from a sponsor
    event FeeDeduction(address indexed sponsor, uint256 amount, uint256 callId);

    /// @notice Emitted when unused execution gas is refunded to the operation sponsor.
    event GasRefund(address indexed sponsor, uint256 amount, uint256 callId);

    /// @notice Emitted when a sponsor-to-caller allowance is explicitly updated.
    event AllowanceUpdated(address indexed sponsor, address indexed caller, uint256 amount);

    /// @notice Emitted when an async escrow is reserved.
    event EscrowReserved(bytes32 indexed escrowId, address indexed sponsor, uint256 amount, uint64 expiryBlock);

    /// @notice Emitted when an escrow is settled.
    event EscrowSettled(bytes32 indexed escrowId, address indexed sponsor, uint256 paid, uint256 refund, bool closed);

    /// @notice Emitted when an escrow payment is credited to a recipient's available balance.
    event EscrowPaymentCredited(bytes32 indexed escrowId, address indexed recipient, uint256 amount);

    /// @notice Emitted when an expired escrow is returned to available balance.
    event EscrowExpired(bytes32 indexed escrowId, address indexed sponsor, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when an account has insufficient available balance
    error InsufficientBalance();

    /// @notice Thrown when caller is not authorized scheduler
    error UnauthorizedScheduler();

    /// @notice Thrown when transfer fails
    error TransferFailed();

    /// @notice Thrown when caller is not authorized for protocol wallet APIs.
    error UnauthorizedCaller();

    /// @notice Thrown when an escrow ID is already used.
    error EscrowAlreadyExists();

    /// @notice Thrown when an escrow is not active.
    error EscrowNotActive();

    /// @notice Thrown when escrow expiry is invalid.
    error InvalidEscrowExpiry();

    /// @notice Thrown when an escrow is absent or has not passed its expiry block.
    error EscrowNotExpired();

    /// @notice Thrown when a reserve request supplies more than the bounded cleanup limit.
    error TooManyExpiredEscrows();

    /// @notice Thrown when allowance is insufficient.
    error InsufficientAllowance();

    /// @notice Thrown when settlement exceeds remaining reserve.
    error SettlementExceedsReserve();

    /// @notice Thrown when refundGas receives a value different from the declared refund amount.
    error RefundValueMismatch(uint256 expected, uint256 actual);

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get account's available balance.
    function availableBalance(address account) external view returns (uint256);

    /// @notice Get account's reserved balance.
    function reservedBalance(address account) external view returns (uint256);

    /// @notice Get allowance from sponsor to caller.
    function allowance(address sponsor, address caller) external view returns (uint256);

    /// @notice Get escrow by ID.
    function escrows(bytes32 escrowId) external view returns (Escrow memory);

    /// @notice Deposit funds.
    function deposit() external payable;

    /// @notice Deposit funds for another account.
    function depositFor(address account) external payable;

    /// @notice Withdraw available funds
    /// @param amount Amount to withdraw in wei
    function withdraw(uint256 amount) external;

    /// @notice Withdraw available funds after sweeping caller-supplied expired escrows.
    function withdraw(uint256 amount, bytes32[] calldata expiredEscrows) external;

    /// @notice Approve caller for amount.
    function approve(address caller, uint256 amount) external;

    /// @notice Increase caller allowance.
    function increaseAllowance(address caller, uint256 amount) external;

    /// @notice Decrease caller allowance.
    function decreaseAllowance(address caller, uint256 amount) external;

    /// @notice Permissionlessly expire one escrow, reverting unless it is present and expired.
    function expire(bytes32 escrowId) external;

    /// @notice Permissionlessly and best-effort expire many escrows.
    function expireMany(bytes32[] calldata escrowIds) external;

    /// @notice Reserve a sponsor-funded escrow for a caller-owned async job.
    function reserveFrom(
        address sponsor,
        address caller,
        bytes32 escrowId,
        uint256 amount,
        uint64 expiryBlock,
        bytes32[] calldata expiredEscrows
    ) external;

    /// @notice Settle an active escrow. If `close` is false and `newExpiry` is zero, the existing expiry is kept.
    /// @dev Restricted in the implementation to authorized protocol contracts: Scheduler, AsyncDelivery, and AsyncJobTracker.
    function settle(bytes32 escrowId, Payment[] calldata payments, uint256 refund, uint64 newExpiry, bool close)
        external;

    /// @notice Deduct scheduled execution fees, consuming amount allowance when caller differs from sponsor.
    function deductScheduledExecutionFeesFrom(
        address sponsor,
        address caller,
        uint256 effectiveFeePerGas,
        uint256 gasLimit,
        uint256 value,
        uint256 fixedFee,
        uint256 callId
    ) external returns (uint256 actualFee);

    /// @notice Refund unused execution gas to an operation sponsor (scheduler/delivery only)
    /// @param sponsor Sponsor address receiving the refund
    /// @param refundAmount Amount to refund in wei
    /// @param callId Associated call ID for tracking
    function refundGas(address sponsor, uint256 refundAmount, uint256 callId) external payable;
}
