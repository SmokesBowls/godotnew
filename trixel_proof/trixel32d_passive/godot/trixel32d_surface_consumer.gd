extends RefCounted

const RESPONSE_CONTRACT := "trixel32d_surface_built.v1"
const RESPONSE_PACKET_TYPE := "trixel32d_surface_built"
const REPORT_CONTRACT := "godot.trixel32d_surface_consume_report.v1"
const COORDINATE_SPACE := "TRIXEL_LOCAL_Y_UP"
const WINDING_POLICY := "CLOCKWISE_FRONT_FACE_GODOT"
const NORMALS_POLICY := "CANONICAL_FACE_NORMALS_INCLUDED"
const TANGENTS_POLICY := "OMITTED_NO_TANGENT_BASIS"
const TOPOLOGY_POLICY := "HEIGHT_FIELD_CELL_EXTRUSION"
const COMPLETE_EDGE_TOPOLOGY := "HEIGHT_FIELD_COMPLETE_EDGE_CONNECTED_SURFACE"
# Mirror of the proven EngAIn/Trixel policy table: only declared policies are
# consumable; the stitched intermediate policy is intentionally not listed.
const SUPPORTED_TOPOLOGIES := [TOPOLOGY_POLICY, COMPLETE_EDGE_TOPOLOGY]
const CANONICAL_WALL_ORDER := ["-field_y", "+field_x", "+field_y", "-field_x"]
const EXPECTED_SURFACES := [
	["PRIMARY_PIXEL_FACE", "top"],
	["NEUTRAL_GAP_FILL", "bottom"],
	["NEUTRAL_GAP_FILL", "-field_y"],
	["NEUTRAL_GAP_FILL", "+field_x"],
	["NEUTRAL_GAP_FILL", "+field_y"],
	["NEUTRAL_GAP_FILL", "-field_x"],
]


static func consume_file(path: String, expected_sha256: String = "") -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _rejected({}, "", "source fixture could not be opened")
	var source_bytes := file.get_buffer(file.get_length())
	file.close()
	var hashing := HashingContext.new()
	if hashing.start(HashingContext.HASH_SHA256) != OK:
		return _rejected({}, "", "source fixture SHA-256 context could not be initialized")
	if hashing.update(source_bytes) != OK:
		return _rejected({}, "", "source fixture SHA-256 could not be computed")
	var actual_sha256 := hashing.finish().hex_encode()
	if not expected_sha256.is_empty() and actual_sha256 != expected_sha256:
		return _rejected({}, actual_sha256, "source fixture SHA-256 mismatch")
	var parser := JSON.new()
	if parser.parse(source_bytes.get_string_from_utf8()) != OK:
		return _rejected({}, actual_sha256, "source fixture is not valid JSON")
	return _consume_verified_payload(parser.get_data(), actual_sha256)


# Internal validation/materialization seam. Callers must verify source bytes first.
static func _consume_verified_payload(packet: Variant, source_sha256: String) -> Dictionary:
	var validation_error := _validate_packet(packet)
	if not validation_error.is_empty():
		return _rejected(packet, source_sha256, validation_error)

	var geometry: Dictionary = packet["geometry"]
	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	for value in geometry["positions"]:
		positions.append(Vector3(float(value[0]), float(value[1]), float(value[2])))
	for value in geometry["normals"]:
		normals.append(Vector3(float(value[0]), float(value[1]), float(value[2])))
	for value in geometry["uvs"]:
		uvs.append(Vector2(float(value[0]), float(value[1])))
	for value in geometry["colors"]:
		colors.append(Color(float(value[0]), float(value[1]), float(value[2]), float(value[3])))
	for value in geometry["indices"]:
		indices.append(int(value))

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	if mesh.get_surface_count() != 1:
		return _rejected(packet, source_sha256, "ArrayMesh materialization did not create exactly one surface")

	return {
		"mesh": mesh,
		"arrays": arrays,
		"report": _report(packet, source_sha256, true, null),
	}


