import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/verification_history_service.dart';
import 'tabs/camera_tab.dart';
import 'tabs/profile_tab.dart';
import 'tabs/ts_verify_tab.dart';
import 'tabs/verify_tab.dart';

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({
    super.key,
    required this.cameras,
  });

  final List<CameraDescription> cameras;

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  final VerificationHistoryService _historyService =
      VerificationHistoryService();

  late final List<Widget> _tabs = <Widget>[
    CameraTab(cameras: widget.cameras, historyService: _historyService),
    VerifyTab(historyService: _historyService), // Detect (ELA)
    TsVerifyTab(historyService: _historyService), // Verify (EXIF + watermark)
    const ProfileTab(),
  ];

  int _currentIndex = 0;

  void _setIndex(int index) {
    if (index == _currentIndex) return;
    HapticFeedback.selectionClick();
    setState(() => _currentIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      extendBody: true,
      body: IndexedStack(
        index: _currentIndex,
        children: _tabs,
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
              child: Container(
                height: 80,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.78),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Colors.white.withOpacity(0.65)),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x1A000000),
                      blurRadius: 30,
                      offset: Offset(0, 14),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _NavItem(
                      label: '相机',
                      icon: CupertinoIcons.camera_fill,
                      selected: _currentIndex == 0,
                      onTap: () => _setIndex(0),
                      activeColor: const Color(0xFF0A8F3E),
                      inactiveColor: theme.colorScheme.onSurfaceVariant,
                    ),
                    _NavItem(
                      label: '鉴伪',
                      icon: CupertinoIcons.waveform_path_ecg,
                      selected: _currentIndex == 1,
                      onTap: () => _setIndex(1),
                      activeColor: const Color(0xFF0B5FFF),
                      inactiveColor: theme.colorScheme.onSurfaceVariant,
                    ),
                    _NavItem(
                      label: '验证',
                      icon: CupertinoIcons.checkmark_shield_fill,
                      selected: _currentIndex == 2,
                      onTap: () => _setIndex(2),
                      activeColor: const Color(0xFF7C3AED),
                      inactiveColor: theme.colorScheme.onSurfaceVariant,
                    ),
                    _NavItem(
                      label: '我的',
                      icon: CupertinoIcons.person_crop_circle_fill,
                      selected: _currentIndex == 3,
                      onTap: () => _setIndex(3),
                      activeColor: const Color(0xFF111827),
                      inactiveColor: theme.colorScheme.onSurfaceVariant,
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
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    required this.activeColor,
    required this.inactiveColor,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final Color activeColor;
  final Color inactiveColor;

  @override
  Widget build(BuildContext context) {
    final selectedColor = selected ? activeColor : inactiveColor;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Center(
        child: AnimatedScale(
          scale: selected ? 1.05 : 1.0,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutBack,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 74,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
            decoration: BoxDecoration(
              color: selected
                  ? activeColor.withOpacity(0.10)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: selected ? 21 : 20,
                  color: selectedColor,
                ),
                const SizedBox(height: 3),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    color: selectedColor,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
