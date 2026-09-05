#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 ]]; then
  print -u2 "usage: $0 OUTPUT_DIRECTORY [DEVICE ...]"
  exit 64
fi

output_directory=$1
shift
mkdir -p "$output_directory"

devices=($@)
if (( ${#devices} == 0 )); then
  inventory=$(mktemp /tmp/twdiw-devices.XXXXXX.json)
  trap 'rm -f "$inventory"' EXIT
  xcrun devicectl list devices --json-output "$inventory" >/dev/null
  devices=(${(f)$(python3 - "$inventory" <<'PY'
import json, sys
for device in json.load(open(sys.argv[1], encoding="utf-8"))["result"]["devices"]:
    props = device.get("deviceProperties", {})
    hardware = device.get("hardwareProperties", {})
    if hardware.get("reality") == "physical" and props.get("ddiServicesAvailable"):
        print(device["identifier"])
PY
)})
fi

if (( ${#devices} == 0 )); then
  print -u2 "No connected Developer Mode device is available."
  exit 69
fi

copied=0
for device in $devices; do
  device_directory="$output_directory/$device"
  mkdir -p "$device_directory"
  destination="$device_directory/verification-runs.json"
  if xcrun devicectl device copy from \
      --device "$device" \
      --domain-type appDataContainer \
      --domain-identifier tw.bonds.backupTW \
      --source 'Library/Application Support/Diagnostics/verification-runs.json' \
      --destination "$destination" \
      --timeout 60; then
    (( copied += 1 ))
  else
    print -u2 "Could not collect $device; keep it unlocked and connected, then retry."
  fi
done

if (( copied == 0 )); then
  exit 1
fi

script_directory=${0:A:h}
python3 "$script_directory/summarize-verification-runs.py" \
  "$output_directory"/*/verification-runs.json \
  --markdown "$output_directory/verification-matrix.md" \
  --csv "$output_directory/verification-runs.csv"

print "Collected $copied device log(s) in $output_directory"
