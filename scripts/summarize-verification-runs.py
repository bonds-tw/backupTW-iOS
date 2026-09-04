#!/usr/bin/env python3

"""Merge privacy-safe device timing logs into the verification matrix report."""

from __future__ import annotations

import argparse
import csv
import json
import statistics
from pathlib import Path
from typing import Any, Iterable


CELLS = ("A1", "A2", "A3", "G1", "G2", "G3", "G4", "W1", "W2")
# Web pairs: the same website checking SD-JWT-VC (left) and a ZK age proof (right).
WEB_PAIRS = (("政府卡片", "A2", "W1"), ("自發 MyData 證件", "G1", "W2"))
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
    preferred_role = "holder" if cell in {"A2", "G1", "W1", "W2"} else "verifier"
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
        "## 網頁查驗：零知識證明 vs SD-JWT-VC",
        "",
        "同一個查驗網站（verifier.mashbean.net）對同一種卡片的兩條路徑。全程＝持卡人掃碼到收到判定；",
        "ZKP 的建立時間是 OpenAC Prepare＋Show，驗證時間是網站後端 verify_linked 的秒數。",
        "",
        "| 卡片 | SD-JWT-VC 全程 median / max | ZKP 全程 median / max | ZKP 建立 median | ZKP 網站驗證 median | 筆數 (SD / ZK) |",
        "|---|---:|---:|---:|---:|---:|",
    ]
    for label, sd_cell, zk_cell in WEB_PAIRS:
        sd = [r for r in report_records(records, sd_cell) if r.get("succeeded") is True]
        zk = [r for r in report_records(records, zk_cell) if r.get("succeeded") is True]
        sd_total = statistic(sd, "endToEndMilliseconds")
        zk_total = statistic(zk, "endToEndMilliseconds")
        creation = [
            {"creation": int(r["proofPrepareMilliseconds"]) + int(r["proofShowMilliseconds"])}
            for r in zk
            if r.get("proofPrepareMilliseconds") is not None and r.get("proofShowMilliseconds") is not None
        ]
        zk_creation = statistic(creation, "creation")
        zk_verify = statistic(zk, "verificationMilliseconds")
        lines.append(
            f"| {label} | {sd_total[0]} / {sd_total[1]} | {zk_total[0]} / {zk_total[1]} | "
            f"{zk_creation[0]} | {zk_verify[0]} | {len(sd)} / {len(zk)} |"
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
