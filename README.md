# AutoStop — on-chain stop-loss & take-profit on Reactive Omni

**Track: Set It and Forget It** · Reactive Omni Buildathon (Nov 5 – Dec 5, 2026)

Set a price once, walk away. AutoStop watches a DEX pair around the clock and
sells your position the moment your stop-loss or take-profit is hit — no bot,
no keeper, no browser tab left open. The rule lives on-chain as a Reactive
contract; the chain itself wakes it up.

## How it works

```
   user sets a rule once
        │
        ▼
┌─────────────┐  createOrder()   ┌──────────────────┐
│ AutoStopVault│◄─────────────────│  you (EOA)       │
│ (Lasna)      │  holds your mTKN │  stop  <= 0.8000 │
│  callback    │  until triggered │  take  >= 1.2000 │
└──────┬──────┘                  └──────────────────┘
       │ ▲
       │ │ executeOrder() — re-verifies price, swaps, pays you
       │ │
┌──────┴──────┐  requestCallbackV_1_0   ┌──────────────────┐
│ AutoStopVault│◄────────────────────────│ AutoStopReactive │
└─────────────┘                         │ (Lasna)          │
                                        └───────┬──────────┘
                                                │ react(Sync)
                                                ▼
                                        ┌──────────────────┐
                                        │ MockPair Sync    │
                                        │ event (Lasna)    │
                                        └──────────────────┘
```

1. **You create an order** on the vault: which pair, which side, how much,
   stop-loss and/or take-profit threshold. Your tokens move into the vault.
2. **Every price move emits a `Sync` event** on the pair. The Reactive system
   contract delivers it to `AutoStopReactive.react()` (~1s blocks on Lasna).
3. **`react()` evaluates every open order for that pair** on-chain: current
   price vs threshold, 5-minute cooldown, max 5 attempts. A crossed order
   triggers `requestCallbackV_1_0` to the vault.
4. **The vault re-verifies the price on-chain** before selling, so a stale
   trigger can never sell at the wrong price. It swaps through the pair and
   sends the proceeds to you. Order closed, `OrderExecuted` emitted.

## Contracts

| Contract | Chain | Role |
|---|---|---|
| `AutoStopReactive` | Lasna (5318007) | Subscribes to pair `Sync` events, evaluates thresholds, requests callbacks |
| `AutoStopVault` | Lasna (5318007) | Holds orders + user funds, executes sales on callback, refunds on cancel |
| `MockPair` | Lasna (5318007) | Minimal Uniswap V2-style pair: `Sync` events, constant-product swaps, 0.3% fee |
| `MockERC20` (mTKN / mUSDC) | Lasna (5318007) | Demo tokens for the pair |

All four live on Lasna only: one chain, one currency (lREACT), one RPC.
The reactive contract reads the pair's `Sync` event — the exact same event a
real Uniswap V2 pair emits — so pointing it at a real V2 pair on Sepolia
needs no reactive-code change (only the subscribed pair address).

## Design decisions (and their trade-offs)

- **Wildcard pair subscription.** The reactive contract subscribes to
  `Sync` on *any* pair on Lasna (chain id + topic are the specific
  conditions; the pair address is a wildcard). New pairs work with zero
  management. On a quiet testnet the extra `react()` calls are negligible;
  on mainnet you would subscribe per-pair instead.
- **The vault is the single source of truth.** `react()` reads open orders
  from the vault instead of mirroring order state via lifecycle events.
  Fewer moving parts, no state drift.
- **Second price verification.** The vault re-reads reserves inside
  `executeOrder()` and refuses to sell if the price moved back. A trigger is
  a *request*, not a command.
- **Cooldown (5 min) + max 5 attempts** per order, on both sides, so a
  failing callback can't drain funds in a retry loop.
- **`react()` never reverts on a non-matching log** — it returns early.
  A revert would still be charged in full.
- **MockPair, not a real AMM.** Lasna has no deployed Uniswap V2, and the
  point of this track is the automation, not the exchange. The pair
  reproduces V2's event surface and constant-product math faithfully.

## Deployed addresses (Lasna testnet)

