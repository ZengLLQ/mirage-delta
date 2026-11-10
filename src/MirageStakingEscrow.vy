#pragma version ^0.4.0

"""
@title MirageStakingEscrow
@author ZengLLQ
@notice Continuous Linear Vesting & Staking Reward Escrow for MirageDelta Protocol.
"""

interface IERC20:
    def transfer(to: address, amount: uint256) -> bool: nonpayable
    def transferFrom(sender: address, recipient: address, amount: uint256) -> bool: nonpayable
    def balanceOf(account: address) -> uint256: view

# Structs
struct VestingSchedule:
    beneficiary: address
    total_amount: uint256
    claimed_amount: uint256
    start_time: uint256
    duration: uint256
    cliff_duration: uint256
    is_active: bool

# Events
event ScheduleCreated:
    schedule_id: indexed(uint256)
    beneficiary: indexed(address)
    total_amount: uint256
    duration: uint256
    cliff: uint256

event TokensClaimed:
    schedule_id: indexed(uint256)
    beneficiary: indexed(address)
    amount: uint256

event ScheduleCancelled:
    schedule_id: indexed(uint256)
    beneficiary: indexed(address)
    refund_amount: uint256

event OwnershipTransferred:
    previous_owner: indexed(address)
    new_owner: indexed(address)

# Constants
WAD: constant(uint256) = 1000000000000000000

# State Variables
owner: public(address)
reward_token: public(address)
schedule_count: public(uint256)
total_escrowed: public(uint256)
total_claimed: public(uint256)

schedules: public(HashMap[uint256, VestingSchedule])
user_schedule_count: public(HashMap[address, uint256])
user_schedules: public(HashMap[address, HashMap[uint256, uint256]]) # user -> index -> schedule_id

@deploy
def __init__(_reward_token: address):
    assert _reward_token != empty(address), "MirageStakingEscrow: zero reward token"
    self.owner = msg.sender
    self.reward_token = _reward_token
    log OwnershipTransferred(previous_owner=empty(address), new_owner=msg.sender)

@external
def create_schedule(
    beneficiary: address,
    amount: uint256,
    duration: uint256,
    cliff_duration: uint256
) -> uint256:
    assert msg.sender == self.owner, "MirageStakingEscrow: only owner"
    assert beneficiary != empty(address), "MirageStakingEscrow: zero beneficiary"
    assert amount > 0, "MirageStakingEscrow: zero amount"
    assert duration > 0, "MirageStakingEscrow: zero duration"
    assert cliff_duration <= duration, "MirageStakingEscrow: cliff exceeds duration"

    sched_id: uint256 = self.schedule_count
    self.schedule_count += 1

    self.schedules[sched_id] = VestingSchedule(
        beneficiary=beneficiary,
        total_amount=amount,
        claimed_amount=0,
        start_time=block.timestamp,
        duration=duration,
        cliff_duration=cliff_duration,
        is_active=True
    )

    idx: uint256 = self.user_schedule_count[beneficiary]
    self.user_schedules[beneficiary][idx] = sched_id
    self.user_schedule_count[beneficiary] = idx + 1
    self.total_escrowed += amount

    extcall IERC20(self.reward_token).transferFrom(msg.sender, self, amount)
    log ScheduleCreated(
        schedule_id=sched_id,
        beneficiary=beneficiary,
        total_amount=amount,
        duration=duration,
        cliff=cliff_duration
    )

    return sched_id

@view
@external
def get_claimable(schedule_id: uint256) -> uint256:
    sched: VestingSchedule = self.schedules[schedule_id]
    if not sched.is_active:
        return 0
    if block.timestamp < sched.start_time + sched.cliff_duration:
        return 0

    elapsed: uint256 = block.timestamp - sched.start_time
    if elapsed >= sched.duration:
        return sched.total_amount - sched.claimed_amount

    vested_total: uint256 = (sched.total_amount * elapsed) // sched.duration
    if vested_total > sched.claimed_amount:
        return vested_total - sched.claimed_amount
    return 0

@external
def claim(schedule_id: uint256) -> uint256:
    sched: VestingSchedule = self.schedules[schedule_id]
    assert sched.is_active, "MirageStakingEscrow: schedule inactive"
    assert msg.sender == sched.beneficiary or msg.sender == self.owner, "MirageStakingEscrow: unauthorized"
    assert block.timestamp >= sched.start_time + sched.cliff_duration, "MirageStakingEscrow: cliff not reached"

    elapsed: uint256 = block.timestamp - sched.start_time
    claimable: uint256 = 0
    if elapsed >= sched.duration:
        claimable = sched.total_amount - sched.claimed_amount
    else:
        vested_total: uint256 = (sched.total_amount * elapsed) // sched.duration
        if vested_total > sched.claimed_amount:
            claimable = vested_total - sched.claimed_amount

    assert claimable > 0, "MirageStakingEscrow: nothing to claim"

    self.schedules[schedule_id].claimed_amount += claimable
    self.total_claimed += claimable

    extcall IERC20(self.reward_token).transfer(sched.beneficiary, claimable)
    log TokensClaimed(schedule_id=schedule_id, beneficiary=sched.beneficiary, amount=claimable)

    return claimable

@external
def cancel_schedule(schedule_id: uint256):
    assert msg.sender == self.owner, "MirageStakingEscrow: only owner"
    sched: VestingSchedule = self.schedules[schedule_id]
    assert sched.is_active, "MirageStakingEscrow: already inactive"

    unclaimed: uint256 = sched.total_amount - sched.claimed_amount
    self.schedules[schedule_id].is_active = False

    if unclaimed > 0:
        self.total_escrowed -= unclaimed
        extcall IERC20(self.reward_token).transfer(self.owner, unclaimed)

    log ScheduleCancelled(schedule_id=schedule_id, beneficiary=sched.beneficiary, refund_amount=unclaimed)

@external
def transfer_ownership(new_owner: address):
    assert msg.sender == self.owner, "MirageStakingEscrow: only owner"
    assert new_owner != empty(address), "MirageStakingEscrow: zero address"
    old: address = self.owner
    self.owner = new_owner
    log OwnershipTransferred(previous_owner=old, new_owner=new_owner)
