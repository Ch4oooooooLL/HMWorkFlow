#!/usr/bin/env python3
"""Build a HyperWorks Extension package for the HM Workflow Tcl toolkit."""

from __future__ import annotations

import fnmatch
import json
import re
import shutil
import sys
import zipfile
from html import escape as xml_escape
from pathlib import Path
from xml.etree import ElementTree as ET


SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
CONFIG_FILE = SCRIPT_DIR / "extension_tools.json"
TEMPLATE_DIR = SCRIPT_DIR / "extension_template"
DIST_DIR = PROJECT_ROOT / "dist"

PAYLOAD_INCLUDE_ITEMS = [
    "README.md",
    "config.yaml",
    "hw_toolkit.tcl",
    "config",
    "doc",
    "modules",
]

EXCLUDED_DIR_NAMES = {
    ".git",
    "__pycache__",
    ".pytest_cache",
    "logs",
    "output",
    "temp",
    "tmp",
    "backup",
    "dist",
}

EXCLUDED_FILE_PATTERNS = {
    "*.zip",
    "*.rar",
    "*.7z",
    "*.log",
    "*.h3d",
    "*.op2",
    "*.odb",
    "*.pch",
    "*.fem",
    "*.hm",
    "*.bak",
    "*.bak_*",
}

KEY_RE = re.compile(r"^[A-Za-z0-9_]+$")


def load_config() -> dict:
    if not CONFIG_FILE.exists():
        raise SystemExit(f"Missing config file: {CONFIG_FILE}")
    with CONFIG_FILE.open("r", encoding="utf-8") as f:
        config = json.load(f)

    required = ["extension_name", "display_name", "version", "min_product_version", "tools"]
    missing = [key for key in required if key not in config]
    if missing:
        raise SystemExit(f"Config is missing required key(s): {', '.join(missing)}")
    if not isinstance(config["tools"], list) or not config["tools"]:
        raise SystemExit("Config key 'tools' must be a non-empty list.")
    return config


def as_posix_rel(path_text: str) -> str:
    return path_text.replace("\\", "/").strip("/")


def validate_config(config: dict) -> None:
    seen_keys: set[str] = set()
    missing_scripts: list[str] = []

    for index, tool in enumerate(config["tools"], start=1):
        for key in ["key", "label", "script", "tooltip"]:
            if key not in tool:
                raise SystemExit(f"Tool #{index} is missing required key: {key}")

        tool_key = tool["key"]
        if not KEY_RE.match(tool_key):
            raise SystemExit(
                f"Invalid tool key '{tool_key}'. Use only English letters, digits, and underscores."
            )
        if tool_key in seen_keys:
            raise SystemExit(f"Duplicate tool key: {tool_key}")
        seen_keys.add(tool_key)

        script_rel = as_posix_rel(str(tool["script"]))
        if not script_rel.lower().endswith(".tcl"):
            raise SystemExit(f"Tool '{tool_key}' script must be a Tcl file: {script_rel}")

        script_path = PROJECT_ROOT / Path(*script_rel.split("/"))
        if not script_path.exists():
            missing_scripts.append(f"  - {tool_key}: {script_rel} -> {script_path}")

        proc_name = str(tool.get("proc", "")).strip()
        if proc_name and not proc_name.startswith("::"):
            raise SystemExit(f"Tool '{tool_key}' proc should be a fully qualified Tcl proc: {proc_name}")

    if missing_scripts:
        raise SystemExit("Configured Tcl script(s) do not exist:\n" + "\n".join(missing_scripts))


def should_ignore(dir_path: str, names: list[str]) -> set[str]:
    ignored: set[str] = set()
    for name in names:
        lower_name = name.lower()
        full_path = Path(dir_path) / name
        if full_path.is_dir() and lower_name in EXCLUDED_DIR_NAMES:
            ignored.add(name)
            continue
        if full_path.is_file():
            for pattern in EXCLUDED_FILE_PATTERNS:
                if fnmatch.fnmatch(lower_name, pattern.lower()):
                    ignored.add(name)
                    break
    return ignored


def tcl_brace(value: object) -> str:
    text = str(value)
    text = text.replace("\\", "\\\\")
    text = text.replace("{", "\\{").replace("}", "\\}")
    return "{" + text + "}"


def xml_attr(value: object) -> str:
    return xml_escape(str(value), quote=True)


