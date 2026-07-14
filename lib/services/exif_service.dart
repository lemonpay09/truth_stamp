import 'dart:convert';
import 'dart:io';

import 'package:gal/gal.dart';
import 'package:native_exif/native_exif.dart';

class ExifService {
  const ExifService();

  Future<String?> extractExifHash(File imageFile) async {
    if (!await imageFile.exists()) {
      throw ArgumentError.value(
        imageFile.path,
        'imageFile',
        'Image file not found.',
      );
    }

    final exif = await Exif.fromPath(imageFile.path);
    try {
      final userComment = await exif.getAttribute('UserComment');
      if (userComment == null || userComment.isEmpty) {
        return null;
      }

      final decoded = jsonDecode(userComment);
      if (decoded is Map<String, dynamic>) {
        final hash = decoded['hash'];
        if (hash is String && hash.isNotEmpty) {
          return hash;
        }
      }
    } finally {
      await exif.close();
    }

    return null;
  }

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
