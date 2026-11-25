#!/usr/bin/env python3
"""H01: godotnew's EngAInRuntimeLink against real EngAIn handlers, end to end.

Runs EngAIn's own 8080 runtime handler (signed /scene/activate + /presentation/observation)
and 8765 scene server (catalog, catalog candidate delivery, live Trixel route) in this
process on ephemeral ports, all state in a temp dir. Godot (headless) then drives
tests/h01_runtime_link_check.gd: catalog -> candidate inspection -> signed activation ->
observation -> consume -> apply_live, plus refusals.

ISOLATED TEST POLICY, NOT PRODUCTION:
  - client policies below are disposable (production policies are deny-all);
  - the builder's actor/tier exists only in this test policy;
  - scene target declarations are written by this harness for the activated scene;
  - the surface is built from a declared TEST_ONLY measurement basis and test elevation grid
    (production metric basis and real elevation are BLOCKED upstream: OP_C, OP_D).
The catalog and candidate are real (the configured vault and Stageroom, read-only).

Usage: python3 tests/h01_runtime_link_check.py [catalog_id]
(needs `godot` on PATH and ENGAIN_ROOT, default ~/Desktop/burdens_of_a_forgotten_past/EngAIn; exit 0 = pass)
"""
import json
import os
import subprocess
import sys
import tempfile
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
ENGAIN = Path(os.environ.get("ENGAIN_ROOT", Path.home() / "Desktop/burdens_of_a_forgotten_past/EngAIn"))
sys.path.insert(0, str(ENGAIN))
os.environ.setdefault("PYTHONDONTWRITEBYTECODE", "1")
sys.dont_write_bytecode = True

import tier1.engainos.bridgeroom.trixel32d_live_route as route  # noqa: E402
from tier1.engainos.authority.local_signed_transport import signed_headers  # noqa: E402
from tier1.engainos.authority.trixel32d_live_authority_state import scene_revision_of  # noqa: E402
from tier1.engainos.bridgeroom import scene_server  # noqa: E402
from tier1.engainos.tests.test_trixel32d_bound_assembly import TEST_BASIS, contributions  # noqa: E402
from tier2.godotsim import presentation_observation as po  # noqa: E402
from tier2.godotsim import scene_activation_intake as sai  # noqa: E402
from tier2.godotsim import sim_runtime  # noqa: E402
from tier2.godotsim.http_handlers import RuntimeHTTPHandler  # noqa: E402
from tier2.godotsim.runtime_core import EngAInRuntime  # noqa: E402

BUILDER, PRESENTER, ACTIVATOR = "h01-test-builder", "h01-test-presenter", "h01-test-activator"
PARENT = ["RUNTIME_CONTAINER", "chapter-selector-surfaces"]  # EngAInRuntimeLink.SURFACE_PARENT
SLOTS = ["slot-h01-a", "slot-h01-b", "slot-h01-c"]
# A proper rotation (90 degrees about +Y) and an offset: the applied node must carry exactly this.
PLACEMENT = {"origin": [1.5, 0.0, -2.0], "basis_columns": [[0.0, 0.0, -1.0], [0.0, 1.0, 0.0], [1.0, 0.0, 0.0]]}


def serve(server):
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_address[1]}"


