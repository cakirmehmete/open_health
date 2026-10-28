#!/usr/bin/env python3
"""Introspect every (newest-version) decrypted Oura model: dump its forward()
input/output schema and top-level submodules, so we know each model's input
contract before wiring it to our data.

Usage: python tools/inspect_models.py [--json] [--all-versions]
Models live in notes/models/ (gitignored). The JSON holds only signatures (no
weights), so it can be shared to wire a runner.
"""
import json
import sys
from pathlib import Path

import torch

from _common import discover_models, resolve_models_dir

REPO = Path(__file__).resolve().parent.parent
MODELS_DIR = resolve_models_dir(REPO)

# Every decrypted model is discovered on its own (newest version per family by
# default, `--all-versions` for every file), so a new APK's versions need no edit here.


def describe(name):
    path = MODELS_DIR / f"{name}.pt"
    info = {"model": name, "loaded": False}
    if not path.exists():
        info["error"] = "file missing"
        return info
    try:
        m = torch.jit.load(str(path), map_location="cpu").eval()
    except Exception as e:
        info["error"] = f"load failed: {e}"
        return info
    info["loaded"] = True

    # forward schema (arg names + types + defaults)
    try:
        sch = m.forward.schema
        args = []
        for a in sch.arguments:
            if a.name == "self":
                continue
            d = {"name": a.name, "type": str(a.type)}
            if a.has_default_value():
                d["default"] = str(a.default_value)
            args.append(d)
        info["forward_args"] = args
        info["forward_returns"] = str(sch.returns[0].type) if sch.returns else None
    except Exception as e:
        info["forward_error"] = str(e)
        # fall back to listing callable methods
        try:
            info["methods"] = [n for n in dir(m) if not n.startswith("_")][:40]
        except Exception:
            pass

    # top-level named children (architecture hint)
    try:
        info["submodules"] = [n for n, _ in m.named_children()]
    except Exception:
        pass
    return info


def main():
    as_json = "--json" in sys.argv
    names = discover_models(MODELS_DIR, newest_only="--all-versions" not in sys.argv)
    if not names:
        sys.exit(f"no models in {MODELS_DIR} (decrypt them there first)")
    results = [describe(n) for n in names]
    if as_json:
        print(json.dumps(results, indent=2))
        return
    for r in results:
        print("=" * 78)
        print(r["model"])
        if not r.get("loaded"):
            print(f"  !! {r.get('error')}")
            continue
        if "forward_args" in r:
            print("  forward(")
            for a in r["forward_args"]:
                dv = f" = {a['default']}" if "default" in a else ""
                print(f"      {a['name']}: {a['type']}{dv}")
            print(f"  ) -> {r['forward_returns']}")
        else:
            print(f"  forward schema unavailable: {r.get('forward_error')}")
            if r.get("methods"):
                print(f"  methods: {r['methods']}")
        if r.get("submodules"):
            print(f"  submodules: {r['submodules']}")


if __name__ == "__main__":
    main()
