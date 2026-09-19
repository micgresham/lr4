# Litter-Robot 4 Mainboard Reference

As of 2026-09-19

## Overview

No public schematic or full parts list exists for the Litter-Robot 4 (LR4) mainboard. What is known comes from two community projects, [esphome-litter-robot](https://codeberg.org/Joseph-DiGiovanni/esphome-litter-robot) and [whiskerless](https://github.com/SisyphusMD/whiskerless), which cover the processors, the programming headers and the serial protocol.

The mainboard sits under the control panel. It pairs a main microcontroller, which runs the robot, with an ESP32 that only bridges Wi-Fi and Bluetooth to it. A separate laser board carries the cat and level sensors.

There are two board revisions, identified by the serial number on the label:

| Serial prefix | Built | Main MCU | ESP32 programming header (J3) |
| --- | --- | --- | --- |
| LR4C | Before Feb 2026 | Microchip PIC | 6 surface pads, 1.27 mm pitch; needs a soldered header |
| LR4S | Feb 2026 on | STM microcontroller | 5 through-hole pads, 2.54 mm pitch; a test clip works |

## Chips

The robot's logic and every safety interlock live in the main MCU; the ESP32 carries no robot logic.

| Part | Role | Source |
| --- | --- | --- |
| ESP32-WROOM-32E module | Wi-Fi and BLE bridge: relays register reads and writes between the cloud (MQTT) and the main MCU over UART | [UART Reference](https://codeberg.org/Joseph-DiGiovanni/esphome-litter-robot/src/branch/main/docs/Litter%20Robot%204/UART%20Reference.md) |
| Main MCU, LR4C: Microchip PIC | Motors, sensors, cycle state machine, real-time clock, sleep schedule, anti-pinch, weight pause, over-current. Can cut power to the ESP32 | both projects |
| Main MCU, LR4S: STM microcontroller | Same role on the newer board revision | [UART Reference](https://codeberg.org/Joseph-DiGiovanni/esphome-litter-robot/src/branch/main/docs/Litter%20Robot%204/UART%20Reference.md) |
| Laser board | Time-of-flight curtain sensors for cat presence, litter level and waste-drawer level | [UART Reference](https://codeberg.org/Joseph-DiGiovanni/esphome-litter-robot/src/branch/main/docs/Litter%20Robot%204/UART%20Reference.md) |

The exact PIC part is disputed. esphome-litter-robot names the **PIC18F47Q43-I/PT**; whiskerless names the **PIC18F67K40**. The difference may be a board revision, or one source may be wrong. The marking on the large square chip in the middle of the board settles it.

## Connectors and headers

J3, next to the ESP32 module, is the main access point: it carries the ESP32's serial console and programming lines.

| Header | What it is | Source |
| --- | --- | --- |
| J3 | ESP32 programming and serial console. LR4C: 2×3 surface pads, 1.27 mm. LR4S: 5 through-holes, 2.54 mm | [Flashing guide](https://codeberg.org/Joseph-DiGiovanni/esphome-litter-robot/src/branch/main/docs/Litter%20Robot%204/Flashing%20Instructions.md) |
| J8 | ESP32 ↔ main MCU UART; the middle 2 of its 4 pads are TX and RX | [Hackaday](https://hackaday.com/2026/08/21/hacking-a-cat-litter-box/) |
| PIC ICSP header | MCLR/VPP, ICSPCLK, ICSPDAT, GND; board powered from the 15 V adapter | [whiskerless](https://github.com/SisyphusMD/whiskerless) |
| J7 (LR4S only) | First square pad accepts 3.3 V to power the board on the bench. Never connect this with the board installed in the robot | [Flashing guide](https://codeberg.org/Joseph-DiGiovanni/esphome-litter-robot/src/branch/main/docs/Litter%20Robot%204/Flashing%20Instructions.md) |

### J3 pinout (LR4C)

Hold the board with the control panel up and the LEDs facing you. J3 is on the left, beside the ESP32 shield; its pads are coated and must be scraped before soldering.

```
 2   4   6      top row
 1   3   5      bottom row
```

| Pad | ESP32 signal | USB-serial adapter (3.3 V) |
| --- | --- | --- |
| 1 | EN (reset) | Flashing only |
| 2 | VDD 3.3 V | Do not connect; the robot powers the board |
| 3 | TXD0 | Adapter RX |
| 4 | GND | Adapter GND |
| 5 | RXD0 | Adapter TX (flashing only) |
| 6 | IO0 (boot mode) | Flashing only |

This is the standard ESP-Prog layout. An ESP-Prog-2's 6-pin ribbon lines up with it directly, pink wire (pin 1) on the left. The board end is not keyed. Reading the console needs only pads 3 and 4.

## ESP32 ↔ main MCU serial link

The two chips talk over UART1 at 256000 baud, 8N1, no flow control. ESP32 TX is GPIO19 and RX is GPIO5 ([UART Reference](https://codeberg.org/Joseph-DiGiovanni/esphome-litter-robot/src/branch/main/docs/Litter%20Robot%204/UART%20Reference.md)).

Every frame is 7 bytes:

| Byte | Field | Values |
| --- | --- | --- |
| 0 | Direction | `0x02` ESP→MCU, `0x01` MCU→ESP |
| 1 | Operation | `0x01` read, `0x02` write, `0x03` read-reply, `0x04` write-ack |
| 2 | Register | Register number |
| 3–4 | Value | 16-bit, big-endian |
| 5 | Checksum | Sum of bytes 0–4, mod 256 |
| 6 | Terminator | Always `0xFF` |

The MCU sends unsolicited event writes, and the ESP32 acks each by echoing the register and value. Cloud commands arrive as `{"serial": "...", "data": ["0xPPRRVVVV"]}`, and the ESP32 adds the direction byte and checksum. The register map is in whiskerless's [registers.md](https://github.com/SisyphusMD/whiskerless/blob/main/docs/devices/litter-robot-4/registers.md).

Listening on J8 is read-only and harmless. Frames flowing both ways show that the ESP32's processor is running, even when its Wi-Fi is not.

## ESP32 firmware and storage

The stock ESP32 firmware is ESP-IDF, with ESP-IDF's standard BLE provisioning service ("protocomm"). It uses no security and no proof-of-possession, so any Bluetooth client in range can use it while the robot is in pairing mode ([whiskerless](https://github.com/SisyphusMD/whiskerless)).

The robot advertises only while in pairing mode: hold Connect about 3 s until the light blinks yellow. Entering pairing mode erases the saved Wi-Fi.

- **Service UUID:** `b7ee1c20-dcfd-4208-8813-14845cac5212`. The GAP name is `LitterRobot4`, and the BLE address is the base MAC + 2.
- **Endpoints:** each is one read+write characteristic, named by its 0x2901 descriptor. A request is a write, then a read on the same characteristic.

| Endpoint | Characteristic | Purpose |
| --- | --- | --- |
| prov-config | `b7ee0002-…` | Stock Wi-Fi SetConfig, ApplyConfig, GetStatus |
| prov-scan | `b7ee0004-…` | Robot-side Wi-Fi scan, results paged 4 at a time |
| mqtt-config | `b7ee0005-…` | Write broker host, topics, root CA, device cert and key; apply |
| whisker-config | `b7ee0006-…` | Read device ID (MAC), set serial, reboot |
| prov-session, proto-ver | not mapped | Stock session and version endpoints |

The cloud identity lives in NVS, not in the firmware image: root CA, device certificate and key, broker host and topics. The certificates cannot be read back over BLE.

The flash also holds a `pic_factory` partition, which whiskerless says is the complete factory PIC image including its bootloader. A full `esptool read_flash` of the 8 MB flash captures all of it. No complete dump of either chip has been published.

## Getting to the board

The mainboard comes out with the control panel attached, after removing the bezel. Whisker's [laser-board replacement video](https://www.youtube.com/watch?v=m9pkoDCwM14) shows the same route up to 1:56. Opening the robot likely voids the warranty.

1. Home the globe, power off and unplug. Remove the bonnet, globe and waste drawer.
2. Lay the unit face-down. Remove 10 screws from the black bridge and 4 behind the bezel's seal strips.
3. Work the bezel off one side at a time.
4. Unplug the laser-board connector (left of the mainboard) and the power connector (right).
5. Remove the 2 screws under the control panel and lift the board out.

### Reading the ESP32 console

1. Solder a 1.27 mm 2×3 SMD header (LR4C) to J3, or clip onto the pads (LR4S).
2. Wire pad 4 to adapter GND and pad 3 to adapter RX, using a 3.3 V adapter.
3. Reinstall the board and reconnect both connectors; the robot powers the ESP32.
4. Start a logger at 115200 baud (`python3 -m serial.tools.miniterm`), then power on.

The ESP32's boot ROM always prints its reset cause at 115200. Whisker's firmware may suppress application logs such as Wi-Fi state changes.

### Backing up the flash

This needs EN, IO0 and RXD0 as well; an ESP-Prog-2 drives them automatically.

```
esptool --port /dev/cu.usbserial-XXXX flash-id
esptool --port /dev/cu.usbserial-XXXX --baud 460800 read_flash 0x0 0x800000 LR4_stock_backup.bin
```

The backup restores the stock firmware with `write_flash 0x0`. Before flashing ESPHome, LR4C units should run stock firmware 1175.5021.292 (July 2024) or later, or the litter hopper won't work ([Flashing guide](https://codeberg.org/Joseph-DiGiovanni/esphome-litter-robot/src/branch/main/docs/Litter%20Robot%204/Flashing%20Instructions.md)).

## Field notes: this unit's Wi-Fi failure

This LR4C (ESP32 MAC `aa:bb:cc:dd:ee:00`, BLE address `AA:BB:CC:DD:EE:02`; both placeholders) can't finish joining any Wi-Fi network. The fault is on the robot side. Tests ran September 2026 with an Android port of whiskerless's BLE provisioning.

- **BLE works:** the robot connects at MTU 500 and all six endpoints answer.
- **Robot-side scan works:** it sees 7 networks, including all three it was tested on.
- **Same failure on three access points:** home SSID A (WPA/WPA2, ch 6), home SSID B (WPA2, ch 6) and a phone hotspot (WPA2, ch 1, −44 dBm).
- **Status never changes:** GetStatus returned `08015a021001` for the full 90 s on every network. That decodes to `sta_state = CONNECTING`, with no failure reason, no disconnect and no IP.
- **Aruba controller view:** the robot is associated to an indoor AP (ch 11, signal about 47) with IP 0.0.0.0 at a 1 Mbps rate. Frames go out to it, but almost none come back.

Other clients on the same SSIDs get DHCP leases normally. The failure began in the last one to two weeks.

The likely cause is ESP32 firmware or ESP32 radio hardware. Reading the J3 console during a join should tell which: it would show whether the key exchange or DHCP stalls, or the chip resets.

## Gaps and open questions

Most of the board outside the two processors and their headers is undocumented.

- Which PIC is fitted: PIC18F47Q43 or PIC18F67K40?
- Motor driver, power supply and battery circuitry: parts and topology.
- Laser board: which ToF sensor parts, and how it connects to the mainboard.
- Pinouts of the power, laser-board and control-panel connectors.
- The LR4S board: which STM part, and whether its UART protocol differs.
- No schematic, and no complete ESP32 or PIC flash dump, is public.

Photos of both sides of the board, with chip markings readable, would close several of these.

## Sources

- [esphome-litter-robot](https://codeberg.org/Joseph-DiGiovanni/esphome-litter-robot): the [UART Reference](https://codeberg.org/Joseph-DiGiovanni/esphome-litter-robot/src/branch/main/docs/Litter%20Robot%204/UART%20Reference.md) and [Flashing Instructions](https://codeberg.org/Joseph-DiGiovanni/esphome-litter-robot/src/branch/main/docs/Litter%20Robot%204/Flashing%20Instructions.md)
- [whiskerless](https://github.com/SisyphusMD/whiskerless): reverse-engineering notes, [registers.md](https://github.com/SisyphusMD/whiskerless/blob/main/docs/devices/litter-robot-4/registers.md) and the app-onboarding capture
- [Hackaday: Hacking A Cat Litter Box](https://hackaday.com/2026/08/21/hacking-a-cat-litter-box/)
- [Hackster: Open Source Firmware Frees the Litter-Robot 4 From the Cloud](https://www.hackster.io/news/open-source-firmware-frees-the-litter-robot-4-from-the-cloud-3078cb43eddf)
- [Whisker: LR4 assembly and disassembly](https://www.litter-robot.com/support/article/litter-robot-4-assembly-and-disassembly/)
- [elttam: reverse engineering the LR3](https://www.elttam.com/blog/re-of-lr3), the previous model
