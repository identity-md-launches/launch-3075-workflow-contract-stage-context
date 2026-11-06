# Local validation record

Validated on 2026-11-06 with Foundry **1.8.3**, Solidity **0.8.26**, Cancun, IR compilation, optimizer enabled with **1 run**, and `bytecode_hash = "none"`. This record reports contributor checks; it is not an independent attestation or security approval.

## Required checks

| Check | Result |
| --- | --- |
| `forge build --sizes` | Pass; all six deployable contracts below EIP-170 and EIP-3860 limits |
| `forge test` | **93 passed, 0 failed, 0 skipped** across eight suites |
| Required fuzz seed | `0x575cc7802996bba860ac81954cece22175d55b79e4400b3dda66c716f8a27bdd` |
| Fuzz cases | 256 per parameterized fuzz test |
| Stateful accounting checks | 64 runs × 48 calls, with three invariant properties checked together |
| `forge fmt --check` | Pass |
| `forge fmt --check fork` | Pass |
| `python3 scripts/export-abi.py` | All six ABI JSON files regenerated from the final source |
| Mainnet fork at block 26357170 | **4 passed, 0 failed, 0 skipped** |

## Offline suite coverage

| Suite | Checks |
| --- | --- |
| `LaunchTokenTest` | Fixed 10^27 supply, factory/deployer balance, name/symbol/decimals, exact transfers/allowances, forbidden mint and invalid transfers |
| `RegistryTest` | Initial pool IDs, enumeration, hour/day/Monday/Gregorian months, leap centuries, fuzzed calendar bounds, authorization, immutable versions, invalid routes/units, initialization-only hook support |
| `MarketsTest` | All four pairwise action combinations, price/time priority, partial fills, prices above 1 and very large prices, min value/ticks/expiry, IOC bounds, capped continuations, failed queued swaps, fee-budget floors at placement and exhaustion later, frozen normal markets whose start price can no longer be recorded, attached proofs skipping recorded boundaries, hints, splits/merges, all settlement outcomes, voids, claims/batches, version snapshots, pair caps, fractional-rounding fuzzing, token failures and reentrancy error verification |
| `BoundaryOracleTest` | Proof timing, latest-price monotonicity, proposals, challenge windows, canonical questions, distinct request ID namespaces, valid/invalid signed responses, replay, block-hash consistency, panel/quorum, oracle fee bounds, atomic two-request rollback, deferred retries, bond conservation, failure and timeout refunds, reopened slots after a refund with dead stale callbacks, late unchallenged finalization after the timeout, the `priceable` view across every window, and 10^36-based hop answers for low-valued routes |
| `BoundaryProofTest` | Genuine three-block/two-pool account and storage proofs, corrupt nodes/headers, wrong pools, wrong block proofs, boundary brackets, history range, extra/missing nodes, strict RLP, inline trie branch/extension/leaf vectors, missing keys, fuzzed proof corruption |
| `SwapTest` | Authenticated unlock callback, exact-output route, signed deltas, intermediate netting, maximum input, short output, token quirks, reentrancy error verification, input conservation fuzzing |
| `DeploymentTest` | Empty-chain constructors, explicit owner arguments, whole launch supply retained by a simulated factory, deployed runtime size and reachable forbidden-opcode checks |
| `AccountingInvariantTest` | Every coin accounted for as free balance/order escrow/fees/collateral; every share exactly backed; both book lists remain sorted, linked and FIFO |

Foundry reports the three simultaneous invariants as one grouped test. The handler exercises deposits, withdrawals, splits, merges, trades, cancellations and permissionless continuation with the same specified fuzz seed. No test reads or changes environment variables, enables FFI, or requires file permissions.

## Mainnet integration

The fork tests use the supplied read-only Ethereum RPC and block **26357170**. They execute against the real deployed USDC, IMD, PoolManager and history contract. Test balances are created only in the fork. There were no broadcasts, signature requests to a wallet, or real token transfers.

- Historical proof verification against the actual EIP-2935 anchor: pass, approximately **5.61 million gas** for recording this two-pool witness.
- Exact-output IMD → native ETH → USDC swap against PoolManager: pass.
- Too-small input budget and rollback against the real pools: pass.
- Deposit real tokens, record the proven price, rest an IMD-only short and match an UP buyer with exact collateral/cleared approval: pass, approximately **8.26 million gas** for the complete test action sequence.

The regular suite embeds the same raw proof bytes as Solidity constants and needs no RPC. `test/fixtures/mainnet-boundary.json` retains the readable witness; `MainnetFixture.sol` supplies its offline equivalent. The fixture's authenticated newest hash is:

`0x60efea6c813136cde6e5824600529ec18ce246b57017a6616e49c4e7eb6931e7`

The sample path prices are 2478148650031285361, 2477558951893506682, and 2477558951893506682 in 18-decimal USD. The expected median is computed independently with Python integer arithmetic when preparing the fixture.

## Deployable runtime sizes

| Artifact | Bytes |
| --- | ---: |
| `LaunchToken` | 1,503 |
| `PimdRegistry` | 5,094 |
| `BoundaryProofVerifier` | 6,919 |
| `BoundaryOracle` | 16,548 |
| `PimdSwap` | 4,090 |
| `PimdMarkets` | 22,401 |

These are built runtime lengths, including fixed-length immutable reference locations. Application constructors contain no external calls. The tested factory deployment retains the entire launch token supply until the protocol performs its own distribution. The application has no reachable DELEGATECALL, CALLCODE or SELFDESTRUCT.

The signer path uses a test-only ERC-1271 signer and deterministic test key; no live oracle service was purchased. ABI shape, canonical hashing, and callback ID semantics were checked against the published service documentation and public data. The initial pools and pricing/storage assumptions were checked against mainnet. Independent adversarial review, verifier static analysis, source publication, signed artifact linkage and deployment remain later workflow responsibilities.
