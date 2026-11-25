#!/usr/bin/env python3
"""H02: the Extract chapter button against EngAIn's real 8765 handler.

8765 (scene_server, single-threaded HTTPServer exactly like production) serves the real
active vault's catalog (read-only) with a throwaway Stageroom, so the extraction writes
its candidate into a temp dir. An isolated 8080 runtime handler runs beside it only to
prove extraction never touches runtime state. Godot runs the real main.tscn with
--selftest --extract-check=<id> --extract-trigger.

Usage: python3 tests/h02_extract_button_check.py [catalog_id]
(default book_01_book_of_genesis/001_the_ethereal_vigil.md; needs `godot` and ENGAIN_ROOT)
"""
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import threading
import urllib.request
from http.server import HTTPServer, ThreadingHTTPServer
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
ENGAIN = Path(os.environ.get("ENGAIN_ROOT", Path.home() / "Desktop/burdens_of_a_forgotten_past/EngAIn"))
sys.path.insert(0, str(ENGAIN))
sys.dont_write_bytecode = True
os.environ.setdefault("PYTHONDONTWRITEBYTECODE", "1")

from tier1.engainos.bridgeroom import scene_server  # noqa: E402
from tier1.engainos.tools.run_chapter_extraction import find_entry  # noqa: E402
from tier2.godotsim import sim_runtime  # noqa: E402
from tier2.godotsim.http_handlers import RuntimeHTTPHandler  # noqa: E402
from tier2.godotsim.runtime_core import EngAInRuntime  # noqa: E402

CATALOG_ID = sys.argv[1] if len(sys.argv) > 1 else "book_01_book_of_genesis/001_the_ethereal_vigil.md"
failures = []


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else f"  {detail}"))
    if not ok:
        failures.append(name)


def serve(server):
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_address[1]}"


def get(url):
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.loads(r.read())


def file_state(path):
    return path.stat().st_mtime_ns, hashlib.sha256(path.read_bytes()).hexdigest()


with tempfile.TemporaryDirectory(prefix="h02_") as tmp:
    stageroom = Path(tmp) / "stageroom"
    scene_server.SceneRequestHandler.stageroom_path = stageroom
    url_8765 = serve(HTTPServer(("127.0.0.1", 0), scene_server.SceneRequestHandler))

    runtime = EngAInRuntime()
    RuntimeHTTPHandler.runtime = runtime
    sim_runtime._install_live_edit_shims(RuntimeHTTPHandler, runtime)
    url_8080 = serve(ThreadingHTTPServer(("127.0.0.1", 0), RuntimeHTTPHandler))

    vault, entry = find_entry(CATALOG_ID)  # the existing resolver, as the endpoint uses it
    chapter = Path(entry["path"])
    manuscript_before = file_state(chapter)
    vault_listing_before = sorted(str(p) for p in Path(vault["root"]).rglob("*"))
    peek_before = get(url_8080 + "/snapshot/peek")["payload"]
    print(f"vault={vault['vault_id']} catalog_id={CATALOG_ID} stageroom={stageroom}")

    out = subprocess.run(["godot", "--headless", "--path", str(PROJECT), "--",
                          "--selftest", f"--extract-check={CATALOG_ID}", "--extract-trigger"],
                         env=dict(os.environ, ENGAIN_TIER1_URL=url_8765, ENGAIN_RUNTIME_URL=url_8080),
                         capture_output=True, text=True, timeout=900)
    lines = [l for l in out.stdout.splitlines() if l.startswith("[selftest]")]
    for l in lines:
        print("  " + l)
    trig = next((l for l in lines if " extract selected " in l), "").lower()
    first = trig
    done = next((l for l in lines if " extract finished " in l), "")
    final = [l for l in lines if " extraction catalog_id=" in l][-1:] or [""]

    check("valid_chapter_selection", f"catalog_id={CATALOG_ID}".lower() in first and ("state=not_extracted" in first or "state=stale" in first), first)
    check("button_enabled_for_unextracted_chapter", "button_enabled_before=true" in trig, trig)
    check("duplicate_extraction_prevented",
          "button_disabled_while_running=true" in trig and "duplicate_blocked=true" in trig, trig)
    check("extraction_request_delivered", bool(done), out.stdout[-2000:] + out.stderr[-2000:])
    receipts = list(stageroom.rglob("receipt.json"))
    receipt = json.loads(receipts[0].read_text()) if len(receipts) == 1 else {}
    check("existing_catalog_resolver_used", receipt.get("catalog_id") == CATALOG_ID
          and receipt.get("source_sha256") == entry["source_sha256"]
          and receipt.get("vault", {}).get("vault_id") == vault["vault_id"], receipt.get("vault"))
    check("existing_mettaext_operation_executed",
          receipt.get("extractor", {}).get("driver") == "tier3/mettaext/narrative_to_game.py"
          and receipt.get("returncode") == 0, receipt.get("returncode"))
    check("extraction_receipt_returned",
          "state=finished" in done and "receipt_status=candidate" in done
          and "engain.chapter_extraction_receipt.v1" in done, done)
    check("candidate_preview_refreshed", "state=candidate" in final[0] and out.returncode == 0,
          f"{final[0]} exit={out.returncode}")
    check("manuscript_unchanged", file_state(chapter) == manuscript_before
          and sorted(str(p) for p in Path(vault["root"]).rglob("*")) == vault_listing_before)
    peek_after = get(url_8080 + "/snapshot/peek")["payload"]
    check("runtime_state_unchanged", peek_after.get("scene_activation") is None
          and peek_after.get("scene_activation") == peek_before.get("scene_activation")
          and runtime.scene_manager.current_activation() is None
          and peek_after.get("scene_id") == peek_before.get("scene_id"))
    if receipt:
        print("receipt: " + json.dumps({k: receipt[k] for k in (
            "contract", "status", "acceptance", "catalog_id", "source_sha256", "returncode", "game_scenes")}))

print(f"H02 {'PASS' if not failures else 'FAIL'} ({len(failures)} failed)")
sys.exit(1 if failures else 0)
