import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth/login_screen.dart';

class ProfileTab extends StatefulWidget {
  const ProfileTab({super.key});

  @override
  State<ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<ProfileTab> {
  SupabaseClient? get _client {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  String _maskIdentity(User user) {
    final phone = user.phone;
    if (phone != null && phone.length >= 7) {
      return '${phone.substring(0, 3)}****${phone.substring(phone.length - 4)}';
    }
    final email = user.email ?? '未设置账号';
    final parts = email.split('@');
    if (parts.length != 2 || parts.first.length < 2) return email;
    final name = parts.first;
    return '${name.substring(0, 1)}***${name.substring(name.length - 1)}@${parts.last}';
  }

  Future<void> _openLoginScreen() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => const LoginScreen(),
      ),
    );
    if (changed == true && mounted) {
      setState(() {});
    }
  }

  Future<void> _signOut() async {
    final client = _client;
    if (client == null) {
      _showSnack('Supabase 尚未初始化');
      return;
    }
    try {
      await client.auth.signOut();
      if (!mounted) return;
      setState(() {});
      _showSnack('已退出登录');
    } on AuthException catch (error) {
      _showSnack(error.message);
    }
  }

  Future<void> _deleteAccount() async {
    final client = _client;
    final user = client?.auth.currentUser;
    if (client == null || user == null) {
      _showSnack('请先登录后再注销账户');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('确认注销账户？'),
          content: const Text(
            '注销后将清除当前登录态，且不可恢复。请谨慎操作。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFDC2626),
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('确认注销'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    try {
      final functionResponse = await client.functions.invoke('delete-account');
      if (functionResponse.status >= 400) {
        throw StateError(
          'delete-account failed (${functionResponse.status}): ${functionResponse.data}',
        );
      }
      await client.auth.signOut();
      if (!mounted) return;
      setState(() {});
      _showSnack('账户已注销');
    } catch (_) {
      try {
        await client.rpc('delete_current_user');
        await client.auth.signOut();
        if (!mounted) return;
        setState(() {});
        _showSnack('账户已注销');
      } on Exception catch (error) {
        _showSnack('账户注销失败：$error');
      }
    }
  }

  Future<void> _openWebDoc(String url) async {
    final uri = Uri.parse(url);
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened) {
      _showSnack('无法打开链接');
    }
  }

  void _showAccountSecuritySheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
          decoration: const BoxDecoration(
            color: Color(0xFFF8FAFC),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFCBD5E1),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 14),
              _bentoTile(
                icon: CupertinoIcons.lock_fill,
                title: '修改密码（模拟）',
                subtitle: '请在下一版本接入密码更新 API',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showSnack('已进入修改密码模拟流程');
                },
              ),
              const SizedBox(height: 10),
              _bentoTile(
                icon: CupertinoIcons.device_phone_portrait,
                title: '设备管理（模拟）',
                subtitle: '查看近期登录设备记录',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showSnack('已进入设备管理模拟流程');
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Widget _bentoTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    Color iconColor = const Color(0xFF0B5FFF),
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [
            BoxShadow(
              color: Color(0x12000000),
              blurRadius: 18,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: const Color(0xFFF3F4F6),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: iconColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: Color(0xFF64748B),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(CupertinoIcons.chevron_forward, size: 18),
          ],
        ),
      ),
    );
  }

  Widget _unauthHeaderCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(30),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 26,
            offset: Offset(0, 10),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '开启 Truth Stamp 数字真迹之旅',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: Color(0xFF0F172A),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '登录后可同步身份、管理安全中心并解锁 PRO 权益',
            style: TextStyle(
              color: Color(0xFF64748B),
              height: 1.35,
            ),
          ),
          const SizedBox(height: 14),
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: const LinearGradient(
                colors: [Color(0xFF3B82F6), Color(0xFF2563EB)],
              ),
            ),
            child: FilledButton(
              onPressed: _openLoginScreen,
              style: FilledButton.styleFrom(
                backgroundColor: Colors.transparent,
                shadowColor: Colors.transparent,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
              child: const Text(
                '登录 / 注册',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _authHeaderCard(User user) {
    final maskedIdentity = _maskIdentity(user);
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(30),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 26,
            offset: Offset(0, 10),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 66,
                height: 66,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [Colors.blue.shade300, Colors.blue.shade600],
                  ),
                ),
                child: const Icon(
                  CupertinoIcons.person_fill,
                  color: Colors.white,
                  size: 34,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Truth Stamp 用户',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      maskedIdentity,
                      style: const TextStyle(
                        color: Color(0xFF64748B),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: const LinearGradient(
                colors: [
                  Color(0xFFFFF6CC),
                  Color(0xFFE8D48C),
                  Color(0xFFFFF2B1),
                ],
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x33D4AF37),
                  blurRadius: 14,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.workspace_premium_rounded,
                    size: 16, color: Color(0xFF8A6D1D)),
                SizedBox(width: 6),
                Text(
                  'PRO 创始会员',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF6B5317),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _signOut,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF111827),
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: const Text(
              '退出登录',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(User? user) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        user == null ? _unauthHeaderCard() : _authHeaderCard(user),
        const SizedBox(height: 16),
        _bentoTile(
          icon: CupertinoIcons.lock_shield_fill,
          title: '账户安全中心',
          subtitle: '密码、设备、风险提醒',
          onTap: _showAccountSecuritySheet,
          iconColor: const Color(0xFF0A8F3E),
        ),
        const SizedBox(height: 10),
        _bentoTile(
          icon: CupertinoIcons.doc_text_fill,
          title: '隐私政策',
          subtitle: '了解我们如何保护你的数据',
          onTap: () => _openWebDoc('https://truth-stamp.vercel.app/privacy'),
        ),
        const SizedBox(height: 10),
        _bentoTile(
          icon: CupertinoIcons.doc_on_doc_fill,
          title: '用户协议',
          subtitle: '查看服务条款与合规要求',
          onTap: () => _openWebDoc('https://truth-stamp.vercel.app/terms'),
        ),
        const SizedBox(height: 10),
        _bentoTile(
          icon: CupertinoIcons.question_circle_fill,
          title: '使用帮助',
          subtitle: '常见问题与操作指南',
          onTap: () => _openWebDoc('https://truth-stamp.vercel.app/help'),
          iconColor: const Color(0xFF2563EB),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: user == null ? null : _deleteAccount,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFDC2626),
            disabledBackgroundColor: const Color(0xFFFCA5A5),
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
          ),
          icon: const Icon(CupertinoIcons.delete_solid),
          label: const Text(
            '账户注销 (Delete Account)',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final client = _client;
    final stream = client?.auth.onAuthStateChange;
    if (stream == null) {
      return Scaffold(
        backgroundColor: const Color(0xFFF7F8FA),
        body: SafeArea(child: _buildBody(null)),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      body: SafeArea(
        child: StreamBuilder<AuthState>(
          stream: stream,
          builder: (context, snapshot) {
            final user = snapshot.data?.session?.user ?? client?.auth.currentUser;
            return _buildBody(user);
          },
        ),
      ),
    );
  }
}
