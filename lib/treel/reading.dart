/// Decoding for JK Tyre Treel TPMS sensors.  See README.md for the format.
///
/// Each sensor broadcasts a stock iBeacon frame under Apple's manufacturer
/// id, with a constant UUID and its own MAC tail in major/minor -- and the
/// pressure in the low byte of minor, in plain psi:
///
///   02 15 | ff..ff e0 | major | minor | tx
///           constant    MAC[3:5] MAC[5],psi  temperature
///
/// The sensor id lives inside the payload, so nothing here needs the BLE
/// MAC -- which Android hides behind permissions and iOS never exposes.
library;

/// Apple's company identifier.  Treel sensors advertise under it because
/// they masquerade as iBeacons; they are not Apple devices.
const int appleManufacturerId = 0x004C;

/// The UUID every Treel sensor advertises.  Constant across sensors, so it
/// is what separates them from real iBeacons.
const List<int> treelUuid = [
  0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, //
  0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xe0,
];

/// Celsius = txPower - this.  Confirmed 27-41 C against the vendor app and
/// against the ideal gas law over a drive.
const int temperatureOffset = 110;

const int _ibeaconFrameLength = 23;
const int _ibeaconType = 0x02;
const int _ibeaconLength = 0x15;

/// One decoded broadcast from one sensor.
class TreelReading {
  const TreelReading({
    required this.sensorId,
    required this.psi,
    required this.celsius,
    required this.rssi,
    required this.at,
  });

  /// Last three octets of the sensor's MAC, e.g. `f10a04`.  Stable, and the
  /// only identity available on platforms that hide the BLE address.
  final String sensorId;

  /// Gauge pressure.  The sensor reports whole psi; it jitters by +-1
  /// between frames.
  final int psi;

  /// Tyre temperature in degrees Celsius.
  final int celsius;

  final int rssi;
  final DateTime at;

  double get kpa => psi / 0.1450377;
  double get bar => psi / 14.503774;

  Map<String, dynamic> toJson() => {
    'id': sensorId,
    'psi': psi,
    'c': celsius,
    'rssi': rssi,
    't': at.millisecondsSinceEpoch,
  };

  static TreelReading? fromJson(Map<String, dynamic> j) {
    final id = j['id'], psi = j['psi'], c = j['c'], t = j['t'];
    if (id is! String || psi is! int || c is! int || t is! int) return null;
    return TreelReading(
      sensorId: id,
      psi: psi,
      celsius: c,
      rssi: j['rssi'] is int ? j['rssi'] as int : 0,
      at: DateTime.fromMillisecondsSinceEpoch(t),
    );
  }

  @override
  String toString() => 'TreelReading($sensorId, $psi psi, $celsius C)';
}

/// Decode one advertisement.
///
/// [manufacturerData] is keyed by company id, as every BLE stack reports it.
/// Returns null for anything that is not a Treel sensor -- including real
/// iBeacons, which share the manufacturer id but not the UUID.
TreelReading? decodeTreel(
  Map<int, List<int>> manufacturerData, {
  required int rssi,
  DateTime? at,
}) {
  final frame = manufacturerData[appleManufacturerId];
  if (frame == null || frame.length != _ibeaconFrameLength) return null;
  if (frame[0] != _ibeaconType || frame[1] != _ibeaconLength) return null;

  for (var i = 0; i < treelUuid.length; i++) {
    if (frame[2 + i] != treelUuid[i]) return null;
  }

  return TreelReading(
    // major (2 bytes) + minor[0] == MAC[3:6]
    sensorId: frame
        .sublist(18, 21)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(),
    psi: frame[21],
    celsius: frame[22] - temperatureOffset,
    rssi: rssi,
    at: at ?? DateTime.now(),
  );
}

/// ZEEPIN / TP630 manufacturer company identifier.
const int zeepinManufacturerId = 0x0001;

/// BR TPMS advertises the 16-bit service UUID 0x27a5.
const String brServiceUuid = '000027a5-0000-1000-8000-00805f9b34fb';

/// Sensor protocol selection. Automatic uses advertisement signatures.
enum SensorProtocol {
  automatic('Automatic', 'automatic'),
  treel('JK Tyre Treel', 'treel'),
  zeepin('ZEEPIN / TP630', 'zeepin'),
  br('BR', 'br'),
  tesla('Tesla / Autel BLE', 'tesla');

  const SensorProtocol(this.label, this.id);
  final String label;
  final String id;
}

