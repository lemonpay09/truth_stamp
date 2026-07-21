import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'screens/main_navigation_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: 'https://iuqabsyyiasobbgizrtp.supabase.co',
    publishableKey: 'sb_publishable_s_-U19FIhyJ3NYvL4glR-Q_YFViYRvW',
  );

  List<CameraDescription> cameras = const [];
  try {
    cameras = await availableCameras();
  } on CameraException catch (error) {
    debugPrint(
        'Failed to enumerate cameras: ${error.description ?? error.code}');
  }

  runApp(TruthStampApp(cameras: cameras));
}

class TruthStampApp extends StatelessWidget {
  const TruthStampApp({
    super.key,
    required this.cameras,
  });

  final List<CameraDescription> cameras;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Truth Stamp',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0A8F3E),
          surface: const Color(0xFFF7F8FA),
        ),
        scaffoldBackgroundColor: const Color(0xFFF7F8FA),
        useMaterial3: true,
      ),
      home: MainNavigationScreen(cameras: cameras),
    );
  }
}
