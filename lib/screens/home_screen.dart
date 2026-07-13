import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/crypto_service.dart';
import '../services/metadata_service.dart';

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
  static const String _backendBaseUrl = 'https://your-vercel-domain.vercel.app';

  final MetadataService _metadataService = const MetadataService();
  final CryptoService _cryptoService = const CryptoService();
  final http.Client _httpClient = http.Client();

  CameraController? _cameraController;
  bool _isInitializingCamera = true;
  String? _loadingMessage;
  String? _errorMessage;
  String? _uploadError;

  Uint8List? _capturedImageBytes;
  Map<String, dynamic>? _capturedMetadata;
  String? _capturedHash;
  bool _uploadSucceeded = false;

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

  String _verificationUrlForHash(String hash) {
    return Uri.parse('$_backendBaseUrl/api/verify')
        .replace(queryParameters: <String, String>{'hash': hash})
        .toString();
  }

  Future<void> _initializeCamera() async {
    if (widget.cameras.isEmpty) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isInitializingCamera = false;
        _errorMessage = 'No camera was found on this device.';
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
        _errorMessage = 'Failed to initialize camera: ${error.description ?? error.code}';
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

  Future<void> _captureAndUpload() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized || _isBusy) {
      return;
    }

    setState(() {
      _loadingMessage = '正在拍照并计算哈希...';
      _errorMessage = null;
      _uploadError = null;
      _uploadSucceeded = false;
    });

    try {
      final photo = await controller.takePicture();
      final photoBytes = await photo.readAsBytes();
      final metadata = await _metadataService.collectMetadata();
      final hash = _cryptoService.calculateSha256(
        imageBytes: photoBytes,
        metadata: metadata,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _capturedImageBytes = photoBytes;
        _capturedMetadata = metadata;
        _capturedHash = hash;
        _loadingMessage = '正在同步至云端...';
      });

      await _uploadCurrentStamp();
    } on CameraException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = 'Failed to capture photo: ${error.description ?? error.code}';
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
        throw Exception(_extractUploadError(response.body, response.statusCode));
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _uploadSucceeded = true;
        _uploadError = null;
      });
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
      _capturedImageBytes = null;
      _capturedMetadata = null;
      _capturedHash = null;
      _uploadError = null;
      _uploadSucceeded = false;
      _errorMessage = null;
    });
  }

  Future<void> _openSettings() async {
    await openAppSettings();
  }

  String _formatNumber(double value) => value.toStringAsFixed(6);

  Widget _buildPreview() {
    if (_capturedImageBytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Image.memory(
          _capturedImageBytes!,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
        ),
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

  Widget _buildStatusCard() {
    if (_uploadError == null) {
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
              '云端同步失败',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              _uploadError!,
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
                  _uploadSucceeded ? Icons.verified_rounded : Icons.hourglass_bottom_rounded,
                  color: _uploadSucceeded ? Colors.green : Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  _uploadSucceeded ? '已同步至云端' : '本地时空指纹',
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
              '其他人扫码后将打开云端存证校验页。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            SelectableText(
              verificationUrl,
              style: Theme.of(context).textTheme.bodySmall,
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
    if (_capturedHash == null) {
      return FilledButton.icon(
        onPressed: _isBusy ? null : _captureAndUpload,
        icon: const Icon(Icons.camera_alt),
        label: const Text('拍照并上传'),
      );
    }

    return Row(
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
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
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
