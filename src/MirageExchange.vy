#pragma version ^0.4.0

"""
@title MirageExchange
@author ZengLLQ
@notice Zero-Slippage Virtual Synthetic Exchange & Skew-Adaptive Fee Engine in Vyper 0.4.3.
"""

interface IMirageToken:
    def mint(to: address, amount: uint256) -> bool: nonpayable
    def burn(from_addr: address, amount: uint256) -> bool: nonpayable
    def totalSupply() -> uint256: view
    def balanceOf(account: address) -> uint256: view

interface IMirageOracle:
    def get_price(asset: bytes32) -> uint256: view

interface IMirageDebtEngine:
    def accrue_fees(amount: uint256): nonpayable
    def base_synth() -> address: view
    def is_registered_synth(synth: address) -> bool: view
    def synth_keys(synth: address) -> bytes32: view

# Events
event SyntheticSwapped:
    trader: indexed(address)
    recipient: indexed(address)
    synth_in: indexed(address)
    synth_out: address
    amount_in: uint256
    amount_out: uint256
    fee_musd: uint256

event FeeParametersUpdated:
    base_fee_bps: uint256
    max_fee_bps: uint256
    skew_fee_bps: uint256

event PausedUpdated:
    is_paused: bool

event OwnershipTransferred:
    previous_owner: indexed(address)
    new_owner: indexed(address)

# Constants
WAD: constant(uint256) = 1000000000000000000
BPS_DIVISOR: constant(uint256) = 10000

# State Variables
owner: public(address)
debt_engine: public(address)
oracle: public(address)

base_fee_bps: public(uint256) # e.g. 30 bps (0.3%)
max_fee_bps: public(uint256)  # e.g. 300 bps (3.0%)
skew_fee_bps: public(uint256) # e.g. 50 bps (0.5%)
is_paused: public(bool)

synth_skew: public(HashMap[address, int256])

@deploy
def __init__(_debt_engine: address, _oracle: address):
    assert _debt_engine != empty(address), "MirageExchange: zero debt engine"
    assert _oracle != empty(address), "MirageExchange: zero oracle"

    self.owner = msg.sender
    self.debt_engine = _debt_engine
    self.oracle = _oracle

    self.base_fee_bps = 30   # 0.3%
    self.max_fee_bps = 300   # 3.0%
    self.skew_fee_bps = 50   # 0.5%

    log OwnershipTransferred(previous_owner=empty(address), new_owner=msg.sender)

@view
@internal
def _calculate_dynamic_fee(synth_in: address, synth_out: address) -> uint256:
    fee: uint256 = self.base_fee_bps
    # Skew surcharge if buying an already over-demanded synth
    skew_out: int256 = self.synth_skew[synth_out]
    if skew_out > 0:
        fee += self.skew_fee_bps
    if fee > self.max_fee_bps:
        fee = self.max_fee_bps
    return fee

@view
@external
def calculate_swap_amount(
    synth_in: address,
    synth_out: address,
    amount_in: uint256
) -> (uint256, uint256):
    assert amount_in > 0, "MirageExchange: zero amount in"
    assert synth_in != synth_out, "MirageExchange: identical tokens"

    k_in: bytes32 = staticcall IMirageDebtEngine(self.debt_engine).synth_keys(synth_in)
    k_out: bytes32 = staticcall IMirageDebtEngine(self.debt_engine).synth_keys(synth_out)
    assert k_in != empty(bytes32) and k_out != empty(bytes32), "MirageExchange: unmapped keys"

    p_in: uint256 = staticcall IMirageOracle(self.oracle).get_price(k_in)
    p_out: uint256 = staticcall IMirageOracle(self.oracle).get_price(k_out)

    gross_usd_val: uint256 = (amount_in * p_in) // WAD
    fee_bps: uint256 = self._calculate_dynamic_fee(synth_in, synth_out)
    fee_usd: uint256 = (gross_usd_val * fee_bps) // BPS_DIVISOR

    net_usd_val: uint256 = gross_usd_val - fee_usd
    amount_out: uint256 = (net_usd_val * WAD) // p_out

    return (amount_out, fee_usd)

