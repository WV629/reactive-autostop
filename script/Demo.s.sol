// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {AutoStopVault} from "../src/AutoStopVault.sol";
import {IAutoStopVault} from "../src/IAutoStopVault.sol";

/// @title Create the two demo orders (stop-loss + take-profit).
/// @notice Usage: set TKN/USDC/PAIR/VAULT (from deployments/lasna.env) then
///   PRIVATE_KEY=0x... forge script script/Demo.s.sol:Demo \
///     --rpc-url https://lasna-rpc.rnk.dev --chain-id 5318007 --broadcast
///   Creates: order 0 = stop-loss, sell 10 mTKN at <= 0.8000;
///            order 1 = take-profit, sell 10 mTKN at >= 1.2000.
contract Demo is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address tkn = vm.envAddress("TKN");
        address pair = vm.envAddress("PAIR");
        address vaultAddr = vm.envAddress("VAULT");

        AutoStopVault vault = AutoStopVault(payable(vaultAddr));
        bool sellToken0 = _isToken0(tkn, pair);

        vm.startBroadcast(pk);
        MockERC20(tkn).approve(vaultAddr, 20 ether);
        uint256 stopId = vault.createOrder(pair, sellToken0, 10 ether, 8_000, IAutoStopVault.OrderType.StopLoss);
        uint256 takeId = vault.createOrder(pair, sellToken0, 10 ether, 12_000, IAutoStopVault.OrderType.TakeProfit);
        vm.stopBroadcast();

        console.log("STOP_LOSS_ORDER =", stopId);
        console.log("TAKE_PROFIT_ORDER =", takeId);
        console.log("price now =", vault.priceOf(pair, sellToken0));
    }

    function _isToken0(address token, address pair) internal view returns (bool) {
        (bool ok, bytes memory ret) = pair.staticcall(abi.encodeWithSignature("token0()"));
        require(ok, "token0 call failed");
        return abi.decode(ret, (address)) == token;
    }
}
