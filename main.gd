extends Control
## G01 chapter selector. Shows Tier 1's live catalog (GET 8765 /chapters/catalog) and, for a selected
## chapter, its Mettaext extraction (GET 8765 /chapters/extraction) labelled as a candidate (M01c).
## No cache: the list is fetched when the selector opens and on every Refresh, and cleared on any
## failure so a stale list is never shown as current. Godot decides nothing about the catalog.
## S03a: a candidate's first game scene is drawn in a static 3D view as placeholder capsules, styled
## by the active asset pack (GET 8765 /assets/active). Missing extraction and missing asset pack are
## separate states: no candidate -> nothing drawn; no pack -> labelled built-in capsules.

const DEFAULT_BASE_URL := "http://127.0.0.1:8765"
const CATALOG_PATH := "/chapters/catalog"
const EXTRACTION_PATH := "/chapters/extraction"
const ASSETS_PATH := "/assets/active"
const FLAG_COLOR := Color(1.0, 0.72, 0.3)

var base_url: String = OS.get_environment("ENGAIN_TIER1_URL") if OS.has_environment("ENGAIN_TIER1_URL") else DEFAULT_BASE_URL
var _selftest := OS.get_cmdline_user_args().has("--selftest")
## --extract-check=<catalog_id>: with --selftest, also fetch that chapter's extraction and print it.
var _extract_check := ""
## --screenshot=<png path>: with --extract-check, save the window once the scene is drawn (needs a display).
var _screenshot := ""

var _http: HTTPRequest
var _xhttp: HTTPRequest  # extraction requests; separate so a catalog refresh never collides
var _x_catalog_id := ""
var _x_entry_text := ""
var _x_reply: Variant = null  # {code, data} of the current selection's extraction answer
var _a_reply: Variant = null  # resolved asset pack for the current selection
var _ahttp: HTTPRequest
var _scene_view: Node
var _summary: Label
var _status: Label
var _refresh: Button
var _tree: Tree
var _detail: RichTextLabel


func _ready() -> void:
	_build_ui()
	_http = HTTPRequest.new()
	_http.timeout = 15.0
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)
	_xhttp = HTTPRequest.new()
	_xhttp.timeout = 15.0
	add_child(_xhttp)
	_xhttp.request_completed.connect(_on_extraction_completed)
	_ahttp = HTTPRequest.new()
	_ahttp.timeout = 15.0
	add_child(_ahttp)
	_ahttp.request_completed.connect(_on_assets_completed)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--extract-check="):
			_extract_check = arg.trim_prefix("--extract-check=")
		elif arg.begins_with("--screenshot="):
			_screenshot = arg.trim_prefix("--screenshot=")
	refresh()


func refresh() -> void:
	if _http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		return  # a request is already in flight
	_refresh.disabled = true
	_status.text = "Loading %s%s ..." % [base_url, CATALOG_PATH]
	var err := _http.request(base_url + CATALOG_PATH)
	if err != OK:
		_fail("Could not start request (error %d)" % err)


func _on_request_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_refresh.disabled = false
	if result != HTTPRequest.RESULT_SUCCESS:
		_fail("8765 unreachable (HTTPRequest result %d)" % result)
		return
	var data: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not data is Dictionary:
		_fail("HTTP %d: response is not a JSON object" % code)
		return
	if code != 200 or not (data as Dictionary).has("catalog"):
		var problems: Array = (data.get("vault", {}) as Dictionary).get("problems", [])
		_fail("HTTP %d: vault not resolved by Tier 1. %s" % [code, "; ".join(PackedStringArray(problems))])
		return
	_show_catalog(data["vault"], data["catalog"])


