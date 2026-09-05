#!/usr/bin/env python3

"""Merge privacy-safe device timing logs into the verification matrix report."""

from __future__ import annotations

import argparse
import csv
import json
import statistics
from pathlib import Path
from typing import Any, Iterable


CELLS = ("A1", "A2", "A3", "G1", "G2", "G3", "G4", "W1", "W2", "S1", "S2")
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
LOCAL_CELLS = {"A1", "G2", "G3", "G4", "S1", "S2"}


def load(paths: Iterable[Path]) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    seen: dict[str, dict[str, Any]] = {}
    for path in paths:
        for record in json.loads(path.read_text(encoding="utf-8")):
            for key in MILLISECONDS + ("payloadBytes",):
                value = record.get(key)
                if value is not None and (type(value) is not int or value < 0):
                    raise ValueError(f"Invalid non-negative integer: {key} in {path}")
            if record.get("succeeded") is not None and type(record["succeeded"]) is not bool:
                raise ValueError(f"Invalid verdict in {path}")
            key = record.get("id")
            if key and key in seen:
                if seen[key] != record:
                    raise ValueError(f"Conflicting copies of a run in {path}")
                continue
            if key:
                seen[key] = dict(record)
            record["sourceFile"] = str(path)
            records.append(record)
    return sorted(records, key=lambda item: item.get("recordedAt", ""))


def report_records(records: list[dict[str, Any]], cell: str) -> list[dict[str, Any]]:
    matching = [record for record in records if record.get("matrixCell") == cell]
    # Verification is measured on the verifier for every local two-device path.
    # Online OIDC4VP has no app record on the Cloudflare page, so use the holder.
    preferred_role = "holder" if cell in {"A2", "G1", "W1", "W2"} else "verifier"
    preferred = [record for record in matching if record.get("role") == preferred_role]
    # Sending successfully is not a verifier verdict. Missing iPad records
    # remain missing even when the iPhone reports a completed Bluetooth send.
    return preferred


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
        "appVersion", "appBuild", "proofPrepareWasCached", "payloadBytes", "sourceFile",
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
        "成功耗時與失敗分開；離線格只採查驗端判定，持卡端傳送完成不算驗證成功。",
        "Bluetooth 傳輸不證明已斷網；飛航模式／Wi-Fi 關閉須另有現場紀錄。",
        "S1／S2 是政府卡／MyData 數位身分證的 SD-JWT-VC 生日揭露；G3／G4 是相同來源的 ZKP。",
        "A1／G1 是 MyData 原有 vc+moica 或舊版 JWT 封套，不能標成 SD-JWT-VC。",
        "",
        "| 格 | 有效筆數 | 成功 | 驗證 median / max (秒) | 全程 median / max (秒) |",
        "|---|---:|---:|---:|---:|",
    ]
    for cell in CELLS:
        selected = report_records(records, cell)
        passed_records = [r for r in selected if r.get("succeeded") is True]
        verification = statistic(passed_records, "verificationMilliseconds")
        end_to_end = statistic(passed_records, "endToEndMilliseconds")
        passed = sum(record.get("succeeded") is True for record in selected)
        lines.append(
            f"| {cell} | {len(selected)} | {passed} | {verification[0]} / {verification[1]} | "
            f"{end_to_end[0]} / {end_to_end[1]} |"
        )

    lines += [
        "",
        "## 網頁查驗：零知識證明 vs 原始卡片出示",
        "",
        "政府卡為 SD-JWT-VC；自發 MyData 為 vc+moica／舊 JWT 封套。兩者不可混稱相同格式。A2／G1 計時從按下送出到提交回應，不包含掃碼與同意；",
        "W1／W2 全程從同意後建立畫面起算，含建立與送出；驗證時間由網站回傳。起訖點不同，不能計算兩者速度倍率。",
        "",
        "| 卡片 | 原始卡片提交 median / max | ZKP 全程 median / max | ZKP 建立 median | ZKP 網站驗證 median | 筆數 (原始 / ZK) |",
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
        "## 離線驗證分組（成功耗時，單位秒）",
        "",
        "cold/warm 是 App 行程的首次／後續紀錄，不代表 Prepare 快取命中。cache 未記錄時保留 unknown。",
        "每列按卡別、查驗裝置、版本、傳輸與快取分開，避免將不同條件平均。",
        "",
        "| 格 | 查驗裝置 | build | 傳輸 | Prepare cache | 判定數 | 成功 | 失敗 | 未判定 | 驗證 median / max | 全程 median / max |",
        "|---|---|---|---|---|---:|---:|---:|---:|---|---|",
    ]
    groups: dict[tuple, list[dict[str, Any]]] = {}
    for record in records:
        if record.get("matrixCell") not in LOCAL_CELLS or record.get("role") != "verifier":
            continue
        if record.get("transport") not in {"bluetooth", "qr"}:
            continue
        key = tuple(record.get(k, "unknown") for k in (
            "matrixCell", "deviceModel", "appBuild", "transport", "proofPrepareWasCached"))
        groups.setdefault(key, []).append(record)
    for key, group in sorted(groups.items(), key=lambda item: str(item[0])):
        passed = [r for r in group if r.get("succeeded") is True]
        failed = sum(r.get("succeeded") is False for r in group)
        unknown = len(group) - len(passed) - failed
        verification = statistic(passed, "verificationMilliseconds")
        total = statistic(passed, "endToEndMilliseconds")
        lines.append(f"| {' | '.join(map(str, key))} | {len(group)} | {len(passed)} | {failed} | {unknown} | "
                     f"{' / '.join(verification)} | {' / '.join(total)} |")
    if not groups:
        lines += ["", "尚無離線查驗端紀錄；不估算離線速度或成功率。"]
    lines += [
        "",
        f"未分類紀錄：{sum(r.get('matrixCell') not in CELLS for r in records)} 筆（保留於 CSV，不推定卡別或驗證方式）。",
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
    parser.add_argument("--since", help="Inclusive ISO-8601 UTC timestamp, e.g. 2026-09-05T00:00:00Z")
    parser.add_argument("--build", help="Only this app build; omit to inventory older evidence")
    args = parser.parse_args()
    records = load(args.inputs)
    if args.since:
        from datetime import datetime
        boundary = datetime.fromisoformat(args.since.replace("Z", "+00:00"))
        records = [r for r in records if datetime.fromisoformat(r["recordedAt"].replace("Z", "+00:00")) >= boundary]
    if args.build:
        records = [r for r in records if r.get("appBuild") == args.build]
    args.markdown.parent.mkdir(parents=True, exist_ok=True)
    write_markdown(args.markdown, records)
    write_csv(args.csv, records)


if __name__ == "__main__":
    main()