def http_json(url, data=None, headers=None):
    req = urllib.request.Request(url, data=data, method="POST" if data is not None else "GET",
                                 headers={"Content-Type": "application/json", **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as err:
        return err.code, json.loads(err.read() or b"{}")


class Services:
    def __init__(self, tmp: Path):
        self.tmp, self.lock = tmp, threading.Lock()
        self.transport = tmp / "transport"
        self.live_policy = tmp / "live_policy.json"
        self.live_policy.write_text(json.dumps({"contract": "engainos.local_client_policy.v1", "clients": {
            BUILDER: {"actor_id": "h01-isolated-test-builder", "actor_authority_tier": 2, "routes": ["build"]},
            PRESENTER: {"routes": ["consume", "observe"]}}}))
        self.activation_policy = tmp / "activation_policy.json"
        self.activation_policy.write_text(json.dumps({"contract": "engainos.local_client_policy.v1",
                                                      "clients": {ACTIVATOR: {"routes": ["activate"]}}}))
        route.RUNTIME_DIR = tmp / "runtime"
        route.SCENE_TRUTH_DIR = tmp / "scene_truth"
        os.environ[route.FLAG_ENV] = "1"
        os.environ[sai.FLAG_ENV] = "1"

        self.runtime = EngAInRuntime()
        RuntimeHTTPHandler.runtime = self.runtime
        sim_runtime._install_live_edit_shims(RuntimeHTTPHandler, self.runtime)
        RuntimeHTTPHandler.presentation_intake, why = po.compose_from_environment(
            policy_path=self.live_policy, transport_dir=self.transport)
        assert RuntimeHTTPHandler.presentation_intake is not None, why
        RuntimeHTTPHandler.activation_intake, why = sai.compose_from_environment(
            policy_path=self.activation_policy, transport_dir=self.transport)
        assert RuntimeHTTPHandler.activation_intake is not None, why
        self.url_8080 = serve(ThreadingHTTPServer(("127.0.0.1", 0), RuntimeHTTPHandler))
        os.environ[route.RUNTIME_URL_ENV] = self.url_8080

        self.authority, why = route.compose_from_environment(
            ledger_path=tmp / "runtime" / "ledger.jsonl", policy_path=self.live_policy, transport_dir=self.transport)
        assert self.authority is not None, why
        scene_server.SceneRequestHandler.trixel32d_authority = self.authority
        self.url_8765 = serve(ThreadingHTTPServer(("127.0.0.1", 0), scene_server.SceneRequestHandler))
        self.url_control = serve(ThreadingHTTPServer(("127.0.0.1", 0), control_handler(self)))
        self.payloads = {}

    def key(self, server, client):
        return self.transport / server / f"{client}.key"

    def build(self, slot_id):
        """Stands in for the authorized build caller: declare targets, contribute, sign, build."""
        stamp = self.runtime.scene_manager.current_activation()
        scene = self.runtime.get_snapshot()["payload"]["scene"]  # what the route reads via peek
        route.SCENE_TRUTH_DIR.mkdir(exist_ok=True)
        (route.SCENE_TRUTH_DIR / f"{stamp['scene_id']}.json").write_text(json.dumps({
            "contract": route.SCENE_TRUTH_CONTRACT, "scene_id": stamp["scene_id"],
            "scene_revision": scene_revision_of(scene),
            "declared_targets": [[*PARENT, s] for s in SLOTS], "slot_occupancy": {}}))
        grid, grant, provenance, policy = contributions(basis=dict(TEST_BASIS, scene_id=stamp["scene_id"]))
        # One request per slot (identical requests share a drop slot and a duplicate dispatch is refused).
        provenance = dict(provenance, topology_artifact_id=f"topology.h01.{slot_id}")
        body = json.dumps({
            "placement": {"mode": "scene_bound", "parent_kind": PARENT[0], "parent_id": PARENT[1],
                          "application_slot_id": slot_id, **PLACEMENT, "visibility": "VISIBLE"},
            "collision": {"mode": "denied"},
            "surface": {"grid_facts": grid, "metric_grant": grant, "provenance": provenance,
                        "construction_policy": policy},
        }).encode()
        secret = bytes.fromhex(self.key(route.SERVER_NAME, BUILDER).read_text())
        code, result = http_json(self.url_8765 + route.ROUTE_PATH, body,
                                 signed_headers(BUILDER, secret, "POST", route.ROUTE_PATH, body))
        out = {"code": code, "errors": result.get("errors")}
        if code == 200:
            entry = result["ledger_entry"]
            payload_path = self.tmp / result["built_drop_dir"] / route.PAYLOAD_FILENAME
            geometry = json.loads(payload_path.read_text())["geometry"]
            out.update(decision_id=entry["decision_id"], apply_id=entry["apply_id"],
                       artifact_sha256=entry["artifact_sha256"],
                       authorization_path=str(self.tmp / result["authorization_file"]),
                       payload_path=str(payload_path), scene_id=stamp["scene_id"],
                       vertex_count=len(geometry["positions"]), index_count=len(geometry["indices"]),
                       placement=PLACEMENT)
        return out


def control_handler(services):
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
            with services.lock:
                result = services.build(body["application_slot_id"]) if self.path == "/test/build" \
                    else {"error": "not found"}
            raw = json.dumps(result).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def log_message(self, *args):
            pass
    return Handler


def pick_catalog_id(services, wanted):
    code, data = http_json(services.url_8765 + "/chapters/catalog")
    assert code == 200, (code, data)
    ids = [c["catalog_id"] for b in data["catalog"]["books"] for c in b["chapters"]]
    for cid in ([wanted] if wanted else ids):
        if http_json(services.url_8765 + "/load_scene?catalog_id=" + urllib.request.quote(cid))[0] == 200:
            return cid, data["vault"].get("vault_id"), len(ids)
    raise SystemExit(f"no catalog chapter with a current, deliverable extraction (wanted={wanted!r})")


def main():
    failures = []
    with tempfile.TemporaryDirectory(prefix="h01_") as tmp:
        services = Services(Path(tmp))
        catalog_id, vault_id, chapters = pick_catalog_id(services, sys.argv[1] if len(sys.argv) > 1 else None)
        print(f"vault={vault_id} chapters={chapters} catalog_id={catalog_id}")
        env = dict(os.environ,
                   ENGAIN_TIER1_URL=services.url_8765, ENGAIN_RUNTIME_URL=services.url_8080,
                   H01_CONTROL_URL=services.url_control, H01_CATALOG_ID=catalog_id,
                   ENGAIN_ACTIVATOR_CLIENT_ID=ACTIVATOR,
                   ENGAIN_ACTIVATOR_KEY_FILE=str(services.key(sai.SERVER_NAME, ACTIVATOR)),
                   ENGAIN_OBSERVER_CLIENT_ID=PRESENTER,
                   ENGAIN_OBSERVER_KEY_FILE=str(services.key(po.SERVER_NAME, PRESENTER)),
                   ENGAIN_EXECUTOR_CLIENT_ID=PRESENTER,
                   ENGAIN_EXECUTOR_KEY_FILE=str(services.key(route.SERVER_NAME, PRESENTER)),
                   ENGAIN_TRIXEL32D_GRANT_PUBLIC_KEY_FILE=str(
                       services.transport / route.SERVER_NAME / route.GRANT_PUBLIC_KEY_FILENAME))
        out = subprocess.run(["godot", "--headless", "--path", str(PROJECT), "--script",
                              "res://tests/h01_runtime_link_check.gd"],
                             env=env, capture_output=True, text=True, timeout=600)
        line = next((l for l in out.stdout.splitlines() if l.startswith("H01_RESULT ")), None)
        if line is None:
            print(out.stdout[-4000:], out.stderr[-4000:])
            raise SystemExit(f"godot probe produced no result (exit {out.returncode})")
        result = json.loads(line[len("H01_RESULT "):])
        for name, ok, detail in result["checks"]:
            print(("PASS " if ok else "FAIL ") + name + ("" if ok else f"  {json.dumps(detail)[:600]}"))
            if not ok:
                failures.append(name)
        # Server-side confirmation: the runtime presents exactly what Godot activated last.
        final = services.runtime.scene_manager.current_activation()
        ok = final == result.get("final_load")
        print(("PASS " if ok else "FAIL ") + "runtime_and_godot_agree_on_final_load")
        failures += [] if ok else ["runtime_and_godot_agree_on_final_load"]
        receipt = result.get("presentation_receipt")
        print("presentation_receipt: " + json.dumps(receipt, sort_keys=True)[:800])
        services.authority.close()
    print(f"H01 {'PASS' if not failures else 'FAIL'} ({len(failures)} failed)")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
