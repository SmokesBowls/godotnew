extends Node
## H01: godotnew's link to the EngAIn runtime (8080) and authority (8765).
##
## Godot requests and presents; EngAIn decides. This node:
##  - activates a chosen candidate as a DRAFT runtime scene (signed POST 8080 /scene/activate,
##    carrying the stamp it last observed — T03-R3; never an actor, tier or reality mode);
##  - reports what it is presenting (signed POST 8080 /presentation/observation);
##  - consumes an authorization at 8765 for a one-time grant (signed POST /trixel32d/consume)
##    and applies the built surface only through the donor's apply_live executor
##    (grant-verified, current-load re-checked, collision DENIED).
## Selecting or inspecting a candidate never calls this node; activation is an explicit request.
##
## Credentials come only from the launch environment (key files EngAIn mints at its start):
##   ENGAIN_ACTIVATOR_CLIENT_ID / ENGAIN_ACTIVATOR_KEY_FILE    8080 `activate` binding
##   ENGAIN_OBSERVER_CLIENT_ID  / ENGAIN_OBSERVER_KEY_FILE     8080 `observe` binding
##   ENGAIN_EXECUTOR_CLIENT_ID  / ENGAIN_EXECUTOR_KEY_FILE     8765 `consume` binding
##   ENGAIN_TRIXEL32D_GRANT_PUBLIC_KEY_FILE                   8765 grant verification key
## Nothing is written to the project or logged.

signal presentation_changed(load: Dictionary)

const SignedRequest := preload("res://scripts/EngAInSignedRequest.gd")
const LiveExecutor := preload("res://trixel_proof/trixel32d_apply_executor/godot/trixel32d_live_apply_executor.gd")
const ACTIVATE_PATH := "/scene/activate"
const OBSERVATION_PATH := "/presentation/observation"
const CONSUME_PATH := "/trixel32d/consume"
const PEEK_PATH := "/snapshot/peek"
## The node this project presents applied surfaces under. A presentation fact, not an authority:
## EngAIn's scene declarations decide whether a slot under it may be used at all.
const SURFACE_PARENT := ["RUNTIME_CONTAINER", "chapter-selector-surfaces"]

var tier1_url: String = OS.get_environment("ENGAIN_TIER1_URL") if OS.has_environment("ENGAIN_TIER1_URL") else "http://127.0.0.1:8765"
var runtime_url: String = OS.get_environment("ENGAIN_RUNTIME_URL") if OS.has_environment("ENGAIN_RUNTIME_URL") else "http://127.0.0.1:8080"

var _activator := SignedRequest.load_credential("ENGAIN_ACTIVATOR_CLIENT_ID", "ENGAIN_ACTIVATOR_KEY_FILE")
var _observer := SignedRequest.load_credential("ENGAIN_OBSERVER_CLIENT_ID", "ENGAIN_OBSERVER_KEY_FILE")
var _executor_credential := SignedRequest.load_credential("ENGAIN_EXECUTOR_CLIENT_ID", "ENGAIN_EXECUTOR_KEY_FILE")
var _executor = null
var _presented_load: Dictionary = {}  # the runtime load this node is presenting now ({} = none)
var _generation := 0
var _report_seq := 0
var _parents: Dictionary = {}


## The container applied surfaces attach under (registered with the executor's parent map).
## A runtime stamp as EngAIn issues it: {runtime_instance_id: String, load_seq: int, scene_id: String}.
## Godot's JSON parser yields floats; EngAIn refuses a non-integer load_seq, so normalize. null stays null.
static func normalize_load(stamp: Variant) -> Variant:
	if not stamp is Dictionary:
		return null
	var seq: Variant = stamp.get("load_seq")
	if not (seq is int or (seq is float and seq == floorf(seq))):
		return stamp  # malformed: pass through unchanged so EngAIn refuses it visibly
	return {"runtime_instance_id": str(stamp.get("runtime_instance_id")), "load_seq": int(seq),
		"scene_id": str(stamp.get("scene_id"))}


func set_surface_container(node: Node3D) -> void:
	_parents["%s|%s" % SURFACE_PARENT] = node


## The node authorized Trixel surfaces currently attach under (null before registration).
func surface_container() -> Node3D:
	return _parents.get("%s|%s" % SURFACE_PARENT)


func presented_load() -> Dictionary:
	return _presented_load.duplicate(true)


func is_configured() -> Dictionary:
	return {"activate": not _activator.is_empty(), "observe": not _observer.is_empty(),
		"consume": not _executor_credential.is_empty(), "grant_key": _executor_or_null() != null}


## GET 8080 /snapshot/peek (non-consuming). Returns {code, body}.
func peek() -> Dictionary:
	return await _request(runtime_url + PEEK_PATH, PackedStringArray(), HTTPClient.METHOD_GET, "")


## Candidate (8765 /load_scene?catalog_id=) -> signed activation against the stamp 8080 shows now.
## Returns {code, body}; on 200 the new load is presented and reported.
func activate_candidate(catalog_id: String) -> Dictionary:
	if _activator.is_empty():
		return {"code": -1, "body": {"errors": ["activator credential is not configured"]}}
	var candidate := await _request("%s/load_scene?catalog_id=%s" % [tier1_url, catalog_id.uri_encode()],
		PackedStringArray(), HTTPClient.METHOD_GET, "")
	if candidate.code != 200 or not candidate.body is Dictionary or not candidate.body.get("data") is Dictionary:
		return {"code": candidate.code, "body": {"errors": ["candidate not delivered by 8765"], "detail": candidate.body}}
	var observed := await peek()
	var payload: Variant = (observed.body as Dictionary).get("payload", {}) if observed.body is Dictionary else {}
	var expected: Variant = (payload as Dictionary).get("scene_activation") if payload is Dictionary else null
	return await activate_scene(candidate.body["data"], expected)


