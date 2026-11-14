"""Build a standalone Shoes executable while preserving the MATLAB reference.

The generated copy changes only deployment path setup and log placement. The
sensor and gait algorithms continue to come from the hash-checked reference.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
from pathlib import Path

from sync_shoes_source import SOURCE_ROOT, SYSTEM_ROOT, TARGET_ROOT, sha256, sync


WORK_ROOT = SYSTEM_ROOT / "server" / "tmp" / "shoes_deploy_source"
DEFAULT_OUTPUT = SYSTEM_ROOT / "server" / "tmp" / "shoes_deploy_build"
BRIDGE = SYSTEM_ROOT / "integrations" / "shoes_bridge" / "runShoesFromSystem.m"


def replace_once(path: Path, old: str, new: str) -> None:
    contents = path.read_text(encoding="utf-8")
    if contents.count(old) != 1:
        raise RuntimeError(f"Shoes deployment patch is no longer valid: {path}")
    path.write_text(contents.replace(old, new), encoding="utf-8")


def prepare_source() -> Path:
    if not (TARGET_ROOT / "runMqttGaitLowLatency.m").is_file():
        raise FileNotFoundError("Run sync_shoes_source.py before building Shoes")
    manifest = json.loads((TARGET_ROOT / "SOURCE_MANIFEST.json").read_text("utf-8"))
    for relative, expected in manifest.items():
        path = TARGET_ROOT / relative
        if not path.is_file() or sha256(path) != expected:
            raise RuntimeError(f"Shoes reference source was changed: {relative}")
    if SOURCE_ROOT.is_dir():
        sync(check=True)
    WORK_ROOT.mkdir(parents=True, exist_ok=True)
    for source in TARGET_ROOT.rglob("*.m"):
        relative = source.relative_to(TARGET_ROOT)
        if relative.parts[0] not in {"src"} and len(relative.parts) != 1:
            continue
        destination = WORK_ROOT / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)

    setup = WORK_ROOT / "setupGaitProject.m"
    replace_once(
        setup,
        "projectRoot = fileparts(mfilename('fullpath'));",
        "if isdeployed\n    projectRoot = ctfroot;\n    return;\nend\n"
        "projectRoot = fileparts(mfilename('fullpath'));",
    )

    log_session = WORK_ROOT / "src" / "logging" / "prepareGaitLogSession.m"
    replace_once(
        log_session,
        "logRootDir = fullfile(projectDir, 'log');",
        "logRootDir = fullfile(projectDir, 'log');\n"
        "if isdeployed\n"
        "    configuredRoot = getenv('MEDVISION_SHOES_LOG_ROOT');\n"
        "    if isempty(configuredRoot)\n"
        "        error('Shoes:MissingLogRoot', ...\n"
        "            'MEDVISION_SHOES_LOG_ROOT must be set by System.');\n"
        "    end\n"
        "    logRootDir = configuredRoot;\n"
        "end",
    )
    return WORK_ROOT


def build(output: Path, compiler: Path) -> Path:
    source = prepare_source()
    output.mkdir(parents=True, exist_ok=True)
    search_paths = [source, *sorted(path for path in (source / "src").rglob("*") if path.is_dir())]
    command = [str(compiler), "-m", "-d", str(output)]
    for path in search_paths:
        command += ["-I", str(path)]
    command += ["-a", str(source), "-a", str(BRIDGE.parent / "deliverShoesSystemCommand.m"), str(BRIDGE)]
    with (output / "build.log").open("w", encoding="utf-8", errors="replace") as log:
        subprocess.run(command, cwd=SYSTEM_ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
    executable = output / "runShoesFromSystem.exe"
    if not executable.is_file():
        raise RuntimeError(f"MATLAB Compiler did not create {executable}")
    return executable


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--compiler", type=Path)
    args = parser.parse_args()
    found = args.compiler or shutil.which("mcc") or shutil.which("mcc.bat")
    if not found:
        matlab = shutil.which("matlab")
        found = Path(matlab).with_name("mcc.bat") if matlab else None
    if not found or not Path(found).is_file():
        parser.error("MATLAB Compiler (mcc) was not found")
    print(build(args.output.resolve(), Path(found)))
