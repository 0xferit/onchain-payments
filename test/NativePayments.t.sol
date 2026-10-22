// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {NativePayments} from "../src/NativePayments.sol";

/// @dev Holds credit but has no receive or fallback, so native withdrawals to it fail.
contract RejectingAccount {
    NativePayments private immutable PAYMENTS;

    constructor(NativePayments payments_) {
        PAYMENTS = payments_;
    }

    function deposit() external payable {
        (bool deposited,) = address(PAYMENTS).call{value: msg.value}("");
        require(deposited);
    }

    function withdraw(uint256 amount) external {
        PAYMENTS.withdraw(amount);
    }
}

/// @dev Re-enters `withdraw` once from its receive hook and records the outcome.
contract ReentrantAccount {
    NativePayments private immutable PAYMENTS;
    uint256 private reentryAmount;
    bool public reentryAttempted;
    bool public reentrySucceeded;
    bytes public reentryRevertData;

    constructor(NativePayments payments_) {
        PAYMENTS = payments_;
    }

    function deposit() external payable {
        (bool deposited,) = address(PAYMENTS).call{value: msg.value}("");
        require(deposited);
    }

    function attack(uint256 amount, uint256 reentryAmount_) external {
        reentryAmount = reentryAmount_;
        PAYMENTS.withdraw(amount);
    }

    receive() external payable {
        if (reentryAttempted) return;
        reentryAttempted = true;
        try PAYMENTS.withdraw(reentryAmount) {
            reentrySucceeded = true;
        } catch (bytes memory reason) {
            reentryRevertData = reason;
        }
    }
}

