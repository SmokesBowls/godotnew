extends RefCounted

## Isolated Trixel 3.2d apply executor.
##
## Application authority is exactly one checksum-locked EngAIn
## apply-authorization artifact (accepted trixel32d_surface_apply.v1 packet,
## gate-TRUE result, authorized intent digest) plus the checksum-bound built
## response it names. A renderer-side consume report is never authority.
## Materialization goes through the existing passive-consumer lane and stays
## separate from application authorization. Collision must be DENIED/NONE.
## Rejection creates no node and mutates no scene state. The quarantined
## runtime attacher is neither touched nor referenced.

const Consumer = preload("res://trixel_proof/trixel32d_passive/godot/trixel32d_surface_consumer.gd")

const AUTHORIZATION_CONTRACT := "engainos.trixel32d_apply_authorization.v1"
const APPLY_CONTRACT := "trixel32d_surface_apply.v1"
const APPLY_PACKET_TYPE := "trixel32d_surface_apply"
const APPLY_GATE_NAME := "gate_trixel32d_surface_apply"
const REPORT_CONTRACT := "godot.trixel32d_apply_report.v1"
const NODE_NAME_PREFIX := "Trixel32DApplied_"


static func apply(
	authorization_path: String,
	expected_authorization_sha256: String,
	payload_path: String,
	parent_nodes: Dictionary
) -> Dictionary:
	var context := {
		"apply_id": null, "surface_id": null, "request_id": null,
		"payload_sha256": null, "authorization_sha256": null,
		"target": null, "transform_origin": null,
	}

	var authorization_bytes := _read_bytes(authorization_path)
	if authorization_bytes.is_empty():
		return _rejected(context, "authorization artifact could not be read")
	var authorization_sha256 := _sha256(authorization_bytes)
	context["authorization_sha256"] = authorization_sha256
	if authorization_sha256 != expected_authorization_sha256:
		return _rejected(context, "authorization artifact SHA-256 does not match the expected lock")

	var parser := JSON.new()
	if parser.parse(authorization_bytes.get_string_from_utf8()) != OK:
		return _rejected(context, "authorization artifact is not valid JSON")
	var artifact: Variant = parser.get_data()
	if not artifact is Dictionary:
		return _rejected(context, "authorization artifact root must be a dictionary")
	if artifact.get("contract") != AUTHORIZATION_CONTRACT:
		return _rejected(context, "authorization contract must be '%s'; a consume report is never application authority" % AUTHORIZATION_CONTRACT)

	var gate_result: Variant = artifact.get("gate_result")
	if not gate_result is Dictionary or gate_result.get("gate_name") != APPLY_GATE_NAME or gate_result.get("passed") != "TRUE":
		return _rejected(context, "authorization must carry a TRUE %s result" % APPLY_GATE_NAME)
	if not (artifact.get("authorized_intent_sha256") is String) or String(artifact["authorized_intent_sha256"]).length() != 64:
		return _rejected(context, "authorization must carry the authorized intent digest")
	if artifact.get("collision_authorized") != false:
		return _rejected(context, "authorization must declare collision_authorized false")

	var packet: Variant = artifact.get("apply_packet")
	if not packet is Dictionary:
		return _rejected(context, "authorization must embed the accepted apply packet")
	if packet.get("contract") != APPLY_CONTRACT or packet.get("packet_type") != APPLY_PACKET_TYPE:
		return _rejected(context, "embedded packet must be the accepted trixel32d_surface_apply.v1 packet")
	if not _valid_prefixed_hex_id(packet.get("apply_id"), "t32dapply_"):
		return _rejected(context, "apply_id must be a canonical t32dapply identity")
	context["apply_id"] = packet["apply_id"]

	var binding: Variant = packet.get("surface_binding")
	if not binding is Dictionary or binding.get("built_contract") != "trixel32d_surface_built.v1":
		return _rejected(context, "surface_binding must name the built response contract")
	if not _valid_prefixed_hex_id(binding.get("request_id"), "t32dreq_"):
		return _rejected(context, "surface_binding.request_id must be canonical")
	if not _valid_prefixed_hex_id(binding.get("surface_id"), "t32dsurface_"):
		return _rejected(context, "surface_binding.surface_id must be canonical")
	var bound_sha: Variant = binding.get("built_response_sha256")
	if not bound_sha is String or String(bound_sha).length() != 64:
		return _rejected(context, "surface_binding.built_response_sha256 must be a SHA-256")
	var artifact_binding: Variant = artifact.get("payload_binding")
	if not artifact_binding is Dictionary or artifact_binding.get("built_response_sha256") != bound_sha \
			or artifact_binding.get("surface_id") != binding["surface_id"] \
			or artifact_binding.get("request_id") != binding["request_id"]:
		return _rejected(context, "artifact payload_binding contradicts the packet surface_binding")
	context["surface_id"] = binding["surface_id"]
	context["request_id"] = binding["request_id"]

	var payload_bytes := _read_bytes(payload_path)
	if payload_bytes.is_empty():
		return _rejected(context, "built-response payload could not be read")
	var payload_sha256 := _sha256(payload_bytes)
	context["payload_sha256"] = payload_sha256
	if payload_sha256 != bound_sha:
		return _rejected(context, "payload bytes do not match the authorized surface binding")

	var visibility: Variant = packet.get("visibility")
	if not visibility is Dictionary or visibility.get("intent") != "VISIBLE":
		return _rejected(context, "this proof honors explicit VISIBLE only")
	var replacement: Variant = packet.get("replacement")
	if not replacement is Dictionary or replacement.get("mode") != "CREATE_ONLY" or replacement.get("replaces_apply_id") != null:
		return _rejected(context, "this proof honors CREATE_ONLY only")
	var lifetime: Variant = packet.get("lifetime")
	if not lifetime is Dictionary or lifetime.get("mode") != "SCENE_BOUND":
		return _rejected(context, "this proof honors SCENE_BOUND lifetime only")
	if packet.get("classification") != "PRESENTATION_ONLY":
		return _rejected(context, "this proof honors PRESENTATION_ONLY classification only")
	var collision: Variant = packet.get("collision")
	if not collision is Dictionary or collision.get("decision") != "DENIED" \
			or collision.get("shape_policy") != "NONE" \
			or int(collision.get("layer", -1)) != 0 or int(collision.get("mask", -1)) != 0:
		return _rejected(context, "collision must be DENIED with shape NONE and layer/mask 0; collision remains denied and untested")

	var target: Variant = packet.get("target")
	if not target is Dictionary:
		return _rejected(context, "packet target must be a dictionary")
	var parent_kind: Variant = target.get("parent_kind")
	var parent_id: Variant = target.get("parent_id")
	var slot_id: Variant = target.get("application_slot_id")
	context["target"] = {"parent_kind": parent_kind, "parent_id": parent_id, "application_slot_id": slot_id}
	var scene_truth: Variant = artifact.get("scene_truth")
	if not scene_truth is Dictionary or not scene_truth.get("declared_targets") is Array:
		return _rejected(context, "authorization must declare scene truth targets")
	var declared := false
	for declared_target in scene_truth["declared_targets"]:
		if declared_target is Array and declared_target.size() == 3 \
				and declared_target[0] == parent_kind and declared_target[1] == parent_id and declared_target[2] == slot_id:
			declared = true
			break
	if not declared:
		return _rejected(context, "target is not a declared (parent_kind, parent_id, slot) tuple")
	var occupancy: Variant = scene_truth.get("slot_occupancy")
	if occupancy is Dictionary and occupancy.has(slot_id):
		return _rejected(context, "CREATE_ONLY requires an unoccupied declared slot")

	var parent_key := "%s|%s" % [parent_kind, parent_id]
	var parent: Variant = parent_nodes.get(parent_key)
	if not parent is Node3D:
		return _rejected(context, "declared parent is not present as a Node3D in the scene manifest")
	if not (parent as Node3D).is_inside_tree():
		return _rejected(context, "declared parent must be inside a scene tree")

	var local_to_scene: Variant = packet.get("local_to_scene")
	if not local_to_scene is Dictionary or local_to_scene.get("space") != "SCENE_LOCAL_Y_UP":
		return _rejected(context, "local_to_scene.space must be SCENE_LOCAL_Y_UP")
	var basis_columns: Variant = local_to_scene.get("basis_columns")
	var origin: Variant = local_to_scene.get("origin")
	if not basis_columns is Array or basis_columns.size() != 3 or not origin is Array or origin.size() != 3:
		return _rejected(context, "authorized transform must declare three basis columns and an origin")
	var authorized_basis := Basis(_vector3(basis_columns[0]), _vector3(basis_columns[1]), _vector3(basis_columns[2]))
	var authorized_transform := Transform3D(authorized_basis, _vector3(origin))
	context["transform_origin"] = origin

	var node_name := NODE_NAME_PREFIX + String(binding["surface_id"])
	if (parent as Node3D).get_node_or_null(NodePath(node_name)) != null:
		return _rejected(context, "CREATE_ONLY refuses an already-applied surface under this parent")

	# Materialization stays separate from authorization: the passive-consumer
	# lane validates and builds the mesh only after authority is established.
	var consume_result := Consumer.consume_file(payload_path, String(bound_sha))
	var consume_report: Variant = consume_result.get("report")
	if not consume_report is Dictionary or consume_report.get("result") != "ACCEPTED":
		var consume_error: Variant = consume_report.get("first_blocking_error") if consume_report is Dictionary else "unknown"
		return _rejected(context, "passive consumer rejected the authorized payload: %s" % consume_error)
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
	(parent as Node3D).add_child(node)

	return {
		"node": node,
		"mesh": mesh,
		"report": _report(context, true, null, node),
	}


