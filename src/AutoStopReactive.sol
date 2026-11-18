// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";
import {IAutoStopVault} from "./IAutoStopVault.sol";

/// @title AutoStopReactive — watches pair prices and fires stop-loss / take-profit.
/// @notice Reactive contract on Lasna. Subscribes to Uniswap V2 `Sync` events on
///         every pair on Lasna (chain id + Sync topic are the specific conditions;
///         the pair address is a wildcard), then evaluates every open order for
///         the pair that just moved. When an order's threshold is crossed it asks
///         the system contract for a callback into the vault, which re-verifies
///         the price and executes the sale.
/// @dev Why a wildcard pair subscription: orders can target any pair, including
///      pairs deployed after this contract. On a quiet testnet the extra `react()`
///      calls are negligible; on mainnet you would subscribe per-pair instead
///      (see `watchPair` notes in the README). `react()` never reverts on a
///      non-matching log — it just returns, so no fee is wasted on reverts.
contract AutoStopReactive is AbstractReactive {
    /// @notice Lasna testnet chain id.
    uint256 public constant LASNA_CHAIN_ID = 5318007;

    /// @notice Uniswap V2 `Sync(uint112,uint112)` event signature.
    bytes32 public constant SYNC_TOPIC_0 = keccak256("Sync(uint112,uint112)");

    /// @notice Gas limit requested for the vault callback (proxy takes its cut first).
    uint64 public constant CALLBACK_GAS_LIMIT = 1_000_000;

    /// @notice Max orders evaluated per `react()` call (reactive tx gas cap is 900k).
    uint256 public constant MAX_ORDERS_PER_REACT = 20;

    /// @notice Same cooldown / retry caps as the vault (mirrored, not enforced twice).
    uint256 public constant TRIGGER_COOLDOWN = 300;
    uint256 public constant MAX_TRIGGER_ATTEMPTS = 5;

    IAutoStopVault public vault;
    address public immutable owner;

    event OrderTriggered(uint256 indexed orderId, address indexed pair, uint256 price, uint256 threshold);
    event VaultSet(address indexed vault);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    /// @param vault_ AutoStopVault address; may be address(0) at deploy time and
    ///        set later via `setVault` (the vault needs this contract's address
    ///        in its own constructor, so one of the two must be set second).
    constructor(address vault_, address owner_) payable {
        vault = IAutoStopVault(vault_);
        owner = owner_;
        SYSTEM.subscribe(
            LASNA_CHAIN_ID, address(0), uint256(SYNC_TOPIC_0), REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    /// @notice Point this contract at the (re)deployed vault.
    function setVault(address vault_) external onlyOwner {
        vault = IAutoStopVault(vault_);
        emit VaultSet(vault_);
    }

    /// @inheritdoc IReactive
    function react(LogRecord memory log_) external onlySystem {
        if (log_.topic0 != uint256(SYNC_TOPIC_0)) return;
        if (address(vault) == address(0)) return;

        (uint112 reserve0, uint112 reserve1) = abi.decode(log_.data, (uint112, uint112));
        if (reserve0 == 0 || reserve1 == 0) return;

        address pair = log_.contractAddress;
        uint256[] memory orderIds = vault.getOpenOrders(pair);
        uint256 evaluated = 0;
        for (uint256 i = 0; i < orderIds.length && evaluated < MAX_ORDERS_PER_REACT; i++) {
            IAutoStopVault.Order memory order = vault.getOrder(orderIds[i]);
            if (order.status != IAutoStopVault.OrderStatus.Open) continue;
            if (order.paused) continue;
            if (order.attempts >= MAX_TRIGGER_ATTEMPTS) continue;
            if (order.lastTriggerAt != 0 && block.timestamp < order.lastTriggerAt + TRIGGER_COOLDOWN) {
                continue;
            }
            evaluated++;

            uint256 price = _price(order.sellToken0, reserve0, reserve1);
            bool crossed = order.orderType == IAutoStopVault.OrderType.StopLoss
                ? price <= order.threshold
                : price >= order.threshold;
            if (!crossed) continue;

            bytes memory payload = abi.encodeWithSignature(
                "executeOrder(address,uint256)",
                address(0), // placeholder: proxy injects this contract's address
                orderIds[i]
            );
            SYSTEM.requestCallbackV_1_0(
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: LASNA_CHAIN_ID, recipient: address(vault), gasLimit: CALLBACK_GAS_LIMIT, payload: payload
                })
            );
            emit OrderTriggered(orderIds[i], pair, price, order.threshold);
        }
    }

    /// @notice Settle outstanding reactive debt from this contract's balance.
    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Price of the pair in the `sellToken0` direction, scaled by 10000.
    function _price(bool sellToken0, uint112 reserve0, uint112 reserve1) internal pure returns (uint256) {
        uint256 coefficient = 10000;
        return sellToken0
            ? uint256(reserve1) * coefficient / uint256(reserve0)
            : uint256(reserve0) * coefficient / uint256(reserve1);
    }
}