static func _validate_packet(packet: Variant) -> String:
	if not packet is Dictionary:
		return "response root must be a dictionary"
	if packet.get("contract") != RESPONSE_CONTRACT:
		return "contract must be 'trixel32d_surface_built.v1'"
	if packet.get("packet_type") != RESPONSE_PACKET_TYPE:
		return "packet_type must be 'trixel32d_surface_built'"
	if not _valid_prefixed_hex_id(packet.get("request_id"), "t32dreq_"):
		return "response request_id must be a canonical t32dreq identity"
	if not _valid_prefixed_hex_id(packet.get("surface_id"), "t32dsurface_"):
		return "surface_id must be a canonical t32dsurface identity"
	if packet.get("status") != "BUILT":
		return "response status must be 'BUILT'"
	if packet.get("errors") is not Array or not packet["errors"].is_empty():
		return "BUILT response errors must be an empty array"
	if packet.get("rejected_cells") is not Array or not packet["rejected_cells"].is_empty():
		return "BUILT response rejected_cells must be an empty array"
	if not SUPPORTED_TOPOLOGIES.has(packet.get("topology_policy")):
		return "unsupported topology_policy declaration"
	var topology_policy := String(packet["topology_policy"])

	var metadata: Variant = packet.get("local_spatial_metadata")
	if not metadata is Dictionary:
		return "local_spatial_metadata must be a dictionary"
	if metadata.get("coordinate_space") != COORDINATE_SPACE:
		return "unsupported coordinate_space declaration"
	if metadata.get("winding_policy") != WINDING_POLICY:
		return "unsupported winding_policy declaration"
	if metadata.get("normals_policy") != NORMALS_POLICY:
		return "unsupported normals_policy declaration"
	if metadata.get("tangents_policy") != TANGENTS_POLICY:
		return "unsupported tangents_policy declaration"

	var appearance_error := _validate_appearance(packet.get("appearance"))
	if not appearance_error.is_empty():
		return appearance_error

	var geometry: Variant = packet.get("geometry")
	if not geometry is Dictionary:
		return "geometry must be a dictionary"
	if geometry.has("tangents"):
		return "geometry must omit tangents under the declared tangents policy"
	for buffer_name in ["positions", "vertices", "normals", "uvs", "colors", "indices"]:
		if geometry.get(buffer_name) is not Array:
			return "geometry.%s must be an array" % buffer_name

	var positions: Array = geometry["positions"]
	var vertices: Array = geometry["vertices"]
	var normals: Array = geometry["normals"]
	var uvs: Array = geometry["uvs"]
	var colors: Array = geometry["colors"]
	var indices: Array = geometry["indices"]
	if positions.is_empty():
		return "geometry.positions must not be empty"
	if vertices.size() != positions.size():
		return "geometry.vertices length must match positions"
	if normals.size() != positions.size() or uvs.size() != positions.size() or colors.size() != positions.size():
		return "vertex attribute buffer lengths must match positions"
	if indices.is_empty() or indices.size() % 3 != 0:
		return "geometry.indices must contain complete triangles"

	for index in range(positions.size()):
		var error := _validate_numeric_vector(positions[index], 3, "positions", index)
		if not error.is_empty():
			return error
		error = _validate_numeric_vector(vertices[index], 3, "vertices", index)
		if not error.is_empty():
			return error
		if vertices[index] != positions[index]:
			return "geometry.vertices must exactly mirror geometry.positions"
		error = _validate_numeric_vector(normals[index], 3, "normals", index)
		if not error.is_empty():
			return error
		error = _validate_numeric_vector(uvs[index], 2, "uvs", index)
		if not error.is_empty():
			return error
		error = _validate_numeric_vector(colors[index], 4, "colors", index)
		if not error.is_empty():
			return error

	for index_ordinal in range(indices.size()):
		var value: Variant = indices[index_ordinal]
		if not _integer_value(value):
			return "geometry.indices[%d] must be an integer" % index_ordinal
		var vertex_index := int(value)
		if vertex_index < 0 or vertex_index >= positions.size():
			return "geometry.indices[%d] is outside the vertex range" % index_ordinal

	var appearance: Dictionary = packet["appearance"]
	var cell_ranges: Variant = packet.get("cell_geometry_ranges")
	var range_error := _validate_cell_ranges(
		cell_ranges,
		positions,
		normals,
		colors,
		indices,
		appearance["recipe_references"],
		appearance["gap_fill_color"],
		topology_policy
	)
	if not range_error.is_empty():
		return range_error
	return _validate_primitive_provenance(packet.get("primitive_provenance"), cell_ranges, indices.size() / 3)


