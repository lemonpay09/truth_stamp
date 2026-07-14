import 'dart:async';
import 'dart:convert';
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

enum _TimerChoice { off, three, five, ten }

enum _AspectChoice { fourThree, oneOne, sixteenNine }

extension _AspectChoiceX on _AspectChoice {
  double get value {
    switch (this) {
      case _AspectChoice.fourThree:
        return 4 / 3;
      case _AspectChoice.oneOne:
        return 1;
      case _AspectChoice.sixteenNine:
        return 16 / 9;
    }
  }

  String get label {
    switch (this) {
      case _AspectChoice.fourThree:
        return '4:3';
      case _AspectChoice.oneOne:
        return '1:1';
      case _AspectChoice.sixteenNine:
        return '16:9';
    }
  }
}

class _CameraTabState extends State<CameraTab> with TickerProviderStateMixin {
  static const String _backendBaseUrl = 'https://truth-stamp.vercel.app';

  final MetadataService _metadataService = const MetadataService();
  final CryptoService _cryptoService = const CryptoService();
  final WatermarkService _watermarkService = const WatermarkService();
  final ExifService _exifService = const ExifService();
  final http.Client _httpClient = http.Client();

  CameraController? _cameraController;
  int _cameraIndex = 0;

  bool _isBusy = false;
  bool _isCountingDown = false;
  bool _panelExpanded = false;
  bool _gridVisible = false;
  bool _nightMode = false;
  bool _focusRingVisible = false;
  bool _showCaptureSpinner = false;

  String? _loadingMessage;
  String? _errorMessage;

  _FlashChoice _flashChoice = _FlashChoice.auto;
  _TimerChoice _timerChoice = _TimerChoice.off;
  _AspectChoice _aspectChoice = _AspectChoice.fourThree;

  double _zoomLevel = 1.0;
  double _minZoomLevel = 1.0;
  double _maxZoomLevel = 1.0;
  double _zoomBase = 1.0;

  double _exposureOffset = 0.0;
  double _minExposureOffset = -2.0;
  double _maxExposureOffset = 2.0;
  double _exposureBase = 0.0;
  double? _nightModeSavedExposure;

  Offset? _focusPoint;
  double _focusOpacity = 0.0;
  Timer? _focusFadeTimer;
  Timer? _countdownTimer;
  int? _countdownRemaining;
  DateTime? _lastLevelHaptic;

