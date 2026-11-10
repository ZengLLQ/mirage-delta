// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";

interface IMirageToken {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function mint(address to, uint256 amount) external returns (bool);
    function burn(address from_addr, uint256 amount) external returns (bool);
    function set_minter(address minter, bool status) external;
    function owner() external view returns (address);
}

interface IMirageOracle {
    function set_price(bytes32 asset, uint256 price) external;
    function set_prices(bytes32[] calldata assets, uint256[] calldata new_prices) external;
    function get_price(bytes32 asset) external view returns (uint256);
    function get_price_unsafe(bytes32 asset) external view returns (uint256);
    function set_reporter(address reporter, bool status) external;
    function set_max_stale_duration(uint256 duration) external;
    function max_stale_duration() external view returns (uint256);
    function owner() external view returns (address);
}

interface IMirageDebtEngine {
    function owner() external view returns (address);
    function oracle() external view returns (address);
    function exchange() external view returns (address);
    function collateral_token() external view returns (address);
    function collateral_key() external view returns (bytes32);
    function base_synth() external view returns (address);
    function target_c_ratio() external view returns (uint256);
    function liquidation_c_ratio() external view returns (uint256);
    function liquidation_bonus_bps() external view returns (uint256);
    function is_paused() external view returns (bool);
    function total_collateral() external view returns (uint256);
    function collateral_balance(address user) external view returns (uint256);
    function total_debt_shares() external view returns (uint256);
    function debt_shares(address user) external view returns (uint256);
    function debt_index() external view returns (uint256);
    function fee_index() external view returns (uint256);
    function user_fee_index(address user) external view returns (uint256);
    function user_claimable_fees(address user) external view returns (uint256);
    function is_registered_synth(address synth) external view returns (bool);
    function synth_keys(address synth) external view returns (bytes32);

    function set_exchange(address exchange) external;
    function register_synth(address synth, bytes32 key) external;
    function update_debt_index() external returns (uint256);
    function get_total_debt() external view returns (uint256);
    function get_user_debt(address user) external view returns (uint256);
    function get_collateral_value(address user) external view returns (uint256);
    function get_c_ratio(address user) external view returns (uint256);
    function get_max_issuable_debt(address user) external view returns (uint256);
    function deposit_collateral(uint256 amount, address recipient) external returns (uint256);
    function withdraw_collateral(uint256 amount, address recipient) external returns (uint256);
    function mint_synths(address synth, uint256 amount, address recipient) external returns (uint256);
    function burn_synths(address synth, uint256 amount, address on_behalf_of) external returns (uint256);
    function liquidate(address borrower, uint256 debt_to_cover, address recipient) external returns (uint256);
    function accrue_fees(uint256 amount) external;
    function claim_rewards(address recipient) external returns (uint256);
    function get_claimable_rewards(address user) external view returns (uint256);
    function set_parameters(uint256 target_c_ratio, uint256 liq_c_ratio, uint256 bonus_bps) external;
    function set_paused(bool paused) external;
    function transfer_ownership(address new_owner) external;
}

interface IMirageExchange {
    function owner() external view returns (address);
    function debt_engine() external view returns (address);
    function oracle() external view returns (address);
    function base_fee_bps() external view returns (uint256);
    function max_fee_bps() external view returns (uint256);
    function skew_fee_bps() external view returns (uint256);
    function is_paused() external view returns (bool);
    function synth_skew(address synth) external view returns (int256);

    function calculate_swap_amount(address synth_in, address synth_out, uint256 amount_in)
        external
        view
        returns (uint256 amount_out, uint256 fee_usd);
    function swap(address synth_in, address synth_out, uint256 amount_in, uint256 min_amount_out, address recipient)
        external
        returns (uint256);
    function set_fee_parameters(uint256 base_bps, uint256 max_bps, uint256 skew_bps) external;
    function set_paused(bool paused) external;
}

