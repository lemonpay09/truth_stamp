import 'dart:convert';
import 'dart:io';

import 'package:gal/gal.dart';
import 'package:native_exif/native_exif.dart';

class ExifService {
  const ExifService();

  Future<bool> secureAndSaveImage(
    File watermarkedFile,
    String hash,
    String verifyUrl,
  ) async {
    if (!await watermarkedFile.exists()) {
      throw ArgumentError.value(
        watermarkedFile.path,
        'watermarkedFile',
        'Watermarked file not found.',
      );
    }

    final exif = await Exif.fromPath(watermarkedFile.path);
    try {
      final payload = jsonEncode(<String, String>{
        'hash': hash,
        'verifyUrl': verifyUrl,
      });

      await exif.writeAttributes(<String, String>{
        'UserComment': payload,
        'ImageDescription': 'Truth Stamp secure asset',
      });
    } finally {
      await exif.close();
    }

    try {
      await Gal.putImage(watermarkedFile.path);
      return true;
    } on GalException {
      return false;
    } on Exception {
      return false;
    }
  }
}
