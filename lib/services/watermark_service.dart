import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

class WatermarkService {
  const WatermarkService();

  Future<File> embedInvisibleWatermark(
    File imageFile,
    String textData,
  ) async {
    if (!await imageFile.exists()) {
      throw ArgumentError.value(imageFile.path, 'imageFile', 'Image file not found.');
    }
    if (textData.isEmpty) {
      throw ArgumentError.value(textData, 'textData', 'Watermark payload cannot be empty.');
    }

    final sourceBytes = await imageFile.readAsBytes();
    final decoded = img.decodeImage(sourceBytes);
    if (decoded == null) {
      throw StateError('Unsupported image format: ${imageFile.path}');
    }

    final payloadBits = _toBitStream(textData);
    final capacityBits = decoded.width * decoded.height * 4;
    if (payloadBits.length > capacityBits) {
      throw StateError(
        'Watermark payload is too large for this image (${payloadBits.length} bits > $capacityBits bits).',
      );
    }

    var bitIndex = 0;
    for (final pixel in decoded) {
      if (bitIndex >= payloadBits.length) {
        break;
      }

      pixel.r = _embedBit(pixel.r.toInt(), payloadBits[bitIndex++]);
      if (bitIndex >= payloadBits.length) {
        break;
      }
      pixel.g = _embedBit(pixel.g.toInt(), payloadBits[bitIndex++]);
      if (bitIndex >= payloadBits.length) {
        break;
      }
      pixel.b = _embedBit(pixel.b.toInt(), payloadBits[bitIndex++]);
      if (bitIndex >= payloadBits.length) {
        break;
      }
      pixel.a = _embedBit(pixel.a.toInt(), payloadBits[bitIndex++]);
    }

    // LSB 水印需要无损保存；PNG 可最大程度保留最低有效位。
    final encoded = img.encodePng(decoded);
    final tempDir = await getTemporaryDirectory();
    final outputFile = File(
      '${tempDir.path}/truth_stamp_watermarked_${DateTime.now().microsecondsSinceEpoch}.png',
    );
    await outputFile.writeAsBytes(Uint8List.fromList(encoded), flush: true);
    return outputFile;
  }

  List<int> _toBitStream(String textData) {
    final payloadBytes = utf8.encode(textData);
    final lengthBytes = ByteData(4)..setUint32(0, payloadBytes.length, Endian.big);
    final fullBytes = <int>[
      ...lengthBytes.buffer.asUint8List(),
      ...payloadBytes,
    ];

    final bits = <int>[];
    for (final byte in fullBytes) {
      for (var shift = 7; shift >= 0; shift--) {
        bits.add((byte >> shift) & 1);
      }
    }
    return bits;
  }

  int _embedBit(int channelValue, int bit) {
    return (channelValue & 0xFE) | (bit & 1);
  }
}
