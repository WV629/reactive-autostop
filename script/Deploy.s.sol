// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {MockPair} from "../src/MockPair.sol";
import {AutoStopVault} from "../src/AutoStopVault.sol";
import {AutoStopReactive} from "../src/AutoStopReactive.sol";

/// @title Deploy AutoStop to Lasna.
/// @notice Usage:
///   PRIVATE_KEY=0x... forge script script/Deploy.s.sol:Deploy \
///     --rpc-url https://lasna-rpc.rnk.dev --chain-id 5318007 --broadcast
///   Optional env: REACTIVE_FUND_WEI (default 0.05 ether), VAULT_FUND_WEI
///   (default 0.02 ether). Writes addresses to deployments/lasna.env.
contract Deploy is Script {
    address internal constant SYSTEM = 0x8888888888888888888888888888888888888888;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        // Funding amounts live in scripts/fund.sh (REACTIVE_FUND_WEI /
        // VAULT_FUND_WEI, defaults 0.05 / 0.02 lREACT) — see the note in run().

        // NOTE: no `{value: ...}` on the creations below — forge script's local
        // simulation pays CREATE value from the (unfunded) script contract and
        // reverts OutOfFunds. Fund with plain calls instead; inside broadcast
        // those are real txs from the deployer EOA.
        vm.startBroadcast(pk);

        MockERC20 tkn = new MockERC20("Mock Token", "mTKN");
        MockERC20 usdc = new MockERC20("Mock USDC", "mUSDC");
        tkn.mint(deployer, 100_000 ether);
        usdc.mint(deployer, 100_000 ether);

        MockPair pair = new MockPair(address(tkn), address(usdc));
        tkn.approve(address(pair), 1_000 ether);
        usdc.approve(address(pair), 1_000 ether);
        pair.addLiquidity(1_000 ether, 1_000 ether); // 1:1 -> price 1.0000

        AutoStopReactive reactive = new AutoStopReactive(address(0), deployer);
        AutoStopVault vault = new AutoStopVault(IPayable(payable(SYSTEM)), address(reactive), deployer);
        reactive.setVault(address(vault));

        // NOTE: funding is NOT done here. forge script's local simulation pays
        // ETH-value calls from the (unfunded) script contract, so value
        // transfers revert OutOfFunds in dry-run even though the broadcast tx
        // would be fine. Fund with scripts/fund.sh (plain `cast send`) after
        // this script writes deployments/lasna.env.
        vm.stopBroadcast();

        console.log("TKN     =", address(tkn));
        console.log("USDC    =", address(usdc));
        console.log("PAIR    =", address(pair));
        console.log("REACTIVE=", address(reactive));
        console.log("VAULT   =", address(vault));

        _writeEnv(address(tkn), address(usdc), address(pair), address(reactive), address(vault), deployer);
    }

    function _writeEnv(address tkn, address usdc, address pair, address reactive, address vault, address deployer)
        internal
    {
        string memory envOut = string.concat(
            "TKN=",
            vm.toString(tkn),
            "\n",
            "USDC=",
            vm.toString(usdc),
            "\n",
            "PAIR=",
            vm.toString(pair),
            "\n",
            "REACTIVE=",
            vm.toString(reactive),
            "\n",
            "VAULT=",
            vm.toString(vault),
            "\n",
            "DEPLOYER=",
            vm.toString(deployer),
            "\n"
        );
        vm.writeFile("deployments/lasna.env", envOut);
    }
}
