#!/usr/bin/env python3
"""Lists localisable keys the compiler extracted (from .stringsdata files in build/) that have no
Turkish translation in App/Resources/Localizable.xcstrings. Run after `make app`. Exit 1 if any are missing."""
import json, pathlib, plistlib, sys

root = pathlib.Path(__file__).resolve().parent.parent
catalog = json.loads((root / "App/Resources/Localizable.xcstrings").read_text(encoding="utf-8"))["strings"]
translated = {k for k, v in catalog.items() if "tr" in v.get("localizations", {}) or v.get("shouldTranslate") is False}

def load(path):
    raw = path.read_bytes()
    try:
        return json.loads(raw)
    except ValueError:
        return plistlib.loads(raw)

extracted = set()
for path in (root / "build").rglob("*.stringsdata"):
    data = load(path)
    for table, entries in data.get("tables", {}).items():
        if table == "Localizable":
            extracted.update(entry["key"] for entry in entries)

missing = sorted(extracted - translated)
for key in missing:
    print(f"missing tr: {key!r}")
print(f"{len(extracted)} extracted, {len(missing)} missing")
sys.exit(1 if missing else 0)
