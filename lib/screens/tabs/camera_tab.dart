import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../services/crypto_service.dart';
import '../../services/exif_service.dart';
import '../../services/metadata_service.dart';
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

enum _FlashChoice { auto, on, off }

enum _TimerChoice { off, threeSeconds, tenSeconds }

enum _AspectChoice { fourThree, sixteenNine, oneOne }

extension on _AspectChoice {
  double get value {
    switch (this) {
      case _AspectChoice.fourThree:
        return 4 / 3;
      case _AspectChoice.sixteenNine:
        return 16 / 9;
      case _AspectChoice.oneOne:
        return 1;
    }
  }

  String get label {
    switch (this) {
      case _AspectChoice.fourThree:
        return '4:3';
      case _AspectChoice.sixteenNine:
        return '16:9';
      case _AspectChoice.oneOne:
        return '1:1';
    }
  }
}

class _CameraTabState extends State<CameraTab> {
  static const String _backendBaseUrl = 'https://truth-stamp.vercel.app';

  final MetadataService _metadataService = const MetadataService();
  final CryptoService _cryptoService = const CryptoService();
  final WatermarkService _watermarkService = const WatermarkService();
  final ExifService _exifService = const ExifService();
  final http.Client _httpClient = http.Client();

  CameraController? _cameraController;
  int _currentCameraIndex = 0;

  bool _isBusy = false;
  bool _isCountingDown = false;
  String? _errorMessage;
  String? _loadingMessage;

  _FlashChoice _flashChoice = _FlashChoice.auto;
  _TimerChoice _timerChoice = _TimerChoice.off;
  _AspectChoice _aspectChoice = _AspectChoice.fourThree;

  double _zoomLevel = 1.0;
  double _minZoomLevel = 1.0;
  double _maxZoomLevel = 1.0;
  double _scaleBaseZoom = 1.0;

  double _exposureOffset = 0.0;
  double _minExposureOffset = -2.0;
  double _maxExposureOffset = 2.0;
  double _dragStartExposure = 0.0;

