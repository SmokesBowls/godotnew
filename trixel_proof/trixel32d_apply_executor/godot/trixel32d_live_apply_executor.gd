extends RefCounted

## Live Trixel 3.2d apply executor (`apply_live`).
##
## Separate from the frozen v1 executor (trixel32d_apply_executor.gd), which
## stays unchanged for the July proof fixtures.
##
## Application needs both of these:
##  1. the EngAInOS live authorization artifact
##     (engainos.trixel32d_live_application_authorization.v1), byte for byte as
##     the authority ledger hashed it, unchanged and unadapted;
##  2. a one-time grant (engainos.trixel32d_application_grant.v1) that the 8765
##     authority mints only after it atomically consumes that authorization
##     against the current runtime session, scene activation and Godot
##     observation, and to the consuming executor's client id. Godot holds only
##     the authority's public key, so it can verify a grant but never mint one.
##     A grant is usable only by the executor whose client id it names, and only
##     between issued_at - CLOCK_SKEW_S and expires_at (unix seconds, same host).
##
## apply_live is synchronous: it verifies the grant, re-checks the host's
## *current* accepted load and presentation observation, then materializes and
## attaches the node, all in the same call with no await, so nothing can change
## between the check and the attach. SCENE_BOUND: nodes are freed with their
## scene, and release_for_load() frees any applied node whose load is no longer
## current (for parents that outlive a load).
##
## Rejection creates no node and mutates no scene state. Collision stays
## DENIED/NONE. The quarantined runtime attacher is neither touched nor referenced.

const V1 = preload("res://trixel_proof/trixel32d_apply_executor/godot/trixel32d_apply_executor.gd")
const Consumer = preload("res://trixel_proof/trixel32d_passive/godot/trixel32d_surface_consumer.gd")

const AUTHORIZATION_CONTRACT := "engainos.trixel32d_live_application_authorization.v1"
const AUTHORIZATION_PACKET_TYPE := "trixel32d_live_application_authorization"
const GRANT_CONTRACT := "engainos.trixel32d_application_grant.v1"
const APPLY_CONTRACT := "trixel32d_surface_apply.v1"
const APPLY_PACKET_TYPE := "trixel32d_surface_apply"
const APPLY_GATE_NAME := "gate_trixel32d_surface_apply"
const REPORT_CONTRACT := "godot.trixel32d_live_apply_report.v1"
const NODE_NAME_PREFIX := "Trixel32DLiveApplied_"
const LOAD_META := "trixel32d_scene_bound_load"
const CLOCK_SKEW_S := 5

# Exact key sets: the ledger enforces the artifact's; the issuer fixes the grant's.
const AUTHORIZATION_KEYS := [
	"apply_packet", "authority_evidence", "authorized_intent_sha256", "contract",
	"execution_performed", "gate_result", "packet_type", "renderer_contacted",
	"scene_activation", "semantic_activation",
]
const GRANT_KEYS := [
	"activation_id", "apply_id", "artifact_sha256", "client_id", "contract", "decision_id",
	"expires_at", "grant_id", "issued_at", "observed_load", "runtime_session_id", "scene_id",
	"scene_revision", "semantic_local_generation", "semantic_main_instance_id",
]
const LOAD_KEYS := ["load_seq", "runtime_instance_id", "scene_id"]

var _public_key: CryptoKey = null
var _executor_client_id := ""
var _clock: Callable = func() -> float: return Time.get_unix_time_from_system()
var _used_grant_ids := {}
var _applied: Array = []  # [{"node": MeshInstance3D, "load": Dictionary}]


## `grant_public_key_pem`: the 8765 process's grant key, delivered by the launch channel.
## `executor_client_id`: this executor's own transport client id (the `consume` binding).
func _init(grant_public_key_pem: String, executor_client_id: String) -> void:
	var key := CryptoKey.new()
	if key.load_from_string(grant_public_key_pem, true) == OK:
		_public_key = key
	_executor_client_id = executor_client_id


## Replace the authority key after an 8765 restart. Grants signed by the previous
## process stop verifying; nodes already applied stay tracked for release_for_load.
func set_grant_public_key(grant_public_key_pem: String) -> void:
	var key := CryptoKey.new()
	_public_key = key if key.load_from_string(grant_public_key_pem, true) == OK else null


## Test seam only: replace the wall clock used for grant expiry.
func set_clock_for_tests(clock: Callable) -> void:
	_clock = clock


