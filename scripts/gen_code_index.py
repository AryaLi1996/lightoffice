#!/usr/bin/env python3
"""Generate code_index.json: the map of every file LightOffice customises.

Every path is verified to exist in the upstream checkout before it is written,
so a stale index fails loudly instead of silently pointing at nothing.

Usage: scripts/gen_code_index.py [/path/to/onlyoffice-src]
"""
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.abspath(
    sys.argv[1] if len(sys.argv) > 1
    else os.environ.get("LIGHTOFFICE_SRC", os.path.join(os.path.dirname(ROOT), "onlyoffice-src"))
)

# key -> (relative path, what it is / why we touch it)
SINGLE = {
    "theme_path": (
        "web-apps/apps/common/main/resources/themes",
        "Editor colour themes. theme_lightwps.json is installed here and "
        "registered in themes.json.",
    ),
    "theme_file": (
        "web-apps/apps/common/main/resources/themes/theme_lightwps.json",
        "The LightOffice theme itself (90 colour keys, matching upstream's "
        "full-theme reference set).",
    ),
    "theme_registry": (
        "web-apps/apps/common/main/resources/themes/themes.json",
        "Theme manifest the editors read to populate the appearance menu.",
    ),
    "theme_variables_less": (
        "web-apps/apps/common/main/resources/less/colors-table.less",
        "Defines the :root CSS custom properties the theme JSON overrides.",
    ),
    "theme_canvas_consumer": (
        "sdkjs/common/skin.js",
        "Canvas renderer; reads the canvas-* theme keys that never appear in "
        "LESS.",
    ),
    "menu_config_path": (
        "web-apps/apps/documenteditor/main/app/controller/Toolbar.js",
        "Builds the document editor toolbar and adds the collaboration tab. "
        "LightOffice forces that tab off here.",
    ),
    "menu_layout_manager": (
        "web-apps/apps/common/main/lib/controller/LayoutManager.js",
        "Upstream's supported element-visibility gate "
        "(customization.layout), licence-gated behind canBrandingExt.",
    ),
    "plugin_host": (
        "web-apps/apps/common/main/lib/controller/Plugins.js",
        "Plugin loader. Disabled by the overlay, which is what removes the AI "
        "assistant (upstream ships it as a plugin, not built-in UI).",
    ),
    "cloud_provider_registry": (
        "desktop-apps/common/loginpage/providers",
        "Per-provider config.json + icons for every cloud the desktop client "
        "can connect to. The lightoffice/ provider is added here.",
    ),
    "cloud_provider_addon_registry": (
        "desktop-apps/common/loginpage/addon/externalcloud.json",
        "Secondary registry of external cloud providers.",
    ),
    "cloud_connect_dialog": (
        "desktop-apps/common/loginpage/src/dialogconnect.js",
        "The connect-to-cloud dialog; reads the portal URL the user enters.",
    ),
    "branding_version_header": (
        "desktop-apps/win-linux/src/version.h",
        "Base VERSIONINFO / About strings.",
    ),
    "branding_vendor_hook": (
        "desktop-apps/win-linux/src/prop/version_p.h",
        "Vendor override hook included at the end of version.h. LightOffice "
        "branding is injected here, leaving upstream sources untouched.",
    ),
    "branding_window_icon": (
        "desktop-apps/win-linux/res/icons/desktopeditors.ico",
        "Windows/Linux window and taskbar icon.",
    ),
    "build_defaults_pri": (
        "desktop-apps/win-linux/defaults.pri",
        "qmake defaults for the desktop app; the size-optimisation profile is "
        "included from here.",
    ),
    "desktop_project_file": (
        "desktop-apps/win-linux/ASCDocumentEditor.pro",
        "Top-level qmake project for the desktop application.",
    ),
    "dictionaries_path": (
        "dictionaries",
        "Hunspell dictionaries. Trimmed to the shipped locale set.",
    ),
}

# key -> (glob-ish list, description)
MULTI = {
    "menu_config_all_editors": (
        [f"web-apps/apps/{e}/main/app/controller/Toolbar.js"
         for e in ("documenteditor", "spreadsheeteditor",
                   "presentationeditor", "pdfeditor")],
        "Every editor's toolbar controller — all four gain the collaboration "
        "trim.",
    ),
}


def rel(p):
    return p.replace(os.sep, "/")


def git_rev(path):
    try:
        return subprocess.run(
            ["git", "-C", path, "rev-parse", "HEAD"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except (subprocess.CalledProcessError, OSError):
        return None


def main():
    if not os.path.isdir(SRC):
        sys.exit(f"upstream checkout not found: {SRC}")

    missing = []
    index = {}

    for key, (path, desc) in SINGLE.items():
        full = os.path.join(SRC, path)
        exists = os.path.exists(full)
        if not exists:
            missing.append(f"{key} -> {path}")
        index[key] = {
            "path": rel(path),
            "type": "directory" if os.path.isdir(full) else "file",
            "exists": exists,
            "description": desc,
        }

    for key, (paths, desc) in MULTI.items():
        entries = []
        for path in paths:
            full = os.path.join(SRC, path)
            if not os.path.exists(full):
                missing.append(f"{key} -> {path}")
            entries.append({"path": rel(path), "exists": os.path.exists(full)})
        index[key] = {"paths": entries, "description": desc}

    submodules = {}
    for name in ("core", "desktop-apps", "desktop-sdk", "sdkjs",
                 "web-apps", "dictionaries"):
        sub = os.path.join(SRC, name)
        if os.path.isdir(sub):
            submodules[name] = git_rev(sub)

    doc = {
        "schema": "lightoffice/code-index@1",
        "generated_by": "scripts/gen_code_index.py",
        "upstream_root": rel(SRC),
        "upstream_revision": git_rev(SRC),
        "submodule_revisions": submodules,
        "build_system": {
            "primary": "qmake",
            "note": "ONLYOFFICE builds with qmake (137 .pro files). Only "
                    "desktop-sdk uses CMake (27 of the 32 CMakeLists.txt in "
                    "the tree).",
        },
        "index": index,
    }

    out = os.path.join(ROOT, "code_index.json")
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, ensure_ascii=False, indent=2)
        fh.write("\n")

    print(f"wrote {out}  ({len(index)} keys)")
    if missing:
        print("MISSING PATHS:", file=sys.stderr)
        for m in missing:
            print("  " + m, file=sys.stderr)
        return 1
    print("all indexed paths verified to exist")
    return 0


if __name__ == "__main__":
    sys.exit(main())
