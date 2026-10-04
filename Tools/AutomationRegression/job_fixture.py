"""Exercise incremental job progress and cancellation on two loaded plugins.

Run against disposable files in a fresh MO2-backed daemon. Validation can yield
within a file; use validation_step_fixture.py to require that behavior on a large
single-file input and verify cancellation with retained ITM findings.
"""
import argparse
import time
from pathlib import Path
from itm_fixture import Client
from validation_step_fixture import finish, findings, validate_progress


def advance(client, job_id):
    started = time.monotonic()
    state = client.call("jobs.get", jobId=job_id)
    return state, time.monotonic() - started


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--files", nargs=2, required=True)
    args = parser.parse_args()
    client = Client(args.exe, args.pid, args.artifacts)
    target = {"files": args.files}

    started = client.call("jobs.start", kind="validation.check_for_itm", target=target)
    assert started["state"] == "queued", started
    assert started["progress"] == {"completed": 0, "total": 2,
                                   "remaining": 2, "unit": "target-file",
                                   "nextFile": args.files[0]}, started
    first, elapsed = advance(client, started["jobId"])
    validate_progress(first)
    assert first["state"] == "running" and first["progress"]["completed"] in (0, 1), first
    assert first["progress"]["nextFile"] == args.files[first["progress"]["completed"]], first
    # The API must remain usable at the yield point and reject loaded-graph edits.
    client.call("session.get_dirty_state")
    denied = client.request('{"command":"session.save","args":{}}')
    assert denied["error"]["code"] == "job_busy", denied
    page = client.call("jobs.findings", jobId=started["jobId"], offset=0, limit=500)
    assert page["total"] == first["findingCount"], (page, first)
    retained = findings(client, started["jobId"])
    canceled = client.call("jobs.cancel", jobId=started["jobId"])
    assert canceled["state"] == "canceled", canceled
    assert canceled["progress"] == first["progress"], canceled
    assert findings(client, started["jobId"]) == retained
    assert client.call("jobs.get", jobId=started["jobId"])["state"] == "canceled"

    restarted = client.call("jobs.start", kind="validation.check_for_itm", target=target)
    timings = []
    two = finish(client, restarted["jobId"], timings)
    assert two["state"] == "succeeded" and two["progress"]["completed"] == 2, two
    assert two["summary"]["fileCount"] == 2, two
    assert len(two["result"]["files"]) == 2, two
    assert two["findingCount"] == two["summary"]["findingCount"], two
    print(f"first traversal step: {elapsed:.3f}s; {len(timings)} restart polls; cancel and complete transitions passed")
    client.call("jobs.discard", jobId=started["jobId"])
    client.call("jobs.discard", jobId=restarted["jobId"])


if __name__ == "__main__":
    main()