/// @dev Sends its endowment without invoking the target's receive function.
contract ForceFeeder {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

contract NativePaymentsTest is Test {
    string private constant ORDER = "ORDER-1";
    string private constant OTHER_ORDER = "ORDER-2";

    NativePayments private payments;
    address private merchant = makeAddr("merchant");
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");

    function setUp() public {
        payments = new NativePayments(merchant);
    }

    function _deposit(address account, uint256 amount) private {
        vm.deal(account, account.balance + amount);
        vm.prank(account);
        (bool deposited,) = address(payments).call{value: amount}("");
        assertTrue(deposited);
    }

    function _pay(address payer, string memory orderCode, uint256 value, uint256 amount) private {
        vm.deal(payer, payer.balance + value);
        vm.prank(payer);
        payments.pay{value: value}(orderCode, amount);
    }

    function _withdraw(address account, uint256 amount) private {
        vm.prank(account);
        payments.withdraw(amount);
    }

    // Merchant configuration

    function test_Constructor_SetsMerchant() public view {
        assertEq(payments.merchant(), merchant);
    }

    function test_Constructor_RevertsOnZeroAddressMerchant() public {
        vm.expectRevert(abi.encodeWithSelector(NativePayments.InvalidMerchant.selector, address(0)));
        new NativePayments(address(0));
    }

    function test_Constructor_RevertsOnOwnAddressMerchant() public {
        address deploymentAddress = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(abi.encodeWithSelector(NativePayments.InvalidMerchant.selector, deploymentAddress));
        new NativePayments(deploymentAddress);
    }

    // Deposits

    function test_Receive_CreditsSenderAndEmitsDeposited() public {
        vm.deal(alice, 3 ether);
        vm.expectEmit(address(payments));
        emit NativePayments.Deposited(alice, 3 ether);
        vm.prank(alice);
        (bool deposited,) = address(payments).call{value: 3 ether}("");

        assertTrue(deposited);
        assertEq(payments.credit(alice), 3 ether);
        assertEq(payments.credit(merchant), 0);
        assertEq(address(payments).balance, 3 ether);
    }

    function test_Receive_AccumulatesRepeatedDeposits() public {
        _deposit(alice, 1 ether);
        _deposit(alice, 2 ether);

        assertEq(payments.credit(alice), 3 ether);
    }

    function test_Receive_RevertsWithTransferGasStipend() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert();
        payable(address(payments)).transfer(1 ether);
    }

    // Payments

    function test_Pay_FundedEntirelyByCredit() public {
        _deposit(alice, 3 ether);

        vm.expectEmit(address(payments));
        emit NativePayments.Payment(alice, ORDER, 2 ether);
        _pay(alice, ORDER, 0, 2 ether);

        assertEq(payments.credit(alice), 1 ether);
        assertEq(payments.credit(merchant), 2 ether);
        assertEq(payments.orderPayments(ORDER), 2 ether);
        assertEq(address(payments).balance, 3 ether);
    }

    function test_Pay_FundedEntirelyByValue() public {
        vm.expectEmit(address(payments));
        emit NativePayments.Payment(alice, ORDER, 2 ether);
        _pay(alice, ORDER, 2 ether, 2 ether);

        assertEq(payments.credit(alice), 0);
        assertEq(payments.credit(merchant), 2 ether);
        assertEq(payments.orderPayments(ORDER), 2 ether);
        assertEq(address(payments).balance, 2 ether);
    }

    function test_Pay_FundedByCreditAndValue() public {
        _deposit(alice, 1 ether);

        vm.expectEmit(address(payments));
        emit NativePayments.Payment(alice, ORDER, 3 ether);
        _pay(alice, ORDER, 2 ether, 3 ether);

        assertEq(payments.credit(alice), 0);
        assertEq(payments.credit(merchant), 3 ether);
        assertEq(payments.orderPayments(ORDER), 3 ether);
        assertEq(address(payments).balance, 3 ether);
    }

    function test_Pay_KeepsExcessValueAsPayerCredit() public {
        _pay(alice, ORDER, 5 ether, 2 ether);

        assertEq(payments.credit(alice), 3 ether);
        assertEq(payments.credit(merchant), 2 ether);
        assertEq(payments.orderPayments(ORDER), 2 ether);
        assertEq(address(payments).balance, 5 ether);
    }

    function test_Pay_RevertsOnInsufficientFunds() public {
        _deposit(alice, 1 ether);
        vm.deal(alice, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(NativePayments.InsufficientFunds.selector, 2 ether, 3 ether));
        vm.prank(alice);
        payments.pay{value: 1 ether}(ORDER, 3 ether);
    }

    function test_Pay_RevertsOnEmptyOrderCode() public {
        vm.deal(alice, 1 ether);

        vm.expectRevert(NativePayments.EmptyOrderCode.selector);
        vm.prank(alice);
        payments.pay{value: 1 ether}("", 1 ether);
    }

    function test_Pay_RevertsOnZeroAmount() public {
        vm.deal(alice, 1 ether);

        vm.expectRevert(NativePayments.ZeroAmount.selector);
        vm.prank(alice);
        payments.pay{value: 1 ether}(ORDER, 0);
    }

    function test_Pay_AccumulatesRepeatedPaymentsPerOrder() public {
        _pay(alice, ORDER, 1 ether, 1 ether);
        _pay(alice, ORDER, 2 ether, 2 ether);
        _pay(bob, ORDER, 3 ether, 3 ether);

        assertEq(payments.orderPayments(ORDER), 6 ether);
        assertEq(payments.orderPayments(OTHER_ORDER), 0);
        assertEq(payments.credit(merchant), 6 ether);
    }

    function test_Pay_MerchantAsPayerKeepsOwnCredit() public {
        _pay(alice, OTHER_ORDER, 2 ether, 2 ether);

        vm.expectEmit(address(payments));
        emit NativePayments.Payment(merchant, ORDER, 3 ether);
        _pay(merchant, ORDER, 1 ether, 3 ether);

        assertEq(payments.credit(merchant), 3 ether);
        assertEq(payments.orderPayments(ORDER), 3 ether);
        assertEq(address(payments).balance, 3 ether);

        _withdraw(merchant, 3 ether);
        assertEq(merchant.balance, 3 ether);
        assertEq(address(payments).balance, 0);
    }

    // Withdrawals

    function test_Withdraw_CustomerPartialThenFull() public {
        _deposit(alice, 3 ether);

        vm.expectEmit(address(payments));
        emit NativePayments.Withdrawn(alice, 1 ether);
        _withdraw(alice, 1 ether);

        assertEq(payments.credit(alice), 2 ether);
        assertEq(alice.balance, 1 ether);

        _withdraw(alice, 2 ether);

        assertEq(payments.credit(alice), 0);
        assertEq(alice.balance, 3 ether);
        assertEq(address(payments).balance, 0);
    }

    function test_Withdraw_MerchantWithdrawsProceedsPartially() public {
        _pay(alice, ORDER, 3 ether, 2 ether);

        vm.expectEmit(address(payments));
        emit NativePayments.Withdrawn(merchant, 1 ether);
        _withdraw(merchant, 1 ether);

        assertEq(payments.credit(merchant), 1 ether);
        assertEq(merchant.balance, 1 ether);
        assertEq(payments.credit(alice), 1 ether);
        assertEq(address(payments).balance, 2 ether);
    }

    function test_Withdraw_MerchantCannotWithdrawUnallocatedDeposits() public {
        _deposit(alice, 3 ether);

        vm.expectRevert(abi.encodeWithSelector(NativePayments.InsufficientFunds.selector, 0, 1 ether));
        _withdraw(merchant, 1 ether);
    }

    function test_Withdraw_RevertsOnZeroAmount() public {
        _deposit(alice, 1 ether);

        vm.expectRevert(NativePayments.ZeroAmount.selector);
        _withdraw(alice, 0);
    }

    function test_Withdraw_RevertsOnInsufficientCredit() public {
        _deposit(alice, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(NativePayments.InsufficientFunds.selector, 1 ether, 2 ether));
        _withdraw(alice, 2 ether);
    }

    function test_Withdraw_RevertsWhenRecipientRejectsNativeTokens() public {
        RejectingAccount account = new RejectingAccount(payments);
        account.deposit{value: 1 ether}();

        vm.expectRevert(NativePayments.TransferFailed.selector);
        account.withdraw(1 ether);

        assertEq(payments.credit(address(account)), 1 ether);
        assertEq(address(payments).balance, 1 ether);
    }

    function test_Withdraw_ReentryCannotWithdrawUncreditedFunds() public {
        _deposit(bob, 5 ether);
        ReentrantAccount attacker = new ReentrantAccount(payments);
        attacker.deposit{value: 1 ether}();

        attacker.attack(1 ether, 1 ether);

        assertTrue(attacker.reentryAttempted());
        assertFalse(attacker.reentrySucceeded());
        assertEq(
            attacker.reentryRevertData(), abi.encodeWithSelector(NativePayments.InsufficientFunds.selector, 0, 1 ether)
        );
        assertEq(address(attacker).balance, 1 ether);
        assertEq(payments.credit(address(attacker)), 0);
        assertEq(payments.credit(bob), 5 ether);
        assertEq(address(payments).balance, 5 ether);
    }

    function test_Withdraw_ReentryLimitedToRemainingCredit() public {
        _deposit(bob, 5 ether);
        ReentrantAccount attacker = new ReentrantAccount(payments);
        attacker.deposit{value: 2 ether}();

        attacker.attack(1 ether, 2 ether);

        assertFalse(attacker.reentrySucceeded());
        assertEq(
            attacker.reentryRevertData(),
            abi.encodeWithSelector(NativePayments.InsufficientFunds.selector, 1 ether, 2 ether)
        );
        assertEq(address(attacker).balance, 1 ether);
        assertEq(payments.credit(address(attacker)), 1 ether);
        assertEq(address(payments).balance, 6 ether);
    }

    // Isolation and forced funds

    function test_MultipleCustomersHaveIndependentBalances() public {
        _deposit(alice, 2 ether);
        _deposit(bob, 3 ether);

        _pay(alice, ORDER, 0, 1 ether);
        _withdraw(bob, 3 ether);

        assertEq(payments.credit(alice), 1 ether);
        assertEq(payments.credit(bob), 0);
        assertEq(bob.balance, 3 ether);

        vm.expectRevert(abi.encodeWithSelector(NativePayments.InsufficientFunds.selector, 1 ether, 2 ether));
        _withdraw(alice, 2 ether);
    }

    function test_ForcedFundsRemainUncredited() public {
        _deposit(alice, 1 ether);
        vm.deal(address(this), 4 ether);

        ForceFeeder feeder = new ForceFeeder{value: 4 ether}(payable(address(payments)));

        assertEq(address(payments).balance, 5 ether);
        assertEq(payments.credit(address(feeder)), 0);
        assertEq(payments.credit(address(this)), 0);
        assertEq(payments.credit(merchant), 0);
        assertEq(payments.credit(alice), 1 ether);

        vm.expectRevert(abi.encodeWithSelector(NativePayments.InsufficientFunds.selector, 0, 1 ether));
        _withdraw(merchant, 1 ether);
    }
}
