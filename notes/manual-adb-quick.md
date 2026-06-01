# Manual ADB Quick Guide

Short manual ADB reference for users who already understand ADB basics.

## Check ADB

```sh
adb version
adb devices
```

## USB

```sh
adb devices
adb shell pm list packages --user 0
adb shell pm uninstall -k --user 0 <package_name>
```

With a specific device:

```sh
adb -s <serial> shell pm uninstall -k --user 0 <package_name>
```

## Wireless

Pair first:

```sh
adb pair <ip>:<pairing_port>
```

Connect:

```sh
adb connect <ip>:<connect_port>
adb devices
```

Use wireless device:

```sh
adb -s <ip>:<connect_port> shell pm list packages --user 0
adb -s <ip>:<connect_port> shell pm uninstall -k --user 0 <package_name>
```

## User ID

Main user is usually `0`.

```sh
adb shell pm list users
```

Use another user if needed:

```sh
adb shell pm list packages --user <user_id>
adb shell pm uninstall -k --user <user_id> <package_name>
```

## Find Packages

All packages:

```sh
adb shell pm list packages --user 0
```

Linux/macOS:

```sh
adb shell pm list packages --user 0 | grep <keyword>
```

Windows CMD:

```bat
adb shell pm list packages --user 0 | findstr <keyword>
```

## Restore Package

```sh
adb shell cmd package install-existing --user 0 <package_name>
```

With a specific device:

```sh
adb -s <serial_or_ip:port> shell cmd package install-existing --user 0 <package_name>
```

## Common Flow

```sh
adb devices
adb shell pm list users
adb shell pm list packages --user 0
adb shell pm uninstall -k --user 0 <package_name>
adb shell cmd package install-existing --user 0 <package_name>
```