static func _validate_appearance(value: Variant) -> String:
	if not value is Dictionary:
		return "appearance must be a dictionary"
	if value.get("policy") != "RECIPE_REFERENCE":
		return "appearance.policy must be 'RECIPE_REFERENCE'"
	var color_error := _validate_numeric_vector(value.get("gap_fill_color"), 4, "appearance.gap_fill_color", 0)
	if not color_error.is_empty():
		return color_error
	var gap_fill_color: Array = value["gap_fill_color"]
	for component in gap_fill_color:
		if float(component) < 0.0 or float(component) > 1.0:
			return "appearance.gap_fill_color components must be between 0 and 1"
	var references: Variant = value.get("recipe_references")
	if not references is Array or references.is_empty():
		return "appearance.recipe_references must be a non-empty array"
	var seen := {}
	for reference in references:
		if not _nonempty_string(reference) or seen.has(reference):
			return "appearance.recipe_references must contain unique non-empty strings"
		seen[reference] = true
	return ""


static func _validate_cell_ranges(
	value: Variant,
	positions: Array,
	normals: Array,
	colors: Array,
	indices: Array,
	recipe_references: Array,
	gap_fill_color: Array,
	topology_policy: String
) -> String:
	var vertex_count := positions.size()
	if not value is Array or value.is_empty():
		return "cell_geometry_ranges must be a non-empty array"
	var used_recipes := {}
	var next_vertex_start := 0
	var next_index_start := 0
	var previous_x := -1
	var previous_y := -1
	var current_row_width := 0
	var expected_row_width := -1
	var cell_keys := {}
	for cell_ordinal in range(value.size()):
		var cell: Variant = value[cell_ordinal]
		if not cell is Dictionary:
			return "cell_geometry_ranges[%d] must be a dictionary" % cell_ordinal
		if not _integer_value(cell.get("source_cell_ordinal")) or int(cell["source_cell_ordinal"]) != cell_ordinal:
			return "cell_geometry_ranges[%d] has invalid source_cell_ordinal" % cell_ordinal
		if not _integer_value(cell.get("field_x")) or not _integer_value(cell.get("field_y")):
			return "cell_geometry_ranges[%d] field coordinates must be integers" % cell_ordinal
		var field_x := int(cell["field_x"])
		var field_y := int(cell["field_y"])
		if field_x < 0 or field_y < 0:
			return "cell_geometry_ranges[%d] field coordinates must be non-negative" % cell_ordinal
		if cell_ordinal == 0:
			if field_x != 0 or field_y != 0:
				return "cell_geometry_ranges must start at field coordinate (0,0)"
			current_row_width = 1
		elif field_y == previous_y:
			if field_x != previous_x + 1:
				return "cell_geometry_ranges are not in contiguous row-major order"
			current_row_width += 1
		elif field_y == previous_y + 1:
			if field_x != 0:
				return "each new cell range row must restart at field_x 0"
			if expected_row_width == -1:
				expected_row_width = current_row_width
			elif current_row_width != expected_row_width:
				return "cell_geometry_ranges must form a rectangular field"
			current_row_width = 1
		else:
			return "cell_geometry_ranges are not in contiguous row-major order"
		previous_x = field_x
		previous_y = field_y
		var expected_key := "%d,%d" % [field_x, field_y]
		if cell.get("cell_key") != expected_key or cell_keys.has(expected_key):
			return "cell_geometry_ranges[%d] has invalid or duplicate cell_key" % cell_ordinal
		cell_keys[expected_key] = true
		if cell.get("disposition") != "PRESERVED_1_TO_1":
			return "cell_geometry_ranges[%d] has unsupported disposition" % cell_ordinal
		var recipe: Variant = cell.get("recipe")
		if not _nonempty_string(recipe) or not recipe_references.has(recipe):
			return "cell_geometry_ranges[%d] references an undeclared recipe" % cell_ordinal
		used_recipes[recipe] = true
		if not _nonempty_string(cell.get("terrain")):
			return "cell_geometry_ranges[%d] terrain must be a non-empty string" % cell_ordinal
		var world_cell: Variant = cell.get("world_cell")
		if not world_cell is Dictionary:
			return "cell_geometry_ranges[%d].world_cell must be a dictionary" % cell_ordinal
		for component in ["world_cell_x", "world_cell_y", "world_cell_z"]:
			if not _integer_value(world_cell.get(component)):
				return "cell_geometry_ranges[%d].world_cell components must be integers" % cell_ordinal
		if int(world_cell["world_cell_x"]) != field_x or int(world_cell["world_cell_z"]) != field_y:
			return "cell_geometry_ranges[%d].world_cell projection does not match field coordinates" % cell_ordinal
		var surfaces: Variant = cell.get("surfaces")
		var expected_surfaces := []
		if topology_policy == COMPLETE_EDGE_TOPOLOGY:
			if not surfaces is Array or surfaces.size() < 2 or surfaces.size() > 6:
				return "cell_geometry_ranges[%d] must declare two through six canonical surfaces" % cell_ordinal
			expected_surfaces = [["PRIMARY_PIXEL_FACE", "top"], ["NEUTRAL_GAP_FILL", "bottom"]]
			var wall_cursor := 0
			for wall_ordinal in range(2, surfaces.size()):
				var wall: Variant = surfaces[wall_ordinal]
				if not wall is Dictionary:
					return "cell range surface must be a dictionary"
				var wall_face: Variant = wall.get("face")
				var order_index := -1
				for cursor in range(wall_cursor, CANONICAL_WALL_ORDER.size()):
					if CANONICAL_WALL_ORDER[cursor] == wall_face:
						order_index = cursor
						break
				if order_index == -1:
					return "cell range wall surfaces must be unique and in canonical order"
				wall_cursor = order_index + 1
				expected_surfaces.append(["NEUTRAL_GAP_FILL", wall_face])
		else:
			if not surfaces is Array or surfaces.size() != EXPECTED_SURFACES.size():
				return "cell_geometry_ranges[%d] must declare exactly six canonical surfaces" % cell_ordinal
			expected_surfaces = EXPECTED_SURFACES
		for surface_ordinal in range(surfaces.size()):
			var surface: Variant = surfaces[surface_ordinal]
			if not surface is Dictionary:
				return "cell range surface must be a dictionary"
			if surface.get("role") != expected_surfaces[surface_ordinal][0] or surface.get("face") != expected_surfaces[surface_ordinal][1]:
				return "cell range surfaces are not in canonical order"
			for field_name in ["vertex_start", "vertex_count", "index_start", "index_count"]:
				if not _integer_value(surface.get(field_name)):
					return "cell range %s must be an integer" % field_name
			var vertex_start := int(surface["vertex_start"])
			var surface_vertex_count := int(surface["vertex_count"])
			var index_start := int(surface["index_start"])
			var surface_index_count := int(surface["index_count"])
			if vertex_start != next_vertex_start or index_start != next_index_start:
				return "cell geometry ranges overlap or leave gaps"
			if topology_policy == COMPLETE_EDGE_TOPOLOGY:
				if surface_vertex_count < 3 or surface_index_count < 3 or surface_index_count % 3 != 0:
					return "each complete-edge cell surface must declare at least three vertices and complete triangles"
			elif surface_vertex_count != 4 or surface_index_count != 6:
				return "each canonical cell surface must declare four vertices and six indices"
			if vertex_start + surface_vertex_count > vertex_count or index_start + surface_index_count > indices.size():
				return "cell geometry range is out of bounds"
			for index_offset in range(index_start, index_start + surface_index_count):
				var referenced_vertex := int(indices[index_offset])
				if referenced_vertex < vertex_start or referenced_vertex >= vertex_start + surface_vertex_count:
					return "cell geometry range references vertices outside its owned surface"
			if surface["face"] == "top":
				for vertex_ordinal in range(vertex_start, vertex_start + surface_vertex_count):
					if abs(float(positions[vertex_ordinal][1]) - float(world_cell["world_cell_y"])) > 0.000000001:
						return "world_cell_y contradicts the owned top-surface positions"
			if surface["role"] == "NEUTRAL_GAP_FILL":
				for vertex_ordinal in range(vertex_start, vertex_start + surface_vertex_count):
					if colors[vertex_ordinal] != gap_fill_color:
						return "neutral gap-fill colors contradict appearance.gap_fill_color"
			var geometry_error := _validate_surface_geometry(
				positions,
				normals,
				indices,
				vertex_start,
				surface_vertex_count,
				index_start,
				surface_index_count,
				surface["face"]
			)
			if not geometry_error.is_empty():
				return geometry_error
			next_vertex_start += surface_vertex_count
			next_index_start += surface_index_count
	if expected_row_width != -1 and current_row_width != expected_row_width:
		return "cell_geometry_ranges must form a rectangular field"
	if next_vertex_start != vertex_count or next_index_start != indices.size():
		return "cell geometry ranges do not cover all canonical geometry"
	if used_recipes.size() != recipe_references.size():
		return "appearance.recipe_references must exactly match recipes used by cells"
	for recipe in recipe_references:
		if not used_recipes.has(recipe):
			return "appearance.recipe_references contains an unused recipe"
	return ""


