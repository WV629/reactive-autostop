# AutoStop — DoraHacks submission pack

Hackathon: **Reactive Omni Buildathon** (Nov 5 – Dec 5, 2026) · Track: **Set It and Forget It**
DoraHacks account (already registered): **wvllm** — https://dorahacks.io/builder/wvllm
(email-code login, wv520629@gmail.com; no password flow — the user logs in)

## Submission copy (paste-ready)

**Project name:** AutoStop

**Tagline:** Set a price once, walk away — on-chain stop-loss & take-profit that
sells your position the moment the price crosses your line. No bot, no keeper,
no browser tab left open.

**Description:**
AutoStop watches a DEX pair around the clock and sells your position the moment
your stop-loss or take-profit is hit. The rule lives on-chain as a Reactive
contract; the chain itself wakes it up.

How it works:
1. You create an order on the vault: which pair, which side, how much,
   stop-loss and/or take-profit threshold. Your tokens move into the vault.
2. Every price move emits a `Sync` event on the pair. The Reactive system
   contract delivers it to `AutoStopReactive.react()` (~1s blocks on Lasna).
3. `react()` evaluates every open order for that pair on-chain: current price
   vs threshold, 5-minute cooldown, max 5 attempts. A crossed order triggers
   `requestCallbackV_1_0` to the vault.
4. The vault re-verifies the price on-chain before selling, so a stale trigger
   can never sell at the wrong price. It swaps through the pair and sends the
   proceeds to you. Order closed, `OrderExecuted` emitted.

Design points: wildcard pair subscription (new pairs work with zero
management); the vault is the single source of truth (no state drift); second
price verification in the vault; cooldown + retry caps so a failing callback
can't drain funds; `react()` never reverts on a non-matching log.

Built with `reactive-lib-omni` v0.1.0 (Omni style: `SYSTEM.subscribe`,
`requestCallbackV_1_0`, `onlySystem`, `onlyServiceProvider` +
`onlyCallbackSender`).

**Repo:** https://github.com/WV629/reactive-autostop

**Demo video:** `demo-video/autostop-demo.mp4` (84s, 1280x720) — STATUS: draft,
see note below. Rebuild script: `demo-video/build-video.py`.

## Live proof (Lasna testnet, chain 5318007)

| Item | Address / hash |
|---|---|
| AutoStopReactive | `0x67cE360Dc6B6eB82b611f17e37271D6A7b1AC4D4` |
| AutoStopVault | `0x452dFB22C0d999cE35A340bC8f55392Ed01143F1` |
| MockPair (mTKN/mUSDC) | `0xAb2EeEfd147C9130BC78302F7be5607738c5436F` |
| mTKN / mUSDC | `0xA4189Dd45FbC861497C67f8A3c06768ACBbE8d3E` / `0x49EaC4c23c354d8e2097D6d68c3A5B4c6a245EEb` |
| Order 0 created (stop-loss <= 0.8000) | `0x8745d53ccaead7bf5eb632ab1cdcf61dce7c134c5c3cc217e1cd4c1ed5be6438` |
| Order 1 created (take-profit >= 1.2000) | `0xa995cc84d4e849a94a0d3123a50c4834d31d49615a37e2561276abbaa7f7f0a7` |
| Origin event (crash swap, price 1.0 -> 0.4448) | `0x2fd87f6020e8ca752dd91fc7d9ab3c1ee8d70222cbf89def1e57009f80da80ea` (block 9200663) |
| Reactive tx (`react()` fired, `OrderTriggered`) | `0x9508e39efab62923228590f110b09bf939dc3cb0962c9def06b50941270275f1` (block 9200664) |
| Reactive tx #2 (second trigger, price 0.4448 -> 0.2504) | `0x24715ffd05118640c6709f7a0123394bc302d278ab7717a7b057455462df9764` (block 9201315) |
| Callback tx (vault `OrderExecuted`) | PENDING — Lasna relay stalled, see below |

Explorer: https://lasna.reactscan.net/

## Known blocker (be honest in the submission if it is still open)

The callback leg is stalled **network-wide on Lasna**, not by our contracts:
official Reactive MCP `trace_reactive_tx` on the reactive tx returns
`CALLBACK_NOT_POSTED` — "no CallbackPosted event exists on this network in
the last 30,000 blocks: results are not being posted back". `getCallbacks()`
is empty for our callback AND for every other recent `CallbackRequest` on
Lasna (sampled incl. ~3h-old ones). Reaction itself is proven (REACTED).
Full diagnosis: `deployments/DEPLOYMENT-20261125.md` §5.

If the relay recovers before Dec 5: re-run Trigger, capture the callback tx +
`OrderExecuted`, re-record the video, and update this pack. Do NOT submit a
video that claims a completed sale before it exists.

## How to submit (user steps — assistant must not log in for the user)

1. Open DoraHacks and log in as **wvllm** (email-code login to
   wv520629@gmail.com).
2. Open the Reactive Omni Buildathon page, find the BUIDL / Submit entry for
   the **Set It and Forget It** track.
3. Create / edit the submission with the copy above, repo link, demo video
   link, and the contract addresses + tx hashes from the table.
4. Submit before **Dec 5, 2026**. Keep the submission's demo video link
   pointing at the final re-recorded video once the callback lands.
