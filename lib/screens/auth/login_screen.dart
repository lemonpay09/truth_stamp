import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

enum _LoginMode { phone, email }

enum _EmailAuthMode { otp, password }

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const String _backendBaseUrl = 'https://truthstamp.cn';

  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  _LoginMode _loginMode = _LoginMode.phone;
  _EmailAuthMode _emailAuthMode = _EmailAuthMode.otp;
  bool _isBusy = false;
  int _countdown = 0;
  Timer? _countdownTimer;

  SupabaseClient? get _client {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  bool get _canSubmitPhoneLogin {
    return _phoneController.text.trim().length == 11 &&
        _codeController.text.trim().length == 6 &&
        !_isBusy;
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _phoneController.dispose();
    _codeController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    setState(() {
      _countdown = 60;
    });
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (_countdown <= 1) {
        timer.cancel();
        setState(() => _countdown = 0);
        return;
      }
      setState(() => _countdown -= 1);
    });
  }

  Future<void> _sendPhoneCode() async {
    final phone = _phoneController.text.trim();
    if (phone.length != 11) {
      _showMessage('请输入正确手机号');
      return;
    }
    setState(() => _isBusy = true);
    try {
      final response = await http.post(
        Uri.parse('$_backendBaseUrl/api/send-sms'),
        headers: const <String, String>{
          'Content-Type': 'application/json; charset=utf-8',
        },
        body: '{"phoneNumber":"$phone"}',
      );
      final payload = response.body.isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(response.body) as Map);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          payload['error']?.toString() ?? '验证码发送失败（${response.statusCode}）',
        );
      }
      _startCountdown();
      _showMessage('验证码已发送');
    } catch (error) {
      _showMessage('发送失败：$error');
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _loginWithPhoneCode() async {
    final phone = _phoneController.text.trim();
    final code = _codeController.text.trim();
    if (phone.length != 11 || code.length != 6) {
      _showMessage('请输入手机号和 6 位验证码');
      return;
    }

    setState(() => _isBusy = true);
    try {
      final response = await http.post(
        Uri.parse('$_backendBaseUrl/api/verify-sms'),
        headers: const <String, String>{
          'Content-Type': 'application/json; charset=utf-8',
        },
        body: '{"phoneNumber":"$phone","code":"$code"}',
      );
      final data = response.body.isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(response.body) as Map);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          data['error']?.toString() ?? '验证码校验失败（${response.statusCode}）',
        );
      }

      final session = data['session'];
      final refreshToken = session is Map ? session['refresh_token'] : null;
      final client = _client;
      if (client != null &&
          refreshToken is String &&
          refreshToken.isNotEmpty) {
        await client.auth.setSession(refreshToken);
      }

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      _showMessage('登录失败：$error');
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _loginWithEmailOtp() async {
    final client = _client;
    if (client == null) {
      _showMessage('Supabase 尚未初始化');
      return;
    }
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      _showMessage('请输入正确邮箱');
      return;
    }
    setState(() => _isBusy = true);
    try {
      await client.auth.signInWithOtp(email: email);
      if (!mounted) return;
      _showMessage('免密登录链接已发送到邮箱');
    } on AuthException catch (error) {
      _showMessage(error.message);
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _loginWithEmailPassword() async {
    final client = _client;
    if (client == null) {
      _showMessage('Supabase 尚未初始化');
      return;
    }
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || !email.contains('@') || password.length < 6) {
      _showMessage('请输入有效邮箱和密码');
      return;
    }
    setState(() => _isBusy = true);
    try {
      await client.auth.signInWithPassword(
        email: email,
        password: password,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on AuthException catch (error) {
      _showMessage(error.message);
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Widget _buildModeSegment() {
    return CupertinoSlidingSegmentedControl<_LoginMode>(
      groupValue: _loginMode,
      thumbColor: Colors.white,
      backgroundColor: const Color(0xFFE5E7EB),
      children: const {
        _LoginMode.phone: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text('手机号'),
        ),
        _LoginMode.email: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text('邮箱'),
        ),
      },
      onValueChanged: (value) {
        if (value == null) return;
        setState(() => _loginMode = value);
      },
    );
  }

  Widget _buildPhoneLogin() {
    final canSend = _countdown == 0 && !_isBusy;
    return Column(
      children: [
        _RoundedInput(
          controller: _phoneController,
          hintText: '请输入手机号',
          keyboardType: TextInputType.phone,
          prefixIcon: CupertinoIcons.phone_fill,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _RoundedInput(
                controller: _codeController,
                hintText: '输入 6 位验证码',
                keyboardType: TextInputType.number,
                prefixIcon: CupertinoIcons.number,
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              height: 52,
              child: FilledButton(
                onPressed: canSend ? _sendPhoneCode : null,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF0B5FFF),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Text(_countdown > 0 ? '${_countdown}s' : '获取验证码'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _PrimaryActionButton(
          title: '注册/登录',
          onPressed: _canSubmitPhoneLogin ? _loginWithPhoneCode : null,
          loading: _isBusy,
        ),
      ],
    );
  }

  Widget _buildEmailLogin() {
    return Column(
      children: [
        _RoundedInput(
          controller: _emailController,
          hintText: '输入邮箱地址',
          keyboardType: TextInputType.emailAddress,
          prefixIcon: CupertinoIcons.mail_solid,
        ),
        const SizedBox(height: 10),
        CupertinoSlidingSegmentedControl<_EmailAuthMode>(
          groupValue: _emailAuthMode,
          thumbColor: Colors.white,
          backgroundColor: const Color(0xFFE5E7EB),
          children: const {
            _EmailAuthMode.otp: Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text('免密链接'),
            ),
            _EmailAuthMode.password: Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text('邮箱密码'),
            ),
          },
          onValueChanged: (value) {
            if (value == null) return;
            setState(() => _emailAuthMode = value);
          },
        ),
        if (_emailAuthMode == _EmailAuthMode.password) ...[
          const SizedBox(height: 10),
          _RoundedInput(
            controller: _passwordController,
            hintText: '输入密码',
            prefixIcon: CupertinoIcons.lock_fill,
            obscureText: true,
          ),
        ],
        const SizedBox(height: 14),
        _PrimaryActionButton(
          title: _emailAuthMode == _EmailAuthMode.otp ? '发送登录链接' : '邮箱登录',
          onPressed: _emailAuthMode == _EmailAuthMode.otp
              ? _loginWithEmailOtp
              : _loginWithEmailPassword,
          loading: _isBusy,
        ),
      ],
    );
  }

  Widget _buildThirdPartyRow() {
    return Row(
      children: [
        Expanded(
          child: _ThirdPartyButton(
            label: '微信',
            icon: CupertinoIcons.chat_bubble_2_fill,
            onTap: () => _showMessage('微信授权模拟唤起'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _ThirdPartyButton(
            label: '支付宝',
            icon: Icons.account_balance_wallet_rounded,
            onTap: () => _showMessage('支付宝授权模拟唤起'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _ThirdPartyButton(
            label: 'Apple',
            icon: Icons.apple,
            onTap: () => _showMessage('Sign in with Apple 模拟唤起'),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6FB),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: const Text('登录 / 注册'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(30),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.82),
                    borderRadius: BorderRadius.circular(30),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x17000000),
                        blurRadius: 28,
                        offset: Offset(0, 12),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '欢迎来到 Truth Stamp',
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '开启你的数字真迹之旅',
                        style: TextStyle(
                          color: Colors.blueGrey.shade600,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 14),
                      _buildModeSegment(),
                      const SizedBox(height: 14),
                      _loginMode == _LoginMode.phone
                          ? _buildPhoneLogin()
                          : _buildEmailLogin(),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              '第三方登录',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: Color(0xFF334155),
              ),
            ),
            const SizedBox(height: 10),
            _buildThirdPartyRow(),
          ],
        ),
      ),
    );
  }
}

class _RoundedInput extends StatelessWidget {
  const _RoundedInput({
    required this.controller,
    required this.hintText,
    required this.prefixIcon,
    this.keyboardType,
    this.obscureText = false,
    this.onChanged,
  });

  final TextEditingController controller;
  final String hintText;
  final IconData prefixIcon;
  final TextInputType? keyboardType;
  final bool obscureText;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(16),
      ),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        obscureText: obscureText,
        onChanged: onChanged,
        decoration: InputDecoration(
          hintText: hintText,
          border: InputBorder.none,
          prefixIcon: Icon(prefixIcon, color: const Color(0xFF64748B)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
        ),
      ),
    );
  }
}

class _PrimaryActionButton extends StatelessWidget {
  const _PrimaryActionButton({
    required this.title,
    required this.onPressed,
    required this.loading,
  });

  final String title;
  final Future<void> Function()? onPressed;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF3B82F6), Color(0xFF2563EB)],
        ),
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(
            color: Color(0x333B82F6),
            blurRadius: 18,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: FilledButton(
        onPressed: loading ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(vertical: 15),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
        child: loading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              )
            : Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
      ),
    );
  }
}

class _ThirdPartyButton extends StatelessWidget {
  const _ThirdPartyButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: const [
            BoxShadow(
              color: Color(0x14000000),
              blurRadius: 12,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          children: [
            Icon(icon, size: 20, color: const Color(0xFF0F172A)),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(
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
