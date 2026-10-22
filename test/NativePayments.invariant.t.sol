// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {NativePayments} from "../src/NativePayments.sol";

/// @dev Drives NativePayments through a fixed set of actors, the merchant included, so the
/// invariant can sum every account that could ever hold credit.
contract NativePaymentsHandler is Test {
    uint256 private constant MAX_TRANSFER = 100 ether;
    uint256 private constant CUSTOMER_COUNT = 3;

    NativePayments public immutable PAYMENTS;
    address[] private actors;
    string[] private orderCodes;

    uint256 public forcedFunds;

    constructor(NativePayments payments_) {
        PAYMENTS = payments_;
        actors.push(payments_.merchant());
        for (uint256 i; i < CUSTOMER_COUNT; ++i) {
            actors.push(makeAddr(string.concat("customer", vm.toString(i))));
        }
        orderCodes.push("ORDER-A");
        orderCodes.push("ORDER-B");
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        amount = bound(amount, 0, MAX_TRANSFER);
        vm.deal(actor, actor.balance + amount);
        vm.prank(actor);
        (bool deposited,) = address(PAYMENTS).call{value: amount}("");
        require(deposited);
    }

    function pay(uint256 actorSeed, uint256 orderSeed, uint256 value, uint256 amount) external {
        address actor = _actor(actorSeed);
        value = bound(value, 0, MAX_TRANSFER);
        uint256 available = PAYMENTS.credit(actor) + value;
        if (available == 0) return;
        amount = bound(amount, 1, available);
        vm.deal(actor, actor.balance + value);
        vm.prank(actor);
        PAYMENTS.pay{value: value}(orderCodes[orderSeed % orderCodes.length], amount);
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        uint256 available = PAYMENTS.credit(actor);
        if (available == 0) return;
        amount = bound(amount, 1, available);
        vm.prank(actor);
        PAYMENTS.withdraw(amount);
    }

    function forceFeed(uint256 amount) external {
        amount = bound(amount, 0, MAX_TRANSFER);
        vm.deal(address(PAYMENTS), address(PAYMENTS).balance + amount);
        forcedFunds += amount;
    }

    function totalCredit() external view returns (uint256 total) {
        for (uint256 i; i < actors.length; ++i) {
            total += PAYMENTS.credit(actors[i]);
        }
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }
}

contract NativePaymentsInvariantTest is Test {
    NativePayments private payments;
    NativePaymentsHandler private handler;

    function setUp() public {
        payments = new NativePayments(makeAddr("merchant"));
        handler = new NativePaymentsHandler(payments);

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = NativePaymentsHandler.deposit.selector;
        selectors[1] = NativePaymentsHandler.pay.selector;
        selectors[2] = NativePaymentsHandler.withdraw.selector;
        selectors[3] = NativePaymentsHandler.forceFeed.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_TotalCreditNeverExceedsBalance() public view {
        assertLe(handler.totalCredit(), address(payments).balance);
    }

    /// @dev Stronger form: the only balance not owed to some account is forced funds.
    function invariant_BalanceEqualsCreditPlusForcedFunds() public view {
        assertEq(address(payments).balance, handler.totalCredit() + handler.forcedFunds());
    }
}
