#!/usr/bin/env python3
"""Fetch and replace Wallet card artwork through airlift."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import posixpath
import secrets
import select
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from PIL import Image, ImageOps

import airlift


CARDS_PATH = "/var/mobile/Library/Passes/Cards"
PASSES_PATH = posixpath.dirname(CARDS_PATH)
FRONT_FACE = "FrontFace"
PAUSE_MARKER = "ready-for-copy"
STEP_MARKER = "ready-for-step:"


class CardsError(RuntimeError):
    def __init__(self, message: str, details: dict[str, Any] | None = None):
        super().__init__(message)
        self.details = details or {}


@dataclass(frozen=True)
class GeneratedPaths:
    token: str
    source: str
    link: str
    recovered: str
    backup: str

    @classmethod
    def create(cls) -> "GeneratedPaths":
        token = secrets.token_hex(10)
        return cls(
            token=token,
            source=f"{airlift.SOURCE_PREFIX}{token}",
            link=f"{airlift.LINK_PREFIX}{token}",
            recovered=f"{airlift.RECOVERED_PREFIX}{token}",
            backup=f"airlift-backup-{token}",
        )

    @property
    def link_identifier(self) -> str:
        return f"../../{self.source}/p0/p1/p2/link"

    @property
    def payload_identifier(self) -> str:
        return f"../../{self.source}/payload"

    @property
    def barrier_identifier(self) -> str:
        return f"../../{self.source}/barrier"

    @property
    def recovered_identifier(self) -> str:
        return f"../../{self.recovered}"

    @property
    def backup_identifier(self) -> str:
        return f"../../{self.backup}"


@dataclass
class StagedOperation:
    paths: GeneratedPaths
    work: Path
    snapshot: Path
    target_directory: str


def progress(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def json_result(value: dict[str, Any]) -> None:
    print(json.dumps(value, ensure_ascii=False, sort_keys=True))


def ensure_helpers() -> None:
    if not airlift.DEVICE_HELPER.is_file() or not airlift.AIRTRAFFIC_HOST.is_file():
        raise CardsError("ヘルパーが未ビルドです。先に make を実行してください。")


def operation_ok(result: dict[str, Any]) -> bool:
    return airlift.operation_ok(result)


def checked_native(command: str, udid: str, *arguments: str) -> dict[str, Any]:
    result = airlift.native(command, udid, *arguments)
    if not operation_ok(result):
        raise CardsError(f"device_helper {command} が失敗しました", {command: result})
    return result


def list_devices() -> list[dict[str, Any]]:
    command = [
        "xcrun",
        "devicectl",
        "list",
        "devices",
        "--timeout",
        "8",
        "--quiet",
        "--json-output",
        "-",
    ]
    completed = subprocess.run(
        command,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=12,
    )
    rows = json.loads(completed.stdout)["result"]["devices"]
    connected: list[dict[str, Any]] = []
    for item in airlift.available_devices(rows):
        raw = next(
            (
                row
                for row in rows
                if (
                    row.get("hardwareProperties", {}).get("udid")
                    or row.get("properties", {}).get("hardware", {}).get("udid")
                )
                == item["udid"]
            ),
            {},
        )
        connection = raw.get("properties", {}).get("connection", {})
        if not isinstance(connection, dict):
            connection = {}
        state = connection.get("state")
        if isinstance(state, str) and state.casefold() not in {
            "connected",
            "available",
        }:
            continue
        connected.append(item)
    return connected


def validate_device(udid: str) -> dict[str, Any]:
    devices = list_devices()
    for device in devices:
        if device["udid"].casefold() == udid.casefold():
            checked_native("probe", udid)
            return device
    raise CardsError("選択したiPhoneは現在接続されていません")


def devicectl_json(arguments: list[str], timeout: int = 20) -> dict[str, Any]:
    completed = subprocess.run(
        ["xcrun", "devicectl", *arguments, "--quiet", "--json-output", "-"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
    )
    try:
        result = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise CardsError("devicectlからJSON結果を取得できませんでした") from error
    if completed.returncode != 0 or result.get("info", {}).get("outcome") != "success":
        raise CardsError("devicectlの端末操作に失敗しました", {"devicectl": result})
    return result


def springboard_pid(udid: str) -> int:
    result = devicectl_json(
        [
            "device",
            "info",
            "processes",
            "--device",
            udid,
            "--search",
            "SpringBoard",
            "--timeout",
            "15",
        ]
    )
    for process in result.get("result", {}).get("runningProcesses", []):
        executable = process.get("executable")
        pid = process.get("processIdentifier")
        if (
            isinstance(executable, str)
            and executable.endswith("/SpringBoard.app/SpringBoard")
            and isinstance(pid, int)
        ):
            return pid
    raise CardsError("SpringBoardのプロセスを取得できませんでした")


def wallet_display_processes(udid: str) -> list[dict[str, Any]]:
    suffixes = (
        "/PassbookUIService.app/PassbookUIService",
        "/PassbookUISceneService.app/PassbookUISceneService",
        "/Passbook.app/Passbook",
        "/WalletApp.app/WalletApp",
    )
    processes: dict[int, dict[str, Any]] = {}
    for search in ("Passbook", "Wallet"):
        result = devicectl_json(
            [
                "device",
                "info",
                "processes",
                "--device",
                udid,
                "--search",
                search,
                "--timeout",
                "15",
            ]
        )
        for process in result.get("result", {}).get("runningProcesses", []):
            executable = process.get("executable")
            pid = process.get("processIdentifier")
            if (
                isinstance(executable, str)
                and executable.endswith(suffixes)
                and isinstance(pid, int)
            ):
                processes[pid] = {
                    "pid": pid,
                    "executable": executable,
                }
    return list(processes.values())


def signal_process(udid: str, pid: int) -> dict[str, Any]:
    return devicectl_json(
        [
            "device",
            "process",
            "signal",
            "--device",
            udid,
            "--pid",
            str(pid),
            "--signal",
            "15",
            "--timeout",
            "15",
        ]
    )


def restart_wallet_display(udid: str) -> dict[str, Any]:
    springboard_before = springboard_pid(udid)
    wallet_processes = wallet_display_processes(udid)
    terminated_wallet_processes = []
    for process in wallet_processes:
        try:
            signal_process(udid, process["pid"])
            terminated_wallet_processes.append(process)
        except CardsError:
            # A service may exit after its owning app is terminated.
            continue
    launch_result = devicectl_json(
        [
            "device",
            "process",
            "launch",
            "--device",
            udid,
            "--terminate-existing",
            "--activate",
            "--timeout",
            "15",
            "com.apple.Passbook",
        ]
    )
    springboard_after = springboard_pid(udid)
    if springboard_after != springboard_before:
        raise CardsError("Wallet再起動中にSpringBoardのPIDが変化しました")
    return {
        "ok": True,
        "springboardPID": springboard_after,
        "terminatedWalletProcesses": terminated_wallet_processes,
        "walletProcess": launch_result.get("result", {}).get("process"),
    }


def target_identifier(path: str) -> str:
    return posixpath.relpath(path, airlift.AIRLOCK_ROOT)


def lexical_target_identifier(path: str) -> str:
    relative = target_identifier(path)
    directory, leaf = posixpath.split(relative)
    return f"{directory}/./{leaf}"


def stage_operation(
    udid: str,
    target_directory: str,
    payload: bytes,
    identifiers: list[str],
    work: Path,
    paths: GeneratedPaths | None = None,
    snapshot: Path | None = None,
) -> StagedOperation:
    generated = paths or GeneratedPaths.create()
    work.mkdir(parents=True, exist_ok=False)
    snapshot_root = snapshot or (work / "books-snapshot")
    if snapshot is None:
        snapshot_root.mkdir()
    archive = work / "payload.zip"
    books = work / "Books.plist"
    archive.write_bytes(airlift.build_archive(target_directory, payload))
    books.write_bytes(airlift.build_books(identifiers))
    command = "stage" if snapshot is not None else "snapshot-and-stage"
    stage = airlift.native(
        command,
        udid,
        generated.source,
        generated.link,
        generated.recovered,
        os.fspath(archive),
        os.fspath(books),
        os.fspath(snapshot_root),
    )
    if not operation_ok(stage):
        cleanup = airlift.native(
            "cleanup-generated",
            udid,
            generated.source,
            generated.link,
            generated.recovered,
            "-",
            os.fspath(snapshot_root),
        )
        raise CardsError(
            "端末への準備データ配置に失敗しました",
            {"stage": stage, "cleanup": cleanup},
        )
    return StagedOperation(generated, work, snapshot_root, target_directory)


def parse_json_output(output: str) -> dict[str, Any]:
    for line in reversed(output.splitlines()):
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            return value
    raise CardsError("airtraffic_host からJSON結果を取得できませんでした")


def run_host_paused(
    udid: str,
    identifiers: list[str],
    destinations: list[str],
    pause_after: int,
    while_paused: Callable[[], None],
) -> dict[str, Any]:
    command = [
        os.fspath(airlift.AIRTRAFFIC_HOST),
        udid,
        "--pause-after",
        str(pause_after),
    ]
    if len(identifiers) != len(destinations):
        raise CardsError("識別子と保存先の数が一致しません")
    for identifier, destination in zip(identifiers, destinations):
        command.extend((identifier, destination))
    process = subprocess.Popen(
        command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    assert process.stdin and process.stdout and process.stderr
    deadline = time.monotonic() + 135
    paused = False
    stderr_lines: list[str] = []
    callback_error: Exception | None = None
    while process.poll() is None and time.monotonic() < deadline and not paused:
        readable, _, _ = select.select(
            [process.stderr, process.stdout], [], [], 0.5
        )
        for stream in readable:
            line = stream.readline()
            if stream is process.stderr and line:
                stderr_lines.append(line)
                if PAUSE_MARKER in line:
                    paused = True
                    break
    if paused:
        try:
            while_paused()
        except Exception as error:
            callback_error = error
        finally:
            process.stdin.write("c")
            process.stdin.flush()
    remaining = max(1, int(deadline - time.monotonic()))
    try:
        stdout, stderr = process.communicate(timeout=remaining)
    except subprocess.TimeoutExpired as error:
        process.kill()
        stdout, stderr = process.communicate()
        raise CardsError(
            "airtraffic_host が時間内に完了しませんでした",
            {"stdout": stdout, "stderr": "".join(stderr_lines) + stderr},
        ) from error
    stderr_text = "".join(stderr_lines) + stderr
    result = parse_json_output(stdout)
    result["exitCode"] = process.returncode
    result["pauseObserved"] = paused
    if callback_error:
        callback_details = (
            callback_error.details
            if isinstance(callback_error, CardsError)
            else {"message": str(callback_error)}
        )
        raise CardsError(
            f"端末データの取得中に失敗しました: {callback_error}",
            {
                "airTraffic": result,
                "callback": callback_details,
                "stderr": stderr_text,
            },
        ) from callback_error
    if process.returncode != 0 or not result.get("ok") or not paused:
        raise CardsError(
            "AirTraffic処理が完了しませんでした",
            {"airTraffic": result, "stderr": stderr_text},
        )
    return result


def run_host_stepped(
    udid: str,
    identifiers: list[str],
    destinations: list[str],
    after_steps: list[Callable[[], None]],
) -> dict[str, Any]:
    if len(identifiers) != len(destinations) or len(after_steps) != len(identifiers):
        raise CardsError("AirTrafficの段階数が一致しません")
    command = [os.fspath(airlift.AIRTRAFFIC_HOST), udid, "--step"]
    for identifier, destination in zip(identifiers, destinations):
        command.extend((identifier, destination))
    process = subprocess.Popen(
        command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    assert process.stdin and process.stdout and process.stderr
    deadline = time.monotonic() + 135
    completed_steps: list[int] = []
    stderr_lines: list[str] = []
    stdout_lines: list[str] = []
    callback_error: Exception | None = None
    while process.poll() is None and time.monotonic() < deadline:
        readable, _, _ = select.select(
            [process.stderr, process.stdout], [], [], 0.5
        )
        for stream in readable:
            line = stream.readline()
            if not line:
                continue
            if stream is process.stdout:
                stdout_lines.append(line)
                continue
            stderr_lines.append(line)
            if STEP_MARKER not in line:
                continue
            try:
                step = int(line.rsplit(STEP_MARKER, 1)[1].strip())
                if step != len(completed_steps):
                    raise CardsError("AirTrafficの段階順が不正です")
                after_steps[step]()
                completed_steps.append(step)
            except Exception as error:
                callback_error = error
            finally:
                process.stdin.write("c")
                process.stdin.flush()
            if callback_error:
                break
        if callback_error:
            break
    if callback_error and process.poll() is None:
        process.terminate()
    remaining = max(1, int(deadline - time.monotonic()))
    try:
        stdout, stderr = process.communicate(timeout=remaining)
    except subprocess.TimeoutExpired as error:
        process.kill()
        stdout, stderr = process.communicate()
        raise CardsError(
            "airtraffic_host が時間内に完了しませんでした",
            {
                "stdout": "".join(stdout_lines) + stdout,
                "stderr": "".join(stderr_lines) + stderr,
                "completedSteps": completed_steps,
            },
        ) from error
    stdout_text = "".join(stdout_lines) + stdout
    stderr_text = "".join(stderr_lines) + stderr
    try:
        result = parse_json_output(stdout_text)
    except CardsError:
        if callback_error is None:
            raise
        result = {"ok": False}
    result["exitCode"] = process.returncode
    result["completedSteps"] = completed_steps
    if callback_error:
        callback_details = (
            callback_error.details
            if isinstance(callback_error, CardsError)
            else {"message": str(callback_error)}
        )
        raise CardsError(
            f"端末状態の確認中に失敗しました: {callback_error}",
            {
                "airTraffic": result,
                "callback": callback_details,
                "stderr": stderr_text,
            },
        ) from callback_error
    if (
        process.returncode != 0
        or not result.get("ok")
        or completed_steps != list(range(len(after_steps)))
    ):
        raise CardsError(
            "AirTraffic処理が完了しませんでした",
            {"airTraffic": result, "stderr": stderr_text},
        )
    return result


def wait_for_operation_state(
    udid: str,
    operation: StagedOperation,
    predicate: Callable[[dict[str, Any]], bool],
    *,
    include_backup: bool = False,
) -> dict[str, Any]:
    deadline = time.monotonic() + 5
    status: dict[str, Any] = {}
    while time.monotonic() < deadline:
        status = generated_status(
            udid, operation, include_backup=include_backup
        )
        if predicate(status):
            return status
        time.sleep(0.05)
    raise CardsError(
        "端末上のAirTraffic処理を確認できませんでした",
        {"generatedStatus": status},
    )


def run_host(
    udid: str,
    identifiers: list[str],
    destinations: list[str],
) -> dict[str, Any]:
    if len(identifiers) != len(destinations):
        raise CardsError("識別子と保存先の数が一致しません")
    command = [os.fspath(airlift.AIRTRAFFIC_HOST), udid]
    for identifier, destination in zip(identifiers, destinations):
        command.extend((identifier, destination))
    result = airlift.run_json(command, timeout=150)
    if result.get("exitCode") != 0 or not result.get("ok"):
        raise CardsError("AirTraffic処理が完了しませんでした", {"airTraffic": result})
    return result


def generated_status(
    udid: str, operation: StagedOperation, *, include_backup: bool
) -> dict[str, Any]:
    backup = operation.paths.backup if include_backup else "-"
    return checked_native(
        "generated-status",
        udid,
        operation.paths.source,
        operation.paths.link,
        operation.paths.recovered,
        backup,
    )["operation"]


def wait_for_generated_status(
    udid: str,
    operation: StagedOperation,
    *,
    include_backup: bool,
    recovered_present: bool,
    backup_present: bool | None = None,
) -> dict[str, Any]:
    backup = operation.paths.backup if include_backup else "-"
    return checked_native(
        "wait-generated-status",
        udid,
        operation.paths.source,
        operation.paths.link,
        operation.paths.recovered,
        backup,
        "1" if recovered_present else "0",
        "-" if backup_present is None else ("1" if backup_present else "0"),
    )["operation"]


def cleanup_operation(
    udid: str, operation: StagedOperation, *, include_backup: bool
) -> dict[str, Any]:
    backup = operation.paths.backup if include_backup else "-"
    return checked_native(
        "cleanup-generated",
        udid,
        operation.paths.source,
        operation.paths.link,
        operation.paths.recovered,
        backup,
        os.fspath(operation.snapshot),
    )["operation"]


def pull_generated(
    udid: str,
    remote_name: str,
    destination: Path,
    *,
    card_catalog_only: bool = False,
) -> dict[str, Any]:
    destination.parent.mkdir(parents=True, exist_ok=True)
    command = "pull-card-catalog" if card_catalog_only else "pull-generated"
    return checked_native(
        command,
        udid,
        remote_name,
        os.fspath(destination),
    )["operation"]


def uid_index(value: Any) -> int:
    if not isinstance(value, plistlib.UID):
        raise CardsError("FrontFace内の参照形式が想定と異なります")
    return value.data


def decode_front_face(path: Path) -> tuple[bytes, dict[str, Any], bytes]:
    data = path.read_bytes()
    if len(data) < 56 or data[48:56] != b"bplist00":
        raise CardsError(f"FrontFace形式を認識できません: {path}")
    archive_data = data[48:]
    if hashlib.sha256(archive_data).digest() != data[16:48]:
        raise CardsError(f"FrontFaceのハッシュが一致しません: {path}")
    archive = plistlib.loads(archive_data)
    if not isinstance(archive, dict) or not isinstance(archive.get("$objects"), list):
        raise CardsError("FrontFaceのアーカイブが想定と異なります")
    objects = archive["$objects"]
    root = objects[uid_index(archive["$top"]["root"])]
    face = objects[uid_index(root["faceImage"])]
    data_object = objects[uid_index(face["imageData"])]
    png = data_object["NS.data"]
    if not isinstance(png, bytes) or not png.startswith(b"\x89PNG\r\n\x1a\n"):
        raise CardsError("FrontFaceの画像データがPNGではありません")
    return data[:16], archive, png


def image_from_bytes(data: bytes) -> Image.Image:
    import io

    with Image.open(io.BytesIO(data)) as image:
        return image.convert("RGBA")


def front_face_image(path: Path) -> Image.Image:
    _, _, png = decode_front_face(path)
    return image_from_bytes(png)


def safe_pass_root(cards_root: Path, card_id: str) -> Path:
    if not card_id or "/" in card_id or "\0" in card_id:
        raise CardsError("カードIDが不正です")
    root = cards_root.resolve()
    pass_root = (root / f"{card_id}.pkpass").resolve()
    if pass_root.parent != root or not pass_root.is_dir():
        raise CardsError("選択したカードのpkpassがありません")
    return pass_root


def card_artwork_asset(pass_root: Path) -> Path | None:
    preferred = [
        "cardBackgroundCombined.pdf",
        "cardBackgroundCombined@3x.png",
        "cardBackgroundCombined@2x.png",
        "cardBackgroundCombined.png",
    ]
    for name in preferred:
        path = pass_root / name
        if path.is_file():
            return path
    return None


def pass_metadata(pass_path: Path) -> dict[str, Any]:
    if not pass_path.is_dir():
        return {}
    json_path = pass_path / "pass.json"
    if json_path.is_file():
        try:
            value = json.loads(json_path.read_text(encoding="utf-8"))
            return value if isinstance(value, dict) else {}
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            return {}
    if pass_path.is_file():
        try:
            with zipfile.ZipFile(pass_path) as archive:
                value = json.loads(archive.read("pass.json"))
            return value if isinstance(value, dict) else {}
        except (OSError, KeyError, zipfile.BadZipFile, json.JSONDecodeError):
            return {}
    return {}


def find_cards_root(download_root: Path) -> Path:
    candidates = [download_root]
    candidates.extend(path for path in download_root.rglob("*") if path.is_dir())
    ranked = sorted(
        ((len(list(path.glob("*.pkpass"))), path) for path in candidates),
        key=lambda item: item[0],
        reverse=True,
    )
    if not ranked or ranked[0][0] == 0:
        raise CardsError("取得したCards内に支払いカードがありません")
    return ranked[0][1]


def create_catalog(download_root: Path, output_root: Path) -> dict[str, Any]:
    cards_root = find_cards_root(download_root)
    thumbnails = output_root / "Thumbnails"
    thumbnails.mkdir(exist_ok=True)
    cards: list[dict[str, Any]] = []
    for pass_root in sorted(
        cards_root.glob("*.pkpass"), key=lambda path: path.name
    ):
        card_id = pass_root.name.removesuffix(".pkpass")
        metadata = pass_metadata(pass_root)
        if "paymentCard" not in metadata:
            continue
        artwork = card_artwork_asset(pass_root)
        front_face = cards_root / f"{card_id}.cache" / FRONT_FACE
        reference = front_face if front_face.is_file() else artwork
        if reference is None:
            progress(f"スキップ: {pass_root.name}: 券面データがありません")
            continue
        try:
            if reference == front_face:
                image = front_face_image(reference)
            else:
                with tempfile.TemporaryDirectory(
                    prefix="airlift-catalog-"
                ) as temporary:
                    image = load_input_image(reference, Path(temporary))
        except CardsError as error:
            progress(f"スキップ: {pass_root.name}: {error}")
            continue
        thumbnail = image.copy()
        thumbnail.thumbnail((520, 320), Image.Resampling.LANCZOS)
        thumbnail_path = thumbnails / f"{hashlib.sha256(card_id.encode()).hexdigest()}.png"
        thumbnail.save(thumbnail_path, "PNG", optimize=True)
        organization = metadata.get("organizationName")
        description = metadata.get("description")
        title = organization if isinstance(organization, str) else description
        if not isinstance(title, str) or not title.strip():
            title = card_id
        suffix = metadata.get("primaryAccountNumberSuffix")
        if not isinstance(suffix, str):
            suffix = metadata.get("primaryAccountSuffix")
        subtitle = f"•••• {suffix}" if isinstance(suffix, str) and suffix else ""
        cards.append(
            {
                "id": card_id,
                "title": title,
                "subtitle": subtitle,
                "thumbnailPath": os.fspath(thumbnail_path.resolve()),
                "artworkPath": (
                    os.fspath(artwork.resolve()) if artwork is not None else None
                ),
                "artworkFileName": artwork.name if artwork is not None else None,
            }
        )
    catalog = {
        "cardsRoot": os.fspath(cards_root.resolve()),
        "cards": cards,
        "count": len(cards),
    }
    (output_root / "catalog.json").write_text(
        json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True),
        encoding="utf-8",
    )
    return catalog


def tree_manifest(root: Path) -> dict[str, str]:
    return {
        path.relative_to(root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }


def emergency_restore(
    udid: str,
    original_operation: StagedOperation,
    remote_original: str,
    target_path: str,
    local_original: Path | None,
    *,
    original_in_backup_slot: bool,
) -> dict[str, Any]:
    """Restore a displaced original through a fresh symlink transaction."""
    old_status = generated_status(
        udid,
        original_operation,
        include_backup=original_in_backup_slot,
    )
    present_key = "backupPresent" if original_in_backup_slot else "recoveredPresent"
    if not old_status.get(present_key):
        cleanup = cleanup_operation(
            udid,
            original_operation,
            include_backup=original_in_backup_slot,
        )
        return {
            "ok": True,
            "attempted": False,
            "reason": "original export is absent; the primary restore completed",
            "generatedStatus": old_status,
            "cleanup": cleanup,
        }

    progress("処理を中断し、元のデータを端末へ戻しています…")
    checked_native(
        "restore-books", udid, os.fspath(original_operation.snapshot)
    )
    recovery_paths = GeneratedPaths.create()
    recovery_work = original_operation.work.parent / (
        f".airlift-recovery-{recovery_paths.token}"
    )
    target_directory, leaf = posixpath.split(target_path)
    identifiers = [
        recovery_paths.link_identifier,
        target_identifier(target_path),
        f"../../{remote_original}",
        lexical_target_identifier(target_path),
        recovery_paths.recovered_identifier,
    ]
    recovery = stage_operation(
        udid,
        target_directory,
        b"airlift recovery\n",
        identifiers,
        recovery_work,
        recovery_paths,
        original_operation.snapshot,
    )
    verification = recovery_work.parent / (
        f".airlift-recovery-verify-{recovery_paths.token}"
    )
    verified = False

    def verify_original() -> None:
        nonlocal verified
        pull_generated(udid, recovery_paths.recovered, verification)
        if local_original is None or not local_original.exists():
            verified = verification.exists()
        elif local_original.is_dir():
            verified = tree_manifest(local_original) == tree_manifest(verification)
        else:
            verified = local_original.read_bytes() == verification.read_bytes()

    air_traffic = run_host_paused(
        udid,
        identifiers,
        [
            recovery_paths.link,
            recovery_paths.backup,
            f"{recovery_paths.link}/{leaf}",
            recovery_paths.recovered,
            f"{recovery_paths.link}/{leaf}",
        ],
        3,
        verify_original,
    )
    recovery_status = wait_for_generated_status(
        udid,
        recovery,
        include_backup=True,
        recovered_present=False,
        backup_present=True,
    )
    if not verified or recovery_status["recoveredPresent"]:
        raise CardsError(
            "元データの自動復元を検証できませんでした",
            {
                "verificationOK": verified,
                "generatedStatus": recovery_status,
                "recoveryWorkPath": os.fspath(recovery_work),
            },
        )
    recovery_cleanup = cleanup_operation(udid, recovery, include_backup=True)
    original_cleanup = cleanup_operation(
        udid,
        original_operation,
        include_backup=original_in_backup_slot,
    )
    if verification.is_dir():
        shutil.rmtree(verification, ignore_errors=True)
    else:
        verification.unlink(missing_ok=True)
    shutil.rmtree(recovery_work, ignore_errors=True)
    return {
        "ok": True,
        "attempted": True,
        "verifiedOriginalBytes": verified,
        "airTraffic": air_traffic,
        "recoveryCleanup": recovery_cleanup,
        "originalCleanup": original_cleanup,
    }


def fetch_cards(udid: str, output: Path) -> dict[str, Any]:
    ensure_helpers()
    if output.exists():
        raise CardsError("出力先は存在しないパスを指定してください")
    output.parent.mkdir(parents=True, exist_ok=True)
    work = output.parent / f".airlift-fetch-{secrets.token_hex(8)}"
    paths = GeneratedPaths.create()
    identifiers = [
        target_identifier(CARDS_PATH),
        paths.link_identifier,
        paths.recovered_identifier,
    ]
    operation: StagedOperation | None = None
    output.mkdir()
    download = output / "Cards"
    try:
        progress("Cardsを端末から退避しています…")
        operation = stage_operation(
            udid,
            PASSES_PATH,
            b"airlift cards fetch\n",
            identifiers,
            work,
            paths,
        )

        def copy_cards() -> None:
            progress("CardsをMacへコピーしています…")
            pull_generated(
                udid,
                paths.recovered,
                download,
                card_catalog_only=True,
            )

        def wait_for_link() -> None:
            wait_for_operation_state(
                udid,
                operation,
                lambda status: status["recoveredPresent"]
                and status["linkPresent"],
            )

        def wait_for_restoration() -> None:
            wait_for_operation_state(
                udid,
                operation,
                lambda status: not status["recoveredPresent"],
            )

        air_traffic = run_host_stepped(
            udid,
            identifiers,
            [paths.recovered, paths.link, f"{paths.link}/Cards"],
            [copy_cards, wait_for_link, wait_for_restoration],
        )
        cleanup = cleanup_operation(udid, operation, include_backup=False)
        progress("カード一覧を作成しています…")
        catalog = create_catalog(download, output)
        result = {
            "ok": True,
            "snapshotPath": os.fspath(output.resolve()),
            **catalog,
            "airTraffic": air_traffic,
            "cleanup": cleanup,
        }
        shutil.rmtree(work, ignore_errors=True)
        return result
    except Exception as error:
        recovery = {
            "workPath": os.fspath(work),
            "outputPath": os.fspath(output),
            "message": "端末側の一時データを保持しました。",
        }
        if operation:
            try:
                recovery["automaticRestore"] = emergency_restore(
                    udid,
                    operation,
                    paths.recovered,
                    CARDS_PATH,
                    None,
                    original_in_backup_slot=False,
                )
                recovery["message"] = "元のCardsを端末へ復元しました。"
            except Exception as status_error:
                recovery["automaticRestoreError"] = str(status_error)
        if isinstance(error, CardsError):
            error.details.setdefault("recovery", recovery)
            raise
        raise CardsError(str(error), {"recovery": recovery}) from error


def convert_input(input_path: Path, temporary: Path) -> Path:
    if input_path.suffix.casefold() != ".pdf":
        return input_path
    converted = temporary / "pdf-page.png"
    completed = subprocess.run(
        [
            "/usr/bin/sips",
            "-s",
            "format",
            "png",
            os.fspath(input_path),
            "--out",
            os.fspath(converted),
        ],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=60,
    )
    if completed.returncode != 0 or not converted.is_file():
        raise CardsError("PDFの先頭ページを画像へ変換できませんでした")
    return converted


def load_input_image(input_path: Path, temporary: Path) -> Image.Image:
    converted = convert_input(input_path, temporary)
    try:
        with Image.open(converted) as source:
            return ImageOps.exif_transpose(source).convert("RGBA")
    except (OSError, ValueError) as error:
        raise CardsError("選択した画像を読み込めませんでした") from error


def original_artwork_backup(
    artwork: Path,
    card_id: str,
    backup_directory: Path,
) -> Path | None:
    prefix = hashlib.sha256(card_id.encode()).hexdigest()
    backups = sorted(
        backup_directory.glob(f"{prefix}-*-{artwork.name}"),
        key=lambda path: path.name,
    )
    return backups[0] if backups else None


def original_artwork_reference(
    artwork: Path,
    card_id: str,
    backup_directory: Path,
) -> Path:
    return original_artwork_backup(artwork, card_id, backup_directory) or artwork


def prepare_artwork_asset(
    input_path: Path,
    artwork: Path,
    output: Path,
    card_id: str,
    backup_directory: Path,
) -> dict[str, Any]:
    if artwork.suffix.casefold() not in {".png", ".pdf"}:
        raise CardsError("このカードの券面形式には対応していません")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="airlift-artwork-") as temporary_name:
        temporary = Path(temporary_name)
        source = load_input_image(input_path, temporary)
        reference_artwork = original_artwork_reference(
            artwork,
            card_id,
            backup_directory,
        )
        if artwork.suffix.casefold() == ".pdf":
            target_temporary = temporary / "target"
            target_temporary.mkdir()
            rendered_artwork = convert_input(reference_artwork, target_temporary)
            with Image.open(rendered_artwork) as target:
                size = target.size
        else:
            with Image.open(reference_artwork) as target:
                size = target.size
        fitted = ImageOps.fit(
            source,
            size,
            method=Image.Resampling.LANCZOS,
            centering=(0.5, 0.5),
        )
        temporary_output = output.with_name(f".{output.name}.{secrets.token_hex(4)}")
        if artwork.suffix.casefold() == ".pdf":
            # sips renders the source PDF at one pixel per PDF point. Saving at
            # 72 dpi preserves that page box instead of shrinking it by half.
            fitted.convert("RGB").save(temporary_output, "PDF", resolution=72)
        else:
            fitted.save(temporary_output, "PNG", optimize=True)
        temporary_output.replace(output)
    return {
        "ok": True,
        "outputPath": os.fspath(output.resolve()),
        "width": size[0],
        "height": size[1],
    }


def validate_artwork_file(path: Path, expected_suffix: str) -> None:
    data = path.read_bytes()
    if expected_suffix.casefold() == ".pdf" and not data.startswith(b"%PDF-"):
        raise CardsError("差し替え用データがPDFではありません")
    if expected_suffix.casefold() == ".png" and not data.startswith(
        b"\x89PNG\r\n\x1a\n"
    ):
        raise CardsError("差し替え用データがPNGではありません")
    if not data or len(data) > 64 * 1024 * 1024:
        raise CardsError("差し替え用データのサイズが不正です")


def apply_card_artwork(
    udid: str,
    cards_root: Path,
    card_id: str,
    replacement_path: Path,
    backup_directory: Path,
    restart_wallet: bool,
) -> dict[str, Any]:
    ensure_helpers()
    pass_root = safe_pass_root(cards_root, card_id)
    metadata = pass_metadata(pass_root)
    if "paymentCard" not in metadata:
        raise CardsError("支払いカード以外は差し替え対象にできません")
    artwork = card_artwork_asset(pass_root)
    if artwork is None:
        raise CardsError("このカードの元券面データが見つかりません")
    validate_artwork_file(replacement_path, artwork.suffix)
    target_path = posixpath.join(
        CARDS_PATH, f"{card_id}.pkpass", artwork.name
    )
    target_directory = posixpath.dirname(target_path)
    leaf = posixpath.basename(target_path)
    cache_path = posixpath.join(CARDS_PATH, f"{card_id}.cache")
    paths = GeneratedPaths.create()
    work = backup_directory / f".airlift-apply-{secrets.token_hex(8)}"
    backup_directory.mkdir(parents=True, exist_ok=True)
    original_backup = original_artwork_backup(
        artwork,
        card_id,
        backup_directory,
    )
    stored_backup_path = original_backup or backup_directory / (
        f"{hashlib.sha256(card_id.encode()).hexdigest()}-"
        f"{time.time_ns()}-{artwork.name}"
    )
    preimage_path = (
        work / f"preimage-{artwork.name}"
        if original_backup is not None
        else stored_backup_path
    )
    current_artwork_directory = backup_directory.parent / "CurrentArtwork"
    current_artwork_directory.mkdir(parents=True, exist_ok=True)
    current_artwork_prefix = hashlib.sha256(card_id.encode()).hexdigest()
    verification_path = current_artwork_directory / (
        f"{current_artwork_prefix}-{paths.token}-{artwork.name}"
    )
    identifiers = [
        target_identifier(target_path),
        paths.link_identifier,
        paths.payload_identifier,
        lexical_target_identifier(target_path),
        paths.recovered_identifier,
        target_identifier(cache_path),
        paths.barrier_identifier,
    ]
    operation: StagedOperation | None = None
    verification_ok = False
    backup_pulled = False
    try:
        progress("元のカード画像を退避しています…")
        operation = stage_operation(
            udid,
            target_directory,
            replacement_path.read_bytes(),
            identifiers,
            work,
            paths,
        )

        def verify_change() -> None:
            nonlocal verification_ok, backup_pulled
            progress("元画像を保存し、変更後データを照合しています…")
            pull_generated(udid, paths.backup, preimage_path)
            backup_pulled = True
            pull_generated(udid, paths.recovered, verification_path)
            verification_ok = (
                verification_path.read_bytes() == replacement_path.read_bytes()
            )

        def wait_for_backup() -> None:
            wait_for_operation_state(
                udid,
                operation,
                lambda status: status["backupPresent"],
                include_backup=True,
            )

        def wait_for_link() -> None:
            wait_for_operation_state(
                udid,
                operation,
                lambda status: status["backupPresent"]
                and status["linkPresent"],
                include_backup=True,
            )

        def wait_for_payload_move() -> None:
            wait_for_operation_state(
                udid,
                operation,
                lambda status: not status["payloadPresent"],
                include_backup=True,
            )

        def wait_for_artwork_restoration() -> None:
            wait_for_operation_state(
                udid,
                operation,
                lambda status: not status["recoveredPresent"],
                include_backup=True,
            )

        final_status: dict[str, Any] = {}

        def wait_for_barrier() -> None:
            nonlocal final_status
            final_status = wait_for_operation_state(
                udid,
                operation,
                lambda status: status["barrierDonePresent"],
                include_backup=True,
            )

        air_traffic = run_host_stepped(
            udid,
            identifiers,
            [
                paths.backup,
                paths.link,
                f"{paths.link}/{leaf}",
                paths.recovered,
                f"{paths.link}/{leaf}",
                paths.recovered,
                f"{paths.source}/barrier-done",
            ],
            [
                wait_for_backup,
                wait_for_link,
                wait_for_payload_move,
                verify_change,
                wait_for_artwork_restoration,
                lambda: None,
                wait_for_barrier,
            ],
        )
        recovered_kind = final_status.get("recoveredKind")
        cache_was_present = recovered_kind == "S_IFDIR"
        if (
            not verification_ok
            or not final_status["backupPresent"]
            or recovered_kind not in {None, "S_IFDIR"}
        ):
            raise CardsError(
                "差し替え後の検証に失敗しました。元画像のバックアップを保持しています。",
                {
                    "generatedStatus": final_status,
                    "verificationOK": verification_ok,
                },
        )
        cleanup = cleanup_operation(udid, operation, include_backup=True)
        for previous in current_artwork_directory.glob(
            f"{current_artwork_prefix}-*-{artwork.name}"
        ):
            if previous != verification_path:
                previous.unlink(missing_ok=True)
        shutil.rmtree(work, ignore_errors=True)
        wallet_restarted = False
        wallet_restart_error: str | None = None
        wallet_restart_result: dict[str, Any] | None = None
        if restart_wallet:
            progress("キャッシュ再生成のためWalletを再起動しています…")
            try:
                wallet_restart_result = restart_wallet_display(udid)
                wallet_restarted = True
            except CardsError as error:
                wallet_restart_error = str(error)
        return {
            "ok": True,
            "cardID": card_id,
            "backupPath": os.fspath(stored_backup_path.resolve()),
            "currentArtworkPath": os.fspath(verification_path.resolve()),
            "verifiedPatchedBytes": True,
            "invalidatedCachePath": cache_path,
            "airTraffic": air_traffic,
            "cacheInvalidation": {
                "ok": True,
                "path": cache_path,
                "cacheWasPresent": cache_was_present,
            },
            "cleanup": cleanup,
            "walletRestartRequested": restart_wallet,
            "walletRestarted": wallet_restarted,
            "walletRestart": wallet_restart_result,
            "walletRestartError": wallet_restart_error,
        }
    except Exception as error:
        recovery = {
            "workPath": os.fspath(work),
            "backupPath": os.fspath(preimage_path) if backup_pulled else None,
            "verificationPath": (
                os.fspath(verification_path) if verification_path.exists() else None
            ),
            "message": "自動削除せず、復旧に必要な端末側一時データを保持しました。",
        }
        if operation:
            try:
                recovery["automaticRestore"] = emergency_restore(
                    udid,
                    operation,
                    paths.backup,
                    target_path,
                    preimage_path if backup_pulled else None,
                    original_in_backup_slot=True,
                )
                recovery["message"] = "元の券面データを端末へ復元しました。"
            except Exception as status_error:
                recovery["automaticRestoreError"] = str(status_error)
        if isinstance(error, CardsError):
            error.details.setdefault("recovery", recovery)
            raise
        raise CardsError(str(error), {"recovery": recovery}) from error


def restore_card_artwork(
    udid: str,
    cards_root: Path,
    card_id: str,
    backup_directory: Path,
    restart_wallet: bool,
) -> dict[str, Any]:
    pass_root = safe_pass_root(cards_root, card_id)
    artwork = card_artwork_asset(pass_root)
    if artwork is None:
        raise CardsError("このカードの元券面データが見つかりません")
    backup = original_artwork_backup(artwork, card_id, backup_directory)
    if backup is None:
        raise CardsError("このカードには元の券面のバックアップがありません")
    result = apply_card_artwork(
        udid,
        cards_root,
        card_id,
        backup,
        backup_directory,
        restart_wallet,
    )
    result["restoredFromPath"] = os.fspath(backup.resolve())
    return result


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("devices")

    fetch = subparsers.add_parser("fetch")
    fetch.add_argument("--device", required=True)
    fetch.add_argument("--output", type=Path, required=True)

    prepare_asset = subparsers.add_parser("prepare-asset")
    prepare_asset.add_argument("--input", type=Path, required=True)
    prepare_asset.add_argument("--artwork", type=Path, required=True)
    prepare_asset.add_argument("--output", type=Path, required=True)
    prepare_asset.add_argument("--card-id", required=True)
    prepare_asset.add_argument("--backup-dir", type=Path, required=True)

    apply = subparsers.add_parser("apply")
    apply.add_argument("--device", required=True)
    apply.add_argument("--cards-root", type=Path, required=True)
    apply.add_argument("--card-id", required=True)
    apply.add_argument("--replacement", type=Path, required=True)
    apply.add_argument("--backup-dir", type=Path, required=True)
    apply.add_argument("--restart-wallet", action="store_true")

    restore = subparsers.add_parser("restore")
    restore.add_argument("--device", required=True)
    restore.add_argument("--cards-root", type=Path, required=True)
    restore.add_argument("--card-id", required=True)
    restore.add_argument("--backup-dir", type=Path, required=True)
    restore.add_argument("--restart-wallet", action="store_true")
    return parser


def main() -> int:
    arguments = build_parser().parse_args()
    try:
        if arguments.command == "devices":
            result = {"ok": True, "devices": list_devices()}
        elif arguments.command == "fetch":
            result = fetch_cards(arguments.device, arguments.output)
        elif arguments.command == "prepare-asset":
            result = prepare_artwork_asset(
                arguments.input,
                arguments.artwork,
                arguments.output,
                arguments.card_id,
                arguments.backup_dir,
            )
        elif arguments.command == "apply":
            result = apply_card_artwork(
                arguments.device,
                arguments.cards_root,
                arguments.card_id,
                arguments.replacement,
                arguments.backup_dir,
                arguments.restart_wallet,
            )
        elif arguments.command == "restore":
            result = restore_card_artwork(
                arguments.device,
                arguments.cards_root,
                arguments.card_id,
                arguments.backup_dir,
                arguments.restart_wallet,
            )
        else:
            raise CardsError("不明なコマンドです")
    except (
        CardsError,
        OSError,
        ValueError,
        KeyError,
        subprocess.SubprocessError,
    ) as error:
        result = {"ok": False, "error": str(error)}
        if isinstance(error, CardsError) and error.details:
            result["details"] = error.details
        json_result(result)
        return 1
    json_result(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