interface IMirageStakingEscrow {
    struct VestingSchedule {
        address beneficiary;
        uint256 total_amount;
        uint256 claimed_amount;
        uint256 start_time;
        uint256 duration;
        uint256 cliff_duration;
        bool is_active;
    }

    function owner() external view returns (address);
    function reward_token() external view returns (address);
    function schedule_count() external view returns (uint256);
    function total_escrowed() external view returns (uint256);
    function total_claimed() external view returns (uint256);
    function schedules(uint256 schedule_id) external view returns (VestingSchedule memory);
    function get_claimable(uint256 schedule_id) external view returns (uint256);
    function create_schedule(address beneficiary, uint256 amount, uint256 duration, uint256 cliff_duration)
        external
        returns (uint256);
    function claim(uint256 schedule_id) external returns (uint256);
    function cancel_schedule(uint256 schedule_id) external;
}

contract MirageDeltaTest is Test {
    IMirageToken public weth;
    IMirageToken public musd;
    IMirageToken public meth;
    IMirageToken public mbtc;
    IMirageToken public msol;

    IMirageOracle public oracle;
    IMirageDebtEngine public engine;
    IMirageExchange public exchange;
    IMirageStakingEscrow public escrow;

    address public owner = address(this);
    address public alice = address(0xAA11);
    address public bob = address(0xBB22);
    address public liquidator = address(0xEE44);

    bytes32 public constant KEY_WETH = keccak256("WETH");
    bytes32 public constant KEY_MUSD = keccak256("MUSD");
    bytes32 public constant KEY_METH = keccak256("METH");
    bytes32 public constant KEY_MBTC = keccak256("MBTC");
    bytes32 public constant KEY_MSOL = keccak256("MSOL");

    uint256 public constant WAD = 1e18;
    uint256 public constant INITIAL_WETH_PRICE = 2000 * 1e18; // $2,000
    uint256 public constant INITIAL_MUSD_PRICE = 1 * 1e18; // $1.00
    uint256 public constant INITIAL_METH_PRICE = 2000 * 1e18; // $2,000
    uint256 public constant INITIAL_MBTC_PRICE = 60000 * 1e18; // $60,000
    uint256 public constant INITIAL_MSOL_PRICE = 150 * 1e18; // $150

    function setUp() public {
        // 1. Deploy Tokens
        weth = IMirageToken(deployCode("src/MirageToken.vy", abi.encode("Wrapped Ether", "WETH")));
        musd = IMirageToken(deployCode("src/MirageToken.vy", abi.encode("Mirage USD", "mUSD")));
        meth = IMirageToken(deployCode("src/MirageToken.vy", abi.encode("Mirage ETH", "mETH")));
        mbtc = IMirageToken(deployCode("src/MirageToken.vy", abi.encode("Mirage BTC", "mBTC")));
        msol = IMirageToken(deployCode("src/MirageToken.vy", abi.encode("Mirage SOL", "mSOL")));

        // 2. Deploy Oracle
        oracle = IMirageOracle(deployCode("src/MirageOracle.vy"));

        // Initialize oracle prices
        oracle.set_price(KEY_WETH, INITIAL_WETH_PRICE);
        oracle.set_price(KEY_MUSD, INITIAL_MUSD_PRICE);
        oracle.set_price(KEY_METH, INITIAL_METH_PRICE);
        oracle.set_price(KEY_MBTC, INITIAL_MBTC_PRICE);
        oracle.set_price(KEY_MSOL, INITIAL_MSOL_PRICE);

        // 3. Deploy Debt Engine
        engine = IMirageDebtEngine(
            deployCode(
                "src/MirageDebtEngine.vy", abi.encode(address(weth), KEY_WETH, address(musd), KEY_MUSD, address(oracle))
            )
        );

        // Register other synths in engine
        engine.register_synth(address(meth), KEY_METH);
        engine.register_synth(address(mbtc), KEY_MBTC);
        engine.register_synth(address(msol), KEY_MSOL);

        // 4. Deploy Exchange
        exchange = IMirageExchange(deployCode("src/MirageExchange.vy", abi.encode(address(engine), address(oracle))));
        engine.set_exchange(address(exchange));

        // 5. Deploy Staking Escrow
        escrow = IMirageStakingEscrow(deployCode("src/MirageStakingEscrow.vy", abi.encode(address(musd))));

        // 6. Wire Minter Authorizations
        // DebtEngine mints/burns all synths
        musd.set_minter(address(engine), true);
        meth.set_minter(address(engine), true);
        mbtc.set_minter(address(engine), true);
        msol.set_minter(address(engine), true);

        // Exchange mints/burns all synths for swaps
        musd.set_minter(address(exchange), true);
        meth.set_minter(address(exchange), true);
        mbtc.set_minter(address(exchange), true);
        msol.set_minter(address(exchange), true);

        // Owner can mint WETH for testing
        weth.set_minter(owner, true);
        weth.mint(alice, 50 * WAD); // 50 WETH ($100k)
        weth.mint(bob, 50 * WAD); // 50 WETH ($100k)
        weth.mint(liquidator, 50 * WAD); // 50 WETH ($100k)

        // Approve DebtEngine
        vm.prank(alice);
        weth.approve(address(engine), type(uint256).max);

        vm.prank(bob);
        weth.approve(address(engine), type(uint256).max);

        vm.prank(liquidator);
        weth.approve(address(engine), type(uint256).max);
    }

    // ==========================================
    // 1. INITIALIZATION & METADATA TESTS
    // ==========================================

    function test_initial_parameters_and_wiring() public view {
        assertEq(engine.collateral_token(), address(weth));
        assertEq(engine.base_synth(), address(musd));
        assertEq(engine.oracle(), address(oracle));
        assertEq(engine.exchange(), address(exchange));
        assertEq(engine.target_c_ratio(), 4 * WAD); // 400%
        assertEq(engine.liquidation_c_ratio(), 15 * WAD / 10); // 150%
        assertEq(engine.liquidation_bonus_bps(), 1000); // 10%
        assertEq(engine.debt_index(), WAD); // 1.0

        assertTrue(engine.is_registered_synth(address(musd)));
        assertTrue(engine.is_registered_synth(address(meth)));
        assertTrue(engine.is_registered_synth(address(mbtc)));
        assertTrue(engine.is_registered_synth(address(msol)));
    }

    // ==========================================
    // 2. COLLATERAL DEPOSIT & WITHDRAWAL
    // ==========================================

    function test_collateral_deposit_and_accounting() public {
        vm.prank(alice);
        uint256 deposited = engine.deposit_collateral(10 * WAD, alice);

        assertEq(deposited, 10 * WAD);
        assertEq(engine.collateral_balance(alice), 10 * WAD);
        assertEq(engine.total_collateral(), 10 * WAD);
        assertEq(weth.balanceOf(address(engine)), 10 * WAD);

        // Value of 10 WETH @ $2000 = $20,000
        assertEq(engine.get_collateral_value(alice), 20000 * WAD);
        // Max issuable @ 400% C-ratio = $20,000 / 4 = $5,000
        assertEq(engine.get_max_issuable_debt(alice), 5000 * WAD);
        // With 0 debt, C-ratio is infinity (max uint256)
        assertEq(engine.get_c_ratio(alice), type(uint256).max);
    }

    function test_collateral_withdrawal_with_no_debt() public {
        vm.prank(alice);
        engine.deposit_collateral(10 * WAD, alice);

        vm.prank(alice);
        uint256 withdrawn = engine.withdraw_collateral(4 * WAD, alice);

        assertEq(withdrawn, 4 * WAD);
        assertEq(engine.collateral_balance(alice), 6 * WAD);
        assertEq(weth.balanceOf(alice), 44 * WAD);
    }

    // ==========================================
    // 3. SYNTH MINTING & C-RATIO CONSTRAINTS
    // ==========================================

    function test_mint_synths_within_target_c_ratio() public {
        // Alice deposits 10 WETH ($20,000). Max issuable debt @ 400% is $5,000.
        vm.prank(alice);
        engine.deposit_collateral(10 * WAD, alice);

        // Alice mints 4,000 mUSD ($4,000 debt). C-ratio = $20k / $4k = 500% >= 400%
        vm.prank(alice);
        uint256 shares = engine.mint_synths(address(musd), 4000 * WAD, alice);

        assertEq(shares, 4000 * WAD);
        assertEq(musd.balanceOf(alice), 4000 * WAD);
        assertEq(engine.debt_shares(alice), 4000 * WAD);
        assertEq(engine.get_user_debt(alice), 4000 * WAD);
        assertEq(engine.get_c_ratio(alice), 5 * WAD); // 500%
    }

    function test_cannot_mint_beyond_target_c_ratio() public {
        // Alice deposits 10 WETH ($20,000). Max issuable is $5,000.
        vm.prank(alice);
        engine.deposit_collateral(10 * WAD, alice);

        // Attempt to mint $5,001 mUSD should revert
        vm.prank(alice);
        vm.expectRevert();
        engine.mint_synths(address(musd), 5001 * WAD, alice);
    }

    function test_cannot_withdraw_collateral_if_c_ratio_breached() public {
        vm.prank(alice);
        engine.deposit_collateral(10 * WAD, alice);

        vm.prank(alice);
        engine.mint_synths(address(musd), 5000 * WAD, alice); // exactly at 400% target

        // Withdrawing even 0.1 WETH drops collateral value below $20k, breaching 400%
        vm.prank(alice);
        vm.expectRevert();
        engine.withdraw_collateral(1 * WAD / 10, alice);
    }

    // ==========================================
    // 4. MULTI-SYNTH MINTING & GLOBAL DEBT SHARES
    // ==========================================

    function test_multi_synth_minting_and_debt_tracking() public {
        // Alice deposits 20 WETH ($40,000). Max debt = $10,000.
        vm.prank(alice);
        engine.deposit_collateral(20 * WAD, alice);

        // Mints 2 mETH ($4,000) and 0.05 mBTC ($3,000) = total $7,000
        vm.prank(alice);
        engine.mint_synths(address(meth), 2 * WAD, alice);

        vm.prank(alice);
        engine.mint_synths(address(mbtc), 5 * WAD / 100, alice);

        assertEq(meth.balanceOf(alice), 2 * WAD);
        assertEq(mbtc.balanceOf(alice), 5 * WAD / 100);

        // Total debt = $4,000 + $3,000 = $7,000
        assertEq(engine.get_user_debt(alice), 7000 * WAD);
        assertEq(engine.get_total_debt(), 7000 * WAD);
    }

    function test_debt_index_adjusts_when_synths_appreciate() public {
        // Alice deposits 20 WETH ($40k) and mints 2 mETH ($4k debt @ $2k/ETH)
        vm.prank(alice);
        engine.deposit_collateral(20 * WAD, alice);

        vm.prank(alice);
        engine.mint_synths(address(meth), 2 * WAD, alice);

        assertEq(engine.get_user_debt(alice), 4000 * WAD);
        assertEq(engine.debt_index(), WAD);

        // ETH price doubles from $2,000 to $4,000!
        oracle.set_price(KEY_METH, 4000 * WAD);

        // Update debt index
        engine.update_debt_index();

        // 2 mETH is now worth $8,000. Debt index should double to 2.0 WAD.
        assertEq(engine.get_total_debt(), 8000 * WAD);
        assertEq(engine.debt_index(), 2 * WAD);
        assertEq(engine.get_user_debt(alice), 8000 * WAD);
    }

    function test_burn_synths_reduces_debt_shares() public {
        vm.prank(alice);
        engine.deposit_collateral(10 * WAD, alice);

        vm.prank(alice);
        engine.mint_synths(address(musd), 4000 * WAD, alice);

        assertEq(engine.get_user_debt(alice), 4000 * WAD);

        // Burn 1,500 mUSD
        vm.prank(alice);
        engine.burn_synths(address(musd), 1500 * WAD, alice);

        assertEq(musd.balanceOf(alice), 2500 * WAD);
        assertEq(engine.get_user_debt(alice), 2500 * WAD);
        assertEq(engine.debt_shares(alice), 2500 * WAD);
    }

    // ==========================================
    // 5. ZERO-SLIPPAGE SYNTHETIC SWAPS & SKEW
    // ==========================================

    function test_synthetic_swap_zero_slippage_with_fee() public {
        vm.prank(alice);
        engine.deposit_collateral(10 * WAD, alice);

        vm.prank(alice);
        engine.mint_synths(address(musd), 4000 * WAD, alice);

        // Alice swaps 2,000 mUSD for mETH
        // @ $2,000 per ETH, gross output is 1.0 mETH
        // Base fee is 30 bps (0.3%) = $6.00 fee in mUSD
        // Net USD = $1,994 -> net output = 1994 / 2000 = 0.997 mETH
        (uint256 expectedOut, uint256 feeUsd) = exchange.calculate_swap_amount(address(musd), address(meth), 2000 * WAD);
        assertEq(feeUsd, 6 * WAD); // $6.00
        assertEq(expectedOut, 997 * 1e15); // 0.997 mETH

        vm.prank(alice);
        uint256 out = exchange.swap(address(musd), address(meth), 2000 * WAD, 990 * 1e15, alice);

        assertEq(out, expectedOut);
        assertEq(musd.balanceOf(alice), 2000 * WAD);
        assertEq(meth.balanceOf(alice), 997 * 1e15);

        // Skew is updated
        assertEq(exchange.synth_skew(address(musd)), -2000 * int256(WAD));
        assertEq(exchange.synth_skew(address(meth)), int256(expectedOut));
    }

    function test_swap_reverts_on_slippage_or_paused() public {
        vm.prank(alice);
        engine.deposit_collateral(10 * WAD, alice);

        vm.prank(alice);
        engine.mint_synths(address(musd), 2000 * WAD, alice);

        // Expect slippage revert if min_amount_out is too high
        vm.prank(alice);
        vm.expectRevert();
        exchange.swap(address(musd), address(meth), 2000 * WAD, 1 * WAD, alice);

        // Pause exchange and verify revert
        exchange.set_paused(true);
        vm.prank(alice);
        vm.expectRevert();
        exchange.swap(address(musd), address(meth), 2000 * WAD, 0, alice);
    }

    // ==========================================
    // 6. SOFT-LIQUIDATION ENGINE
    // ==========================================

    function test_soft_liquidation_of_undercollateralized_position() public {
        // Alice deposits 10 WETH ($20k) and mints $5,000 mUSD (400% C-ratio)
        vm.prank(alice);
        engine.deposit_collateral(10 * WAD, alice);

        vm.prank(alice);
        engine.mint_synths(address(musd), 5000 * WAD, alice);

        // Solvent position cannot be liquidated
        vm.prank(liquidator);
        vm.expectRevert();
        engine.liquidate(alice, 1000 * WAD, liquidator);

        // Market crashes: WETH drops from $2,000 to $700!
        // Alice's 10 WETH is now worth $7,000. Debt = $5,000.
        // C-ratio = $7,000 / $5,000 = 140% < 150% liquidation threshold!
        oracle.set_price(KEY_WETH, 700 * WAD);
        assertLt(engine.get_c_ratio(alice), 15 * WAD / 10);

        // Liquidator mints mUSD by depositing collateral
        vm.prank(liquidator);
        engine.deposit_collateral(20 * WAD, liquidator);

        vm.prank(liquidator);
        engine.mint_synths(address(musd), 2500 * WAD, liquidator);

        // Liquidator covers max 50% close factor ($2,500 of Alice's debt)
        // With 10% bonus, effective debt covered is $2,500 * 1.10 = $2,750
        // Seized collateral @ $700/WETH = 2750 / 700 = 3.92857 WETH
        uint256 colBefore = weth.balanceOf(liquidator);

        vm.prank(liquidator);
        uint256 colSeized = engine.liquidate(alice, 2500 * WAD, liquidator);

        assertGt(colSeized, 0);
        assertEq(weth.balanceOf(liquidator) - colBefore, colSeized);
        assertEq(engine.get_user_debt(alice), 2500 * WAD);

        // Alice's remaining collateral is ~6.07 WETH ($4,250), debt is $2,500
        // New C-ratio = 4250 / 2500 = 170% > 150% (restored solvency!)
        assertGt(engine.get_c_ratio(alice), 15 * WAD / 10);
    }

    // ==========================================
    // 7. FEE POOL ACCUMULATION & REWARDS CLAIM
    // ==========================================

    function test_staker_reward_accrual_and_claiming() public {
        // Alice and Bob deposit collateral and mint debt
        vm.prank(alice);
        engine.deposit_collateral(10 * WAD, alice);
        vm.prank(alice);
        engine.mint_synths(address(musd), 3000 * WAD, alice); // 3,000 shares (75%)

        vm.prank(bob);
        engine.deposit_collateral(10 * WAD, bob);
        vm.prank(bob);
        engine.mint_synths(address(musd), 1000 * WAD, bob); // 1,000 shares (25%)

        // Alice performs a large swap generating $20 in fees
        // Swapping 1,000 mUSD -> mSOL
        vm.prank(alice);
        exchange.swap(address(musd), address(msol), 1000 * WAD, 0, alice);

        // Check fee accrual
        assertGt(engine.fee_index(), 0);

        // Alice should have ~75% of fees, Bob ~25%
        uint256 aliceClaimable = engine.get_claimable_rewards(alice);
        uint256 bobClaimable = engine.get_claimable_rewards(bob);

        assertGt(aliceClaimable, 0);
        assertGt(bobClaimable, 0);
        assertGt(aliceClaimable, bobClaimable);

        // Claim rewards
        uint256 musdBefore = musd.balanceOf(bob);
        vm.prank(bob);
        uint256 claimed = engine.claim_rewards(bob);

        assertEq(claimed, bobClaimable);
        assertEq(musd.balanceOf(bob) - musdBefore, claimed);
        assertEq(engine.get_claimable_rewards(bob), 0);
    }

    // ==========================================
    // 8. VESTING ESCROW TESTS
    // ==========================================

    function test_continuous_vesting_schedule_and_claim() public {
        // Owner mints 1,000 mUSD and creates vesting schedule for Alice (100 days, 10-day cliff)
        musd.set_minter(owner, true);
        musd.mint(owner, 1000 * WAD);
        musd.approve(address(escrow), 1000 * WAD);

        uint256 duration = 100 days;
        uint256 cliff = 10 days;
        uint256 schedId = escrow.create_schedule(alice, 1000 * WAD, duration, cliff);

        assertEq(schedId, 0);
        assertEq(escrow.get_claimable(schedId), 0);

        // Before cliff: 0 claimable
        vm.warp(vm.getBlockTimestamp() + 5 days);
        assertEq(escrow.get_claimable(schedId), 0);

        // At 50 days (halfway through duration): 500 mUSD claimable
        vm.warp(vm.getBlockTimestamp() + 45 days);
        uint256 claimable = escrow.get_claimable(schedId);
        assertEq(claimable, 500 * WAD);

        vm.prank(alice);
        uint256 claimed = escrow.claim(schedId);
        assertEq(claimed, 500 * WAD);
        assertEq(musd.balanceOf(alice), 500 * WAD);

        // At 100 days: remaining 500 mUSD claimable
        vm.warp(vm.getBlockTimestamp() + 50 days);
        assertEq(escrow.get_claimable(schedId), 500 * WAD);

        vm.prank(alice);
        escrow.claim(schedId);
        assertEq(musd.balanceOf(alice), 1000 * WAD);
        assertEq(escrow.get_claimable(schedId), 0);
    }

    // ==========================================
    // 9. FUZZ & INVARIANT PROPERTY TESTS
    // ==========================================

    function testFuzz_interleaved_deposits_and_debt_solvency(uint256 depositEth, uint256 mintMusd) public {
        depositEth = bound(depositEth, 1 * WAD, 20 * WAD);
        // Collateral value = depositEth * $2000
        // Max issuable = (depositEth * 2000) / 4 = depositEth * 500
        uint256 maxMint = (depositEth * 500);
        mintMusd = bound(mintMusd, 1 * WAD, maxMint);

        vm.prank(alice);
        engine.deposit_collateral(depositEth, alice);

        vm.prank(alice);
        engine.mint_synths(address(musd), mintMusd, alice);

        // Invariant 1: C-ratio must be >= 400%
        assertGe(engine.get_c_ratio(alice), 4 * WAD);

        // Invariant 2: Total debt equals user debt
        assertEq(engine.get_total_debt(), mintMusd);
        assertEq(engine.get_user_debt(alice), mintMusd);

        // Invariant 3: Collateral balance matches
        assertEq(engine.collateral_balance(alice), depositEth);
    }

    function testFuzz_oracle_staleness_protection(uint256 elapsed) public {
        elapsed = bound(elapsed, 3601, 100000); // Beyond 1 hour max stale duration
        vm.warp(vm.getBlockTimestamp() + elapsed);

        // Oracle should revert when price is stale
        vm.expectRevert();
        oracle.get_price(KEY_WETH);

        // Unsafe getter should still return price
        assertEq(oracle.get_price_unsafe(KEY_WETH), INITIAL_WETH_PRICE);
    }

    function testFuzz_swap_conservation_and_fee_bounds(uint256 amountIn) public view {
        amountIn = bound(amountIn, 10 * WAD, 5000 * WAD);

        (uint256 amountOut, uint256 feeUsd) = exchange.calculate_swap_amount(address(musd), address(mbtc), amountIn);

        // Fee must be bounded between 0.3% and 3.0%
        uint256 feeBps = (feeUsd * 10000) / amountIn;
        assertGe(feeBps, 29); // ~30 bps
        assertLe(feeBps, 301); // ~300 bps

        // Gross USD value must equal amountOut value + fee
        uint256 outUsd = (amountOut * INITIAL_MBTC_PRICE) / WAD;
        assertApproxEqAbs(outUsd + feeUsd, amountIn, 1e16); // sub-cent tolerance
    }

    // ==========================================
    // 10. ADVANCED GOVERNANCE, SKEW & ESCROW
    // ==========================================

    function test_admin_parameter_updates_and_guards() public {
        // Only owner can update parameters
        vm.prank(alice);
        vm.expectRevert();
        engine.set_parameters(5 * WAD, 2 * WAD, 1500);

        // Target must exceed liquidation ratio
        vm.expectRevert();
        engine.set_parameters(2 * WAD, 2 * WAD, 1500);

        // Liquidation bonus cannot exceed 25% (2500 bps)
        vm.expectRevert();
        engine.set_parameters(5 * WAD, 2 * WAD, 2501);

        // Successful update
        engine.set_parameters(5 * WAD, 2 * WAD, 1500);
        assertEq(engine.target_c_ratio(), 5 * WAD);
        assertEq(engine.liquidation_c_ratio(), 2 * WAD);
        assertEq(engine.liquidation_bonus_bps(), 1500);
    }

    function test_admin_ownership_transfer_lifecycle() public {
        address newOwner = address(0x9999);
        engine.transfer_ownership(newOwner);
        assertEq(engine.owner(), newOwner);

        // Old owner reverts
        vm.expectRevert();
        engine.set_parameters(5 * WAD, 2 * WAD, 1500);

        // New owner succeeds
        vm.prank(newOwner);
        engine.set_parameters(5 * WAD, 2 * WAD, 1500);
    }

    function test_exchange_dynamic_skew_surcharge() public {
        vm.prank(alice);
        engine.deposit_collateral(20 * WAD, alice);
        vm.prank(alice);
        engine.mint_synths(address(musd), 8000 * WAD, alice);

        // First swap: buying mETH when skew is 0. Base fee = 30 bps (0.3%).
        (uint256 out1, uint256 fee1) = exchange.calculate_swap_amount(address(musd), address(meth), 1000 * WAD);
        assertEq((fee1 * 10000) / (1000 * WAD), 30); // exactly 30 bps

        vm.prank(alice);
        exchange.swap(address(musd), address(meth), 1000 * WAD, 0, alice);

        // Now mETH has positive skew (in excess demand)!
        assertGt(exchange.synth_skew(address(meth)), 0);

        // Second swap: buying more mETH now incurs skew surcharge!
        // Base fee (30 bps) + skew surcharge (50 bps) = 80 bps!
        (uint256 out2, uint256 fee2) = exchange.calculate_swap_amount(address(musd), address(meth), 1000 * WAD);
        assertEq((fee2 * 10000) / (1000 * WAD), 80); // exactly 80 bps surcharge
        assertLt(out2, out1); // receives slightly less due to dynamic surcharge
    }

    function test_oracle_batch_price_updates() public {
        bytes32[] memory assets = new bytes32[](3);
        assets[0] = KEY_WETH;
        assets[1] = KEY_METH;
        assets[2] = KEY_MBTC;

        uint256[] memory newPrices = new uint256[](3);
        newPrices[0] = 2500 * WAD;
        newPrices[1] = 2500 * WAD;
        newPrices[2] = 70000 * WAD;

        oracle.set_prices(assets, newPrices);

        assertEq(oracle.get_price(KEY_WETH), 2500 * WAD);
        assertEq(oracle.get_price(KEY_METH), 2500 * WAD);
        assertEq(oracle.get_price(KEY_MBTC), 70000 * WAD);
    }

    function test_escrow_cancel_schedule_refunds_unclaimed() public {
        musd.set_minter(owner, true);
        musd.mint(owner, 1000 * WAD);
        musd.approve(address(escrow), 1000 * WAD);

        uint256 schedId = escrow.create_schedule(alice, 1000 * WAD, 100 days, 10 days);

        // Warp 30 days into schedule
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.prank(alice);
        uint256 claimed = escrow.claim(schedId);
        assertEq(claimed, 300 * WAD);

        // Cancel schedule
        uint256 ownerMusdBefore = musd.balanceOf(owner);
        escrow.cancel_schedule(schedId);

        // Owner receives refund of remaining 700 mUSD
        assertEq(musd.balanceOf(owner) - ownerMusdBefore, 700 * WAD);

        // Schedule is inactive, Alice cannot claim further
        vm.warp(vm.getBlockTimestamp() + 50 days);
        assertEq(escrow.get_claimable(schedId), 0);
        vm.prank(alice);
        vm.expectRevert();
        escrow.claim(schedId);
    }

    function testFuzz_multi_user_debt_proportionality(uint256 aliceCol, uint256 bobCol) public {
        aliceCol = bound(aliceCol, 2 * WAD, 20 * WAD);
        bobCol = bound(bobCol, 2 * WAD, 20 * WAD);

        vm.prank(alice);
        engine.deposit_collateral(aliceCol, alice);
        vm.prank(alice);
        uint256 aliceDebt = aliceCol * 400; // conservative minting
        engine.mint_synths(address(musd), aliceDebt, alice);

        vm.prank(bob);
        engine.deposit_collateral(bobCol, bob);
        vm.prank(bob);
        uint256 bobDebt = bobCol * 400;
        engine.mint_synths(address(musd), bobDebt, bob);

        // Invariant: total debt shares = alice shares + bob shares
        assertEq(engine.total_debt_shares(), engine.debt_shares(alice) + engine.debt_shares(bob));
        assertEq(engine.get_total_debt(), aliceDebt + bobDebt);
    }
}