def generate_extension_xml(config: dict) -> str:
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<section name="Extension">
    <entry name="name" value="{xml_attr(config['extension_name'])}" />
    <entry name="displayName" value="{xml_attr(config['display_name'])}" />
    <entry name="version" value="{xml_attr(config['version'])}" />
    <entry name="minProductVersion" value="{xml_attr(config['min_product_version'])}" />
    <entry name="supportedClient" value="HyperWorksDesktop" />
    <entry name="resources" value="resources" />
    <entry name="autoLoad" value="true" />
    <entry name="tclscript" value="global-init.tcl" />

    <section name="profile" value="HyperMesh">
        <entry name="ribbonxml" value="hm/hm-ribbon.xml" />
    </section>
</section>
"""


def generate_global_init_tcl(config: dict) -> str:
    entries: list[str] = []
    for tool in config["tools"]:
        script_rel = as_posix_rel(str(tool["script"]))
        proc_name = str(tool.get("proc", "")).strip()
        info_value = (
            "script "
            + tcl_brace(script_rel)
            + " proc "
            + tcl_brace(proc_name)
            + " label "
            + tcl_brace(tool["label"])
        )
        entries.append(
            tcl_brace(tool["key"])
            + " "
            + "{"
            + info_value
            + "}"
        )
    tool_map = " ".join(entries)
    version = config["version"]
    display_name = config["display_name"]

    return f"""# Auto-generated HM WorkFlow Extension wrapper.
# Do not put HyperMesh business logic in this file. It only locates and sources
# the original Tcl scripts from payload/.

namespace eval ::HMWorkflowExt {{
    variable EXT_ROOT [file normalize [file dirname [info script]]]
    variable TOOL_ROOT [file normalize [file join $EXT_ROOT payload]]
    variable VERSION {tcl_brace(version)}
    variable DISPLAY_NAME {tcl_brace(display_name)}
    variable TOOL_MAP [dict create {tool_map}]
}}

proc ::HMWorkflowExt::message {{icon title message}} {{
    if {{[llength [info commands tk_messageBox]] > 0}} {{
        tk_messageBox -icon $icon -title $title -message $message
    }} elseif {{[llength [info commands hm_usermessage]] > 0}} {{
        catch {{hm_usermessage $message}}
    }} else {{
        puts stderr "$title: $message"
    }}
}}

proc ::HMWorkflowExt::run {{toolKey}} {{
    variable TOOL_ROOT
    variable TOOL_MAP
    variable DISPLAY_NAME

    if {{![dict exists $TOOL_MAP $toolKey]}} {{
        set msg "Unknown HM WorkFlow tool key: $toolKey"
        ::HMWorkflowExt::message error $DISPLAY_NAME $msg
        return -code error $msg
    }}

    set info [dict get $TOOL_MAP $toolKey]
    set scriptRel [dict get $info script]
    set scriptPath [file normalize [file join $TOOL_ROOT $scriptRel]]

    if {{![file exists $scriptPath]}} {{
        set msg "Tcl script not found:\\n$scriptPath"
        ::HMWorkflowExt::message error $DISPLAY_NAME $msg
        return -code error $msg
    }}

    set oldPwd [pwd]
    set code [catch {{
        cd [file dirname $scriptPath]
        uplevel #0 [list source $scriptPath]

        if {{[dict exists $info proc]}} {{
            set procName [string trim [dict get $info proc]]
            if {{$procName ne ""}} {{
                if {{[llength [info commands $procName]] == 0}} {{
                    error "Configured Tcl proc does not exist after source: $procName"
                }}
                uplevel #0 [list $procName]
            }}
        }}
    }} err opts]
    catch {{cd $oldPwd}}

    if {{$code}} {{
        set msg "Tool '$toolKey' failed:\\n$err"
        ::HMWorkflowExt::message error $DISPLAY_NAME $msg
        return -options $opts $err
    }}
    return
}}