  late final AnimationController _panelController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );

  late final AnimationController _levelController = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  )..repeat();

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
    _panelController.dispose();
    _levelController.dispose();
    _httpClient.close();
    _cameraController?.dispose();
    super.dispose();
  }

  bool get _isMockMode => widget.cameras.isEmpty;

  bool get _cameraReady =>
      _cameraController != null && _cameraController!.value.isInitialized;

  CameraDescription? get _selectedCamera {
    if (widget.cameras.isEmpty) return null;
    if (_cameraIndex >= 0 && _cameraIndex < widget.cameras.length) {
      return widget.cameras[_cameraIndex];
    }
    return widget.cameras.first;
  }

  double get _aspectValue => _aspectChoice.value;

  String _verificationUrlForHash(String hash) {
    return Uri.parse('$_backendBaseUrl/api/verify')
        .replace(queryParameters: <String, String>{'hash': hash})
        .toString();
  }

  Future<void> _initializeCamera() async {
    if (widget.cameras.isEmpty) {
      if (!mounted) return;
      setState(() => _errorMessage = null);
      return;
    }

    final permission = await Permission.camera.status;
    if (!permission.isGranted) {
      final request = await Permission.camera.request();
      if (!request.isGranted) {
        if (!mounted) return;
        setState(() {
          _errorMessage = request.isPermanentlyDenied
              ? 'Camera permission is permanently denied. Please enable it in Settings.'
              : 'Camera permission is required to use the camera.';
        });
        return;
      }
    }

    final selected = _selectedCamera;
    if (selected == null) {
      if (!mounted) return;
      setState(() => _errorMessage = 'No usable camera was found on this device.');
      return;
    }

    final controller = CameraController(
      selected,
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
      if (_nightMode) {
        await _applyNightMode(true, fromInitialization: true);
      }
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
      setState(() => _errorMessage = 'Failed to initialize camera: $error');
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
      // Ignore unsupported zoom.
    }

    try {
      await controller.setExposureOffset(_exposureOffset);
    } on Exception {
      // Ignore unsupported exposure.
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
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Zoom control is unavailable: $error');
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
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Exposure control is unavailable: $error');
    }
  }

  Future<void> _safeSetFocusAndExposurePoint(Offset normalizedPoint) async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;

    try {
      await controller.setFocusPoint(normalizedPoint);
    } on Exception catch (_) {
      // Some devices do not support focus point.
    }

    try {
      await controller.setExposurePoint(normalizedPoint);
    } on Exception catch (_) {
      // Some devices do not support exposure point.
    }
  }

  Future<void> _switchCamera() async {
    if (_isBusy || _isCountingDown || widget.cameras.length < 2) return;

    final current = _selectedCamera;
    if (current == null) return;

    final back = widget.cameras
        .indexWhere((camera) => camera.lensDirection == CameraLensDirection.back);
    final front = widget.cameras
        .indexWhere((camera) => camera.lensDirection == CameraLensDirection.front);
    final targetIndex = current.lensDirection == CameraLensDirection.back
        ? (front == -1 ? _cameraIndex : front)
        : (back == -1 ? _cameraIndex : back);

    if (targetIndex == _cameraIndex) return;

    setState(() => _cameraIndex = targetIndex);
    await _cameraController?.dispose();
    _cameraController = null;
    await _initializeCamera();
  }

  void _resetFocusFadeTimer() {
    _focusFadeTimer?.cancel();
    _focusFadeTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      setState(() {
        _focusRingVisible = false;
        _focusOpacity = 0.0;
      });
    });
  }

  void _presentFocusRing(Offset localPosition) {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;

    setState(() {
      _focusPoint = localPosition;
      _focusRingVisible = true;
      _focusOpacity = 1.0;
    });
    _resetFocusFadeTimer();
    HapticFeedback.lightImpact();
  }

  void _applyFocusDrag(DragUpdateDetails details) {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    if (!_focusRingVisible || _focusPoint == null) return;

    final delta = -details.primaryDelta!;
    final range = _maxExposureOffset - _minExposureOffset;
    final next = _exposureBase + (delta * range / 220.0);
    unawaited(_safeSetExposureOffset(next));
    _resetFocusFadeTimer();
  }

  void _onFocusDragStart() {
    _exposureBase = _exposureOffset;
  }

  void _onScaleStart() {
    _zoomBase = _zoomLevel;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (!_cameraReady || details.scale == 1.0) return;
    unawaited(_safeSetZoomLevel(_zoomBase * details.scale));
  }

  void _onVerticalSwipeEnd(DragEndDetails details) {
    if (_focusRingVisible && _focusPoint != null) return;
    final velocity = details.primaryVelocity ?? 0.0;
    if (velocity < -150) {
      _setPanelExpanded(true);
    } else if (velocity > 150) {
      _setPanelExpanded(false);
    }
  }

  void _setPanelExpanded(bool expanded) {
    if (_panelExpanded == expanded) return;
    setState(() => _panelExpanded = expanded);
    if (expanded) {
      _panelController.forward();
    } else {
      _panelController.reverse();
    }
  }

  void _togglePanel() => _setPanelExpanded(!_panelExpanded);

  Future<void> _openFlashMenu() async {
    final choice = await _showSelectionMenu<_FlashChoice>(
      title: '闪光灯',
      selected: _flashChoice,
      entries: const [
        _MenuEntry(
          value: _FlashChoice.auto,
          icon: CupertinoIcons.bolt_circle_fill,
          title: '自动',
          subtitle: 'Auto',
        ),
        _MenuEntry(
          value: _FlashChoice.on,
          icon: CupertinoIcons.bolt_fill,
          title: '常开',
          subtitle: 'On',
        ),
        _MenuEntry(
          value: _FlashChoice.off,
          icon: CupertinoIcons.bolt_slash_fill,
          title: '关闭',
          subtitle: 'Off',
        ),
      ],
    );
    if (choice != null) {
      await _safeSetFlashMode(choice);
    }
  }

  Future<void> _openTimerMenu() async {
    final choice = await _showSelectionMenu<_TimerChoice>(
      title: '计时器',
      selected: _timerChoice,
      entries: const [
        _MenuEntry(
          value: _TimerChoice.off,
          icon: CupertinoIcons.clear_circled,
          title: '关闭',
          subtitle: 'Off',
        ),
        _MenuEntry(
          value: _TimerChoice.three,
          icon: CupertinoIcons.timer,
          title: '3 秒',
          subtitle: '3s',
        ),
        _MenuEntry(
          value: _TimerChoice.five,
          icon: CupertinoIcons.timer,
          title: '5 秒',
          subtitle: '5s',
        ),
        _MenuEntry(
          value: _TimerChoice.ten,
          icon: CupertinoIcons.timer,
          title: '10 秒',
          subtitle: '10s',
        ),
      ],
    );
    if (choice != null && mounted) {
      setState(() => _timerChoice = choice);
    }
  }

  Future<void> _openAspectMenu() async {
    final choice = await _showSelectionMenu<_AspectChoice>(
      title: '比例',
      selected: _aspectChoice,
      entries: const [
        _MenuEntry(
          value: _AspectChoice.fourThree,
          icon: CupertinoIcons.crop,
          title: '4:3',
          subtitle: 'Classic',
        ),
        _MenuEntry(
          value: _AspectChoice.oneOne,
          icon: CupertinoIcons.square,
          title: '1:1',
          subtitle: 'Square',
        ),
        _MenuEntry(
          value: _AspectChoice.sixteenNine,
          icon: CupertinoIcons.rectangle,
          title: '16:9',
          subtitle: 'Wide',
        ),
      ],
    );
    if (choice != null && mounted) {
      setState(() => _aspectChoice = choice);
    }
  }

  Future<void> _openExposureSheet() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;

    final result = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) {
        double temp = _exposureOffset;
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            bottom: 16 + MediaQuery.of(sheetContext).viewInsets.bottom,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.14),
                  border: Border.all(color: Colors.white.withOpacity(0.18)),
                  borderRadius: BorderRadius.circular(28),
                ),
                child: StatefulBuilder(
                  builder: (context, setModalState) {
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          '曝光补偿',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'EV ${temp.toStringAsFixed(1)}',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.78),
                            fontSize: 12,
                          ),
                        ),
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 10,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 18,
                            ),
                          ),
                          child: Slider(
                            value: temp.clamp(_minExposureOffset, _maxExposureOffset),
                            min: _minExposureOffset,
                            max: _maxExposureOffset,
                            onChanged: (value) {
                              setModalState(() => temp = value);
                              unawaited(_safeSetExposureOffset(value));
                            },
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: () => Navigator.of(sheetContext).pop(0.0),
                            child: const Text('重置到 0'),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );

    if (result != null && mounted) {
      await _safeSetExposureOffset(result);
    }
  }

  Future<void> _toggleNightMode() async {
    await _applyNightMode(!_nightMode);
  }

  Future<void> _applyNightMode(
    bool enabled, {
    bool fromInitialization = false,
  }) async {
    if (mounted) {
      setState(() {
        _nightMode = enabled;
      });
    } else {
      _nightMode = enabled;
    }

    if (enabled) {
      _nightModeSavedExposure ??= _exposureOffset;
      final target = math.min(_maxExposureOffset, math.max(1.2, _maxExposureOffset * 0.75));
      await _safeSetExposureOffset(target);
      try {
        await _safeSetFlashMode(_FlashChoice.off);
      } catch (_) {
        // ignore
      }
    } else if (!fromInitialization) {
      final restore = _nightModeSavedExposure ?? 0.0;
      _nightModeSavedExposure = null;
      await _safeSetExposureOffset(restore);
    }
  }

  void _toggleGrid() {
    setState(() => _gridVisible = !_gridVisible);
  }

  Future<void> _handleCapturePressed() async {
    if (_isBusy || _isCountingDown) return;

    if (_isMockMode) {
      await _captureMockAndUpload();
      return;
    }

    final delay = switch (_timerChoice) {
      _TimerChoice.off => 0,
      _TimerChoice.three => 3,
      _TimerChoice.five => 5,
      _TimerChoice.ten => 10,
    };

    if (delay > 0) {
      await _startCountdown(delay);
      return;
    }

    await _capturePipeline();
  }

  Future<void> _startCountdown(int seconds) async {
    if (_isBusy || _isCountingDown) return;
    setState(() {
      _isCountingDown = true;
      _countdownRemaining = seconds;
      _errorMessage = null;
    });

    await HapticFeedback.lightImpact();
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }

      final next = (_countdownRemaining ?? seconds) - 1;
      if (next <= 0) {
        timer.cancel();
        setState(() {
          _countdownRemaining = null;
          _isCountingDown = false;
        });
        await HapticFeedback.mediumImpact();
        await _capturePipeline();
        return;
      }

      setState(() => _countdownRemaining = next);
      await HapticFeedback.selectionClick();
    });
  }

  Future<void> _captureMockAndUpload() async {
    if (_isBusy) return;
    setState(() {
      _isBusy = true;
      _loadingMessage = '正在模拟拍照并同步...';
      _errorMessage = null;
      _showCaptureSpinner = true;
    });

    try {
      final timestamp = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
      final mockFile = await _createMockCaptureFile(timestamp);
      final bytes = await mockFile.readAsBytes();
      final metadata = <String, dynamic>{
        'timestamp': timestamp,
        'latitude': 31.2304,
        'longitude': 121.4737,
        'accuracy': 10.0,
      };
      final hash = _cryptoService.calculateSha256(
        imageBytes: bytes,
        metadata: metadata,
      );

      setState(() => _loadingMessage = '正在同步至云端...');
      await _uploadStamp(hash, metadata);
      await _protectAndSaveCapturedImage(mockFile, hash);
      await _persistHistory(mockFile, hash, metadata);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Mock capture synced successfully')),
      );
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Mock capture failed: $error');
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
          _showCaptureSpinner = false;
          _loadingMessage = null;
        });
      }
    }
  }

  Future<void> _capturePipeline() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized || _isBusy) return;

    setState(() {
      _isBusy = true;
      _loadingMessage = '正在拍照并同步...';
      _showCaptureSpinner = true;
      _errorMessage = null;
    });

    try {
      if (_nightMode) {
        await Future<void>.delayed(const Duration(milliseconds: 900));
      }

      final shot = await controller.takePicture();
      final sourceFile = File(shot.path);
      final cropped = await _cropPhotoToSelectedAspect(sourceFile);
      final bytes = await cropped.readAsBytes();
      final metadata = await _metadataService.collectMetadata();
      final normalizedMetadata = <String, dynamic>{
        ...metadata,
        'timestamp': metadata['timestamp']?.toString() ??
            DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now()),
      };
      final hash = _cryptoService.calculateSha256(
        imageBytes: bytes,
        metadata: normalizedMetadata,
      );

      setState(() => _loadingMessage = '正在同步至云端...');
      await _uploadStamp(hash, normalizedMetadata);
      await _protectAndSaveCapturedImage(cropped, hash);
      await _persistHistory(cropped, hash, normalizedMetadata);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('拍照完成，已保存并同步')),
      );
    } on CameraException catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'Failed to capture photo: ${error.description ?? error.code}';
      });
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = 'Capture failed: $error');
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
          _showCaptureSpinner = false;
          _loadingMessage = null;
        });
      }
    }
  }

  Future<File> _createMockCaptureFile(String timestamp) async {
    final image = img.Image(width: 1600, height: 1200);
    for (final pixel in image) {
      final x = pixel.x / image.width;
      final y = pixel.y / image.height;
      pixel
        ..r = (32 + 90 * x).round()
        ..g = (52 + 100 * y).round()
        ..b = (110 + 55 * (1 - x)).round()
        ..a = 255;
    }

    final encoded = img.encodeJpg(image, quality: 94);
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/truth_stamp_mock_$timestamp.jpg'
          .replaceAll(':', '-')
          .replaceAll(' ', '_'),
    );
    await file.writeAsBytes(encoded, flush: true);
    return file;
  }

  Future<File> _cropPhotoToSelectedAspect(File sourceFile) async {
    final bytes = await sourceFile.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return sourceFile;

    final targetAspect = _aspectValue;
    final currentAspect = decoded.width / decoded.height;
    if ((currentAspect - targetAspect).abs() < 0.01) {
      return sourceFile;
    }

    int cropWidth = decoded.width;
    int cropHeight = decoded.height;
    int cropX = 0;
    int cropY = 0;

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

    final dir = await getTemporaryDirectory();
    final out = File(
      '${dir.path}/truth_stamp_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );
    await out.writeAsBytes(img.encodeJpg(cropped, quality: 95), flush: true);
    return out;
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
      throw StateError(_extractError(response.body, response.statusCode));
    }
  }

  Future<void> _protectAndSaveCapturedImage(File sourceFile, String hash) async {
    final verifyUrl = _verificationUrlForHash(hash);
    try {
      final watermarked = await _watermarkService.embedInvisibleWatermark(
        sourceFile,
        verifyUrl,
      );
      final saved = await _exifService.secureAndSaveImage(
        watermarked,
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

  Future<void> _persistHistory(
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

  String _extractError(String body, int statusCode) {
    if (body.trim().isEmpty) return 'HTTP $statusCode';
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic> && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } on FormatException {
      // Fallback below.
    }
    return body;
  }

  Future<T?> _showSelectionMenu<T>({
    required String title,
    required List<_MenuEntry<T>> entries,
    required T selected,
  }) {
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: title,
      barrierColor: Colors.black.withOpacity(0.10),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return SafeArea(
          child: Stack(
            children: [
              Positioned(
                left: 16,
                right: 16,
                top: 16,
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
            scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  Future<void> _onArrowTapped() async {
    _togglePanel();
    await HapticFeedback.selectionClick();
  }

  Future<void> _onPanelExposureTapped() async {
    await _openExposureSheet();
  }

  Future<void> _onNightTap() async {
    await _toggleNightMode();
    await HapticFeedback.lightImpact();
  }

  Widget _buildStage() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final visibleHeight = math.min(
          constraints.maxHeight,
          constraints.maxWidth / _aspectValue,
        );
        final maskHeight = ((constraints.maxHeight - visibleHeight) / 2).clamp(
          0.0,
          constraints.maxHeight / 2,
        );
        final controller = _cameraController;
        final previewAspect = controller?.value.aspectRatio ?? (4 / 3);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) {
            if (_isBusy || _isCountingDown) return;
            _presentFocusRing(details.localPosition);
            _exposureBase = _exposureOffset;
            final normalized = Offset(
              (details.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0),
              (details.localPosition.dy / constraints.maxHeight).clamp(0.0, 1.0),
            );
            unawaited(_safeSetFocusAndExposurePoint(normalized));
          },
          onScaleStart: (_) => _onScaleStart(),
          onScaleUpdate: _onScaleUpdate,
          onVerticalDragStart: (_) => _onFocusDragStart(),
          onVerticalDragUpdate: _applyFocusDrag,
          onVerticalDragEnd: _onVerticalSwipeEnd,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(child: _buildPreviewContent(previewAspect)),
              AnimatedPositioned(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                left: 0,
                right: 0,
                top: 0,
                height: maskHeight,
                child: Container(
                  color: Colors.black.withOpacity(0.35),
                ),
              ),
              AnimatedPositioned(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                left: 0,
                right: 0,
                bottom: 0,
                height: maskHeight,
                child: Container(
                  color: Colors.black.withOpacity(0.35),
                ),
              ),
              if (_gridVisible) Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _GridPainter()))),
              Positioned.fill(child: _buildCenterLevel()),
              Positioned(top: 10, left: 0, right: 0, child: Center(child: _buildArrow())),
              Positioned(
                left: 16,
                right: 16,
                bottom: 18,
                child: _buildPanel(),
              ),
              if (_focusRingVisible && _focusPoint != null)
                _buildFocusOverlay(constraints),
              if (_countdownRemaining != null) _buildCountdownOverlay(),
              if (_showCaptureSpinner) _buildCaptureSpinner(),
              if (_errorMessage != null)
                Positioned(
                  left: 14,
                  right: 14,
                  top: 56,
                  child: _InlineNotice(message: _errorMessage!),
                ),
              if (_loadingMessage != null)
                Positioned(
                  left: 14,
                  right: 14,
                  bottom: maskHeight + 24,
                  child: _InlineNotice(message: _loadingMessage!),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPreviewContent(double previewAspect) {
    final controller = _cameraController;
    if (_isMockMode || controller == null || !controller.value.isInitialized) {
      return _buildMockSurface();
    }

    return Center(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: 1000,
          height: 1000 / previewAspect,
          child: CameraPreview(controller),
        ),
      ),
    );
  }

  Widget _buildMockSurface() {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            Color(0xFF08111F),
            Color(0xFF172554),
            Color(0xFF0B1020),
          ],
        ),
      ),
    );
  }

  Widget _buildArrow() {
    return GestureDetector(
      onTap: _onArrowTapped,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.12),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.white.withOpacity(0.16)),
            ),
            child: AnimatedRotation(
              turns: _panelExpanded ? 0.5 : 0.0,
              duration: const Duration(milliseconds: 220),
              child: const Icon(
                CupertinoIcons.chevron_down,
                color: Colors.white,
                size: 18,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPanel() {
    final labelsVisible = _panelExpanded;
    return AnimatedSlide(
      offset: _panelExpanded ? Offset.zero : const Offset(0, 0.42),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(
        opacity: _panelExpanded ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 180),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(34),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.14),
                borderRadius: BorderRadius.circular(34),
                border: Border.all(color: Colors.white.withOpacity(0.16)),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x30000000),
                    blurRadius: 30,
                    offset: Offset(0, 12),
                  ),
                ],
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                child: Row(
                  children: [
                    _ChubbyControl(
                      icon: CupertinoIcons.bolt_fill,
                      title: '闪光灯',
                      active: _flashChoice != _FlashChoice.off,
                      expanded: labelsVisible,
                      onTap: _openFlashMenu,
                    ),
                    _ChubbyControl(
                      icon: CupertinoIcons.circle_grid_3x3_fill,
                      title: '实况',
                      active: false,
                      disabled: true,
                      expanded: labelsVisible,
                      onTap: null,
                    ),
                    _ChubbyControl(
                      icon: CupertinoIcons.timer,
                      title: '计时器',
                      active: _timerChoice != _TimerChoice.off,
                      expanded: labelsVisible,
                      onTap: _openTimerMenu,
                    ),
                    _ChubbyControl(
                      icon: CupertinoIcons.sun_max_fill,
                      title: '曝光',
                      active: _exposureOffset.abs() > 0.05,
                      expanded: labelsVisible,
                      subtitle: 'EV ${_exposureOffset.toStringAsFixed(1)}',
                      onTap: _onPanelExposureTapped,
                    ),
                    _ChubbyControl(
                      icon: CupertinoIcons.crop,
                      title: '宽高比',
                      active: true,
                      expanded: labelsVisible,
                      subtitle: _aspectChoice.label,
                      onTap: _openAspectMenu,
                    ),
                    _ChubbyControl(
                      icon: CupertinoIcons.moon_stars_fill,
                      title: '夜间',
                      active: _nightMode,
                      expanded: labelsVisible,
                      onTap: _onNightTap,
                    ),
                    _ChubbyControl(
                      icon: CupertinoIcons.grid,
                      title: '网格线',
                      active: _gridVisible,
                      expanded: labelsVisible,
                      onTap: () {
                        _toggleGrid();
                        HapticFeedback.selectionClick();
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCenterLevel() {
    return AnimatedBuilder(
      animation: _levelController,
      builder: (context, _) {
        final t = _levelController.value * math.pi * 2;
        const amp = 6.0;
        final offset = Offset(math.sin(t) * amp, math.cos(t * 1.2) * amp);
        final aligned = offset.distance < 0.9;
        if (aligned) {
          final now = DateTime.now();
          if (_lastLevelHaptic == null ||
              now.difference(_lastLevelHaptic!) > const Duration(seconds: 1)) {
            _lastLevelHaptic = now;
            unawaited(HapticFeedback.lightImpact());
          }
        }

        return IgnorePointer(
          child: Center(
            child: Stack(
              alignment: Alignment.center,
              children: [
                _CrossHair(
                  color: Colors.white.withOpacity(0.36),
                  size: 24,
                  strokeWidth: 1.1,
                ),
                Transform.translate(
                  offset: offset,
                  child: _CrossHair(
                    color: aligned ? const Color(0xFFFFD84D) : Colors.white.withOpacity(0.92),
                    size: 18,
                    strokeWidth: 1.5,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildFocusOverlay(BoxConstraints constraints) {
    final point = _focusPoint!;
    const ringSize = 84.0;
    const sliderWidth = 28.0;
    const sliderHeight = 138.0;

    final left = (point.dx - ringSize / 2).clamp(10.0, constraints.maxWidth - ringSize - sliderWidth - 18);
    final top = (point.dy - ringSize / 2 - 8).clamp(10.0, constraints.maxHeight - sliderHeight - 20.0);

    final sliderValue = (_exposureOffset - _minExposureOffset) /
        math.max(0.01, _maxExposureOffset - _minExposureOffset);

    return Positioned(
      left: left,
      top: top,
      child: AnimatedOpacity(
        opacity: _focusOpacity,
        duration: const Duration(milliseconds: 220),
        child: AnimatedScale(
          scale: _focusOpacity > 0.0 ? 1.0 : 0.94,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutBack,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: ringSize,
                height: ringSize,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFFFFD84D), width: 2.1),
                  color: const Color(0x18FFD84D),
                ),
                child: const Center(
                  child: _CrossHair(
                    color: Color(0xFFFFD84D),
                    size: 20,
                    strokeWidth: 1.4,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: sliderWidth,
                height: sliderHeight,
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.26),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: Colors.white.withOpacity(0.12)),
                ),
                child: Column(
                  children: [
                    const Icon(CupertinoIcons.sun_max_fill, color: Colors.white, size: 14),
                    const SizedBox(height: 8),
                    Expanded(
                      child: Align(
                        alignment: Alignment(0, 1 - (sliderValue * 2)),
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(0xFFFFD84D),
                          ),
                        ),
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
            borderRadius: BorderRadius.circular(40),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Container(
                width: 176,
                height: 176,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(40),
                  border: Border.all(color: Colors.white.withOpacity(0.18)),
                ),
                child: Center(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 160),
                    transitionBuilder: (child, animation) {
                      return FadeTransition(
                        opacity: animation,
                        child: ScaleTransition(scale: animation, child: child),
                      );
                    },
                    child: Text(
                      '${_countdownRemaining!}',
                      key: ValueKey<int>(_countdownRemaining!),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 88,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -4,
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

  Widget _buildCaptureSpinner() {
    return Positioned.fill(
      child: IgnorePointer(
        child: Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(40),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(
                width: 92,
                height: 92,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.20),
                  borderRadius: BorderRadius.circular(40),
                  border: Border.all(color: Colors.white.withOpacity(0.15)),
                ),
                child: const Center(
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: Colors.white,
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

  Widget _buildZoomControls() {
   const zoomLevels = [0.5, 1.0, 2.0];
   return Container(
     height: 56,
     padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
     child: Row(
       mainAxisAlignment: MainAxisAlignment.center,
       children: [
         for (final zoom in zoomLevels) ...[
           GestureDetector(
             onTap: _isBusy || _isCountingDown
                 ? null
                 : () => _setZoomLevel(zoom),
             child: AnimatedContainer(
               duration: const Duration(milliseconds: 200),
               width: 48,
               height: 40,
               margin: const EdgeInsets.symmetric(horizontal: 6),
               decoration: BoxDecoration(
                 color: (_zoomLevel - zoom).abs() < 0.1
                     ? Colors.white.withOpacity(0.25)
                     : Colors.white.withOpacity(0.12),
                 border: Border.all(
                   color: Colors.white.withOpacity(0.28),
                   width: 1.2,
                 ),
                 borderRadius: BorderRadius.circular(10),
               ),
               child: Center(
                 child: Text(
                   zoom == 1.0
                       ? '1x'
                       : zoom == 0.5
                           ? '0.5x'
                           : '2x',
                   style: TextStyle(
                     color: Colors.white.withOpacity(0.88),
                     fontSize: 13,
                     fontWeight: FontWeight.w600,
                   ),
                 ),
               ),
             ),
           ),
           if (zoom != zoomLevels.last) const SizedBox(width: 2),
         ],
       ],
     ),
   );
  }

  Future<void> _setZoomLevel(double level) async {
   try {
     final controller = _cameraController;
     if (controller == null || !controller.value.isInitialized) return;
      
     final minZoom = _minZoomLevel;
     final maxZoom = _maxZoomLevel;
     final targetZoom = (level * minZoom).clamp(minZoom, maxZoom);
      
     await controller.setZoomLevel(targetZoom);
     setState(() {
       _zoomLevel = level;
     });
     HapticFeedback.selectionClick();
   } catch (e) {
     debugPrint('Zoom error: $e');
   }
  }

  Widget _buildBottomBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      child: Row(
        children: [
          _RoundActionButton(
            icon: CupertinoIcons.camera_rotate_fill,
            label: widget.cameras.length > 1 ? '切换' : '单摄',
            onTap: widget.cameras.length > 1 && !_isBusy && !_isCountingDown
                ? _switchCamera
                : null,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Center(
              child: GestureDetector(
                onTap: _isBusy || _isCountingDown ? null : _handleCapturePressed,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withOpacity(_isBusy ? 0.18 : 0.08),
                    border: Border.all(
                      color: Colors.white.withOpacity(_isBusy ? 0.55 : 0.88),
                      width: 4,
                    ),
                  ),
                  child: Center(
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withOpacity(_isBusy ? 0.55 : 1),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          _RoundActionButton(
            icon: CupertinoIcons.crop,
            label: _aspectChoice.label,
            onTap: !_isBusy && !_isCountingDown ? _openAspectMenu : null,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _buildStage()),
            _buildZoomControls(),
            _buildBottomBar(),
          ],
        ),
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
      borderRadius: BorderRadius.circular(28),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.14),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: Colors.white.withOpacity(0.16)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? Colors.white.withOpacity(0.18) : Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? Colors.white.withOpacity(0.28) : Colors.white.withOpacity(0.08),
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

class _ChubbyControl extends StatelessWidget {
  const _ChubbyControl({
    required this.icon,
    required this.title,
    required this.expanded,
    required this.onTap,
    this.subtitle,
    this.active = false,
    this.disabled = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool expanded;
  final bool active;
  final bool disabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = !disabled && onTap != null;
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          width: expanded ? 82 : 58,
          padding: EdgeInsets.symmetric(horizontal: expanded ? 10 : 6, vertical: 10),
          decoration: BoxDecoration(
            color: disabled
                ? Colors.white.withOpacity(0.06)
                : active
                    ? Colors.white.withOpacity(0.16)
                    : Colors.white.withOpacity(0.08),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: disabled
                  ? Colors.white.withOpacity(0.05)
                  : Colors.white.withOpacity(active ? 0.20 : 0.10),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 21,
                color: disabled
                    ? Colors.white.withOpacity(0.35)
                    : active
                        ? const Color(0xFFFFD84D)
                        : Colors.white,
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                child: expanded
                    ? Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              style: TextStyle(
                                color: disabled
                                    ? Colors.white.withOpacity(0.45)
                                    : Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (subtitle != null)
                              Text(
                                subtitle!,
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.60),
                                  fontSize: 9,
                                ),
                              ),
                          ],
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoundActionButton extends StatelessWidget {
  const _RoundActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final active = onTap != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(active ? 0.10 : 0.05),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withOpacity(0.12)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: Colors.white),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: Colors.white.withOpacity(active ? 0.92 : 0.50),
                    fontSize: 11,
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

class _CrossHair extends StatelessWidget {
  const _CrossHair({
    required this.color,
    required this.size,
    required this.strokeWidth,
  });

  final Color color;
  final double size;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _CrossHairPainter(color: color, strokeWidth: strokeWidth),
      ),
    );
  }
}

class _CrossHairPainter extends CustomPainter {
  _CrossHairPainter({
    required this.color,
    required this.strokeWidth,
  });

  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(
      Offset(size.width / 2, 0),
      Offset(size.width / 2, size.height),
      paint,
    );
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _CrossHairPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.strokeWidth != strokeWidth;
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.16)
      ..strokeWidth = 0.7;

    const divisions = 3;
    for (var i = 1; i < divisions; i++) {
      final dx = size.width * i / divisions;
      final dy = size.height * i / divisions;
      canvas.drawLine(Offset(dx, 0), Offset(dx, size.height), paint);
      canvas.drawLine(Offset(0, dy), Offset(size.width, dy), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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
            border: Border.all(color: Colors.white.withOpacity(0.10)),
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
