extends Node3D
## One extracted entity as a placeholder capsule (S03a). Harvested from the Semantic donor's
## scripts/SemanticActor.gd + _spawn_bridge_entity capsule fallback. The donor's 5x5 debug remap
## is NOT carried over: the node sits exactly at the position the extraction supplied.

const DEFAULT_COLOR := Color(0.2, 0.6, 1.0)
const DEFAULT_SCALE := Vector3(0.5, 1.8, 0.5)  # x = capsule radius, y = capsule height (donor defaults)


## eid/data come from the extraction; style is the resolved asset config (may be empty).
func apply_entity_data(eid: String, data: Dictionary, pos: Vector3, style: Dictionary) -> void:
	position = pos
	set_meta("entity_id", eid)
	set_meta("entity_type", str(data.get("type", "unknown")))
	set_meta("supplied_position", pos)

	var scale_v := DEFAULT_SCALE
	var s: Variant = style.get("scale")
	if s is Array and (s as Array).size() >= 3:
		scale_v = Vector3(float(s[0]), float(s[1]), float(s[2]))
	var color := DEFAULT_COLOR
	var c: Variant = style.get("color")
	if c is Array and (c as Array).size() >= 3:
		color = Color(float(c[0]), float(c[1]), float(c[2]))

	var mesh := CapsuleMesh.new()
	mesh.radius = scale_v.x
	mesh.height = maxf(scale_v.y, 2.0 * scale_v.x)  # Godot requires height >= 2 * radius
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	var body := $Body as MeshInstance3D
	body.mesh = mesh
	body.material_override = mat
	body.position.y = mesh.height * 0.5  # presentation only: capsule stands on the supplied point

	var label := $Name as Label3D
	var name_text := str(data.get("name", eid))
	label.text = name_text if name_text.to_lower() == eid.to_lower() else "%s\nid=%s" % [name_text, eid]
	label.position.y = mesh.height + 0.6
