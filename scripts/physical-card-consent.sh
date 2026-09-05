#!/bin/sh
set -eu

usage() {
  echo "usage: $0 --device <paired-device-name-or-id> [--slot <number>]" >&2
}

device=""
slot=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --device)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      device=$2
      shift 2
      ;;
    --slot)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      slot=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[ -n "$device" ] || { usage; exit 2; }

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
tool_dir="$repo_dir/tools/official-document-physical-card-signer"
tool="$tool_dir/target/release/bonds-official-document-physical-card-signer"
bundle_id="tw.bonds.backupTW"
request_path="Library/Application Support/OfficialDocumentInbox/physical-card-request.json"
response_path="Library/Application Support/OfficialDocumentInbox/physical-card-response.json"
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/bonds-physical-card.XXXXXX")
request="$temporary_dir/request.json"
response="$temporary_dir/response.json"

cleanup() {
  rm -rf -- "$temporary_dir"
}
trap cleanup EXIT HUP INT TERM

echo "從已配對 iPhone 拉取一次性、無身分資料的簽章請求…"
xcrun devicectl device copy from \
  --device "$device" \
  --source "$request_path" \
  --destination "$request" \
  --domain-type appDataContainer \
  --domain-identifier "$bundle_id"

echo "建置已鎖定上游 commit 的本機簽章工具…"
cargo build --release --locked --manifest-path "$tool_dir/Cargo.toml"

if [ -n "$slot" ]; then
  "$tool" --request "$request" --response "$response" --slot "$slot"
else
  "$tool" --request "$request" --response "$response"
fi

echo "把簽章結果推回 iPhone 的受保護 App data container…"
xcrun devicectl device copy to \
  --device "$device" \
  --source "$response" \
  --destination "$response_path" \
  --domain-type appDataContainer \
  --domain-identifier "$bundle_id"

echo "完成。Mac 暫存會在腳本退出時刪除；回到 App 再點一次實體卡測試列進行驗章。"

