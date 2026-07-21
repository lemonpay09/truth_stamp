import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;

class ThumbnailService {
  const ThumbnailService();

  Future<String?> generateTinyThumbnailBase64(
    File source, {
    int size = 80,
  }) async {
    if (!await source.exists()) return null;
    final bytes = await source.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;

    final square = _centerCropSquare(decoded);
    final resized = img.copyResize(
      square,
      width: size,
      height: size,
      interpolation: img.Interpolation.cubic,
    );
    final jpeg = img.encodeJpg(resized, quality: 72);
    return base64Encode(jpeg);
  }

  img.Image _centerCropSquare(img.Image image) {
    final side = image.width < image.height ? image.width : image.height;
    final x = (image.width - side) ~/ 2;
    final y = (image.height - side) ~/ 2;
    return img.copyCrop(image, x: x, y: y, width: side, height: side);
  }
}
