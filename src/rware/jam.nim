## The deadlock detector of tick step 8, and the jam-span table the viewer's
## scrubber and sparkline read.
##
## A JAM is the set of robots with `stuck >= jamTicks` that are linked by the
## blocking relation -- robot A's requested cell is occupied by robot B --
## closed transitively, with AT LEAST TWO members. A single robot grinding
## against a wall is stuck, not jammed: nobody else is waiting on it.
##
## PURE INTEGER (see warehouse.nim).

import robots

type
  JamState* = object
    active*: bool
    members*: seq[int]        ## robot slots, ascending
    startedTick*: int
    ticksTotal*: int          ## every tick a jam was active, episode-wide
    longestTicks*: int
    count*: int               ## how many distinct jams have started

proc sameMembers*(a, b: seq[int]): bool =
  if a.len != b.len:
    return false
  for i in 0 ..< a.len:
    if a[i] != b[i]:
      return false
  true

proc detectJam*(
  world: World, wanted: openArray[int], jamTicks: int
): seq[int] =
  ## `wanted[slot]` is the cell that robot requested this tick (its own cell
  ## when it did not request FORWARD). Returns the jammed slots, ascending, or
  ## an empty seq.
  let count = world.robots.len
  var eligible = newSeq[bool](count)
  for slot in 0 ..< count:
    eligible[slot] = world.robots[slot].stuck >= jamTicks
  # Union-find over the blocking relation, restricted to eligible robots.
  var parent = newSeq[int](count)
  for slot in 0 ..< count:
    parent[slot] = slot

  proc find(parent: var seq[int], slot: int): int =
    var root = slot
    while parent[root] != root:
      root = parent[root]
    var walk = slot
    while parent[walk] != walk:
      let next = parent[walk]
      parent[walk] = root
      walk = next
    root

  var linked = newSeq[bool](count)
  for slot in 0 ..< count:
    if not eligible[slot]:
      continue
    let target = wanted[slot]
    if target == world.robots[slot].cell:
      continue
    let other = world.robotAtCell(target)
    if other < 0 or other == slot or not eligible[other]:
      continue
    linked[slot] = true
    linked[other] = true
    let
      a = find(parent, slot)
      b = find(parent, other)
    if a != b:
      parent[min(a, b)] = min(a, b)
      parent[max(a, b)] = min(a, b)
  # The largest linked group, tie-broken toward the lowest member slot.
  var
    best: seq[int] = @[]
  for root in 0 ..< count:
    if not eligible[root] or not linked[root] or find(parent, root) != root:
      continue
    var group: seq[int]
    for slot in 0 ..< count:
      if eligible[slot] and linked[slot] and find(parent, slot) == root:
        group.add(slot)
    if group.len >= 2 and group.len > best.len:
      best = group
  best

proc updateJam*(
  state: var JamState, members: seq[int], tick: int
): tuple[started, cleared: bool, clearedTicks: int] =
  ## Folds this tick's jam set into the running state and reports the
  ## transitions the feed, the beats and the events all read from one place.
  result = (false, false, 0)
  if members.len >= 2:
    if not state.active:
      state.active = true
      state.startedTick = tick
      inc state.count
      result.started = true
    elif not sameMembers(state.members, members):
      result.started = true
    state.members = members
    inc state.ticksTotal
    let run = tick - state.startedTick + 1
    if run > state.longestTicks:
      state.longestTicks = run
  elif state.active:
    state.active = false
    result.cleared = true
    result.clearedTicks = tick - state.startedTick
    state.members = @[]