@external
def swap(
    synth_in: address,
    synth_out: address,
    amount_in: uint256,
    min_amount_out: uint256,
    recipient: address
) -> uint256:
    assert not self.is_paused, "MirageExchange: paused"
    assert amount_in > 0, "MirageExchange: zero amount in"
    assert recipient != empty(address), "MirageExchange: zero recipient"
    assert synth_in != synth_out, "MirageExchange: identical tokens"

    # Verify both synths are registered in engine
    assert staticcall IMirageDebtEngine(self.debt_engine).is_registered_synth(synth_in), "MirageExchange: synth_in not registered"
    assert staticcall IMirageDebtEngine(self.debt_engine).is_registered_synth(synth_out), "MirageExchange: synth_out not registered"

    k_in: bytes32 = staticcall IMirageDebtEngine(self.debt_engine).synth_keys(synth_in)
    k_out: bytes32 = staticcall IMirageDebtEngine(self.debt_engine).synth_keys(synth_out)

    p_in: uint256 = staticcall IMirageOracle(self.oracle).get_price(k_in)
    p_out: uint256 = staticcall IMirageOracle(self.oracle).get_price(k_out)

    gross_usd_val: uint256 = (amount_in * p_in) // WAD
    fee_bps: uint256 = self._calculate_dynamic_fee(synth_in, synth_out)
    fee_usd: uint256 = (gross_usd_val * fee_bps) // BPS_DIVISOR

    net_usd_val: uint256 = gross_usd_val - fee_usd
    amount_out: uint256 = (net_usd_val * WAD) // p_out

    assert amount_out >= min_amount_out, "MirageExchange: slippage exceeded"
    assert amount_out > 0, "MirageExchange: zero output amount"

    # Burn synth_in from trader
    extcall IMirageToken(synth_in).burn(msg.sender, amount_in)

    # Mint synth_out to recipient
    extcall IMirageToken(synth_out).mint(recipient, amount_out)

    # If fee > 0, mint mUSD to debt_engine and accrue fees
    base_synth: address = staticcall IMirageDebtEngine(self.debt_engine).base_synth()
    if fee_usd > 0 and base_synth != empty(address):
        extcall IMirageToken(base_synth).mint(self.debt_engine, fee_usd)
        extcall IMirageDebtEngine(self.debt_engine).accrue_fees(fee_usd)

    # Update skew
    self.synth_skew[synth_in] -= convert(amount_in, int256)
    self.synth_skew[synth_out] += convert(amount_out, int256)

    log SyntheticSwapped(
        trader=msg.sender,
        recipient=recipient,
        synth_in=synth_in,
        synth_out=synth_out,
        amount_in=amount_in,
        amount_out=amount_out,
        fee_musd=fee_usd
    )

    return amount_out

@external
def set_fee_parameters(_base_bps: uint256, _max_bps: uint256, _skew_bps: uint256):
    assert msg.sender == self.owner, "MirageExchange: only owner"
    assert _base_bps <= _max_bps, "MirageExchange: base fee exceeds max fee"
    assert _max_bps <= 1000, "MirageExchange: max fee cannot exceed 10%"
    assert _skew_bps <= 500, "MirageExchange: skew fee cannot exceed 5%"

    self.base_fee_bps = _base_bps
    self.max_fee_bps = _max_bps
    self.skew_fee_bps = _skew_bps

    log FeeParametersUpdated(base_fee_bps=_base_bps, max_fee_bps=_max_bps, skew_fee_bps=_skew_bps)

@external
def set_paused(paused: bool):
    assert msg.sender == self.owner, "MirageExchange: only owner"
    self.is_paused = paused
    log PausedUpdated(is_paused=paused)

@external
def transfer_ownership(new_owner: address):
    assert msg.sender == self.owner, "MirageExchange: only owner"
    assert new_owner != empty(address), "MirageExchange: zero address"
    old: address = self.owner
    self.owner = new_owner
    log OwnershipTransferred(previous_owner=old, new_owner=new_owner)
