# godotnew — Verified Capabilities

Run from the project root (needs `godot` 4.6 on PATH and the EngAIn checkout; `ENGAIN_ROOT` overrides its path). All passed on 2026-11-25 at `a2c4bd4`.

| Check | Command | Result | Proves |
|---|---|---|---|
| T02 | `python3 tests/t02_signed_request_check.py` | 0 failures (24 checks) | Godot signatures verify under EngAIn's `SignedRequestVerifier` |
| S03a | `python3 tests/s03a_check.py` | 5/5 | catalog + candidate preview rendering |
| H01 | `python3 tests/h01_runtime_link_check.py` | 22/22 | catalog → inspection (no runtime change) → signed activation → build → consume → apply (counts, transform, collision denied) → stale refusal |
| H02 | `python3 tests/h02_extract_button_check.py` | 10/10 | Extract button: resolver-only, duplicate blocked, receipt, preview refresh, manuscript + runtime unchanged |
| H03 | `python3 tests/h03_reference_stage.py --selftest [--screenshot PNG]` | APPLIED, 5/5 receipts | visible Trixel-built provisional stage (receipts/screenshot: `/mnt/data-drive/EngAIn_Recovery/01_ARCHIVES_ORIGINAL/H03_reference_stage_2026-11-25/`) |
| H04 | `python3 tests/h04_world_check.py` | 18/18 | world opens with/without activation, honest empty world, exact runtime entity hydration, stamp unchanged, camera moves, surfaces routed to world, selector preserved on return |

All harnesses run EngAIn's real handlers in-process with a disposable test policy in a temp dir; nothing touches the production stack, vault, or manuscript.
