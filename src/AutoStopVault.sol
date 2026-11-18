// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockPair} from "./MockPair.sol";
import {IAutoStopVault} from "./IAutoStopVault.sol";

/// @title AutoStopVault — holds user stop-loss / take-profit orders and executes
///         them when the Reactive Network calls back.
/// @notice Destination (callback) contract. Lives on Lasna, so its callback proxy
///         is the Reactive system contract itself (0x8888…8888).
///         A user deposits the token they want to sell, picks a threshold price,
///         and the vault sells it through the pair the moment a callback arrives.
///         The vault re-verifies the price on-chain before executing, so a stale
///         trigger can never sell at the wrong price.
contract AutoStopVault is AbstractCallback, IAutoStopVault {
    /// @notice Price scale: 10000 = 4 decimals (0.8 -> 8000, 1.2 -> 12000).
    uint256 public constant COEFFICIENT = 10000;

    /// @notice Cooldown between two trigger attempts for the same order.
    uint256 public constant TRIGGER_COOLDOWN = 300; // 5 minutes

    /// @notice After this many failed attempts the order is marked Failed.
    uint256 public constant MAX_TRIGGER_ATTEMPTS = 5;

    address public immutable owner;

    uint256 public nextOrderId;
    mapping(uint256 => Order) private orders;
    mapping(address => uint256[]) private openOrdersByPair;

    event OrderCreated(
        uint256 indexed orderId,
        address indexed owner,
        address indexed pair,
        bool sellToken0,
        uint256 amountIn,
        uint256 threshold,
        OrderType orderType
    );
    event OrderExecuted(uint256 indexed orderId, address indexed owner, uint256 amountOut, uint256 price);
    event OrderNotTriggered(uint256 indexed orderId, uint256 price, uint256 threshold);
    event OrderCancelled(uint256 indexed orderId);
    event OrderPaused(uint256 indexed orderId);
    event OrderResumed(uint256 indexed orderId);
    event OrderFailed(uint256 indexed orderId);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier onlyOrderOwner(uint256 orderId) {
        require(orders[orderId].owner == msg.sender, "not order owner");
        _;
    }

    /// @param callbackProxy_ On Lasna this is the system contract 0x8888…8888.
    /// @param callbackSender_ The AutoStopReactive contract allowed to trigger us.
    /// @param owner_ Admin (rescue + coverDebt helper); the deployer.
    constructor(IPayable callbackProxy_, address callbackSender_, address owner_)
        payable
        AbstractCallback(callbackProxy_, callbackSender_)
    {
        owner = owner_;
    }

    /// @notice Create a stop-loss / take-profit order. Pulls `amountIn` of the
    ///         token being sold from the caller into the vault.
    function createOrder(address pair, bool sellToken0, uint256 amountIn, uint256 threshold, OrderType orderType)
        external
        returns (uint256 orderId)
    {
        require(pair != address(0), "zero pair");
        require(amountIn > 0, "zero amount");
        require(threshold > 0, "zero threshold");

        address tokenIn = sellToken0 ? MockPair(pair).token0() : MockPair(pair).token1();
        require(MockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn), "pull");

        orderId = nextOrderId++;
        orders[orderId] = Order({
            owner: msg.sender,
            pair: pair,
            sellToken0: sellToken0,
            amountIn: amountIn,
            threshold: threshold,
            orderType: orderType,
            status: OrderStatus.Open,
            paused: false,
            attempts: 0,
            lastTriggerAt: 0,
            createdAt: block.timestamp
        });
        openOrdersByPair[pair].push(orderId);

        emit OrderCreated(orderId, msg.sender, pair, sellToken0, amountIn, threshold, orderType);
    }

    /// @notice Executed only via an authenticated Reactive callback.
    /// @dev First param is the injected reactive-contract address (proxy overwrites
    ///      the placeholder the reactive side encoded as address(0)).
    function executeOrder(address reactive_, uint256 orderId)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        Order storage order = orders[orderId];
        require(order.status == OrderStatus.Open, "not open");
        require(!order.paused, "paused");

        if (order.attempts >= MAX_TRIGGER_ATTEMPTS) {
            order.status = OrderStatus.Failed;
            emit OrderFailed(orderId);
            return;
        }
        order.attempts += 1;
        order.lastTriggerAt = block.timestamp;

        uint256 price = priceOf(order.pair, order.sellToken0);
        bool crossed = order.orderType == OrderType.StopLoss ? price <= order.threshold : price >= order.threshold;
        if (!crossed) {
            // Stale trigger: price moved back. Leave the order open for the
            // next Sync event; do not sell at the wrong price.
            emit OrderNotTriggered(orderId, price, order.threshold);
            return;
        }

        (uint112 reserve0, uint112 reserve1,) = MockPair(order.pair).getReserves();
        (uint256 reserveIn, uint256 reserveOut) =
            order.sellToken0 ? (uint256(reserve0), uint256(reserve1)) : (uint256(reserve1), uint256(reserve0));
        uint256 amountOut = MockPair(order.pair).getAmountOut(order.amountIn, reserveIn, reserveOut);
        require(amountOut > 0, "zero out");

        address tokenIn = order.sellToken0 ? MockPair(order.pair).token0() : MockPair(order.pair).token1();
        address tokenOut = order.sellToken0 ? MockPair(order.pair).token1() : MockPair(order.pair).token0();

        require(MockERC20(tokenIn).transfer(order.pair, order.amountIn), "fund pair");
        if (order.sellToken0) {
            MockPair(order.pair).swap(0, amountOut, address(this));
        } else {
            MockPair(order.pair).swap(amountOut, 0, address(this));
        }
        require(MockERC20(tokenOut).transfer(order.owner, amountOut), "payout");

        order.status = OrderStatus.Executed;
        _removeOpenOrder(order.pair, orderId);

        emit OrderExecuted(orderId, order.owner, amountOut, price);
    }

    function cancelOrder(uint256 orderId) external onlyOrderOwner(orderId) {
        Order storage order = orders[orderId];
        require(order.status == OrderStatus.Open, "not open");
        order.status = OrderStatus.Cancelled;
        _removeOpenOrder(order.pair, orderId);

        address tokenIn = order.sellToken0 ? MockPair(order.pair).token0() : MockPair(order.pair).token1();
        require(MockERC20(tokenIn).transfer(order.owner, order.amountIn), "refund");

        emit OrderCancelled(orderId);
    }

    function pauseOrder(uint256 orderId) external onlyOrderOwner(orderId) {
        Order storage order = orders[orderId];
        require(order.status == OrderStatus.Open, "not open");
        require(!order.paused, "already paused");
        order.paused = true;
        _removeOpenOrder(order.pair, orderId);
        emit OrderPaused(orderId);
    }

    function resumeOrder(uint256 orderId) external onlyOrderOwner(orderId) {
        Order storage order = orders[orderId];
        require(order.status == OrderStatus.Open, "not open");
        require(order.paused, "not paused");
        order.paused = false;
        openOrdersByPair[order.pair].push(orderId);
        emit OrderResumed(orderId);
    }

    /// @inheritdoc IAutoStopVault
    function getOrder(uint256 orderId) external view returns (Order memory) {
        return orders[orderId];
    }

    /// @inheritdoc IAutoStopVault
    function getOpenOrders(address pair) external view returns (uint256[] memory) {
        return openOrdersByPair[pair];
    }

    /// @inheritdoc IAutoStopVault
    function priceOf(address pair, bool sellToken0) public view returns (uint256) {
        (uint112 reserve0, uint112 reserve1,) = MockPair(pair).getReserves();
        if (reserve0 == 0 || reserve1 == 0) return 0;
        return sellToken0
            ? uint256(reserve1) * COEFFICIENT / uint256(reserve0)
            : uint256(reserve0) * COEFFICIENT / uint256(reserve1);
    }

    /// @notice Settle outstanding callback debt from this contract's balance.
    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Rescue tokens stuck in the vault (admin only).
    function rescue(address token, address to, uint256 amount) external onlyOwner {
        require(MockERC20(token).transfer(to, amount), "rescue");
    }

    function _removeOpenOrder(address pair, uint256 orderId) internal {
        uint256[] storage ids = openOrdersByPair[pair];
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == orderId) {
                ids[i] = ids[ids.length - 1];
                ids.pop();
                return;
            }
        }
    }
}
