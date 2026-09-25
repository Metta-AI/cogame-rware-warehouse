## One game-owned order catalog shared by training and ordinary player policies.

import std/[json, strutils]
import sim_types, warehouse

const ActionCount* = 16

proc actionChoices*(view: JsonNode): JsonNode =
  result = newJArray()
  result.add(%*{"verb": "hold"})
  result.add(%*{"verb": "yield"})
  result.add(%*{"verb": "deliver", "station": "W1"})
  result.add(%*{"verb": "deliver", "station": "W2"})
  for index in 0 ..< 4:
    if index < view["requests"].len:
      result.add(%*{"verb": "fetch",
        "shelf": view["requests"][index]["shelf"]})
    else:
      result.add(newJNull())
  for index in 0 ..< MaxFreeSlotsReported:
    if index < view["seen"]["free_slots"].len:
      let cell = view["seen"]["free_slots"][index]
      result.add(%*{"verb": "stow", "x": cell[0], "y": cell[1]})
    else:
      result.add(newJNull())
  doAssert result.len == ActionCount

proc values*(view: JsonNode): JsonNode =
  result = newJArray()
  for field in ["turn", "of", "tick", "turn_ticks", "ticks_left"]:
    result.add(view[field])
  let warehouse = view["warehouse"]
  for field in ["width", "height", "storage_slots", "sensor_range"]:
    result.add(warehouse[field])
  for station in ["W1", "W2"]:
    for coordinate in warehouse["stations"][station]: result.add(coordinate)
  let robot = view["you_are"]
  for coordinate in robot["cell"]: result.add(coordinate)
  for facing in ["up", "right", "down", "left"]:
    result.add(%(if robot["facing"].getStr() == facing: 1 else: 0))
  result.add(%(if robot["loaded"].getBool(): 1 else: 0))
  result.add(%(if robot["carrying"].kind == JString:
    parseShelfLabel(robot["carrying"].getStr(), MaxShelves) else: -1))
  for field in ["order_age_turns", "blocked_ticks_last_turn"]:
    result.add(robot[field])
  result.add(%(if robot["on_aisle"].getBool(): 1 else: 0))
  for status in ["running", "done", "shelf_gone", "no_path",
                 "no_free_slot", "not_loaded", "already_loaded"]:
    result.add(%(if robot["last_order_result"].getStr() == status: 1 else: 0))
  for index in 0 ..< 4:
    if index < view["requests"].len:
      let request = view["requests"][index]
      result.add(%parseShelfLabel(request["shelf"].getStr(), MaxShelves))
      for coordinate in request["home"]: result.add(coordinate)
    else:
      for _ in 0 ..< 3: result.add(%(-1))
  for index in 0 ..< MaxFreeSlotsReported:
    if index < view["seen"]["free_slots"].len:
      for coordinate in view["seen"]["free_slots"][index]:
        result.add(coordinate)
    else:
      result.add(%(-1))
      result.add(%(-1))
  for other in ["Alpha", "Bravo", "Charlie", "Delta"]:
    var visible = false
    for seen in view["seen"]["robots"]:
      if seen["alias"].getStr() == other:
        visible = true
        for coordinate in seen["cell"]: result.add(coordinate)
        result.add(%(if seen["loaded"].getBool(): 1 else: 0))
        for facing in ["up", "right", "down", "left"]:
          result.add(%(if seen["facing"].getStr() == facing: 1 else: 0))
    if not visible:
      for _ in 0 ..< 7: result.add(%(-1))
  let fleet = view["fleet_status"]
  for field in ["delivered", "par", "jam_ticks"]: result.add(fleet[field])
  result.add(%(if fleet["jam"].getBool(): 1 else: 0))
  let rows = warehouse["floor_plan"].getStr().splitLines()
  for y in 0 ..< 11:
    for x in 0 ..< 16:
      let tile = if y < rows.len and x < rows[y].len: rows[y][x] else: ' '
      for symbol in ['#', '.', 'W']:
        result.add(%(if tile == symbol: 1 else: 0))