## current_load:        {runtime_instance_id, load_seq, scene_id} of the snapshot the host
##                      last accepted and is presenting right now.
## current_observation: {main_instance_id, local_generation} the host is presenting right now.
func apply_live(
	authorization_path: String,
	grant_json: String,
	grant_signature_b64: String,
	payload_path: String,
	parent_nodes: Dictionary,
	current_load: Dictionary,
	current_observation: Dictionary
) -> Dictionary:
	var context := {
		"grant_id": null, "decision_id": null, "apply_id": null, "surface_id": null,
		"request_id": null, "authorization_sha256": null, "payload_sha256": null,
		"target": null, "load": null,
	}

	# 1. The grant: authority-signed, well-formed, unused.
	if _public_key == null or _executor_client_id.is_empty():
		return _rejected(context, "grant public key or executor identity is unavailable")
	var signature := Marshalls.base64_to_raw(grant_signature_b64)
	var grant_bytes := grant_json.to_utf8_buffer()
	if signature.is_empty() or not Crypto.new().verify(HashingContext.HASH_SHA256, _digest(grant_bytes), signature, _public_key):
		return _rejected(context, "grant signature does not verify under the authority key")
	var grant: Variant = JSON.parse_string(grant_json)
	if not grant is Dictionary or not _has_exact_keys(grant, GRANT_KEYS) or grant["contract"] != GRANT_CONTRACT:
		return _rejected(context, "grant has an invalid shape")
	if not _is_hex(grant["grant_id"], 32):
		return _rejected(context, "grant_id must be 32 lowercase hex")
	context["grant_id"] = grant["grant_id"]
	context["decision_id"] = grant["decision_id"]
	context["apply_id"] = grant["apply_id"]
	if _used_grant_ids.has(grant["grant_id"]):
		return _rejected(context, "grant was already used")
	# Burned on first presentation: no failure below makes a grant reusable.
	_used_grant_ids[grant["grant_id"]] = true

	if grant["client_id"] != _executor_client_id:
		return _rejected(context, "grant was consumed by another executor identity")
	var now: float = _clock.call()
	if not _same_int(grant["issued_at"], grant["issued_at"]) or not _same_int(grant["expires_at"], grant["expires_at"]) \
			or now < float(grant["issued_at"]) - CLOCK_SKEW_S or now > float(grant["expires_at"]):
		return _rejected(context, "grant is outside its validity window")

	# 2. The grant must describe what is being presented right now.
	if not _same_load(grant["observed_load"], current_load):
		return _rejected(context, "current scene load is not the load this grant was consumed under")
	context["load"] = current_load.duplicate(true)
	if grant["observed_load"]["scene_id"] != grant["scene_id"]:
		return _rejected(context, "grant load and activation name different scenes")
	if not _same_int(grant["semantic_main_instance_id"], current_observation.get("main_instance_id")) \
			or not _same_int(grant["semantic_local_generation"], current_observation.get("local_generation")):
		return _rejected(context, "current presentation observation is not the one this grant was consumed under")

	# 3. The authorization artifact: exact bytes the grant names, unchanged live contract.
	var authorization_bytes: PackedByteArray = V1._read_bytes(authorization_path)
	if authorization_bytes.is_empty():
		return _rejected(context, "authorization artifact could not be read")
	var authorization_sha256: String = V1._sha256(authorization_bytes)
	context["authorization_sha256"] = authorization_sha256
	if authorization_sha256 != grant["artifact_sha256"]:
		return _rejected(context, "authorization artifact bytes do not match the grant")
	var artifact: Variant = JSON.parse_string(authorization_bytes.get_string_from_utf8())
	if not artifact is Dictionary or not _has_exact_keys(artifact, AUTHORIZATION_KEYS):
		return _rejected(context, "authorization artifact does not have the live contract's exact fields")
	if artifact["contract"] != AUTHORIZATION_CONTRACT or artifact["packet_type"] != AUTHORIZATION_PACKET_TYPE:
		return _rejected(context, "authorization contract must be '%s'" % AUTHORIZATION_CONTRACT)
	var gate_result: Variant = artifact["gate_result"]
	if not gate_result is Dictionary or gate_result.get("gate_name") != APPLY_GATE_NAME or gate_result.get("passed") != "TRUE":
		return _rejected(context, "authorization must carry a TRUE %s result" % APPLY_GATE_NAME)
	if artifact["execution_performed"] != false or artifact["renderer_contacted"] != false:
		return _rejected(context, "authorization must be authorization only")
	if not _is_hex(artifact["authorized_intent_sha256"], 64):
		return _rejected(context, "authorization must carry the authorized intent digest")

	# 4. The artifact and the grant must name the same decision, session, activation and observation.
	var evidence: Variant = artifact["authority_evidence"]
	var activation: Variant = artifact["scene_activation"]
	var semantic: Variant = artifact["semantic_activation"]
	var packet: Variant = artifact["apply_packet"]
	if not evidence is Dictionary or not activation is Dictionary or not semantic is Dictionary or not packet is Dictionary:
		return _rejected(context, "authorization evidence blocks must be dictionaries")
	if evidence.get("decision_id") != grant["decision_id"] or evidence.get("runtime_session_id") != grant["runtime_session_id"]:
		return _rejected(context, "grant decision or runtime session contradicts the authorization")
	if activation.get("activation_id") != grant["activation_id"] or activation.get("scene_id") != grant["scene_id"] \
			or activation.get("scene_revision") != grant["scene_revision"]:
		return _rejected(context, "grant scene activation contradicts the authorization")
	if semantic.get("activation_id") != grant["activation_id"] \
			or not _same_int(semantic.get("semantic_main_instance_id"), grant["semantic_main_instance_id"]) \
			or not _same_int(semantic.get("semantic_local_generation"), grant["semantic_local_generation"]):
		return _rejected(context, "grant Semantic observation contradicts the authorization")

	# 5. The embedded apply packet, under the same rules the v1 proof honors.
	if packet.get("contract") != APPLY_CONTRACT or packet.get("packet_type") != APPLY_PACKET_TYPE:
		return _rejected(context, "embedded packet must be the accepted trixel32d_surface_apply.v1 packet")
	if packet.get("apply_id") != grant["apply_id"] or not V1._valid_prefixed_hex_id(packet.get("apply_id"), "t32dapply_"):
		return _rejected(context, "apply_id must be canonical and match the grant")
	var authorization: Variant = packet.get("authorization")
	if not authorization is Dictionary or authorization.get("decision") != "AUTHORIZED" \
			or authorization.get("decision_id") != grant["decision_id"] \
			or authorization.get("runtime_session_id") != grant["runtime_session_id"]:
		return _rejected(context, "packet authorization contradicts the grant")
	var binding: Variant = packet.get("surface_binding")
	if not binding is Dictionary or binding.get("built_contract") != "trixel32d_surface_built.v1":
		return _rejected(context, "surface_binding must name the built response contract")
	if not V1._valid_prefixed_hex_id(binding.get("request_id"), "t32dreq_") \
			or not V1._valid_prefixed_hex_id(binding.get("surface_id"), "t32dsurface_"):
		return _rejected(context, "surface_binding identities must be canonical")
	var bound_sha: Variant = binding.get("built_response_sha256")
	if not _is_hex(bound_sha, 64):
		return _rejected(context, "surface_binding.built_response_sha256 must be a SHA-256")
	context["surface_id"] = binding["surface_id"]
	context["request_id"] = binding["request_id"]
	var visibility: Variant = packet.get("visibility")
	if not visibility is Dictionary or visibility.get("intent") != "VISIBLE":
		return _rejected(context, "this executor honors explicit VISIBLE only")
	var replacement: Variant = packet.get("replacement")
	if not replacement is Dictionary or replacement.get("mode") != "CREATE_ONLY" or replacement.get("replaces_apply_id") != null:
		return _rejected(context, "this executor honors CREATE_ONLY only")
	var lifetime: Variant = packet.get("lifetime")
	if not lifetime is Dictionary or lifetime.get("mode") != "SCENE_BOUND":
		return _rejected(context, "this executor honors SCENE_BOUND lifetime only")
	if packet.get("classification") != "PRESENTATION_ONLY":
		return _rejected(context, "this executor honors PRESENTATION_ONLY classification only")
	var collision: Variant = packet.get("collision")
	if not collision is Dictionary or collision.get("decision") != "DENIED" \
			or collision.get("shape_policy") != "NONE" \
			or not _same_int(collision.get("layer"), 0) or not _same_int(collision.get("mask"), 0):
		return _rejected(context, "collision must be DENIED with shape NONE and layer/mask 0")
	var target: Variant = packet.get("target")
	if not target is Dictionary or target.get("scene_id") != grant["scene_id"] or target.get("scene_revision") != grant["scene_revision"]:
		return _rejected(context, "packet target scene contradicts the grant")
	var parent_kind: Variant = target.get("parent_kind")
	var parent_id: Variant = target.get("parent_id")
	context["target"] = {"parent_kind": parent_kind, "parent_id": parent_id, "application_slot_id": target.get("application_slot_id")}
	var local_to_scene: Variant = packet.get("local_to_scene")
	if not local_to_scene is Dictionary or local_to_scene.get("space") != "SCENE_LOCAL_Y_UP":
		return _rejected(context, "local_to_scene.space must be SCENE_LOCAL_Y_UP")
	var basis_columns: Variant = local_to_scene.get("basis_columns")
	var origin: Variant = local_to_scene.get("origin")
	if not basis_columns is Array or basis_columns.size() != 3 or not origin is Array or origin.size() != 3:
		return _rejected(context, "authorized transform must declare three basis columns and an origin")
	var authorized_transform := Transform3D(
		Basis(V1._vector3(basis_columns[0]), V1._vector3(basis_columns[1]), V1._vector3(basis_columns[2])),
		V1._vector3(origin))

	# 6. Payload bytes, declared parent, CREATE_ONLY under that parent.
	var payload_bytes: PackedByteArray = V1._read_bytes(payload_path)
	var payload_sha256: String = V1._sha256(payload_bytes) if not payload_bytes.is_empty() else ""
	context["payload_sha256"] = payload_sha256
	if payload_sha256 != bound_sha:
		return _rejected(context, "payload bytes do not match the authorized surface binding")
	var parent: Variant = parent_nodes.get("%s|%s" % [parent_kind, parent_id])
	if not parent is Node3D or not (parent as Node3D).is_inside_tree():
		return _rejected(context, "declared parent is not present inside the scene tree")
	var node_name := NODE_NAME_PREFIX + String(binding["surface_id"])
	if (parent as Node3D).get_node_or_null(NodePath(node_name)) != null:
		return _rejected(context, "CREATE_ONLY refuses an already-applied surface under this parent")

	# 7. Materialize through the passive-consumer lane, then attach.
	var consume_result := Consumer.consume_file(payload_path, String(bound_sha))
	var consume_report: Variant = consume_result.get("report")
	if not consume_report is Dictionary or consume_report.get("result") != "ACCEPTED":
		return _rejected(context, "passive consumer rejected the authorized payload")
	if consume_report.get("surface_id") != binding["surface_id"] or consume_report.get("response_id") != binding["request_id"]:
		return _rejected(context, "consumed payload identity contradicts the authorized surface binding")
	var mesh: Variant = consume_result.get("mesh")
	if not mesh is ArrayMesh:
		return _rejected(context, "passive consumer did not return an ArrayMesh")

	var node := MeshInstance3D.new()
	node.name = node_name
	node.transform = authorized_transform
	node.visible = true
	node.mesh = mesh
	node.set_meta(LOAD_META, current_load.duplicate(true))
	(parent as Node3D).add_child(node)
	_applied.append({"node": node, "load": current_load.duplicate(true)})
	return {"node": node, "report": _report(context, true, null, node)}