> Status: contracts are written, tested locally (8/8 forge tests pass), and
> ready to deploy. **Deployment is pending testnet funds** — Lasna lREACT
> only comes from the Sepolia faucet (send Sepolia ETH to
> `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434`, 1 ETH → 100 lREACT), and the
> deployer wallet currently holds 0 Sepolia ETH. Once ~0.1 Sepolia ETH
> arrives, deployment is one command (below) and this section gets filled in.

| Contract | Address |
|---|---|
| mTKN | _pending_ |
| mUSDC | _pending_ |
| MockPair (mTKN/mUSDC) | _pending_ |
| AutoStopReactive | _pending_ |
| AutoStopVault | _pending_ |

Explorer: https://lasna.reactscan.net/

## Run it yourself

```bash
# 0. Fund the deployer with Sepolia ETH first (see above), then:
#    send 0.1 Sepolia ETH to the faucet contract -> 10 lREACT on Lasna.
#    Deployer address: 0x3b5a98D6c365553a494Ee43037CA6e3919aa86A6 (testnet only)

# 1. Deploy everything (tokens, pair + 1000/1000 liquidity, reactive, vault)
export PRIVATE_KEY=0x...   # Lasna deployer key, testnet only
forge script script/Deploy.s.sol:Deploy \
  --rpc-url https://lasna-rpc.rnk.dev --chain-id 5318007 --broadcast
# -> writes deployments/lasna.env

# 2. Create demo orders: stop-loss 10 mTKN @ <= 0.8000, take-profit @ >= 1.2000
source deployments/lasna.env
forge script script/Demo.s.sol:Demo \
  --rpc-url https://lasna-rpc.rnk.dev --chain-id 5318007 --broadcast

# 3. Crash the price (sell 500 mTKN -> price ~0.44). The reactive contract
#    fires within ~1 second; the stop-loss executes on callback.
forge script script/Trigger.s.sol:Trigger \
  --rpc-url https://lasna-rpc.rnk.dev --chain-id 5318007 --broadcast
#    (SIDE=pump to test the take-profit instead)

# 4. Check health any time
./scripts/status.sh
```

Verify the loop on https://lasna.reactscan.net/: the `Sync` event tx, the
reactive tx it triggered, the callback tx, and the vault's `OrderExecuted`
event — plus `getCallbacks(reactiveTxHash)` on the system contract
(`0x8888888888888888888888888888888888888888`).

## Funding

- Reactive contract: 0.05 lREACT at deploy (covers dozens of `react()` runs;
  each costs roughly 200–400k gas-equivalent at Lasna gas prices).
- Vault: 0.02 lREACT at deploy (callback side; destination is Lasna, so the
  callback is also paid in lREACT).
- Top up either side any time with
  `cast send 0x8888…8888 "depositTo(address)" <contract> --value <amount>`,
  or `coverDebt()` on the contract. **Any debt > 0 halts that contract** —
  check `./scripts/status.sh` before demoing.

## Tests

```bash
forge test
# 8 tests: full stop-loss loop, full take-profit loop, no-trigger in range,
# stale-trigger refusal, cancel refund, subscription on deploy, react()
# onlySystem, executeOrder() proxy+sender auth.
```

The tests etch a `MockSystem` onto the real system address
(`0x8888…8888`) and feed the pair's *real* emitted `Sync` log into
`react()`, so the local loop exercises the same code path Lasna will.

## Submission checklist

- [x] Public repo, open source (this repo)
- [x] Reactive contract + callback contract (Omni style, `reactive-lib-omni` v0.1.0)
- [x] Working demo flow (local end-to-end tests green)
- [ ] Deployed contract addresses on Lasna — **blocked on Sepolia ETH for the faucet**
- [ ] Transaction hashes: origin event → reactive tx → callback tx — **same blocker**
- [ ] Demo video (< 3 min) — recorded after deployment, from the real run

## References

- Reactive docs: https://dev.reactive.network/ (Omni migration, Reactive
  Contracts, Callback Contracts, Economy, Lasna testnet)
- `reactive-lib-omni` v0.1.0: https://github.com/Reactive-Network/reactive-lib-omni
- Official stop-loss demo (Legacy code, logic reference only):
  https://github.com/Reactive-Network/reactive-smart-contract-demos/tree/main/src/demos/uniswap-v2-stop-take-profit-order
- Buildathon: https://blog.reactive.network/reactive-omni-buildathon-thirty-days-to-find-out-what-one-second-buys/
