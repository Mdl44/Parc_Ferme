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

## Contracts

| Contract | Role |
|---|---|
| `StewardsPanel` | 2-of-3 multisig (EIP-712 signatures, ERC-1271). Owns everything else and holds the fines |
| `SuperLicence` | Soulbound ERC-721 (ERC-5192) with a driver's penalty points, behind a UUPS proxy |
| `TeamBond` | Per-weekend ETH bond of each team; fines priced in EUR via Chainlink; withdrawal pattern |
| `DocumentRegistry` | One Merkle root per weekend for the official PDFs, with IPFS CID |
| `PenaltyLib` | Own library: ban rule, EUR to wei conversion, fine split |

See `docs/DECISIONS.md` for the reasoning and `docs/REQUIREMENTS.md` for the grading map.

## Setup

```bash
git clone --recurse-submodules <repo>
cd contracts && forge build && forge test
cd ../frontend && npm install && npm run dev
```

Deploy locally (start `anvil` in another terminal first):

```bash
cd contracts
forge script script/Deploy.s.sol --rpc-url localhost --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # Anvil's public test key
bash script/export-abis.sh   # copies the ABIs to the front-end
```

Copy `.env.example` to `.env` (git-ignored) before deploying to Sepolia.

## Notes

- This folder is on an NTFS drive that ignores the exec bit, so the front-end scripts call `node node_modules/<tool>/bin/...` directly instead of the `.bin` shortcuts.
- Libraries (forge-std, OpenZeppelin, OpenZeppelin upgradeable, Chainlink) are pinned submodules.
