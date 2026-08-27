## The board payload: the robot chips and shelf crates the viewer blits, the
## baked-floor descriptor and the object-pool sizing.
##
## The board is a GRID, not a pixel arena: coordinates are emitted in CELL
## space and the renderer scales them, so the same packet reads correctly at
## 360 px and at desktop width. There is no fov cache and no shadowcasting --
## spectators see the whole warehouse; the DRIVERS' radius-3 limit lives in the
## observation builder (decide.nim), not in the renderer.

import std/json
import sim_types, sim_state, warehouse, robots

const
  RobotSpriteBase* = 1000
    ## Robot chip pool base id, sized to MaxRobots and filled in slot order,
    ## like the starter's other object families.
  ShelfObjectBase* = 2000
    ## Shelf crate pool base id, sized to MaxShelves and filled in shelf-id
    ## order.
  FloorDarkenPermille* = 180
    ## arena_floor.png is tiled and darkened 18 % at install, plus chalk aisle
    ## lines, the two workstation pads and the shelf-block shadow -- one static
    ## bake, so the per-frame cost is robots, shelves and overlays only.

proc robotsJson*(sim: SimServer): JsonNode =
  ## One entry per robot: `[x, y, facing, carryingShelfOrMinusOne, jammed]`.
  result = newJArray()
  for slot in 0 ..< sim.world.robots.len:
    let robot = sim.world.robots[slot]
    var jammed = 0
    for member in sim.jamState.members:
      if member == slot:
        jammed = 1
    result.add(%[sim.world.wh.cellX(robot.cell), sim.world.wh.cellY(robot.cell),
      robot.facing, robot.carrying, jammed])

proc shelvesJson*(sim: SimServer): JsonNode =
  ## One entry per STANDING shelf: `[x, y, requested]`. A carried shelf rides
  ## on its robot and is drawn from the robot entry, so it is not repeated
  ## here.
  result = newJArray()
  for id in 0 ..< sim.world.shelves.len:
    let shelf = sim.world.shelves[id]
    if shelf.carrier >= 0:
      continue
    result.add(%[sim.world.wh.cellX(shelf.cell), sim.world.wh.cellY(shelf.cell),
      (if sim.world.requested[id]: 1 else: 0)])

proc requestsJson*(sim: SimServer): JsonNode =
  ## The request rail: one chip per queue entry -- the shelf id, its home cell,
  ## and the alias of the robot carrying it when that is publicly known.
  result = newJArray()
  for id in sim.world.requestQueue:
    if id < 0 or id >= sim.world.shelves.len:
      continue
    let shelf = sim.world.shelves[id]
    var carrier = -1
    if shelf.carrier >= 0:
      carrier = shelf.carrier
    result.add(%*{
      "id": shelfLabel(id),
      "x": sim.world.wh.cellX(shelf.home),
      "y": sim.world.wh.cellY(shelf.home),
      "by": carrier
    })

proc deliveriesJson*(sim: SimServer): JsonNode =
  ## The deliveries resolved in the frame just stepped: the renderer flashes
  ## the pad green and strikes the rail chip through.
  result = newJArray()
  for mark in sim.lastDeliveries:
    result.add(%*{
      "slot": mark.slot,
      "shelf": shelfLabel(mark.shelf),
      "station": mark.station
    })

proc jamJson*(sim: SimServer): JsonNode =
  var members = newJArray()
  var cells = newJArray()
  for slot in sim.jamState.members:
    members.add(%slot)
    cells.add(%[sim.world.wh.cellX(sim.world.robots[slot].cell),
      sim.world.wh.cellY(sim.world.robots[slot].cell)])
  %*{
    "on": sim.jamState.active,
    "slots": members,
    "cells": cells,
    "ticks": (if sim.jamState.active: sim.tick - sim.jamState.startedTick + 1
              else: 0)
  }

proc boardJson*(sim: SimServer): JsonNode =
  ## The static board descriptor, sent every frame (it is a handful of numbers)
  ## so a viewer that joins mid-stream never draws an unsized grid.
  var goals = newJArray()
  for goal in sim.world.wh.goals:
    goals.add(%[sim.world.wh.cellX(goal), sim.world.wh.cellY(goal)])
  var storage = newJArray()
  for cell in sim.world.wh.slotCell:
    storage.add(%[sim.world.wh.cellX(cell), sim.world.wh.cellY(cell)])
  %*{
    "w": sim.world.wh.width,
    "h": sim.world.wh.height,
    "goals": goals,
    "storage": storage,
    "floorDarken": FloorDarkenPermille,
    "maxRobots": MaxRobots,
    "maxShelves": MaxShelves
  }
