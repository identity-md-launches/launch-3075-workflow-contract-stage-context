#!/usr/bin/env python3
"""Export deployable contract ABIs from the pinned Foundry build. No network is required."""
import json
import subprocess
from pathlib import Path

CONTRACTS = ["LaunchToken", "PimdRegistry", "BoundaryProofVerifier", "BoundaryOracle", "PimdSwap", "PimdMarkets"]
destination = Path("docs/abi")
destination.mkdir(parents=True, exist_ok=True)
for name in CONTRACTS:
    raw = subprocess.check_output(["forge", "inspect", f"src/{name}.sol:{name}", "abi", "--json"], text=True)
    abi = json.loads(raw)
    if not isinstance(abi, list):
        raise ValueError(f"Unexpected ABI for {name}")
    (destination / f"{name}.json").write_text(json.dumps(abi, indent=2) + "\n")
    print(f"Exported {name}")
