# Manual ADB Guide

This guide is the manual version of the ADB workflow. It is not tied to the debloat scripts. Use it when you want to run ADB commands yourself.

## Before You Start

Install Android SDK Platform Tools and make sure `adb` can be used from your terminal.

Check ADB:

```sh
adb version
```

On your Android device:

1. Open Developer options.
2. Enable USB debugging for USB usage.
3. Enable Wireless debugging for wireless usage.
4. Accept the debugging prompt when Android asks for permission.

## Check Connected Devices

Run:

```sh
adb devices
```

Expected result:

```text
List of devices attached
R58N123456A    device
```

If the state is `unauthorized`, unlock the phone and accept the debugging prompt.

If the state is `offline`, disconnect and reconnect the device, then run:

```sh
adb kill-server
adb start-server
adb devices
```

## USB Connection

Connect the phone with a USB cable, then run:

```sh
adb devices
```

If there is only one device, you can run commands directly:

```sh
adb shell pm list packages --user 0
```

If there are multiple devices, target one device with `-s`:

```sh
adb -s R58N123456A shell pm list packages --user 0
```

## Wireless Connection

Wireless debugging usually uses two ports:

- Pairing port: used once for `adb pair`.
- Connect port: used for `adb connect`.

Both ports are shown in Android's Wireless debugging screen.

Pair the device:

```sh
adb pair 192.168.1.20:37123
```

ADB will ask for the pairing code shown on the phone.

Connect to the device:

```sh
adb connect 192.168.1.20:5555
```

Check the device:

```sh
adb devices
```

Then use the wireless address as the serial:

```sh
adb -s 192.168.1.20:5555 shell pm list packages --user 0
```

## Android User ID

Most devices use user `0` for the main profile.

Check available users:

```sh
adb shell pm list users
```

Example:

```text
Users:
    UserInfo{0:Owner:13} running
    UserInfo{10:Work profile:30} running
```

Use the user ID that matches the profile you want to manage.

## List Installed Packages

List all packages for the main user:

```sh
adb shell pm list packages --user 0
```

Search for a package on macOS or Linux:

```sh
adb shell pm list packages --user 0 | grep samsung
```

Search for a package on Windows CMD:

```bat
adb shell pm list packages --user 0 | findstr samsung
```

## Disable or Uninstall a Package for One User

The common debloat command is:

```sh
adb shell pm uninstall -k --user 0 <package_name>
```

Example:

```sh
adb shell pm uninstall -k --user 0 com.example.app
```

What it means:

- `pm uninstall`: asks Android package manager to uninstall.
- `-k`: keeps app data/cache where Android allows it.
- `--user 0`: applies only to user `0`.
- `<package_name>`: the package you want to remove for that user.

When targeting a specific device:

```sh
adb -s R58N123456A shell pm uninstall -k --user 0 com.example.app
```

For wireless:

```sh
adb -s 192.168.1.20:5555 shell pm uninstall -k --user 0 com.example.app
```

## Restore a Package

If the package still exists on the system partition, restore it with:

```sh
adb shell cmd package install-existing --user 0 <package_name>
```

Example:

```sh
adb shell cmd package install-existing --user 0 com.example.app
```

With a specific device:

```sh
adb -s R58N123456A shell cmd package install-existing --user 0 com.example.app
```

## Practical Manual Workflow

1. Connect the device with USB or Wireless debugging.
2. Run `adb devices`.
3. Check the Android user ID with `adb shell pm list users`.
4. List packages with `adb shell pm list packages --user 0`.
5. Copy the exact package name.
6. Run `adb shell pm uninstall -k --user 0 <package_name>`.
7. If needed, restore with `adb shell cmd package install-existing --user 0 <package_name>`.

## Notes

Only remove packages you understand. Some packages look optional but may affect calls, notifications, login, setup, accessibility, work profile, or device-specific features.

For safer manual testing, remove a small number of packages first, reboot the device, and check whether the features you use still work.
