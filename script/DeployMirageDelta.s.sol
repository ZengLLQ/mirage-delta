// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";

interface IMirageToken {
    function set_minter(address minter, bool status) external;
    function mint(address to, uint256 amount) external returns (bool);
}

interface IMirageOracle {
    function set_price(bytes32 asset, uint256 price) external;
}

interface IMirageDebtEngine {
    function set_exchange(address exchange) external;
    function register_synth(address synth, bytes32 key) external;
}

contract DeployMirageDelta is Script {
    bytes32 public constant KEY_WETH = keccak256("WETH");
    bytes32 public constant KEY_MUSD = keccak256("MUSD");
    bytes32 public constant KEY_METH = keccak256("METH");
    bytes32 public constant KEY_MBTC = keccak256("MBTC");
    bytes32 public constant KEY_MSOL = keccak256("MSOL");

    uint256 public constant WAD = 1e18;

    function run() external {
        vm.startBroadcast();

        // 1. Deploy Synthetic Tokens
        address weth = deployCode("src/MirageToken.vy", abi.encode("Wrapped Ether", "WETH"));
        address musd = deployCode("src/MirageToken.vy", abi.encode("Mirage USD", "mUSD"));
        address meth = deployCode("src/MirageToken.vy", abi.encode("Mirage ETH", "mETH"));
        address mbtc = deployCode("src/MirageToken.vy", abi.encode("Mirage BTC", "mBTC"));
        address msol = deployCode("src/MirageToken.vy", abi.encode("Mirage SOL", "mSOL"));

        // 2. Deploy Oracle
        address oracle = deployCode("src/MirageOracle.vy");
        IMirageOracle(oracle).set_price(KEY_WETH, 2000 * WAD);
        IMirageOracle(oracle).set_price(KEY_MUSD, 1 * WAD);
        IMirageOracle(oracle).set_price(KEY_METH, 2000 * WAD);
        IMirageOracle(oracle).set_price(KEY_MBTC, 60000 * WAD);
        IMirageOracle(oracle).set_price(KEY_MSOL, 150 * WAD);

        // 3. Deploy Debt Engine
        address engine = deployCode("src/MirageDebtEngine.vy", abi.encode(weth, KEY_WETH, musd, KEY_MUSD, oracle));
        IMirageDebtEngine(engine).register_synth(meth, KEY_METH);
        IMirageDebtEngine(engine).register_synth(mbtc, KEY_MBTC);
        IMirageDebtEngine(engine).register_synth(msol, KEY_MSOL);

        // 4. Deploy Exchange
        address exchange = deployCode("src/MirageExchange.vy", abi.encode(engine, oracle));
        IMirageDebtEngine(engine).set_exchange(exchange);

        // 5. Deploy Staking Escrow
        address escrow = deployCode("src/MirageStakingEscrow.vy", abi.encode(musd));

        // 6. Authorizations
        IMirageToken(musd).set_minter(engine, true);
        IMirageToken(meth).set_minter(engine, true);
        IMirageToken(mbtc).set_minter(engine, true);
        IMirageToken(msol).set_minter(engine, true);

        IMirageToken(musd).set_minter(exchange, true);
        IMirageToken(meth).set_minter(exchange, true);
        IMirageToken(mbtc).set_minter(exchange, true);
        IMirageToken(msol).set_minter(exchange, true);

        console.log("Deployed MirageDelta Protocol:");
        console.log("  WETH:", weth);
        console.log("  mUSD:", musd);
        console.log("  mETH:", meth);
        console.log("  mBTC:", mbtc);
        console.log("  mSOL:", msol);
        console.log("  Oracle:", oracle);
        console.log("  DebtEngine:", engine);
        console.log("  Exchange:", exchange);
        console.log("  StakingEscrow:", escrow);

        vm.stopBroadcast();
    }
}
