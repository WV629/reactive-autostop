// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {MockERC20} from "./MockERC20.sol";

/// @title MockPair — minimal Uniswap V2-style pair for the Lasna testnet.
/// @notice Reproduces the exact event surface a stop-loss bot needs from a real
///         Uniswap V2 pair: `Sync(uint112 reserve0, uint112 reserve1)` on every
///         reserve change, plus a constant-product `swap()` with the 0.3% fee.
///         There is no live Uniswap V2 on Lasna, so this pair stands in for it;
///         `AutoStopReactive` only ever reads the `Sync` event, so pointing it at
///         a real V2 pair (e.g. on Sepolia) needs no reactive-code change.
/// @dev No LP tokens: liquidity is added/removed by the deployer directly.
///      Tokens are sorted by address, exactly like Uniswap V2 (token0 < token1).
contract MockPair {
    address public immutable token0;
    address public immutable token1;

    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;

    bool private locked;

    event Sync(uint112 reserve0, uint112 reserve1);
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);

    modifier nonReentrant() {
        require(!locked, "locked");
        locked = true;
        _;
        locked = false;
    }

    constructor(address tokenA, address tokenB) {
        require(tokenA != tokenB, "identical tokens");
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "zero token");
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    /// @notice Add liquidity: pulls both tokens from the caller and updates reserves.
    function addLiquidity(uint256 amount0, uint256 amount1) external nonReentrant {
        require(amount0 > 0 && amount1 > 0, "zero liquidity");
        require(MockERC20(token0).transferFrom(msg.sender, address(this), amount0), "t0");
        require(MockERC20(token1).transferFrom(msg.sender, address(this), amount1), "t1");
        reserve0 = uint112(uint256(reserve0) + amount0);
        reserve1 = uint112(uint256(reserve1) + amount1);
        blockTimestampLast = uint32(block.timestamp % 2 ** 32);
        emit Mint(msg.sender, amount0, amount1);
        emit Sync(reserve0, reserve1);
    }

    /// @notice Constant-product amount-out with the Uniswap V2 0.3% fee.
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        public
        pure
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "zero in");
        require(reserveIn > 0 && reserveOut > 0, "no liquidity");
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /// @notice Swap, Uniswap V2 style: the caller must have sent the input tokens
    ///         to the pair before calling (or send them in the same flow); the pair
    ///         sends the output first, then verifies the constant-product invariant.
    function swap(uint256 amount0Out, uint256 amount1Out, address to) external nonReentrant {
        require(amount0Out > 0 || amount1Out > 0, "zero out");
        require(amount0Out < reserve0 && amount1Out < reserve1, "insufficient liquidity");
        require(to != token0 && to != token1, "invalid to");

        if (amount0Out > 0) require(MockERC20(token0).transfer(to, amount0Out), "t0 out");
        if (amount1Out > 0) require(MockERC20(token1).transfer(to, amount1Out), "t1 out");

        uint256 balance0 = MockERC20(token0).balanceOf(address(this));
        uint256 balance1 = MockERC20(token1).balanceOf(address(this));

        uint256 amount0In = balance0 > uint256(reserve0) - amount0Out ? balance0 - (uint256(reserve0) - amount0Out) : 0;
        uint256 amount1In = balance1 > uint256(reserve1) - amount1Out ? balance1 - (uint256(reserve1) - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "no input");

        uint256 balance0Adjusted = balance0 * 1000 - amount0In * 3;
        uint256 balance1Adjusted = balance1 * 1000 - amount1In * 3;
        require(balance0Adjusted * balance1Adjusted >= uint256(reserve0) * uint256(reserve1) * 1000 ** 2, "invariant");

        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = uint32(block.timestamp % 2 ** 32);

        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
        emit Sync(reserve0, reserve1);
    }
}
