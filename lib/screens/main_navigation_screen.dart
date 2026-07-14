import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/verification_history_service.dart';
import 'tabs/camera_tab.dart';
import 'tabs/profile_tab.dart';
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
    VerifyTab(historyService: _historyService),
    const ProfileTab(),
  ];

  int _currentIndex = 0;

  void _setIndex(int index) {
    if (index == _currentIndex) return;
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
                height: 78,
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
                  children: [
                    Expanded(
                      child: _NavItem(
                        label: '相机',
                        icon: CupertinoIcons.camera_fill,
                        selected: _currentIndex == 0,
                        onTap: () => _setIndex(0),
                        activeColor: const Color(0xFF0A8F3E),
                        inactiveColor: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Expanded(
                      child: _NavItem(
                        label: '鉴伪',
                        icon: CupertinoIcons.shield_lefthalf_fill,
                        selected: _currentIndex == 1,
                        onTap: () => _setIndex(1),
                        activeColor: const Color(0xFF0B5FFF),
                        inactiveColor: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Expanded(
                      child: _NavItem(
                        label: '我的',
                        icon: CupertinoIcons.person_crop_circle_fill,
                        selected: _currentIndex == 2,
                        onTap: () => _setIndex(2),
                        activeColor: const Color(0xFF111827),
                        inactiveColor: theme.colorScheme.onSurfaceVariant,
                      ),
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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Center(
        child: AnimatedScale(
          scale: selected ? 1.06 : 1.0,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutBack,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
                  size: selected ? 23 : 21,
                  color: selected ? activeColor : inactiveColor,
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    color: selected ? activeColor : inactiveColor,
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
