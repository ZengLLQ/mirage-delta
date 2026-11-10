#pragma version ^0.4.0

"""
@title MirageOracle
@author ZengLLQ
@notice High-Precision Multi-Asset Oracle & Staleness Guard for MirageDelta Protocol.
"""

# Events
event PriceUpdated:
    asset: indexed(bytes32)
    price: uint256
    timestamp: uint256

event ReporterUpdated:
    reporter: indexed(address)
    status: bool

event MaxStaleDurationUpdated:
    new_duration: uint256

event OwnershipTransferred:
    previous_owner: indexed(address)
    new_owner: indexed(address)

# State Variables
owner: public(address)
max_stale_duration: public(uint256)
is_reporter: public(HashMap[address, bool])

prices: public(HashMap[bytes32, uint256])
last_update: public(HashMap[bytes32, uint256])

@deploy
def __init__():
    self.owner = msg.sender
    self.is_reporter[msg.sender] = True
    self.max_stale_duration = 3600  # 1 hour
    log OwnershipTransferred(previous_owner=empty(address), new_owner=msg.sender)
    log ReporterUpdated(reporter=msg.sender, status=True)

@external
def set_price(asset: bytes32, price: uint256):
    assert self.is_reporter[msg.sender] or msg.sender == self.owner, "MirageOracle: unauthorized reporter"
    assert price > 0, "MirageOracle: price must be positive"
    assert asset != empty(bytes32), "MirageOracle: zero asset key"

    self.prices[asset] = price
    self.last_update[asset] = block.timestamp
    log PriceUpdated(asset=asset, price=price, timestamp=block.timestamp)

@external
def set_prices(assets: DynArray[bytes32, 32], new_prices: DynArray[uint256, 32]):
    assert self.is_reporter[msg.sender] or msg.sender == self.owner, "MirageOracle: unauthorized reporter"
    assert len(assets) == len(new_prices), "MirageOracle: length mismatch"

    for i: uint256 in range(32):
        if i >= len(assets):
            break
        a: bytes32 = assets[i]
        p: uint256 = new_prices[i]
        assert p > 0, "MirageOracle: price must be positive"
        assert a != empty(bytes32), "MirageOracle: zero asset key"
        self.prices[a] = p
        self.last_update[a] = block.timestamp
        log PriceUpdated(asset=a, price=p, timestamp=block.timestamp)

@view
@external
def get_price(asset: bytes32) -> uint256:
    p: uint256 = self.prices[asset]
    assert p > 0, "MirageOracle: price uninitialized"
    lu: uint256 = self.last_update[asset]
    assert block.timestamp >= lu, "MirageOracle: future timestamp"
    assert block.timestamp - lu <= self.max_stale_duration, "MirageOracle: price is stale"
    return p

@view
@external
def get_price_unsafe(asset: bytes32) -> uint256:
    p: uint256 = self.prices[asset]
    assert p > 0, "MirageOracle: price uninitialized"
    return p

@external
def set_reporter(reporter: address, status: bool):
    assert msg.sender == self.owner, "MirageOracle: only owner"
    assert reporter != empty(address), "MirageOracle: zero address"
    self.is_reporter[reporter] = status
    log ReporterUpdated(reporter=reporter, status=status)

@external
def set_max_stale_duration(duration: uint256):
    assert msg.sender == self.owner, "MirageOracle: only owner"
    assert duration >= 60, "MirageOracle: duration too short"
    self.max_stale_duration = duration
    log MaxStaleDurationUpdated(new_duration=duration)

@external
def transfer_ownership(new_owner: address):
    assert msg.sender == self.owner, "MirageOracle: only owner"
    assert new_owner != empty(address), "MirageOracle: zero address"
    old: address = self.owner
    self.owner = new_owner
    log OwnershipTransferred(previous_owner=old, new_owner=new_owner)
