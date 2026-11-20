#!/usr/bin/env python3
"""S03a fallback checks: runs the selector headless against a fixture 8765 (synthetic data only).

Each case serves a chosen /chapters/extraction and /assets/active answer and asserts what the
scene view drew. Missing extraction must draw nothing; a missing asset pack must still draw the
candidate, as labelled built-in capsules.

Usage: python3 tests/s03a_check.py   (needs `godot` on PATH; exit 0 = all cases pass)
"""
import json
import os
import re
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
CID = "book_test/001_fixture.md"
CATALOG = {"status": "success",
           "vault": {"vault_id": "fixture", "root": "/fixture", "authority_fields": {"root": "fixture"}},
           "catalog": {"book_count": 1, "chapter_count": 1, "anomaly_counts": {}, "manifest_discrepancies": {},
                       "books": [{"book_id": "book_test", "chapters": [
                           {"catalog_id": CID, "file_name": "001_fixture.md", "anomalies": []}]}]}}
SCENE = {"scene_id": "fixture", "metadata": {}, "events": [], "locations": [], "entities": [
    {"id": "alpha", "name": "Alpha", "type": "character", "position": {"x": 0, "y": 0, "z": 0}},
    {"id": "beta", "name": "Beta", "type": "character", "position": [5, 0, 0]},
    {"id": "gamma", "name": "Gamma", "type": "object", "transform": {"position": {"x": 10, "y": 0, "z": 0}}},
    {"id": "alpha", "name": "Alpha again", "type": "character", "position": {"x": 15, "y": 0, "z": 0}},
    {"id": "nowhere", "name": "Nowhere", "type": "character"},
    {"name": "No id", "position": {"x": 20, "y": 0, "z": 0}},
]}
CANDIDATE = (200, {"status": "success", "extraction": "candidate", "catalog_id": CID, "receipt": {},
                   "game_scenes": {"game_scenes/001_fixture.json": SCENE}})
ASSETS_OK = (200, {"status": "success", "asset_pack": {"status": "ok", "asset_pack_id": "fixture_pack", "problems": [],
              "manifest": {"spec_version": "engain.assets_manifest.v1", "asset_pack_id": "fixture_pack",
                           "fallback": {"entity": {"mode": "procedural_capsule"}}, "entities": {}, "types": {}}}})
ASSETS_MISSING = (503, {"status": "error", "asset_pack": {"status": "error", "asset_pack_id": "fixture_pack",
                  "problems": ["asset pack manifest does not exist: /x"], "manifest": None}})

# name: (extraction answer, assets answer, expected actors, expected assets, expected state)
CASES = {
    "candidate_with_pack": (CANDIDATE, ASSETS_OK, 3, "fixture_pack", "candidate"),
    "candidate_without_pack": (CANDIDATE, ASSETS_MISSING, 3, "unavailable", "candidate"),
    "not_extracted_with_pack": ((404, {"status": "error", "extraction": "not_extracted", "catalog_id": CID}),
                                ASSETS_OK, 0, "fixture_pack", "not_extracted"),
    "stale_with_pack": ((409, {"status": "error", "extraction": "stale", "catalog_id": CID, "previous": []}),
                        ASSETS_OK, 0, "fixture_pack", "stale"),
    "receipt_mismatch_without_pack": ((500, {"status": "error", "extraction": "receipt_mismatch", "catalog_id": CID}),
                                      ASSETS_MISSING, 0, "unavailable", "receipt_mismatch"),
}


def serve(extraction, assets):
    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            path = self.path.split("?")[0]
            code, body = {"/chapters/catalog": (200, CATALOG), "/chapters/extraction": extraction,
                          "/assets/active": assets}.get(path, (404, {"status": "error"}))
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *a):
            pass
    srv = HTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def main():
    failures = 0
    for name, (extraction, assets, want_actors, want_assets, want_state) in CASES.items():
        srv = serve(extraction, assets)
        env = dict(os.environ, ENGAIN_TIER1_URL=f"http://127.0.0.1:{srv.server_address[1]}")
        out = subprocess.run(["godot", "--headless", "--path", str(PROJECT), "--", "--selftest",
                              f"--extract-check={CID}"], env=env, capture_output=True, text=True, timeout=60)
        srv.shutdown()
        srv.server_close()
        render = re.search(r"render actors=(\d+) assets=(\S+) ids=(\S*) skipped_missing_position=(\d+)", out.stdout)
        state = re.search(r"state=(\S+)", out.stdout)
        got = (int(render.group(1)), render.group(2), state.group(1)) if render and state else None
        ok = got == (want_actors, want_assets, want_state) and "SCRIPT ERROR" not in out.stderr
        if ok and want_actors:  # duplicate, id-less and position-less entities are dropped, never placed
            ok = render.group(3) == "alpha,beta,gamma" and render.group(4) == "1"
        print(f"{'PASS' if ok else 'FAIL'}  {name}: got {got}, want {(want_actors, want_assets, want_state)}")
        if not ok:
            failures += 1
            print(out.stdout[-2000:], out.stderr[-2000:], sep="\n")
    print(f"{len(CASES) - failures}/{len(CASES)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
