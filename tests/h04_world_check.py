#!/usr/bin/env python3
"""H04b: the independent world environment against real EngAIn handlers.

Reuses the H01 isolated services (real 8080 runtime + 8765 scene server, temp state,
disposable test policy). Two runs of the real main.tscn with --selftest --world-check:
  1. empty runtime: the world opens, says so, shows nothing, and the runtime is untouched;
  2. after an explicit signed activation: the world hydrates exactly the runtime's
     bridge_entities for that stamp, and opening it changes no runtime state.
Both runs also check the fly camera, the Trixel destination, and the return to the selector.

Usage: python3 tests/h04_world_check.py [catalog_id]   (needs `godot` and ENGAIN_ROOT)
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("h01", HERE / "h01_runtime_link_check.py")
h01 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h01)
route = h01.route

failures = []


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else f"  {detail}"))
    if not ok:
        failures.append(name)


def field(line, key):
    for part in line.split(" "):
        if part.startswith(key + "="):
            return part[len(key) + 1:]
    return None


def run_godot(services, catalog_id, activate):
    env = dict(os.environ, ENGAIN_TIER1_URL=services.url_8765, ENGAIN_RUNTIME_URL=services.url_8080,
               ENGAIN_ACTIVATOR_CLIENT_ID=h01.ACTIVATOR,
               ENGAIN_ACTIVATOR_KEY_FILE=str(services.key(h01.sai.SERVER_NAME, h01.ACTIVATOR)),
               ENGAIN_OBSERVER_CLIENT_ID=h01.PRESENTER,
               ENGAIN_OBSERVER_KEY_FILE=str(services.key(h01.po.SERVER_NAME, h01.PRESENTER)))
    args = ["godot", "--headless", "--path", str(h01.PROJECT), "--", "--selftest",
            f"--extract-check={catalog_id}", "--world-check"] + (["--world-activate"] if activate else [])
    out = subprocess.run(args, env=env, capture_output=True, text=True, timeout=600)
    lines = {k: next((l for l in out.stdout.splitlines() if l.startswith(f"[selftest] world {k}")), "")
             for k in ("opened", "camera_moved", "returned")}
    for l in lines.values():
        print("  " + l[:400])
    if not all(lines.values()):
        print(out.stdout[-3000:], out.stderr[-3000:])
    return lines, out.returncode


def common(tag, lines, code):
    o, c, r = lines["opened"], lines["camera_moved"], lines["returned"]
    check(f"{tag}: independent_world_opens", field(o, "opened") == "true" and field(o, "main_hidden") == "true", o)
    check(f"{tag}: camera_navigation_operational",
          c != "" and float(field(c, "camera_moved") or 0) > 0.5 and field(c, "mouse_look") == "true", c)
    check(f"{tag}: trixel_destination_registered_to_world", field(c, "surfaces_registered") == "true", c)
    check(f"{tag}: return_to_selector", field(r, "main_visible") == "true" and field(r, "world_freed") == "true"
          and field(r, "surfaces_back_to_preview") == "true", r)
    check(f"{tag}: selector_selection_and_preview_preserved",
          field(r, "selection_preserved") == "true" and field(r, "preview_preserved") == "true", r)
    check(f"{tag}: selector_exit_clean", code == 0, code)


def main():
    with tempfile.TemporaryDirectory(prefix="h04_") as tmp:
        services = h01.Services(Path(tmp))
        catalog_id, vault_id, _ = h01.pick_catalog_id(services, sys.argv[1] if len(sys.argv) > 1 else None)
        print(f"vault={vault_id} catalog_id={catalog_id}")

        print("-- run 1: no active runtime scene")
        lines, code = run_godot(services, catalog_id, activate=False)
        common("empty", lines, code)
        o, c = lines["opened"], lines["camera_moved"]
        check("empty: honest_empty_world", field(o, "state") == "empty" and field(o, "actors") == "0"
              and "No runtime scene is active" in o, o)
        check("empty: no_runtime_mutation", field(c, "stamp_before") == "null" and field(c, "stamp_after") == "null"
              and services.runtime.scene_manager.current_activation() is None, c)

        print("-- run 2: after an explicit signed activation")
        lines, code = run_godot(services, catalog_id, activate=True)
        common("active", lines, code)
        stamp = services.runtime.scene_manager.current_activation()
        payload = services.runtime.get_snapshot()["payload"]
        runtime_ids = sorted(str(e.get("entity_id")) for e in payload.get("bridge_entities", []))
        o, c = lines["opened"], lines["camera_moved"]
        world_ids = sorted((field(o, "ids") or "").split(",")) if field(o, "ids") else []
        check("active: runtime_snapshot_connection", field(o, "state") == "hydrated" and stamp is not None, o)
        check("active: runtime_entity_hydration_exact", world_ids == runtime_ids and len(runtime_ids) > 0,
              f"world={world_ids} runtime={runtime_ids}")
        check("active: stamp_respected_and_unchanged_by_world",
              json.loads(field(c, "stamp_before") or "null") == stamp == json.loads(field(c, "stamp_after") or "null"),
              f"{c} runtime={stamp}")
        check("active: world_did_not_activate_or_build", stamp["load_seq"] == 1 and not list((Path(tmp) / "runtime").glob("trixel32d_*")),
              stamp)
        services.authority.close()
    print(f"H04 {'PASS' if not failures else 'FAIL'} ({len(failures)} failed)")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
