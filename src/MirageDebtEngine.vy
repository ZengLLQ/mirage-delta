#pragma version ^0.4.0

"""
@title MirageDebtEngine
@author ZengLLQ
@notice Production-Grade Multi-Collateral Synthetic Asset & Virtual Debt Engine in Vyper 0.4.3.
"""

interface IERC20:
    def transfer(to: address, amount: uint256) -> bool: nonpayable
    def transferFrom(sender: address, recipient: address, amount: uint256) -> bool: nonpayable
    def balanceOf(account: address) -> uint256: view

interface IMirageToken:
    def mint(to: address, amount: uint256) -> bool: nonpayable
    def burn(from_addr: address, amount: uint256) -> bool: nonpayable
    def totalSupply() -> uint256: view
    def balanceOf(account: address) -> uint256: view

interface IMirageOracle:
    def get_price(asset: bytes32) -> uint256: view

# Events
event CollateralDeposited:
    user: indexed(address)
    recipient: indexed(address)
    amount: uint256

event CollateralWithdrawn:
    user: indexed(address)
    recipient: indexed(address)
    amount: uint256

event SynthsMinted:
    user: indexed(address)
    synth: indexed(address)
    amount: uint256
    shares_issued: uint256
    debt_value: uint256

event SynthsBurned:
    user: indexed(address)
    synth: indexed(address)
    amount: uint256
    shares_burned: uint256
    debt_value: uint256

event PositionLiquidated:
    liquidator: indexed(address)
    borrower: indexed(address)
    debt_covered: uint256
    collateral_seized: uint256

event FeesAccrued:
    amount: uint256
    new_fee_index: uint256

event RewardsClaimed:
    user: indexed(address)
    recipient: indexed(address)
    amount: uint256

event SynthRegistered:
    synth: indexed(address)
    asset_key: bytes32

event ParametersUpdated:
    target_c_ratio: uint256
    liquidation_c_ratio: uint256
    liquidation_bonus_bps: uint256

event PausedUpdated:
    is_paused: bool

event OwnershipTransferred:
    previous_owner: indexed(address)
    new_owner: indexed(address)

# Constants
WAD: constant(uint256) = 1000000000000000000
BPS_DIVISOR: constant(uint256) = 10000
MAX_CLOSE_FACTOR_BPS: constant(uint256) = 5000  # Max 50% debt covered per liquidation

# State Variables
owner: public(address)
oracle: public(address)
exchange: public(address)
collateral_token: public(address)
collateral_key: public(bytes32)
base_synth: public(address)  # mUSD token

target_c_ratio: public(uint256)        # e.g. 4.0 WAD (400%)
liquidation_c_ratio: public(uint256)   # e.g. 1.5 WAD (150%)
liquidation_bonus_bps: public(uint256) # e.g. 1000 bps = 10%
is_paused: public(bool)

total_collateral: public(uint256)
collateral_balance: public(HashMap[address, uint256])

total_debt_shares: public(uint256)
debt_shares: public(HashMap[address, uint256])
debt_index: public(uint256)  # In WAD, tracks global debt growth

fee_index: public(uint256)   # Cumulative fees per debt share in WAD
user_fee_index: public(HashMap[address, uint256])
user_claimable_fees: public(HashMap[address, uint256])

registered_synths: public(DynArray[address, 16])
synth_keys: public(HashMap[address, bytes32])
is_registered_synth: public(HashMap[address, bool])

@deploy
def __init__(
    _collateral_token: address,
    _collateral_key: bytes32,
    _base_synth: address,
    _base_synth_key: bytes32,
    _oracle: address
):
    assert _collateral_token != empty(address), "MirageDebtEngine: zero collateral token"
    assert _base_synth != empty(address), "MirageDebtEngine: zero base synth"
    assert _oracle != empty(address), "MirageDebtEngine: zero oracle"
    assert _collateral_key != empty(bytes32), "MirageDebtEngine: zero collateral key"
    assert _base_synth_key != empty(bytes32), "MirageDebtEngine: zero base synth key"

    self.owner = msg.sender
    self.collateral_token = _collateral_token
    self.collateral_key = _collateral_key
    self.base_synth = _base_synth
    self.oracle = _oracle

    self.target_c_ratio = 4 * WAD              # 400%
    self.liquidation_c_ratio = (15 * WAD) // 10  # 150%
    self.liquidation_bonus_bps = 1000          # 10%
    self.debt_index = WAD                      # 1.0

    # Auto-register base synth
    self.registered_synths.append(_base_synth)
    self.synth_keys[_base_synth] = _base_synth_key
    self.is_registered_synth[_base_synth] = True

    log OwnershipTransferred(previous_owner=empty(address), new_owner=msg.sender)
    log SynthRegistered(synth=_base_synth, asset_key=_base_synth_key)

