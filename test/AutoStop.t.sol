// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {MockSystem} from "./MockSystem.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {MockPair} from "../src/MockPair.sol";
import {AutoStopVault} from "../src/AutoStopVault.sol";
import {AutoStopReactive} from "../src/AutoStopReactive.sol";
import {IAutoStopVault} from "../src/IAutoStopVault.sol";

/// @title AutoStop end-to-end tests (local simulation of the Lasna loop).
/// @notice The real loop on Lasna is: pair Sync event -> system contract calls
///         react() -> reactive requests callback -> proxy calls executeOrder().
///         Here MockSystem stands in for the system contract/proxy, and the
///         Sync log is taken from the pair's real emitted event via recordLogs.
contract AutoStopTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 internal constant LASNA_CHAIN_ID = 5318007;

    MockSystem internal system_;
    /// @notice Same mock, reached through the etched system address — the
    ///         reactive/vault contracts talk to THIS storage, not `system_`'s.
    MockSystem internal systemAt;
    MockERC20 internal tkn;
    MockERC20 internal usdc;
    MockPair internal pair;
    AutoStopVault internal vault;
    AutoStopReactive internal reactive;

    address internal user = makeAddr("user");
    address internal deployer = address(this);

    function setUp() public {
        // Etch the mock system contract onto the real system address.
        system_ = new MockSystem();
        vm.etch(SYSTEM_ADDR, address(system_).code);
        systemAt = MockSystem(payable(SYSTEM_ADDR));

        tkn = new MockERC20("Mock Token", "mTKN");
        usdc = new MockERC20("Mock USDC", "mUSDC");
        tkn.mint(deployer, 100_000 ether);
        usdc.mint(deployer, 100_000 ether);
        tkn.mint(user, 1_000 ether);
        usdc.mint(user, 1_000 ether);

        pair = new MockPair(address(tkn), address(usdc));
        // mTKN < mUSDC by address order? token0 is the smaller address; sort
        // the liquidity amounts accordingly.
        _addLiquidity(1_000 ether, 1_000 ether);

        reactive = new AutoStopReactive{value: 1 ether}(address(0), deployer);
        vault = new AutoStopVault{value: 1 ether}(IPayable(payable(SYSTEM_ADDR)), address(reactive), deployer);
        reactive.setVault(address(vault));
    }

    // --- helpers -----------------------------------------------------------

    function _addLiquidity(uint256 amountA, uint256 amountB) internal {
        // pair.token0/token1 are address-sorted; map amounts to the right side.
        address t0 = pair.token0();
        uint256 a0 = t0 == address(tkn) ? amountA : amountB;
        uint256 a1 = t0 == address(tkn) ? amountB : amountA;
        tkn.approve(address(pair), type(uint256).max);
        usdc.approve(address(pair), type(uint256).max);
        pair.addLiquidity(a0, a1);
    }

    /// @notice Swap `amountIn` of `tokenIn` for the other token, from the deployer.
    function _swap(address tokenIn, uint256 amountIn) internal returns (uint256 amountOut) {
        bool inIsT0 = tokenIn == pair.token0();
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint256 rIn, uint256 rOut) = inIsT0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        amountOut = pair.getAmountOut(amountIn, rIn, rOut);
        MockERC20(tokenIn).transfer(address(pair), amountIn);
        if (inIsT0) {
            pair.swap(0, amountOut, deployer);
        } else {
            pair.swap(amountOut, 0, deployer);
        }
    }

    function _createOrder(uint256 amountIn, uint256 threshold, IAutoStopVault.OrderType otype)
        internal
        returns (uint256 orderId)
    {
        // The user always sells mTKN; sellToken0 just records which side of
        // the pair mTKN sits on (address-sorted).
        bool sellT0 = address(tkn) == pair.token0();
        vm.startPrank(user);
        MockERC20(address(tkn)).approve(address(vault), amountIn);
        orderId = vault.createOrder(address(pair), sellT0, amountIn, threshold, otype);
        vm.stopPrank();
    }

    /// @notice Feed the pair's latest real Sync log into react() as the system would.
    function _triggerReactFromLastSync() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 syncTopic = keccak256("Sync(uint112,uint112)");
        for (uint256 i = logs.length; i > 0; i--) {
            Vm.Log memory l = logs[i - 1];
            if (l.topics.length > 0 && l.topics[0] == syncTopic) {
                IReactive.LogRecord memory rec = IReactive.LogRecord({
                    chainId: LASNA_CHAIN_ID,
                    contractAddress: l.emitter,
                    topic0: uint256(l.topics[0]),
                    topic1: 0,
                    topic2: 0,
                    topic3: 0,
                    data: l.data,
                    blockNumber: block.number,
                    opCode: 1,
                    blockHash: uint256(blockhash(block.number - 1)),
                    txHash: 0,
                    logIndex: 0
                });
                vm.prank(SYSTEM_ADDR);
                reactive.react(rec);
                return;
            }
        }
        revert("no Sync log found");
    }

    function _executeCallback(uint256 orderId) internal {
        vm.prank(SYSTEM_ADDR);
        vault.executeOrder(address(reactive), orderId);
    }

    function _price() internal view returns (uint256) {
        bool sellT0 = address(tkn) == pair.token0();
        return vault.priceOf(address(pair), sellT0);
    }

    // --- tests -------------------------------------------------------------

    function testReactiveSubscribesToSyncOnDeploy() public view {
        (uint256 chainId, address contractAddr, uint256 topic0,,,) = systemAt.subscriptions(0);
        assertEq(chainId, LASNA_CHAIN_ID);
        assertEq(contractAddr, address(0)); // wildcard: any pair on Lasna
        assertEq(topic0, uint256(keccak256("Sync(uint112,uint112)")));
        assertEq(topic0, uint256(reactive.SYNC_TOPIC_0()));
    }

    function testStopLossFullLoop() public {
        assertEq(_price(), 10_000); // 1:1 pool -> price 1.0000
        uint256 orderId = _createOrder(10 ether, 8_000, IAutoStopVault.OrderType.StopLoss);

        // Crash the mTKN price: sell 500 mTKN into the pair.
        vm.recordLogs();
        _swap(address(tkn), 500 ether);
        assertLt(_price(), 8_000);

        uint256 usdcBefore = usdc.balanceOf(user);
        _triggerReactFromLastSync();

        // Reactive asked the system for exactly one callback to the vault.
        assertEq(systemAt.callbackRequestCount(), 1);
        (uint256 cbChainId, address recipient,, bytes memory payload) = systemAt.callbackRequests(0);
        assertEq(cbChainId, LASNA_CHAIN_ID);
        assertEq(recipient, address(vault));
        (address sender, uint256 cbOrderId) = abi.decode(_payloadTail(payload), (address, uint256));
        assertEq(sender, address(0)); // placeholder, proxy injects reactive addr
        assertEq(cbOrderId, orderId);

        _executeCallback(orderId);

        IAutoStopVault.Order memory order = vault.getOrder(orderId);
        assertEq(uint256(order.status), uint256(IAutoStopVault.OrderStatus.Executed));
        assertGt(usdc.balanceOf(user), usdcBefore); // user got paid out
        assertEq(vault.getOpenOrders(address(pair)).length, 0);
    }

    function testTakeProfitFullLoop() public {
        uint256 orderId = _createOrder(10 ether, 12_000, IAutoStopVault.OrderType.TakeProfit);

        // Pump the mTKN price: sell 500 mUSDC into the pair.
        vm.recordLogs();
        _swap(address(usdc), 500 ether);
        assertGt(_price(), 12_000);

        _triggerReactFromLastSync();
        assertEq(systemAt.callbackRequestCount(), 1);
        (, address recipient,,) = systemAt.callbackRequests(0);
        assertEq(recipient, address(vault));
        _executeCallback(orderId);

        assertEq(uint256(vault.getOrder(orderId).status), uint256(IAutoStopVault.OrderStatus.Executed));
    }

    function testNoTriggerWhilePriceInRange() public {
        _createOrder(10 ether, 8_000, IAutoStopVault.OrderType.StopLoss);
        vm.recordLogs();
        _swap(address(tkn), 10 ether); // small move, price stays above 0.8
        assertGt(_price(), 8_000);
        _triggerReactFromLastSync();
        assertEq(systemAt.callbackRequestCount(), 0); // nothing requested
    }

    function testStaleTriggerDoesNotSell() public {
        uint256 orderId = _createOrder(10 ether, 8_000, IAutoStopVault.OrderType.StopLoss);

        vm.recordLogs();
        _swap(address(tkn), 500 ether); // crash below 0.8
        _triggerReactFromLastSync();
        assertEq(systemAt.callbackRequestCount(), 1);

        _swap(address(usdc), 500 ether); // price recovers above 0.8 before callback
        assertGt(_price(), 8_000);

        uint256 usdcBefore = usdc.balanceOf(user);
        _executeCallback(orderId);
        // Vault re-verified the price and refused to sell.
        assertEq(uint256(vault.getOrder(orderId).status), uint256(IAutoStopVault.OrderStatus.Open));
        assertEq(usdc.balanceOf(user), usdcBefore);
    }

    function testCancelRefunds() public {
        uint256 orderId = _createOrder(10 ether, 8_000, IAutoStopVault.OrderType.StopLoss);
        uint256 before = tkn.balanceOf(user);
        vm.prank(user);
        vault.cancelOrder(orderId);
        assertEq(tkn.balanceOf(user), before + 10 ether);
        assertEq(uint256(vault.getOrder(orderId).status), uint256(IAutoStopVault.OrderStatus.Cancelled));
    }

    function testReactOnlySystem() public {
        IReactive.LogRecord memory rec = IReactive.LogRecord({
            chainId: LASNA_CHAIN_ID,
            contractAddress: address(pair),
            topic0: uint256(keccak256("Sync(uint112,uint112)")),
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode(uint112(1_000 ether), uint112(1_000 ether)),
            blockNumber: block.number,
            opCode: 1,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
        vm.expectRevert();
        reactive.react(rec);
    }

    function testExecuteOrderOnlyProxyAndSender() public {
        uint256 orderId = _createOrder(10 ether, 8_000, IAutoStopVault.OrderType.StopLoss);
        vm.expectRevert();
        vault.executeOrder(address(reactive), orderId); // not the proxy
        vm.prank(SYSTEM_ADDR);
        vm.expectRevert();
        vault.executeOrder(address(0x1234), orderId); // wrong sender
    }

    // --- internals ---------------------------------------------------------

    /// @notice Callback payload is abi.encodeWithSignature("executeOrder(address,uint256)", 0, id);
    ///         the first 4 bytes are the function selector; the rest is the args.
    function _payloadTail(bytes memory payload) internal pure returns (bytes memory) {
        bytes memory tail = new bytes(payload.length - 4);
        for (uint256 i = 0; i < tail.length; i++) {
            tail[i] = payload[i + 4];
        }
        return tail;
    }
}