/// Decode the ZEEPIN / TP630 manufacturer payload.
///
/// universal_ble separates the two-byte company id from this 16-byte value.
/// Integer fields are little-endian, as in ra6070/BLE-TPMS.
TreelReading? decodeZeepin(
  Map<int, List<int>> manufacturerData, {
  required int rssi,
  DateTime? at,
}) {
  final frame = manufacturerData[zeepinManufacturerId];
  if (frame == null || frame.length != 16) return null;
  if (frame[0] < 0x80 || frame[0] > 0x8f) return null;
  if (frame[1] != 0xea || frame[2] != 0xca) return null;

  final pressureMilliKpa =
      frame[6] | (frame[7] << 8) | (frame[8] << 16) | (frame[9] << 24);
  final temperatureCenti =
      frame[10] | (frame[11] << 8) | (frame[12] << 16) | (frame[13] << 24);
  final pressureKpa = pressureMilliKpa / 1000.0;
  final psi = (pressureKpa * 0.1450377377).round();
  final celsius = (temperatureCenti / 100.0).round();
  if (psi < 0 || psi > 200 || celsius < -50 || celsius > 150) return null;

  return TreelReading(
    sensorId: frame
        .sublist(0, 6)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(),
    psi: psi,
    celsius: celsius,
    rssi: rssi,
    at: at ?? DateTime.now(),
  );
}

/// Decode the BR advertisement documented by andi38/TPMS.
///
/// The Bluetooth company id is 0x1d28 and the manufacturer payload is five
/// bytes. The upstream Python example reads temperature from byte 0 and
/// pressure from bytes 1-2. The final two bytes are not validated because the
/// repository does not document their checksum algorithm.
TreelReading? decodeBr(
  Map<int, List<int>> manufacturerData, {
  required int rssi,
  required String deviceId,
  DateTime? at,
}) {
  final frame = manufacturerData[0x1d28];
  if (frame == null || frame.length != 5) return null;

  final celsius = frame[0];
  final pressureRaw = (frame[1] << 8) | frame[2];
  final pressureBar = (pressureRaw - 145) / 145.0;
  final psi = (pressureBar * 14.503774).round();
  if (psi < 0 || psi > 200 || celsius > 150) return null;

  final stableId = deviceId.toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9]'),
    '',
  );
  final sensorId = 'br-$stableId';
  return TreelReading(
    sensorId: sensorId,
    psi: psi,
    celsius: celsius,
    rssi: rssi,
    at: at ?? DateTime.now(),
  );
}


/// Tesla's Bluetooth SIG company identifier.
const int teslaManufacturerId = 0x022B;

class TeslaTpmsPayload {
  const TeslaTpmsPayload({required this.psi, required this.celsius});

  final int psi;
  final int celsius;
}

bool isTeslaTpmsAdvertisement(List<int>? frame) {
  if (frame == null || frame.length < 3) return false;
  if (frame[2] < 0x05) return frame.length <= 16;
  if (frame.length < 8) return false;
  final batteryMv = frame[6] | (frame[7] << 8);
  return batteryMv >= 1500 && batteryMv <= 4300;
}

TreelReading? decodeTeslaAdvertisement(
  Map<int, List<int>> manufacturerData, {
  required int rssi,
  required String deviceId,
  DateTime? at,
}) {
  final frame = manufacturerData[teslaManufacturerId];
  if (!isTeslaTpmsAdvertisement(frame) || frame![2] < 0x05) return null;
  final rawPressureKpa = frame[3] | (frame[4] << 8);
  final psi = ((rawPressureKpa - 100) * 0.1450377377).round();
  final celsius = frame[5] - 50;
  if (psi < 0 || psi > 200 || celsius < -50 || celsius > 150) return null;
  final id = deviceId.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  return TreelReading(
    sensorId: 'tesla-$id',
    psi: psi,
    celsius: celsius,
    rssi: rssi,
    at: at ?? DateTime.now(),
  );
}

int? _readTeslaVarint(List<int> bytes, int start) {
  var shift = 0;
  var value = 0;
  var index = start;
  while (index < bytes.length && shift <= 63) {
    final byte = bytes[index++];
    value |= (byte & 0x7f) << shift;
    if ((byte & 0x80) == 0) return value;
    shift += 7;
  }
  return null;
}