@external
def set_exchange(_exchange: address):
    assert msg.sender == self.owner, "MirageDebtEngine: only owner"
    assert _exchange != empty(address), "MirageDebtEngine: zero exchange"
    self.exchange = _exchange

@external
def register_synth(synth: address, key: bytes32):
    assert msg.sender == self.owner, "MirageDebtEngine: only owner"
    assert synth != empty(address), "MirageDebtEngine: zero synth address"
    assert key != empty(bytes32), "MirageDebtEngine: zero key"
    assert not self.is_registered_synth[synth], "MirageDebtEngine: synth already registered"
    assert len(self.registered_synths) < 16, "MirageDebtEngine: max synths reached"

    self.registered_synths.append(synth)
    self.synth_keys[synth] = key
    self.is_registered_synth[synth] = True
    log SynthRegistered(synth=synth, asset_key=key)

@internal
def _update_user_rewards(user: address):
    shares: uint256 = self.debt_shares[user]
    if shares > 0:
        delta_fee: uint256 = self.fee_index - self.user_fee_index[user]
        if delta_fee > 0:
            self.user_claimable_fees[user] += (shares * delta_fee) // WAD
    self.user_fee_index[user] = self.fee_index

@view
@internal
def _calculate_total_debt() -> uint256:
    total: uint256 = 0
    for i: uint256 in range(16):
        if i >= len(self.registered_synths):
            break
        s: address = self.registered_synths[i]
        supply: uint256 = staticcall IMirageToken(s).totalSupply()
        if supply > 0:
            k: bytes32 = self.synth_keys[s]
            p: uint256 = staticcall IMirageOracle(self.oracle).get_price(k)
            total += (supply * p) // WAD
    return total

@internal
def _update_debt_index() -> uint256:
    total_debt: uint256 = self._calculate_total_debt()
    if self.total_debt_shares > 0 and total_debt > 0:
        new_idx: uint256 = (total_debt * WAD) // self.total_debt_shares
        if new_idx > 0:
            self.debt_index = new_idx
    return self.debt_index

@external
def update_debt_index() -> uint256:
    return self._update_debt_index()

@view
@external
def get_total_debt() -> uint256:
    return self._calculate_total_debt()

@view
@external
def get_user_debt(user: address) -> uint256:
    return (self.debt_shares[user] * self.debt_index) // WAD

@view
@external
def get_collateral_value(user: address) -> uint256:
    p: uint256 = staticcall IMirageOracle(self.oracle).get_price(self.collateral_key)
    return (self.collateral_balance[user] * p) // WAD

@view
@external
def get_c_ratio(user: address) -> uint256:
    debt: uint256 = (self.debt_shares[user] * self.debt_index) // WAD
    if debt == 0:
        return max_value(uint256)
    p: uint256 = staticcall IMirageOracle(self.oracle).get_price(self.collateral_key)
    col_val: uint256 = (self.collateral_balance[user] * p) // WAD
    return (col_val * WAD) // debt

@view
@external
def get_max_issuable_debt(user: address) -> uint256:
    p: uint256 = staticcall IMirageOracle(self.oracle).get_price(self.collateral_key)
    col_val: uint256 = (self.collateral_balance[user] * p) // WAD
    return (col_val * WAD) // self.target_c_ratio

@external
def deposit_collateral(amount: uint256, recipient: address) -> uint256:
    assert not self.is_paused, "MirageDebtEngine: paused"
    assert amount > 0, "MirageDebtEngine: zero deposit"
    assert recipient != empty(address), "MirageDebtEngine: zero recipient"

    self._update_user_rewards(recipient)
    self.collateral_balance[recipient] += amount
    self.total_collateral += amount

    extcall IERC20(self.collateral_token).transferFrom(msg.sender, self, amount)
    log CollateralDeposited(user=msg.sender, recipient=recipient, amount=amount)
    return amount

