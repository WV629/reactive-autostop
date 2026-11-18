#!/usr/bin/env bash
# Fund the reactive + vault contracts with lREACT (Lasna) after deployment.
# forge script's local simulation can't do ETH-value calls, so funding lives
# here as plain `cast send` txs from the deployer EOA.
# Usage: source deployments/lasna.env; PRIVATE_KEY=0x... ./scripts/fund.sh
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"

LASNA_RPC="${LASNA_RPC:-https://lasna-rpc.rnk.dev}"
CHAIN_ID="${CHAIN_ID:-5318007}"
# Pick up addresses from the deploy output if not already exported.
if [ -f deployments/lasna.env ]; then set -a; source deployments/lasna.env; set +a; fi
: "${PRIVATE_KEY:?set PRIVATE_KEY (testnet deployer key)}"
: "${REACTIVE:?deploy first (deployments/lasna.env missing)}"
: "${VAULT:?deploy first (deployments/lasna.env missing)}"
REACTIVE_FUND_WEI="${REACTIVE_FUND_WEI:-50000000000000000}" # 0.05 lREACT
VAULT_FUND_WEI="${VAULT_FUND_WEI:-20000000000000000}"       # 0.02 lREACT

echo "funding reactive $REACTIVE with $REACTIVE_FUND_WEI wei..."
cast send "$REACTIVE" --value "$REACTIVE_FUND_WEI" \
  --rpc-url "$LASNA_RPC" --chain-id "$CHAIN_ID" --private-key "$PRIVATE_KEY" | grep -E "transactionHash|status"

echo "funding vault $VAULT with $VAULT_FUND_WEI wei..."
cast send "$VAULT" --value "$VAULT_FUND_WEI" \
  --rpc-url "$LASNA_RPC" --chain-id "$CHAIN_ID" --private-key "$PRIVATE_KEY" | grep -E "transactionHash|status"

echo "balances after funding:"
cast balance "$REACTIVE" --rpc-url "$LASNA_RPC"
cast balance "$VAULT" --rpc-url "$LASNA_RPC"
