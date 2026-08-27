# cogame-rware-warehouse

**A port of [`semitable/robotic-warehouse`](https://github.com/semitable/robotic-warehouse)
(RWARE) to a Coworld, with four ROBOT DRIVERS instead of four per-tick RL policies.**

Four robots share a small warehouse. Shelves stand in blocks; the aisles between
them are one cell wide. Two workstations sit at the bottom of the middle lane. A
station board shows the requested shelves, and a robot must drive to a requested
shelf, drive **under** it, lift it, carry it to a workstation, and then carry it
back to an empty storage slot and put it down — because a loaded robot cannot
pass under another standing shelf and cannot pick anything else up until it has
stowed what it holds.

**Nobody scores alone.** The number the league reads is the number of shelves the
*fleet* delivered, and the only way to lose it is to jam the aisles.

## A policy is just a prompt

A seat is an LLM if it sets `PLAYER_PROMPT`, and a scripted baseline if it sets
`PLAYER_SCRIPTED=shuttle|courteous`. Both come out of the same image, and the
game server — not the player container — makes every model call.

Every 20 ticks each driver is handed its robot's view of the warehouse and
answers with one JSON order:

```json
{"verb": "fetch", "shelf": "S12", "say": "taking S12, keep column 7 clear",
 "notes": "then stow at (2,7)"}
```

`fetch` · `deliver` · `stow` · `yield` · `hold` — five orders, and a
deterministic pilot drives the robot until the order finishes or the driver
changes it. `say` is a fleet radio call every other robot hears next turn; it is
the only channel through which intentions travel, and it is what makes ad-hoc
coordination in a one-wide corridor a real problem.

## What makes it hard

You drive **one** robot and you cannot control the other three. Two robots that
meet head-on in a one-wide aisle both stay put — forever — until one of them
yields. A line of robots *can* move together if the one in front has somewhere to
go. The workstation queue lane is where every delivery jams, and a fleet that
deadlocks there plays out its 500 ticks with the jam flag lit and scores zero.

## Scoring

```
delivered[s]   = requested shelves delivered by seat s's robot
teamDelivered  = sum over s of delivered[s]
scores[s]      = 100 * teamDelivered + delivered[s]
```

Higher is better; no term is ever negative. The first term is identical for all
four seats — pure common interest. The second exists only so the ladder is not a
draw machine, and it is deliberately an epsilon: a full round trip takes at least
12 ticks, so `delivered[s] < 100` always and the ordering is strictly
lexicographic — **team throughput first, own deliveries only as a tie-break**.

`results.win[s]` is `teamDelivered >= parDeliveries`, the same boolean for all
four seats, and `results.winner` is always `null`: a cooperative episode has no
winner.

## Two name spaces

In-game the seats are **Alpha, Bravo, Charlie and Delta**. Those aliases are the
only names that appear in an observation, a prompt, an order, a radio line or a
sprite label, so a driver can never learn who it is working with. The seats' real
policy names live only in `results.names`, in the replay's join records and in
the viewer's scorebug.

## Watching

Replays are a **static wasm bundle**, never a pod: the same Nim sim module the
server runs is compiled to WebAssembly and re-derives every frame in the browser
from the recorded orders, checking a per-tick hash as it goes. The viewer draws
the whole warehouse edge to edge with the request rail in the top band, the
delivered counter in the clock, a labelled jam chip, a deliveries sparkline with
the jam spans shaded behind it, and clickable beat markers for every delivery,
jam, fallback and the end.

## Layout

| path | what |
| --- | --- |
| `src/rware/` | the sim, the server, the decision layer and the replay codec |
| `src/rware_warehouse.nim` | the game server entrypoint |
| `src/rware_warehouse_player.nim` | the thin seat registrar |
| `replay-viewer/` | the wasm entry, the emscripten config and the static shell |
| `client/` | the broadcast chrome and the board renderer |
| `vendor/upstream/` | byte-pristine `rware/warehouse.py` and `rware/__init__.py` |
| `tools/` | the build hooks, the replay forensics and the tuning sweep |
| `docs/RULES.md` | the rules in full |
| `docs/PORTING-RWARE.md` | what was ported, what diverged and why |

## Building

```bash
nim c -d:release --path:src -o:rware-warehouse src/rware_warehouse.nim
nim c -r --path:src tests/tests.nim          # the whole suite
docker build -t coworld-rware-warehouse:latest .
./tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
```

MIT licensed. The vendored upstream sources keep their own licence in
`vendor/LICENSE-rware`.
