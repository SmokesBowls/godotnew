extends VBoxContainer
## S03a static scene view: renders one Mettaext candidate scene's entities as placeholder capsules.
## Display only. Never talks to 8080; positions are shown exactly as supplied (Pass 5 synthetic
## layout), labelled as placeholder layout; no terrain or environment is inferred from the text.
## Spawn/hydrate logic harvested from the Semantic donor (Main.gd _spawn_bridge_entity,
## hydrate_from_snapshot_payload, _disk_position_dict).

const ActorScene := preload("res://semantic_actor.tscn")
const PLACEMENT_NOTE := "placeholder layout — not narrative placement (positions as supplied by the extraction)"

var _banner: RichTextLabel
var _actors: Node3D
var _surfaces: Node3D  # runtime-authorized surfaces (EngAInRuntimeLink); never candidate content
var _camera: Camera3D


func _ready() -> void:
	_banner = RichTextLabel.new()
	_banner.bbcode_enabled = true
	_banner.fit_content = true
	_banner.scroll_active = false
	add_child(_banner)

	var container := SubViewportContainer.new()
	container.stretch = true
	container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	container.custom_minimum_size = Vector2(0, 240)
	add_child(container)
	var vp := SubViewport.new()
	vp.own_world_3d = true  # this view's world is never shared with anything else
	container.add_child(vp)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.11, 0.12, 0.14)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.65)
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	vp.add_child(world_env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -30, 0)
	vp.add_child(sun)
	_camera = Camera3D.new()
	_camera.fov = 50
	vp.add_child(_camera)
	_actors = Node3D.new()
	_actors.name = "Actors"
	vp.add_child(_actors)
	_surfaces = Node3D.new()
	_surfaces.name = "Surfaces"
	vp.add_child(_surfaces)
	show_message("Select a chapter to view its extracted entities.")


## No scene is rendered: clears every actor so nothing previous looks current.
func show_message(bbcode: String) -> void:
	_clear()
	_banner.text = bbcode


## scene: one game scene from the candidate. assets: {ok, pack_id, manifest, problems}.
## Returns counts for the self-test.
func render(scene: Dictionary, scene_label: String, assets: Dictionary) -> Dictionary:
	_clear()
	var manifest: Dictionary = assets.get("manifest", {}) if assets.get("ok", false) else {}
	var stats := {"spawned": 0, "skipped_empty_id": 0, "skipped_duplicate": 0,
		"skipped_missing_position": 0, "unsupported_mode": 0, "ids": []}
	var seen := {}
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for e in scene.get("entities", []):
		if not e is Dictionary:
			stats.skipped_empty_id += 1
			continue
		var eid := str(e.get("entity_id", e.get("id", "")))
		if eid.is_empty():
			stats.skipped_empty_id += 1
			continue
		if seen.has(eid):
			stats.skipped_duplicate += 1
			continue
		var p := position_dict(e)
		if p.is_empty():
			stats.skipped_missing_position += 1  # never invent a position
			continue
		seen[eid] = true
		var style := resolve_style(manifest, eid, str(e.get("type", e.get("entity_type", "unknown"))))
		if str(style.get("mode", "procedural_capsule")) != "procedural_capsule":
			stats.unsupported_mode += 1  # S03a renders capsules only; the actor still shows
		var pos := Vector3(float(p.get("x", 0.0)), float(p.get("y", 0.0)), float(p.get("z", 0.0)))
		var actor := ActorScene.instantiate()
		actor.name = eid.validate_node_name()
		_actors.add_child(actor)
		actor.apply_entity_data(eid, e, pos, style)
		lo = lo.min(pos)
		hi = hi.max(pos)
		stats.spawned += 1
		(stats.ids as Array).append(eid)

	if stats.spawned > 0:
		_frame(lo, hi)
	var lines := PackedStringArray([
		"[color=#ffb84d][b]CANDIDATE — not accepted[/b][/color]   %s   %d entities shown" % [scene_label, stats.spawned],
		"[color=#ffb84d]%s[/color]" % PLACEMENT_NOTE,
	])
	if assets.get("ok", false):
		lines.append("assets: pack [b]%s[/b] from 8765 /assets/active" % str(assets.get("pack_id", "?")))
	else:
		lines.append("[color=#ff8080]asset pack unavailable[/color] — built-in capsule fallback, not from any manifest (%s)" % "; ".join(PackedStringArray(assets.get("problems", []))))
	var skipped := int(stats.skipped_empty_id) + int(stats.skipped_duplicate) + int(stats.skipped_missing_position)
	if skipped > 0 or int(stats.unsupported_mode) > 0:
		lines.append("not shown: %d without id, %d duplicate, %d without position;  %d with a non-capsule asset mode drawn as capsules" % [
			stats.skipped_empty_id, stats.skipped_duplicate, stats.skipped_missing_position, stats.unsupported_mode])
	_banner.text = "\n".join(lines)
	return stats


## Donor resolution order: entities[id] -> types[type] -> fallback.entity -> built-in capsule.
static func resolve_style(manifest: Dictionary, eid: String, etype: String) -> Dictionary:
	for cfg in [(manifest.get("entities", {}) as Dictionary).get(eid, {}),
			(manifest.get("types", {}) as Dictionary).get(etype, {}),
			(manifest.get("fallback", {}) as Dictionary).get("entity", {})]:
		if cfg is Dictionary and not (cfg as Dictionary).is_empty():
			return cfg
	return {}


## Accepts position as {x,y,z} or [x,y,z], or transform.position in either form (donor _disk_position_dict).
static func position_dict(e: Dictionary) -> Dictionary:
	for v: Variant in [e.get("position"), (e.get("transform", {}) as Dictionary).get("position") if e.get("transform") is Dictionary else null]:
		if v is Dictionary:
			return v
		if v is Array and (v as Array).size() >= 3:
			return {"x": v[0], "y": v[1], "z": v[2]}
	return {}


## Camera only: frames whatever was supplied, moves no entity.
func _frame(lo: Vector3, hi: Vector3) -> void:
	var center := (lo + hi) * 0.5 + Vector3(0, 1, 0)
	var extent := maxf((hi - lo).length(), 4.0)
	_camera.position = center + Vector3(0, extent * 0.2 + 2.0, extent * 0.55 + 4.0)
	_camera.look_at(center)


func _clear() -> void:
	for child in _actors.get_children():
		_actors.remove_child(child)
		child.queue_free()


## Parent for applied runtime surfaces. Candidate rendering never touches it; the live
## executor frees its nodes when their runtime load stops being presented.
func surface_container() -> Node3D:
	return _surfaces


func actor_count() -> int:
	return _actors.get_child_count()