## Signed activation of an explicit scene document with the stamp the caller observed (or null).
func activate_scene(scene: Dictionary, expected_scene_activation: Variant) -> Dictionary:
	if _activator.is_empty():
		return {"code": -1, "body": {"errors": ["activator credential is not configured"]}}
	var body := JSON.stringify({"scene": scene, "expected_scene_activation": normalize_load(expected_scene_activation)})
	var result := await _request(runtime_url + ACTIVATE_PATH,
		SignedRequest.headers(_activator, "POST", ACTIVATE_PATH, body), HTTPClient.METHOD_POST, body)
	if result.code == 200 and result.body is Dictionary and result.body.get("scene_activation") is Dictionary:
		await present(result.body["scene_activation"])
	return result


## Begin presenting `load` (a runtime stamp). Frees surfaces bound to any other load,
## advances the local generation and reports the testimony. Returns the report {code, body}.
func present(load: Dictionary) -> Dictionary:
	_presented_load = normalize_load(load)
	_generation += 1
	var executor = _executor_or_null()
	if executor != null:
		executor.release_for_load(_presented_load)
	presentation_changed.emit(presented_load())
	return await report_observation()


## Signed testimony of the current presentation (EngAIn retains the latest per client).
func report_observation() -> Dictionary:
	if _observer.is_empty() or _presented_load.is_empty():
		return {"code": -1, "body": {"errors": ["observer credential or presented load missing"]}}
	_report_seq += 1
	var body := JSON.stringify({"observed_load": _presented_load, "main_instance_id": get_instance_id(),
		"local_generation": _generation, "presentation_active": true, "report_seq": _report_seq})
	return await _request(runtime_url + OBSERVATION_PATH,
		SignedRequest.headers(_observer, "POST", OBSERVATION_PATH, body), HTTPClient.METHOD_POST, body)


## authorization: {decision_id, apply_id, artifact_sha256, authorization_path, payload_path}
## as handed over by the authorized build caller. Consumes it for a one-time grant, then applies
## against the load and generation current *after* the await. Returns the executor's report.
func apply_authorization(authorization: Dictionary) -> Dictionary:
	var executor = _executor_or_null()
	if executor == null or _executor_credential.is_empty():
		return _refusal("live executor is not configured (grant key or executor credential missing)")
	if _presented_load.is_empty():
		return _refusal("no runtime load is being presented")
	var testimony := {"observed_load": _presented_load, "main_instance_id": get_instance_id(),
		"local_generation": _generation, "presentation_active": true,
		"decision_id": authorization.get("decision_id"), "apply_id": authorization.get("apply_id"),
		"artifact_sha256": authorization.get("artifact_sha256")}
	var body := JSON.stringify(testimony)
	var consumed := await _request(tier1_url + CONSUME_PATH,
		SignedRequest.headers(_executor_credential, "POST", CONSUME_PATH, body), HTTPClient.METHOD_POST, body)
	if consumed.code != 200 or not consumed.body is Dictionary:
		var errors: Variant = (consumed.body as Dictionary).get("errors") if consumed.body is Dictionary else null
		return _refusal("EngAInOS refused consumption (%s): %s" % [consumed.code, errors])
	var grant: Dictionary = consumed.body
	return executor.apply_live(
		String(authorization.get("authorization_path", "")), String(grant.get("grant_json", "")),
		String(grant.get("grant_signature_b64", "")), String(authorization.get("payload_path", "")),
		_parents, _presented_load, {"main_instance_id": get_instance_id(), "local_generation": _generation})["report"]


func _executor_or_null():
	if _executor == null:
		var key_file := OS.get_environment("ENGAIN_TRIXEL32D_GRANT_PUBLIC_KEY_FILE").strip_edges()
		var executor_id := OS.get_environment("ENGAIN_EXECUTOR_CLIENT_ID").strip_edges()
		if key_file.is_empty() or executor_id.is_empty() or not FileAccess.file_exists(key_file):
			return null
		_executor = LiveExecutor.new(FileAccess.get_file_as_string(key_file), executor_id)
	return _executor


func _refusal(reason: String) -> Dictionary:
	return {"result": "REJECTED", "first_blocking_error": reason, "runtime_application_completed": false}


func _request(url: String, headers: PackedStringArray, method: int, body: String) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = 60.0
	add_child(http)
	var err := http.request(url, headers, method, body)
	if err != OK:
		http.queue_free()
		return {"code": -1, "body": {"errors": ["HTTPRequest start failed: %d" % err]}}
	var result: Array = await http.request_completed
	http.queue_free()
	var parsed: Variant = JSON.parse_string((result[3] as PackedByteArray).get_string_from_utf8())
	return {"code": result[1] if result[0] == HTTPRequest.RESULT_SUCCESS else -1, "body": parsed if parsed != null else {}}
