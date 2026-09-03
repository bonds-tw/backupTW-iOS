#!/usr/bin/env python3

"""Merge privacy-safe device timing logs into the verification matrix report."""

from __future__ import annotations

import argparse
import csv
import json
import statistics
from pathlib import Path
from typing import Any, Iterable


CELLS = ("A1", "A2", "A3", "G1", "G2", "G3", "G4")
MILLISECONDS = (
    "preparationMilliseconds",
    "proofPrepareMilliseconds",
    "proofShowMilliseconds",
    "transportMilliseconds",
    "verificationMilliseconds",
    "endToEndMilliseconds",
)


def load(paths: Iterable[Path]) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for path in paths:
        for record in json.loads(path.read_text(encoding="utf-8")):
            record["sourceFile"] = str(path)
            records.append(record)
    return sorted(records, key=lambda item: item.get("recordedAt", ""))


def report_records(records: list[dict[str, Any]], cell: str) -> list[dict[str, Any]]:
    matching = [record for record in records if record.get("matrixCell") == cell]
    # Verification is measured on the verifier for every local two-device path.
    # Online OIDC4VP has no app record on the Cloudflare page, so use the holder.
    preferred_role = "holder" if cell in {"A2", "G1"} else "verifier"
    preferred = [record for record in matching if record.get("role") == preferred_role]
    return preferred or matching


def seconds(value: Any) -> str:
    return "" if value is None else f"{int(value) / 1000:.3f}"


def statistic(records: list[dict[str, Any]], key: str) -> tuple[str, str]:
    values = [int(record[key]) for record in records if record.get(key) is not None]
    if not values:
        return "—", "—"
    return f"{statistics.median(values) / 1000:.3f}", f"{max(values) / 1000:.3f}"


def write_csv(path: Path, records: list[dict[str, Any]]) -> None:
    fields = (
        "recordedAt", "matrixCell", "flow", "role", "credentialKind", "transport",
        "succeeded", "runTemperature", "processSessionID", "processRunOrdinal",
        "authenticationObservation", "qrFallbackWasVisible", "lowPowerModeEnabled",
        "thermalState", *MILLISECONDS, "correlationToken", "deviceModel", "osVersion",
        "appVersion", "appBuild", "sourceFile",
    )
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        for record in records:
            writer.writerow(record)


def write_markdown(path: Path, records: list[dict[str, Any]]) -> None:
    lines = [
        "# 有備而來實機驗證自動紀錄",
        "",
        "所有秒數由 App 的 monotonic clock 自動保存；下載與解壓時間不混入 OpenAC Prepare／Show。",
        "五筆樣本只報 raw values、median 與 max，不稱為 p95。",
        "",
        "| 格 | 有效筆數 | 成功 | 驗證 median / max (秒) | 全程 median / max (秒) |",
        "|---|---:|---:|---:|---:|",
    ]
    for cell in CELLS:
        selected = report_records(records, cell)
        verification = statistic(selected, "verificationMilliseconds")
        end_to_end = statistic(selected, "endToEndMilliseconds")
        passed = sum(record.get("succeeded") is True for record in selected)
        lines.append(
            f"| {cell} | {len(selected)} | {passed} | {verification[0]} / {verification[1]} | "
            f"{end_to_end[0]} / {end_to_end[1]} |"
        )

    lines += [
        "",
        "## Raw values",
        "",
        "這裡保留同一次互動的 holder 與 verifier 紀錄；匿名關聯碼可用來配對兩台裝置，",
        "不包含 DID、證件編號、姓名或揭露欄位內容。",
        "",
    ]
    for cell in CELLS:
        selected = [record for record in records if record.get("matrixCell") == cell]
        lines += [f"### {cell}", ""]
        if not selected:
            lines += ["尚無紀錄。", ""]
            continue
        lines += [
            "| # | 時間 | 流程 | 角色 | cold/warm | 解鎖 | 傳輸 | Prepare | Show | 驗證 | 全程 | 結果 | fallback | 關聯碼 |",
            "|---:|---|---|---|---|---|---|---:|---:|---:|---:|---|---|---|",
        ]
        for index, record in enumerate(selected, start=1):
            result = "pass" if record.get("succeeded") is True else (
                "fail" if record.get("succeeded") is False else "no verdict"
            )
            lines.append(
                "| {index} | {recordedAt} | {flow} | {role} | {runTemperature} | {authentication} | "
                "{transport} | {prepare} | {show} | {verify} | {end} | {result} | {fallback} | "
                "{correlation} |".format(
                    index=index,
                    recordedAt=record.get("recordedAt", ""),
                    flow=record.get("flow", ""),
                    role=record.get("role", ""),
                    runTemperature=record.get("runTemperature", ""),
                    authentication=record.get("authenticationObservation", ""),
                    transport=record.get("transport", ""),
                    prepare=seconds(record.get("proofPrepareMilliseconds")),
                    show=seconds(record.get("proofShowMilliseconds")),
                    verify=seconds(record.get("verificationMilliseconds")),
                    end=seconds(record.get("endToEndMilliseconds")),
                    result=result,
                    fallback=record.get("qrFallbackWasVisible", ""),
                    correlation=record.get("correlationToken", ""),
                )
            )
        lines.append("")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("inputs", nargs="+", type=Path)
    parser.add_argument("--markdown", required=True, type=Path)
    parser.add_argument("--csv", required=True, type=Path)
    args = parser.parse_args()
    records = load(args.inputs)
    args.markdown.parent.mkdir(parents=True, exist_ok=True)
    write_markdown(args.markdown, records)
    write_csv(args.csv, records)


if __name__ == "__main__":
    main()
