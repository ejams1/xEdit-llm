"""Generate the source-union xEdit agent operation inventory (stdlib only).

This is a static audit, not a Delphi parser or proof of runtime availability.
Run from any directory: python Tools/AgentCoverage/generate.py [--check]
"""

import argparse
from collections import Counter
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
CONFIG = HERE / "routes.json"
JSON_OUT = HERE / "coverage.json"
MD_OUT = ROOT / "AUTOMATION-COVERAGE.md"
GUI_EVENTS = r"OnClick|OnExecute|OnDblClick|OnKeyDown|OnKeyPress|OnDragDrop|OnNewText|OnChecked|OnChange|OnMouseDown|OnHeaderClick|OnHeaderDropped|OnHeaderMouseDown"


def read(path):
    return path.read_text(encoding="utf-8-sig")


def source(path, line):
    return {"file": path.relative_to(ROOT).as_posix(), "line": line}


def pascal_code(text):
    """Remove Pascal comments, preserving offsets, lines and quoted literals."""
    result = list(text)
    i = 0
    while i < len(text):
        if text[i] == "'":
            i += 1
            while i < len(text):
                if text[i] == "'":
                    if i + 1 < len(text) and text[i + 1] == "'":
                        i += 2
                        continue
                    i += 1
                    break
                i += 1
            continue
        end = None
        if text.startswith("//", i):
            end = text.find("\n", i)
            end = len(text) if end < 0 else end
        elif text[i] == "{":
            closing = text.find("}", i + 1)
            end = len(text) if closing < 0 else closing + 1
        elif text.startswith("(*", i):
            closing = text.find("*)", i + 2)
            end = len(text) if closing < 0 else closing + 2
        if end is not None:
            for j in range(i, end):
                if result[j] not in "\r\n":
                    result[j] = " "
            i = end
        else:
            i += 1
    return "".join(result)


def extract_gui():
    rows = []
    implementations = {}
    for path in sorted((ROOT / "xEdit").rglob("*.dfm"), key=lambda p: p.relative_to(ROOT).as_posix()):
        stack = []
        for number, line in enumerate(read(path).splitlines(), 1):
            match = re.match(r"(\s*)(?:object|inherited|inline) (\w+): (\w+)", line)
            if match:
                depth = len(match[1])
                while stack and stack[-1]["depth"] >= depth:
                    stack.pop()
                stack.append({"depth": depth, "component": match[2], "class": match[3],
                              "caption": match[2], "source": source(path, number)})
                continue
            if not stack:
                continue
            node = stack[-1]
            if re.match(r"\s*end\s*$", line) and len(line) - len(line.lstrip()) == node["depth"]:
                stack.pop()
                continue
            caption = re.match(r"\s*Caption = '((?:''|[^'])*)'", line)
            if caption:
                node["caption"] = caption[1].replace("''", "'")
            action = re.match(r"\s*Action = (\w+)", line)
            if action:
                node["action"] = action[1]
            event = re.match(rf"\s*({GUI_EVENTS}) = (\w+)", line)
            if event:
                rows.append({"id": path.relative_to(ROOT).as_posix() + ":" + node["component"] + ":" + event[1],
                             "component": node["component"], "caption": node["caption"],
                             "class": node["class"], "handler": event[2],
                             "event": event[1], "source": source(path, number),
                             "mainForm": path.name == "xeMainForm.dfm"})
    # Dynamic menu entries do not necessarily have DFM counterparts.
    path = ROOT / "xEdit/xeMainForm.pas"
    seen = {(row["handler"].lower(), row["event"]) for row in rows if row["mainForm"]}
    for number, line in enumerate(pascal_code(read(path)).splitlines(), 1):
        match = re.search(rf"\.({GUI_EVENTS})\s*:=\s*(\w+)\s*;", line)
        if match and (match[2].lower(), match[1]) not in seen and match[2].lower() != "nil":
            seen.add((match[2].lower(), match[1]))
            rows.append({"id": "dynamic:" + match[2] + ":" + match[1], "component": "dynamic:" + match[2],
                         "caption": "Dynamic action: " + match[2], "class": "runtime binding",
                         "handler": match[2], "event": match[1], "source": source(path, number),
                         "mainForm": True})
    # Preserve native visibility/enable predicates and implementation entrypoints
    # as evidence, without pretending to evaluate Delphi expressions.
    text = pascal_code(read(path))
    guards = {}
    for match in re.finditer(r"\b(\w+)\.(Visible|Enabled)\s*:=\s*([^;]+);", text):
        guards.setdefault(match[1].lower(), []).append({
            "property": match[2], "expression": " ".join(match[3].split()),
            "source": source(path, text.count("\n", 0, match.start()) + 1)})
    for row in rows:
        row["nativeGuards"] = guards.get(row["component"].lower(), []) if row["mainForm"] else []
        implementation = ROOT / row["source"]["file"]
        implementation = implementation.with_suffix(".pas")
        owner = "TfrmMain" if row["mainForm"] else r"\w+"
        if implementation not in implementations:
            implementations[implementation] = pascal_code(read(implementation)) if implementation.exists() else ""
        body = implementations[implementation]
        pattern = rf"(?:procedure|function)\s+{owner}\.{re.escape(row['handler'])}\b"
        row["handlerSources"] = [source(implementation, body.count("\n", 0, m.start()) + 1)
                                 for m in re.finditer(pattern, body, re.IGNORECASE)]
    return rows


