# Parc Fermé

Formula 1 stewarding on-chain. The FIA stewards' panel (a 2-of-3 multisig) issues penalty decisions that add points to a driver's soulbound super licence and charge fines from a team's bond. The hashes of the official decision documents are committed as a Merkle root, so anyone can verify a PDF.

Course project for Smart Contracts / Web3 Applications.

## Layout

```
contracts/   Foundry project (src, test, script). Libraries in contracts/lib are git submodules
frontend/    Vite + React + ethers v6
data/        FIA decision PDFs and penalties.json (week 3)
docs/        REQUIREMENTS.md: where each grading requirement is covered
```

## Setup

```bash
git clone --recurse-submodules <repo>
cd contracts && forge build && forge test
cd ../frontend && npm install && npm run dev
```

Copy `.env.example` to `.env` (git-ignored) before deploying to Sepolia.

## Notes

- This folder is on an NTFS drive that ignores the exec bit, so the front-end scripts call `node node_modules/<tool>/bin/...` directly instead of the `.bin` shortcuts.
- Libraries (forge-std, OpenZeppelin, OpenZeppelin upgradeable, Chainlink) are pinned submodules.
