#!/usr/bin/env python3
"""H03: operator-triggered PROVISIONAL reference stage, built by real Trixel, shown in godotnew.

Starts the isolated EngAIn services from H01 (real 8080 runtime handler, real 8765 scene server
with the live Trixel route; temp state, disposable client policy) and launches the godotnew
project with credentials in its environment. Nothing runs until the operator:
  1. selects a chapter with a candidate, 2. presses "Activate in runtime (DRAFT)",
  3. presses "Construct reference stage (PROVISIONAL TEST)".
Step 3 asks this process's build caller (holder of the test `build` binding) to:
  WorldField  field_from_elevation_grid: 20 x 20 cells, flat elevation 0.5 (grass -> default.generic)
  Cartographer solve_terrain_metrics: 100 x 100 m, 2 m vertical, basis_status "provisional",
               allow_provisional=True (explicit, this harness only)
  EngAInOS    signed /trixel32d/build on an authority composed with allow_provisional_metrics=True
  Trixel3.2D  real consumer subprocess
then Godot consumes the one-time grant and applies through apply_live, and posts its report back.
All measurements and terrain here are PROVISIONAL TEST INPUTS, not manuscript evidence.

Usage:
  python3 tests/h03_reference_stage.py [--receipts DIR] [--catalog-id ID]          operator mode (window)
  python3 tests/h03_reference_stage.py --selftest --screenshot PNG [--receipts DIR] automated, saves a screenshot
"""
import argparse
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("h01", HERE / "h01_runtime_link_check.py")
h01 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h01)  # EngAIn imports + Services (no side effects at import)

from tier1.engainos.authority.local_signed_transport import signed_headers  # noqa: E402
from tier1.engainos.authority.trixel32d_live_authority_state import scene_revision_of  # noqa: E402
from tier1.engainos.bridgeroom import scene_server  # noqa: E402
from tier1.engainos.tests.test_trixel32d_bound_assembly import POLICY  # noqa: E402
from tier2.cartographer.layoutroom.terrain_metric_solver import solve_terrain_metrics  # noqa: E402
from tier2.cartographer.reckoningroom.terrain_metric_validator import validate_terrain_metric_grant  # noqa: E402
from tier2.worldfield.grid_facts_emitter import emit_grid_facts  # noqa: E402
from tier2.worldfield.trixel_world_adapter import field_from_elevation_grid  # noqa: E402

route = h01.route
GRID_CELLS = 20
FLAT_ELEVATION = 0.5
STAGE_SLOT = "slot-h03-reference-stage"
STAGE_BASIS = {
    "basis_id": "H03_PROVISIONAL_REFERENCE_STAGE",
    "source": "H03 operator-approved provisional construction reference stage (2026-11-25); "
              "test input, not manuscript evidence",
    "basis_status": "provisional",
    "physical_width_m": 100.0, "physical_depth_m": 100.0, "vertical_extent_m": 2,
}
# Flat top at round(0.5 * 2) = 1 m; lower the node 1 m so the stage top is the y = 0 ground plane.
PLACEMENT = {"origin": [0.0, -1.0, 0.0], "basis_columns": [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]}