def extract_commands():
    rows = []
    for path in sorted((ROOT / "xEdit").glob("xeAutomationCommands*.pas"), key=lambda p: p.relative_to(ROOT).as_posix()):
        text = pascal_code(read(path))
        constants = dict(re.findall(r"\b(\w+)\s*=\s*'([^']+)'", text))
        pattern = r"xeAutomationRegister(Command|JobKind(?:WithValidator)?)\s*\(\s*('([^']+)'|(\w+))\s*,\s*(\w+)"
        for match in re.finditer(pattern, text):
            name = match[3] or constants.get(match[4])
            if name is None:
                raise ValueError(f"Unresolved registration {match[4]} in {path}")
            rows.append({"name": name, "kind": "command" if match[1] == "Command" else "job",
                         "handler": match[5], "source": source(path, text.count("\n", 0, match.start()) + 1)})
    return sorted(rows, key=lambda row: (row["kind"], row["name"]))


def extract_policy():
    path = ROOT / "xEdit/xeScriptRuntimePolicy.pas"
    text = pascal_code(read(path))
    pattern = r"\(Symbol:\s*'([^']+)';\s*Action:\s*(\w+);\s*Policy:\s*(\w+);\s*PathArgIndex:\s*(-?\d+)\)"
    rows = [{"symbol": m[1], "action": m[2], "policy": m[3], "pathArgIndex": int(m[4]),
             "source": source(path, text.count("\n", 0, m.start()) + 1)} for m in re.finditer(pattern, text)]
    bound = re.search(r"xeScriptRuntimePolicyEntries:\s*array\[0\.\.(\d+)\]", text)
    if not bound or len(rows) != int(bound[1]) + 1:
        raise ValueError("Script ledger format/count changed; update the extractor")
    for row in rows:
        row["verification"] = "policy-in-source; runtime-not-verified"
        row["prerequisites"] = "scripts.run consent, loaded targets when relevant, budgets and native symbol predicates; game applicability not inferred"
        if row["policy"] == "srpAllowPureRead":
            row["effect"] = "read/utility; no plugin persistence intended by classification"
        elif row["policy"] == "srpAllowInMemoryMutate":
            row["effect"] = "in-memory object/index/plugin mutation; plugin changes require save + flush"
        elif row["policy"] == "srpAllowBoundedFsRead":
            row["effect"] = "filesystem read restricted to ScriptsPath/reparse policy and argument/mode checks"
        else:
            row["effect"] = "denied by headless policy; no supported agent route through this symbol/action"
    return rows


def extract_adapters(policy):
    rows = []
    index = {(row["symbol"].lower(), row["action"]): [] for row in policy}
    for row in policy:
        index[(row["symbol"].lower(), row["action"])].append(row["policy"])
    for path in sorted((ROOT / "xEdit/JvI").glob("*.pas"), key=lambda p: p.relative_to(ROOT).as_posix()):
        for number, line in enumerate(pascal_code(read(path)).splitlines(), 1):
            match = re.search(r"\bAdd(Function|Get|Set)\(\s*([^,]+),\s*'([^']+)'", line)
            if not match or line.lstrip().startswith("//"):
                continue
            symbol = match[3] if match[1] == "Function" else match[2].strip() + "." + match[3]
            action = "aaSet" if match[1] == "Set" else "aaGet"
            policies = index.get((symbol.lower(), action), [])
            status = "allowed" if any(p.startswith("srpAllow") for p in policies) else "unclassified"
            if any(p.startswith("srpDeny") for p in policies):
                status = "denied"
            rows.append({"symbol": symbol, "action": action, "policies": policies,
                         "status": status, "source": source(path, number)})
    return rows


