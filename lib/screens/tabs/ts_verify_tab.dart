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

class TsVerifyTab extends StatefulWidget {
  const TsVerifyTab({
    super.key,
    required this.historyService,
  });

  final VerificationHistoryService historyService;

  @override
  State<TsVerifyTab> createState() => _TsVerifyTabState();
}

class _TsVerifyTabState extends State<TsVerifyTab> {
  static const String _backendBaseUrl = 'https://truthstamp.cn';

  final ImagePicker _imagePicker = ImagePicker();
  final ExifService _exifService = const ExifService();
  final WatermarkService _watermarkService = const WatermarkService();
  final http.Client _httpClient = http.Client();
  late final VoidCallback _historyListener;

  bool _isBusy = false;
  String? _errorMessage;
  String? _busyMessage;
  List<VerificationRecord> _records = <VerificationRecord>[];

  @override
  void initState() {
    super.initState();
    _historyListener = _reloadRecords;
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
      _busyMessage = '正在校验 EXIF 与盲水印...';
      _errorMessage = null;
    });

    try {
      final exifHash = await _exifService.extractExifHash(file);
      final watermarkPayload =
          await _watermarkService.extractInvisibleWatermark(file);
      final watermarkHash = _extractHashFromWatermarkPayload(watermarkPayload);
      final hash = exifHash ?? watermarkHash;

      if (hash == null || hash.isEmpty) {
        throw StateError('未提取到有效哈希。');
      }
      if (exifHash != null &&
          watermarkHash != null &&
          exifHash != watermarkHash) {
        throw StateError('EXIF 与盲水印哈希不一致。');
      }

      setState(() => _busyMessage = '正在查询云端存证记录...');
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
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = '验证失败：$error');
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
          _busyMessage = null;
        });
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
      throw StateError('云端返回数据格式异常。');
    }
    return <String, dynamic>{'stamp': stamp};
  }

  String _extractError(String body, int statusCode) {
    if (body.trim().isEmpty) return 'HTTP $statusCode';
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        if (decoded['error'] is String) return decoded['error'] as String;
      }
    } on FormatException {
      return body;
    }
    return body;
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
                  Text(
                    'TS 照片验证',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '本地提取 EXIF 与盲水印，匹配 Supabase 云端记录。',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _isBusy ? null : _importAndVerify,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF0B5FFF),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(22),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: Text(
                      _isBusy ? '验证中...' : '导入验证',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
            ),
            if (_busyMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                _busyMessage!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF2563EB),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.redAccent),
              ),
            ],
            const SizedBox(height: 16),
            Text(
              '最近验证记录',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            if (_records.isEmpty)
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(22),
                ),
                padding:
                    const EdgeInsets.symmetric(vertical: 28, horizontal: 18),
                child: Text(
                  '暂无记录',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              ..._records.take(8).map(
                    (record) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: ListTile(
                        tileColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                        title: Text(record.shortHash),
                        subtitle: Text(record.timestamp),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () async {
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
                        },
                      ),
                    ),
                  ),
          ],
        ),
      ),
    );
  }
}
