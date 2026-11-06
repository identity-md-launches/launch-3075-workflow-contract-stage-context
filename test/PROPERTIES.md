# Additional adversarial tests

These tests supplement the accepted implementation's suite. They use the existing vendored Foundry and OpenZeppelin dependencies; no installation, RPC, FFI, environment mutation, or generated file is needed to run them. The supplied protected checks were read as acceptance definitions, not imported or modified.

Run with the assignment's seed:

```sh
FOUNDRY_FUZZ_SEED=0x575cc7802996bba860ac81954cece22175d55b79e4400b3dda66c716f8a27bdd forge test
```

The additional invariant suites specify 128 runs in Solidity comments. Market, oracle, and swap campaigns use 96 calls per run; the token campaign uses 128. Additional stateless fuzz suites use 512 cases. `fail-on-revert = true` makes an unexpected handler revert fail its campaign. Deliberate negative calls assert the expected error. Handlers restrict valid operations using available balances and lifecycle state; they do not catch and discard arbitrary failures.

## Property selection

The supplied Pashov and Trail of Bits references informed five local review passes: conservation, inverse operations and rounding, state transitions, unauthorized extraction and withdrawal liveness, and token/order-book rules. The properties below come from the approved workflow's obligations and ERC-20 semantics. None requires a change to production contracts.

| Suite | Main properties and failure cases |
| --- | --- |
| `MarketAdversarial.t.sol` | Invalid orders roll back lazy creation, balances and IDs; rejected claim batches roll back earlier claims; expiry includes its exact deadline; excess claims cannot burn shares; all four mirrored match combinations conserve shares; fractional claims pay only once; repeated splits/merges across supported units cannot create dust or profit. |
| `MarketLifecycleInvariant.t.sol` | Three markets, two pinned versions, multiple traders and the fee recipient; time advancement, orders, fills, cancellations, expiry, settlement, partial claims, deposits, withdrawals and donations. Escrowed sell shares remain redemption liabilities after settlement. Every campaign ends by closing all orders, claiming all positions and withdrawing all credits. A deterministic handler test exercises actual fills, winning claims and missing-price refunds. |
| `OracleAdversarial.t.sol` | Exact proof/proposal/dispute/timeout boundaries; wrong chain, block window, price, caller and budget; token failures and withdrawal reentrancy; third-party sponsorship; partial-answer failure; malformed signed answers; consumer binding and attestation UUID replay; exact unused-budget refunds. |
| `OracleBondInvariant.t.sol` | Six boundaries and four funded actors; proposals, disputes, deferred service calls, retries, partial answers in either order, finalization, failure, timeout, donations and withdrawals. Terminal prices cannot change, requests are consumed once, and every campaign releases and withdraws all remaining bond liabilities. |
| `SwapAdversarial.t.sol` | Exact output and input limits; wrong callback data, replay and nested swaps; invalid signed deltas, short output, bad settlement and inconsistent return values; one- and three-hop routes; direct donations remain untouched. Stateful sequences mix successful swaps, rejected swaps and donations. |
| `TokenInvariant.t.sol` | Fixed `10^27` supply and an independent ledger of balances and allowances over transfers, approvals, delegated transfers, overspending attempts and forbidden administrative calls. Explicit tests include zero/self/full-supply transfers, infinite allowance, failed allowance consumption and invalid receivers. |
| `LibraryProperties.t.sol` | RLP decoding against independently encoded integers, strings and lists; malformed lengths and compact trie paths; root/key/value proof binding; exact binary price vectors on both arithmetic branches; monotonicity and nonprofitable quote round trips; median permutation and duplicate-input properties. |
| `RegistryProperties.t.sol` | Unauthorized mutation, invalid units/caps/routes/hooks, cyclic or disconnected paths, pinned IMD pools, period limits, append-only versions, custom-round partitions and contiguous Gregorian months. |
| `ProofTradingIntegration.t.sol` | Actual verifier, oracle, markets and swapper composed together. Genuine bundled mainnet proof bytes attach to orders and claims. Invalid orders, failed swaps, an invalid second proof and excess claims must roll back the first recorded price as well as market state. |

## Independent accounting checks

Market custody equals free user/owner balances plus order cash, asset, swap and fee escrow plus market reserves plus separately tracked donations. A second identity checks custody against the starting balance and the handler's cumulative deposits/withdrawals. These identities run after every randomized action.

The redemption invariant counts both free and escrowed outcome shares. Active markets owe one USDC and their pinned asset units per pair. UP settlement owes both coins for remaining UP shares; DOWN settlement owes both for remaining DOWN shares; refunds owe USDC for UP and the asset for DOWN. Losing shares carry no reserve claim. This avoids incorrectly treating the original pair count as remaining collateral after claims.

Oracle custody equals outstanding proposal/challenge bonds plus withdrawable credits plus donations. Independently, all amounts pulled from actors must equal oracle custody, completed withdrawals and service payments, after accounting for donations. Repeated failed service attempts cannot consume bonds or leave an allowance. The test advances time and drains every remaining credit at campaign end.

Swap checks compare user balance changes, actual manager balances, exact requested output and independently accumulated spend/output totals. The swapper retains only tracked donations between calls. The token suite models balances and allowances independently instead of summing only the contract's own reported aggregates.

## Revision: reopened oracle slots, late finalization, frozen markets and fee floors

- `OracleAdversarial.t.sol`: an unchallenged proposal can never be timed out and still finalizes after the boundary's timeout; a disputed one times out only at `boundary + 3 days`. A refunded slot reopens a fresh proposal (no inherited challenger, requests or answers), and the dead proposal's callbacks (`onOracleResult`, `onFailure`) are refused before and after the new dispute. A live or recorded slot refuses another proposal. `priceable` is checked at each window edge and fuzzed against what a proposal can actually still do.
- `OracleBondInvariant.t.sol`: the handler re-proposes refunded slots, finalizes late unchallenged proposals, expects `timeout` to revert for unchallenged ones, and settles every open proposal by the right route at campaign end. Bond custody identities are unchanged.
- `MarketLifecycleInvariant.t.sol`: `split` on a normal market whose start price can no longer be recorded must revert `InvalidMarket`. Custody stays exact.
- `ProofTradingIntegration.t.sol`: a placement with no recorded price for the version reverts `MissingPrice`, and an attached proof makes it work. A proof somebody else already recorded is skipped. A fee budget one unit below `feeQuote` is refused for both maker and taker.

No defects were found in this revision, so no `.imd-findings.json` is filed. Note for operators: settlement does not finalize pending proposals itself. An unchallenged proposal for a market's end boundary must be finalized before `end + 3 days`, or anyone may void the market first. The brief specifies this void rule.

## Test boundaries

The additional tests are offline. Oracle signatures use a local ERC-1271 fixture; they do not claim a live service attestation. The swap manager is a deterministic exchange and signed-debt model, not a Uniswap liquidity/pricing simulation. The integration suite uses genuine historical Ethereum proof bytes with a fixed local EIP-2935 anchor. The pre-existing `fork/MainnetFork.t.sol` remains the separate live-fork integration suite.

Passing these properties does not establish resistance to the documented three-block spot-price manipulation or optimistic-oracle economic assumptions, and does not replace the workflow's independent source/manifest review.