def build(config):
    commands = extract_commands()
    names = {row["name"] for row in commands}
    if len(names) != len(commands):
        raise ValueError("Duplicate operation registrations need explicit conditional-build audit")
    policy = extract_policy()
    denied_gets = {row["symbol"].lower() for row in policy
                   if row["action"] == "aaGet" and row["policy"].startswith("srpDeny")}
    symbols = {row["symbol"].lower() for row in policy
               if row["action"] == "aaGet" and row["policy"].startswith("srpAllow")} - denied_gets
    profiles = config["profiles"]
    for key, profile in profiles.items():
        for route in profile.get("routes", []):
            if route not in names:
                raise ValueError(f"Unknown command/job {route} in profile {key}")
        for symbol in profile.get("scriptSymbols", []):
            if symbol.lower() not in symbols:
                raise ValueError(f"Script symbol not admitted by ledger: {symbol} ({key})")
    gui = extract_gui()
    if len({row["id"] for row in gui}) != len(gui):
        raise ValueError("Duplicate GUI operation identities")
    used = set()
    handlers = {key.lower(): value for key, value in config["handlers"].items()}
    components = {key.lower(): value for key, value in config["components"].items()}
    for row in gui:
        key = components.get(row["component"].lower()) if row["mainForm"] else None
        if key is None and row["mainForm"]:
            key = handlers.get(row["handler"].lower())
        if key is None:
            key = "unassessed" if row["mainForm"] else config["forms"].get(row["source"]["file"], "unassessed")
        if key not in profiles:
            raise ValueError(f"Unknown profile {key}")
        used.add(key)
        row["profile"] = key
        row.update(profiles[key])
        row["verification"] = "source-reviewed; runtime-not-verified"
    registered = []
    for row in commands:
        row = dict(row)
        family = row["name"].split(".")[0]
        key = "jobs" if row["kind"] == "job" or family == "jobs" else family
        row.update(config["commandFamilies"][key])
        row.update(config.get("operationOverrides", {}).get(row["name"], {}))
        row["verification"] = "registered-in-source; runtime-not-verified"
        registered.append(row)
    handler_names = {r["handler"].lower() for r in gui if r["mainForm"]}
    component_names = {r["component"].lower() for r in gui if r["mainForm"]}
    stale = sorted(set(handlers) - handler_names) + sorted(set(components) - component_names)
    if stale:
        raise ValueError("Stale route mappings: " + ", ".join(stale))
    gui_forms = {r["source"]["file"] for r in gui if not r["mainForm"]}
    if set(config["forms"]) - gui_forms:
        raise ValueError("Stale child-form mappings")
    if set(config.get("operationOverrides", {})) - names:
        raise ValueError("Stale operation metadata")
    if names - set(config.get("operationOverrides", {})):
        raise ValueError("New registered operations require explicit effect metadata")
    missing = sorted(set(config["requiredProfiles"]) - used)
    if missing:
        raise ValueError("Required operation families absent from inventory: " + ", ".join(missing))
    system_source = pascal_code(read(ROOT / "xEdit/xeAutomationCommandsSystem.pas"))
    version = re.search(r"Result\.S\['contractVersion'\]\s*:=\s*'([^']+)'", system_source)
    if not version:
        raise ValueError("Cannot extract automation contract version")
    return {"schemaVersion": 1, "contractVersion": version[1], "issue": "https://github.com/ejams1/xEdit-llm/issues/8",
            "scope": "Source union, not preprocessed per game/build. No runtime availability or semantic parity claim.",
            "guiActions": gui, "registeredOperations": registered, "scriptPolicy": policy,
            "adapterRegistrations": extract_adapters(policy), "gaps": config["gaps"]}


def link(ref):
    return f"[{ref['file']}:{ref['line']}]({ref['file']}#L{ref['line']})"


def cell(value):
    return str(value).replace("|", "\\|").replace("\n", " ")


def table(headers, rows):
    return "\n".join(["| " + " | ".join(headers) + " |", "| " + " | ".join("---" for _ in headers) + " |"] +
                     ["| " + " | ".join(cell(value) for value in row) + " |" for row in rows])


