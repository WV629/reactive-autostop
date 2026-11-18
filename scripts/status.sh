#!/usr/bin/env bash
# Check AutoStop health on Lasna: balances, debt, reserves, price, open orders.
# Usage: source deployments/lasna.env first (or pass env vars), then ./scripts/status.sh
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"

LASNA_RPC="${LASNA_RPC:-https://lasna-rpc.rnk.dev}"
SYSTEM=0x8888888888888888888888888888888888888888
# Pick up addresses from the deploy output if not already exported.
if [ -f deployments/lasna.env ]; then set -a; source deployments/lasna.env; set +a; fi
: "${REACTIVE:?deploy first (deployments/lasna.env missing)}"
: "${VAULT:?deploy first (deployments/lasna.env missing)}"
: "${PAIR:?deploy first (deployments/lasna.env missing)}"
: "${TKN:?deploy first (deployments/lasna.env missing)}"

echo "== balances (lREACT) =="
echo -n "reactive: "; cast balance "$REACTIVE" --rpc-url "$LASNA_RPC" | awk '{print $1}'
echo -n "vault:    "; cast balance "$VAULT" --rpc-url "$LASNA_RPC" | awk '{print $1}'

echo "== debt / reserves (0 = healthy; any debt > 0 halts the contract) =="
echo -n "reactive debt:     "; cast call "$SYSTEM" "debt(address)(uint256)" "$REACTIVE" --rpc-url "$LASNA_RPC" | awk '{print $1}'
echo -n "reactive reserves: "; cast call "$SYSTEM" "reserves(address)(uint256)" "$REACTIVE" --rpc-url "$LASNA_RPC" | awk '{print $1}'
echo -n "vault debt:        "; cast call "$SYSTEM" "debt(address)(uint256)" "$VAULT" --rpc-url "$LASNA_RPC" | awk '{print $1}'
echo -n "vault reserves:    "; cast call "$SYSTEM" "reserves(address)(uint256)" "$VAULT" --rpc-url "$LASNA_RPC" | awk '{print $1}'

echo "== price (scaled by 10000; 10000 = 1.0) =="
SELL_T0=$(cast call "$PAIR" "token0()(address)" --rpc-url "$LASNA_RPC")
if [ "$SELL_T0" = "$TKN" ]; then SELL=true; else SELL=false; fi
echo -n "mTKN price: "; cast call "$VAULT" "priceOf(address,bool)(uint256)" "$PAIR" "$SELL" --rpc-url "$LASNA_RPC" | awk '{print $1}'

echo "== open orders for this pair =="
cast call "$VAULT" "getOpenOrders(address)(uint256[])" "$PAIR" --rpc-url "$LASNA_RPC"
