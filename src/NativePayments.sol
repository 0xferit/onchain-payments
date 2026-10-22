// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.24;

/// @title NativePayments
/// @notice Holds native-token credit per address and lets payers allocate it to order codes.
/// Deposits and order allocation are separate steps: funds sent to `receive` become the
/// sender's credit, and `pay` moves credit (plus any attached value) to the merchant.
/// @dev The contract only tracks credit it was told about. Native funds that arrive without
/// executing `receive` or `pay` (for example via `selfdestruct` or as a block's fee recipient) are
/// never credited to anyone and cannot be withdrawn.
contract NativePayments {
    /// @notice The address credited with every payment. Fixed at deployment.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable merchant;

    /// @notice Native-token amount each address may spend through `pay` or take out through `withdraw`.
    mapping(address => uint256) public credit;

    /// @notice Cumulative amount allocated to each order code. Says nothing about whether an
    /// order is fully paid; order terms live off-chain.
    mapping(string => uint256) public orderPayments;

    /// @notice `sender` added `amount` to its credit without assigning it to an order.
    event Deposited(address indexed sender, uint256 amount);
    /// @notice `payer` allocated `amount` to `orderCode`. The order code is deliberately not
    /// indexed so its text stays readable in the log data.
    event Payment(address indexed payer, string orderCode, uint256 amount);
    /// @notice `amount` of `account`'s credit was sent to `account`.
    event Withdrawn(address indexed account, uint256 amount);

    /// @notice The merchant is the zero address or this contract's own address.
    error InvalidMerchant(address merchant);
    /// @notice `pay` was called with an empty order code.
    error EmptyOrderCode();
    /// @notice A payment or withdrawal amount of zero.
    error ZeroAmount();
    /// @notice The caller's spendable funds are below the requested amount.
    error InsufficientFunds(uint256 available, uint256 required);
    /// @notice The native-token transfer to the withdrawing account failed.
    error TransferFailed();

    /// @param merchant_ Recipient of all payments; must not be zero or this contract.
    constructor(address merchant_) {
        if (merchant_ == address(0) || merchant_ == address(this)) revert InvalidMerchant(merchant_);
        merchant = merchant_;
    }

    /// @notice Credits the sender with `msg.value` without assigning it to any order.
    /// @dev Writes storage, so plain `transfer` or `send` (2300 gas stipend) cannot deposit.
    receive() external payable {
        credit[msg.sender] += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    /// @notice Allocates `amount` from the caller's credit plus `msg.value` to `orderCode`.
    /// Whatever `msg.value` is not needed stays as the caller's credit.
    /// @dev Makes no external calls. Reverts with `EmptyOrderCode`, `ZeroAmount` or
    /// `InsufficientFunds`. Correct when the caller is the merchant: the merchant's credit
    /// ends up increased by `msg.value` alone.
    /// @param orderCode Backend-issued order identifier; repeated and partial payments accumulate.
    /// @param amount Amount to allocate to the order.
    function pay(string calldata orderCode, uint256 amount) external payable {
        if (bytes(orderCode).length == 0) revert EmptyOrderCode();
        if (amount == 0) revert ZeroAmount();

        uint256 available = credit[msg.sender] + msg.value;
        if (available < amount) revert InsufficientFunds(available, amount);

        credit[msg.sender] = available - amount;
        credit[merchant] += amount;
        orderPayments[orderCode] += amount;

        emit Payment(msg.sender, orderCode, amount);
    }

    /// @notice Sends `amount` of the caller's credit to the caller. Customers withdraw unused
    /// funds and the merchant withdraws payment proceeds through this same function.
    /// @dev Deducts credit before the external call, so re-entry can spend only what remains.
    /// Reverts with `ZeroAmount`, `InsufficientFunds` or `TransferFailed`.
    function withdraw(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        uint256 available = credit[msg.sender];
        if (available < amount) revert InsufficientFunds(available, amount);

        credit[msg.sender] = available - amount;

        (bool sent,) = msg.sender.call{value: amount}("");
        if (!sent) revert TransferFailed();

        emit Withdrawn(msg.sender, amount);
    }
}
