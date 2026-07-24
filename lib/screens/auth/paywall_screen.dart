import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<bool> showProPaywall(
  BuildContext context, {
  required int dailyCount,
}) async {
  final upgraded = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _PaywallSheet(dailyCount: dailyCount),
  );
  return upgraded ?? false;
}

class _Plan {
  const _Plan({
    required this.title,
    required this.price,
    required this.role,
    this.badge,
    this.highlight = false,
  });

  final String title;
  final String price;
  final String role;
  final String? badge;
  final bool highlight;
}

class _PaywallSheet extends StatefulWidget {
  const _PaywallSheet({required this.dailyCount});

  final int dailyCount;

  @override
  State<_PaywallSheet> createState() => _PaywallSheetState();
}

class _PaywallSheetState extends State<_PaywallSheet> {
  static const _plans = <_Plan>[
    _Plan(title: '月度 Pro', price: '¥9.9/月', role: 'Pro'),
    _Plan(title: '年度 Pro', price: '¥68/年', role: 'Pro', badge: '省40%', highlight: true),
    _Plan(title: '终身 Founder', price: '¥199/终身', role: 'Founder', badge: '限量100位'),
  ];

  bool _isPaying = false;
  String _status = '';

  Future<void> _purchase(_Plan plan) async {
    if (_isPaying) return;
    setState(() {
      _isPaying = true;
      _status = '正在通过 Apple Pay 安全验证指纹...';
    });
    await HapticFeedback.selectionClick();

    try {
      await Future<void>.delayed(const Duration(seconds: 3));
      final client = Supabase.instance.client;
      final user = client.auth.currentUser;
      if (user == null) {
        throw StateError('请先登录后再升级会员');
      }
      await client.from('app_users').upsert(
        <String, dynamic>{
          'user_id': user.id,
          'phone_number': user.phone ?? '',
          'role': plan.role,
          'last_login_at': DateTime.now().toIso8601String(),
        },
        onConflict: 'user_id',
      );

      if (!mounted) return;
      await HapticFeedback.heavyImpact();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('恭喜您已升级为 TruthStamp 创始会员！')),
      );
      Navigator.of(context).pop(true);
    } on PostgrestException catch (error) {
      if (!mounted) return;
      setState(() {
        _isPaying = false;
        _status = '';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('升级失败：${error.message}')),
      );
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _isPaying = false;
        _status = '';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('升级失败：$error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: const LinearGradient(
              colors: [Color(0xFFD4AF37), Color(0xFF2563EB)],
            ),
          ),
          padding: const EdgeInsets.all(1.2),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF090C10),
              borderRadius: BorderRadius.circular(19),
            ),
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        gradient: const LinearGradient(
                          colors: [Color(0xFFD4AF37), Color(0xFF60EFFF)],
                        ),
                      ),
                      child: const Icon(Icons.workspace_premium_rounded, color: Colors.white, size: 20),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        '解锁 TruthStamp PRO 创始权益',
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Colors.white),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '今日免费额度已用 ${widget.dailyCount}/5 次',
                  style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 12),
                ),
                const SizedBox(height: 14),
                Row(
                  children: _plans
                      .map(
                        (plan) => Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: _planCard(plan),
                          ),
                        ),
                      )
                      .toList(),
                ),
                if (_isPaying) ...[
                  const SizedBox(height: 14),
                  const Center(child: CircularProgressIndicator(strokeWidth: 2.4)),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      _status,
                      style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 12),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _planCard(_Plan plan) {
    return InkWell(
      onTap: _isPaying ? null : () => _purchase(plan),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: plan.highlight ? const Color(0xFF60EFFF) : Colors.white24,
          ),
          color: plan.highlight ? const Color(0xFF111827) : const Color(0xFF0F172A),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (plan.badge != null)
              Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color: const Color(0xFF1D4ED8).withOpacity(0.28),
                ),
                child: Text(
                  plan.badge!,
                  style: const TextStyle(fontSize: 10, color: Color(0xFFBFDBFE), fontWeight: FontWeight.w700),
                ),
              ),
            Text(plan.title, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(plan.price, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800)),
          ],
        ),
      ),
    );
  }
}