static func _validate_surface_geometry(
	positions: Array,
	normals: Array,
	indices: Array,
	vertex_start: int,
	surface_vertex_count: int,
	index_start: int,
	surface_index_count: int,
	face_name: String
) -> String:
	var used_vertices := {}
	var expected_normal := _expected_face_normal(face_name)
	for vertex_ordinal in range(vertex_start, vertex_start + surface_vertex_count):
		var declared_normal := _vector3(normals[vertex_ordinal])
		if abs(declared_normal.length() - 1.0) > 0.00001:
			return "canonical face normals must be unit length"
		if declared_normal.dot(expected_normal) < 0.99999:
			return "canonical face normal contradicts the declared face direction"
	for triangle_offset in range(0, surface_index_count, 3):
		var first := int(indices[index_start + triangle_offset])
		var second := int(indices[index_start + triangle_offset + 1])
		var third := int(indices[index_start + triangle_offset + 2])
		if first == second or second == third or first == third:
			return "canonical surface triangle must reference three distinct vertices"
		used_vertices[first] = true
		used_vertices[second] = true
		used_vertices[third] = true
		var edge_one := _vector3(positions[second]) - _vector3(positions[first])
		var edge_two := _vector3(positions[third]) - _vector3(positions[first])
		var winding_normal := edge_one.cross(edge_two)
		if winding_normal.length_squared() <= 0.000000000001:
			return "canonical surface triangle must not be degenerate"
		winding_normal = winding_normal.normalized()
		for vertex_ordinal in [first, second, third]:
			var declared_normal := _vector3(normals[vertex_ordinal])
			if winding_normal.dot(declared_normal) < 0.99999:
				return "triangle winding is incompatible with canonical face normals"
	if used_vertices.size() != surface_vertex_count:
		return "canonical surface indices must cover all owned vertices"
	return ""


