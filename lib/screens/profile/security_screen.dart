import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

class SecurityScreen extends StatefulWidget {
  const SecurityScreen({
    super.key,
    required this.isLoggedIn,
    required this.onSignOut,
    required this.onDeleteAccount,
  });

  final bool isLoggedIn;
  final Future<void> Function() onSignOut;
  final Future<void> Function() onDeleteAccount;

  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  final TextEditingController _oldPwdController = TextEditingController();
  final TextEditingController _newPwdController = TextEditingController();
  bool _isSubmittingPassword = false;

  @override
  void dispose() {
    _oldPwdController.dispose();
    _newPwdController.dispose();
    super.dispose();
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _submitPasswordSimulation() async {
    final oldPwd = _oldPwdController.text.trim();
    final newPwd = _newPwdController.text.trim();
    if (oldPwd.length < 6 || newPwd.length < 6) {
      _showSnack('请输入至少 6 位旧/新密码');
      return;
    }
    setState(() => _isSubmittingPassword = true);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    setState(() => _isSubmittingPassword = false);
    _showSnack('模拟器演示：密码已更新（未写入真实后端）');
  }

  Widget _sectionCard({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 20,
            offset: Offset(0, 10),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: child,
    );
  }

  Widget _pwdInput({
    required TextEditingController controller,
    required String hint,
  }) {
    return Container(
      margin: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(14),
      ),
      child: TextField(
        controller: controller,
        obscureText: true,
        decoration: InputDecoration(
          hintText: hint,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          prefixIcon: const Icon(CupertinoIcons.lock_fill, size: 18),
        ),
      ),
    );
  }

  Widget _deviceRow({
    required String name,
    required String subtitle,
    required bool isCurrent,
  }) {
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const Icon(CupertinoIcons.device_phone_portrait, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(fontWeight: FontWeight.w800),
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
          if (isCurrent)
            const Text(
              '当前设备',
              style: TextStyle(
                color: Color(0xFF0A8F3E),
                fontWeight: FontWeight.w800,
                fontSize: 12,
              ),
            )
          else
            FilledButton(
              onPressed: () => _showSnack('已强制该设备退出（模拟）'),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFDC2626),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: const Text(
                '强退该设备',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: const Text('账户安全中心'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
        children: [
          _sectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '修改密码（模拟器版）',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                _pwdInput(controller: _oldPwdController, hint: '输入旧密码'),
                _pwdInput(controller: _newPwdController, hint: '输入新密码'),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed:
                      _isSubmittingPassword ? null : _submitPasswordSimulation,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF111827),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: _isSubmittingPassword
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('模拟修改密码'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _sectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '设备管理（模拟器版）',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                _deviceRow(
                  name: 'iPhone 15',
                  subtitle: '当前设备',
                  isCurrent: true,
                ),
                _deviceRow(
                  name: 'MacBook Pro',
                  subtitle: '2026-07-14 登录',
                  isCurrent: false,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: widget.isLoggedIn
                ? () async {
                    final navigator = Navigator.of(context);
                    await widget.onSignOut();
                    if (mounted) navigator.pop();
                  }
                : null,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              disabledBackgroundColor: const Color(0xFFFCA5A5),
              padding: const EdgeInsets.symmetric(vertical: 15),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
            ),
            icon: const Icon(CupertinoIcons.square_arrow_left),
            label: const Text(
              '退出当前账户',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: widget.isLoggedIn
                ? () async {
                    final navigator = Navigator.of(context);
                    await widget.onDeleteAccount();
                    if (mounted) navigator.pop();
                  }
                : null,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB91C1C),
              disabledBackgroundColor: const Color(0xFFFCA5A5),
              padding: const EdgeInsets.symmetric(vertical: 15),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
            ),
            icon: const Icon(CupertinoIcons.delete_solid),
            label: const Text(
              '账户注销 (Delete Account)',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }
}
