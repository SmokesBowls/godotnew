extends Node3D
## H04b: the independent world environment (Layer 2). Separate from the selector's object preview.
## Shows exactly what the runtime holds: the activated scene's entities (8080 /snapshot/peek
## bridge_entities, gated on the scene_activation stamp) and any authorized Trixel surface
## attached under Surfaces. It never activates, builds, or invents terrain; an empty runtime
## shows an empty world and says so.
## Fly camera from the Semantic donor (Main.gd handle_movement / handle_mouse_look); its F9 disk
## snapshot, Tab chooser and runtime connections are not carried over.

signal closed

const ActorScene := preload("res://semantic_actor.tscn")
const SceneView := preload("res://scene_view.gd")
const POLL_SECONDS := 2.0

@onready var camera: Camera3D = $World/CameraRig/Camera3D
@onready var actors: Node3D = $World/Actors
@onready var surfaces: Node3D = $World/Surfaces
@onready var _status: Label = $UI/Bar/Status

var move_speed := 10.0
var vertical_speed := 8.0
var mouse_sensitivity := 0.0025
var yaw := 0.0
var pitch := 0.0

var _link: Node  # the selector's EngAInRuntimeLink (shared, not duplicated)
var _manifest: Dictionary = {}
var _shown_stamp: Variant = null
var _poll: Timer


func _ready() -> void:
	$UI/Bar/Back.pressed.connect(close)
	$UI/Bar/Refresh.pressed.connect(refresh)
	camera.current = true
	_poll = Timer.new()
	_poll.wait_time = POLL_SECONDS
	_poll.timeout.connect(refresh)
	add_child(_poll)


## runtime_link: the selector's EngAInRuntimeLink. asset_manifest: resolved /assets/active manifest ({} = built-in capsules).
func open(runtime_link: Node, asset_manifest: Dictionary) -> void:
	_link = runtime_link
	_manifest = asset_manifest
	_poll.start()
	refresh()


func close() -> void:
	_poll.stop()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	closed.emit()


## Reads the runtime (non-consuming peek) and rebuilds actors when the activation stamp changes.
func refresh() -> Dictionary:
	var peeked: Dictionary = await _link.peek()
	if not is_inside_tree():
		return {}
	var payload: Dictionary = (peeked.body as Dictionary).get("payload", {}) if peeked.body is Dictionary else {}
	var stamp: Variant = _link.normalize_load(payload.get("scene_activation"))
	if peeked.code != 200:
		_set_empty("Runtime unreachable (HTTP %d) — nothing shown." % peeked.code)
		return {"state": "unreachable"}
	if stamp == null or str(payload.get("scene_id", "")) != stamp["scene_id"]:
		_set_empty("No runtime scene is active — empty world. Activate a candidate in the selector to populate it.")
		return {"state": "empty"}
	if stamp == _shown_stamp:
		return {"state": "unchanged", "actors": actors.get_child_count()}
	var stats := hydrate(payload.get("bridge_entities", []))
	_shown_stamp = stamp
	_status.text = "Runtime scene %s  (load %d, DRAFT — not accepted)   %d entities from the runtime%s   |   %d authorized surfaces" % [
		stamp["scene_id"], stamp["load_seq"], stats.spawned,
		"" if stats.skipped == 0 else ", %d without id/position not shown" % stats.skipped, surfaces.get_child_count()]
	if stats.spawned > 0:
		_frame(stats.lo, stats.hi)
	return {"state": "hydrated", "stamp": stamp, "actors": stats.spawned, "ids": stats.ids, "skipped": stats.skipped}


## Places only the entities the runtime supplied, at the positions it supplied.
func hydrate(entities: Variant) -> Dictionary:
	_clear_actors()
	var stats := {"spawned": 0, "skipped": 0, "ids": [], "lo": Vector3(INF, INF, INF), "hi": -Vector3(INF, INF, INF)}
	if not entities is Array:
		return stats
	var seen := {}
	for e in entities:
		var eid := str(e.get("entity_id", e.get("id", ""))) if e is Dictionary else ""
		var p: Dictionary = SceneView.position_dict(e) if e is Dictionary else {}
		if eid.is_empty() or seen.has(eid) or p.is_empty():
			stats.skipped += 1  # never invent an id or a position
			continue
		seen[eid] = true
		var pos := Vector3(float(p.get("x", 0.0)), float(p.get("y", 0.0)), float(p.get("z", 0.0)))
		var etype := str(e.get("type", e.get("zw_concept", "unknown")))
		var actor := ActorScene.instantiate()
		actor.name = eid.validate_node_name()
		actors.add_child(actor)
		actor.apply_entity_data(eid, e, pos, SceneView.resolve_style(_manifest, eid, etype))
		stats.lo = stats.lo.min(pos)
		stats.hi = stats.hi.max(pos)
		stats.spawned += 1
		(stats.ids as Array).append(eid)
	return stats


func _set_empty(message: String) -> void:
	_clear_actors()
	_shown_stamp = null
	_status.text = message


func _clear_actors() -> void:
	for child in actors.get_children():
		actors.remove_child(child)
		child.queue_free()


## Camera only: looks at what the runtime supplied; moves no entity.
func _frame(lo: Vector3, hi: Vector3) -> void:
	var center := (lo + hi) * 0.5
	var extent := maxf((hi - lo).length(), 6.0)
	camera.global_position = center + Vector3(0, extent * 0.35 + 3.0, extent * 0.7 + 6.0)
	camera.look_at(center)
	var e := camera.global_rotation
	pitch = e.x
	yaw = e.y


# ── Donor fly camera (Main.gd), unchanged apart from capture-gated mouse look ──

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		handle_mouse_look(event)
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		elif event.keycode == KEY_ENTER:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _process(delta: float) -> void:
	handle_movement(delta)


func handle_movement(delta: float) -> void:
	if Input.is_key_pressed(KEY_CTRL) and Input.is_action_pressed("ui_up"):
		camera.global_position.y += vertical_speed * delta
		return
	if Input.is_key_pressed(KEY_CTRL) and Input.is_action_pressed("ui_down"):
		camera.global_position.y -= vertical_speed * delta
		return
	var dir := Vector3.ZERO
	if Input.is_action_pressed("ui_up"):
		dir -= camera.global_transform.basis.z
	if Input.is_action_pressed("ui_down"):
		dir += camera.global_transform.basis.z
	if Input.is_action_pressed("ui_left"):
		dir -= camera.global_transform.basis.x
	if Input.is_action_pressed("ui_right"):
		dir += camera.global_transform.basis.x
	dir.y = 0
	if dir.length() > 0:
		camera.global_position += dir.normalized() * move_speed * delta


func handle_mouse_look(event: InputEventMouseMotion) -> void:
	yaw -= event.relative.x * mouse_sensitivity
	pitch = clamp(pitch - event.relative.y * mouse_sensitivity, -1.5, 1.5)
	camera.global_transform.basis = Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch)