static func _expected_face_normal(face_name: String) -> Vector3:
	match face_name:
		"top":
			return Vector3.UP
		"bottom":
			return Vector3.DOWN
		"-field_y":
			return Vector3.BACK
		"+field_x":
			return Vector3.RIGHT
		"+field_y":
			return Vector3.FORWARD
		"-field_x":
			return Vector3.LEFT
	return Vector3.ZERO


static func _validate_primitive_provenance(value: Variant, cell_ranges: Variant, triangle_count: int) -> String:
	if not value is Array or not cell_ranges is Array:
		return "primitive_provenance must be an array"
	var expected_records := 0
	for cell in cell_ranges:
		expected_records += cell["surfaces"].size()
	if value.size() != expected_records:
		return "primitive_provenance must contain one record per canonical surface"
	var next_primitive := 0
	var ordinal := 0
	for cell_ordinal in range(cell_ranges.size()):
		var cell: Dictionary = cell_ranges[cell_ordinal]
		var cell_surfaces: Array = cell["surfaces"]
		for face_ordinal in range(cell_surfaces.size()):
			var record: Variant = value[ordinal]
			if not record is Dictionary:
				return "primitive_provenance[%d] must be a dictionary" % ordinal
			for integer_field in ["source_cell_ordinal", "face_ordinal", "primitive_start", "primitive_count"]:
				if not _integer_value(record.get(integer_field)):
					return "primitive provenance %s must be an integer" % integer_field
			var surface: Dictionary = cell_surfaces[face_ordinal]
			var primitive_start := int(record["primitive_start"])
			var primitive_count := int(record["primitive_count"])
			var expected_start := int(surface["index_start"] / 3)
			var expected_count := int(surface["index_count"] / 3)
			if primitive_start != next_primitive or primitive_start != expected_start or primitive_count != expected_count:
				return "primitive provenance range contradicts its canonical cell surface"
			if int(record["source_cell_ordinal"]) != int(cell["source_cell_ordinal"]):
				return "primitive provenance source_cell_ordinal contradicts its cell range"
			if int(record["face_ordinal"]) != face_ordinal:
				return "primitive provenance face_ordinal contradicts canonical surface order"
			if record.get("cell_key") != cell["cell_key"]:
				return "primitive provenance cell_key contradicts its cell range"
			if record.get("role") != surface["role"] or record.get("face") != surface["face"]:
				return "primitive provenance identity contradicts its canonical cell surface"
			next_primitive += primitive_count
			ordinal += 1
	if next_primitive != triangle_count:
		return "primitive provenance does not cover every triangle"
	return ""