## Call whenever the host accepts a new runtime load. Frees every node applied under
## any other load; returns how many were freed.
func release_for_load(current_load: Dictionary) -> int:
	var freed := 0
	var kept: Array = []
	for entry in _applied:
		var node: Variant = entry["node"]
		if not is_instance_valid(node):
			continue  # already freed with its scene
		if _same_load(entry["load"], current_load):
			kept.append(entry)
		else:
			(node as Node).get_parent().remove_child(node)
			(node as Node).free()
			freed += 1
	_applied = kept
	return freed


func applied_count() -> int:
	return _applied.filter(func(entry): return is_instance_valid(entry["node"])).size()


static func _report(context: Dictionary, applied: bool, error: Variant, node: Variant) -> Dictionary:
	return {
		"contract": REPORT_CONTRACT,
		"version": 1,
		"result": "APPLIED" if applied else "REJECTED",
		"first_blocking_error": error,
		"grant_id": context["grant_id"],
		"decision_id": context["decision_id"],
		"apply_id": context["apply_id"],
		"surface_id": context["surface_id"],
		"request_id": context["request_id"],
		"authorization_sha256": context["authorization_sha256"],
		"payload_sha256": context["payload_sha256"],
		"target": context["target"],
		"scene_bound_load": context["load"] if applied else null,
		"collision_applied": "DENIED_NONE",
		"node_name": String(node.name) if node is MeshInstance3D else null,
		"runtime_application_completed": applied,
	}


