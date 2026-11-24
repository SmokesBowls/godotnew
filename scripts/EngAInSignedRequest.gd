extends RefCounted

## Client side of EngAIn's local signed-request transport
## (EngAIn tier1/engainos/authority/local_signed_transport.py).
##
## A credential is a transport *binding* (client id + 32-byte secret) minted by
## the EngAIn server at its start and handed to this process through the launch
## environment. It identifies the client, never an actor or a tier. Nothing here
## is persisted in the project.

const HEADER_CLIENT := "X-EngAIn-Client"
const HEADER_TIMESTAMP := "X-EngAIn-Timestamp"
const HEADER_NONCE := "X-EngAIn-Nonce"
const HEADER_SIGNATURE := "X-EngAIn-Signature"


## Returns {"client_id": String, "secret": PackedByteArray}, or {} when not configured.
static func load_credential(client_id_env: String, key_file_env: String) -> Dictionary:
	var client_id := OS.get_environment(client_id_env).strip_edges()
	var key_file := OS.get_environment(key_file_env).strip_edges()
	if client_id.is_empty() or key_file.is_empty() or not FileAccess.file_exists(key_file):
		return {}
	var secret := FileAccess.get_file_as_string(key_file).strip_edges().hex_decode()
	if secret.size() != 32:
		return {}
	return {"client_id": client_id, "secret": secret}


## Signs METHOD \n PATH \n TIMESTAMP \n NONCE \n hex(sha256(body)) with HMAC-SHA256.
static func headers(credential: Dictionary, method: String, path: String, body: String) -> PackedStringArray:
	var crypto := Crypto.new()
	var timestamp := str(int(Time.get_unix_time_from_system()))
	var nonce := crypto.generate_random_bytes(16).hex_encode()
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(body.to_utf8_buffer())
	var message := "%s\n%s\n%s\n%s\n%s" % [method.to_upper(), path, timestamp, nonce, hashing.finish().hex_encode()]
	var signature := crypto.hmac_digest(HashingContext.HASH_SHA256, credential["secret"], message.to_utf8_buffer()).hex_encode()
	return PackedStringArray([
		"Content-Type: application/json",
		"%s: %s" % [HEADER_CLIENT, credential["client_id"]],
		"%s: %s" % [HEADER_TIMESTAMP, timestamp],
		"%s: %s" % [HEADER_NONCE, nonce],
		"%s: %s" % [HEADER_SIGNATURE, signature],
	])
