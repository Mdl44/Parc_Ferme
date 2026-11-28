# Parc Fermé

[![CI](https://github.com/Mdl44/Parc_Ferme/actions/workflows/ci.yml/badge.svg)](https://github.com/Mdl44/Parc_Ferme/actions/workflows/ci.yml)

Formula 1 stewarding on-chain. The FIA stewards' panel (a 2-of-3 multisig that is also an ERC-4337 smart account) issues penalty decisions that add points to a driver's soulbound super licence and charge fines from a team's bond. Every decision carries the hash of the official FIA document it comes from, and each weekend's documents are committed as one Merkle root, so anyone can verify a PDF.

The data is real: the 724 FIA documents of the ten 2026 race weekends after the summer break (Zandvoort to Las Vegas), from which the grid and the 28 penalty decisions are extracted.

Course project for Smart Contracts / Web3 Applications.

## Layout

```
contracts/   Foundry project (src, test, script). Libraries in contracts/lib are git submodules
scripts/     Node scripts: fetch and process the FIA documents, seed a local chain, upgrade the licence
data/        documents.json, grid.json, penalties.json and the Merkle trees (the PDFs themselves are not in git)
frontend/    Vite + React + ethers v6
```

## Contracts

| Contract | Role |
|---|---|
| `StewardsPanel` | 2-of-3 multisig: EIP-712 signed decisions (`executeDecision`) and ERC-4337 UserOperations through the EntryPoint (`executeBatch`, the panel pays its own gas). ERC-1271. Owns everything else and holds the fines |
| `SuperLicence` | Soulbound ERC-721 (ERC-5192) with a driver's profile and penalty points, on-chain `tokenURI` (JSON + SVG), behind a UUPS proxy |
| `SuperLicenceV2` | The upgrade: penalty points expire 12 months after they were given |
| `TeamBond` | Per-weekend ETH bond of each team; fines priced in EUR via Chainlink; debt; withdrawal pattern |
| `DocumentRegistry` | One Merkle root per weekend for the official PDFs, with IPFS CID |
| `PenaltyLib` | Own library: ban rule, EUR to wei conversion, fine split |

## Setup

Needs Foundry, Node 22+ and, only for rebuilding the data from the PDFs, `pdftotext` (poppler).

```bash
git clone --recurse-submodules https://github.com/Mdl44/Parc_Ferme.git
cd Parc_Ferme/contracts && forge build && forge test
cd ../scripts && npm install
cd ../frontend && npm install
```

## Local chain with the 2026 season

```bash
anvil                                   # in its own terminal

cd contracts
forge script script/Deploy.s.sol --rpc-url localhost --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # Anvil's public test key
bash script/export-abis.sh

cd ../scripts
npm run seed          # replays Zandvoort to São Paulo; Las Vegas is left open for a live demo (--all to close it too)
npm run upgrade       # optional: upgrade the licence to V2 through a stewards decision
npm run warp -- 365   # optional: move the chain a year forward (points expire on V2)
npm run prices        # refresh the mock price feeds (fines need a price younger than one day)
```

Accounts all come from Anvil's public test mnemonic (`test test ... junk`), never use them on a real network:

| Index | Role |
|---|---|
| 0 | Deployer |
| 1, 2, 3 | Stewards |
| 10 to 20 | Teams, in the order of `data/grid.json` |
| 30 to 65 | Drivers, in the order of `data/grid.json` |

## Data

```bash
cd scripts
npm run fetch   # download the FIA documents (about 250 MB, skips files already there)
npm run data    # hash the PDFs, extract the grid and penalties, build the Merkle trees
```

`data/documents.json` lists every document with its `keccak256`; `data/merkle/` holds one tree per weekend and is rebuilt in CI to prove it matches the hashes.

Copy `.env.example` to `.env` (git-ignored) before deploying to Sepolia.
