# Porting RWARE

The rules this Coworld plays are
[`semitable/robotic-warehouse`](https://github.com/semitable/robotic-warehouse)'s
`rware/warehouse.py` and `rware/__init__.py`, transcribed into Nim. This page is
what was ported, how the port is proven, and every place it deliberately
diverges.

## The pin

`vendor/upstream/warehouse.py` and `vendor/upstream/__init__.py` are
**byte-pristine** copies at a pinned commit, never edited. `vendor/UPSTREAM.md`
records the repo, the commit hash, the fetch URL and each file's sha256, and
`vendor/LICENSE-rware` carries the upstream licence.

`src/rware/upstream.nim` is the ONE place an upstream number is written down,
each constant beside the line it was read from.

## The three fidelity gates

1. **`tests/test_rware_upstream.nim`** — the tripwire. It regex-parses the
   vendored files and asserts byte-equality against every constant in
   `upstream.nim`: the two grid-size formulas, the four `highway_func` clauses,
   the goal-cell formula, the action enum and its integer values, the direction
   wrap list, `column_height = 8`, the size table
   `{tiny (1,3), small (2,3), medium (2,5), large (3,5)}`, the difficulty table
   `{easy 2, normal 1, hard 0.5}`, `max_steps = 500`, `sensor_range = 1`,
   `msg_bits = 0` and `request_queue_size = int(agents * d)`. A re-vendor that
   changes a number FAILS THE TESTS instead of silently desyncing the game.
2. **`tests/test_rware_layout.nim`** — a direct transcription of upstream's
   layout loop is run for `(rows, cols)` in `{(1,3), (2,3), (2,5), (3,5),
   (1,5)}` and asserted equal, cell for cell, to `warehouse.nim`'s generator;
   `(1,3)` is asserted to yield exactly 10x11, 32 shelves and goals (4,10) and
   (5,10), `(1,5)` exactly 16x11, 64 shelves and goals (7,10) and (8,10); and
   every vertical aisle is asserted to be exactly one cell wide.
3. **`tests/test_rware_determinism.nim`** — the episode is re-derived from the
   replay's seed and order records alone, on a fresh sim, and every per-tick
   `gameHash` must match. The same chain runs in the browser: the wasm viewer
   compiles the SAME `src/rware/sim.nim` and checks the hash at every tick.

## Documented divergences

1. **Deterministic collision tie-breaks.** Upstream delegates the cycle search
   and the longest path to networkx, whose choice among several cycles or
   several longest paths is implementation-defined. The port pins both: cells
   are ordered by index `y*W + x`, the cycle search starts from the
   lowest-indexed node of the component and visits successors in ascending index
   order, and the DAG longest path is broken toward the path whose start node
   has the lowest index. Required for a re-derivable replay; the *rules* —
   2-cycles fail, longer cycles rotate, DAG longest path advances — are
   upstream's exactly.
2. **Who chooses the action changed, not what the actions are.** Per-tick RL
   policies are replaced by five high-level orders under a deterministic pilot.
   The five-action space, the direction wrap list, the loaded-move veto, the
   load/unload rules, the delivery rule and the request refill are upstream's.
3. **`sensor_range` 1 -> 3.** A seat plans 20 ticks ahead and a 3x3 window
   cannot see a corridor conflict forming.
4. **Scoring is `100 x GLOBAL + INDIVIDUAL`** rather than upstream's registered
   `INDIVIDUAL`. The game is fully cooperative and the league needs a rankable
   per-seat integer. Both upstream quantities are recorded in `results`
   (`teamDelivered`, `delivered[]`).
5. **`max_inactivity_steps` disabled.** Upstream's optional inactivity
   termination is off, so a jam is watched rather than hidden.
6. **The request board shows home cells.** Upstream marks requested shelves only
   inside the sensor window; a dispatcher that cannot be told where a shelf
   lives cannot issue `fetch`. Home cells are static warehouse knowledge;
   *dynamic* facts (who is carrying what, which slots are free) stay
   radius-limited.
7. **One game per episode.** The starter's multi-game side swap is not used: a
   cooperative game has no side to swap.
8. **The `courteous` fetch cost adds its contention penalty.** The design note
   writes the choice as minimising `path - contentionPenalty`; minimising that
   would PREFER a shelf another robot is already closer to, which is the
   opposite of the rule the same paragraph describes. The port adds the penalty.
9. **`courteous` has a release valve.** The note's yield rule fires when a
   visible robot with a LOWER slot index is also blocked, so exactly one robot
   in any pair backs off. The lower-slot robot in a standoff may be a `shuttle`,
   which never yields, and then nobody does and the aisle is dead for the rest
   of the episode. A robot blocked for twice `yieldAfter` therefore yields
   whatever its slot — late enough that the slot tie-break still decides every
   ordinary pair.
10. **`yield` plans with the other robots as obstacles.** Everywhere else the
    pilot ignores them on purpose (RWARE's chain rule lets a queue advance
    behind a mover), but the shortest route to the nearest junction is very
    often straight through the robot that is blocking you, which would turn the
    release valve into part of the deadlock.
11. **Two integer RNG streams, not numpy.** `setupRng` draws the spawn cells,
    the facings and the opening request board; `requestRng`'s k-th draw is a
    pure function of `(seed, k)` where `k` is the number of deliveries so far,
    so which shelf is requested next cannot be steered by which seat delivered.
    That is the idea's "request stream seeded" integrity pin, and
    `tests/test_rware_requests.nim` asserts it by replaying the same seed with
    different seat behaviour and comparing the two request sequences.

12. **`fetch` steers to the shelf's CURRENT standing cell, not its home
    cell.** The note names the home cell. A shelf that has been delivered and
    then stowed somewhere else is no longer at home, and a `fetch` aimed at the
    empty home cell would report `shelf_gone` for as long as that shelf stays
    re-stowed -- permanently, for a shelf the request board keeps drawing. The
    two cells differ only after somebody moves a shelf; for a carried shelf,
    which has no standing cell, the goal falls back to its home. The
    observation still advertises the home cell (`decide.nim:93`), which is the
    static warehouse fact the note wants a driver to plan from.
    `docs/RULES.md` states the shipped rule.

## Divergences from the design note's viewer and packaging plan

The entries above are divergences from UPSTREAM. These are divergences from the
DESIGN NOTE: the shipped code is deliberate and internally consistent, but it
does not match what the note describes, so it is recorded here rather than left
for a reader to discover in a diff.

13. **No emscripten virtual filesystem: `--preload-file data@data` and
    `-s FILESYSTEM=1` are dropped.** The note lists both among the link flags
    kept as one internally consistent set. The bootstrap-critical half of that
    set is untouched -- the module is emitted NON-modularized and the Worker
    sets `Module.onRuntimeInitialized`, which is the pairing whose mismatch
    deadlocked cogame-lantern -- but nothing in the bundle reads a preloaded
    file: `Dockerfile.replay-viewer` copies every asset next to the worker and
    `client/broadcast_core.js` fetches them over HTTP, so a `.data` package
    would ship each asset twice and add a second, silent load path.
    `tests/test_rware_viewer.nim` pins the absence rather than accepting
    either shape.

14. **Speed chips are `[1, 2, 4, 8]`, not the note's `[0.5, 1, 2, 4, 8]`.**
    The playback speed is an INTEGER multiplier all the way down: `sim_types`
    holds `PlaybackSpeeds` as an integer array, `wire_constants.nim` emits it
    through `jsIntArray` so the page and the sim cannot disagree, and
    `replay_runtime.advanceReplayFrame` multiplies the tick accumulator by it.
    A `0.5` chip would need a float on that wire and a fractional accumulator
    in the re-derivation path -- the one place this port keeps free of
    floating point (`tests/test_rware_sim.nim`'s no-float grep). The default
    is still `1`, so the note's playback-length arithmetic (500 ticks at 30
    fps = 16.7 s) is unchanged; the starter's own set was
    `[1, 2, 3, 4, 8, 16]`, so this is a narrowing of an integer ladder, not a
    new kind of control.

15. **`#stage.tiny` toggles at 640 px, not the starter's 620.** The note keeps
    the starter's `relayout()` verbatim, and the `--hudscale` clamp IS
    verbatim; only the density threshold moved. Checklist item 11 states
    "labels hidden under `640px`", and the game block's own CSS comment says
    the same, so leaving the toggle at 620 left the 621-640 px band as a strip
    where the plate labels stayed and every comment about them lied.
    `client/page_script.js` carries the same note at the call site.

16. **No `rig_art.nim`: the art is baked in JS at page load, and `global.nim`
    is a JSON payload module.** The note forks the starter's `rig_art.nim`
    compositor and bakes the robot chips, the crates and the floor with pixie
    at install. The starter's compositor exists to feed the Bitworld SPRITE
    PROTOCOL -- a binary sprite stream with server-side pools. This port's wire
    is one UTF-8 JSON state object per frame over an integer cell grid
    (`global.nim` emits `robotsJson`/`shelvesJson`/`requestsJson` in cell space
    and keeps the pool bases as constants), so there is nothing server-side to
    composite into and a pixie dependency would have to be carried into the
    wasm build for nothing.

    The OUTCOME the note describes is produced, from the same byte-for-byte
    starter assets: `client/broadcast_core.js` bakes 96 robot chips (three
    sizes x four facings x loaded/empty, `bakeRobotChips`), the tinted crates
    (`bakeCrates`) and the tiled, 18 %-darkened floor with its chalk aisles and
    workstation pads (`bakeFloor`) once at load, so a frame is blits. It is the
    same file in the native page and in the Worker, so the two delivery modes
    cannot drift.

17. **The endcard forbidden-vocabulary sweep drops the word `kill`.** The note
    lists `kill` among the words that must not appear anywhere in the shipped
    labels and asserts zero matches. It cannot be zero: the same note lists
    `#killfeed` among the starter chrome ids KEPT, and the page carries
    `<div id="killfeed">`. `tests/test_rware_endcard_labels.nim` therefore
    sweeps the note's list minus that one word, and says so at the constant.
    The thing the word was there to catch -- ctf's kill beat -- is enforced
    separately and positively: `tools/build_broadcast_page.py` deletes
    `.beat-marker.kill` through `REMOVED_SELECTORS`, and
    `tests/test_rware_viewer.nim` asserts the beat CSS set is exactly
    `{delivery, jam, fallback, end}`.

18. **`game.docs` ships inline `{"type": "text"}` values, not the note's
    `uri` form.** The note writes the docs block as `uri` references to files
    in the repo; ACCEPTANCE CHECKLIST item 10 (prompts/30-review-loop.md), the
    gate a release is judged against, spells it as
    `{"readme": {"type": "text", "value": ...}, "pages": [{"id", "title",
    "content": {"type": "text", "value": ...}}]}`. The platform validator
    accepts either shape; the checklist does not, so the manifest ships
    `text`. Inlining duplicates files that also live in the tree, so
    `tools/embed_manifest_docs.py` is the single writer of that block and
    `tests/test_rware_manifest.nim` asserts the embedded copy equals the file
    it was embedded from, byte for byte.

19. **`yieldAfter` is 4, not the note's 6.** The note quotes the three
    `courteous` tunables as `yieldAfter = 6, penalty = 4, stowClearance = 2`
    and, in the same paragraph, pins the MECHANISM that produced them: the
    head-to-head sweep in `tools/tune_baselines.nim`, "not guessed", re-run by
    `ci.yml` so a controller change that invalidates the pick is red in CI
    rather than in a ladder round. The r1 fix for finding F17 -- a credited
    `deliver` now finishes and the robot parks off the workstation instead of
    squatting it -- is such a change, and it moved the pick: `(4, 4, 2)` now
    ranks 1st of 27 at the tool's 200-tick horizon and 4th at the test's
    120-tick horizon, where `(6, 4, 2)` fell to 16th. The shipped defaults and
    `tools/ci/baseline_tuning.json` carry the re-swept pick; `penalty` and
    `stowClearance` are unchanged.

20. **`yield`'s passing-place table excludes the robot's own cell and every
    queue-lane cell.** The note defines a passing place as "a highway cell with
    >= 3 free orthogonal neighbours, i.e. an aisle junction (ties by lowest
    cell index)" and names neither exclusion; the >= 3 rule and the tie-break
    are exactly as pinned. Own cell: standing still is a length-1 cycle in the
    move graph, so everyone queued behind the yielding robot still cannot move
    -- a `yield` that resolves to "stay here" is a no-op with a `done` on it.
    Queue lane: the two columns below the shelf blocks are where every delivery
    queues, so backing INTO them moves the standoff onto the one lane that must
    stay clear. Both are stated in `docs/RULES.md` and at the call site in
    `robots.passingPlacesByDistance` / `warehouse.initWarehouse`. (Divergence
    10 above covers the other half of the same order: `yield` is the one order
    that plans with the other robots as obstacles.)

## Not ported

The flattened `(1 + 2*sensor_range)^2` observation vector, `msg_bits`
communication (the radio replaces it), the image observation modes, the
`TWO_STAGE` and `GLOBAL` reward modes as the *score* (both quantities are still
recorded), the `small`/`medium`/`large` layouts as shipped variants (the
generator and the layout test already cover them; they letterbox to 10 px per
cell in a 360 px embed, where a robot's facing stops reading), seat counts other
than 4, and Jumanji's JAX reimplementation — a cross-check reference in
`vendor/UPSTREAM.md`, not a second set of rules.
