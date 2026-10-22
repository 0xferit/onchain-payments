// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
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

/// @dev Calls back into NativePayments once from its receive hook, with a configurable value
/// and calldata, and records the outcome. Used to re-enter during `withdraw`.
contract CallbackAccount {
    NativePayments private immutable PAYMENTS;
    uint256 private callbackValue;
    bytes private callbackData;
    bool public callbackAttempted;
    bool public callbackSucceeded;
    bytes public callbackRevertData;

    constructor(NativePayments payments_) {
        PAYMENTS = payments_;
    }

    function deposit() external payable {
        (bool deposited,) = address(PAYMENTS).call{value: msg.value}("");
        require(deposited);
    }

    function withdrawWithCallback(uint256 amount, uint256 callbackValue_, bytes calldata callbackData_) external {
        callbackValue = callbackValue_;
        callbackData = callbackData_;
        PAYMENTS.withdraw(amount);
    }

    receive() external payable {
        if (callbackAttempted) return;
        callbackAttempted = true;
        bytes memory result;
        (callbackSucceeded, result) = address(PAYMENTS).call{value: callbackValue}(callbackData);
        if (!callbackSucceeded) callbackRevertData = result;
    }
}

/// @dev Spends about 1.3M gas on receipt, like a smart wallet with heavy receive logic.
contract GasHungryAccount {
    uint256 private constant SLOTS_WRITTEN_ON_RECEIVE = 60;

    NativePayments private immutable PAYMENTS;
    mapping(uint256 => uint256) private written;

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

    receive() external payable {
        for (uint256 i; i < SLOTS_WRITTEN_ON_RECEIVE; ++i) {
            written[i] = i + 1;
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

    /// @dev The required event layouts, declared independently of the contract so that a change
    /// to which fields are indexed fails `expectEmit` instead of moving the expectation with it.
    event Deposited(address indexed sender, uint256 amount);
    event Payment(address indexed payer, string orderCode, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);

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

    function test_Constructor_AcceptsDeployingContractAsMerchant() public {
        NativePayments deployed = new NativePayments(address(this));

        assertEq(deployed.merchant(), address(this));
    }

    function test_Constructor_AcceptsDeployingAccountAsMerchant() public {
        vm.prank(alice, alice);
        NativePayments deployed = new NativePayments(alice);

        assertEq(deployed.merchant(), alice);
    }

    // Deposits

    function test_Receive_CreditsSenderAndEmitsDeposited() public {
        vm.deal(alice, 3 ether);
        vm.expectEmit(address(payments));
        emit Deposited(alice, 3 ether);
        vm.prank(alice);
        (bool deposited,) = address(payments).call{value: 3 ether}("");

        assertTrue(deposited);
        assertEq(payments.credit(alice), 3 ether);
        assertEq(payments.credit(merchant), 0);
        assertEq(address(payments).balance, 3 ether);
    }

    function test_Receive_AccumulatesRepeatedDeposits() public {
        _deposit(alice, 1 ether);

        vm.expectEmit(address(payments));
        emit Deposited(alice, 2 ether);
        _deposit(alice, 2 ether);

        assertEq(payments.credit(alice), 3 ether);
    }

    function test_Receive_RevertsWithTransferGasStipend() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert();
        payable(address(payments)).transfer(1 ether);
    }

    function test_Receive_RejectsUnknownCalldata() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool acceptedWithValue,) = address(payments).call{value: 1 ether}(hex"deadbeef");
        (bool acceptedWithoutValue,) = address(payments).call(hex"deadbeef");

        assertFalse(acceptedWithValue);
        assertFalse(acceptedWithoutValue);
        assertEq(payments.credit(alice), 0);
        assertEq(address(payments).balance, 0);
    }

    // Payments

    function test_Pay_FundedEntirelyByCredit() public {
        _deposit(alice, 3 ether);

        vm.expectEmit(address(payments));
        emit Payment(alice, ORDER, 2 ether);
        _pay(alice, ORDER, 0, 2 ether);

        assertEq(payments.credit(alice), 1 ether);
        assertEq(payments.credit(merchant), 2 ether);
        assertEq(payments.orderPayments(ORDER), 2 ether);
        assertEq(address(payments).balance, 3 ether);
    }

    function test_Pay_FundedEntirelyByValue() public {
        vm.expectEmit(address(payments));
        emit Payment(alice, ORDER, 2 ether);
        _pay(alice, ORDER, 2 ether, 2 ether);

        assertEq(payments.credit(alice), 0);
        assertEq(payments.credit(merchant), 2 ether);
        assertEq(payments.orderPayments(ORDER), 2 ether);
        assertEq(address(payments).balance, 2 ether);
    }

    function test_Pay_FundedByCreditAndValue() public {
        _deposit(alice, 1 ether);

        vm.expectEmit(address(payments));
        emit Payment(alice, ORDER, 3 ether);
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

        vm.expectEmit(address(payments));
        emit Payment(alice, ORDER, 2 ether);
        _pay(alice, ORDER, 2 ether, 2 ether);

        vm.expectEmit(address(payments));
        emit Payment(bob, ORDER, 3 ether);
        _pay(bob, ORDER, 3 ether, 3 ether);

        assertEq(payments.orderPayments(ORDER), 6 ether);
        assertEq(payments.orderPayments(OTHER_ORDER), 0);
        assertEq(payments.credit(merchant), 6 ether);
    }

    function test_Pay_KeepsLongOrderCodesWithSharedPrefixDistinct() public {
        string memory first = "INVOICE-2026-10-22-CUSTOMER-000000000001";
        string memory second = "INVOICE-2026-10-22-CUSTOMER-000000000002";

        _pay(alice, first, 1 ether, 1 ether);
        _pay(alice, second, 2 ether, 2 ether);

        assertEq(payments.orderPayments(first), 1 ether);
        assertEq(payments.orderPayments(second), 2 ether);
    }

    function test_Pay_TreatsOrderCodesAsExactBytes() public {
        _pay(alice, "order-a", 1 ether, 1 ether);
        _pay(alice, "ORDER-A", 2 ether, 2 ether);

        assertEq(payments.orderPayments("order-a"), 1 ether);
        assertEq(payments.orderPayments("ORDER-A"), 2 ether);
    }

    function test_Pay_MerchantRevertsOnInsufficientFunds() public {
        vm.expectRevert(abi.encodeWithSelector(NativePayments.InsufficientFunds.selector, 0, 1 ether));
        vm.prank(merchant);
        payments.pay(ORDER, 1 ether);
    }

    function test_Pay_EmitsOnlyPayment() public {
        vm.deal(alice, 3 ether);
        vm.recordLogs();
        vm.prank(alice);
        payments.pay{value: 3 ether}(ORDER, 1 ether);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], Payment.selector);
    }

    function test_Pay_MerchantAsPayerKeepsOwnCredit() public {
        _pay(alice, ORDER, 2 ether, 2 ether);

        vm.expectEmit(address(payments));
        emit Payment(merchant, ORDER, 3 ether);
        _pay(merchant, ORDER, 1 ether, 3 ether);

        assertEq(payments.credit(merchant), 3 ether);
        assertEq(payments.orderPayments(ORDER), 5 ether);
        assertEq(address(payments).balance, 3 ether);

        _withdraw(merchant, 3 ether);
        assertEq(merchant.balance, 3 ether);
        assertEq(address(payments).balance, 0);
    }

    // Withdrawals

    function test_Withdraw_CustomerPartialThenFull() public {
        _deposit(alice, 3 ether);

        vm.expectEmit(address(payments));
        emit Withdrawn(alice, 1 ether);
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
        emit Withdrawn(merchant, 1 ether);
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

    function test_Withdraw_ForwardsAllGasToRecipient() public {
        GasHungryAccount account = new GasHungryAccount(payments);
        account.deposit{value: 1 ether}();

        account.withdraw(1 ether);

        assertEq(address(account).balance, 1 ether);
        assertEq(payments.credit(address(account)), 0);
    }

    function test_Withdraw_ReentryCannotWithdrawUncreditedFunds() public {
        _deposit(bob, 5 ether);
        CallbackAccount attacker = new CallbackAccount(payments);
        attacker.deposit{value: 1 ether}();

        attacker.withdrawWithCallback(1 ether, 0, abi.encodeCall(NativePayments.withdraw, (1 ether)));

        assertTrue(attacker.callbackAttempted());
        assertFalse(attacker.callbackSucceeded());
        assertEq(
            attacker.callbackRevertData(), abi.encodeWithSelector(NativePayments.InsufficientFunds.selector, 0, 1 ether)
        );
        assertEq(address(attacker).balance, 1 ether);
        assertEq(payments.credit(address(attacker)), 0);
        assertEq(payments.credit(bob), 5 ether);
        assertEq(address(payments).balance, 5 ether);
    }

    function test_Withdraw_ReentryLimitedToRemainingCredit() public {
        _deposit(bob, 5 ether);
        CallbackAccount attacker = new CallbackAccount(payments);
        attacker.deposit{value: 2 ether}();

        attacker.withdrawWithCallback(1 ether, 0, abi.encodeCall(NativePayments.withdraw, (2 ether)));

        assertFalse(attacker.callbackSucceeded());
        assertEq(
            attacker.callbackRevertData(),
            abi.encodeWithSelector(NativePayments.InsufficientFunds.selector, 1 ether, 2 ether)
        );
        assertEq(address(attacker).balance, 1 ether);
        assertEq(payments.credit(address(attacker)), 1 ether);
        assertEq(address(payments).balance, 6 ether);
    }

    function test_Withdraw_SuccessfulReentryAccountsEachWithdrawal() public {
        _deposit(bob, 5 ether);
        CallbackAccount account = new CallbackAccount(payments);
        account.deposit{value: 3 ether}();

        vm.recordLogs();
        account.withdrawWithCallback(1 ether, 0, abi.encodeCall(NativePayments.withdraw, (1 ether)));

        assertTrue(account.callbackSucceeded());
        assertEq(address(account).balance, 2 ether);
        assertEq(payments.credit(address(account)), 1 ether);
        assertEq(address(payments).balance, 6 ether);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2);
        for (uint256 i; i < logs.length; ++i) {
            assertEq(logs[i].topics[0], Withdrawn.selector);
            assertEq(abi.decode(logs[i].data, (uint256)), 1 ether);
        }
    }

    function test_Withdraw_DepositDuringWithdrawalIsCredited() public {
        CallbackAccount account = new CallbackAccount(payments);
        account.deposit{value: 2 ether}();

        account.withdrawWithCallback(1 ether, 1 ether, "");

        assertTrue(account.callbackSucceeded());
        assertEq(payments.credit(address(account)), 2 ether);
        assertEq(address(payments).balance, 2 ether);
    }

    function test_Withdraw_PaymentDuringWithdrawalSucceeds() public {
        CallbackAccount account = new CallbackAccount(payments);
        account.deposit{value: 2 ether}();

        account.withdrawWithCallback(1 ether, 0, abi.encodeCall(NativePayments.pay, (ORDER, 1 ether)));

        assertTrue(account.callbackSucceeded());
        assertEq(payments.credit(address(account)), 0);
        assertEq(payments.credit(merchant), 1 ether);
        assertEq(payments.orderPayments(ORDER), 1 ether);
    }

    function test_Withdraw_RevertsOnMaxAmountInsteadOfWithdrawingAll() public {
        _deposit(alice, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(NativePayments.InsufficientFunds.selector, 1 ether, type(uint256).max));
        _withdraw(alice, type(uint256).max);
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