@external
def withdraw_collateral(amount: uint256, recipient: address) -> uint256:
    assert not self.is_paused, "MirageDebtEngine: paused"
    assert amount > 0, "MirageDebtEngine: zero withdraw"
    assert recipient != empty(address), "MirageDebtEngine: zero recipient"
    assert self.collateral_balance[msg.sender] >= amount, "MirageDebtEngine: insufficient collateral"

    self._update_debt_index()
    self._update_user_rewards(msg.sender)

    # Check remaining collateral vs debt requirement
    rem_col: uint256 = self.collateral_balance[msg.sender] - amount
    user_shares: uint256 = self.debt_shares[msg.sender]

    if user_shares > 0:
        p: uint256 = staticcall IMirageOracle(self.oracle).get_price(self.collateral_key)
        rem_val: uint256 = (rem_col * p) // WAD
        user_debt: uint256 = (user_shares * self.debt_index) // WAD
        c_ratio: uint256 = (rem_val * WAD) // user_debt
        assert c_ratio >= self.target_c_ratio, "MirageDebtEngine: c-ratio below target"

    self.collateral_balance[msg.sender] = rem_col
    self.total_collateral -= amount

    extcall IERC20(self.collateral_token).transfer(recipient, amount)
    log CollateralWithdrawn(user=msg.sender, recipient=recipient, amount=amount)
    return amount

@external
def mint_synths(synth: address, amount: uint256, recipient: address) -> uint256:
    assert not self.is_paused, "MirageDebtEngine: paused"
    assert amount > 0, "MirageDebtEngine: zero mint"
    assert recipient != empty(address), "MirageDebtEngine: zero recipient"
    assert self.is_registered_synth[synth], "MirageDebtEngine: unregistered synth"

    self._update_debt_index()
    self._update_user_rewards(msg.sender)

    # Calculate debt value of minted amount
    k: bytes32 = self.synth_keys[synth]
    p: uint256 = staticcall IMirageOracle(self.oracle).get_price(k)
    mint_debt_val: uint256 = (amount * p) // WAD

    # Convert debt value into virtual debt shares
    new_shares: uint256 = (mint_debt_val * WAD) // self.debt_index
    assert new_shares > 0, "MirageDebtEngine: zero new shares"

    total_user_shares: uint256 = self.debt_shares[msg.sender] + new_shares
    new_user_debt: uint256 = (total_user_shares * self.debt_index) // WAD

    # Enforce target C-ratio
    p_col: uint256 = staticcall IMirageOracle(self.oracle).get_price(self.collateral_key)
    col_val: uint256 = (self.collateral_balance[msg.sender] * p_col) // WAD
    c_ratio: uint256 = (col_val * WAD) // new_user_debt
    assert c_ratio >= self.target_c_ratio, "MirageDebtEngine: insufficient c-ratio"

    self.debt_shares[msg.sender] = total_user_shares
    self.total_debt_shares += new_shares

    extcall IMirageToken(synth).mint(recipient, amount)
    log SynthsMinted(user=msg.sender, synth=synth, amount=amount, shares_issued=new_shares, debt_value=mint_debt_val)
    return new_shares

@external
def burn_synths(synth: address, amount: uint256, on_behalf_of: address) -> uint256:
    assert not self.is_paused, "MirageDebtEngine: paused"
    assert amount > 0, "MirageDebtEngine: zero burn"
    assert on_behalf_of != empty(address), "MirageDebtEngine: zero target"
    assert self.is_registered_synth[synth], "MirageDebtEngine: unregistered synth"

    self._update_debt_index()
    self._update_user_rewards(on_behalf_of)

    k: bytes32 = self.synth_keys[synth]
    p: uint256 = staticcall IMirageOracle(self.oracle).get_price(k)
    burn_debt_val: uint256 = (amount * p) // WAD

    shares_to_burn: uint256 = (burn_debt_val * WAD) // self.debt_index
    if shares_to_burn > self.debt_shares[on_behalf_of]:
        shares_to_burn = self.debt_shares[on_behalf_of]

    assert shares_to_burn > 0, "MirageDebtEngine: zero shares burned"

    self.debt_shares[on_behalf_of] -= shares_to_burn
    self.total_debt_shares -= shares_to_burn

    extcall IMirageToken(synth).burn(msg.sender, amount)
    log SynthsBurned(user=on_behalf_of, synth=synth, amount=amount, shares_burned=shares_to_burn, debt_value=burn_debt_val)
    return shares_to_burn

