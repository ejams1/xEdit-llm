"""FO4 copy-before-clean injected-reference scene with fresh-process readback."""
import argparse
from pathlib import Path
import struct
from itm_fixture import Client, record, subrecord
from circular_fixture import leveled_record
from formid_fixture import plugin

BASE = "AutomationInjectedBase.esm"
PROVIDER = "AutomationInjectedProvider.esp"


def fixtures():
    # Base references a missing identity in its own slot. The later provider
    # injects that identity, allowing xEdit to resolve an otherwise illegal link.
    body = subrecord(b"EDID", b"AutoInjectedReferrer\0") + subrecord(b"OBND", b"\0" * 12)
    body += subrecord(b"LVLD", b"\0") + subrecord(b"LVLF", b"\0") + subrecord(b"LLCT", b"\2")
    for level, target in ((1, 0x01000900), (2, 0x01000801)):
        body += subrecord(b"LVLO", struct.pack("<HHIHBB", level, 0, target, 1, 0, 0))
    base = record(b"LVLI", body, form_id=0x01000800)
    base += leveled_record(b"LVLI", "AutoInjectedUnrelated", 0x01000801)
    injected = leveled_record(b"LVLI", "AutoInjectedPayload", 0x01000900)
    return {BASE: plugin(["Fallout4.esm"], base, 2, True),
            PROVIDER: plugin(["Fallout4.esm", BASE], injected, 1)}


def discover(client, file):
    listing = client.call("records.list", file=file, signature="LVLI", limit=50)
    assert not listing["truncated"], listing
    return {item["object"]["editorId"]: item["locator"] for item in listing["records"]}


def refs(client, locator):
    return {item["locator"]["formId"] for item in
            client.call("records.references", **locator, limit=50)["hits"]}


def verify(client):
    base, provider = discover(client, BASE), discover(client, PROVIDER)
    source = base["AutoInjectedReferrer"]
    preserved = provider["AutoInjectedReferrer"]
    injected = provider["AutoInjectedPayload"]["formId"]
    unrelated = base["AutoInjectedUnrelated"]["formId"]
    assert source["formId"] == preserved["formId"], (source, preserved)
    assert refs(client, source) == {unrelated}, refs(client, source)
    assert refs(client, preserved) == {injected, unrelated}, refs(client, preserved)
    assert client.call("elements.children", **{**source, "path": "Leveled List Entries"}, limit=50)["total"] == 1
    assert client.call("elements.children", **{**preserved, "path": "Leveled List Entries"}, limit=50)["total"] == 2


def start(client, source, dry_run):
    job = client.call("jobs.start", kind="cleaning.cleanup_injected_references",
                      dryRun=dry_run, target={"files": [BASE]},
                      options={"records": [source], "injectionFile": PROVIDER})
    for _ in range(1000):
        job = client.call("jobs.get", jobId=job["jobId"])
        if job["terminal"]:
            break
    assert job["state"] == "succeeded", job
    findings = client.call("jobs.findings", jobId=job["jobId"], limit=50)["findings"]
    client.call("jobs.discard", jobId=job["jobId"])
    return job, findings


def exercise(client):
    base, provider = discover(client, BASE), discover(client, PROVIDER)
    source = base["AutoInjectedReferrer"]
    before_refs = refs(client, source)
    assert before_refs == {base["AutoInjectedUnrelated"]["formId"], provider["AutoInjectedPayload"]["formId"]}
    before = client.call("session.get_dirty_state")
    planned, findings = start(client, source, True)
    assert planned["summary"]["planned"] == 1 and planned["summary"]["applied"] == 0, planned
    assert findings[0]["code"] == "injected_cleanup_planned", findings
    assert findings[0]["injectionFile"] == PROVIDER, findings
    assert refs(client, source) == before_refs
    after = client.call("session.get_dirty_state")
    assert before["mutationRevision"] == after["mutationRevision"] and before["dirtyFiles"] == after["dirtyFiles"]
    assert "AutoInjectedReferrer" not in discover(client, PROVIDER)
    applied, findings = start(client, source, False)
    assert applied["summary"]["applied"] == 1 and applied["summary"]["requiresManualReview"] == 0, applied
    assert applied["result"]["records"][0]["cleaned"], applied
    assert [finding["code"] for finding in findings] == [
        "injected_cleanup_planned", "injected_cleanup_applied"], findings
    assert not findings[0]["applied"] and findings[1]["applied"], findings
    assert set(applied["summary"]["dirtyFiles"]) == {BASE, PROVIDER}, applied
    verify(client)
    client.call("session.save", files=[BASE, PROVIDER])
    client.call("session.flush")


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument("phase", choices=("generate", "exercise", "verify"))
    parser.add_argument("--overlay", type=Path, required=True)
    parser.add_argument("--exe", type=Path)
    parser.add_argument("--pid", type=int)
    parser.add_argument("--artifacts", type=Path)
    args = parser.parse_args()
    if args.phase == "generate":
        args.overlay.mkdir(parents=True, exist_ok=True)
        for name, data in fixtures().items():
            with (args.overlay / name).open("xb") as stream:
                stream.write(data)
    else:
        if args.exe is None or args.pid is None or args.artifacts is None:
            parser.error("Live phases require --exe, --pid and --artifacts")
        (exercise if args.phase == "exercise" else verify)(Client(args.exe, args.pid, args.artifacts))


if __name__ == "__main__":
    main()
