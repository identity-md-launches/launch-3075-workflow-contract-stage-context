# pIMD contracts

pIMD is an Ethereum Up/Down prediction market on the IMD price. This repository implements the contract stage: the fixed-supply launch token, immutable market contracts, tests, a historical-proof builder, and ABI exports. Publishing, the independently generated `launch.json`, independent security review, deployment, explorer verification, and the IPFS website belong to subsequent workflow stages. Nothing here broadcasts transactions or manages a wallet key.

## Build and checks

Foundry runs from this repository root. All Solidity dependencies are ordinary vendored files; no network, package installation, submodule, environment-dependent test configuration, FFI, or filesystem cheatcode permission is needed for the default suite. The compiler is **Solidity 0.8.26**, with optimization, IR compilation, Cancun instructions, and `bytecode_hash = "none"`.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x575cc7802996bba860ac81954cece22175d55b79e4400b3dda66c716f8a27bdd forge test
forge fmt --check
python3 scripts/export-abi.py
```

The separate, optional fork suite uses real Ethereum USDC, IMD, PoolManager, and EIP-2935 history at block **26357170**:

```sh
FOUNDRY_PROFILE=fork forge test --fork-url YOUR_ETHEREUM_ARCHIVE_RPC --fork-block-number 26357170
```

The ordinary suite replays genuine mainnet account/storage proofs from blocks **26357164–26357166**, so it remains useful offline. The reference boundary is **1793984400**, with median price **2477558951893506682** in 18-decimal USD per IMD. See [validation](docs/VALIDATION.md), [security review handoff](docs/SECURITY.md), and [ABI guide](docs/ABI.md).

## Deployment parameters

Deploy in this order. All constructors are nonpayable, contain no external calls, require no deployed dependencies during construction, and take only static address arguments. There are five application contracts, plus the launch token. No linked library, proxy, initializer, or upgrade step is required.

| Contract | Constructor arguments, in order |
| --- | --- |
| `LaunchToken` | None |
| `PimdRegistry` | `$owner` |
| `BoundaryProofVerifier` | None |
| `BoundaryOracle` | `$contract:PimdRegistry`, `$contract:BoundaryProofVerifier` |
| `PimdSwap` | `$contract:PimdRegistry` |
| `PimdMarkets` | `$owner`, `$contract:PimdRegistry`, `$contract:BoundaryOracle`, `$contract:PimdSwap` |

`$owner` is **0x3c587eff6c96eacf7e3dcc2cff6416161386e48c** under this assignment. The registry and market fee recipient must use that same owner. Neither the factory nor the deploying service is an administrator. The token does not grant application authority and is not an application collateral asset at launch. Every application dependency must refer to the corresponding contract above; constructors intentionally do not call other contracts to validate that wiring.

The Ethereum external addresses and initial route are fixed from the approved brief and exercised on the fork:

| Purpose | Address / pool |
| --- | --- |
| USDC, 6 decimals | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| IMD, 18 decimals | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` |
| Uniswap v4 PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| IMD/native ETH pool | `0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3`, fee 10000, spacing 200, no hook |
| Native ETH/USDC pool | `0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27`, fee 500, spacing 10, no hook |
| EIP-2935 history | `0x0000F90827F1C53a10cb7A02335B175320002935` |
| IdentityMD Intake | `0xa43e6F75ee006411F79Ac1C84120606C2330DE82` |
| Oracle signer | `0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982` |

The initial IMD route remains fixed even if the owner changes its units or pair limit. Future assets may have one to three connected, acyclic v4 pools with no swap/liquidity/delta hook callbacks ending in USDC. Their market version pins that same route for proofs and swaps.

## Markets, shares, and balances

Markets are keyed by `(asset address, period ID, UTC start, ladder strike)`. Strike zero selects a normal Up/Down round. Positive strike selects a ladder (UP = YES, DOWN = NO), with at most three significant decimal digits. A first limit/market order or split creates the market. Creating future rounds is supported; an existing market's asset version, units, maximum pairs, boundaries, and ladder strike never change.

Initial period IDs are 0 hourly, 1 daily, 2 weekly starting Monday 00:00 UTC, and 3 Gregorian calendar month. Monthly calculations include century/leap-year rules. A normal market compares the price at its start and end, even if it was first traded later. A ladder compares the end price to its fixed strike. Trading stops exactly at the end timestamp. Splitting and merging remain possible until settlement, including after trading ends.

