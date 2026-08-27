# Vendored upstream — `semitable/robotic-warehouse`

The rules this Coworld plays are RWARE's. The two files under `upstream/` are
**byte-pristine** copies at a pinned commit and are never edited: they are the
evidence `src/rware/upstream.nim` is checked against, not a dependency of the
build.

| field | value |
| --- | --- |
| repo | `https://github.com/semitable/robotic-warehouse` |
| commit | `96fbc64e3eae5fee915e0d390f864fa06ddccd47` |
| committed | 2024-09-15 |
| licence | MIT — copied verbatim to `vendor/LICENSE-rware` |

## Files

| path | upstream path | sha256 |
| --- | --- | --- |
| `upstream/warehouse.py` | `rware/warehouse.py` | `cc1be89dd654cde7928d6f0a813ebf36f070764adeb137fc1b74065f9344d12a` |
| `upstream/__init__.py` | `rware/__init__.py` | `a5aa8b89cf8bf06fd644d9514a6b7af66132df50b6867601b947af608da70352` |

## Fetch

```bash
C=96fbc64e3eae5fee915e0d390f864fa06ddccd47
for f in rware/warehouse.py rware/__init__.py LICENSE; do
  curl -fsSL "https://raw.githubusercontent.com/semitable/robotic-warehouse/$C/$f" \
    -o "vendor/upstream/$(basename "$f")"
done
sha256sum vendor/upstream/warehouse.py vendor/upstream/__init__.py
```

Re-vendoring is expected to break `tests/test_rware_upstream.nim` whenever a
constant moved. That is the point: the tripwire regex-parses these files and
asserts byte-equality against every constant in `src/rware/upstream.nim`, so a
silent desync is impossible.

## Cross-reference

[Jumanji's `RobotWarehouse`](https://github.com/instadeepai/jumanji) is a JAX
reimplementation of the same environment. It was read as a cross-check while
writing the port — the collision-resolution rules and the highway formula agree
— but it is **not** a second set of rules: the port target is
`semitable/robotic-warehouse` and the tripwire only ever reads the files above.

See `PATCHES.md` for every place the port deliberately diverges.
