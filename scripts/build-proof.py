#!/usr/bin/env python3
"""Build an offline boundary witness using only read-only Ethereum JSON-RPC and Foundry cast.

Usage: python3 scripts/build-proof.py --rpc URL --boundary UNIX_SECONDS --out witness.json
No keys, signing, transactions, environment configuration, or third-party Python packages.
"""
import argparse
import json
import subprocess
import urllib.request
from pathlib import Path

MANAGER = "0x000000000004444c5dc75cb358380d2e3de08a90"
POOLS = [
    "0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3",
    "0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27",
]


def keccak(data):
    return subprocess.check_output(["cast", "keccak", "0x" + data.hex()], text=True).strip()


def rlp(value):
    if isinstance(value, list):
        data = b"".join(map(rlp, value))
        return prefix(data, 192)
    if isinstance(value, int):
        value = value.to_bytes((value.bit_length() + 7) // 8, "big")
    if len(value) == 1 and value[0] < 128:
        return value
    return prefix(value, 128)


def prefix(data, base):
    if len(data) < 56:
        return bytes([base + len(data)]) + data
    size = len(data).to_bytes((len(data).bit_length() + 7) // 8, "big")
    return bytes([base + 55 + len(size)]) + size + data


def header(block):
    fields = ["parentHash", "sha3Uncles", "miner", "stateRoot", "transactionsRoot", "receiptsRoot", "logsBloom",
              "difficulty", "number", "gasLimit", "gasUsed", "timestamp", "extraData", "mixHash", "nonce"]
    optional = ["baseFeePerGas", "withdrawalsRoot", "blobGasUsed", "excessBlobGas", "parentBeaconBlockRoot", "requestsHash"]
    integers = {"difficulty", "number", "gasLimit", "gasUsed", "timestamp", "baseFeePerGas", "blobGasUsed", "excessBlobGas"}
    fields += [field for field in optional if field in block and block[field] is not None]
    encoded = rlp([int(block[f], 16) if f in integers else bytes.fromhex(block[f][2:]) for f in fields])
    if keccak(encoded).lower() != block["hash"].lower():
        raise ValueError("Header hash mismatch: unsupported header format")
    return "0x" + encoded.hex()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rpc", required=True)
    parser.add_argument("--boundary", type=int, required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--proxy", help="Explicit HTTP proxy when a sandbox isolates the RPC endpoint")
    parser.add_argument("--pool-id", action="append", help="One to three pool IDs in asset-to-USDC order; defaults to IMD")
    args = parser.parse_args()
    sequence = 0

    def call(method, params):
        nonlocal sequence
        sequence += 1
        payload = json.dumps({"jsonrpc": "2.0", "id": sequence, "method": method, "params": params}).encode()
        if args.proxy:
            raw = subprocess.check_output(["curl", "-sS", "--fail", "--max-time", "60", "-x", args.proxy,
                                           "--noproxy", "", "-H", "Content-Type: application/json", "--data-binary", "@-", args.rpc], input=payload)
            response = json.loads(raw)
        else:
            request = urllib.request.Request(args.rpc, payload, {"Content-Type": "application/json"})
            with urllib.request.urlopen(request, timeout=60) as result:
                response = json.load(result)
        if "error" in response:
            raise RuntimeError(response["error"])
        return response["result"]

    if int(call("eth_chainId", []), 16) != 1:
        raise ValueError("Ethereum mainnet required")
    head = int(call("eth_blockNumber", []), 16)
    low, high = 0, head
    while low + 1 < high:
        middle = (low + high) // 2
        block = call("eth_getBlockByNumber", [hex(middle), False])
        if int(block["timestamp"], 16) <= args.boundary:
            low = middle
        else:
            high = middle
    if low + 2 >= head:
        raise ValueError("Wait for N+2 and at least one successor block")
    pools = args.pool_id or POOLS
    if not 1 <= len(pools) <= 3 or any(len(p) != 66 or not p.startswith("0x") for p in pools):
        raise ValueError("Supply one to three 32-byte pool IDs")
    slots = [keccak(bytes.fromhex(pool[2:]) + (6).to_bytes(32, "big")) for pool in pools]
    blocks, proofs = [], []
    for number in range(low, low + 3):
        block = call("eth_getBlockByNumber", [hex(number), False])
        proof = call("eth_getProof", [MANAGER, slots, hex(number)])
        by_slot = {int(p["key"], 16): p for p in proof["storageProof"]}
        blocks.append({"number": number, "hash": block["hash"], "timestamp": int(block["timestamp"], 16), "stateRoot": block["stateRoot"]})
        proofs.append({"header": header(block), "accountProof": proof["accountProof"],
                       "storageProofs": [by_slot[int(slot, 16)]["proof"] for slot in slots],
                       "slot0": [by_slot[int(slot, 16)]["value"] for slot in slots]})
    if not blocks[0]["timestamp"] <= args.boundary < blocks[1]["timestamp"]:
        raise ValueError("Boundary not bracketed")
    # Recheck the anchor after collecting proofs, detecting a concurrent reorganization.
    if call("eth_getBlockByNumber", [hex(low + 2), False])["hash"] != blocks[2]["hash"]:
        raise ValueError("Reorganization; rebuild the witness")
    witness = {"chainId": 1, "boundary": args.boundary, "poolManager": MANAGER, "poolIds": pools,
               "slots": slots, "blocks": blocks, "proofs": proofs}
    Path(args.out).write_text(json.dumps(witness, indent=2) + "\n")
    print(f"Saved blocks {low}..{low+2}; {sequence} read-only RPC calls")


if __name__ == "__main__":
    main()
