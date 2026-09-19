# LR4 Provisioner

An Android app that talks to a Litter-Robot 4's ESP32 over Bluetooth, using the
same protocomm provisioning channel the Whisker app uses. It can:

- **Scan for WiFi from the robot's own radio.** Shows what the robot can
  actually reach, with signal strength, channel and security type.
- **Test a WiFi join.** Sends the SSID and password, then reports the robot's
  verdict: connected (with IP), wrong password, or network not found.
- **Provision the robot to your own MQTT broker.** Writes the broker host,
  topics and your CA certificate, plus an optional client certificate and key.
  After that the robot runs locally with no Whisker cloud. Re-onboarding in the
  Whisker app undoes it.

The protocol code is a Dart port of
[whiskerless](https://github.com/SisyphusMD/whiskerless) by SisyphusMD (MIT):
`ble/protobuf.py`, `ble/messages.py`, `ble/transport.py` and `ble/provision.py`.

## Build / install

```sh
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
flutter test          # protocol byte vectors from whiskerless's own tests
```

## Using it

1. Hold the robot's **Connect** button about 3 s, until the light **blinks
   yellow**. A short tap only toggles WiFi.
   ⚠️ Pairing mode wipes the saved WiFi, and the only way out is to finish a
   provision, either in this app or in the Whisker app.
2. **Find robot**, then tap it to connect.
3. **Scan networks from robot**, pick your network (2.4 GHz only) and enter
   the password.
4. Either:
   - **Test WiFi join**: diagnose only. Afterwards, finish setup in the
     Whisker app or here.
   - **Provision to my broker**: enter the serial (label, `LR4C` + 6 digits),
     the broker host/IP and the CA PEM. The broker must serve TLS on port
     8883 with a certificate from that CA whose name matches the host.

After provisioning, the robot publishes to `prod/LR4/<serial>/activity` and
`…/state` and subscribes to `prod/LR4/<serial>/command`. See the whiskerless
docs for the broker setup and the JSON protocol.
