import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../verification_detail_screen.dart';
import '../../services/crypto_service.dart';
import '../../services/exif_service.dart';
import '../../services/metadata_service.dart';
import '../../services/thumbnail_service.dart';
import '../../services/verification_history_service.dart';
import '../../services/watermark_service.dart';

class CameraTab extends StatefulWidget {
  const CameraTab({
    super.key,
    required this.cameras,
    required this.historyService,
  });

  final List<CameraDescription> cameras;
  final VerificationHistoryService historyService;

  @override
  State<CameraTab> createState() => _CameraTabState();
}

class _CameraCaptureResult {
  const _CameraCaptureResult({
    required this.hash,
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.createdAt,
    required this.verifyUrl,
  });

  final String hash;
  final String timestamp;
  final String latitude;
  final String longitude;
  final String accuracy;
  final String createdAt;
  final String verifyUrl;
}

class _CameraTabState extends State<CameraTab> {
  static const String _backendBaseUrl = 'https://truthstamp.cn';

  final MetadataService _metadataService = const MetadataService();
  final CryptoService _cryptoService = const CryptoService();
  final WatermarkService _watermarkService = const WatermarkService();
  final ExifService _exifService = const ExifService();
  final ThumbnailService _thumbnailService = const ThumbnailService();
  final ImagePicker _imagePicker = ImagePicker();
  final http.Client _httpClient = http.Client();

  bool _isProcessing = false;
  String? _progressMessage;
  String? _errorMessage;
  _CameraCaptureResult? _lastResult;

  @override
  void dispose() {
    _httpClient.close();
    super.dispose();
  }

  String _verificationUrlForHash(String hash) {
    return Uri.parse('$_backendBaseUrl/api/verify')
        .replace(queryParameters: <String, String>{'hash': hash})
        .toString();
  }

  Future<void> _openSystemCamera() async {
    if (_isProcessing) return;
    if (widget.cameras.isEmpty) {
      setState(() {
        _errorMessage = '当前设备未检测到可用摄像头。';
      });
      return;
    }

    setState(() {
      _errorMessage = null;
    });

    final shot = await _imagePicker.pickImage(source: ImageSource.camera);
    if (shot == null) return;

    await _processCapturedImage(File(shot.path));
  }

