import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../models/verification_record.dart';
import '../../services/crypto_service.dart';
import '../../services/exif_service.dart';
import '../../services/metadata_service.dart';
import '../../services/verification_history_service.dart';
import '../../services/watermark_service.dart';
import '../verification_detail_screen.dart';

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

class _CameraTabState extends State<CameraTab> {
  static const String _backendBaseUrl = 'https://truth-stamp.vercel.app';

  final MetadataService _metadataService = const MetadataService();
  final CryptoService _cryptoService = const CryptoService();
  final WatermarkService _watermarkService = const WatermarkService();
  final ExifService _exifService = const ExifService();
  final http.Client _httpClient = http.Client();

  CameraController? _cameraController;
  bool _isInitializingCamera = true;
  bool _isProcessing = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  @override
  void dispose() {
    _httpClient.close();
    _cameraController?.dispose();
    super.dispose();
  }

  CameraDescription? get _preferredCamera {
    for (final camera in widget.cameras) {
      if (camera.lensDirection == CameraLensDirection.back) {
        return camera;
      }
    }
    return widget.cameras.isNotEmpty ? widget.cameras.first : null;
  }

  bool get _isMockMode => widget.cameras.isEmpty;

  Future<void> _initializeCamera() async {
    if (_isMockMode) {
      if (!mounted) return;
      setState(() => _isInitializingCamera = false);
      return;
    }

    final selectedCamera = _preferredCamera;
    if (selectedCamera == null) {
      if (!mounted) return;
      setState(() {
        _isInitializingCamera = false;
        _errorMessage = 'No usable camera was found.';
      });
      return;
    }

    final controller = CameraController(
      selectedCamera,
      ResolutionPreset.high,
      enableAudio: false,
    );

    try {
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _cameraController = controller;
        _isInitializingCamera = false;
      });
    } on Exception catch (error) {
      await controller.dispose();
      if (!mounted) return;
      setState(() {
        _isInitializingCamera = false;
        _errorMessage = 'Failed to initialize camera: $error';
      });
    }
  }

  Future<void> _capture() async {
    if (_isProcessing) return;

    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });

    try {
      final capture = _isMockMode
          ? await _createMockCapture()
          : await _captureFromCamera();
      await _processCapture(capture);
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Capture failed: $error';
      });
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  Future<_CaptureBundle> _captureFromCamera() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      throw StateError('Camera is not ready.');
    }

    final photo = await controller.takePicture();
    final file = File(photo.path);
    final bytes = await file.readAsBytes();
    return _CaptureBundle(file: file, bytes: bytes);
  }

  Future<_CaptureBundle> _createMockCapture() async {
    final timestamp = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
    final bytes = await _buildMockPreviewBytes();
    final file = await _mockImageFile(timestamp, bytes);
    return _CaptureBundle(file: file, bytes: bytes);
  }

  Future<File> _mockImageFile(String timestamp, Uint8List bytes) async {
    final directory = await getTemporaryDirectory();
    final file = File(
      '${directory.path}/truth_stamp_camera_mock_$timestamp.png'
          .replaceAll(':', '-')
          .replaceAll(' ', '_'),
    );
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<Uint8List> _buildMockPreviewBytes() async {
    // 生成一个纯本地可预览的 PNG，避免模拟器空相机时页面空白。
    final image = img.Image(width: 1600, height: 1200);
    for (final pixel in image) {
      final xRatio = pixel.x / image.width;
      final yRatio = pixel.y / image.height;
      pixel
        ..r = (40 + 80 * xRatio).round()
        ..g = (70 + 90 * yRatio).round()
        ..b = (120 + 40 * (1 - xRatio)).round()
        ..a = 255;
    }
    return Uint8List.fromList(img.encodePng(image));
  }

  Future<void> _processCapture(_CaptureBundle capture) async {
    final timestamp = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
    final metadata = _isMockMode
        ? <String, dynamic>{
            'timestamp': timestamp,
            'latitude': 31.23,
            'longitude': 121.47,
            'accuracy': 10.0,
          }
        : await _metadataService.collectMetadata();

    final hash = _cryptoService.calculateSha256(
      imageBytes: capture.bytes,
      metadata: metadata,
    );

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
          }),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_responseError(response.body, response.statusCode));
    }

    final decoded = jsonDecode(response.body);
    final stamp = decoded is Map<String, dynamic> ? decoded['stamp'] : null;
    final stampMap = stamp is Map<String, dynamic> ? stamp : <String, dynamic>{};
    final verifyUrl = _verificationUrlForHash(hash);

    final record = await widget.historyService.upsertRecord(
      sourceImage: capture.file,
      hash: hash,
      timestamp: metadata['timestamp']?.toString() ?? timestamp,
      latitude: metadata['latitude']?.toString() ?? '-',
      longitude: metadata['longitude']?.toString() ?? '-',
      accuracy: metadata['accuracy']?.toString() ?? '-',
      createdAt: stampMap['created_at']?.toString() ?? DateTime.now().toIso8601String(),
      verifyUrl: verifyUrl,
    );

    await _saveSecureGalleryCopy(File(record.imagePath), record.hash, record.verifyUrl);

    if (!mounted) return;
    await _showSuccessSheet(record);
  }

  Future<void> _saveSecureGalleryCopy(
    File sourceFile,
    String hash,
    String verifyUrl,
  ) async {
    try {
      final watermarkedFile = await _watermarkService.embedInvisibleWatermark(
        sourceFile,
        verifyUrl,
      );
      await _exifService.secureAndSaveImage(watermarkedFile, hash, verifyUrl);
    } on Exception {
      // 保持主流程成功；本地相册保护失败不应阻断云端同步后的反馈。
    }
  }

  String _verificationUrlForHash(String hash) {
    return Uri.parse('$_backendBaseUrl/api/verify')
        .replace(queryParameters: <String, String>{'hash': hash})
        .toString();
  }

  String _responseError(String body, int statusCode) {
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

  Future<void> _showSuccessSheet(VerificationRecord record) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewPadding.bottom),
          child: DraggableScrollableSheet(
            initialChildSize: 0.72,
            minChildSize: 0.52,
            maxChildSize: 0.92,
            builder: (context, controller) {
              return Container(
                decoration: const BoxDecoration(
                  color: Color(0xFFF7F8FA),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
                ),
                child: ListView(
                  controller: controller,
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                  children: [
                    Center(
                      child: Container(
                        width: 42,
                        height: 5,
                        decoration: BoxDecoration(
                          color: Colors.black12,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(28),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x14000000),
                            blurRadius: 30,
                            offset: Offset(0, 10),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Icon(Icons.verified_rounded, color: Color(0xFF1B5E20), size: 56),
                          const SizedBox(height: 10),
                          Text(
                            '已同步至云端',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '本次拍摄已生成防伪二维码与云端记录。',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 18),
                          Center(
                            child: Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(24),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Color(0x14000000),
                                    blurRadius: 18,
                                    offset: Offset(0, 8),
                                  ),
                                ],
                              ),
                              child: QrImageView(
                                data: record.verifyUrl,
                                size: 210,
                                backgroundColor: Colors.white,
                                version: QrVersions.auto,
                                eyeStyle: const QrEyeStyle(
                                  eyeShape: QrEyeShape.square,
                                  color: Color(0xFF1B5E20),
                                ),
                                dataModuleStyle: const QrDataModuleStyle(
                                  dataModuleShape: QrDataModuleShape.square,
                                  color: Color(0xFF111827),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 18),
                          _InfoLine(label: '哈希指纹', value: record.hash),
                          const SizedBox(height: 10),
                          _InfoLine(label: '时间', value: record.timestamp),
                          const SizedBox(height: 10),
                          _InfoLine(
                            label: '经纬度',
                            value: '${record.latitude}, ${record.longitude}',
                          ),
                          const SizedBox(height: 10),
                          _InfoLine(label: '定位精度', value: '${record.accuracy} m'),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        gradient: const LinearGradient(
                          colors: [Color(0xFF34C759), Color(0xFF0A8F3E)],
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x220A8F3E),
                            blurRadius: 24,
                            offset: Offset(0, 10),
                          ),
                        ],
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
                        onPressed: () {
                          Navigator.of(context).pop();
                          Navigator.of(this.context).push(
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
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(32),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x14000000),
                        blurRadius: 30,
                        offset: Offset(0, 12),
                      ),
                    ],
                  ),
                  child: _buildPreviewArea(),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 74,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(26),
                    gradient: const LinearGradient(
                      colors: [Color(0xFF34C759), Color(0xFF0A8F3E)],
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x220A8F3E),
                        blurRadius: 24,
                        offset: Offset(0, 10),
                      ),
                    ],
                  ),
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(26),
                      ),
                    ),
                    onPressed: _isProcessing ? null : _capture,
                    icon: const Icon(Icons.camera_alt_rounded),
                    label: Text(
                      _isMockMode ? '模拟拍照并同步' : '拍照并同步',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 12),
                Text(
                  _errorMessage!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPreviewArea() {
    if (_isInitializingCamera) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_isMockMode) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(32),
        child: Container(
          color: const Color(0xFFF2F4F7),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.photo_camera_outlined, size: 64, color: Color(0xFF6B7280)),
              const SizedBox(height: 12),
              Text(
                '模拟器模式 · 无实体相机',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: const Color(0xFF374151),
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
        ),
      );
    }

    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(32),
      child: CameraPreview(controller),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 88,
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
        ),
      ],
    );
  }
}

class _CaptureBundle {
  const _CaptureBundle({
    required this.file,
    required this.bytes,
  });

  final File file;
  final Uint8List bytes;
}