proc ::HMWorkflowExt::about {{}} {{
    variable DISPLAY_NAME
    variable VERSION
    variable TOOL_ROOT
    variable TOOL_MAP

    set keys [lsort [dict keys $TOOL_MAP]]
    set msg "$DISPLAY_NAME\\nVersion: $VERSION\\n\\nPayload:\\n$TOOL_ROOT\\n\\nTools:\\n[join $keys \\n]"
    ::HMWorkflowExt::message info $DISPLAY_NAME $msg
}}
"""


def generate_ribbon_xml(config: dict) -> str:
    action_lines = [
        '        <action',
        '            tag="HMWorkflowExt_about"',
        '            text="About"',
        '            tooltip="About HM WorkFlow"',
        '            command="tcl: ::HMWorkflowExt::about"/>',
    ]
    action_refs = ['                <action actiontag="HMWorkflowExt_about"/>']

    for tool in config["tools"]:
        key = tool["key"]
        tag = f"HMWorkflowExt_{key}"
        action_lines.extend(
            [
                "        <action",
                f'            tag="{xml_attr(tag)}"',
                f'            text="{xml_attr(tool["label"])}"',
                f'            tooltip="{xml_attr(tool["tooltip"])}"',
                f'            command="tcl: ::HMWorkflowExt::run {xml_attr(key)}"/>',
            ]
        )
        action_refs.append(f'                <action actiontag="{xml_attr(tag)}"/>')

    return f"""<?xml version="1.0" encoding="UTF-8"?>
<root>
    <actionlist>
{chr(10).join(action_lines)}
    </actionlist>

    <page tag="HMWorkflowExt_Page" text="{xml_attr(config['display_name'])}">
        <group tag="HMWorkflowExt_Group_Main" text="Tools">
            <actiongroup tag="HMWorkflowExt_ActionGroup_Main" text="Run">
{chr(10).join(action_refs)}
            </actiongroup>
        </group>
    </page>
</root>
"""


def generate_readme(config: dict) -> str:
    return f"""# {config['display_name']} HyperWorks Extension

## Install

1. Unzip `{config['extension_name']}_{config['version']}_HyperWorks_Extension.zip`.
2. Open HyperWorks.
3. Go to `File > Extensions`.
4. Click `Add Extension`.
5. Select the unzipped `{config['extension_name']}` folder that contains `extension.xml`.
6. Enable the extension.

## Verify

1. Switch to the HyperMesh profile.
2. Check that the `{config['display_name']}` Ribbon page appears.
3. Click `About` or one of the tool buttons.

## Notes

- Extension Manager loads the extension folder, not the zip file.
- The zip file is only for distribution.
- Rebuild the extension after changing source Tcl files.
- Restart HyperWorks if the Ribbon does not refresh.
- If the Ribbon only shows one `Run` item that opens an info dialog, remove that
  extension entry and load the generated `{config['extension_name']}` folder from
  `dist` instead.