def render(data, config):
    gui = data["guiActions"]
    counts = Counter(r["status"] for r in gui if r["mainForm"])
    operations = data["registeredOperations"]
    out = ["# xEdit agent operation coverage", "",
           "Generated by `python Tools/AgentCoverage/generate.py`; do not edit this file. "
           "Edit [routes.json](Tools/AgentCoverage/routes.json), then regenerate. "
           "Run `python Tools/AgentCoverage/generate.py --check` to detect drift.", "",
           "Implements [review issue #8](https://github.com/ejams1/xEdit-llm/issues/8). "
           "Machine-readable inventory: [coverage.json](Tools/AgentCoverage/coverage.json).", "",
           "## Scope and evidence", "",
           data["scope"], "",
           "Inventory includes every declared click/execute, double-click, keyboard, drag/drop, new-text, checked, "
           "change, mouse-down and header-click/drop bindings in xEdit DFM files and dynamic main-form bindings, "
           "every explicit automation registration, every runtime-policy ledger entry, and literal "
           "AddFunction/AddGet/AddSet registrations in xEdit/JvI. Child dialogs are inventoried separately. "
           "Rendering/lifecycle callbacks, inherited external-component behavior, RTL adapter registrations, "
           "constants/classes, and computed registration names are not exhaustively parsed. "
           "Do not interpret this as proof that every conceivable UI gesture is covered.", "",
           "All routes below are source-reviewed and **runtime-not-verified** in this checkout. "
           "Policy admission proves only permission for that symbol/action; it does not prove a recipe compiles "
           "or reproduces GUI behavior. Unsupported game/record/target combinations must fail before mutation.", "",
           "## Prerequisites and persistence", "",
           "Use a loaded daemon session and probe system.capabilities for current support and consent state. "
           "Structured mutation requires -IKnowWhatImDoing, edit mode and an editable non-protected target. "
           "Game, signature, parent and schema predicates remain native; a source-union row is not an all-games promise. "
           "Use elements.edit_capabilities/assign_templates before structural edits. "
           "Jobs require jobs.start, then jobs.get; retained factories advance per-kind work units with progress/cancellation boundaries. Native calls remain indivisible and can block a poll; inspect supports.jobs.kindLimits. "
           "Script routes require Agent/ storage, policy admission and budgets, and do not inherit every structured-command guard.", "",
           "Plugin changes stay in memory until session.save. Check both dirty and pendingShutdownCount; "
           "session.flush is terminal and refuses unsaved changes unless force:true accepts loss. "
           "Confirm durable output by loading it in a fresh process. scripts.write/delete change script files immediately. "
           "Generated external files need separate output-path and durability contracts.", "",
           "## Coverage summary", "",
           f"Contract {data['contractVersion']}: {sum(r['kind'] == 'command' for r in operations)} commands; "
           f"{sum(r['kind'] == 'job' for r in operations)} job kinds; "
           f"{sum(r['mainForm'] for r in gui)} main-form action bindings; "
           f"{sum(not r['mainForm'] for r in gui)} child-form action bindings; "
           f"{len(data['scriptPolicy'])} script-policy entries; "
           f"{len(data['adapterRegistrations'])} literal xEdit JvI function/member registrations.", "",
           table(["Main-form status", "Bindings"], sorted(counts.items())), "",
           "direct = registered equivalent for the stated scope; composed = multiple commands; "
           "partial = only part of GUI scope is covered; script-candidate = admitted primitives but unverified recipe; "
           "missing = native operation lacks a supported route; presentation = UI/session preference; "
           "obsolete = legacy warning/no-op; unassessed = needs manual audit. Counts are bindings, not distinct workflows.", "",
           "## Workflow acceptance backlog", "",
           "These tracked workflow families preserve the original acceptance scope. Implemented routes and explicit exclusions appear below; source coverage is distinct from native acceptance. See [the issue PR/test map](Tools/AutomationRegression/ISSUE-STATUS.md). "
           "Each must preserve native game gates, return structured outcomes, expose safe prerequisites, "
           "and have game-backed semantic tests. Plugin writes use the explicit save boundary; "
           "external-output operations need a bounded filesystem contract.", ""]
    for gap in data["gaps"]:
        matching = [r for r in gui if r["profile"] in gap["profiles"]]
        out += [f"### {gap['id']}: {gap['title']}", "", gap["acceptance"], "",
                "Evidence: " + "; ".join(link(r["source"]) for r in matching[:4]) + ".", ""]
    out += ["## Main-form operation matrix", "",
            table(["Action / component", "Status / profile", "Agent route", "Scope, limitations and native prerequisites", "Effect / persistence", "Source"],
                  [(r["caption"] + " (`" + r["component"] + "`)", r["status"] + " / " + r["profile"],
                    ", ".join(r.get("routes", [])) + ("; script: " + ", ".join(r["scriptSymbols"]) if r.get("scriptSymbols") else ""),
                    r["notes"], r["effect"], link(r["source"]) +
                    ("; handler " + link(r["handlerSources"][0]) if r["handlerSources"] else "")) for r in gui if r["mainForm"]]), "",
            "Native Visible/Enabled expressions and all matching handler implementation locations are retained "
            "in coverage.json. These are source evidence, not evaluated availability guarantees.", "",
            "## Child-form controls", "",
            "These controls belong to containing modal/editor workflows. Their presence does not provide a standalone "
            "daemon route. UI-only controls are not new plugin-operation implementation requests; "
            "data-editor/export controls need parent-workflow audit.", "",
            table(["Control", "Handler", "Classification / profile", "Scope / persistence", "Source"],
                  [(r["caption"] + " (`" + r["component"] + "`)", r["handler"], r["status"] + " / " + r["profile"],
                    r["notes"] + " " + r["effect"], link(r["source"]))
                   for r in gui if not r["mainForm"]]), "",
            "## Registered command and job matrix", "",
            "Family prerequisites describe common behavior; individual source predicates remain authoritative. "
            "Registration does not certify semantic parity or runtime readiness.", "",
            table(["Operation", "Kind", "Prerequisites / game applicability", "Effect / persistence", "Source"],
                  [(r["name"], r["kind"], r["prerequisites"], r["effect"], link(r["source"])) for r in operations]), "",
            "## Agent workflow recipes", "", config["recipes"], "",
            "## Script policy and adapter coverage", "",
            "The JSON contains every ledger entry with symbol, aaGet/aaSet, policy, bounded path argument and source. "
            "It also joins literal xEdit JvI adapter registrations to exact ledger rows. Deny rows outrank allow rows. "
            "Unclassified adapter entries are audit candidates: inheritance matching and external registrations "
            "can affect runtime behavior, so this static join does not establish an actual denial.", "",
            table(["Policy", "Entries"], sorted(Counter(r["policy"] for r in data["scriptPolicy"]).items())), "",
            table(["Literal adapter classification", "Registrations"], sorted(Counter(r["status"] for r in data["adapterRegistrations"]).items())), "",
            "Unclassified literal registrations:", "",
            table(["Symbol", "Action", "Source"], [(r["symbol"], r["action"], link(r["source"]))
                  for r in data["adapterRegistrations"] if r["status"] == "unclassified"]), "",
            "## Verification requirements", "",
            "Static check validates extraction, ledger count, mapping references, stale mappings and artifact drift. "
            "It does not run Delphi or xEdit. Before marking a route runtime-verified, record executable/commit, game, "
            "fixture, exact request, expected response, error cases and fresh-process persistence readback for writes. "
            "Existing review issues #1-#7 and #10-#18 remain correctness/reliability work even for rows marked direct.", ""]
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail on missing/unassessed routes or generated-artifact drift")
    parser.add_argument("--list-gui", action="store_true", help="Print extracted main-form bindings without requiring config")
    args = parser.parse_args()
    if args.list_gui:
        for row in extract_gui():
            if row["mainForm"]:
                print(f"{row['component']}\t{row['handler']}\t{row['caption']}")
        return 0
    config = json.loads(read(CONFIG))
    data = build(config)
    outputs = {JSON_OUT: json.dumps(data, indent=2, ensure_ascii=False) + "\n", MD_OUT: render(data, config)}
    if args.check:
        unknown = [r["id"] for r in data["guiActions"] if r["status"] == "unassessed"]
        stale = [p.relative_to(ROOT).as_posix() for p, text in outputs.items() if not p.exists() or read(p) != text]
        if unknown or stale:
            print(json.dumps({"unassessed": unknown, "staleArtifacts": stale}, indent=2))
            return 1
    else:
        for path, text in outputs.items():
            path.write_text(text, encoding="utf-8", newline="\n")
    print(f"Coverage {'verified' if args.check else 'generated'}: {len(data['registeredOperations'])} registered operations, "
          f"{len(data['guiActions'])} GUI bindings, {len(data['scriptPolicy'])} policy entries")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, KeyError) as error:
        print(f"Coverage validation failed: {error}", file=sys.stderr)
        sys.exit(1)
