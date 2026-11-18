// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {MockPair} from "../src/MockPair.sol";
import {AutoStopVault} from "../src/AutoStopVault.sol";

/// @title Crash (or pump) the demo price so the stop-loss fires.
/// @notice Usage: set TKN/USDC/PAIR/VAULT (from deployments/lasna.env) then
///   PRIVATE_KEY=0x... forge script script/Trigger.s.sol:Trigger \
///     --rpc-url https://lasna-rpc.rnk.dev --chain-id 5318007 --broadcast
///   Env: SIDE=crash (default, sell 500 mTKN -> price ~0.44) or pump
///   (sell 500 mUSDC -> price ~2.25). After this tx the reactive contract
///   should fire within ~1s: watch the vault order status flip to Executed.
contract Trigger is Script {
    address internal tkn;
    address internal usdc;
    address internal pairAddr;
    address internal vaultAddr;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        tkn = vm.envAddress("TKN");
        usdc = vm.envAddress("USDC");
        pairAddr = vm.envAddress("PAIR");
        vaultAddr = vm.envAddress("VAULT");

        string memory side = vm.envOr("SIDE", string("crash"));
        bool crash = keccak256(bytes(side)) == keccak256(bytes("crash"));
        address tokenIn = crash ? tkn : usdc;

        console.log("price before =", _price());
        vm.startBroadcast(pk);
        _swap(tokenIn, 500 ether, vm.addr(pk));
        vm.stopBroadcast();
        console.log("price after  =", _price());
    }

    function _price() internal view returns (uint256) {
        MockPair pair = MockPair(pairAddr);
        AutoStopVault vault = AutoStopVault(payable(vaultAddr));
        return vault.priceOf(pairAddr, tkn == pair.token0());
    }

    function _swap(address tokenIn, uint256 amountIn, address to) internal {
        MockPair pair = MockPair(pairAddr);
        bool inIsT0 = tokenIn == pair.token0();
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint256 rIn, uint256 rOut) = inIsT0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 amountOut = pair.getAmountOut(amountIn, rIn, rOut);

        MockERC20(tokenIn).transfer(pairAddr, amountIn);
        if (inIsT0) {
            pair.swap(0, amountOut, to);
        } else {
            pair.swap(amountOut, 0, to);
        }
        console.log("swapped in:", amountIn);
        console.log("swapped out:", amountOut);
    }
}
