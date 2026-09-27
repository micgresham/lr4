# LR4 Provisioner

A Flutter app that talks to a Litter-Robot 4's ESP32 over Bluetooth, using the
same protocomm provisioning channel the Whisker app uses. It runs on Android,
iOS, macOS and Windows. It can:

- **Scan for WiFi from the robot's own radio.** Shows what the robot can
  actually reach, with signal strength, channel and security type.
- **Test a WiFi join.** Sends the SSID and password, then reports the robot's
  verdict: connected (with IP), wrong password, or network not found. The log
  shows the robot's raw status bytes, which is useful when a join stalls.
- **Provision the robot to your own MQTT broker.** Writes the broker host,
  topics and your CA certificate, plus an optional client certificate and key.
  After that the robot runs locally with no Whisker cloud. Re-onboarding in the
  Whisker app undoes it.
- **Restore Whisker's cloud settings.** Writes Whisker's own AWS IoT endpoint,
  the stock topics and Amazon Root CA 1, without the Whisker app. See
  [Restoring the stock cloud](#restoring-the-stock-cloud).

The protocol code is a Dart port of
[whiskerless](https://github.com/SisyphusMD/whiskerless) by SisyphusMD (MIT):
`ble/protobuf.py`, `ble/messages.py`, `ble/transport.py` and `ble/provision.py`.
See [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES).

For what is known about the robot's hardware (chips, headers, the ESP32 serial
console, flash backup), see
[docs/lr4-mainboard-reference.md](docs/lr4-mainboard-reference.md).

## Platforms

| Platform | Minimum | Build on | Bluetooth backend |
| --- | --- | --- | --- |
| Android | Android 5.0 (API 21) | any | Android BLE |
| iOS | iOS 12 | macOS + Xcode | CoreBluetooth |
| macOS | macOS 10.14 | macOS + Xcode | CoreBluetooth |
| Windows | Windows 10 | Windows + Visual Studio | WinRT |

Linux and web aren't set up.

## Building

Requires Flutter 3.32 (Dart 3.8). Run the protocol tests on any platform with:

```sh
flutter test
```

### Android

```sh
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

The release APK is signed with the debug key, which is fine for sideloading.
The first scan asks for the **Nearby devices** permission.

### iOS

Needs Xcode and CocoaPods (`brew install cocoapods`).

1. Open `ios/Runner.xcworkspace` in Xcode.
2. Under **Runner → Signing & Capabilities**, choose your Team. A free Apple
   ID works for installing on your own phone, but the app expires after 7 days.
3. Connect the iPhone and run `flutter run --release`, or build from Xcode.

To check that it compiles without signing: `flutter build ios --release --no-codesign`.

iOS asks for Bluetooth permission on first use. iOS hides MAC addresses, so the
scan list shows a per-phone UUID instead of the robot's Bluetooth address.
The MAC the robot itself reports is still shown after connecting.

### macOS

```sh
flutter build macos --release
open "build/macos/Build/Products/Release/LR4 Provisioner.app"
```

The app is sandboxed, with the Bluetooth and "user-selected files (read)"
entitlements. The second one lets it load certificate files. macOS asks for
Bluetooth permission on first use. If you declined, allow it under
**System Settings → Privacy & Security → Bluetooth**.

A local build runs on the Mac that built it. To give it to another Mac, sign it
with a Developer ID and notarize it.

### Windows

Windows builds need a Windows PC with Visual Studio 2022, including the
**Desktop development with C++** workload:

```sh
flutter build windows --release
```

The output is the whole `build\windows\x64\runner\Release\` folder. Keep the
`.exe` next to its DLLs and `data` folder. The PC needs a Bluetooth LE adapter
and Windows 10 or later.

### Builds without the toolchains (GitHub Actions)

[.github/workflows/build.yml](.github/workflows/build.yml) runs the analyzer and
tests. It then builds Android, Windows, macOS and unsigned iOS on every push to
`main`, and on demand from the **Actions** tab (**Run workflow**). Each build is
attached to the run as a downloadable artifact:

| Artifact | Contents |
| --- | --- |
| `lr4-provisioner-android` | `app-release.apk` |
| `lr4-provisioner-windows` | The Release folder with the `.exe` |
| `lr4-provisioner-macos` | Zipped `.app`, ad-hoc signed |
| `lr4-provisioner-ios-unsigned` | Zipped `Runner.app`. Proves the project compiles; can't be installed without signing |

A macOS build downloaded this way is quarantined by Gatekeeper. Right-click it
and choose **Open** the first time.

## Using it

1. Hold the robot's **Connect** button about 3 s, until the light **blinks
   yellow**. A short tap only toggles WiFi.
   ⚠️ Pairing mode wipes the saved WiFi, and the only way out is to finish a
   provision, either in this app or in the Whisker app.
2. **Find robot**, then tap it to connect. The log shows the robot's MAC and
   whatever version information it reports (`proto-ver`).
3. **Scan networks from robot**, pick your network (2.4 GHz only) and enter
   the password. The full scan list, with security types, goes to the log.
4. Either:
   - **Test WiFi join**: diagnose only. Enter the robot's serial (label,
     `LR4C` + 6 digits) to have it written first, as the Whisker app does.
     Afterwards, finish setup in the Whisker app or here.
   - **Provision to my broker**: enter the serial, the broker host or IP, and the
     CA PEM. The broker must serve TLS on port 8883 with a certificate from that
     CA whose name matches the host.

The copy icon next to **Log** puts the whole session on the clipboard.

### Restoring the stock cloud

**Restore Whisker cloud settings** puts the robot back on the official service.
It needs the serial and a WiFi network, and writes exactly what the Whisker app
writes at onboarding:

| Setting | Value |
| --- | --- |
| Broker host | `a2wz9c6y6mikoy-ats.iot.us-east-1.amazonaws.com` |
| Subscribe topic | `prod/LR4/<serial>/command` |
| Publish topic | `prod/LR4/<serial>/activity` |
| Root CA | [Amazon Root CA 1](https://www.amazontrust.com/repository/AmazonRootCA1.pem) |

None of this is secret or per-robot. The endpoint is Whisker's AWS account
endpoint, recovered by whiskerless from a decoded capture of the app's own BLE
onboarding; the robot cannot be asked for it, since the firmware has no read
command for any of these settings. The topics embed the serial from the label.
The CA is Amazon's public root, and its 1188-byte PEM matches the 1188 bytes the
app was captured writing. `test/cloud_test.dart` checks the embedded copy
against the certificate's published fingerprint.

**What it cannot restore is the robot's certificate and key.** Those identify
the robot to AWS, nothing can read them back, and this app never replaces them
unless you turn on the client-identity option when provisioning to your own
broker. So:

- If the robot still has its factory identity, which is the normal case, this
  puts it back on the cloud.
- If you replaced the identity, only the Whisker app can recover it, because it
  reissues all three certificate slots on every onboarding.

After provisioning, the robot publishes to `prod/LR4/<serial>/activity` and
`…/state` and subscribes to `prod/LR4/<serial>/command`. See the whiskerless
docs for the broker setup and the JSON protocol.

## Code layout

| Path | What it is |
| --- | --- |
| `lib/protocol/protobuf.dart` | Minimal protobuf encode/decode |
| `lib/protocol/messages.dart` | Endpoint message builders and response parsers |
| `lib/protocol/cloud.dart` | Whisker's stock cloud host and Amazon Root CA 1 |
| `lib/ble/robot_link.dart` | BLE transport, WiFi scan/join, provisioning sequence |
| `lib/main.dart` | UI: find robot, WiFi test, broker details |
| `test/messages_test.dart` | Byte vectors from whiskerless's own tests |
| `test/cloud_test.dart` | Checks the stock-cloud values and the embedded CA |
