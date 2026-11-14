#!/usr/bin/env python3
"""Build only the declared package exports in a separate temporary workspace."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
manifest = (root / "build.zig.zon").read_text()
# This package intentionally has a literal .paths list; fail if that changes.
exports = re.search(r'[.]paths = [.]{([^}]+)}', manifest)
if exports is None:
    raise SystemExit("Expected literal package .paths list")
with tempfile.TemporaryDirectory(prefix="libdbus-consumer-") as temporary:
    workspace = Path(temporary)
    package = workspace / "libdbus"
    package.mkdir()
    for name in re.findall(r'"([^"]+)"', exports.group(1)):
        source = root / name
        if not source.resolve().is_relative_to(root):
            raise SystemExit("Package export escapes package root")
        destination = package / name
        if source.is_dir():
            shutil.copytree(source, destination)
        else:
            shutil.copy2(source, destination)
    consumer = workspace / "consumer"
    shutil.copytree(root / "tests" / "consumer", consumer, ignore=shutil.ignore_patterns(".zig-cache", "zig-out"))
    dependency = consumer / "build.zig.zon"
    text = dependency.read_text()
    if text.count('"../.."') != 1:
        raise SystemExit("Expected exactly one local dependency path")
    dependency.write_text(text.replace('"../.."', '"../libdbus"'))
    env = os.environ.copy()
    env["ZIG_GLOBAL_CACHE_DIR"] = str(workspace / "global-cache")
    env["ZIG_LOCAL_CACHE_DIR"] = str(workspace / "local-cache")
    for mode in ("Debug", "ReleaseSafe"):
        subprocess.run([env.get("ZIG", "zig"), "build", "test", "-Doptimize=" + mode, "--summary", "all"], cwd=consumer, env=env, check=True)
    print("Independent consumer passed with exported files and fresh caches", flush=True)