({Map<int, int> values, List<List<int>> nested}) _teslaProtoFields(
  List<int> bytes,
) {
  final values = <int, int>{};
  final nested = <List<int>>[];
  var index = 0;
  while (index < bytes.length) {
    final tag = _readTeslaVarint(bytes, index);
    if (tag == null || tag == 0) break;
    final tagBytes = _teslaVarintLength(tag);
    index += tagBytes;
    final field = tag >> 3;
    switch (tag & 7) {
      case 0:
        final value = _readTeslaVarint(bytes, index);
        if (value == null) return (values: values, nested: nested);
        values[field] = value;
        index += _teslaVarintLength(value);
      case 1:
        if (index + 8 > bytes.length) return (values: values, nested: nested);
        index += 8;
      case 2:
        final length = _readTeslaVarint(bytes, index);
        if (length == null) return (values: values, nested: nested);
        index += _teslaVarintLength(length);
        if (length < 0 || index + length > bytes.length) {
          return (values: values, nested: nested);
        }
        nested.add(bytes.sublist(index, index + length));
        index += length;
      case 5:
        if (index + 4 > bytes.length) return (values: values, nested: nested);
        index += 4;
      default:
        return (values: values, nested: nested);
    }
  }
  return (values: values, nested: nested);
}

int _teslaVarintLength(int value) {
  var length = 1;
  while (value >= 0x80) {
    value >>= 7;
    length++;
  }
  return length;
}

({int pressure, int? temperature})? _findTeslaTpData(
  List<int> bytes, [
  int depth = 0,
]) {
  if (depth > 5) return null;
  final fields = _teslaProtoFields(bytes);
  if (fields.values.containsKey(1)) {
    return (pressure: fields.values[1]!, temperature: fields.values[2]);
  }
  for (final nested in fields.nested) {
    final result = _findTeslaTpData(nested, depth + 1);
    if (result != null) return result;
  }
  return null;
}

TeslaTpmsPayload? decodeTeslaTpData(List<int> payload) {
  final fields = _findTeslaTpData(payload);
  if (fields == null || fields.pressure < 0 || fields.pressure > 100000) {
    return null;
  }
  final pressurePsi =
      ((fields.pressure - 101.325) * 0.1450377377).round();
  final temperature = fields.temperature == null
      ? null
      : ((fields.temperature! >> 1) ^ -(fields.temperature! & 1));
  if (pressurePsi < 0 || pressurePsi > 200) return null;
  if (temperature != null && (temperature < -50 || temperature > 150)) {
    return null;
  }
  if (temperature == null) return null;
  return TeslaTpmsPayload(psi: pressurePsi, celsius: temperature);
}

List<List<int>> get teslaTpDataRequests {
  const inner = [0x08, 0x01];
  final frames = <List<int>>[
    inner,
    [0x0a, 0x02, ...inner],
    [0x12, 0x02, ...inner],
    [0x1a, 0x02, ...inner],
  ];
  return [
    ...frames,
    for (final frame in frames) [0x00, frame.length, ...frame],
  ];
}

/// Decode an advertisement using the selected or automatically detected
/// sensor protocol.
TreelReading? decodeSensor(
  Map<int, List<int>> manufacturerData, {
  required int rssi,
  required SensorProtocol protocol,
  required String deviceId,
  String? name,
  List<String> services = const [],
  DateTime? at,
}) {
  switch (protocol) {
    case SensorProtocol.treel:
      return decodeTreel(manufacturerData, rssi: rssi, at: at);
    case SensorProtocol.zeepin:
      return decodeZeepin(manufacturerData, rssi: rssi, at: at);
    case SensorProtocol.tesla:
      return decodeTeslaAdvertisement(
        manufacturerData,
        rssi: rssi,
        deviceId: deviceId,
        at: at,
      );
    case SensorProtocol.br:
      return decodeBr(
        manufacturerData,
        rssi: rssi,
        deviceId: deviceId,
        at: at,
      );
    case SensorProtocol.automatic:
      final tesla = decodeTeslaAdvertisement(
        manufacturerData,
        rssi: rssi,
        deviceId: deviceId,
        at: at,
      );
      if (tesla != null) return tesla;
      final treel = decodeTreel(manufacturerData, rssi: rssi, at: at);
      if (treel != null) return treel;
      final zeepin = decodeZeepin(manufacturerData, rssi: rssi, at: at);
      if (zeepin != null) return zeepin;
      final hasBrService = services.any(
        (uuid) => uuid.toLowerCase() == brServiceUuid,
      );
      final hasBrManufacturer = manufacturerData[0x1d28]?.length == 5;
      if (hasBrService || hasBrManufacturer || name == 'BR') {
        return decodeBr(
          manufacturerData,
          rssi: rssi,
          deviceId: deviceId,
          at: at,
        );
      }
      return null;
  }
}
