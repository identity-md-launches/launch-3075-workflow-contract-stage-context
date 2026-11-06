# ABI and integration guide

The complete JSON ABI for each deployable Solidity contract is in `docs/abi/<Contract>.json`. Regenerate them with `python3 scripts/export-abi.py` after compiling with the root configuration. Constructor order and deployment references are in the root README; a separate assignment produces the manifest.

## Units and identifiers

| Value | Representation |
| --- | --- |
| Share quantity | `uint128` in order/split/merge arguments, 6 decimals |
| USDC balance, order price `x` | USDC minor units, 6 decimals; tick 100 |
| Asset balances, swap input, asset-side fees | Token minor units |
| Boundary price, ladder strike | USD per `unitsPerShare`, 18 decimals |
| Market key | `keccak256(abi.encode(token, uint32 period, uint64 start, uint256 strike))` |
| Standard strike | Zero is the explicit standard-market discriminator |
| Order IDs | Monotonic `uint64`, starting at 1; zero means no linked order |
| Asset versions | Monotonic `uint32`, starting at 1; old versions remain queryable |
| Proposal key | `keccak256(abi.encode(uint32 version, uint64 boundary))` |

`MarketSpec` declaration order is `(address token, uint32 period, uint64 start, uint256 strike)`. The `start` must be exactly the result of `registry.bounds(period, start)`. The default hourly period is ID 0. Passing the same spec always resolves to the same market, independent of current registry settings after it was created.

`Action`: 0 BuyUp, 1 BuyDown, 2 SellUp, 3 SellDown. BuyUp/SellDown are bids; BuyDown/SellUp are asks. `Outcome`: 0 Active (may already have ended), 1 Up, 2 Down, 3 Refund. The strike and close fields in `Market` are finalized on settlement; before that, read the boundary oracle for available prices.

## Market entry points

| Call | Behavior |
| --- | --- |
| `deposit(token, amount)` | Pull exactly `amount` from the caller after ERC-20 approval; credit free balance |
| `withdraw(token, amount)` | Debit caller free balance; transfer to caller; reverts atomically if transfer fails |
| `split(spec, quantity)` | Create if necessary, escrow both coins, issue equal outcome balances |
| `merge(id, quantity)` | Burn both outcomes and release collateral before settlement |
| `place(spec, input)` | Escrow, match, and optionally rest an order; returns its ID |
| `placeWithProofs(spec, input, proofs)` | Record up to two boundary proofs, then place atomically |
| `matchMarket(id, maxSteps)` | Permissionlessly continue capped matching of the best bid/ask; returns number of fills |
| `cancel(order)` | Maker-only cancellation, including after market end/settlement |
| `expire(ids)` | Anyone releases up to 64 expired orders or orders in settled markets; harmless on inactive IDs |
| `settle(id)` | Permissionlessly settle with prices, or void after the price deadline |
| `claim(id, up, down)` | Settle if possible, redeem caller's available outcome shares, credit free balances |
| `claimWithProofs(id, up, down, proofs)` | Attach up to two proofs and claim atomically |
| `claimAll(ids)` | Redeem all caller available shares in up to 64 markets, atomically; an unsettled market without an eligible result reverts the batch |
| `feeQuote(id, x, quantity, taker, down)` | Quote the side's fee coin at the latest recorded boundary |

An existing zero position in `claimAll` is skipped. The batch does not cancel open orders, so release their held shares first. A direct zero claim or repeated claim reverts. A claim still depends on a settled/refundable outcome; `Active` by itself does not imply the market can still be traded.

`OrderInput` declaration order:

1. `action`: the enum above.
2. `quantity`: total six-decimal shares.
3. `limitPrice`: six-decimal mirrored UP price, a positive multiple of 100.
4. `expiry`: absolute UTC seconds; between now +300 and market end for a resting order. Ignored for IOC.
5. `immediateOrCancel`: true for a market sweep whose unfilled quantity is returned.
6. `assetOnly`: permitted only for BuyDown. The swap only funds its USDC contribution.
7. `maxSwapInput`: asset minor units, in addition to pair collateral and the fee budget. For an asset-only short below USD 1, this must cover the boundary estimate plus 5%.
8. `feeBudget`: fee coin reserve, USDC for UP actions and asset for DOWN actions. It is **not** a rate. Reserve enough for taker execution and any later maker executions; unspent amounts are refunded.
9. `insertionHint`: a preceding active order on the same market/side, or zero for bounded automatic search. A zero hint is also valid when inserting ahead of the current head.
10. `maxSteps`: 1–64 total examined maker orders.

Additional cash collateral of 1024 USDC atomic units covers per-fill rounding for BuyUp; below USD 1 for non-asset-only BuyDown; and above USD 1 for SellDown. Selling a position explicitly locks the existing shares; it does not silently choose a different action. Fee reserves are funded up front even when a sale will later earn coins. Only the escrow is spendable by matching; an order cannot silently consume extra free balance.

`order(id)` returns all remaining escrow, linked neighbors, fill count, trader, market, expiry, side, price, and resting status. `market(id)` returns the immutable snapshot and settlement/accounting state. Use `marketCount`/`marketIds`, `bestBid`/`bestAsk`, and `order.next` for enumeration. Apply local pagination when following links. Expired entries may still appear until someone expires or matches them.

## Proofs and optimistic resolution

