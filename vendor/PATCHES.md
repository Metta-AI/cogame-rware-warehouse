# Patches — where this port diverges from upstream

The vendored files under `upstream/` are byte-pristine and are never edited.
Every divergence lives in the Nim port and is enumerated here, mirrored from
`docs/PORTING-RWARE.md`, so a reviewer can diff intent against code in one
place.

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

Everything not listed above is upstream's, and `tests/test_rware_upstream.nim`,
`tests/test_rware_layout.nim` and `tests/test_rware_determinism.nim` are what
keep it that way.
