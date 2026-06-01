#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s nullglob extglob

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
package_pattern='^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$'

list_values=()
whitelist_values=()
serial=""
wireless=""
pair_requested=0
pair_target=""
pair_code=""
user_id="0"
user_supplied=0
dry_run=0
yes=0
list_devices=0

show_help() {
  cat <<'EOF'
Android Debloat via ADB

Usage:
  ./debloat.sh
  ./debloat.sh --serial R58N123456A --list samsung --user 0 --yes
  ./debloat.sh --list google --list samsung --user 0 --dry-run
  ./debloat.sh --wireless 192.168.1.20:5555 --list samsung --user 10 --yes
  ./debloat.sh --pair --pair-target 192.168.1.20:37123 --pair-code 123456 --wireless 192.168.1.20:5555 --list samsung --user 0 --yes

Options:
  --list <name|path>       Package list file. Repeat or use comma-separated values.
  --whitelist <name|path>  Whitelist file. Defaults to all whitelist/*.txt.
  --serial <serial>        ADB device serial to target.
  --wireless <host:port>   Run adb connect first. Port defaults to 5555 if omitted.
  --pair                   Run adb pair before adb connect.
  --pair-target <host:port> Wireless debugging pairing endpoint.
  --pair-code <code>       Wireless debugging pairing code.
  --user <id>              Android user id. Default: 0.
  --dry-run                Show actions without uninstalling.
  --yes                    Skip confirmation prompt.
  --list-devices           Print adb devices and exit.
EOF
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

split_values() {
  local value part
  for value in "$@"; do
    IFS=',' read -ra parts <<< "$value"
    for part in "${parts[@]}"; do
      part="${part##+([[:space:]])}"
      part="${part%%+([[:space:]])}"
      [[ -n "$part" ]] && printf '%s\n' "$part"
    done
  done
}

resolve_text_file() {
  local value="$1"
  local folder="$2"
  local names=("$value")
  [[ "${value,,}" != *.txt ]] && names+=("$value.txt")

  local name direct nested
  for name in "${names[@]}"; do
    if [[ "$name" = /* || "$name" =~ ^[A-Za-z]:[\\/].* ]]; then
      direct="$name"
    else
      direct="$script_dir/$name"
    fi

    [[ -f "$direct" ]] && realpath "$direct" && return 0

    nested="$script_dir/$folder/$name"
    [[ -f "$nested" ]] && realpath "$nested" && return 0
  done

  fail "File '$value' was not found in the repository root or '$folder' folder."
}

get_text_files() {
  local folder="$1"
  local folder_path="$script_dir/$folder"
  [[ -d "$folder_path" ]] || fail "Folder '$folder' was not found."

  local files=("$folder_path"/*.txt)
  ((${#files[@]} > 0)) || return 0
  printf '%s\n' "${files[@]}" | sort
}

select_package_lists() {
  mapfile -t files < <(get_text_files "list")
  ((${#files[@]} > 0)) || fail "No .txt files were found in the 'list' folder."

  printf 'Select debloat list:\n' >&2
  local i
  for i in "${!files[@]}"; do
    printf '  %d. %s\n' "$((i + 1))" "$(basename "${files[$i]}")" >&2
  done

  local selection part number
  printf 'Enter number, comma-separated for multiple lists: ' >&2
  read -r selection
  IFS=',' read -ra parts <<< "$selection"
  for part in "${parts[@]}"; do
    part="${part##+([[:space:]])}"
    part="${part%%+([[:space:]])}"
    [[ "$part" =~ ^[0-9]+$ ]] || fail "Invalid list selection: '$part'."
    number="$part"
    ((number >= 1 && number <= ${#files[@]})) || fail "Invalid list selection: '$part'."
    printf '%s\n' "${files[$((number - 1))]}"
  done
}

resolve_package_lists() {
  if ((${#list_values[@]} == 0)); then
    select_package_lists
    return 0
  fi

  local value
  while IFS= read -r value; do
    resolve_text_file "$value" "list"
  done < <(split_values "${list_values[@]}")
}

resolve_whitelist_files() {
  if ((${#whitelist_values[@]} == 0)); then
    get_text_files "whitelist"
    return 0
  fi

  local value
  while IFS= read -r value; do
    resolve_text_file "$value" "whitelist"
  done < <(split_values "${whitelist_values[@]}")
}

read_package_file() {
  local path="$1"
  local line clean
  while IFS= read -r line || [[ -n "$line" ]]; do
    clean="${line//$'\r'/}"
    clean="${clean%%#*}"
    clean="${clean%%;*}"
    clean="${clean##+([[:space:]])}"
    clean="${clean%%+([[:space:]])}"
    [[ -z "$clean" ]] && continue

    if [[ "$clean" =~ $package_pattern ]]; then
      printf '%s\n' "$clean"
    else
      printf "WARN: Skipped invalid line in '%s': %s\n" "$path" "$line" >&2
    fi
  done < "$path"
}

normalize_wireless_target() {
  local target="$1"
  [[ -z "$target" ]] && return 0
  if [[ "$target" =~ :[0-9]+$ ]]; then
    printf '%s\n' "$target"
  else
    printf '%s:5555\n' "$target"
  fi
}

join_adb_endpoint() {
  local host_value="$1"
  local port_value="$2"
  local default_port="$3"

  host_value="${host_value##+([[:space:]])}"
  host_value="${host_value%%+([[:space:]])}"
  [[ -n "$host_value" ]] || fail "Wireless IP address cannot be empty."

  if [[ "$host_value" =~ :[0-9]+$ && -z "$port_value" ]]; then
    printf '%s\n' "$host_value"
    return 0
  fi

  port_value="${port_value##+([[:space:]])}"
  port_value="${port_value%%+([[:space:]])}"
  [[ -n "$port_value" ]] || port_value="$default_port"
  [[ "$port_value" =~ ^[0-9]+$ ]] || fail "ADB port must be an integer between 1 and 65535."
  ((port_value >= 1 && port_value <= 65535)) || fail "ADB port must be an integer between 1 and 65535."

  printf '%s:%s\n' "$host_value" "$port_value"
}

get_adb() {
  command -v adb >/dev/null 2>&1 || fail "ADB was not found in PATH. Install Android SDK Platform Tools, then open a new terminal."
  command -v adb
}

select_connection_mode() {
  [[ -n "$serial" || -n "$wireless" ]] && return 0

  printf 'Select connection mode:\n'
  printf '  1. USB\n'
  printf '  2. Wireless\n'

  local mode ip_address pair_answer pair_port connect_port
  read -r -p "Enter connection mode number: " mode
  case "$mode" in
    1)
      return 0
      ;;
    2)
      read -r -p "Enter device IP address: " ip_address
      read -r -p "Pair this device first? [y/N]: " pair_answer
      if [[ "$pair_answer" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        read -r -p "Enter pairing port: " pair_port
        pair_requested=1
        pair_target="$(join_adb_endpoint "$ip_address" "$pair_port" 0)"
        if [[ -z "$pair_code" ]]; then
          read -r -p "Enter pairing code: " pair_code
        fi
      fi

      read -r -p "Enter connect port (empty = 5555): " connect_port
      wireless="$(join_adb_endpoint "$ip_address" "$connect_port" 5555)"
      return 0
      ;;
    *)
      fail "Invalid connection mode."
      ;;
  esac
}

resolve_user_id() {
  local raw="$user_id"
  if ((user_supplied == 0)); then
    read -r -p "Enter Android user id (empty = 0): " raw
  fi

  raw="${raw##+([[:space:]])}"
  raw="${raw%%+([[:space:]])}"
  if [[ -z "$raw" ]]; then
    user_id="0"
    return 0
  fi

  [[ "$raw" =~ ^[0-9]+$ ]] || fail "Android user id must be 0 or a greater integer."
  user_id="$raw"
}

connect_wireless() {
  local adb_path="$1"
  local target
  target="$(normalize_wireless_target "$wireless")"
  [[ -z "$target" ]] && return 0

  printf 'Connecting ADB wireless to %s ...\n' "$target"
  local output
  if ! output="$("$adb_path" connect "$target" 2>&1)"; then
    fail "Failed to run adb connect to $target. Output: $output"
  fi

  case "${output,,}" in
    *failed*|*unable*|*cannot*|*refused*)
      fail "Failed to run adb connect to $target. Output: $output"
      ;;
  esac
}

pair_wireless_device() {
  local adb_path="$1"
  ((pair_requested)) || return 0

  if [[ -z "$pair_target" ]]; then
    read -r -p "Enter wireless debugging pairing IP:port: " pair_target
  fi

  if [[ -z "$pair_code" ]]; then
    read -r -p "Enter pairing code: " pair_code
  fi

  local target output
  target="${pair_target##+([[:space:]])}"
  target="${target%%+([[:space:]])}"
  [[ "$target" =~ :[0-9]+$ ]] || fail "Pair target must include the wireless debugging pairing port."

  printf 'Pairing ADB wireless with %s ...\n' "$target"
  if ! output="$("$adb_path" pair "$target" "$pair_code" 2>&1)"; then
    fail "Failed to run adb pair with $target. Output: $output"
  fi

  case "${output,,}" in
    *failed*|*unable*|*cannot*|*refused*|*error*)
      fail "Failed to run adb pair with $target. Output: $output"
      ;;
  esac
}

get_devices() {
  local adb_path="$1"
  "$adb_path" devices | awk 'NR > 1 && NF >= 2 { print $1 "\t" $2 }'
}

select_adb_device() {
  local adb_path="$1"
  local devices online
  mapfile -t devices < <(get_devices "$adb_path")

  if [[ -n "$serial" ]]; then
    local row state
    for row in "${devices[@]}"; do
      if [[ "${row%%$'\t'*}" == "$serial" ]]; then
        state="${row##*$'\t'}"
        [[ "$state" == "device" ]] || fail "Device '$serial' is in '$state' state, not 'device'."
        printf '%s\n' "$serial"
        return 0
      fi
    done
    fail "Device '$serial' does not appear in adb devices."
  fi

  mapfile -t online < <(printf '%s\n' "${devices[@]}" | awk '$2 == "device" { print $1 }')
  ((${#online[@]} > 0)) || fail "No ready ADB device was found."

  if ((${#online[@]} == 1)); then
    printf '%s\n' "${online[0]}"
    return 0
  fi

  printf 'Select ADB device:\n' >&2
  local i selection
  for i in "${!online[@]}"; do
    printf '  %d. %s\n' "$((i + 1))" "${online[$i]}" >&2
  done

  printf 'Enter device number: ' >&2
  read -r selection
  [[ "$selection" =~ ^[0-9]+$ ]] || fail "Invalid device selection."
  ((selection >= 1 && selection <= ${#online[@]})) || fail "Invalid device selection."
  printf '%s\n' "${online[$((selection - 1))]}"
}

run_debloat() {
  local adb_path="$1"
  local device="$2"
  local package_name="$3"

  if ((dry_run)); then
    printf 'DRY-RUN adb -s %s shell pm uninstall -k --user %s %s\n' "$device" "$user_id" "$package_name"
    return 0
  fi

  local output
  if output="$("$adb_path" -s "$device" shell pm uninstall -k --user "$user_id" "$package_name" 2>&1)" && [[ "$output" == *Success* ]]; then
    return 0
  fi

  printf '%s\n' "$output"
  return 1
}

while (($# > 0)); do
  case "$1" in
    --list)
      (($# >= 2)) || fail "--list requires a value."
      list_values+=("$2")
      shift 2
      ;;
    --whitelist)
      (($# >= 2)) || fail "--whitelist requires a value."
      whitelist_values+=("$2")
      shift 2
      ;;
    --serial)
      (($# >= 2)) || fail "--serial requires a value."
      serial="$2"
      shift 2
      ;;
    --wireless)
      (($# >= 2)) || fail "--wireless requires a value."
      wireless="$2"
      shift 2
      ;;
    --pair)
      pair_requested=1
      shift
      ;;
    --pair-target)
      (($# >= 2)) || fail "--pair-target requires a value."
      pair_target="$2"
      pair_requested=1
      shift 2
      ;;
    --pair-code)
      (($# >= 2)) || fail "--pair-code requires a value."
      pair_code="$2"
      pair_requested=1
      shift 2
      ;;
    --user)
      (($# >= 2)) || fail "--user requires a value."
      if [[ -n "$2" && ! "$2" =~ ^[0-9]+$ ]]; then
        fail "--user must be a number or empty."
      fi
      user_id="$2"
      user_supplied=1
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --yes)
      yes=1
      shift
      ;;
    --list-devices)
      list_devices=1
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

adb_path="$(get_adb)"

if ((list_devices)); then
  "$adb_path" devices
  exit $?
fi

select_connection_mode
mapfile -t list_files < <(resolve_package_lists)
mapfile -t whitelist_files < <(resolve_whitelist_files)
resolve_user_id

declare -A target_packages=()
declare -A protected_packages=()

for file in "${list_files[@]}"; do
  while IFS= read -r package_name; do
    [[ -n "${target_packages[$package_name]+x}" ]] || target_packages[$package_name]="$file"
  done < <(read_package_file "$file")
done

for file in "${whitelist_files[@]}"; do
  while IFS= read -r package_name; do
    [[ -n "${protected_packages[$package_name]+x}" ]] || protected_packages[$package_name]="$file"
  done < <(read_package_file "$file")
done

((${#target_packages[@]} > 0)) || fail "Debloat list is empty after parsing."

candidates=()
blocked=()
while IFS= read -r package_name; do
  if [[ -n "${protected_packages[$package_name]+x}" ]]; then
    blocked+=("$package_name")
  else
    candidates+=("$package_name")
  fi
done < <(printf '%s\n' "${!target_packages[@]}" | sort)

printf 'Debloat lists: %d file(s), %d unique package(s).\n' "${#list_files[@]}" "${#target_packages[@]}"
printf 'Whitelist: %d file(s), %d unique package(s).\n' "${#whitelist_files[@]}" "${#protected_packages[@]}"
printf 'Will process: %d. Skipped by whitelist: %d.\n' "${#candidates[@]}" "${#blocked[@]}"

((${#candidates[@]} > 0)) || {
  printf 'No packages to process.\n'
  exit 0
}

if ((!dry_run && !yes)); then
  read -r -p "Type DEBLOAT to uninstall packages for user $user_id: " answer
  [[ "$answer" == "DEBLOAT" ]] || {
    printf 'Canceled.\n'
    exit 0
  }
fi

"$adb_path" start-server >/dev/null
pair_wireless_device "$adb_path"
connect_wireless "$adb_path"
device="$(select_adb_device "$adb_path")"

declare -A installed=()
if ! installed_output="$("$adb_path" -s "$device" shell pm list packages --user "$user_id" 2>&1)"; then
  fail "Failed to read installed packages for user $user_id. Output: $installed_output"
fi

while IFS= read -r package_name; do
  [[ -n "$package_name" ]] && installed[$package_name]=1
done < <(printf '%s\n' "$installed_output" | sed -n 's/^package://p')

success=0
failed=0
not_installed=0

for package_name in "${candidates[@]}"; do
  if [[ -z "${installed[$package_name]+x}" ]]; then
    ((not_installed += 1))
    printf 'SKIP not-installed %s\n' "$package_name"
    continue
  fi

  if output="$(run_debloat "$adb_path" "$device" "$package_name")"; then
    ((success += 1))
    [[ -n "$output" ]] && printf '%s\n' "$output"
    printf 'OK %s\n' "$package_name"
  else
    ((failed += 1))
    printf 'FAIL %s :: %s\n' "$package_name" "$output"
  fi
done

printf '\nDone.\n'
printf '  Device: %s\n' "$device"
printf '  User: %s\n' "$user_id"
printf '  Success: %d\n' "$success"
printf '  Failed: %d\n' "$failed"
printf '  Not installed: %d\n' "$not_installed"
printf '  Skipped by whitelist: %d\n' "${#blocked[@]}"

((failed == 0)) || exit 2
