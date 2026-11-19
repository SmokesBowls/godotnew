extends Control
## G01 chapter selector. Shows Tier 1's live catalog (GET 8765 /chapters/catalog) and nothing else.
## No cache: the list is fetched when the selector opens and on every Refresh, and cleared on any
## failure so a stale list is never shown as current. Godot decides nothing about the catalog.

const DEFAULT_BASE_URL := "http://127.0.0.1:8765"
const CATALOG_PATH := "/chapters/catalog"
const FLAG_COLOR := Color(1.0, 0.72, 0.3)

var base_url: String = OS.get_environment("ENGAIN_TIER1_URL") if OS.has_environment("ENGAIN_TIER1_URL") else DEFAULT_BASE_URL
var _selftest := OS.get_cmdline_user_args().has("--selftest")

var _http: HTTPRequest
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

	if _selftest:
		var ok := shown == int(catalog.get("chapter_count", -1))
		print("[selftest] vault=%s books=%d chapters=%d tree_items=%d %s" % [
			vault.get("vault_id"), catalog.get("book_count"), catalog.get("chapter_count"), shown, "OK" if ok else "MISMATCH"])
		get_tree().quit(0 if ok else 1)


func _fail(message: String) -> void:
	_refresh.disabled = false
	_tree.clear()  # never leave a previous list on screen as if it were current
	_summary.text = "No catalog"
	_status.text = message
	_detail.text = ""
	if _selftest:
		print("[selftest] FAIL: ", message)
		get_tree().quit(1)


func _on_item_selected() -> void:
	var item := _tree.get_selected()
	var entry: Variant = item.get_metadata(0) if item else null
	if not entry is Dictionary:
		return
	var flags: Array = entry.get("anomalies", [])
	_detail.text = "\n".join(PackedStringArray([
		"[b]%s[/b]" % entry.get("file_name"),
		"",
		"catalog_id:     %s" % entry.get("catalog_id"),
		"chapter_id:     %s  (legacy)" % entry.get("chapter_id"),
		"leading_number: %s" % str(entry.get("leading_number")),
		"anomalies:      %s" % (", ".join(PackedStringArray(flags)) if not flags.is_empty() else "none"),
		"source_sha256:  %s" % entry.get("source_sha256"),
		"path:           %s" % entry.get("path"),
	]))


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

	_detail = RichTextLabel.new()
	_detail.bbcode_enabled = true
	_detail.selection_enabled = true
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail.custom_minimum_size = Vector2(420, 0)
	split.add_child(_detail)
