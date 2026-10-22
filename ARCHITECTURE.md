# Architecture

## Contract boundary

One contract, `src/NativePayments.sol`, with no dependencies, no owner and no upgrade path. The only configuration is the immutable `merchant`, validated at construction (not zero, not the contract itself). Everything about orders (validity, price, expiry, fulfilment) lives in the backend; on chain an order code is an opaque non-empty string and `orderPayments` is a monotonic sum.

## Ledger

State is a single credit ledger, `credit[address]`, plus the per-order sums. Every operation is a move inside the ledger or across its edge:

| Operation | Enters ledger | Moves inside ledger | Leaves ledger |
| --- | --- | --- | --- |
| `receive` | `msg.value` to sender | | |
| `pay` | `msg.value` to payer | `amount` payer to merchant | |
| `withdraw` | | | `amount` from caller |

`pay` reads `available = credit[payer] + msg.value` once, then writes the payer before crediting the merchant. Because the merchant write reads the slot after the payer write, a merchant paying itself ends with its old credit plus `msg.value`, which is correct.

## Guarantees

- `address(this).balance == sum(credit) + forced funds`. Forced funds are native tokens that arrived without running `receive` or `pay`; they belong to nobody and are never withdrawable. Consequently total credit never exceeds the balance. Pinned by the invariant test.
- Only `msg.sender` can spend or withdraw its own credit. There is no `tx.origin` use, no signature path and no claim by transaction hash, so funds credited to an intermediary (an exchange hot wallet) stay with that intermediary.
- Customer deposits are not merchant revenue: the merchant's credit grows only through `pay` or its own deposits.
- `pay` makes no external calls. `withdraw` makes exactly one, after deducting credit, so re-entry can spend only remaining credit. No reentrancy guard is needed for that reason.

## Trade-offs

- Deposits through `receive` write storage and so fail under the 2300 gas stipend of `transfer`/`send`. Accepted to keep deposits attributable without a separate deposit function.
- Pull-based payouts: the merchant collects proceeds with `withdraw` rather than being paid during `pay`, so a reverting merchant cannot block customer payments.
