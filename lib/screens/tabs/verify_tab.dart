import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/verification_record.dart';
import '../../services/thumbnail_service.dart';
import '../../services/usage_limit_service.dart';
import '../../services/verification_history_service.dart';
import '../auth/paywall_screen.dart';
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
  static const String _detectorApiUrl = 'http://192.168.3.107:8000/api/detect';

  final ImagePicker _imagePicker = ImagePicker();
  final ThumbnailService _thumbnailService = const ThumbnailService();
  final UsageLimitService _usageLimitService = const UsageLimitService();
  late final VoidCallback _historyListener;

  bool _isBusy = false;
  String? _busyMessage;
  String? _errorMessage;
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
    super.dispose();
  }

  Future<void> _reloadRecords() async {
    final records = await widget.historyService.loadRecordsByType('detect');
    if (!mounted) return;
    setState(() => _records = records);
  }

  Future<void> _importAndVerify() async {
    if (_isBusy) return;
    final decision = await _usageLimitService.evaluate();
    if (!decision.allowed) {
      await HapticFeedback.mediumImpact();
      if (!mounted) return;
      await showProPaywall(context, dailyCount: decision.todayCount);
      return;
    }

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
      _busyMessage = '正在进行物理级像素取证...';
      _errorMessage = null;
    });

    try {
      await _usageLimitService.consume(decision);
      final thumbnailBase64 =
          await _thumbnailService.generateTinyThumbnailBase64(file);
      final result = await _detectWithDetector(file);
      final now = DateTime.now();
      final conclusion = result.conclusion.isNotEmpty
          ? result.conclusion
          : _buildConclusion(
              metadataScore: result.metadataScore,
              forgeryScore: result.forgeryScore,
            );
      final record = await widget.historyService.upsertRecord(
        sourceImage: file,
        hash: 'detect-${now.microsecondsSinceEpoch}',
        timestamp: now.toString(),
        latitude: '-',
        longitude: '-',
        accuracy: '-',
        createdAt: now.toIso8601String(),
        verifyUrl: '',
        recordType: 'detect',
        thumbnailBase64: thumbnailBase64,
        heatmapBase64: result.heatmapImage,
        maskBase64: result.maskImageBase64,
        metadataScore: result.metadataScore.toString(),
        forgeryScore: result.forgeryScore.toString(),
        conclusion: conclusion,
        aiScore: result.aiScore.toString(),
      );

      if (!mounted) return;
      await HapticFeedback.lightImpact();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => VerificationDetailScreen(
            isDetectorResult: true,
            detectorHeatmapImage: result.heatmapImage,
            detectorMaskImage: result.maskImageBase64,
            sourceImagePath: record.imagePath,
            metadataScore: result.metadataScore,
            aiScore: result.aiScore,
            forgeryScore: result.forgeryScore,
            detectorMessage: result.message,
            isForgery: result.isForgery,
            detectorConclusion: conclusion,
            hash: record.hash,
            timestamp: '-',
            latitude: '-',
            longitude: '-',
            accuracy: '-',
            createdAt: record.createdAt,
            verifyUrl: '',
          ),
        ),
      );
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = '鉴别失败：$error');
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
          _busyMessage = null;
        });
      }
    }
  }

  Future<_DetectorResult> _detectWithDetector(File file) async {
    final request = http.MultipartRequest('POST', Uri.parse(_detectorApiUrl));
    request.headers['Accept'] = 'application/json';
    final extension = _fileExtension(file.path);
    final mediaType = extension == '.png'
        ? MediaType('image', 'png')
        : MediaType('image', 'jpeg');

    request.files.add(
      await http.MultipartFile.fromPath(
        'file',
        file.path,
        filename: file.uri.pathSegments.isNotEmpty
            ? file.uri.pathSegments.last
            : 'upload.jpg',
        contentType: mediaType,
      ),
    );

    final streamResponse = await request.send().timeout(
      const Duration(seconds: 40),
      onTimeout: () {
        throw StateError('算法服务超时，请确认 Python 鉴伪服务正在运行。');
      },
    );
    final response = await http.Response.fromStream(streamResponse);
    final rawBody = response.body.trim();
    final decoded = rawBody.isEmpty ? <String, dynamic>{} : jsonDecode(rawBody);
    final body = decoded is Map<String, dynamic>
        ? decoded
        : <String, dynamic>{'raw': rawBody};

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final detail = body['detail']?.toString();
      throw StateError(
        detail ?? body['error']?.toString() ?? '检测接口异常（${response.statusCode}）',
      );
    }

    final heatmap = body['heatmap_image']?.toString() ?? '';
    if (heatmap.isEmpty) {
      throw StateError('算法服务未返回 heatmap_image。');
    }

    final details = body['details'] as Map<String, dynamic>? ?? <String, dynamic>{};
    final aiScore = _asInt(details['ai_score']);
    final maskImage = body['mask_image_base64']?.toString() ??
        details['mask_image_base64']?.toString() ??
        '';

    return _DetectorResult(
      isForgery: body['is_forgery'] == true,
      metadataScore: _asInt(body['metadata_score']),
      forgeryScore: _asInt(body['forgery_score']),
      aiScore: aiScore,
      heatmapImage: heatmap,
      maskImageBase64: maskImage,
      message: body['message']?.toString() ?? '取证完成',
      conclusion: body['conclusion']?.toString() ?? details['conclusion']?.toString() ?? '',
    );
  }

  String _fileExtension(String path) {
    final index = path.lastIndexOf('.');
    if (index < 0) return '';
    return path.substring(index).toLowerCase();
  }

  int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  String _buildConclusion({
    required int metadataScore,
    required int forgeryScore,
  }) {
    if (forgeryScore >= 80 || metadataScore <= 35) {
      return '高度伪造风险';
    }
    if (forgeryScore >= 55 || metadataScore <= 60) {
      return '疑似局部修改';
    }
    return '安全 (未见篡改)';
  }

  Future<void> _openHistoryDetail(VerificationRecord record) async {
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
          isDetectorResult: true,
          detectorHeatmapImage: record.heatmapBase64,
          detectorMaskImage: record.maskBase64,
          sourceImagePath: record.imagePath,
          metadataScore: int.tryParse(record.metadataScore ?? ''),
          aiScore: int.tryParse(record.aiScore ?? ''),
          forgeryScore: int.tryParse(record.forgeryScore ?? ''),
          detectorConclusion: record.conclusion,
        ),
      ),
    );
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
                              '从相册导入图片并鉴伪',
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '上传算法服务器进行像素误差取证，生成篡改热力图。',
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
                        _isBusy ? '取证中...' : '导入鉴伪',
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
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '历史记录',
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
                padding:
                    const EdgeInsets.symmetric(vertical: 36, horizontal: 24),
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
                      '暂无鉴伪记录',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '导入外来图片后，记录会出现在这里。',
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
                                if ((record.conclusion ?? '').isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    record.conclusion!,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: const Color(0xFF2563EB),
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Icon(
                            Icons.chevron_right_rounded,
                            color: Color(0xFF9CA3AF),
                          ),
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
    final thumb = record.thumbnailBase64;
    if (thumb != null && thumb.isNotEmpty) {
      final bytes = _safeDecodeBase64(thumb);
      if (bytes != null) {
        return Image.memory(bytes, fit: BoxFit.cover);
      }
    }

    final file = File(record.imagePath);
    if (record.imagePath.isNotEmpty && file.existsSync()) {
      return Image.file(file, fit: BoxFit.cover);
    }
    return Container(
      color: const Color(0xFFF3F4F6),
      child: const Icon(Icons.photo_rounded, color: Color(0xFF9CA3AF)),
    );
  }

  Uint8List? _safeDecodeBase64(String value) {
    final normalized = value.contains(',') ? value.split(',').last : value;
    try {
      return base64Decode(normalized);
    } on FormatException {
      return null;
    }
  }
}

class _DetectorResult {
  const _DetectorResult({
    required this.isForgery,
    required this.metadataScore,
    required this.forgeryScore,
    required this.aiScore,
    required this.heatmapImage,
    required this.maskImageBase64,
    required this.message,
    required this.conclusion,
  });

  final bool isForgery;
  final int metadataScore;
  final int forgeryScore;
  final int aiScore;
  final String heatmapImage;
  final String maskImageBase64;
  final String message;
  final String conclusion;
}