`ProofSubmission` is `(uint32 version, uint64 boundary, BlockProof[3] proofs)`. Each `BlockProof` contains the RLP header, `bytes[] accountProof` for PoolManager, and `bytes[][] storageProofs` in the pinned asset path order. No caller-supplied price or storage root is trusted. The JSON generated by `scripts/build-proof.py` includes extra `slot0` values and block metadata for client debugging; those extra JSON members are not ABI arguments. `BoundaryProofVerifier.verify` is a read-only validation method; persistent recording goes through `BoundaryOracle.prove`.

`price(version, boundary)` returns zero when absent. A version change can produce a distinct price record at the same timestamp because its units/path can differ; all markets that pin one version share its records. `latestBoundary(version)` is monotonic by boundary time, not by submission order.

| Oracle call | Description |
| --- | --- |
| `propose(version, boundary, price, firstBlock)` | After 27 hours, post a 10-IMD bond and open a full one-hour challenge window |
| `oracleCost(version)` | Per-question and total quote; throws when the total exceeds the 10-IMD losing bond |
| `dispute(version, boundary, maxCost)` | Lock a second bond and fee budget, challenge, and attempt the atomic oracle requests |
| `retryResolution(version, boundary, maxCost)` | Anyone advances an additional budget after a deferred request; excess becomes their credit |
| `finalize(version, boundary)` | Finalize an unchallenged proposal after its hour and before its three-day timeout |
| `onOracleResult(intakeRequestId, attestation, signature)` | Intake-only asynchronous success, with EIP-712 validation |
| `onFailure(intakeRequestId, status, reason, panelSize, agreed, details)` | Intake-only failure, status 1 or 2; refund bonds and terminate pending requests |
| `timeout(version, boundary)` | Refund a proposal's outstanding bonds at boundary + three days |
| `withdrawCredit()` | Withdraw the caller's bond/refund/reward credit in IMD |

`requestResolution` is an implementation subcall and rejects every external caller except the oracle contract itself. A `ResolutionDeferred` event means the challenge is effective but no service fee was spent; it can be retried. A successful request's service cost is reimbursed to its actual fee payer only on successful resolution. A failed oracle request or timed-out result returns the two bonds; spent service costs stay spent.

The full `Attestation` tuple is in the ABI. The EIP-712 struct name is `OracleAttestation`, domain name `IdentityMD Oracle`, version `2`, chain ID 1, verifying contract the deployed `BoundaryOracle`. `digest(attestation)` exposes the exact digest. Signed request IDs are distinct from local Intake IDs. Pairing requires the stored canonical question hash and pinned block window; consumers must not enforce equality of these two different ID namespaces.

## Events and client indexing

All application economic changes can be reconstructed from events plus the fixed version configuration. Index by transaction hash/log index; undo logs on reorgs and prefer confirmed headers. No server-held signing key is required for indexing or proof submission.

| Events | Client purpose |
| --- | --- |
| `AssetConfigured`, `PeriodAdded` | Discover listings and immutable configuration versions |
| `MarketCreated` | Discover period/start/ladder markets and their snapshots |
| `Deposited`, `Withdrawn` | Track external user cash flows, excluded from trading PnL |
| `Split`, `Merged` | Track equal share issuance/burn and collateral movements |
| `OrderPlaced`, `OrderEscrowed` | Track owner/action/limit/quantity and exact initial cash, asset, fee, swap reserves |
| `ShortFunded` | Attribute exact swap asset cost and USDC output to a particular order |
| `Trade` | Maker/taker execution price and quantity; join to order actions to derive share/cash flows |
| `FeePaid` | Actual charged fee and maker rebate in the emitted coin |
| `OrderClosed` | Unfilled quantity, reason and exact free-balance refunds |
| `Settled`, `Claimed` | Result, final boundary prices, share burns and redeemed coins |
| `PriceRecorded` | Historical boundary chart and fee reference |
| `Proposed`, `Disputed`, `OracleRequested`, `ResolutionDeferred`, `ProposalClosed`, `CreditWithdrawn` | Dispute timelines and bond/service fee accounting |

Order close reasons: 0 complete/IOC/fill-lifetime limit, 1 expiry/settlement cleanup, 2 insufficient resting-order fee budget, 3 resting-order swap failure, 5 maker cancellation. `unfilled` disambiguates a complete fill from an unfilled IOC/lifetime closure. A capped limit order remains on the book and can be processed through `matchMarket`; show crossed levels as pending execution. Trades quote USD at the boundary convention; showing current mark-to-market USD PnL requires a separately labelled current valuation. Contract events are sufficient to derive realized token cash flows and quantities; they do not assert a continuously updated fiat mark.

## Source references

The oracle ID distinction, canonical question hash, and EIP-712 shape follow the [IdentityMD oracle and Intake documentation](https://imd.fun/docs/#intake-binding-an-answer-to-its-request). Historical hashes use [EIP-2935](https://eips.ethereum.org/EIPS/eip-2935). Pool keys, swap delta signs, and storage proofs use the deployed [Uniswap v4 PoolManager interface](https://github.com/Uniswap/v4-core/blob/main/src/interfaces/IPoolManager.sol) and [state layout](https://github.com/Uniswap/v4-core/blob/main/src/libraries/StateLibrary.sol). Addresses come from the approved brief; mainnet fixtures independently check the initial pool IDs and state.
