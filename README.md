# Android Debloat

ADB-based Android debloat helper for Windows PowerShell and Bash.

The scripts are designed so normal users only edit package text files:

- Add or edit debloat lists in `list/*.txt`.
- Add or edit protected packages in `whitelist/*.txt`.
- Do not edit the scripts unless you are changing behavior.

If the same package exists in both `list/*.txt` and `whitelist/*.txt`, the whitelist wins and the package is skipped.

## Requirements

- Android SDK Platform Tools
- `adb` available in `PATH`
- USB debugging or Wireless debugging enabled on the Android device

Check ADB:

```sh
adb version
adb devices
```

## Windows

Run:

```powershell
.\debloat.bat
```

The wizard will ask for:

1. Connection mode: USB or Wireless
2. Wireless pairing details, if needed
3. Package list
4. Android user ID, default `0`
5. Final confirmation

Direct usage:

```powershell
.\debloat.bat -Serial R58N123456A -List samsung -User 0 -Yes
.\debloat.bat -Pair -PairTarget 192.168.1.20:37123 -PairCode 123456 -Wireless 192.168.1.20:5555 -List samsung -User 0 -Yes
```

## Bash

Run:

```sh
./debloat.sh
```

Direct usage:

```sh
./debloat.sh --serial R58N123456A --list samsung --user 0 --yes
./debloat.sh --pair --pair-target 192.168.1.20:37123 --pair-code 123456 --wireless 192.168.1.20:5555 --list samsung --user 0 --yes
```

## Package Lists

Each non-empty line should contain one package name:

```text
com.example.package
com.vendor.app
```

Comments are supported:

```text
# This line is ignored
com.example.package
com.vendor.app # inline comment
```

Add a new list by creating a new `.txt` file in `list/`. The scripts will detect it automatically.

## Whitelist

Put packages that must never be debloated in `whitelist/*.txt`.

Whitelist files are loaded automatically. A package in the whitelist is skipped even if it appears in a debloat list.

## Failure Handling

The scripts continue when an individual package cannot be uninstalled.

Result types:

- `OK`: package uninstall command succeeded
- `FAIL`: package uninstall command failed, and the script continued
- `SKIP not-installed`: package was not installed for the selected user

If at least one package fails, the script finishes the remaining packages and exits with code `2`.

## Manual ADB Notes

- Full manual guide: `notes/manual-adb.md`
- Quick manual reference: `notes/manual-adb-quick.md`

## Safety

Debloating is device-specific. Review package names before running the scripts, and keep important packages in the whitelist.
