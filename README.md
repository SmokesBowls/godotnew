# EngAIn Chapter Selector (G01)

Minimal standalone Godot 4.6 project. Display only: it shows Tier 1's live chapter
catalog from `GET http://127.0.0.1:8765/chapters/catalog` (override with
`ENGAIN_TIER1_URL`). No cache: fetched on open and on every Refresh; any failure
clears the list rather than showing a stale one. Godot decides nothing about the catalog.

Run:       godot --path /mnt/data-drive/devvm-projects/engain-chapter-selector
Self-test: godot --headless --path /mnt/data-drive/devvm-projects/engain-chapter-selector -- --selftest
           (exit 0 when every catalog chapter appears in the tree)

Selecting a chapter shows its Mettaext extraction from GET 8765 /chapters/extraction, labelled
CANDIDATE — not accepted (display only; nothing is sent to 8080).
Extraction check: add --extract-check=<catalog_id> after --selftest.

S03a static scene view: for a CANDIDATE, the first game scene's entities are drawn as capsules,
styled by the active asset pack from GET 8765 /assets/active, and labelled
"placeholder layout — not narrative placement". Positions are exactly as the extraction supplied them.
Entities without an id or position, and duplicate ids, are counted, not drawn.
- No candidate (not extracted, stale, failed, error): nothing is drawn; the state is shown.
- No asset pack: the candidate is still drawn, as built-in capsules labelled "asset pack unavailable".
No 8080, no terrain/environment, no text-triggered generation.
Screenshot: add --screenshot=<png> after --extract-check (needs a display).
Fallback checks: python3 tests/s03a_check.py  (fixture 8765, synthetic data; exit 0 = pass)

Not yet: terrain/environment, walkthrough, scene picker for chapters with several game scenes.
# godotnew