A normal market needs its start price. While `BoundaryOracle.priceable(version, start)` is true (the price exists, a proof or proposal can still record it, or a proposal is live), the market trades normally. Once that is false the void is certain, so `place`, `split` and `matchMarket` revert with `InvalidMarket`; `cancel`, `expire`, `merge`, settlement and claims still work. This can only happen to periods longer than 71 hours (weekly, monthly, long custom periods) whose start boundary nobody proved within 27 hours or proposed within three days; hourly and daily markets end before that point. Ladder markets do not depend on the start price. The website should check `priceable` for the start boundary before offering a normal market, and should prove start boundaries itself when nobody has.

Shares have **6 decimals** and are held in `positions`, not transferable ERC-20 tokens. For IMD, `split(n)` debits `n` USDC minor units and `n × 10^12` IMD minor units, creating equal UP and DOWN quantities. `merge(n)` burns both and reverses those exact debits. For another version, the asset factor is `unitsPerShare / 10^6`; units must be divisible by `10^6`, so backing never rounds down. The default limit is **1,000,000 open pairs per market**. Matching two new positions creates a pair; matching two holders burns a pair; one holder against a new buyer transfers the corresponding outcome.

At settlement, UP wins on `close > strike`, DOWN on `close < strike`. A winning share receives its fraction of **both** collateral coins; the loser receives nothing. Equality or a void returns USDC to UP and asset collateral to DOWN. This is redemption by side, not reversal of historical trades. Anyone may settle, or void if a required price is still missing three days after the market end. A settled outcome never changes, even if a price later appears. Claims credit internal balances; withdrawals are separate, so a token transfer failure cannot block settlement or erase a claim.

Deposits credit only the exact tokens received. Withdrawals take only the caller's free balance. Locked collateral, resting orders, bonds, and accrued fees cannot be withdrawn as somebody else's funds. The owner has no sweep, pause, arbitrary payout, or upgrade function. Unsolicited direct token transfers are donations without a recovery mechanism. Supported assets must be conventional, non-rebasing ERC-20s; assets with mutable transfer taxes are unsuitable. USDC issuer freezes can delay deposits and withdrawals.

## Mirrored order book

The book uses **USDC per UP share**, represented with 6 decimals, at a tick of **100** (USD 0.0001). Values above USD 1 are supported. The four explicit actions avoid ambiguity when a user already holds shares:

| Action | Book side | Cash flow per filled share at `x` | Asset flow | Shares |
| --- | --- | --- | --- | --- |
| Buy UP | Bid | Pay `x` USDC | None | Receive UP |
| Buy DOWN | Ask | Pay `max(0,1-x)` or receive `max(0,x-1)` USDC | Pay one asset unit | Receive DOWN |
| Sell UP | Ask | Receive `x` USDC | None | Sell held UP |
| Sell DOWN | Bid | Receive `max(0,1-x)` or pay `max(0,x-1)` USDC | Receive one asset unit | Sell held DOWN |

Execution uses the resting maker's price, best price first and FIFO within a price. Partial fills retain priority. Limit orders rest; `immediateOrCancel=true` implements market orders with the supplied limit as the worst acceptable mirrored price. DOWN buyers therefore specify a minimum mirrored price. Unfilled IOC quantities return to balance. The order must initially have at least **USD 1 of mirrored UP notional**, `quantity × limitPrice / 10^6`; later partial/dust fills may be smaller. Any positive tick-aligned price representable by the `uint128` field is supported when the trader can fund it.

Resting expiry is selected by the user, from five minutes after submission through market end. Cancellation is always available to the maker. Anyone can release expired orders with `expire`; matching also removes expired makers. Onchain state cannot update merely because time passed, so expiry refunds require a transaction. Resting shares must be cancelled/expired before they can be claimed.

Each transaction examines at most the user's `maxSteps`, capped at **64**, counting expirations and failed orders as well as fills. A limit remainder stays escrowed, including when matching stops at the cap; an IOC remainder is returned. Anyone may call `matchMarket` to continue a capped sweep, and each new order also advances matching. A temporarily crossed book therefore represents pending executions. Matching always uses the best bid and ask, FIFO within each price; the earlier of those orders is the maker. A pair-cap shortage leaves limit orders resting until capacity becomes available, cancellation, or expiry. A resting order supports at most **1024 fills**, then releases its remainder. Linked insertion can scan up to **128 orders**; an existing predecessor hint supports constant-cost insertion beyond that limit. Hints are validated against market, side, price, and time priority.

