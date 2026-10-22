# onchain-payments

`NativePayments` is a minimal Solidity contract for accepting native-token payments against order codes issued by a backend. It keeps deposits separate from order allocation: a customer first holds credit in the contract, then allocates some of it to an order.

## Flow

1. **Deposit.** Send native tokens straight to the contract. `receive()` credits the sender and emits `Deposited(sender, amount)`. The deposit belongs to no order.
2. **Pay.** Call `pay(orderCode, amount)`, optionally attaching value. The contract takes `amount` from the caller's credit plus `msg.value`, credits it to the merchant, adds it to `orderPayments[orderCode]` and emits `Payment(payer, orderCode, amount)`. Any attached value beyond `amount` stays as the caller's credit. One call with exact value is the common case; a deposit followed by `pay` with no value also works.
3. **Withdraw.** Call `withdraw(amount)` to receive native tokens from your own credit and emit `Withdrawn(account, amount)`. Customers use it to take back unused funds; the merchant uses it to collect payment proceeds.

The backend watches `Payment` events (the order code is not indexed, so its text is readable in the log) and decides whether an order is paid. `orderPayments` is a cumulative total: repeated and partial payments to one code add up, and the contract never says whether an order is complete.

The merchant address is fixed at deployment and cannot be the zero address or the contract itself. There is no owner, upgrade path, pause switch, fee, token support or signature flow.

## Limitations

- **Direct transfers need gas for a storage write.** `receive()` updates storage, so a plain `transfer` or `send` (2300 gas stipend) reverts. Wallets sending an ordinary transaction are fine; contracts must use `call` with enough gas, or use `pay` instead.
- **Exchange withdrawals credit the exchange.** Credit belongs to `msg.sender`. When a customer withdraws from an exchange directly to this contract, the exchange's hot wallet receives the credit, not the customer, and the customer cannot spend or reclaim it. There is deliberately no claim-by-transaction-hash or `tx.origin` path. Customers should pay from a wallet they control.
- **No order validation.** The contract accepts any non-empty order code and any non-zero amount. Prices, expiry, duplicates and fulfilment are the backend's job.
- **Forced funds are stranded.** Native tokens that arrive without executing `receive()` or `pay()` (for example through `selfdestruct`, or by naming the contract as a block's fee recipient) are credited to nobody and cannot be withdrawn. There is no recovery function.
- **The merchant must be able to receive native tokens.** The merchant address is immutable and proceeds leave only through `withdraw`, which sends to the caller. If the merchant is a contract that cannot call `withdraw` or rejects native tokens, its proceeds are locked permanently. Use an externally owned account or a wallet contract known to accept native tokens.

## Development

Requires [Foundry](https://getfoundry.sh).

```sh
forge build
forge test
```

The suite includes unit tests for every path and an invariant test checking that the contract balance always equals the sum of all credit plus any forced funds. [ARCHITECTURE.md](ARCHITECTURE.md) lists the accounting guarantees the contract maintains.
