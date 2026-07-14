import 'package:flutter/material.dart';

class ProfileTab extends StatelessWidget {
  const ProfileTab({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget bentoSection({
      required String title,
      required List<Widget> children,
    }) {
      return Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(28),
          boxShadow: const [
            BoxShadow(
              color: Color(0x10000000),
              blurRadius: 24,
              offset: Offset(0, 10),
            ),
          ],
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      );
    }

    Widget menuTile({
      required IconData icon,
      required String title,
      required String subtitle,
      Color iconColor = const Color(0xFF0B5FFF),
    }) {
      return Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(22),
        ),
        child: ListTile(
          leading: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: iconColor),
          ),
          title: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right_rounded),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(32),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x14000000),
                    blurRadius: 30,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Container(
                    width: 74,
                    height: 74,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [
                          Colors.green.shade200,
                          Colors.green.shade600,
                        ],
                      ),
                    ),
                    child: const Center(
                      child: Text(
                        'L',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 28,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Leon',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(18),
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
                                blurRadius: 18,
                                offset: Offset(0, 8),
                              ),
                            ],
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
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
                        const SizedBox(height: 8),
                        Text(
                          '极简、隐私优先的本地鉴伪体验',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            bentoSection(
              title: '账户与安全',
              children: [
                menuTile(
                  icon: Icons.phone_rounded,
                  title: '手机号绑定',
                  subtitle: '完善账户验证方式',
                ),
                menuTile(
                  icon: Icons.lock_rounded,
                  title: '密码管理',
                  subtitle: '更新登录与设备安全',
                ),
              ],
            ),
            const SizedBox(height: 16),
            bentoSection(
              title: '系统与合规',
              children: [
                menuTile(
                  icon: Icons.privacy_tip_rounded,
                  title: '隐私协议',
                  subtitle: '了解我们如何保护你的数据',
                ),
                menuTile(
                  icon: Icons.description_rounded,
                  title: '用户服务协议',
                  subtitle: '查看服务条款与使用规范',
                ),
                menuTile(
                  icon: Icons.info_rounded,
                  title: '关于我们',
                  subtitle: 'Truth Stamp · 版本与团队信息',
                ),
              ],
            ),
            const SizedBox(height: 16),
            bentoSection(
              title: '支持与反馈',
              children: [
                menuTile(
                  icon: Icons.help_rounded,
                  title: '帮助中心',
                  subtitle: '常见问题与使用说明',
                  iconColor: const Color(0xFF0A8F3E),
                ),
                menuTile(
                  icon: Icons.feedback_rounded,
                  title: '意见反馈',
                  subtitle: '向我们提交改进建议',
                  iconColor: const Color(0xFF0B5FFF),
                ),
                menuTile(
                  icon: Icons.system_update_alt_rounded,
                  title: '检查更新',
                  subtitle: 'App Version: 1.0.0',
                  iconColor: const Color(0xFF111827),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                color: const Color(0xFFFFF1F1),
              ),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  foregroundColor: const Color(0xFFB91C1C),
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
                onPressed: () {},
                icon: const Icon(Icons.delete_forever_rounded),
                label: const Text(
                  '注销并删除账号',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