func _show_catalog(vault: Dictionary, catalog: Dictionary) -> void:
	_tree.clear()
	var root := _tree.create_item()
	var shown := 0
	for book: Dictionary in catalog.get("books", []):
		var chapters: Array = book.get("chapters", [])
		var book_item := _tree.create_item(root)
		book_item.set_text(0, "%s  (%d)" % [book.get("book_id", "?"), chapters.size()])
		book_item.set_selectable(0, false)
		book_item.set_selectable(1, false)
		book_item.collapsed = true
		for entry: Dictionary in chapters:
			var item := _tree.create_item(book_item)
			item.set_text(0, str(entry.get("file_name", "?")))
			item.set_metadata(0, entry)
			var flags: Array = entry.get("anomalies", [])
			if not flags.is_empty():
				item.set_text(1, ", ".join(PackedStringArray(flags)))
				item.set_custom_color(0, FLAG_COLOR)
				item.set_custom_color(1, FLAG_COLOR)
			shown += 1

	var md: Dictionary = catalog.get("manifest_discrepancies", {})
	_summary.text = "Vault: %s   |   %d books, %d chapters   |   flags: %s   |   vault manifest: %d listed-missing, %d unlisted" % [
		vault.get("vault_id", "?"), catalog.get("book_count", 0), catalog.get("chapter_count", 0),
		_format_counts(catalog.get("anomaly_counts", {})),
		(md.get("listed_but_missing", []) as Array).size(), (md.get("on_disk_but_unlisted", []) as Array).size()]
	_status.text = "Loaded %s from %s%s   (root: %s, via %s)" % [
		Time.get_time_string_from_system(), base_url, CATALOG_PATH, vault.get("root", "?"),
		(vault.get("authority_fields", {}) as Dictionary).get("root", "?")]
	_detail.text = "Select a chapter file to see its catalog entry."
	_scene_view.show_message("Select a chapter to view its extracted entities.")

	if _selftest:
		var ok := shown == int(catalog.get("chapter_count", -1))
		print("[selftest] vault=%s books=%d chapters=%d tree_items=%d %s" % [
			vault.get("vault_id"), catalog.get("book_count"), catalog.get("chapter_count"), shown, "OK" if ok else "MISMATCH"])
		if not ok or _extract_check.is_empty():
			get_tree().quit(0 if ok else 1)
		else:
			_request_extraction(_extract_check)


func _fail(message: String) -> void:
	_refresh.disabled = false
	_tree.clear()  # never leave a previous list on screen as if it were current
	_summary.text = "No catalog"
	_status.text = message
	_detail.text = ""
	_scene_view.show_message("No catalog.")
	if _selftest:
		print("[selftest] FAIL: ", message)
		get_tree().quit(1)


func _on_item_selected() -> void:
	var item := _tree.get_selected()
	var entry: Variant = item.get_metadata(0) if item else null
	if not entry is Dictionary:
		return
	var flags: Array = entry.get("anomalies", [])
	_x_entry_text = "\n".join(PackedStringArray([
		"[b]%s[/b]" % entry.get("file_name"),
		"",
		"catalog_id:     %s" % entry.get("catalog_id"),
		"chapter_id:     %s  (legacy)" % entry.get("chapter_id"),
		"leading_number: %s" % ("none" if entry.get("leading_number") == null else str(int(entry.get("leading_number")))),
		"anomalies:      %s" % (", ".join(PackedStringArray(flags)) if not flags.is_empty() else "none"),
		"source_sha256:  %s" % entry.get("source_sha256"),
		"path:           %s" % entry.get("path"),
	]))
	_request_extraction(str(entry.get("catalog_id")))


func _request_extraction(catalog_id: String) -> void:
	_xhttp.cancel_request()  # a newer selection replaces any request still in flight
	_ahttp.cancel_request()
	_x_catalog_id = catalog_id
	_x_reply = null
	_a_reply = null
	_scene_view.show_message("Loading %s ..." % catalog_id)
	if _ahttp.request(base_url + ASSETS_PATH) != OK:
		_a_reply = {"ok": false, "problems": ["could not start /assets/active request"]}
	_detail.text = _x_entry_text + "\n\n[b]Mettaext extraction[/b]\nLoading ..."
	var err := _xhttp.request("%s%s?catalog_id=%s" % [base_url, EXTRACTION_PATH, catalog_id.uri_encode()])
	if err != OK:
		_show_extraction("[color=#ff8080]Could not start request (error %d)[/color]" % err)
		_x_reply = {"code": 0, "data": {"extraction": "request_not_started"}}
		_try_render()