static func _report(context: Dictionary, applied: bool, error: Variant, node: Variant) -> Dictionary:
	return {
		"contract": REPORT_CONTRACT,
		"version": 1,
		"result": "APPLIED" if applied else "REJECTED",
		"first_blocking_error": error,
		"apply_id": context["apply_id"],
		"surface_id": context["surface_id"],
		"request_id": context["request_id"],
		"payload_sha256": context["payload_sha256"],
		"authorization_sha256": context["authorization_sha256"],
		"target": context["target"],
		"transform_origin_applied": context["transform_origin"] if applied else null,
		"visibility_applied": "VISIBLE" if applied else null,
		"replacement_mode": "CREATE_ONLY" if applied else null,
		"collision_applied": "DENIED_NONE",
		"node_name": String(node.name) if node is MeshInstance3D else null,
		"node_class": "MeshInstance3D" if node is MeshInstance3D else null,
		"runtime_application_completed": applied,
		"godot_runtime_scope": "ISOLATED_APPLY_EXECUTOR_PROOF_ONLY",
	}


static func _rejected(context: Dictionary, error: String) -> Dictionary:
	return {"node": null, "mesh": null, "report": _report(context, false, error, null)}


static func _read_bytes(path: String) -> PackedByteArray:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return PackedByteArray()
	var data := file.get_buffer(file.get_length())
	file.close()
	return data


static func _sha256(data: PackedByteArray) -> String:
	var hashing := HashingContext.new()
	if hashing.start(HashingContext.HASH_SHA256) != OK or hashing.update(data) != OK:
		return ""
	return hashing.finish().hex_encode()


static func _vector3(value: Array) -> Vector3:
	return Vector3(float(value[0]), float(value[1]), float(value[2]))


static func _valid_prefixed_hex_id(value: Variant, prefix: String) -> bool:
	if not value is String:
		return false
	var identity := String(value)
	if not identity.begins_with(prefix) or identity.length() != prefix.length() + 16:
		return false
	for character in identity.substr(prefix.length()):
		if not "0123456789abcdef".contains(character):
			return false
	return true
