import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/crypto_service.dart';
import '../services/exif_service.dart';
import '../services/metadata_service.dart';
import '../services/watermark_service.dart';
import 'verification_detail_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.cameras,
  });

  final List<CameraDescription> cameras;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const String _backendBaseUrl = 'https://truthstamp.cn';

  final MetadataService _metadataService = const MetadataService();
  final CryptoService _cryptoService = const CryptoService();
  final WatermarkService _watermarkService = const WatermarkService();
  final ExifService _exifService = const ExifService();
  final ImagePicker _imagePicker = ImagePicker();
  final http.Client _httpClient = http.Client();

  CameraController? _cameraController;
  bool _isInitializingCamera = true;
  String? _loadingMessage;
  String? _errorMessage;
  String? _uploadError;
  String? _saveError;

  File? _capturedImageFile;
  Map<String, dynamic>? _capturedMetadata;
  Map<String, dynamic>? _cloudStamp;
  String? _capturedHash;
  bool _uploadSucceeded = false;
  bool _gallerySaved = false;

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

  bool get _isBusy => _loadingMessage != null;

  /// 没有相机（iOS 模拟器）时自动进入 Mock 模式。
  bool get _isMockMode => widget.cameras.isEmpty;

  String _verificationUrlForHash(String hash) {
    return Uri.parse('$_backendBaseUrl/api/verify')
        .replace(queryParameters: <String, String>{'hash': hash}).toString();
  }

  Future<void> _initializeCamera() async {
    if (widget.cameras.isEmpty) {
      if (!mounted) return;
      // Mock 模式：无相机时不报错，直接进入模拟器占位界面。
      setState(() {
        _isInitializingCamera = false;
      });
      return;
    }

    final cameraStatus = await Permission.camera.status;
    if (!cameraStatus.isGranted) {
      final requestResult = await Permission.camera.request();
      if (!requestResult.isGranted) {
        if (!mounted) {
          return;
        }
        setState(() {
          _isInitializingCamera = false;
          _errorMessage = requestResult.isPermanentlyDenied
              ? 'Camera permission is permanently denied. Please enable it in system settings.'
              : 'Camera permission is required to take photos.';
        });
        return;
      }
    }

    final selectedCamera = _preferredCamera;
    if (selectedCamera == null) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isInitializingCamera = false;
        _errorMessage = 'No usable camera was found on this device.';
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
      await _cameraController?.dispose();
      setState(() {
        _cameraController = controller;
        _isInitializingCamera = false;
        _errorMessage = null;
      });
    } on CameraException catch (error) {
      await controller.dispose();
      if (!mounted) {
        return;
      }
      setState(() {
        _isInitializingCamera = false;
        _errorMessage =
            'Failed to initialize camera: ${error.description ?? error.code}';
      });
    } on Exception catch (error) {
      await controller.dispose();
      if (!mounted) {
        return;
      }
      setState(() {
        _isInitializingCamera = false;
        _errorMessage = 'Failed to initialize camera: $error';
      });
    }
  }

  /// Mock 模式：生成虚假图片字节 + 固定测试元数据，走完整的哈希 + 上传流程。
  Future<void> _mockCaptureAndUpload() async {
    if (_isBusy) return;

    setState(() {
      _loadingMessage = '模拟拍照并计算哈希...';
      _errorMessage = null;
      _uploadError = null;
      _saveError = null;
      _uploadSucceeded = false;
      _gallerySaved = false;
      _capturedMetadata = null;
      _capturedHash = null;
      _capturedImageFile = null;
    });

    try {
      final timestamp =
          DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
      final mockFile = await _createMockCaptureFile(timestamp);
      final fakeImageBytes = await mockFile.readAsBytes();

      const mockMetadata = <String, dynamic>{
        'latitude': 31.23,
        'longitude': 121.47,
        'accuracy': 10.0,
      };
      final metadata = <String, dynamic>{
        ...mockMetadata,
        'timestamp': timestamp,
      };

      final hash = _cryptoService.calculateSha256(
        imageBytes: fakeImageBytes,
        metadata: metadata,
      );

      if (!mounted) return;

      setState(() {
        _capturedImageFile = mockFile;
        _capturedMetadata = metadata;
        _capturedHash = hash;
        _cloudStamp = null;
        _loadingMessage = '正在同步至云端...';
      });

      await _uploadCurrentStamp();
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Mock capture failed: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingMessage = null;
        });
      }
    }
  }

  Future<File> _createMockCaptureFile(String timestamp) async {
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

    final encoded = img.encodePng(image);
    final directory = await getTemporaryDirectory();
    final file = File(
      '${directory.path}/truth_stamp_mock_$timestamp.png'
          .replaceAll(':', '-')
          .replaceAll(' ', '_'),
    );
    await file.writeAsBytes(encoded, flush: true);
    return file;
  }

  Future<void> _captureAndUpload() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized || _isBusy) {
      return;
    }

    setState(() {
      _loadingMessage = '正在拍照并计算哈希...';
      _errorMessage = null;
      _uploadError = null;
      _saveError = null;
      _uploadSucceeded = false;
      _gallerySaved = false;
      _capturedImageFile = null;
    });

    try {
      final photo = await controller.takePicture();
      final photoFile = File(photo.path);
      final photoBytes = await photoFile.readAsBytes();
      final metadata = await _metadataService.collectMetadata();
      final hash = _cryptoService.calculateSha256(
        imageBytes: photoBytes,
        metadata: metadata,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _capturedImageFile = photoFile;
        _capturedMetadata = metadata;
        _capturedHash = hash;
        _cloudStamp = null;
        _loadingMessage = '正在同步至云端...';
      });

      await _uploadCurrentStamp();
    } on CameraException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage =
            'Failed to capture photo: ${error.description ?? error.code}';
      });
    } on Exception catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = 'Capture failed: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingMessage = null;
        });
      }
    }
  }

  Future<void> _uploadCurrentStamp() async {
    final hash = _capturedHash;
    final metadata = _capturedMetadata;
    if (hash == null || metadata == null) {
      if (!mounted) {
        return;
      }
      setState(() {
        _uploadError = '缺少本地拍照结果，无法上传。';
      });
      return;
    }

    try {
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
        throw Exception(
            _extractUploadError(response.body, response.statusCode));
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _uploadSucceeded = true;
        _uploadError = null;
      });

      final stamp = await _lookupStamp(hash);
      if (mounted && stamp != null) {
        setState(() {
          _cloudStamp = stamp['stamp'] as Map<String, dynamic>?;
        });
      }

      await _protectAndSaveCapturedImage();
    } on TimeoutException {
      if (!mounted) {
        return;
      }
      setState(() {
        _uploadSucceeded = false;
        _uploadError = '上传超时，请检查网络后重试。';
      });
    } on http.ClientException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _uploadSucceeded = false;
        _uploadError = '上传失败：$error';
      });
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _uploadSucceeded = false;
        _uploadError = '上传响应解析失败：$error';
      });
    } on Exception catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _uploadSucceeded = false;
        _uploadError = '上传失败：$error';
      });
    }
  }

  Future<void> _protectAndSaveCapturedImage() async {
    final sourceFile = _capturedImageFile;
    final hash = _capturedHash;
    final metadata = _capturedMetadata;
    if (sourceFile == null || hash == null || metadata == null) {
      if (!mounted) return;
      setState(() {
        _saveError = '缺少本地图片或元数据，无法保存防伪原图。';
      });
      return;
    }

    final verifyUrl = _verificationUrlForHash(hash);
    if (mounted) {
      setState(() {
        _loadingMessage = '正在写入隐形水印并保存相册...';
      });
    }

    try {
      final watermarkedFile = await _watermarkService.embedInvisibleWatermark(
        sourceFile,
        verifyUrl,
      );
      final saved = await _exifService.secureAndSaveImage(
        watermarkedFile,
        hash,
        verifyUrl,
      );

      if (!mounted) return;

      setState(() {
        _gallerySaved = saved;
        _saveError = saved ? null : '双重防伪图片保存失败，请检查相册权限。';
      });

      if (saved) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('防伪原图已自动安全保存至系统相册'),
          ),
        );
      }
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _gallerySaved = false;
        _saveError = '保存防伪原图失败：$error';
      });
    }
  }

  String _extractUploadError(String body, int statusCode) {
    if (body.trim().isEmpty) {
      return 'HTTP $statusCode';
    }

    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic> && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } on FormatException {
      // Fall back to the raw response body below.
    }

    return body;
  }

  Future<void> _retryUpload() async {
    if (_isBusy) {
      return;
    }
    if (_capturedHash == null || _capturedMetadata == null) {
      return;
    }

    setState(() {
      _loadingMessage = '正在同步至云端...';
      _uploadError = null;
      _uploadSucceeded = false;
    });

    try {
      await _uploadCurrentStamp();
    } finally {
      if (mounted) {
        setState(() {
          _loadingMessage = null;
        });
      }
    }
  }

  void _retake() {
    if (_isBusy) {
      return;
    }

    setState(() {
      _capturedImageFile = null;
      _capturedMetadata = null;
      _cloudStamp = null;
      _capturedHash = null;
      _uploadError = null;
      _saveError = null;
      _uploadSucceeded = false;
      _gallerySaved = false;
      _errorMessage = null;
    });
  }

  Future<void> _openSettings() async {
    await openAppSettings();
  }

  Future<void> _importAndVerify() async {
    if (_isBusy) {
      return;
    }

    final picked = await _imagePicker.pickImage(source: ImageSource.gallery);
    if (picked == null) {
      return;
    }

    final importedFile = File(picked.path);
    if (!await importedFile.exists()) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '所选图片不存在，无法继续鉴别。';
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _loadingMessage = '正在本地提取 EXIF 与盲水印...';
      _errorMessage = null;
      _uploadError = null;
      _saveError = null;
    });

    try {
      final exifHash = await _exifService.extractExifHash(importedFile);
      final watermarkPayload =
          await _watermarkService.extractInvisibleWatermark(importedFile);

      final watermarkHash = _extractHashFromWatermarkPayload(watermarkPayload);
      final effectiveHash = exifHash ?? watermarkHash;
      if (effectiveHash == null) {
        throw StateError('未在图片中提取到可验证的 EXIF 哈希或盲水印。');
      }

      if (exifHash != null &&
          watermarkHash != null &&
          exifHash != watermarkHash) {
        throw StateError('EXIF 哈希与盲水印哈希不一致，图片可能被篡改。');
      }

      final lookup = await _lookupStamp(effectiveHash);
      if (!mounted) return;

      if (lookup == null) {
        setState(() {
          _loadingMessage = null;
          _errorMessage = '云端未找到对应记录。';
        });
        return;
      }

      final stamp = lookup['stamp'] as Map<String, dynamic>;
      final verifyUrl = _verificationUrlForHash(effectiveHash);
      setState(() {
        _loadingMessage = null;
      });

      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => VerificationDetailScreen(
            hash: stamp['hash']?.toString() ?? effectiveHash,
            timestamp: stamp['timestamp']?.toString() ?? '-',
            latitude: stamp['latitude']?.toString() ?? '-',
            longitude: stamp['longitude']?.toString() ?? '-',
            accuracy: stamp['accuracy']?.toString() ?? '-',
            createdAt: stamp['created_at']?.toString() ?? '-',
            verifyUrl: verifyUrl,
          ),
        ),
      );
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingMessage = null;
        _errorMessage = '导入鉴别失败：$error';
      });
    }
  }

  String? _extractHashFromWatermarkPayload(String? payload) {
    if (payload == null || payload.isEmpty) {
      return null;
    }

    final uri = Uri.tryParse(payload);
    final hashFromUrl = uri?.queryParameters['hash'];
    if (hashFromUrl != null && hashFromUrl.isNotEmpty) {
      return hashFromUrl;
    }

    return payload.trim();
  }

  Future<Map<String, dynamic>?> _lookupStamp(String hash) async {
    final response = await _httpClient
        .get(
          Uri.parse('$_backendBaseUrl/api/lookup')
              .replace(queryParameters: <String, String>{'hash': hash}),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode == 404) {
      return null;
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_extractUploadError(response.body, response.statusCode));
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic> || decoded['found'] != true) {
      return null;
    }

    final stamp = decoded['stamp'];
    if (stamp is! Map<String, dynamic>) {
      return null;
    }

    return <String, dynamic>{'stamp': stamp};
  }

  Future<void> _openCurrentVerificationDetail() async {
    final metadata = _capturedMetadata;
    final hash = _capturedHash;
    final cloudStamp = _cloudStamp;
    if (metadata == null || hash == null) {
      return;
    }

    final verifyUrl = _verificationUrlForHash(hash);
    final createdAt = cloudStamp?['created_at']?.toString() ??
        DateTime.now().toIso8601String();
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VerificationDetailScreen(
          hash: hash,
          timestamp: metadata['timestamp']?.toString() ?? '-',
          latitude: metadata['latitude']?.toString() ?? '-',
          longitude: metadata['longitude']?.toString() ?? '-',
          accuracy: metadata['accuracy']?.toString() ?? '-',
          createdAt: createdAt,
          verifyUrl: verifyUrl,
        ),
      ),
    );
  }

  String _formatNumber(double value) => value.toStringAsFixed(6);

  Widget _buildPreview() {
    if (_capturedImageFile != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Image.file(
          _capturedImageFile!,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
        ),
      );
    }

    if (_isMockMode) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: _buildMockPlaceholder(label: '模拟器模式 · 无实体相机'),
      );
    }

    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: CameraPreview(controller),
    );
  }

  Widget _buildMockPlaceholder({required String label}) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: const Color(0xFF2A2A2A),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.camera_alt_outlined,
            size: 56,
            color: Colors.white.withOpacity(0.35),
          ),
          const SizedBox(height: 14),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withOpacity(0.55),
              fontSize: 14,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusCard() {
    final isSaveError = _saveError != null;
    final message = _saveError ?? _uploadError;
    if (message == null) {
      return const SizedBox.shrink();
    }

    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isSaveError ? '本地保存失败' : '云端同步失败',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: _retryUpload,
              child: const Text('重试上传'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetadataCard() {
    final metadata = _capturedMetadata;
    if (_capturedHash == null || metadata == null) {
      return Card(
        elevation: 0,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: const Padding(
          padding: EdgeInsets.all(20),
          child: Text('拍照后，这里会展示 SHA-256、时间和位置信息。'),
        ),
      );
    }

    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _gallerySaved
                      ? Icons.verified_rounded
                      : Icons.hourglass_bottom_rounded,
                  color: _gallerySaved
                      ? Colors.green
                      : Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  _gallerySaved
                      ? '已同步并保存至相册'
                      : (_uploadSucceeded ? '云端已同步，正在保存至相册' : '本地时空指纹'),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildInfoRow('SHA-256', _capturedHash!),
            const SizedBox(height: 12),
            _buildInfoRow('时间', metadata['timestamp']?.toString() ?? '-'),
            const SizedBox(height: 12),
            _buildInfoRow(
              '经纬度',
              '${_formatNumber((metadata['latitude'] as num).toDouble())}, '
                  '${_formatNumber((metadata['longitude'] as num).toDouble())}',
            ),
            const SizedBox(height: 12),
            _buildInfoRow(
              '定位精度',
              '${(metadata['accuracy'] as num).toDouble().toStringAsFixed(1)} m',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQrCard() {
    if (!_uploadSucceeded || _capturedHash == null) {
      return const SizedBox.shrink();
    }

    final verificationUrl = _verificationUrlForHash(_capturedHash!);

    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '防伪二维码',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 12),
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
                  data: verificationUrl,
                  version: QrVersions.auto,
                  size: 220,
                  backgroundColor: Colors.white,
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
            const SizedBox(height: 12),
            Text(
              '扫码后即可进入云端验证页。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 14),
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
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
                onPressed:
                    _gallerySaved ? _openCurrentVerificationDetail : null,
                child: const Text(
                  '查看鉴别详情',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 6),
        SelectableText(
          value,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    );
  }

  Widget _buildActions() {
    final importButton = FilledButton.tonalIcon(
      onPressed: _isBusy ? null : _importAndVerify,
      icon: const Icon(Icons.photo_library_outlined),
      label: const Text('导入鉴别'),
    );

    // ── Mock 模式（模拟器，无相机）──────────────────────────
    if (_isMockMode) {
      if (_capturedHash == null) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            importButton,
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _isBusy ? null : _mockCaptureAndUpload,
              icon: const Icon(Icons.science_outlined),
              label: const Text('模拟拍照并上传 (Mock)'),
            ),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          importButton,
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _isBusy ? null : _mockCaptureAndUpload,
                  icon: const Icon(Icons.science_outlined),
                  label: const Text('重新模拟'),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: _isBusy ? null : _retake,
                child: const Text('重置'),
              ),
            ],
          ),
        ],
      );
    }

    // ── 正常相机模式 ─────────────────────────────────────
    if (_capturedHash == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          importButton,
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _isBusy ? null : _captureAndUpload,
            icon: const Icon(Icons.camera_alt),
            label: const Text('拍照并上传'),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        importButton,
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _isBusy ? null : _captureAndUpload,
                icon: const Icon(Icons.upload_rounded),
                label: const Text('重试上传'),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton(
              onPressed: _isBusy ? null : _retake,
              child: const Text('重拍'),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Truth Stamp'),
      ),
      body: SafeArea(
        child: Stack(
          children: [
            SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_errorMessage != null) ...[
                    Card(
                      color: theme.colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '错误',
                              style: theme.textTheme.titleSmall?.copyWith(
                                color: theme.colorScheme.onErrorContainer,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _errorMessage!,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onErrorContainer,
                              ),
                            ),
                            if (_errorMessage!.contains('permission')) ...[
                              const SizedBox(height: 12),
                              FilledButton.tonal(
                                onPressed: _openSettings,
                                child: const Text('打开系统设置'),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  AspectRatio(
                    aspectRatio: 3 / 4,
                    child: Container(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: _isInitializingCamera
                          ? const Center(child: CircularProgressIndicator())
                          : _buildPreview(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildStatusCard(),
                  if (_uploadError != null) const SizedBox(height: 16),
                  _buildMetadataCard(),
                  const SizedBox(height: 16),
                  _buildQrCard(),
                  if (_capturedHash != null) const SizedBox(height: 16),
                  _buildActions(),
                ],
              ),
            ),
            if (_loadingMessage != null)
              Container(
                color: Colors.black45,
                child: Center(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 18),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          ),
                          const SizedBox(width: 16),
                          Text(_loadingMessage!),
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