USDC execution amounts round up once per fill and are applied symmetrically to the two parties. A refundable **1024-micro-USDC rounding reserve** accompanies cash-spending orders so a series of fractional fills cannot exhaust funds locked using a single whole-order multiplication. This is collateral, not a fee; all unused amounts return on close. Fractional execution may differ from the exact price product by less than one micro-USDC per fill. The client also chooses a separate **fee budget in the side's coin**. At placement it must at least pay the order's own full execution at its limit price under the latest boundary price: the maker fee for a resting order, the taker fee for an immediate-or-cancel order (`feeQuote` gives both). A smaller budget is refused with `InvalidOrder`, so an order that could never fill cannot occupy book priority or takers' matching steps; placement therefore needs a recorded boundary price for the asset version, as matching already did. If a later fee no longer fits a maker's budget, that maker is cancelled; a taker with insufficient fee budget reverts. Price improvement and unused fee/swap reserves are released when the order closes.

An IMD-only Buy DOWN locks the pair's IMD, its chosen maximum swap input, and its IMD fee budget. The maximum must cover a boundary-price estimate plus the required **5% buffer**. Each partial fill receives its proportional share of the remaining swap budget. The adapter performs exact-output swaps backwards through the fixed route inside one v4 unlock, nets intermediate ETH, and pays only IMD. Exact output and the input maximum are checked both by the adapter and the market. A failed resting swap cancels that maker and matching continues; a failed taker swap reverts the transaction. Approvals are exact and cleared after use.

## Fees

Let `P` be USD per collateral asset unit at the latest recorded boundary for that asset version, `V = 1 + P`, and `q = clamp(x / V, 0.01, 0.99)`.

- Taker: `0.07 × q × (1-q) × V` USD per share.
- Maker: `0.01 × q × (1-q) × V` USD per share.
- 25% of the taker's charged fee is immediately credited to the maker, in the taker's payment coin; the owner receives the rest plus the maker fee.
- UP actions pay USDC. DOWN actions pay the collateral asset, converted at `P`. Fixed-point intermediate products round down; the final charge rounds up to one atomic payment unit. The rebate rounds down.
- Cancellation, expiry, split, merge, settlement, and redemption have no application fee. Underlying v4 swap fees and gas are additional costs.

At `P = USD 1`, `x = USD 0.60`, ten shares cost a taker USD **0.294**, a maker USD **0.042**, with a USD **0.0735** taker rebate. Fees use the latest recorded boundary, not a live swap quote, and therefore can be stale when nobody records newer boundaries. A missing initial price blocks matching; it does not invent a bootstrap price.

## Boundary proofs and fallback

`prove` records a price once per `(asset version, boundary)` during the first **27 hours**. The timestamp must be a boundary of an enumerated period. The proof contains RLP headers for N, N+1, N+2 and the PoolManager account/storage proofs at each block. The newest header is authenticated by EIP-2935; parent hashes authenticate the older headers. The verifier checks `timestamp(N) <= T < timestamp(N+1)`, consecutive numbers, state roots, account inclusion, and the slot0 storage at `keccak256(abi.encode(poolId, uint256(6)))`. The secure-trie key hashes that slot again. Each block's complete path is quoted using its proven sqrt prices, then the median of the three path prices is recorded. A spot price or caller-chosen header alone is insufficient.

EIP-2935 serves **8191 blocks**, not an exact wall-clock duration. Both the 27-hour application deadline and the history contract's actual range must hold. Anyone can supply the witness; no designated keeper or backend signature is needed. `placeWithProofs` and `claimWithProofs` accept up to two proofs in the same transaction; a proof for a boundary that somebody else already recorded is skipped rather than reverting the order or claim. Submit old boundaries separately if a client needs more. The standalone builder uses read-only RPC methods:

```sh
python3 scripts/build-proof.py --rpc YOUR_ETHEREUM_ARCHIVE_RPC --boundary UNIX_SECONDS --out witness.json
```

After 27 hours, anyone may propose a positive price and the candidate N with a **10 IMD** bond. A proposal needs a full **one-hour** challenge window before the boundary's three-day timeout, so the last proposal can be made one hour and one second before it. Unchallenged proposals become final only through `finalize`, which anyone may call at any time after the hour, including after the three-day timeout; the bond becomes withdrawable credit. `timeout` never applies to an unchallenged proposal.

