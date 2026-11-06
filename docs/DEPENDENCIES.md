# Vendored dependencies

All dependencies are committed as ordinary source files. No submodule or package manager is required by the verifier.

| Directory | Upstream release | Included material | License |
| --- | --- | --- | --- |
| `lib/openzeppelin-contracts` | `OpenZeppelin/openzeppelin-contracts` **v5.1.0** | `contracts/`, `LICENSE` | MIT |
| `lib/forge-std` | `foundry-rs/forge-std` **v1.9.7** | `src/`, license files | MIT / Apache-2.0 |

OpenZeppelin supplies ERC-20 behavior, SafeERC20, reentrancy guards, full-precision arithmetic, EIP-712, signature checking, and decimal/hex formatting. Its `forceApprove` is used for exact, short-lived allowances. Forge Standard Library is test-only. RLP/MPT, calendar, path quote math, question construction, and the application contracts are source in this repository.

Sources were retrieved from the corresponding pinned GitHub release archives. The project does not need to retrieve them during compilation. ABI generation uses the locally pinned Foundry build; the optional proof builder uses Python's standard library and the installed `cast` executable.
