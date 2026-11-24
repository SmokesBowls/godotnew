extends SceneTree
## T02 probe, driven by tests/t02_signed_request_check.py. Calls the ported
## EngAInSignedRequest with credentials named by T02_* environment variables and
## prints one JSON line (prefixed T02_RESULT) for the Python side to verify.

const SignedRequest = preload("res://scripts/EngAInSignedRequest.gd")
const CASES := ["valid", "missing_id", "missing_key_env", "missing_file", "short_key", "non_hex_key", "empty_key"]
const REQUESTS := [
	["POST", "/trixel32d/consume", "{\"a\":1}"],
	["post", "/presentation/observation", ""],
	["GET", "/trixel32d/build", "{\"name\":\"Ǣlfrēd — ✓\"}"],
]


func _initialize() -> void:
	var loaded := {}
	for case_name in CASES:
		var prefix := "T02_%s_" % case_name.to_upper()
		var credential: Dictionary = SignedRequest.load_credential(prefix + "ID", prefix + "KEY")
		loaded[case_name] = {} if credential.is_empty() else {
			"client_id": credential["client_id"], "secret_hex": (credential["secret"] as PackedByteArray).hex_encode()}
	var signed: Array = []
	var valid: Dictionary = SignedRequest.load_credential("T02_VALID_ID", "T02_VALID_KEY")
	if not valid.is_empty():
		for r in REQUESTS:
			signed.append({"method": r[0], "path": r[1], "body": r[2],
				"headers": Array(SignedRequest.headers(valid, r[0], r[1], r[2]))})
	print("T02_RESULT " + JSON.stringify({"loaded": loaded, "signed": signed}))
	quit(0)
