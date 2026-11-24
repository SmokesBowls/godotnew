#!/usr/bin/env python3
"""T02: the ported scripts/EngAInSignedRequest.gd against EngAIn's own transport.

Credentials are minted by EngAIn's provision_credentials into a throwaway temp dir
(never the project), and every Godot signature is checked by EngAIn's
SignedRequestVerifier. Nothing is reimplemented here.

Usage: python3 tests/t02_signed_request_check.py   (needs `godot` on PATH and an EngAIn
checkout: ENGAIN_ROOT, default ~/Desktop/burdens_of_a_forgotten_past/EngAIn; exit 0 = pass)
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
ENGAIN = Path(os.environ.get("ENGAIN_ROOT", Path.home() / "Desktop/burdens_of_a_forgotten_past/EngAIn"))
sys.path.insert(0, str(ENGAIN))
from tier1.engainos.authority.local_signed_transport import (  # noqa: E402
    SignedRequestVerifier, TransportAuthError, provision_credentials)

CLIENT = "t02-test-client"
failures = []


def check(ok, label):
    print(("PASS " if ok else "FAIL ") + label)
    if not ok:
        failures.append(label)


def rejects(verifier, method, path, headers, body, label):
    try:
        verifier.verify(method, path, headers, body)
        check(False, label)
    except TransportAuthError:
        check(True, label)


with tempfile.TemporaryDirectory(prefix="t02_creds_") as tmp:
    tmp = Path(tmp)
    secret = provision_credentials(tmp / "keys", [CLIENT])[CLIENT]
    key = tmp / "keys" / f"{CLIENT}.key"
    (tmp / "short.key").write_text(secret.hex()[:62])
    (tmp / "nonhex.key").write_text("zz" * 32)
    (tmp / "empty.key").write_text("")
    env = dict(os.environ,
               T02_VALID_ID=CLIENT, T02_VALID_KEY=str(key),
               T02_MISSING_ID_KEY=str(key),
               T02_MISSING_KEY_ENV_ID=CLIENT,
               T02_MISSING_FILE_ID=CLIENT, T02_MISSING_FILE_KEY=str(tmp / "absent.key"),
               T02_SHORT_KEY_ID=CLIENT, T02_SHORT_KEY_KEY=str(tmp / "short.key"),
               T02_NON_HEX_KEY_ID=CLIENT, T02_NON_HEX_KEY_KEY=str(tmp / "nonhex.key"),
               T02_EMPTY_KEY_ID=CLIENT, T02_EMPTY_KEY_KEY=str(tmp / "empty.key"))
    out = subprocess.run(["godot", "--headless", "--path", str(PROJECT), "--script", "res://tests/t02_signed_request_check.gd"],
                         env=env, capture_output=True, text=True, timeout=120)
    line = next((l for l in out.stdout.splitlines() if l.startswith("T02_RESULT ")), None)
    check(out.returncode == 0 and line is not None, "godot probe ran (exit %d)" % out.returncode)
    if line is None:
        print(out.stdout[-2000:], out.stderr[-2000:])
        sys.exit(1)
    result = json.loads(line[len("T02_RESULT "):])

    loaded = result["loaded"]
    check(loaded["valid"] == {"client_id": CLIENT, "secret_hex": secret.hex()}, "valid credential loads the provisioned secret")
    for case in ("missing_id", "missing_key_env", "missing_file", "short_key", "empty_key"):
        check(loaded[case] == {}, f"{case} credential is rejected")
    # Recorded, not fixed here: see the T02 receipt if this one fails.
    check(loaded["non_hex_key"] == {}, "non_hex_key credential is rejected")

    verifier = SignedRequestVerifier({CLIENT: secret})
    check(len(result["signed"]) == 3, "three requests signed")
    for req in result["signed"]:
        headers = dict(h.split(": ", 1) for h in req["headers"])
        body = req["body"].encode("utf-8")
        label = f"{req['method']} {req['path']}"
        rejects(verifier, req["method"], req["path"], headers, body + b" ", f"{label}: tampered body is refused")
        rejects(verifier, req["method"], req["path"] + "x", headers, body, f"{label}: other path is refused")
        try:
            check(verifier.verify(req["method"], req["path"], headers, body) == CLIENT, f"{label}: EngAIn verifies Godot's signature")
        except TransportAuthError as exc:
            check(False, f"{label}: EngAIn verifies Godot's signature ({exc})")
        rejects(verifier, req["method"], req["path"], headers, body, f"{label}: replay is refused")
        rejects(SignedRequestVerifier({CLIENT: bytes(32)}), req["method"], req["path"], headers, body,
                f"{label}: wrong secret is refused")

print("T02: %d failure(s)" % len(failures))
sys.exit(1 if failures else 0)
