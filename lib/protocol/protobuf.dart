// A tiny protobuf codec — just enough for protocomm provisioning.
// Port of whiskerless `ble/protobuf.py` (MIT, SisyphusMD).
//
// Matches proto3 wire semantics: scalar fields equal to their default (0 / "")
// are omitted, which is what the firmware's protobuf-c decoder and the official
// app both produce. Message (oneof-arm) fields are always emitted, even when
// empty, because their presence selects the oneof arm.

import 'dart:convert';
import 'dart:typed_data';

const int wireVarint = 0;
const int wireLen = 2;

List<int> encodeVarint(int value) {
  final out = <int>[];
  var v = value;
  while (true) {
    final byte = v & 0x7F;
    v = v >>> 7;
    out.add(byte | (v != 0 ? 0x80 : 0));
    if (v == 0) return out;
  }
}

List<int> _tag(int field, int wire) => encodeVarint(field << 3 | wire);

/// A varint field, omitted when zero (proto3 default).
List<int> fieldVarint(int field, int value) =>
    value == 0 ? const [] : [..._tag(field, wireVarint), ...encodeVarint(value)];

/// A string field, omitted when empty (proto3 default).
List<int> fieldString(int field, String value) {
  if (value.isEmpty) return const [];
  final data = utf8.encode(value);
  return [..._tag(field, wireLen), ...encodeVarint(data.length), ...data];
}

/// A length-delimited sub-message — always emitted (selects a oneof arm).
List<int> fieldMessage(int field, List<int> data) =>
    [..._tag(field, wireLen), ...encodeVarint(data.length), ...data];

Uint8List concat(List<List<int>> parts) =>
    Uint8List.fromList([for (final p in parts) ...p]);

/// Decoded field value: an [int] for varints, a [Uint8List] for length-delimited.
typedef Fields = Map<int, List<Object>>;

/// Collect a message into `{fieldNumber: [values...]}`.
///
/// Varints wider than 63 bits wrap into Dart's signed 64-bit int, which is
/// exactly the int32/int64 sign extension protobuf uses for negatives (RSSI).
Fields readFields(List<int> data) {
  final fields = <int, List<Object>>{};
  var pos = 0;
  (int, int) readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (pos >= data.length) throw const FormatException('truncated varint');
      final byte = data[pos++];
      if (shift < 64) result |= (byte & 0x7F) << shift;
      if (byte & 0x80 == 0) return (result, pos);
      shift += 7;
    }
  }

  while (pos < data.length) {
    final (key, _) = readVarint();
    final field = key >> 3;
    final wire = key & 0x07;
    if (wire == wireVarint) {
      final (value, _) = readVarint();
      fields.putIfAbsent(field, () => []).add(value);
    } else if (wire == wireLen) {
      final (length, _) = readVarint();
      final end = (pos + length).clamp(0, data.length);
      fields.putIfAbsent(field, () => []).add(Uint8List.fromList(data.sublist(pos, end)));
      pos = end;
    } else if (wire == 5) {
      pos += 4;
    } else if (wire == 1) {
      pos += 8;
    } else {
      break; // unsupported / malformed — stop rather than misread
    }
  }
  return fields;
}

int? firstInt(Fields f, int field) {
  final v = f[field];
  return (v != null && v.isNotEmpty && v.first is int) ? v.first as int : null;
}

Uint8List? firstBytes(Fields f, int field) {
  final v = f[field];
  return (v != null && v.isNotEmpty && v.first is Uint8List) ? v.first as Uint8List : null;
}
