"""Readiness/save/flush and fresh-process checks with reproducible provenance."""
import argparse
import hashlib
import json
from pathlib import Path
import time
from itm_fixture import Client


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument("phase", choices=("ready", "finish", "readback"))
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--file", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--build-log", type=Path, required=True)
    parser.add_argument("--previous-run", type=Path)
    args = parser.parse_args()
    transcript = args.build_log.read_text(encoding="utf-8-sig", errors="replace")
    assert "LiteDebug, Win32" in transcript, "Reject unverified build configuration"
    client = Client(args.exe, args.pid, args.artifacts)
    evidence = {"pid": args.pid, "commit": args.commit, "phase": args.phase,
                "executable": str(args.exe.resolve()),
                "sha256": hashlib.sha256(args.exe.read_bytes()).hexdigest(),
                "buildLogSha256": hashlib.sha256(args.build_log.read_bytes()).hexdigest()}
    if args.phase == "ready":
        deadline = time.monotonic() + 300
        while True:
            try:
                assert client.call("system.ping")["status"] == "ok"
                loaded = client.call("files.list")
                assert any(f["fileName"].casefold() == args.file.casefold()
                           for f in loaded["files"]), loaded
                break
            except (RuntimeError, AssertionError):
                if time.monotonic() >= deadline:
                    raise
                time.sleep(1)
        evidence["capabilities"] = client.call("system.capabilities")
        evidence["loadedFiles"] = loaded
    elif args.phase == "finish":
        evidence["save"] = client.call("session.save", files=[args.file])
        assert not client.call("session.get_dirty_state")["dirty"]
        evidence["flush"] = client.call("session.flush")
        assert evidence["flush"]["pendingRemainingCount"] == 0
        # Flush is terminal. Readback requires an external MO2 relaunch.
    else:
        assert args.previous_run, "Supply finish-run metadata to prove a fresh process"
        previous = json.loads(args.previous_run.read_text(encoding="utf-8"))
        assert previous["phase"] == "finish"
        assert previous["pid"] != args.pid, "Readback must use a fresh daemon PID"
        assert previous["sha256"] == evidence["sha256"], "Executable changed between phases"
        evidence["records"] = client.call("records.list", file=args.file)
        assert not evidence["records"]["truncated"], "Use the pagination runner for large fixtures"
        assert not client.call("session.get_dirty_state")["dirty"]
    (args.artifacts / "run.json").write_text(json.dumps(evidence, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
