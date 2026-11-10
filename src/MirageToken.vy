#pragma version ^0.4.0

"""
@title MirageToken
@author ZengLLQ
@notice Standard ERC-20 Synthetic Token implementation for MirageDelta Protocol.
"""

# Events
event Transfer:
    sender: indexed(address)
    receiver: indexed(address)
    value: uint256

event Approval:
    owner: indexed(address)
    spender: indexed(address)
    value: uint256

event MinterUpdated:
    minter: indexed(address)
    status: bool

event OwnershipTransferred:
    previous_owner: indexed(address)
    new_owner: indexed(address)

# State Variables
name: public(String[32])
symbol: public(String[32])
decimals: public(uint8)
totalSupply: public(uint256)

balanceOf: public(HashMap[address, uint256])
allowance: public(HashMap[address, HashMap[address, uint256]])

owner: public(address)
is_minter: public(HashMap[address, bool])

@deploy
def __init__(_name: String[32], _symbol: String[32]):
    self.name = _name
    self.symbol = _symbol
    self.decimals = 18
    self.owner = msg.sender
    log OwnershipTransferred(previous_owner=empty(address), new_owner=msg.sender)

@external
def transfer(to: address, amount: uint256) -> bool:
    assert to != empty(address), "ERC20: transfer to zero address"
    assert self.balanceOf[msg.sender] >= amount, "ERC20: insufficient balance"
    self.balanceOf[msg.sender] -= amount
    self.balanceOf[to] += amount
    log Transfer(sender=msg.sender, receiver=to, value=amount)
    return True

@external
def approve(spender: address, amount: uint256) -> bool:
    assert spender != empty(address), "ERC20: approve to zero address"
    self.allowance[msg.sender][spender] = amount
    log Approval(owner=msg.sender, spender=spender, value=amount)
    return True

@external
def transferFrom(sender: address, recipient: address, amount: uint256) -> bool:
    assert sender != empty(address), "ERC20: transfer from zero address"
    assert recipient != empty(address), "ERC20: transfer to zero address"
    assert self.balanceOf[sender] >= amount, "ERC20: insufficient balance"
    
    current_allowance: uint256 = self.allowance[sender][msg.sender]
    if current_allowance != max_value(uint256):
        assert current_allowance >= amount, "ERC20: insufficient allowance"
        self.allowance[sender][msg.sender] = current_allowance - amount

    self.balanceOf[sender] -= amount
    self.balanceOf[recipient] += amount
    log Transfer(sender=sender, receiver=recipient, value=amount)
    return True

@external
def mint(to: address, amount: uint256) -> bool:
    assert self.is_minter[msg.sender], "MirageToken: caller is not minter"
    assert to != empty(address), "ERC20: mint to zero address"
    self.totalSupply += amount
    self.balanceOf[to] += amount
    log Transfer(sender=empty(address), receiver=to, value=amount)
    return True

@external
def burn(from_addr: address, amount: uint256) -> bool:
    assert self.is_minter[msg.sender], "MirageToken: caller is not minter"
    assert from_addr != empty(address), "ERC20: burn from zero address"
    assert self.balanceOf[from_addr] >= amount, "ERC20: burn exceeds balance"
    self.balanceOf[from_addr] -= amount
    self.totalSupply -= amount
    log Transfer(sender=from_addr, receiver=empty(address), value=amount)
    return True

@external
def set_minter(minter: address, status: bool):
    assert msg.sender == self.owner, "MirageToken: only owner"
    assert minter != empty(address), "MirageToken: zero minter address"
    self.is_minter[minter] = status
    log MinterUpdated(minter=minter, status=status)

@external
def transfer_ownership(new_owner: address):
    assert msg.sender == self.owner, "MirageToken: only owner"
    assert new_owner != empty(address), "MirageToken: zero new owner"
    old_owner: address = self.owner
    self.owner = new_owner
    log OwnershipTransferred(previous_owner=old_owner, new_owner=new_owner)