  Future<void> _processCapturedImage(File sourceImage) async {
    setState(() {
      _isProcessing = true;
      _progressMessage = '正在获取时空元数据...';
      _errorMessage = null;
    });

    try {
      final metadata = await _metadataService.collectMetadata();
      final normalizedMetadata = <String, dynamic>{
        ...metadata,
        'timestamp': metadata['timestamp']?.toString() ??
            DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now()),
      };

      final bytes = await sourceImage.readAsBytes();
      final hash = _cryptoService.calculateSha256(
        imageBytes: bytes,
        metadata: normalizedMetadata,
      );
      final thumbnailBase64 =
          await _thumbnailService.generateTinyThumbnailBase64(sourceImage);
      final verifyUrl = _verificationUrlForHash(hash);

      if (!mounted) return;
      setState(() => _progressMessage = '正在同步至云端...');
      await _uploadStamp(hash, normalizedMetadata, thumbnailBase64);

      if (!mounted) return;
      setState(() => _progressMessage = '正在写入防伪信息...');
      final watermarked = await _watermarkService.embedInvisibleWatermark(
        sourceImage,
        verifyUrl,
      );
      final saved = await _exifService.secureAndSaveImage(
        watermarked,
        hash,
        verifyUrl,
      );
      if (!saved) {
        throw StateError('防伪图片保存失败，请检查相册权限。');
      }

      if (!mounted) return;
      setState(() => _progressMessage = '正在生成鉴别结果...');
      final createdAt = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
      await widget.historyService.upsertRecord(
        sourceImage: watermarked,
        hash: hash,
        timestamp: normalizedMetadata['timestamp']?.toString() ?? '-',
        latitude: normalizedMetadata['latitude']?.toString() ?? '-',
        longitude: normalizedMetadata['longitude']?.toString() ?? '-',
        accuracy: normalizedMetadata['accuracy']?.toString() ?? '-',
        createdAt: createdAt,
        verifyUrl: verifyUrl,
        recordType: 'verify',
        thumbnailBase64: thumbnailBase64,
      );

      final result = _CameraCaptureResult(
        hash: hash,
        timestamp: normalizedMetadata['timestamp']?.toString() ?? '-',
        latitude: normalizedMetadata['latitude']?.toString() ?? '-',
        longitude: normalizedMetadata['longitude']?.toString() ?? '-',
        accuracy: normalizedMetadata['accuracy']?.toString() ?? '-',
        createdAt: createdAt,
        verifyUrl: verifyUrl,
      );

      if (!mounted) return;
      setState(() {
        _lastResult = result;
        _isProcessing = false;
        _progressMessage = null;
      });

      await _showResultSheet(result);
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _progressMessage = null;
        _errorMessage = '处理失败：$error';
      });
    }
  }

  Future<void> _uploadStamp(
    String hash,
    Map<String, dynamic> metadata,
    String? thumbnailBase64,
  ) async {
    final response = await _httpClient
        .post(
          Uri.parse('$_backendBaseUrl/api/upload'),
          headers: const <String, String>{
            'Content-Type': 'application/json; charset=utf-8',
          },
          body: jsonEncode(<String, dynamic>{
            'hash': hash,
            'timestamp': metadata['timestamp'],
            'latitude': metadata['latitude'],
            'longitude': metadata['longitude'],
            'accuracy': metadata['accuracy'],
            'thumbnail_base64': thumbnailBase64,
          }),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(_extractError(response.body, response.statusCode));
    }
  }

  String _extractError(String body, int statusCode) {
    if (body.trim().isEmpty) return 'HTTP $statusCode';
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic> && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } on FormatException {
      // fallback below
    }
    return body;
  }

  Future<void> _showResultSheet(_CameraCaptureResult result) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return DraggableScrollableSheet(
          initialChildSize: 0.72,
          minChildSize: 0.56,
          maxChildSize: 0.92,
          expand: false,
          builder: (_, controller) {
            return Container(
              decoration: const BoxDecoration(
                color: Color(0xFFF7F8FB),
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 20),
              child: ListView(
                controller: controller,
                children: [
                  Center(
                    child: Container(
                      width: 42,
                      height: 4,
                      decoration: BoxDecoration(
                        color: const Color(0xFFCBD5E1),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    '防伪凭证已生成',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x14000000),
                          blurRadius: 24,
                          offset: Offset(0, 12),
                        ),
                      ],
                    ),
                    child: Center(
                      child: QrImageView(
                        data: result.verifyUrl,
                        version: QrVersions.auto,
                        size: 180,
                        backgroundColor: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  _ResultRow(label: '哈希指纹', value: result.hash),
                  _ResultRow(label: '时间', value: result.timestamp),
                  _ResultRow(
                    label: 'GPS',
                    value: '${result.latitude}, ${result.longitude}',
                  ),
                  _ResultRow(label: '定位精度', value: '${result.accuracy} m'),
                  const SizedBox(height: 12),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      gradient: const LinearGradient(
                        colors: [Color(0xFF3B82F6), Color(0xFF2563EB)],
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x332563EB),
                          blurRadius: 18,
                          offset: Offset(0, 8),
                        ),
                      ],
                    ),
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        shadowColor: Colors.transparent,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => VerificationDetailScreen(
                              hash: result.hash,
                              timestamp: result.timestamp,
                              latitude: result.latitude,
                              longitude: result.longitude,
                              accuracy: result.accuracy,
                              createdAt: result.createdAt,
                              verifyUrl: result.verifyUrl,
                            ),
                          ),
                        );
                      },
                      child: const Text(
                        '查看鉴别详情',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasCamera = widget.cameras.isNotEmpty;
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6FA),
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      onTap: hasCamera ? _openSystemCamera : null,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(22, 28, 22, 28),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE9EDF3),
                          borderRadius: BorderRadius.circular(30),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x22000000),
                              blurRadius: 24,
                              offset: Offset(0, 12),
                            ),
                          ],
                        ),
                        child: Column(
                          children: [
                            Container(
                              width: 62,
                              height: 62,
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.85),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: const Icon(
                                CupertinoIcons.camera_fill,
                                size: 30,
                                color: Color(0xFF475569),
                              ),
                            ),
                            const SizedBox(height: 14),
                            const Text(
                              '点击开启系统相机，固化时空真迹',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF334155),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          gradient: const LinearGradient(
                            colors: [Color(0xFF3B82F6), Color(0xFF2563EB)],
                          ),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x332563EB),
                              blurRadius: 22,
                              offset: Offset(0, 10),
                            ),
                          ],
                        ),
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            shadowColor: Colors.transparent,
                            padding: const EdgeInsets.symmetric(vertical: 17),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                          ),
                          onPressed: hasCamera ? _openSystemCamera : null,
                          child: const Text(
                            '开启原厂相机',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 14),
                      Text(
                        _errorMessage!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xFFB91C1C),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    if (_lastResult != null) ...[
                      const SizedBox(height: 10),
                      TextButton(
                        onPressed: () => _showResultSheet(_lastResult!),
                        child: const Text('查看最近一次防伪结果'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (_isProcessing)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black.withOpacity(0.25),
                  child: Center(
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 28),
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 26,
                            height: 26,
                            child: CircularProgressIndicator(strokeWidth: 2.8),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _progressMessage ?? '处理中...',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF334155),
                            ),
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
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Color(0xFF64748B),
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            value,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF0F172A),
            ),
          ),
        ],
      ),
    );
  }
}