A challenger posts another 10 IMD and advances a capped oracle-cost budget. The contract asks two `uint256` questions for IMD's two pools (one per hop for future assets), using `oracle.request@oracle-1`, chain evidence, `univ4-spot`, absolute N..N+2, five panel members and quorum four. Each question asks for currency1 atomic units per **10^36** currency0 atomic units (`sqrtPriceX96^2 × 10^36 / 2^192`, rounded down), so a hop whose currency0 is worth less than one currency1 atomic unit per 10^18 units still gets a nonzero, precise answer; the largest v4 ratio times 10^36 fits a `uint256`. Each question requires the boundary timestamp bracket. Costs use Intake `priceOf` or **0.5 IMD per question** when unavailable/zero, never more than one losing bond in total. Both requests and payments are atomic. If the oracle is unavailable or too expensive, the challenge still prevents uncontested finalization; anyone may fund `retryResolution`, and timeout remains available. An affordable published quote must be covered by the initial challenge budget. Unspent budgets become withdrawable credit.

The signed IdentityMD v2 EIP-712 domain is chain 1 and the `BoundaryOracle` address. The callback must come from the fixed Intake for a pending request. The signed question hash is computed from canonical JSON, includes the consumer/version, and pins the window and pool. The signed oracle request ID differs from the Intake callback ID; it is checked for replay, while the question binds the answer to the local request. The answer must be type 3, with panel ≥5, quorum ≥4, `quorum <= agreed <= panel`, a matching window, nonzero block hash, and current issuance/expiry bounds. EOA and ERC-1271 signers are supported through `SignatureChecker`.

The fallback composes the **median quote of each pool**; the direct proof takes the **median of each block's complete path price**. These filters can differ when the two pools move in different orders. This is an explicit consequence of the requested two independent `univ4-spot` questions; the fallback price is the value used to decide its bond dispute. Proposals should use that fallback convention. A proposed value equal to the resolved value wins; otherwise the challenger wins. The successful fee payer is reimbursed from the loser's bond, and the winner receives the two bonds minus that cost. On oracle failure, both bonds are returned intact; the advanced third-party service cost is not refunded. A silent oracle also releases both bonds of a disputed proposal at the boundary's three-day timeout. A refunded proposal frees its `(version, boundary)` slot: while the proposal window is still open (one hour before the timeout), anyone may propose again, and the dead proposal's oracle requests can no longer affect the new one. The contract cannot check that N straddles the boundary; the panel does, and refuses a false window. A proposer who picks a false window and is disputed therefore gets a refund rather than losing the bond, and costs the challenger one oracle fee per round; it cannot lock the boundary, but repeated rounds consume the window, so observers should dispute false proposals early and prove boundaries within 27 hours whenever possible. The market voids if no price exists at its end plus three days.

## Launch token and policy differences

`LaunchToken` is named and symbolized **pIMD**, has 18 decimals, and mints exactly **1,000,000,000 tokens (10^27 minor units)** to its deploying factory. It has no owner, mint entry point, burn entry point, tax, pause, blacklist, limit, or upgrade function.

The approved workflow's website text requested 50% burned, 35% pool, 10% swarm, 5% developer. The assignment's binding launch policy instead distributes **35% pool, 10% swarm, 55% paying wallet/treasury** through the factory. This source does not burn 50% or reserve 5% for a developer; no application receives launch supply. The launch pool pairs pIMD with IMD, fee **12500 (1.25%)**, tick spacing **60**, and manifest initialPrice **79228162514264337593543950336**. The deployer derives the effective opening price from the policy's **2500 IMD** whole-supply opening cap. Pool trading fees are the factory's 1% paying wallet plus 0.25% IMD; the token adds none. The factory supplies liquidity and the MerkleDistributor/initialization guard; this repository does not redeploy them.

## After launch

There are no missing requester-owned service values or mandatory owner initialization calls. The factory deployments are sufficient. The owner may use `PimdRegistry.configureAsset` to add assets or create a new future-market configuration, and `addPeriod` to append a custom fixed-duration UTC period. Obtain each asset's real ERC-20 address, exact units and v4 pool keys from its chain deployment and verify token behavior and pool liquidity before listing it. Paths must end in USDC. Future assets may use initialization-only hooks (including a factory pool guard); hooks with other callback permission bits are rejected. The IMD route cannot change. The selected bounds are 1–3 hops, units between `10^6` and `10^24`, at most `10^24` six-decimal pairs, 32 periods, and custom durations from 5 minutes through 366 days. These limits are named/validated in source.

The website should enumerate registry assets/periods, display predicted future strikes as estimates, build proofs, show budgets and rounding collateral, expire orders before claiming locked shares, and index the events described in the ABI guide. It should correct the superseded tokenomics text before publication. The owner withdraws only credited fees through the same `withdraw` function as users. The fixed oracle signer and Intake cannot be rotated; service failure leads to retries/timeouts/voids, not administrative replacement. Independent reviewers should assess the risks in [SECURITY.md](docs/SECURITY.md) before the services publish and deploy the accepted source.