  Offset? _focusPoint;
  double _focusOpacity = 0.0;
  Timer? _focusFadeTimer;
  Timer? _countdownTimer;
  int? _countdownRemaining;
  bool _shutterFlashVisible = false;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  @override
  void didUpdateWidget(covariant CameraTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.cameras, widget.cameras)) {
      _initializeCamera();
    }
  }

  @override
  void dispose() {
    _focusFadeTimer?.cancel();
    _countdownTimer?.cancel();
    _httpClient.close();
    _cameraController?.dispose();
    super.dispose();
  }

  bool get _isMockMode => widget.cameras.isEmpty;

  CameraDescription? get _selectedCamera {
    if (widget.cameras.isEmpty) return null;
    if (_currentCameraIndex < widget.cameras.length) {
      return widget.cameras[_currentCameraIndex];
    }
    return widget.cameras.first;
  }

  double get _captureAspectRatio => _aspectChoice.value;

  String _verificationUrlForHash(String hash) {
    return Uri.parse('$_backendBaseUrl/api/verify')
        .replace(queryParameters: <String, String>{'hash': hash})
        .toString();
  }

  Future<void> _initializeCamera() async {
    if (widget.cameras.isEmpty) {
      if (!mounted) return;
      setState(() {
        _errorMessage = null;
      });
      return;
    }

    final permission = await Permission.camera.status;
    if (!permission.isGranted) {
      final result = await Permission.camera.request();
      if (!result.isGranted) {
        if (!mounted) return;
        setState(() {
          _errorMessage = result.isPermanentlyDenied
              ? 'Camera permission is permanently denied. Please enable it in Settings.'
              : 'Camera permission is required to use the camera.';
        });
        return;
      }
    }

    final selectedCamera = _selectedCamera;
    if (selectedCamera == null) {
      if (!mounted) return;
      setState(() {
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
      await _applyControllerCapabilities(controller);

      if (!mounted) {
        await controller.dispose();
        return;
      }

      await _cameraController?.dispose();
      setState(() {
        _cameraController = controller;
        _errorMessage = null;
      });

      await _safeSetFlashMode(_flashChoice);
    } on CameraException catch (error) {
      await controller.dispose();
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'Failed to initialize camera: ${error.description ?? error.code}';
      });
    } on Exception catch (error) {
      await controller.dispose();
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Failed to initialize camera: $error';
      });
    }
  }

  Future<void> _applyControllerCapabilities(CameraController controller) async {
    try {
      _minZoomLevel = await controller.getMinZoomLevel();
    } on Exception {
      _minZoomLevel = 1.0;
    }

    try {
      _maxZoomLevel = await controller.getMaxZoomLevel();
    } on Exception {
      _maxZoomLevel = math.max(_minZoomLevel, 1.0);
    }

    try {
      _minExposureOffset = await controller.getMinExposureOffset();
    } on Exception {
      _minExposureOffset = -2.0;
    }

    try {
      _maxExposureOffset = await controller.getMaxExposureOffset();
    } on Exception {
      _maxExposureOffset = 2.0;
    }

    _zoomLevel = _zoomLevel.clamp(_minZoomLevel, _maxZoomLevel);
    _exposureOffset = _exposureOffset.clamp(_minExposureOffset, _maxExposureOffset);

    try {
      await controller.setZoomLevel(_zoomLevel);
    } on Exception {
      // Ignore unsupported zoom control.
    }

    try {
      await controller.setExposureOffset(_exposureOffset);
    } on Exception {
      // Ignore unsupported exposure control.
    }
  }

  Future<void> _safeSetFlashMode(_FlashChoice choice) async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;

    try {
      final mode = switch (choice) {
        _FlashChoice.auto => FlashMode.auto,
        _FlashChoice.on => FlashMode.always,
        _FlashChoice.off => FlashMode.off,
      };
      await controller.setFlashMode(mode);
      if (!mounted) return;
      setState(() => _flashChoice = choice);
    } on CameraException catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'Flash mode is unavailable: ${error.description ?? error.code}';
      });
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Flash mode is unavailable: $error';
      });
    }
  }

  Future<void> _safeSetZoomLevel(double target) async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;

    final clamped = target.clamp(_minZoomLevel, _maxZoomLevel);
    if ((clamped - _zoomLevel).abs() < 0.01) return;

    try {
      await controller.setZoomLevel(clamped);
      if (!mounted) return;
      setState(() => _zoomLevel = clamped);
    } on CameraException catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'Zoom control is unavailable: ${error.description ?? error.code}';
      });
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Zoom control is unavailable: $error';
      });
    }
  }

  Future<void> _setZoomPreset(double preset) async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;

    final clamped = preset.clamp(_minZoomLevel, _maxZoomLevel);
    final start = _zoomLevel;
    const steps = 8;
    for (var i = 1; i <= steps; i++) {
      final next = start + (clamped - start) * (i / steps);
      await _safeSetZoomLevel(next);
      await Future<void>.delayed(const Duration(milliseconds: 18));
    }
  }

  Future<void> _safeSetExposureOffset(double target) async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;

    final clamped = target.clamp(_minExposureOffset, _maxExposureOffset);
    if ((clamped - _exposureOffset).abs() < 0.01) return;

    try {
      await controller.setExposureOffset(clamped);
      if (!mounted) return;
      setState(() => _exposureOffset = clamped);
    } on CameraException catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'Exposure control is unavailable: ${error.description ?? error.code}';
      });
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Exposure control is unavailable: $error';
      });
    }
  }

  Future<void> _safeSetFocusAndExposurePoint(Offset normalizedPoint) async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;

    try {
      await controller.setFocusPoint(normalizedPoint);
    } on CameraException catch (error) {
      if (mounted) {
        setState(() {
          _errorMessage =
              'Focus control is unavailable: ${error.description ?? error.code}';
        });
      }
    } on Exception catch (error) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Focus control is unavailable: $error';
        });
      }
    }

    try {
      await controller.setExposurePoint(normalizedPoint);
    } on CameraException catch (_) {
      // Some devices only support focus point.
    } on Exception {
      // Some devices only support focus point.
    }
  }

  Future<void> _switchCamera() async {
    if (_isBusy || _isCountingDown || widget.cameras.length < 2) return;

    final current = _selectedCamera;
    if (current == null) return;

    final nextIndex = widget.cameras.indexWhere(
      (camera) => camera.lensDirection != current.lensDirection,
    );
    if (nextIndex == -1) return;

    setState(() {
      _currentCameraIndex = nextIndex;
    });
    await _cameraController?.dispose();
    _cameraController = null;
    await _initializeCamera();
  }

  void _showFocusIndicator(Offset point) {
    _focusFadeTimer?.cancel();
    setState(() {
      _focusPoint = point;
      _focusOpacity = 1.0;
    });
    _focusFadeTimer = Timer(const Duration(milliseconds: 850), () {
      if (!mounted) return;
      setState(() => _focusOpacity = 0.15);
    });
  }

  void _handleTapToFocus(
    TapDownDetails details,
    BoxConstraints constraints,
  ) {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized || _isBusy) {
      return;
    }

    final local = details.localPosition;
    final normalized = Offset(
      (local.dx / constraints.maxWidth).clamp(0.0, 1.0),
      (local.dy / constraints.maxHeight).clamp(0.0, 1.0),
    );

    _showFocusIndicator(local);
    _dragStartExposure = _exposureOffset;
    unawaited(_safeSetFocusAndExposurePoint(normalized));
  }

  void _handleScaleStart(ScaleStartDetails details) {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    _scaleBaseZoom = _zoomLevel;
  }

  void _handleScaleUpdate(ScaleUpdateDetails details) {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    if (details.scale == 1.0) return;
    unawaited(_safeSetZoomLevel(_scaleBaseZoom * details.scale));
  }

  void _handleFocusExposureDrag(DragUpdateDetails details) {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    final delta = -details.primaryDelta!;
    final range = _maxExposureOffset - _minExposureOffset;
    final next = _dragStartExposure + (delta * range / 240.0);
    unawaited(_safeSetExposureOffset(next));
  }

  Future<void> _handleCapturePressed() async {
    if (_isBusy || _isCountingDown) return;
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }

    final delaySeconds = switch (_timerChoice) {
      _TimerChoice.off => 0,
      _TimerChoice.threeSeconds => 3,
      _TimerChoice.tenSeconds => 10,
    };

    if (delaySeconds <= 0) {
      await _capturePipeline();
      return;
    }

    await _startCountdown(delaySeconds);
  }

  Future<void> _startCountdown(int seconds) async {
    final completer = Completer<void>();
    int remaining = seconds;

    setState(() {
      _isCountingDown = true;
      _countdownRemaining = remaining;
      _loadingMessage = null;
    });

    await HapticFeedback.lightImpact();
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted) {
        timer.cancel();
        if (!completer.isCompleted) completer.complete();
        return;
      }

      remaining -= 1;
      if (remaining > 0) {
        setState(() => _countdownRemaining = remaining);
        await HapticFeedback.selectionClick();
        return;
      }

      timer.cancel();
      setState(() {
        _countdownRemaining = null;
        _isCountingDown = false;
      });
      await HapticFeedback.mediumImpact();
      await _capturePipeline();
      if (!completer.isCompleted) completer.complete();
    });

    await completer.future;
  }

  Future<void> _capturePipeline() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized || _isBusy) {
      return;
    }

    setState(() {
      _isBusy = true;
      _errorMessage = null;
      _loadingMessage = '正在拍照并同步...';
      _shutterFlashVisible = true;
    });

    try {
      await Future<void>.delayed(const Duration(milliseconds: 70));
      final shot = await controller.takePicture();
      final photoFile = File(shot.path);
      final croppedFile = await _cropPhotoToSelectedAspect(photoFile);
      final photoBytes = await croppedFile.readAsBytes();
      final metadata = await _metadataService.collectMetadata();
      final normalizedMetadata = <String, dynamic>{
        ...metadata,
        'timestamp': metadata['timestamp']?.toString() ??
            DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now()),
      };
      final hash = _cryptoService.calculateSha256(
        imageBytes: photoBytes,
        metadata: normalizedMetadata,
      );

      if (!mounted) return;
      setState(() => _loadingMessage = '正在同步至云端...');

      await _uploadStamp(hash, normalizedMetadata);
      await _protectAndSaveCapturedImage(croppedFile, hash);
      await _persistToHistory(croppedFile, hash, normalizedMetadata);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('拍照完成，已同步并保存到历史记录')),
        );
      }
    } on CameraException catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'Failed to capture photo: ${error.description ?? error.code}';
      });
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Capture failed: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
          _shutterFlashVisible = false;
          _loadingMessage = null;
        });
      }
    }
  }

  Future<File> _cropPhotoToSelectedAspect(File sourceFile) async {
    final bytes = await sourceFile.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return sourceFile;

    final targetAspect = _captureAspectRatio;
    final currentAspect = decoded.width / decoded.height;
    if ((currentAspect - targetAspect).abs() < 0.01) {
      return sourceFile;
    }

    int cropX = 0;
    int cropY = 0;
    int cropWidth = decoded.width;
    int cropHeight = decoded.height;

    if (currentAspect > targetAspect) {
      cropWidth = (decoded.height * targetAspect).round();
      cropX = ((decoded.width - cropWidth) / 2).round();
    } else {
      cropHeight = (decoded.width / targetAspect).round();
      cropY = ((decoded.height - cropHeight) / 2).round();
    }

    cropWidth = cropWidth.clamp(1, decoded.width);
    cropHeight = cropHeight.clamp(1, decoded.height);
    cropX = cropX.clamp(0, decoded.width - cropWidth);
    cropY = cropY.clamp(0, decoded.height - cropHeight);

    final cropped = img.copyCrop(
      decoded,
      x: cropX,
      y: cropY,
      width: cropWidth,
      height: cropHeight,
    );

    final outputDirectory = await getTemporaryDirectory();
    final outputFile = File(
      '${outputDirectory.path}/truth_stamp_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );
    await outputFile.writeAsBytes(img.encodeJpg(cropped, quality: 95), flush: true);
    return outputFile;
  }

  Future<void> _uploadStamp(
    String hash,
    Map<String, dynamic> metadata,
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
          }),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(_extractUploadError(response.body, response.statusCode));
    }
  }

  Future<void> _protectAndSaveCapturedImage(
    File sourceFile,
    String hash,
  ) async {
    final verifyUrl = _verificationUrlForHash(hash);
    if (mounted) {
      setState(() => _loadingMessage = '正在写入隐形水印并保存相册...');
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

      if (!saved) {
        throw StateError('双重防伪图片保存失败，请检查相册权限。');
      }
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = '保存防伪原图失败：$error');
    }
  }

  Future<void> _persistToHistory(
    File sourceFile,
    String hash,
    Map<String, dynamic> metadata,
  ) async {
    try {
      await widget.historyService.upsertRecord(
        sourceImage: sourceFile,
        hash: hash,
        timestamp: metadata['timestamp']?.toString() ?? '-',
        latitude: metadata['latitude']?.toString() ?? '-',
        longitude: metadata['longitude']?.toString() ?? '-',
        accuracy: metadata['accuracy']?.toString() ?? '-',
        createdAt: DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now()),
        verifyUrl: _verificationUrlForHash(hash),
      );
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = '历史记录写入失败：$error');
    }
  }

  String _extractUploadError(String body, int statusCode) {
    if (body.trim().isEmpty) return 'HTTP $statusCode';

    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic> && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } on FormatException {
      // Fall through to raw body.
    }

    return body;
  }

  Future<T?> _showGlassSelectionMenu<T>({
    required BuildContext context,
    required String title,
    required List<_MenuEntry<T>> entries,
    required T selected,
  }) {
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: title,
      barrierColor: Colors.black.withOpacity(0.08),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return SafeArea(
          child: Stack(
            children: [
              Positioned(
                right: 16,
                top: 86,
                child: Material(
                  color: Colors.transparent,
                  child: _GlassSelectionCard<T>(
                    title: title,
                    entries: entries,
                    selected: selected,
                    onSelected: (value) => Navigator.of(dialogContext).pop(value),
                  ),
                ),
              ),
            ],
          ),
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.94, end: 1.0).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  Future<void> _openFlashMenu() async {
    final choice = await _showGlassSelectionMenu<_FlashChoice>(
      context: context,
      title: '闪光灯',
      entries: <_MenuEntry<_FlashChoice>>[
        const _MenuEntry(
          value: _FlashChoice.auto,
          icon: CupertinoIcons.bolt_circle_fill,
          title: '自动',
          subtitle: 'Auto',
        ),
        const _MenuEntry(
          value: _FlashChoice.on,
          icon: CupertinoIcons.bolt_fill,
          title: '常开',
          subtitle: 'Always / On',
        ),
        const _MenuEntry(
          value: _FlashChoice.off,
          icon: CupertinoIcons.bolt_slash_fill,
          title: '关闭',
          subtitle: 'Off',
        ),
      ],
      selected: _flashChoice,
    );
    if (choice != null) {
      await _safeSetFlashMode(choice);
    }
  }

  Future<void> _openTimerMenu() async {
    final choice = await _showGlassSelectionMenu<_TimerChoice>(
      context: context,
      title: '延时拍照',
      entries: <_MenuEntry<_TimerChoice>>[
        const _MenuEntry(
          value: _TimerChoice.off,
          icon: CupertinoIcons.clear_circled,
          title: '关闭',
          subtitle: 'Off',
        ),
        const _MenuEntry(
          value: _TimerChoice.threeSeconds,
          icon: CupertinoIcons.timer,
          title: '3 秒',
          subtitle: '3 seconds',
        ),
        const _MenuEntry(
          value: _TimerChoice.tenSeconds,
          icon: CupertinoIcons.timer,
          title: '10 秒',
          subtitle: '10 seconds',
        ),
      ],
      selected: _timerChoice,
    );
    if (choice != null && mounted) {
      setState(() => _timerChoice = choice);
    }
  }

  Future<void> _openAspectMenu() async {
    final choice = await _showGlassSelectionMenu<_AspectChoice>(
      context: context,
      title: '比例切换',
      entries: <_MenuEntry<_AspectChoice>>[
        const _MenuEntry(
          value: _AspectChoice.fourThree,
          icon: CupertinoIcons.crop,
          title: '4:3',
          subtitle: 'Classic',
        ),
        const _MenuEntry(
          value: _AspectChoice.sixteenNine,
          icon: CupertinoIcons.rectangle,
          title: '16:9',
          subtitle: 'Wide',
        ),
        const _MenuEntry(
          value: _AspectChoice.oneOne,
          icon: CupertinoIcons.square,
          title: '1:1',
          subtitle: 'Square',
        ),
      ],
      selected: _aspectChoice,
    );
    if (choice != null && mounted) {
      setState(() => _aspectChoice = choice);
    }
  }

  String _flashLabel(_FlashChoice choice) {
    return switch (choice) {
      _FlashChoice.auto => 'Auto',
      _FlashChoice.on => 'On',
      _FlashChoice.off => 'Off',
    };
  }

  String _timerLabel(_TimerChoice choice) {
    return switch (choice) {
      _TimerChoice.off => 'Off',
      _TimerChoice.threeSeconds => '3s',
      _TimerChoice.tenSeconds => '10s',
    };
  }

  bool get _cameraReady =>
      _cameraController != null && _cameraController!.value.isInitialized;

  @override
  Widget build(BuildContext context) {
    final cameraReady = _cameraReady;

    return Scaffold(
      backgroundColor: const Color(0xFF050507),
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: _buildPreviewStage(cameraReady),
              ),
            ),
            const SizedBox(height: 14),
            _buildZoomRow(),
            const SizedBox(height: 14),
            _buildBottomControls(),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Row(
        children: [
          _GlassIconButton(
            icon: CupertinoIcons.bolt_fill,
            label: _flashLabel(_flashChoice),
            onTap: _isCountingDown || _isBusy ? null : _openFlashMenu,
          ),
          const SizedBox(width: 10),
          _GlassIconButton(
            icon: CupertinoIcons.timer,
            label: _timerLabel(_timerChoice),
            onTap: _isCountingDown || _isBusy ? null : _openTimerMenu,
          ),
          const SizedBox(width: 10),
          _GlassIconButton(
            icon: CupertinoIcons.crop,
            label: _aspectChoice.label,
            onTap: _isCountingDown || _isBusy ? null : _openAspectMenu,
          ),
          const Spacer(),
          _GlassIconButton(
            icon: CupertinoIcons.camera_rotate_fill,
            label: widget.cameras.length > 1 ? '切换' : '单摄',
            onTap: _isCountingDown || _isBusy ? null : _switchCamera,
            enabled: widget.cameras.length > 1,
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewStage(bool cameraReady) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      transitionBuilder: (child, animation) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(scale: Tween<double>(begin: 0.98, end: 1).animate(curved), child: child),
        );
      },
      child: cameraReady || _isMockMode
          ? _buildCameraSurface(key: ValueKey<String>('surface-${_aspectChoice.name}-$_currentCameraIndex'))
          : _buildLoadingSurface(key: const ValueKey<String>('loading-surface')),
    );
  }

  Widget _buildLoadingSurface({required Key key}) {
    return Container(
      key: key,
      decoration: BoxDecoration(
        color: const Color(0xFF111113),
        borderRadius: BorderRadius.circular(34),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Colors.white),
            const SizedBox(height: 14),
            Text(
              _errorMessage ?? '正在加载相机...',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withOpacity(0.85),
                fontSize: 14,
                height: 1.35,
              ),
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 16),
              TextButton(
                onPressed: _initializeCamera,
                child: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCameraSurface({required Key key}) {
    return LayoutBuilder(
      key: key,
      builder: (context, constraints) {
        final aspect = _captureAspectRatio;
        final focusPoint = _focusPoint;

        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFF111113),
            borderRadius: BorderRadius.circular(34),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x4D000000),
                blurRadius: 26,
                offset: Offset(0, 14),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(34),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Center(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 260),
                    child: AspectRatio(
                      key: ValueKey<double>(aspect),
                      aspectRatio: aspect,
                      child: LayoutBuilder(
                        builder: (context, innerConstraints) {
                          final previewSize = Size(
                            innerConstraints.maxWidth,
                            innerConstraints.maxHeight,
                          );
                          return Stack(
                            fit: StackFit.expand,
                            children: [
                              if (_isMockMode)
                                _buildMockPreview()
                              else
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTapDown: (details) =>
                                      _handleTapToFocus(details, innerConstraints),
                                  onScaleStart: _handleScaleStart,
                                  onScaleUpdate: _handleScaleUpdate,
                                  child: CameraPreview(_cameraController!),
                                ),
                              IgnorePointer(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: <Color>[
                                        Colors.black.withOpacity(0.30),
                                        Colors.transparent,
                                        Colors.transparent,
                                        Colors.black.withOpacity(0.34),
                                      ],
                                      stops: const [0.0, 0.16, 0.72, 1.0],
                                    ),
                                  ),
                                ),
                              ),
                              if (_shutterFlashVisible)
                                IgnorePointer(
                                  child: AnimatedOpacity(
                                    opacity: 0.90,
                                    duration: const Duration(milliseconds: 90),
                                    child: Container(color: Colors.white),
                                  ),
                                ),
                              if (focusPoint != null)
                                _buildFocusOverlay(previewSize, focusPoint),
                              if (_countdownRemaining != null) _buildCountdownOverlay(),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
                if (_errorMessage != null)
                  Positioned(
                    left: 14,
                    right: 14,
                    top: 14,
                    child: _InlineNotice(message: _errorMessage!),
                  ),
                if (_loadingMessage != null)
                  Positioned(
                    left: 14,
                    right: 14,
                    bottom: 14,
                    child: _InlineNotice(message: _loadingMessage!),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildMockPreview() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: null,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[Color(0xFF1D2B53), Color(0xFF0F172A), Color(0xFF111827)],
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Text(
                  'Mock Mode',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.72),
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
            ),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    CupertinoIcons.camera_fill,
                    color: Colors.white.withOpacity(0.92),
                    size: 68,
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'No camera detected',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.9),
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Preview and controls stay available for simulator fallback.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.68),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFocusOverlay(Size previewSize, Offset focusPoint) {
    const boxSize = 66.0;
    const exposureWidth = 38.0;
    const exposureHeight = 150.0;

    final x = (focusPoint.dx - boxSize / 2).clamp(10.0, previewSize.width - boxSize - 10.0);
    final y = (focusPoint.dy - boxSize / 2 - 28).clamp(10.0, previewSize.height - exposureHeight - 18.0);

    return Positioned(
      left: x,
      top: y,
      child: AnimatedOpacity(
        opacity: _focusOpacity,
        duration: const Duration(milliseconds: 220),
        child: GestureDetector(
          onVerticalDragStart: (_) {
            _dragStartExposure = _exposureOffset;
          },
          onVerticalDragUpdate: _handleFocusExposureDrag,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: boxSize,
                height: boxSize,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFFFFD84D), width: 2.2),
                  color: const Color(0x22FFD84D),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0x66FFD84D).withOpacity(0.35),
                      blurRadius: 18,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: Center(
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFFFFD84D), width: 2),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Container(
                width: exposureWidth,
                height: exposureHeight,
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color: Colors.black.withOpacity(0.22),
                  border: Border.all(color: Colors.white.withOpacity(0.14)),
                ),
                child: Column(
                  children: [
                    const Icon(CupertinoIcons.sun_max_fill, color: Colors.white, size: 14),
                    const SizedBox(height: 8),
                    Expanded(
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: LinearProgressIndicator(
                          value: (_exposureOffset - _minExposureOffset) /
                              math.max(0.01, _maxExposureOffset - _minExposureOffset),
                          backgroundColor: Colors.white.withOpacity(0.12),
                          valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFFFD84D)),
                          minHeight: 4,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'EV ${_exposureOffset.toStringAsFixed(1)}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCountdownOverlay() {
    return Positioned.fill(
      child: IgnorePointer(
        child: Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(38),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: Container(
                width: 170,
                height: 170,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(38),
                  border: Border.all(color: Colors.white.withOpacity(0.22)),
                ),
                child: Center(
                  child: AnimatedScale(
                    scale: 1.0,
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOutBack,
                    child: Text(
                      '${_countdownRemaining!}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 86,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -5,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildZoomRow() {
    final presets = <double>[0.5, 1.0, 2.0];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final preset in presets) ...[
            _ZoomPresetButton(
              label: preset == 1.0 ? '1x' : '${preset.toStringAsFixed(1)}x',
              selected: (_zoomLevel - preset).abs() < 0.18,
              onTap: _isBusy || _isCountingDown || !_cameraReady
                  ? null
                  : () => _setZoomPreset(preset),
            ),
            if (preset != presets.last) const SizedBox(width: 12),
          ],
        ],
      ),
    );
  }

  Widget _buildBottomControls() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Zoom ${_zoomLevel.toStringAsFixed(1)}x',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.72),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _MicroActionButton(
                      icon: CupertinoIcons.bolt_circle_fill,
                      label: '闪光',
                      onTap: _isBusy || _isCountingDown ? null : _openFlashMenu,
                    ),
                    _MicroActionButton(
                      icon: CupertinoIcons.timer,
                      label: '延时',
                      onTap: _isBusy || _isCountingDown ? null : _openTimerMenu,
                    ),
                    _MicroActionButton(
                      icon: CupertinoIcons.crop,
                      label: _aspectChoice.label,
                      onTap: _isBusy || _isCountingDown ? null : _openAspectMenu,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          _ShutterButton(
            enabled: !_isBusy && !_isCountingDown && _cameraReady,
            onTap: _handleCapturePressed,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  widget.cameras.length > 1
                      ? '前后置可切换'
                      : '单摄设备',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.72),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _MicroActionButton(
                      icon: CupertinoIcons.camera_rotate_fill,
                      label: '切换',
                      onTap: _isBusy || _isCountingDown || widget.cameras.length < 2
                          ? null
                          : _switchCamera,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuEntry<T> {
  const _MenuEntry({
    required this.value,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final T value;
  final IconData icon;
  final String title;
  final String subtitle;
}

class _GlassSelectionCard<T> extends StatelessWidget {
  const _GlassSelectionCard({
    required this.title,
    required this.entries,
    required this.selected,
    required this.onSelected,
  });

  final String title;
  final List<_MenuEntry<T>> entries;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          width: 220,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.14),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withOpacity(0.18)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x32000000),
                blurRadius: 28,
                offset: Offset(0, 14),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(height: 10),
              for (final entry in entries) ...[
                _GlassSelectionTile<T>(
                  entry: entry,
                  selected: entry.value == selected,
                  onTap: () => onSelected(entry.value),
                ),
                if (entry != entries.last) const SizedBox(height: 6),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _GlassSelectionTile<T> extends StatelessWidget {
  const _GlassSelectionTile({
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  final _MenuEntry<T> entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? Colors.white.withOpacity(0.20) : Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? Colors.white.withOpacity(0.30) : Colors.white.withOpacity(0.08),
          ),
        ),
        child: Row(
          children: [
            Icon(entry.icon, color: Colors.white, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    entry.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    entry.subtitle,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.66),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              const Icon(
                CupertinoIcons.check_mark_circled_solid,
                color: Color(0xFFFFD84D),
                size: 20,
              ),
          ],
        ),
      ),
    );
  }
}

class _GlassIconButton extends StatelessWidget {
  const _GlassIconButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final active = enabled && onTap != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(active ? 0.12 : 0.06),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: Colors.white.withOpacity(active ? 0.18 : 0.10),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: Colors.white, size: 16),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: Colors.white.withOpacity(active ? 0.95 : 0.55),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MicroActionButton extends StatelessWidget {
  const _MicroActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(enabled ? 0.10 : 0.05),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white.withOpacity(enabled ? 0.14 : 0.08)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 16),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: Colors.white.withOpacity(enabled ? 0.90 : 0.50),
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ZoomPresetButton extends StatelessWidget {
  const _ZoomPresetButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? Colors.white : Colors.white.withOpacity(0.08),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: Colors.white.withOpacity(0.15),
                    blurRadius: 18,
                    spreadRadius: 1,
                  ),
                ]
              : const [],
          border: Border.all(
            color: selected ? Colors.white : Colors.white.withOpacity(0.12),
            width: 1.2,
          ),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: selected ? const Color(0xFF050507) : Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.2,
            ),
          ),
        ),
      ),
    );
  }
}

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({
    required this.enabled,
    required this.onTap,
  });

  final bool enabled;
  final Future<void> Function()? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled && onTap != null ? () => onTap!() : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        width: 92,
        height: 92,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withOpacity(enabled ? 0.08 : 0.03),
          border: Border.all(color: Colors.white.withOpacity(enabled ? 0.9 : 0.28), width: 4),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.35),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Center(
          child: Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: enabled ? Colors.white : Colors.white.withOpacity(0.34),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x26FFFFFF),
                  blurRadius: 12,
                  spreadRadius: 0.5,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.28),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withOpacity(0.12)),
          ),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              height: 1.25,
            ),
          ),
        ),
      ),
    );
  }
}
