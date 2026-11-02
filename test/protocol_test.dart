import 'package:flutter_test/flutter_test.dart';
import 'package:tpms_libre/treel/reading.dart';

List<int> hex(String s) => [
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
];

void main() {
  test('decodes ZEEPIN TP630 manufacturer payload', () {
    final reading = decodeZeepin({
      0x0001: hex('80EACA108A78E36D0000E60A00005B00'),
    }, rssi: -60);

    expect(reading, isNotNull);
    expect(reading!.sensorId, '80eaca108a78');
    expect(reading.psi, 4);
    expect(reading.celsius, 28);
  });

  test('rejects malformed ZEEPIN manufacturer payload', () {
    expect(decodeZeepin({0x0001: hex('80EACA')}, rssi: -60), isNull);
  });

  test('decodes the BR manufacturer payload using upstream scaling', () {
    final reading = decodeBr(
      {0x1d28: hex('130105A376')},
      rssi: -60,
      deviceId: 'AC:15:85:12:34:56',
    );

    expect(reading, isNotNull);
    expect(reading!.sensorId, 'br-ac1585123456');
    expect(reading.celsius, 19);
    expect(reading.psi, 12);
  });

  test('automatic detection recognises Treel and ZEEPIN signatures', () {
    final treel = decodeSensor({
      0x004c: hex('0215ffffffffffffffffffffffffffffffe0f10a02238a'),
    }, rssi: -60, protocol: SensorProtocol.automatic, deviceId: 'treel');
    expect(treel?.sensorId, 'f10a02');

    final zeepin = decodeSensor({
      0x0001: hex('80EACA108A78E36D0000E60A00005B00'),
    }, rssi: -60, protocol: SensorProtocol.automatic, deviceId: 'zeepin');
    expect(zeepin?.sensorId, '80eaca108a78');
  });

  test('automatic detection recognises BR manufacturer signature', () {
    final br = decodeSensor({
      0x1d28: hex('130105A376'),
    }, rssi: -60, protocol: SensorProtocol.automatic, deviceId: 'AC:15:85:12:34:56');
    expect(br?.sensorId, 'br-ac1585123456');
  });

  test('manual protocol selection does not decode a different format', () {
    expect(
      decodeSensor(
        {0x1d28: hex('130105A376')},
        rssi: -60,
        protocol: SensorProtocol.treel,
        deviceId: 'br',
      ),
      isNull,
    );
  });
}