func _on_extraction_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		_show_extraction("[color=#ff8080]8765 unreachable (HTTPRequest result %d)[/color]" % result)
		_x_reply = {"code": 0, "data": {"extraction": "8765 unreachable"}}
		_try_render()
		return
	var data: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not data is Dictionary:
		_show_extraction("[color=#ff8080]HTTP %d: response is not a JSON object[/color]" % code)
		_x_reply = {"code": code, "data": {"extraction": "invalid response"}}
		_try_render()
		return
	var d: Dictionary = data
	if str(d.get("catalog_id", _x_catalog_id)) != _x_catalog_id:
		return  # answer for an older selection
	var state := str(d.get("extraction", ""))
	var lines := PackedStringArray()
	match state:
		"candidate":
			lines.append("[color=#ffb84d][b]CANDIDATE — not accepted[/b][/color]  (Mettaext output, display only)")
			lines.append_array(_receipt_lines(d.get("receipt", {})))
			var scenes: Dictionary = d.get("game_scenes", {})
			for rel in scenes:
				lines.append_array(_scene_lines(rel, scenes[rel]))
		"failed":
			lines.append("[color=#ff8080][b]Extraction FAILED[/b][/color]  (returncode %s; see run.log beside the receipt)" % str((d.get("receipt", {}) as Dictionary).get("returncode")))
		"not_extracted":
			lines.append("Not extracted yet. Run:")
			lines.append("python3 -m tier1.engainos.tools.run_chapter_extraction --catalog-id \"%s\"" % _x_catalog_id)
		"stale":
			lines.append("[color=#ffb84d]Stale:[/color] the chapter changed after its last extraction; no output is shown for the current text.")
			for prev in d.get("previous", []):
				lines.append("  earlier run: source %s  (%s)" % [str(prev.get("source_sha256", "?")).left(12), prev.get("status", "?")])
			lines.append("Re-run the extraction command for this catalog_id.")
		_:
			lines.append("[color=#ff8080]HTTP %d: %s[/color]" % [code, str(d.get("extraction", d.get("message", "error")))])
	_show_extraction("\n".join(lines))
	_x_reply = {"code": code, "data": d}
	_try_render()


func _on_assets_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var data: Variant = JSON.parse_string(body.get_string_from_utf8()) if result == HTTPRequest.RESULT_SUCCESS else null
	var pack: Dictionary = (data as Dictionary).get("asset_pack", {}) if data is Dictionary else {}
	if result != HTTPRequest.RESULT_SUCCESS:
		_a_reply = {"ok": false, "problems": ["8765 unreachable (HTTPRequest result %d)" % result]}
	elif code == 200 and pack.get("status") == "ok" and pack.get("manifest") is Dictionary:
		_a_reply = {"ok": true, "pack_id": pack.get("asset_pack_id"), "manifest": pack["manifest"]}
	else:
		var problems: Array = pack.get("problems", []) if not pack.is_empty() else ["HTTP %d from %s" % [code, ASSETS_PATH]]
		_a_reply = {"ok": false, "problems": problems}
	_try_render()


## Draws only when both answers for the current selection are in. Only a candidate is drawn.
func _try_render() -> void:
	if _x_reply == null or _a_reply == null:
		return
	var code: int = _x_reply.code
	var d: Dictionary = _x_reply.data
	var state := str(d.get("extraction", ""))
	var scenes: Dictionary = d.get("game_scenes", {}) if state == "candidate" else {}
	var stats := {}
	if scenes.is_empty():
		_scene_view.show_message("[color=#ff8080][b]No scene drawn[/b][/color] — extraction %s (HTTP %d). Nothing here is accepted or placed." % [
			state if not state.is_empty() else "unavailable", code])
	else:
		var keys := scenes.keys()
		keys.sort()
		# shortcut: draws the first game scene only (every current chapter has one); add a scene picker when one has more.
		var label := "%s%s" % [keys[0], "  (1 of %d scenes)" % keys.size() if keys.size() > 1 else ""]
		stats = _scene_view.render(scenes[keys[0]], label, _a_reply)
	if _selftest and not _extract_check.is_empty():
		print("[selftest] extraction catalog_id=%s http=%d state=%s scenes=%d" % [_x_catalog_id, code, state, scenes.size() if state == "candidate" else (d.get("game_scenes", {}) as Dictionary).size()])
		print("[selftest] render actors=%d assets=%s ids=%s skipped_missing_position=%d" % [
			_scene_view.actor_count(), str(_a_reply.get("pack_id")) if _a_reply.ok else "unavailable",
			",".join(PackedStringArray(stats.get("ids", []))), int(stats.get("skipped_missing_position", 0))])
		if not _screenshot.is_empty():
			for i in 4:
				await RenderingServer.frame_post_draw
			var err := get_viewport().get_texture().get_image().save_png(_screenshot)
			print("[selftest] screenshot %s %s" % [_screenshot, "saved" if err == OK else "FAILED %d" % err])
		get_tree().quit(0 if code in [200, 404] else 1)