"""


def copy_template_resources(extension_dir: Path) -> None:
    resources_src = TEMPLATE_DIR / "resources"
    resources_dst = extension_dir / "resources"
    resources_dst.mkdir(parents=True, exist_ok=True)
    if resources_src.exists():
        for item in resources_src.iterdir():
            target = resources_dst / item.name
            if item.is_dir():
                shutil.copytree(item, target, dirs_exist_ok=True)
            else:
                shutil.copy2(item, target)


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8", newline="\n")


def build_extension(config: dict) -> tuple[Path, Path]:
    extension_name = str(config["extension_name"])
    version = str(config["version"])
    extension_dir = DIST_DIR / extension_name
    zip_path = DIST_DIR / f"{extension_name}_{version}_HyperWorks_Extension.zip"

    if extension_dir.exists():
        shutil.rmtree(extension_dir)
    if zip_path.exists():
        zip_path.unlink()

    (extension_dir / "hm").mkdir(parents=True, exist_ok=True)
    copy_template_resources(extension_dir)

    write_text(extension_dir / "extension.xml", generate_extension_xml(config))
    write_text(extension_dir / "global-init.tcl", generate_global_init_tcl(config))
    write_text(extension_dir / "hm" / "hm-ribbon.xml", generate_ribbon_xml(config))
    write_text(extension_dir / "README.md", generate_readme(config))

    payload_dir = extension_dir / "payload"
    copy_runtime_payload(payload_dir)

    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for path in extension_dir.rglob("*"):
            if path.is_file():
                arcname = Path(extension_name) / path.relative_to(extension_dir)
                zf.write(path, arcname.as_posix())

    verify_extension_package(config, extension_dir, zip_path)
    return extension_dir, zip_path


def copy_runtime_payload(payload_dir: Path) -> None:
    payload_dir.mkdir(parents=True, exist_ok=True)
    for item in PAYLOAD_INCLUDE_ITEMS:
        source = PROJECT_ROOT / item
        if not source.exists():
            continue

        target = payload_dir / item
        if source.is_dir():
            shutil.copytree(source, target, ignore=should_ignore)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)


def verify_extension_package(config: dict, extension_dir: Path, zip_path: Path) -> None:
    ribbon_path = extension_dir / "hm" / "hm-ribbon.xml"
    init_path = extension_dir / "global-init.tcl"
    payload_dir = extension_dir / "payload"

    if not ribbon_path.exists():
        raise SystemExit(f"Generated Ribbon XML is missing: {ribbon_path}")
    if not init_path.exists():
        raise SystemExit(f"Generated global Tcl wrapper is missing: {init_path}")
    if "Auto-generated HM WorkFlow Extension wrapper" not in init_path.read_text(encoding="utf-8"):
        raise SystemExit(f"Generated global Tcl wrapper was not written correctly: {init_path}")

    try:
        ribbon_root = ET.parse(ribbon_path).getroot()
    except ET.ParseError as exc:
        raise SystemExit(f"Generated Ribbon XML is invalid: {ribbon_path}: {exc}") from exc

    action_tags = {
        action.get("tag")
        for action in ribbon_root.findall(".//actionlist/action")
        if action.get("tag")
    }
    action_refs = {
        action.get("actiontag")
        for action in ribbon_root.findall(".//actiongroup/action")
        if action.get("actiontag")
    }

    expected_tool_tags = {f"HMWorkflowExt_{tool['key']}" for tool in config["tools"]}
    missing_actions = sorted(expected_tool_tags - action_tags)
    missing_refs = sorted(expected_tool_tags - action_refs)
    if missing_actions or missing_refs:
        details = []
        if missing_actions:
            details.append("missing action(s): " + ", ".join(missing_actions))
        if missing_refs:
            details.append("missing action reference(s): " + ", ".join(missing_refs))
        raise SystemExit("Generated Ribbon XML is incomplete: " + "; ".join(details))

    missing_payload = []
    for tool in config["tools"]:
        script_rel = as_posix_rel(str(tool["script"]))
        if not (payload_dir / Path(*script_rel.split("/"))).exists():
            missing_payload.append(script_rel)
    if missing_payload:
        raise SystemExit("Generated extension payload is missing Tcl script(s): " + ", ".join(missing_payload))

    nested_extension_xml = [
        path
        for path in payload_dir.rglob("extension.xml")
        if path.is_file()
    ]
    if nested_extension_xml:
        rels = ", ".join(path.relative_to(extension_dir).as_posix() for path in nested_extension_xml)
        raise SystemExit(
            "Generated extension payload contains nested extension.xml file(s), "
            f"which can make HyperWorks load the wrong extension: {rels}"
        )

    with zipfile.ZipFile(zip_path, "r") as zf:
        extension_xml_entries = [
            name for name in zf.namelist() if name.replace("\\", "/").endswith("/extension.xml")
        ]
    if len(extension_xml_entries) != 1:
        raise SystemExit(
            "Zip package should contain exactly one extension.xml, found "
            f"{len(extension_xml_entries)}: {', '.join(extension_xml_entries)}"
        )


def print_summary(config: dict, extension_dir: Path, zip_path: Path) -> None:
    print()
    print("HM WorkFlow HyperWorks Extension build finished.")
    print(f"Extension folder: {extension_dir}")
    print(f"Zip package:      {zip_path}")
    print()
    print("Install:")
    print("  1. Unzip the zip package on the target workstation.")
    print("  2. Open HyperWorks > File > Extensions.")
    print(f"  3. Click Add Extension and select the generated '{config['extension_name']}' folder.")
    print("  4. Enable the extension and switch to the HyperMesh profile.")
    print(f"  5. Confirm the '{config['display_name']}' Ribbon page is visible.")
    print()
    print("Configured Ribbon tools:")
    for tool in config["tools"]:
        proc = str(tool.get("proc", "")).strip()
        suffix = f" -> {proc}" if proc else ""
        print(f"  - {tool['key']}: {tool['script']}{suffix}")


def main() -> int:
    config = load_config()
    validate_config(config)
    extension_dir, zip_path = build_extension(config)
    print_summary(config, extension_dir, zip_path)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
