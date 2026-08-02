"""
内容寻址去重（硬链接）
======================
同一份大文件（如 RealSense .bag）无论上传几次、导入几次分割，
物理上只保存一份：首次写入时记录 SHA-256，之后相同内容的文件
用 NTFS 硬链接零拷贝复用（仅限同一卷内）。
硬链接不可用时自动回退为独立副本（原文件保持不变）。

索引文件: {data_dir}/content_index.json
  {"<sha256>": {"size": <int>, "paths": ["<绝对路径>", ...]}}

删除联动：删除平台内文件时调用 ``unlink_ref`` 把路径从索引移除。
硬链接的引用计数由文件系统管理——删除任一链接不影响其他引用。
"""

from __future__ import annotations

import hashlib
import json
import os
import threading
from pathlib import Path
from typing import Any

DEDUP_MIN_SIZE = 1024 * 1024  # 1MB 以下不做去重，避免索引膨胀

_lock = threading.RLock()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _index_path(data_dir: Path) -> Path:
    return data_dir / "content_index.json"


def _load(data_dir: Path) -> dict[str, Any]:
    path = _index_path(data_dir)
    if not path.is_file():
        return {}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
        return payload if isinstance(payload, dict) else {}
    except (OSError, ValueError):
        return {}


def _save(data_dir: Path, index: dict[str, Any]) -> None:
    path = _index_path(data_dir)
    temp_path = path.with_suffix(".json.tmp")
    temp_path.write_text(
        json.dumps(index, ensure_ascii=False, indent=1),
        encoding="utf-8",
    )
    os.replace(temp_path, path)


def _valid_existing(entry: dict[str, Any], expected_size: int) -> Path | None:
    for raw in entry.get("paths", []):
        candidate = Path(str(raw))
        try:
            if candidate.is_file() and candidate.stat().st_size == expected_size:
                return candidate
        except OSError:
            continue
    return None


def deduplicate(data_dir: Path, path: Path) -> Path:
    """让 ``path`` 与平台内已存在的相同内容共享存储（硬链接）。

    - 相同内容已在平台内 → 把 ``path`` 替换为指向已有文件的硬链接；
    - 否则保留原文件，并把其 SHA-256 与路径登记到索引；
    - 小文件或硬链接不可用时原样返回（独立副本语义）。
    """
    path = path.resolve()
    try:
        size = path.stat().st_size
    except OSError:
        return path
    if size < DEDUP_MIN_SIZE:
        return path

    digest = sha256_file(path)
    with _lock:
        index = _load(data_dir)
        entry = index.get(digest)
        if entry is not None:
            existing = _valid_existing(entry, size)
            if existing is not None:
                link_temp = path.with_name(path.name + ".dedup-tmp")
                try:
                    os.link(str(existing), str(link_temp))
                    os.replace(str(link_temp), str(path))
                except OSError:
                    # 硬链接不可用（跨卷/文件系统不支持）→ 保留独立副本
                    try:
                        link_temp.unlink(missing_ok=True)
                    except OSError:
                        pass
                    return path

        entry = index.setdefault(digest, {"size": size, "paths": []})
        entry["size"] = size
        paths = entry.setdefault("paths", [])
        if str(path) not in paths:
            paths.append(str(path))
        _save(data_dir, index)
    return path


def unlink_ref(data_dir: Path, path: Path) -> None:
    """把 ``path`` 从去重索引中移除（不触碰其他硬链接）。

    调用方负责实际的物理删除（unlink/rmtree）。
    """
    path = path.resolve()
    with _lock:
        index = _load(data_dir)
        changed = False
        for digest, entry in list(index.items()):
            paths = [p for p in entry.get("paths", []) if p != str(path)]
            if len(paths) != len(entry.get("paths", [])):
                changed = True
            if paths:
                entry["paths"] = paths
            else:
                index.pop(digest, None)
        if changed:
            _save(data_dir, index)
