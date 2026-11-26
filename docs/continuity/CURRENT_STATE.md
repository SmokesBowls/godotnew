# godotnew (EngAIn Chapter Selector) — Current State

Last updated: 2026-11-25. Branch `main`, all work pushed (see `git log -1`). Development paused for the manuscript rewrite.
Godot 4.6.1, GL Compatibility. Entry scene: `res://main.tscn`. EngAIn: `~/Desktop/burdens_of_a_forgotten_past/EngAIn` (see its `docs/continuity/`).
Push: origin is HTTPS without stored credentials — use `git push git@github.com:SmokesBowls/godotnew.git main`.

## What exists

| Piece | File / function | Commit |
|---|---|---|
| Chapter selector: live catalog Book → Chapter, candidate details, CANDIDATE — not accepted | `main.gd` | pre-T02 (G01/M01c) |
| Object preview (Layer 1, inspection only, own SubViewport world) | `scene_view.gd::render`, `semantic_actor.tscn` | S03a `e03b731` |
| Signed-request client (byte-identical to donor) | `scripts/EngAInSignedRequest.gd` | T02 `89e589c` |
| Runtime link: signed activation, peek, presentation testimony, consume + apply | `scripts/EngAInRuntimeLink.gd` (`activate_candidate`, `activate_scene`, `peek`, `present`, `report_observation`, `apply_authorization`, `normalize_load`, `surface_container`) | H01 `0f9eafc`, `a2c4bd4` |
| Live apply executor + surface consumer (byte-identical donor ports) | `trixel_proof/trixel32d_apply_executor/godot/*.gd`, `trixel_proof/trixel32d_passive/godot/*.gd` | H01 `0f9eafc` |
| Buttons: Activate in runtime (DRAFT), Extract chapter, Open World Environment; Construct reference stage (PROVISIONAL TEST) only when launched by the H03 harness | `main.gd` (`_on_activate_pressed`, `_on_extract_pressed`, `open_world`/`close_world`, `_on_stage_pressed`) | H01, H02 `509dfd4`, H04b, H03 `341cc70` |
| World environment (Layer 2, separate): environment, light, camera rig + fly camera, Surfaces, Actors; hydrates runtime `bridge_entities` for the current stamp | `world_environment.tscn`, `world_environment.gd` (`open`, `refresh`, `hydrate`, `handle_movement`, `handle_mouse_look`) | H04b `a2c4bd4` |

## Launch

- Against the running EngAIn stack (catalog, preview, extraction work; activation needs credentials the stack does not deliver yet): open the project in Godot and run `main.tscn`. URLs default to `127.0.0.1:8765` / `:8080`; override with `ENGAIN_TIER1_URL`, `ENGAIN_RUNTIME_URL`.
- With isolated EngAIn services and test credentials (activation, world, provisional stage all usable): `python3 tests/h03_reference_stage.py` (opens the window; Activate → Open World Environment / Construct reference stage).

## Credentials (environment only, never in the project)

`ENGAIN_ACTIVATOR_CLIENT_ID/_KEY_FILE`, `ENGAIN_OBSERVER_CLIENT_ID/_KEY_FILE`, `ENGAIN_EXECUTOR_CLIENT_ID/_KEY_FILE`, `ENGAIN_TRIXEL32D_GRANT_PUBLIC_KEY_FILE`, `ENGAIN_H03_BUILD_CALLER_URL`. `.gitignore` excludes `*.key`, `*.pem`.

## Where development stopped

H04b. See NEXT_OPERATION.md.
