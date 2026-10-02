"""Issue #4/#10 checks against the synthetic string fixture in a loaded daemon."""

import argparse
from pathlib import Path

from itm_fixture import Client
from string_fixture import PLUGIN


def expect_failure(client, command, **args):
    try:
        client.call(command, **args)
    except RuntimeError as error:
        envelope = error.args[0]
        assert isinstance(envelope, dict) and envelope.get("ok") is False, error
        return envelope["error"]
    raise AssertionError(f"{command} unexpectedly succeeded")


def exercise(client):
    before = client.call("session.get_dirty_state")
    records_before = client.call("records.list", file=PLUGIN)
    # LAND has no EditorID. This must be rejected without creating its group,
    # consuming an ID or changing native mutation generation.
    expect_failure(client, "records.create", targetFile=PLUGIN, signature="LAND", editorId="InvalidLandEditorId")
    after = client.call("session.get_dirty_state")
    assert after["mutationRevision"] == before["mutationRevision"], (before, after)
    assert client.call("records.list", file=PLUGIN) == records_before
    messages = client.call("records.list", file=PLUGIN, signature="MESG")["records"]
    target = next(r["locator"] for r in messages if r["object"]["editorId"] == "AutomationStringWhitespace")
    field = {**target, "path": "DESC"}
    client.call("elements.set_native_value", **field, kind="string", value="Already dirty")
    before = client.call("session.get_dirty_state")
    assert before["dirty"], before
    source = """unit AgentMutationAudit;
function Process(e: IInterface): Integer;
var n: Integer;
begin
  SetElementNativeValues(e, 'DESC', 'Changed before runtime failure');
  n := 0;
  Result := 1 div n;
end;
end.
"""
    client.call("scripts.write", id="Agent/MutationAudit.pas", source=source, overwrite=True)
    error = expect_failure(client, "scripts.run", id="Agent/MutationAudit.pas", targets=[target])
    details = error["details"]
    assert details["mutationsAppliedBeforeFailure"] is True, error
    assert PLUGIN in details["modifiedFilesBeforeFailure"], error
    assert details["mutationState"]["generationBefore"] != details["mutationState"]["generationAfter"], error
    assert client.call("elements.get_value", **field)["values"]["editValue"] == "Changed before runtime failure"
    client.call("session.save", files=[PLUGIN])
    client.call("session.flush")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", required=True, type=Path)
    parser.add_argument("--pid", required=True, type=int)
    parser.add_argument("--artifacts", required=True, type=Path)
    args = parser.parse_args()
    exercise(Client(args.exe, args.pid, args.artifacts))


if __name__ == "__main__":
    main()
