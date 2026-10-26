"""Shared helpers for the tools/ model runners (run_models, run_activity_model,
run_sleep_model). Imported as a sibling module — each runner's directory is on
sys.path[0] when invoked as `python tools/run_*.py`.
"""
import os
import sys
from pathlib import Path


def resolve_models_dir(repo, required=None):
    """Locate the private desktop TorchScript models without coupling repos.

    ``open_health`` owns the runners, while existing decrypted model files may
    still live in the sibling ``open_oura`` checkout after the repository split.
    An explicit environment variable wins so packaged/custom layouts remain
    supported. The returned directory need not exist, allowing each runner to
    report its precise missing model filename.
    """
    configured = os.environ.get("OURA_MODELS_DIR")
    if configured:
        return Path(configured).expanduser()

    candidates = (
        repo / "notes" / "models",
        repo.parent / "open_oura" / "notes" / "models",
    )
    if required:
        return next(
            (path for path in candidates if (path / required).is_file()),
            candidates[0],
        )
    return next((path for path in candidates if path.is_dir()), candidates[0])


def model_versions(models_dir, family, ext=".pt"):
    """Every version of one model family in ``models_dir``, newest first.

    Oura ships several versions per family (``cva_2_1_0``, ``cva_2_1_5``); which ones
    exist locally depends on what was decrypted. A version is digits only, so
    ``cva_calibrator_1_3_0`` is not a ``cva`` version.
    """
    found = []
    for path in Path(models_dir).glob(f"{family}_*{ext}"):
        version = path.name[len(family) + 1:-len(ext)]
        parts = version.split("_")
        if parts and all(p.isdigit() for p in parts):
            found.append((tuple(int(p) for p in parts), path))
    return [p for _, p in sorted(found, reverse=True)]


def resolve_model(repo, family, validated, oldest=None, newest=None, ext=".pt"):
    """The model file for ``family``: the ``validated`` version (the one the runner's
    inputs were checked against) when present, else the newest local version within
    ``oldest``..``newest`` (the versions whose forward() takes the same inputs; e.g.
    AAD 3.1.15 swapped its threshold scalars for a settings tensor). When none
    exists, returns the validated path so the caller's "not found" names it.
    """
    want = f"{family}_{validated}{ext}"
    models_dir = resolve_models_dir(repo, want)
    if (models_dir / want).is_file():
        return models_dir / want
    key = lambda v: tuple(int(p) for p in v.split("_"))
    lo = key(oldest or validated)
    hi = key(newest) if newest else (float("inf"),)
    for d in (models_dir, repo / "notes" / "models", repo.parent / "open_oura" / "notes" / "models"):
        for path in (model_versions(d, family, ext) if d.is_dir() else []):
            if lo <= key(path.stem[len(family) + 1:]) <= hi:
                return path
    return models_dir / want


def discover_models(models_dir, newest_only=True, ext=".pt"):
    """Model names (file stems) in ``models_dir``, sorted; with ``newest_only``, one
    per family, the newest version. ``foo_bar_1_2_0`` is family ``foo_bar``."""
    families = {}
    for path in Path(models_dir).glob(f"*{ext}"):
        parts = path.stem.split("_")
        n = len(parts)
        while n > 0 and parts[n - 1].isdigit():
            n -= 1
        if n == 0 or n == len(parts):
            continue  # no family name, or no version (e.g. a helper file)
        family = "_".join(parts[:n])
        key = tuple(int(p) for p in parts[n:])
        families.setdefault(family, []).append((key, path.stem))
    names = []
    for versions in families.values():
        versions.sort(reverse=True)
        names.extend(v for _, v in (versions[:1] if newest_only else versions))
    return sorted(names)


def model_version(path, family):
    """``.../cva_2_1_5.pt`` → ``"2.1.5"``."""
    return Path(path).stem[len(family) + 1:].replace("_", ".")


def resolve_db(arg, repo):
    """Resolve the SQLite events DB path.

    Explicit ``arg`` wins; otherwise pick the first existing default among
    ./oura.db, repo/oura.db, repo/captures/ring5.db, falling back to
    repo/oura.db. Exit with a clear error if the resolved DB is missing.
    """
    if arg:
        db = Path(arg)
    else:
        db = next(
            (c for c in (Path.cwd() / "oura.db", repo / "oura.db",
                         repo / "captures" / "ring5.db") if c.exists()),
            repo / "oura.db",
        )
    if not db.exists():
        sys.exit(f"error: database not found: {db} (run `oura sync` first)")
    return db
