import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/verification_record.dart';

class VerificationHistoryService extends ChangeNotifier {
  VerificationHistoryService();

  Future<File> _historyFile() async {
    final directory = await getApplicationDocumentsDirectory();
    final folder = Directory('${directory.path}/truth_stamp');
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }
    return File('${folder.path}/history.json');
  }

  Future<Directory> _imagesDirectory() async {
    final directory = await getApplicationDocumentsDirectory();
    final folder = Directory('${directory.path}/truth_stamp/history_images');
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }
    return folder;
  }

  Future<List<VerificationRecord>> loadRecords() async {
    final file = await _historyFile();
    if (!await file.exists()) {
      return <VerificationRecord>[];
    }

    final raw = await file.readAsString();
    if (raw.trim().isEmpty) {
      return <VerificationRecord>[];
    }

    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return <VerificationRecord>[];
    }

    return decoded
        .whereType<Map>()
        .map((item) => VerificationRecord.fromJson(item.cast<String, dynamic>()))
        .where((record) => record.hash.isNotEmpty)
        .toList();
  }

  Future<void> saveRecords(List<VerificationRecord> records) async {
    final file = await _historyFile();
    final payload = jsonEncode(records.map((record) => record.toJson()).toList());
    await file.writeAsString(payload, flush: true);
    notifyListeners();
  }

  Future<VerificationRecord> upsertRecord({
    required File sourceImage,
    required String hash,
    required String timestamp,
    required String latitude,
    required String longitude,
    required String accuracy,
    required String createdAt,
    required String verifyUrl,
  }) async {
    if (!await sourceImage.exists()) {
      throw ArgumentError.value(sourceImage.path, 'sourceImage', 'Image file not found.');
    }

    final copiedImage = await _copyImageToHistory(sourceImage, hash);
    final record = VerificationRecord(
      hash: hash,
      timestamp: timestamp,
      latitude: latitude,
      longitude: longitude,
      accuracy: accuracy,
      createdAt: createdAt,
      verifyUrl: verifyUrl,
      imagePath: copiedImage.path,
    );

    final records = await loadRecords();
    records.removeWhere((item) => item.hash == hash);
    records.insert(0, record);
    await saveRecords(records);
    return record;
  }

  Future<File> _copyImageToHistory(File sourceImage, String hash) async {
    final folder = await _imagesDirectory();
    final extension = _extensionForPath(sourceImage.path);
    final target = File('${folder.path}/$hash$extension');
    return sourceImage.copy(target.path);
  }

  String _extensionForPath(String path) {
    final fileName = path.split(Platform.pathSeparator).last;
    final index = fileName.lastIndexOf('.');
    if (index == -1) {
      return '.jpg';
    }
    return fileName.substring(index);
  }
}
