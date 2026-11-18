// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title IAutoStopVault — the interface `AutoStopReactive` reads.
/// @notice Shared so the reactive contract can evaluate orders without knowing
///         the vault's storage layout.
interface IAutoStopVault {
    enum OrderType {
        StopLoss,
        TakeProfit
    }

    enum OrderStatus {
        Open,
        Executed,
        Cancelled,
        Failed
    }

    struct Order {
        address owner;
        address pair;
        bool sellToken0;
        uint256 amountIn;
        uint256 threshold;
        OrderType orderType;
        OrderStatus status;
        bool paused;
        uint256 attempts;
        uint256 lastTriggerAt;
        uint256 createdAt;
    }

    function getOrder(uint256 orderId) external view returns (Order memory);

    function getOpenOrders(address pair) external view returns (uint256[] memory);

    /// @notice Current price of `pair` for the `sellToken0` direction,
    ///         scaled by the vault's coefficient (10000 = 4 decimals).
    function priceOf(address pair, bool sellToken0) external view returns (uint256);
}