@external
def liquidate(borrower: address, debt_to_cover: uint256, recipient: address) -> uint256:
    assert not self.is_paused, "MirageDebtEngine: paused"
    assert debt_to_cover > 0, "MirageDebtEngine: zero liquidation cover"
    assert borrower != empty(address), "MirageDebtEngine: zero borrower"
    assert recipient != empty(address), "MirageDebtEngine: zero recipient"

    self._update_debt_index()
    self._update_user_rewards(borrower)

    # Check if borrower is liquidatable: C-ratio < liquidation_c_ratio
    p_col: uint256 = staticcall IMirageOracle(self.oracle).get_price(self.collateral_key)
    col_val: uint256 = (self.collateral_balance[borrower] * p_col) // WAD
    user_debt: uint256 = (self.debt_shares[borrower] * self.debt_index) // WAD

    assert user_debt > 0, "MirageDebtEngine: borrower has no debt"
    c_ratio: uint256 = (col_val * WAD) // user_debt
    assert c_ratio < self.liquidation_c_ratio, "MirageDebtEngine: position is solvent"

    # Enforce close factor (max 50% debt covered per liquidation)
    max_cover: uint256 = (user_debt * MAX_CLOSE_FACTOR_BPS) // BPS_DIVISOR
    actual_cover: uint256 = debt_to_cover
    if actual_cover > max_cover:
        actual_cover = max_cover

    # Collateral reward = debt_to_cover * (1 + bonus) / collateral_price
    bonus_multiplier: uint256 = WAD + (self.liquidation_bonus_bps * WAD) // BPS_DIVISOR
    effective_debt_val: uint256 = (actual_cover * bonus_multiplier) // WAD
    col_seized: uint256 = (effective_debt_val * WAD) // p_col

    if col_seized > self.collateral_balance[borrower]:
        col_seized = self.collateral_balance[borrower]

    # Calculate debt shares to burn
    shares_burned: uint256 = (actual_cover * WAD) // self.debt_index
    if shares_burned > self.debt_shares[borrower]:
        shares_burned = self.debt_shares[borrower]

    self.debt_shares[borrower] -= shares_burned
    self.total_debt_shares -= shares_burned
    self.collateral_balance[borrower] -= col_seized
    self.total_collateral -= col_seized

    # Burn mUSD from liquidator and transfer seized collateral
    extcall IMirageToken(self.base_synth).burn(msg.sender, actual_cover)
    extcall IERC20(self.collateral_token).transfer(recipient, col_seized)

    log PositionLiquidated(liquidator=msg.sender, borrower=borrower, debt_covered=actual_cover, collateral_seized=col_seized)
    return col_seized

@external
def accrue_fees(amount: uint256):
    assert msg.sender == self.exchange or msg.sender == self.owner, "MirageDebtEngine: unauthorized fee source"
    if amount > 0 and self.total_debt_shares > 0:
        self.fee_index += (amount * WAD) // self.total_debt_shares
        log FeesAccrued(amount=amount, new_fee_index=self.fee_index)

@external
def claim_rewards(recipient: address) -> uint256:
    assert recipient != empty(address), "MirageDebtEngine: zero recipient"
    self._update_user_rewards(msg.sender)
    earned: uint256 = self.user_claimable_fees[msg.sender]
    if earned > 0:
        self.user_claimable_fees[msg.sender] = 0
        extcall IMirageToken(self.base_synth).mint(recipient, earned)
        log RewardsClaimed(user=msg.sender, recipient=recipient, amount=earned)
    return earned

@view
@external
def get_claimable_rewards(user: address) -> uint256:
    shares: uint256 = self.debt_shares[user]
    earned: uint256 = self.user_claimable_fees[user]
    if shares > 0:
        delta_fee: uint256 = self.fee_index - self.user_fee_index[user]
        if delta_fee > 0:
            earned += (shares * delta_fee) // WAD
    return earned

@external
def set_parameters(_target_c_ratio: uint256, _liq_c_ratio: uint256, _bonus_bps: uint256):
    assert msg.sender == self.owner, "MirageDebtEngine: only owner"
    assert _target_c_ratio > _liq_c_ratio, "MirageDebtEngine: target must exceed liquidation ratio"
    assert _liq_c_ratio >= WAD, "MirageDebtEngine: liquidation ratio below 100%"
    assert _bonus_bps <= 2500, "MirageDebtEngine: liquidation bonus too high"

    self.target_c_ratio = _target_c_ratio
    self.liquidation_c_ratio = _liq_c_ratio
    self.liquidation_bonus_bps = _bonus_bps
    log ParametersUpdated(target_c_ratio=_target_c_ratio, liquidation_c_ratio=_liq_c_ratio, liquidation_bonus_bps=_bonus_bps)

@external
def set_paused(paused: bool):
    assert msg.sender == self.owner, "MirageDebtEngine: only owner"
    self.is_paused = paused
    log PausedUpdated(is_paused=paused)

@external
def transfer_ownership(new_owner: address):
    assert msg.sender == self.owner, "MirageDebtEngine: only owner"
    assert new_owner != empty(address), "MirageDebtEngine: zero address"
    old: address = self.owner
    self.owner = new_owner
    log OwnershipTransferred(previous_owner=old, new_owner=new_owner)
