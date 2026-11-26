# godotnew — Open Blockers

| # | Blocker | Effect | Owner |
|---|---|---|---|
| 1 | No real scene environment (EngAIn D1/D2: measurement basis, elevation source) | world shows light, camera and runtime entities only | EngAIn architect / WorldField |
| 2 | Production policies deny-all; `start_stack.fish` delivers no credentials (EngAIn D3, D5) | Activate / consume only work under the test harnesses | EngAIn architect |
| 3 | No production build caller or authorization handoff (EngAIn D6) | surfaces appear only via the H03 harness | EngAIn Tier 1 |
| 4 | Surfaces render grey: donor consumer writes vertex colours, no material uses them (EngAIn D9) | declared appearance not shown | decision: patch port vs material in godotnew |
| 5 | World view sends no presentation testimony of its own (only activation does) | builds rely on the activating session's testimony | design choice to revisit |
| 6 | Preview shows the 5 **candidate** entities (Mettaext Pass 4 `@entities`, via Pass 5); world shows the 17 **runtime** entities (those 5 + 12 added by GodotSim's `SceneExtractor` from the narration, several not real entities). Keep them distinct; see EngAIn `docs/continuity/CURRENT_STATE.md` findings #4 | by design: each view shows its own source | EngAIn GodotSim / Mettaext |
| 7 | `tests/h01_runtime_link_check.gd.uid` untracked (Godot-generated) | none | — |