class StageServices(h01.Services):
    def __init__(self, tmp: Path, receipts: Path):
        super().__init__(tmp)
        self.receipts = receipts
        self.authority.close()  # recompose: the only difference is the explicit provisional allowance
        self.authority, why = route.compose_from_environment(
            ledger_path=tmp / "runtime" / "ledger.jsonl", policy_path=self.live_policy,
            transport_dir=self.transport, allow_provisional_metrics=True)
        assert self.authority is not None, why
        scene_server.SceneRequestHandler.trixel32d_authority = self.authority
        self.url_control = h01.serve(ThreadingHTTPServer(("127.0.0.1", 0), stage_handler(self)))
        self.consumed = None

    def write(self, name, payload):
        (self.receipts / name).write_text(json.dumps(payload, indent=2, sort_keys=True))

    def build_stage(self, scene_activation):
        stamp = self.runtime.scene_manager.current_activation()
        if not stamp or scene_activation != stamp:
            return {"code": 409, "errors": ["requested load is not the runtime's current activation"]}
        # WorldField: the numerical field and its facts.
        field, _, adapter = field_from_elevation_grid([[FLAT_ELEVATION] * GRID_CELLS for _ in range(GRID_CELLS)], "coastal_beach")
        grid = emit_grid_facts(field, adapter)
        self.write("worldfield_grid_receipt.json", {
            "receipt": "H03 WorldField grid facts (PROVISIONAL TEST INPUT)", "function": "field_from_elevation_grid + emit_grid_facts",
            "grid_facts_sha256": hashlib.sha256(json.dumps(grid, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
            "width": grid["width"], "height": grid["height"], "profile": grid["profile"], "cell_count": len(grid["cells"]),
            "elevation_range": [min(c["elevation"] for c in grid["cells"]), max(c["elevation"] for c in grid["cells"])],
            "terrains": sorted({c["terrain"] for c in grid["cells"]}), "recipes": sorted({str(c["recipe"]) for c in grid["cells"]}),
            "unmapped_terrains": grid["unmapped_terrains"], "fully_mapped": grid["fully_mapped"]})
        # Cartographer: provisional measurements, explicitly allowed here only.
        basis = dict(STAGE_BASIS, scene_id=stamp["scene_id"])
        solved = solve_terrain_metrics(grid, basis, allow_provisional=True)
        if solved["status"] != "GRANTED":
            self.write("cartographer_measurement_receipt.json", solved)
            return {"code": 409, "errors": ["Cartographer: " + "; ".join(solved["missing"])]}
        grant = solved["grant"]
        self.write("cartographer_measurement_receipt.json", {
            "receipt": "H03 Cartographer terrain metric grant (PROVISIONAL)", "function": "solve_terrain_metrics(allow_provisional=True)",
            "grant": grant, "validation": validate_terrain_metric_grant(grant, grid)})
        # EngAInOS: authority-owned declarations for this exact scene revision, then a signed build.
        scene = self.runtime.get_snapshot()["payload"]["scene"]
        route.SCENE_TRUTH_DIR.mkdir(exist_ok=True)
        (route.SCENE_TRUTH_DIR / f"{stamp['scene_id']}.json").write_text(json.dumps({
            "contract": route.SCENE_TRUTH_CONTRACT, "scene_id": stamp["scene_id"], "scene_revision": scene_revision_of(scene),
            "declared_targets": [[*h01.PARENT, STAGE_SLOT]], "slot_occupancy": {}}))
        body = json.dumps({
            "placement": {"mode": "scene_bound", "parent_kind": h01.PARENT[0], "parent_id": h01.PARENT[1],
                          "application_slot_id": STAGE_SLOT, **PLACEMENT, "visibility": "VISIBLE"},
            "collision": {"mode": "denied"},
            "surface": {"grid_facts": grid, "metric_grant": grant, "construction_policy": POLICY,
                        "provenance": {"source_scene_id": stamp["scene_id"],
                                       "topology_artifact_id": f"h03.provisional_reference_stage.load{stamp['load_seq']}",
                                       "metric_layout_artifact_id": grant["source_artifact_id"]}},
        }).encode()
        secret = bytes.fromhex(self.key(route.SERVER_NAME, h01.BUILDER).read_text())
        code, result = h01.http_json(self.url_8765 + route.ROUTE_PATH, body,
                                     signed_headers(h01.BUILDER, secret, "POST", route.ROUTE_PATH, body))
        self.write("engainos_dispatch_receipt.json", {"receipt": "H03 EngAInOS /trixel32d/build", "http": code, "response": result})
        if code != 200:
            return {"code": code, "errors": result.get("errors")}
        slot = Path(result["built_drop_dir"]).name
        trixel = {"intake_receipt": json.loads((route.RUNTIME_DIR / "trixel32d_reports" / slot / route.RECEIPT_FILENAME).read_text()),
                  "built_drop_envelope": json.loads((self.tmp / result["built_drop_dir"] / "TRIXEL32D_SURFACE_BUILT_DROP_V1.json").read_text())}
        payload_path = self.tmp / result["built_drop_dir"] / route.PAYLOAD_FILENAME
        geometry = json.loads(payload_path.read_text())["geometry"]
        trixel["geometry_counts"] = {"positions": len(geometry["positions"]), "indices": len(geometry["indices"])}
        self.write("trixel_construction_receipt.json", trixel)
        entry = result["ledger_entry"]
        return {"code": 200, "decision_id": entry["decision_id"], "apply_id": entry["apply_id"],
                "artifact_sha256": entry["artifact_sha256"], "authorization_path": str(self.tmp / result["authorization_file"]),
                "payload_path": str(payload_path)}


def stage_handler(services):
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
            with services.lock:
                if self.path == "/h03/build":
                    result = services.build_stage(body.get("scene_activation"))
                elif self.path == "/h03/consumed":
                    services.consumed = body
                    services.write("godot_consumption_receipt.json", body)
                    result = {"recorded": True}
                else:
                    result = {"error": "not found"}
            raw = json.dumps(result).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def log_message(self, *args):
            pass
    return Handler


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--receipts", type=Path, default=None)
    ap.add_argument("--catalog-id", default=None)
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--screenshot", type=Path, default=None)
    args = ap.parse_args()
    with tempfile.TemporaryDirectory(prefix="h03_") as tmp:
        receipts = args.receipts or Path(tmp) / "receipts"
        receipts.mkdir(parents=True, exist_ok=True)
        services = StageServices(Path(tmp), receipts)
        catalog_id, vault_id, _ = h01.pick_catalog_id(services, args.catalog_id)
        env = dict(os.environ, ENGAIN_TIER1_URL=services.url_8765, ENGAIN_RUNTIME_URL=services.url_8080,
                   ENGAIN_H03_BUILD_CALLER_URL=services.url_control,
                   ENGAIN_ACTIVATOR_CLIENT_ID=h01.ACTIVATOR,
                   ENGAIN_ACTIVATOR_KEY_FILE=str(services.key(h01.sai.SERVER_NAME, h01.ACTIVATOR)),
                   ENGAIN_OBSERVER_CLIENT_ID=h01.PRESENTER,
                   ENGAIN_OBSERVER_KEY_FILE=str(services.key(h01.po.SERVER_NAME, h01.PRESENTER)),
                   ENGAIN_EXECUTOR_CLIENT_ID=h01.PRESENTER,
                   ENGAIN_EXECUTOR_KEY_FILE=str(services.key(route.SERVER_NAME, h01.PRESENTER)),
                   ENGAIN_TRIXEL32D_GRANT_PUBLIC_KEY_FILE=str(services.transport / route.SERVER_NAME / route.GRANT_PUBLIC_KEY_FILENAME))
        cmd = ["godot", "--path", str(h01.PROJECT)]
        if args.selftest:
            cmd += ["--", "--selftest", f"--extract-check={catalog_id}", "--h03-construct"]
            if args.screenshot:
                cmd.append(f"--screenshot={args.screenshot}")
        print(f"vault={vault_id} catalog_id={catalog_id} receipts={receipts}")
        print("Operator: select that chapter (or any with a candidate), press Activate, then Construct reference stage."
              if not args.selftest else "selftest running ...", flush=True)
        out = subprocess.run(cmd, env=env, capture_output=args.selftest, text=True, timeout=None if not args.selftest else 900)
        if args.selftest:
            for line in out.stdout.splitlines():
                if line.startswith("[selftest]"):
                    print("  " + line)
        names = ["worldfield_grid_receipt.json", "cartographer_measurement_receipt.json", "engainos_dispatch_receipt.json",
                 "trixel_construction_receipt.json", "godot_consumption_receipt.json"]
        present = {n: (receipts / n).is_file() for n in names}
        print("receipts: " + json.dumps(present))
        applied = (services.consumed or {}).get("result") == "APPLIED"
        print(f"H03 {'APPLIED' if applied else 'NOT APPLIED'}")
        services.authority.close()
        return 0 if applied and all(present.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
