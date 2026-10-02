"""Wire boundary and lost-response replay checks against an existing MO2 daemon."""
import argparse
import json
from pathlib import Path
import subprocess
from itm_fixture import Client

LIMIT = 4 * 1024 * 1024


def padded_ping(size):
    base = json.dumps({"command": "system.ping", "args": {"padding": "é"}},
                      ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    # Trailing JSON whitespace counts toward encoded admission without changing
    # the ping itself, including a multibyte code point at the byte boundary.
    assert size >= len(base)
    return base + b" " * (size - len(base))


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    args = parser.parse_args()
    client = Client(args.exe, args.pid, args.artifacts)
    probe = Path(__file__).with_name("pipe_probe.ps1")

    def raw(name, data, mode="call"):
        request = args.artifacts / f"{name}.raw.request.json"
        response = args.artifacts / f"{name}.raw.response.json"
        request.write_bytes(data)
        subprocess.run(["powershell", "-NoProfile", "-File", str(probe.resolve()),
                        "-DaemonPid", str(args.pid), "-Request", str(request.resolve()),
                        "-Response", str(response.resolve()), "-Mode", mode],
                       check=True, timeout=85)
        return json.loads(response.read_bytes()) if mode == "call" else None

    assert raw("limit", padded_ping(LIMIT))["ok"]
    oversized = raw("limit-plus-one", padded_ping(LIMIT + 1))
    assert oversized["error"]["code"] == "request_too_large", oversized
    assert oversized["error"]["details"]["executed"] is False
    for mode in ("stall", "no-read"):
        raw(mode, padded_ping(100), mode)
        assert client.call("system.ping") is not None  # next exchange remains usable
    request = json.dumps({"command": "records.create", "idempotencyKey": "fixture-create-once",
                          "requestId": "stable", "args": {"targetFile": "AutomationStringValues.esp",
                          "signature": "KYWD", "editorId": "AutomationReplayCreated"}},
                         separators=(",", ":"))
    raw("lost-create", request.encode("utf-8"), "disconnect")
    replay = client.request(request)
    assert replay["ok"], replay
    assert client.request(request) == replay
    conflict = client.request(request + " ")
    assert conflict["error"]["code"] == "idempotency_conflict", conflict
    records = client.call("records.list", file="AutomationStringValues.esp", signature="KYWD")
    assert not records["truncated"], records
    assert sum(r["object"].get("editorId") == "AutomationReplayCreated"
               for r in records["records"]) == 1, records
    client.call("session.save", files=["AutomationStringValues.esp"])
    client.call("session.flush")


if __name__ == "__main__":
    main()
