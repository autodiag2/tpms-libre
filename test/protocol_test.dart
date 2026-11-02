import 'package:flutter_test/flutter_test.dart';
import 'package:tpms_libre/treel/reading.dart';

List<int> hex(String s) => [
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
];

void main() {
  test('decodes ZEEPIN TP630 manufacturer data', () {
    final reading = decodeZeepin({
      0x0001: hex('80EACA108A78E36D0000E60A00005B00'),
    }, rssi: -60);

    expect(reading, isNotNull);
    expect(reading!.sensorId, '80eaca108a78');
    expect(reading.psi, 10);
    expect(reading.celsius, 27);
  });

  test('rejects malformed ZEEPIN manufacturer data', () {
    expect(decodeZeepin({0x0001: hex('80EACA')}, rssi: -60), isNull);
  });

  test('decodes BR service advertisement manufacturer data', () {
    final reading = decodeBr({
      0x1d28: hex('130105A37600AA'),
    }, rssi: -60, name: 'BR', at: null);

    expect(reading, isNotNull);
    expect(reading!.sensorId, startsWith('br-'));
    expect(reading.celsius, 5);
    expect(reading.psi, 26);
  });

  test('automatic detection prefers exact Treel and ZEEPIN signatures', () {
    final treel = decodeSensor({
      0x004c: hex('0215ffffffffffffffffffffffffffffffe0f10a02238a'),
    }, rssi: -60, protocol: SensorProtocol.automatic);
    expect(treel?.sensorId, 'f10a02');

    final zeepin = decodeSensor({
      0x0001: hex('80EACA108A78E36D0000E60A00005B00'),
    }, rssi: -60, protocol: SensorProtocol.automatic);
    expect(zeepin?.sensorId, '80eaca108a78');
  });
}
