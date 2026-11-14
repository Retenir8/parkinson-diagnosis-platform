"""Keep a publishable Shoes algorithm copy inside System.

Only connection settings are replaced with environment variables. The sensor
and gait algorithms stay unchanged. Recordings and third-party manuals remain
local to the original Shoes directory and are never copied into this repo.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path


SYSTEM_ROOT = Path(__file__).resolve().parents[2]
SOURCE_ROOT = SYSTEM_ROOT.parent / "Shoes"
TARGET_ROOT = SYSTEM_ROOT / "integrations" / "shoes_reference"


def source_files(root: Path) -> list[Path]:
    files = [
        path for path in root.rglob("*")
        if path.is_file()
        and path.relative_to(root).parts[0]
        not in {".git", "data", "diagnostics", "docs", "log", "third_party"}
    ]
    return sorted(files)


def source_gateway_ids(root: Path) -> tuple[bytes, bytes]:
    main = (root / "runMqttGaitLowLatency.m").read_bytes()
    identifiers = re.findall(
        rb'cfg\.mqtt\.(?:left|right)GatewayPreference, "([0-9A-F]{12})"',
        main,
    )
    if len(identifiers) != 2:
        raise RuntimeError("Shoes gateway defaults changed")
    return identifiers[0], identifiers[1]


def publishable_content(
    path: Path, relative: Path, gateway_ids: tuple[bytes, bytes]
) -> bytes:
    # Use stable LF bytes in the manifest on Windows and on fresh clones.
    content = path.read_bytes().replace(b"\r\n", b"\n")
    if relative.parts[0] == "tests" or relative.as_posix() == "src/io/decodeMqttSensorMessage.m":
        return (
            content.replace(gateway_ids[0], b"AABBCCDDEEFF")
            .replace(gateway_ids[1], b"112233445566")
        )
    if relative.as_posix() == "runMqttGaitLowLatency.m":
        text = content.decode("utf-8").replace("\r\n", "\n")
        newline = "\n"
        settings = {
            "host": "MEDVISION_SHOES_MQTT_HOST",
            "username": "MEDVISION_SHOES_MQTT_USERNAME",
            "password": "MEDVISION_SHOES_MQTT_PASSWORD",
        }
        for field, variable in settings.items():
            pattern = rf'(?m)^cfg\.mqtt\.{field} = "[^"]+";$'
            replacement = f"cfg.mqtt.{field} = string(getenv('{variable}'));"
            text, count = re.subn(pattern, replacement, text)
            if count != 1:
                raise RuntimeError(f"Shoes connection setting changed: {field}")
        validation = (
            "if any(strlength([cfg.mqtt.host, cfg.mqtt.username, cfg.mqtt.password]) == 0)"
            + newline
            + "    error('Shoes:MissingMqttConfig', 'Set MEDVISION_SHOES_MQTT_HOST, MEDVISION_SHOES_MQTT_USERNAME and MEDVISION_SHOES_MQTT_PASSWORD.');"
            + newline
            + "end"
        )
        anchor = 'cfg.mqtt.clientID = "matlab_gait_low_latency";'
        if text.count(anchor) != 1:
            raise RuntimeError("Shoes connection configuration layout changed")
        text = text.replace(anchor, validation + newline + anchor)
        gateway_replacements = (
            (
                r'(?m)^    cfg\.mqtt\.leftGatewayPreference, "[0-9A-F]{12}"\);$',
                "    cfg.mqtt.leftGatewayPreference, leftGatewayDefault);",
            ),
            (
                r'(?m)^    cfg\.mqtt\.rightGatewayPreference, "[0-9A-F]{12}"\);$',
                "    cfg.mqtt.rightGatewayPreference, rightGatewayDefault);",
            ),
            (
                r'(?m)^        cfg, "[0-9A-F]{12}", "[0-9A-F]{12}"\);$',
                "        cfg, leftGatewayDefault, rightGatewayDefault);",
            ),
        )
        for pattern, replacement in gateway_replacements:
            text, count = re.subn(pattern, replacement, text)
            if count != 1:
                raise RuntimeError("Shoes gateway defaults changed")
        gateway_anchor = "leftGatewayId = getGatewayPreference( ..."
        if text.count(gateway_anchor) != 1:
            raise RuntimeError("Shoes gateway configuration layout changed")
        text = text.replace(
            gateway_anchor,
            "leftGatewayDefault = string(getenv('MEDVISION_SHOES_LEFT_GATEWAY_ID'));"
            + newline
            + "rightGatewayDefault = string(getenv('MEDVISION_SHOES_RIGHT_GATEWAY_ID'));"
            + newline
            + gateway_anchor,
        )
        return text.encode("utf-8")
    if relative.as_posix() == "README.md":
        text = content.decode("utf-8").replace("\r\n", "\n")
        text = text.replace(
            "- `data/calibration_walks/` contains the retained calibration recordings.",
            "- `data/calibration_walks/` is local-only and is not committed to Git.",
        ).replace(
            "- `diagnostics/` contains MQTT timing tools and smoke-test artifacts.",
            "- `diagnostics/` is local-only and is not committed to Git.",
        ).replace(
            "- `docs/` contains the HiPNUC IMU manual.",
            "- The device manual remains local and is not committed to Git.",
        ).replace(
            "- `third_party/ximu_matlab_library/` is retained as a reference implementation\n"
            "  and is not added to the runtime MATLAB path.",
            "- The xIMU third-party reference remains local and is not on the runtime path.",
        )
        text += (
            "\nThe published main program reads MQTT host, username, password and optional\n"
            "gateway defaults from `MEDVISION_SHOES_MQTT_HOST`,\n"
            "`MEDVISION_SHOES_MQTT_USERNAME`, `MEDVISION_SHOES_MQTT_PASSWORD`,\n"
            "`MEDVISION_SHOES_LEFT_GATEWAY_ID` and `MEDVISION_SHOES_RIGHT_GATEWAY_ID`.\n"
        )
        return text.encode("utf-8")
    if relative.as_posix() in {
        "src/io/crc16_imu_frame.m",
        "src/io/crc16_update_matlab.m",
    }:
        return content.rstrip(b"\n") + b"\n"
    return content


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sync(check: bool = False, source: Path = SOURCE_ROOT) -> dict[str, str]:
    if not source.is_dir():
        raise FileNotFoundError(f"Shoes source directory is missing: {source}")
    manifest: dict[str, str] = {}
    gateway_ids = source_gateway_ids(source)
    for path in source_files(source):
        relative = path.relative_to(source)
        target = TARGET_ROOT / relative
        published = publishable_content(path, relative, gateway_ids)
        source_hash = hashlib.sha256(published).hexdigest()
        manifest[relative.as_posix()] = source_hash
        if check:
            if not target.is_file() or sha256(target) != source_hash:
                raise AssertionError(f"Shoes source drift: {relative}")
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(published)
    manifest_path = TARGET_ROOT / "SOURCE_MANIFEST.json"
    if check:
        if not manifest_path.is_file() or json.loads(manifest_path.read_text("utf-8")) != manifest:
            raise AssertionError("Shoes source manifest is stale")
    else:
        manifest_path.write_bytes(
            (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
        )
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if the copy differs")
    parser.add_argument("--source", type=Path, default=SOURCE_ROOT)
    arguments = parser.parse_args()
    result = sync(check=arguments.check, source=arguments.source)
    print(f"Verified {len(result)} Shoes source files" if arguments.check else f"Copied {len(result)} Shoes source files")
