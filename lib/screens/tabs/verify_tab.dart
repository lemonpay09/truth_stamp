import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import '../../models/verification_record.dart';
import '../../services/exif_service.dart';
import '../../services/verification_history_service.dart';
import '../../services/watermark_service.dart';
import '../verification_detail_screen.dart';

class VerifyTab extends StatefulWidget {
  const VerifyTab({
    super.key,
    required this.historyService,
  });

  final VerificationHistoryService historyService;

  @override
  State<VerifyTab> createState() => _VerifyTabState();
}

class _VerifyTabState extends State<VerifyTab> {
  static const String _backendBaseUrl = 'https://truth-stamp.vercel.app';

  final ImagePicker _imagePicker = ImagePicker();
  final ExifService _exifService = const ExifService();
  final WatermarkService _watermarkService = const WatermarkService();
  final http.Client _httpClient = http.Client();
  late final VoidCallback _historyListener;

  bool _isBusy = false;
  String? _errorMessage;
  List<VerificationRecord> _records = <VerificationRecord>[];

  @override
  void initState() {
    super.initState();
    _historyListener = () {
      _reloadRecords();
    };
    _reloadRecords();
    widget.historyService.addListener(_historyListener);
  }

  @override
  void dispose() {
    widget.historyService.removeListener(_historyListener);
    _httpClient.close();
    super.dispose();
  }

  Future<void> _reloadRecords() async {
    final records = await widget.historyService.loadRecords();
    if (!mounted) return;
    setState(() => _records = records);
  }

  Future<void> _importAndVerify() async {
    if (_isBusy) return;

    final picked = await _imagePicker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;

    final file = File(picked.path);
    if (!await file.exists()) {
      if (!mounted) return;
      setState(() => _errorMessage = '所选图片不存在。');
      return;
    }

    setState(() {
      _isBusy = true;
      _errorMessage = null;
    });

    try {
      final exifHash = await _exifService.extractExifHash(file);
      final watermarkPayload =
          await _watermarkService.extractInvisibleWatermark(file);
      final watermarkHash = _extractHashFromWatermarkPayload(watermarkPayload);
      final hash = exifHash ?? watermarkHash;

      if (hash == null || hash.isEmpty) {
        throw StateError('未提取到有效的哈希。');
      }

      if (exifHash != null &&
          watermarkHash != null &&
          exifHash != watermarkHash) {
        throw StateError('EXIF 与盲水印哈希不一致。');
      }

      final lookup = await _lookup(hash);
      final stamp = lookup['stamp'] as Map<String, dynamic>;
      final verifyUrl = _verificationUrlForHash(hash);
      final record = await widget.historyService.upsertRecord(
        sourceImage: file,
        hash: hash,
        timestamp: stamp['timestamp']?.toString() ?? '-',
        latitude: stamp['latitude']?.toString() ?? '-',
        longitude: stamp['longitude']?.toString() ?? '-',
        accuracy: stamp['accuracy']?.toString() ?? '-',
        createdAt: stamp['created_at']?.toString() ?? '-',
        verifyUrl: verifyUrl,
      );

      if (!mounted) return;
      await _openDetail(record);
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = '鉴别失败：$error');
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  String? _extractHashFromWatermarkPayload(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    final uri = Uri.tryParse(payload);
    final queryHash = uri?.queryParameters['hash'];
    if (queryHash != null && queryHash.isNotEmpty) return queryHash;
    return payload.trim();
  }

  String _verificationUrlForHash(String hash) {
    return Uri.parse('$_backendBaseUrl/api/verify')
        .replace(queryParameters: <String, String>{'hash': hash})
        .toString();
  }

  Future<Map<String, dynamic>> _lookup(String hash) async {
    final response = await _httpClient
        .get(
          Uri.parse('$_backendBaseUrl/api/lookup')
              .replace(queryParameters: <String, String>{'hash': hash}),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(_extractError(response.body, response.statusCode));
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic> || decoded['found'] != true) {
      throw StateError('云端未找到对应记录。');
    }

    final stamp = decoded['stamp'];
    if (stamp is! Map<String, dynamic>) {
      throw StateError('云端返回的数据格式异常。');
    }

    return <String, dynamic>{'stamp': stamp};
  }

  String _extractError(String body, int statusCode) {
    if (body.trim().isEmpty) return 'HTTP $statusCode';
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic> && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } on FormatException {
      // ignore
    }
    return body;
  }

  Future<void> _openDetail(VerificationRecord record) async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VerificationDetailScreen(
          hash: record.hash,
          timestamp: record.timestamp,
          latitude: record.latitude,
          longitude: record.longitude,
          accuracy: record.accuracy,
          createdAt: record.createdAt,
          verifyUrl: record.verifyUrl,
        ),
      ),
    );
  }

  Future<void> _openHistoryDetail(VerificationRecord record) async {
    await _openDetail(record);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFFF3F6FB),
                borderRadius: BorderRadius.circular(28),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x12000000),
                    blurRadius: 30,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 62,
                        height: 62,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Icon(
                          Icons.photo_library_outlined,
                          color: Color(0xFF0B5FFF),
                          size: 30,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '从相册导入图片并鉴别',
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '本地提取 EXIF 与盲水印，再查询云端记录。',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      gradient: const LinearGradient(
                        colors: [Color(0xFFEAF1FF), Color(0xFFDCE7FF)],
                      ),
                    ),
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        shadowColor: Colors.transparent,
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                      ),
                      onPressed: _isBusy ? null : _importAndVerify,
                      child: Text(
                        _isBusy ? '鉴别中...' : '导入鉴别',
                        style: const TextStyle(
                          color: Color(0xFF0F172A),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.redAccent),
              ),
            ],
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'History Logs',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  '${_records.length} 条记录',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_records.isEmpty)
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(28),
                ),
                padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 24),
                child: Column(
                  children: [
                    Container(
                      width: 90,
                      height: 90,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF3F4F6),
                        borderRadius: BorderRadius.circular(28),
                      ),
                      child: const Icon(
                        Icons.inventory_2_outlined,
                        size: 42,
                        color: Color(0xFF9CA3AF),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      '暂无防伪记录',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '拍照同步成功后，历史记录会出现在这里。',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              )
            else
              ..._records.map(
                (record) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: InkWell(
                    onTap: () => _openHistoryDetail(record),
                    borderRadius: BorderRadius.circular(26),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(26),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x10000000),
                            blurRadius: 18,
                            offset: Offset(0, 8),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(20),
                            child: SizedBox(
                              width: 72,
                              height: 72,
                              child: _buildThumbnail(record),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  record.shortHash,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  record.timestamp,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '${record.latitude}, ${record.longitude}',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Icon(Icons.chevron_right_rounded, color: Color(0xFF9CA3AF)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnail(VerificationRecord record) {
    final file = File(record.imagePath);
    if (record.imagePath.isNotEmpty && file.existsSync()) {
      return Image.file(file, fit: BoxFit.cover);
    }
    return Container(
      color: const Color(0xFFF3F4F6),
      child: const Icon(Icons.photo_rounded, color: Color(0xFF9CA3AF)),
    );
  }
}
