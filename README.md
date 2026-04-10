# 🪙 Foundry DeFi Stablecoin

A decentralized, algorithmic, USD-pegged stablecoin built with Solidity and Foundry — inspired by MakerDAO's DAI.

---

## What Is This?

This project implements a crypto-collateralized stablecoin system where:

- **1 token = $1.00 USD** at all times (soft peg via overcollateralization)
- Users deposit **wETH or wBTC** as collateral to mint tokens
- **Chainlink price feeds** provide real-time collateral valuations
- The system is **algorithmic and decentralized** — no central authority controls the peg

Think of it as a simplified DAI clone built from scratch to understand how DeFi stablecoin mechanics work under the hood.

---

## Core Properties

| Property | Details |
|----------|---------|
| Stability | USD-pegged ($1.00) |
| Collateral Type | Exogenous crypto (wETH, wBTC) |
| Minting Mechanism | Algorithmic — requires sufficient collateral |
| Price Oracle | Chainlink price feeds |
| Framework | Foundry (Forge + Cast) |
| Language | Solidity |

---

## How It Works

1. **Deposit collateral** — User deposits wETH or wBTC into the protocol
2. **Mint stablecoin** — User mints tokens against their collateral (must stay overcollateralized)
3. **Chainlink oracle** — Real-time ETH/USD and BTC/USD prices keep the collateral ratio accurate
4. **Liquidation** — If a position becomes undercollateralized, it can be liquidated to protect the peg

---

## Project Structure

```
├── src/                  # Core smart contracts
├── script/               # Deployment scripts
├── test/                 # Foundry tests
├── lib/                  # Dependencies (OpenZeppelin, Chainlink, etc.)
├── .github/workflows/    # CI pipeline
└── foundry.toml          # Foundry configuration
```

---

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
- Git

### Installation

```bash
git clone https://github.com/heisenberg2687/foundry-defi-stablecoin
cd foundry-defi-stablecoin
forge install
```

### Build

```bash
forge build
```

### Run Tests

```bash
forge test
```

### Deploy (local Anvil node)

```bash
anvil
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast
```

---

## Key Concepts Implemented

- **Overcollateralization** — collateral value must always exceed minted token value
- **Liquidation engine** — protects protocol solvency when positions go underwater
- **Chainlink integration** — trustless price feeds with staleness checks
- **DSCEngine** — the core logic contract managing minting, burning, and liquidation

---

## Acknowledgements

Built following the [Patrick Collins](https://github.com/PatrickAlphaC) Foundry DeFi course. Great resource for learning production-level Solidity and DeFi primitives.