func _show_extraction(text: String) -> void:
	_detail.text = _x_entry_text + "\n\n[b]Mettaext extraction[/b]\n" + text


func _receipt_lines(r: Dictionary) -> PackedStringArray:
	var ex: Dictionary = r.get("extractor", {})
	return PackedStringArray([
		"source_sha256:  %s" % str(r.get("source_sha256", "?")),
		"extracted:      %s UTC" % Time.get_datetime_string_from_unix_time(int(r.get("finished_at", 0)), true),
		"engain commit:  %s%s" % [str(ex.get("git_head", "?")).left(12), "  (mettaext dirty)" if ex.get("mettaext_dirty", false) else ""],
		"driver:         %s" % str(ex.get("driver", "?")),
	])


func _scene_lines(rel: String, scene: Dictionary) -> PackedStringArray:
	var meta: Dictionary = scene.get("metadata", {})
	var out := PackedStringArray(["", "[b]%s[/b]  (%s)" % [scene.get("scene_id", "?"), rel],
		"where: %s" % str(meta.get("where", "?")), "when:  %s" % str(meta.get("when", "?")),
		"description: %s" % str(scene.get("description", ""))])
	var ents: Array = scene.get("entities", [])
	out.append("entities (%d):" % ents.size())
	for e in ents:
		if e is Dictionary:
			out.append("  • %s  [%s]  id=%s" % [e.get("name", "?"), e.get("type", "?"), e.get("id", "?")])
	var events: Array = scene.get("events", [])
	out.append("events (%d):" % events.size())
	for ev in events.slice(0, 12):
		out.append("  • %s" % (JSON.stringify(ev) if not ev is String else ev).left(140))
	var locs: Array = scene.get("locations", [])
	out.append("locations (%d): %s" % [locs.size(), JSON.stringify(locs).left(200)])
	return out


func _format_counts(counts: Dictionary) -> String:
	var parts := PackedStringArray()
	for key in counts:
		parts.append("%s %d" % [key, counts[key]])
	return ", ".join(parts) if not parts.is_empty() else "none"


func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	add_child(margin)

	var column := VBoxContainer.new()
	margin.add_child(column)

	var header := HBoxContainer.new()
	column.add_child(header)
	_refresh = Button.new()
	_refresh.text = "Refresh"
	_refresh.pressed.connect(refresh)
	header.add_child(_refresh)
	_summary = Label.new()
	_summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary.text = "No catalog"
	header.add_child(_summary)

	_status = Label.new()
	_status.modulate = Color(1, 1, 1, 0.7)
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	column.add_child(_status)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(split)

	_tree = Tree.new()
	_tree.columns = 2
	_tree.hide_root = true
	_tree.column_titles_visible = true
	_tree.set_column_title(0, "Book / chapter file")
	_tree.set_column_title(1, "Flags")
	_tree.set_column_expand_ratio(0, 3)
	_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tree.size_flags_stretch_ratio = 1.4
	_tree.item_selected.connect(_on_item_selected)
	split.add_child(_tree)

	var right := VSplitContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_stretch_ratio = 1.6
	split.add_child(right)
	_scene_view = preload("res://scene_view.gd").new()
	_scene_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scene_view.size_flags_stretch_ratio = 1.4
	right.add_child(_scene_view)

	_detail = RichTextLabel.new()
	_detail.bbcode_enabled = true
	_detail.selection_enabled = true
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail.custom_minimum_size = Vector2(420, 160)
	_detail.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(_detail)
