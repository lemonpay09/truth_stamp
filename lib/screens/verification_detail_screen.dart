import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class VerificationDetailScreen extends StatelessWidget {
  const VerificationDetailScreen({
    super.key,
    this.hash = '',
    this.timestamp = '',
    this.latitude = '',
    this.longitude = '',
    this.accuracy = '',
    this.createdAt = '',
    this.verifyUrl = '',
    this.isDetectorResult = false,
    this.detectorHeatmapImage,
    this.metadataScore,
    this.forgeryScore,
    this.detectorMessage,
    this.detectorConclusion,
    this.isForgery,
  });

  final String hash;
  final String timestamp;
  final String latitude;
  final String longitude;
  final String accuracy;
  final String createdAt;
  final String verifyUrl;

  final bool isDetectorResult;
  final String? detectorHeatmapImage;
  final int? metadataScore;
  final int? forgeryScore;
  final String? detectorMessage;
  final String? detectorConclusion;
  final bool? isForgery;

  String get _mapUrl =>
      'https://www.google.com/maps/search/?api=1&query=$latitude,$longitude';

  Future<void> _openMap() async {
    final uri = Uri.parse(_mapUrl);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Uint8List? _decodeHeatmapBytes() {
    final base64Image = detectorHeatmapImage;
    if (base64Image == null || base64Image.isEmpty) return null;
    final normalized =
        base64Image.contains(',') ? base64Image.split(',').last : base64Image;
    try {
      return base64Decode(normalized);
    } on FormatException {
      return null;
    }
  }

  Color _scoreColor(int score) {
    if (score >= 80) return const Color(0xFF0A8F3E);
    if (score >= 60) return const Color(0xFFF59E0B);
    return const Color(0xFFDC2626);
  }

  String _resolveConclusionText(int metadata, int physical) {
    if (detectorConclusion != null && detectorConclusion!.trim().isNotEmpty) {
      return detectorConclusion!.trim();
    }
    if (physical >= 80 || metadata <= 35) {
      return '高度伪造风险';
    }
    if (physical >= 55 || metadata <= 60) {
      return '疑似局部修改';
    }
    return '安全 (未见篡改)';
  }

  Color _conclusionColor(String value) {
    if (value == '高度伪造风险') return const Color(0xFFDC2626);
    if (value == '疑似局部修改') return const Color(0xFFF59E0B);
    return const Color(0xFF0A8F3E);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: const Text('鉴伪详情'),
      ),
      body: SafeArea(
        child: isDetectorResult
            ? _buildDetectorResult(theme)
            : _buildCloudResult(theme),
      ),
    );
  }

  Widget _buildDetectorResult(ThemeData theme) {
    final heatmapBytes = _decodeHeatmapBytes();
    final metadata = metadataScore ?? 0;
    final physical = forgeryScore ?? 0;
    final conclusionText = _resolveConclusionText(metadata, physical);
    final conclusionColor = _conclusionColor(conclusionText);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(28),
            boxShadow: const [
              BoxShadow(
                color: Color(0x12000000),
                blurRadius: 24,
                offset: Offset(0, 10),
              ),
            ],
          ),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '物理级像素误差分析报告',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                detectorMessage ?? '算法取证完成',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  color: const Color(0xFF0F172A),
                ),
                clipBehavior: Clip.antiAlias,
                child: AspectRatio(
                  aspectRatio: 1,
                  child: heatmapBytes == null
                      ? const Center(
                          child: Text(
                            '未获取到热力图',
                            style: TextStyle(color: Colors.white70),
                          ),
                        )
                      : Image.memory(
                          heatmapBytes,
                          fit: BoxFit.cover,
                        ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        GridView(
          physics: const NeverScrollableScrollPhysics(),
          shrinkWrap: true,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 1.2,
          ),
          children: [
            _bentoMetricCard(
              theme: theme,
              title: '原始元数据 (EXIF)',
              value: '$metadata',
              suffix: '/100',
              tint: _scoreColor(metadata),
            ),
            _bentoMetricCard(
              theme: theme,
              title: '物理像素残差 (ELA)',
              value: '$physical',
              suffix: '/100',
              tint: _scoreColor(physical),
            ),
            _bentoMetricCard(
              theme: theme,
              title: '检测结论',
              value: conclusionText,
              tint: conclusionColor,
            ),
            _bentoMetricCard(
              theme: theme,
              title: '算法状态',
              value: conclusionText == '安全 (未见篡改)' ? '未见明显异常' : '异常特征较多',
              tint: conclusionColor,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCloudResult(ThemeData theme) {
    final surface = theme.colorScheme.surface;
    final muted = theme.colorScheme.onSurfaceVariant;

    Widget detailTile(String title, String value) {
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(22),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.labelLarge?.copyWith(color: muted),
            ),
            const SizedBox(height: 8),
            SelectableText(
              value,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            decoration: BoxDecoration(
              color: surface,
              borderRadius: BorderRadius.circular(28),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x16000000),
                  blurRadius: 30,
                  offset: Offset(0, 10),
                ),
              ],
            ),
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8F5E9),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: const Icon(
                    Icons.shield_rounded,
                    color: Color(0xFF1B5E20),
                    size: 38,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '真迹：通过 Truth Stamp 官方认证',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '这是一份本地解密后得到的原生鉴伪报告。',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Container(
            decoration: BoxDecoration(
              color: surface,
              borderRadius: BorderRadius.circular(28),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x12000000),
                  blurRadius: 30,
                  offset: Offset(0, 10),
                ),
              ],
            ),
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Bento Grid',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 14),
                GridView.count(
                  crossAxisCount: 2,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  childAspectRatio: 1.18,
                  children: [
                    detailTile('拍摄时间', timestamp),
                    detailTile('纬度', latitude),
                    detailTile('经度', longitude),
                    detailTile('定位精度', '$accuracy m'),
                    detailTile('存证时间', createdAt),
                  ],
                ),
                const SizedBox(height: 14),
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFF3F4F6),
                    borderRadius: BorderRadius.circular(22),
                  ),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '哈希指纹',
                        style:
                            theme.textTheme.labelLarge?.copyWith(color: muted),
                      ),
                      const SizedBox(height: 8),
                      SelectableText(
                        hash,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
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
              onPressed: _openMap,
              child: const Text(
                '在地图中查看拍摄位置',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '验证 URL：$verifyUrl',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ],
      ),
    );
  }

  Widget _bentoMetricCard({
    required ThemeData theme,
    required String title,
    required String value,
    required Color tint,
    String? suffix,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x10000000),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          RichText(
            text: TextSpan(
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
                color: tint,
              ),
              children: [
                TextSpan(text: value),
                if (suffix != null)
                  TextSpan(
                    text: suffix,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
