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

Everything not listed above is upstream's, and `tests/test_rware_upstream.nim`,
`tests/test_rware_layout.nim` and `tests/test_rware_determinism.nim` are what
keep it that way.
