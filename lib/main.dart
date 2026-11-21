import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'ar/ar_bridge.dart';
import 'ui/ar_page.dart';
import 'ui/desktop_page.dart';
import 'ui/gyro_page.dart';
import 'ui/scene_loader.dart';
import 'ui/widgets.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WalkOnPhotosApp());
}

bool get isMobile =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android);

class WalkOnPhotosApp extends StatelessWidget {
  const WalkOnPhotosApp({super.key, this.forceDesktop = false});

  /// Lets widget tests exercise the desktop UI on any host.
  final bool forceDesktop;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Walk on Photos',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: kAccent,
        useMaterial3: true,
      ),
      home: HomePage(forceDesktop: forceDesktop),
    );
  }
}

enum _Mode { checking, desktop, ar, gyro }

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.forceDesktop = false});

  final bool forceDesktop;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final SceneLoader _loader = SceneLoader();
  _Mode _mode = _Mode.checking;

  @override
  void initState() {
    super.initState();
    _chooseMode();
  }

  Future<void> _chooseMode() async {
    if (widget.forceDesktop || !isMobile) {
      setState(() => _mode = _Mode.desktop);
      return;
    }
    // Sensor axes and AR framing assume portrait.
    SystemChrome.setPreferredOrientations(<DeviceOrientation>[
      DeviceOrientation.portraitUp,
    ]);
    bool ar = await isArSupported();
    if (ar) ar = await requestCameraPermission();
    if (!mounted) return;
    setState(() => _mode = ar ? _Mode.ar : _Mode.gyro);
  }

  @override
  void dispose() {
    _loader.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: switch (_mode) {
        _Mode.checking => const Center(
          child: CircularProgressIndicator(color: kAccent),
        ),
        _Mode.desktop => DesktopPage(loader: _loader),
        _Mode.ar => ArPage(loader: _loader),
        _Mode.gyro => GyroPage(loader: _loader),
      },
    );
  }
}