static func _validate_numeric_vector(value: Variant, expected_size: int, buffer_name: String, ordinal: int) -> String:
	if not value is Array or value.size() != expected_size:
		return "geometry.%s[%d] must contain %d numeric values" % [buffer_name, ordinal, expected_size]
	for component in value:
		if not _finite_number(component):
			return "geometry.%s[%d] contains a non-finite value" % [buffer_name, ordinal]
	return ""


static func _finite_number(value: Variant) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value))


static func _integer_value(value: Variant) -> bool:
	return _finite_number(value) and float(value) == floor(float(value))


static func _vector3(value: Array) -> Vector3:
	return Vector3(float(value[0]), float(value[1]), float(value[2]))


static func _valid_prefixed_hex_id(value: Variant, prefix: String) -> bool:
	if not value is String:
		return false
	var identity := String(value)
	if not identity.begins_with(prefix) or identity.length() != prefix.length() + 16:
		return false
	var suffix := identity.substr(prefix.length())
	for character in suffix:
		if not "0123456789abcdef".contains(character):
			return false
	return true


static func _nonempty_string(value: Variant) -> bool:
	return value is String and not String(value).is_empty()


static func _rejected(packet: Variant, source_sha256: String, error: String) -> Dictionary:
	return {
		"mesh": null,
		"arrays": null,
		"report": _report(packet, source_sha256, false, error),
	}


static func _report(packet: Variant, source_sha256: String, accepted: bool, error: Variant) -> Dictionary:
	var response_id: Variant = null
	var surface_id: Variant = null
	var response_status: Variant = null
	var vertex_count := 0
	var index_count := 0
	var cell_range_count := 0
	if packet is Dictionary:
		response_id = packet.get("request_id")
		surface_id = packet.get("surface_id")
		response_status = packet.get("status")
		if accepted:
			var geometry: Dictionary = packet["geometry"]
			vertex_count = geometry["positions"].size()
			index_count = geometry["indices"].size()
			cell_range_count = packet["cell_geometry_ranges"].size()
	return {
		"contract": REPORT_CONTRACT,
		"version": 1,
		"response_id": response_id,
		"surface_id": surface_id,
		"response_status": response_status,
		"result": "ACCEPTED" if accepted else "REJECTED",
		"first_blocking_error": error,
		"vertex_count": vertex_count,
		"index_count": index_count,
		"triangle_count": index_count / 3,
		"cell_range_count": cell_range_count,
		"mapped_godot_arrays": {
			"positions": {"godot_type": "PackedVector3Array", "length": vertex_count},
			"normals": {"godot_type": "PackedVector3Array", "length": vertex_count},
			"uvs": {"godot_type": "PackedVector2Array", "length": vertex_count},
			"colors": {"godot_type": "PackedColorArray", "length": vertex_count},
			"indices": {"godot_type": "PackedInt32Array", "length": index_count},
		},
		"passive_materialization_completed": accepted,
		"source_fixture_sha256": source_sha256,
	}
