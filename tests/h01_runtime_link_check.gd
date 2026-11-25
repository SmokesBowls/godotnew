extends SceneTree
## H01 probe, driven by tests/h01_runtime_link_check.py (isolated EngAIn services + test policy).
## Uses the real EngAInRuntimeLink and the real scene view's Surfaces container.
## Prints one line: H01_RESULT {"checks": [[name, ok, detail], ...], "final_load": {...}, ...}

const Link := preload("res://scripts/EngAInRuntimeLink.gd")
const SceneView := preload("res://scene_view.gd")

var _checks: Array = []
var _link: Node
var _view: Node
var _control := OS.get_environment("H01_CONTROL_URL")
var _catalog_id := OS.get_environment("H01_CATALOG_ID")


func _initialize() -> void:
	_run.call_deferred()


func _check(name: String, ok: bool, detail: Variant = null) -> void:
	_checks.append([name, ok, detail])


func _run() -> void:
	_view = SceneView.new()
	root.add_child(_view)
	_link = Link.new()
	root.add_child(_link)
	_link.set_surface_container(_view.surface_container())
	var surfaces: Node3D = _view.surface_container()
	var configured: Dictionary = _link.is_configured()
	_check("credentials_from_launch_environment", configured.values().all(func(v): return v), configured)

	# 1. Live catalog and the chosen chapter (Book -> Chapter).
	var catalog: Dictionary = await _http_get(_link.tier1_url + "/chapters/catalog")
	var found := false
	for book in (catalog.body.get("catalog", {}) as Dictionary).get("books", []):
		for chapter in book.get("chapters", []):
			found = found or chapter.get("catalog_id") == _catalog_id
	_check("live_catalog_lists_selected_chapter", catalog.code == 200 and found, {"code": catalog.code})

	# 2. Candidate inspection is display-only: the runtime is untouched.
	var inspection: Dictionary = await _http_get(_link.tier1_url + "/chapters/extraction?catalog_id=" + _catalog_id.uri_encode())
	_check("candidate_resolved_from_mettaext", inspection.code == 200 and inspection.body.get("extraction") == "candidate",
		{"code": inspection.code, "extraction": inspection.body.get("extraction")})
	var before: Dictionary = await _link.peek()
	_check("inspection_does_not_mutate_runtime", before.code == 200 and _stamp(before) == null, _stamp(before))

	# 3. Unauthenticated activation is refused and changes nothing.
	var unsigned: Dictionary = await _post(_link.runtime_url + "/scene/activate",
		JSON.stringify({"scene": {"scene_id": "scene.h01_forged", "segments": []}, "expected_scene_activation": null}),
		PackedStringArray(["Content-Type: application/json"]))
	_check("unauthenticated_activation_refused", unsigned.code == 401, unsigned)
	_check("refusal_left_runtime_empty", _stamp(await _link.peek()) == null)

	# 4. Signed activation of the real candidate.
	var activated: Dictionary = await _link.activate_candidate(_catalog_id)
	var stamp: Variant = Link.normalize_load(activated.body.get("scene_activation")) if activated.body is Dictionary else null
	_check("authorized_activation_succeeds", activated.code == 200 and stamp is Dictionary, activated)
	if not stamp is Dictionary:
		return _finish()
	var after: Dictionary = await _link.peek()
	var payload: Dictionary = after.body.get("payload", {})
	_check("active_scene_identity_confirmed", _stamp(after) == stamp and payload.get("scene_id") == stamp["scene_id"]
		and (payload.get("scene", {}) as Dictionary).get("scene_id") == stamp["scene_id"], {"peek": _stamp(after), "stamp": stamp})
	_check("godot_presents_the_activated_load", _link.presented_load() == stamp, _link.presented_load())

	# 5. Build (authorized build caller) -> consume -> apply.
	var built: Dictionary = await _build("slot-h01-a")
	_check("trixel_surface_build_completes", built.get("code") == 200, built)
	var report: Dictionary = await _link.apply_authorization(built) if built.get("code") == 200 else {}
	_check("godot_consumes_delivered_surface", report.get("result") == "APPLIED", report)
	var meshes := surfaces.get_children().filter(func(n): return n is MeshInstance3D)
	_check("one_surface_node_attached", meshes.size() == 1, surfaces.get_child_count())
	if meshes.size() == 1:
		var node: MeshInstance3D = meshes[0]
		var arrays: Array = node.mesh.surface_get_arrays(0) if node.mesh != null and node.mesh.get_surface_count() > 0 else []
		var vcount: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() if not arrays.is_empty() else -1
		var icount: int = (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() if not arrays.is_empty() and arrays[Mesh.ARRAY_INDEX] != null else -1
		_check("geometry_counts_match_packet", vcount == built["vertex_count"] and icount == built["index_count"],
			{"vertices": [vcount, built["vertex_count"]], "indices": [icount, built["index_count"]]})
		var p: Dictionary = built["placement"]
		var expected := Transform3D(Basis(_v(p["basis_columns"][0]), _v(p["basis_columns"][1]), _v(p["basis_columns"][2])), _v(p["origin"]))
		_check("declared_transform_applied", node.transform.is_equal_approx(expected), [str(node.transform), str(expected)])
		var physics := node.find_children("*", "CollisionObject3D", true, false) + node.find_children("*", "CollisionShape3D", true, false)
		_check("collision_denial_honored", physics.is_empty() and report.get("collision", {}).get("mode", "denied") in ["denied", "DENIED", "NONE"], report.get("collision"))
	_check("presentation_receipt_produced", report.get("runtime_application_completed") == true, report)

	# 6. Stale surface: authorized for this load, presented after a re-activation -> refused.
	var stale: Dictionary = await _build("slot-h01-b")
	var scene_doc: Dictionary = (await _http_get(_link.tier1_url + "/load_scene?catalog_id=" + _catalog_id.uri_encode())).body.get("data", {})
	var replaced: Dictionary = await _link.activate_scene(scene_doc, _link.presented_load())  # same scene, current stamp -> new load
	_check("same_scene_reload_with_stamp_is_a_new_load", replaced.code == 200
		and int(replaced.body["scene_activation"]["load_seq"]) == int(stamp["load_seq"]) + 1, replaced)
	_check("old_surface_released_with_its_load", surfaces.get_children().filter(func(n): return n is MeshInstance3D).is_empty(),
		surfaces.get_child_count())
	var stale_report: Dictionary = await _link.apply_authorization(stale) if stale.get("code") == 200 else {}
	_check("stale_surface_consumption_refused", stale.get("code") == 200 and stale_report.get("result") != "APPLIED", {"build": stale, "report": stale_report})
	_check("nothing_attached_after_refusal", surfaces.get_children().filter(func(n): return n is MeshInstance3D).is_empty())
	var old_stamp: Dictionary = await _link.activate_scene(scene_doc, stamp)
	_check("stale_activation_rejected", old_stamp.code == 409, old_stamp)
	_finish(report)


func _finish(receipt: Variant = null) -> void:
	print("H01_RESULT " + JSON.stringify({"checks": _checks, "final_load": _link.presented_load(),
		"presentation_receipt": receipt}))
	quit(0)


func _stamp(peeked: Dictionary) -> Variant:
	return Link.normalize_load(((peeked.body as Dictionary).get("payload", {}) as Dictionary).get("scene_activation")) if peeked.body is Dictionary else null


func _v(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])


func _build(slot: String) -> Dictionary:
	return (await _post(_control + "/test/build", JSON.stringify({"application_slot_id": slot}),
		PackedStringArray(["Content-Type: application/json"]))).body


func _http_get(url: String) -> Dictionary:
	return await _post(url, "", PackedStringArray(), HTTPClient.METHOD_GET)


func _post(url: String, body: String, headers: PackedStringArray, method := HTTPClient.METHOD_POST) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = 300.0
	root.add_child(http)
	if http.request(url, headers, method, body) != OK:
		http.queue_free()
		return {"code": -1, "body": {}}
	var r: Array = await http.request_completed
	http.queue_free()
	var parsed: Variant = JSON.parse_string((r[3] as PackedByteArray).get_string_from_utf8())
	return {"code": r[1], "body": parsed if parsed is Dictionary else {}}