static func _rejected(context: Dictionary, error: String) -> Dictionary:
	return {"node": null, "report": _report(context, false, error, null)}


static func _digest(data: PackedByteArray) -> PackedByteArray:
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(data)
	return hashing.finish()


static func _has_exact_keys(value: Dictionary, keys: Array) -> bool:
	var actual: Array = value.keys()
	actual.sort()
	return actual == keys


static func _is_hex(value: Variant, length: int) -> bool:
	if not value is String or String(value).length() != length:
		return false
	for character in String(value):
		if not "0123456789abcdef".contains(character):
			return false
	return true


## JSON numbers arrive as floats; compare integral values exactly, never bools.
static func _same_int(a: Variant, b: Variant) -> bool:
	for value in [a, b]:
		if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
			return false
		if typeof(value) == TYPE_FLOAT and float(value) != floor(float(value)):
			return false
	return int(a) == int(b)


static func _same_load(a: Variant, b: Variant) -> bool:
	if not a is Dictionary or not b is Dictionary or not _has_exact_keys(a, LOAD_KEYS) or not _has_exact_keys(b, LOAD_KEYS):
		return false
	return a["runtime_instance_id"] is String and a["runtime_instance_id"] == b["runtime_instance_id"] \
		and a["scene_id"] is String and a["scene_id"] == b["scene_id"] \
		and _same_int(a["load_seq"], b["load_seq"])
