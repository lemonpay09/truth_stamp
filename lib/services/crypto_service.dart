import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class CryptoService {
  const CryptoService();

  String calculateSha256({
    required Uint8List imageBytes,
    required Map<String, dynamic> metadata,
  }) {
    if (imageBytes.isEmpty) {
      throw ArgumentError.value(imageBytes, 'imageBytes', 'Image bytes cannot be empty.');
    }

    try {
      final metadataBytes = utf8.encode(jsonEncode(metadata));
      final combinedBytes = Uint8List.fromList([
        ...imageBytes,
        ...metadataBytes,
      ]);
      return sha256.convert(combinedBytes).toString();
    } on JsonUnsupportedObjectError catch (error) {
      throw Exception('Metadata cannot be encoded as JSON: $error');
    } on FormatException catch (error) {
      throw Exception('Invalid metadata format: $error');
    } on Exception catch (error) {
      throw Exception('Unable to calculate SHA-256: $error');
    }
  }
}
