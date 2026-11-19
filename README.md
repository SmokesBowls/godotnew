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

Not yet: placeholders, environment walkthrough, scene selection.
# godotnew
