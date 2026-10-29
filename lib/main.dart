import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: AppColors.bg,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const PcRemoteApp());
}

class AppColors {
  static const bg = Color(0xFF0F1115);
  static const card = Color(0xFF1A1D24);
  static const button = Color(0xFF232732);
  static const accent = Color(0xFF2563EB);
  static const accentSoft = Color(0xFF3B82F6);
  static const shutdown = Color(0xFFEF4444);
  static const confirm = Color(0xFF10B981);
  static const text = Color(0xFFF3F4F6);
  static const muted = Color(0xFF9CA3AF);
}

class PcConfig {
  final String ip;
  final int port;
  final String mac;
  final String token;
  final String name;

  const PcConfig({
    required this.ip,
    required this.port,
    required this.mac,
    required this.token,
    required this.name,
  });

  factory PcConfig.defaults() => const PcConfig(
        ip: '192.168.0.10',
        port: 5050,
        mac: '',
        token: '',
        name: 'ПК',
      );

  String get baseUrl => 'http://$ip:$port';

  PcConfig copyWith({
    String? ip,
    int? port,
    String? mac,
    String? token,
    String? name,
  }) {
    return PcConfig(
      ip: ip ?? this.ip,
      port: port ?? this.port,
      mac: mac ?? this.mac,
      token: token ?? this.token,
      name: name ?? this.name,
    );
  }

  static PcConfig? fromQr(String raw) {
    try {
      final uri = Uri.parse(raw.trim());
      if (uri.scheme != 'remotepc') return null;
      final host = uri.host.isNotEmpty ? uri.host : uri.path.replaceAll('/', '');
      if (host.isEmpty) return null;
      return PcConfig(
        ip: host,
        port: uri.hasPort ? uri.port : 5050,
        token: uri.queryParameters['token'] ?? '',
        mac: (uri.queryParameters['mac'] ?? '').toUpperCase(),
        name: uri.queryParameters['name'] ?? 'ПК',
      );
    } catch (_) {
      return null;
    }
  }
}

class PcRemoteApp extends StatelessWidget {
  const PcRemoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PC Remote',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.bg,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.accent,
          secondary: AppColors.accentSoft,
          surface: AppColors.card,
          error: AppColors.shutdown,
        ),
        fontFamily: 'Segoe UI',
        useMaterial3: true,
      ),
      home: const RemoteHomePage(),
    );
  }
}

class RemoteHomePage extends StatefulWidget {
  const RemoteHomePage({super.key});

  @override
  State<RemoteHomePage> createState() => _RemoteHomePageState();
}

class _RemoteHomePageState extends State<RemoteHomePage>
    with TickerProviderStateMixin {
  PcConfig _config = PcConfig.defaults();
  bool _online = false;
  bool _sleepArmed = false;
  bool _wakeArmed = false;
  bool _pulseUnlock = false;
  int _volume = 50;
  int _shutdownLeft = 0;
  final _passwordCtrl = TextEditingController();
  Timer? _statusTimer;
  Timer? _volumeDebounce;
  Timer? _shutdownTimer;
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _load();
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _volumeDebounce?.cancel();
    _shutdownTimer?.cancel();
    _pulse.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _config = PcConfig(
        ip: p.getString('ip') ?? '192.168.0.10',
        port: p.getInt('port') ?? 5050,
        mac: p.getString('mac') ?? '',
        token: p.getString('token') ?? '',
        name: p.getString('name') ?? 'ПК',
      );
    });
    _startPolling();
    _refreshVolume();
  }

  Future<void> _save(PcConfig c) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('ip', c.ip);
    await p.setInt('port', c.port);
    await p.setString('mac', c.mac);
    await p.setString('token', c.token);
    await p.setString('name', c.name);
    setState(() => _config = c);
    _startPolling();
    _refreshVolume();
  }

  void _startPolling() {
    _statusTimer?.cancel();
    _pingStatus();
    _statusTimer = Timer.periodic(const Duration(seconds: 3), (_) => _pingStatus());
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_config.token.isNotEmpty) 'X-Token': _config.token,
      };

  Uri _uri(String path, [Map<String, String>? extra]) {
    return Uri.parse('${_config.baseUrl}$path').replace(
      queryParameters: {
        if (_config.token.isNotEmpty) 'token': _config.token,
        ...?extra,
      },
    );
  }

  Future<http.Response?> _get(String path) async {
    try {
      return await http.get(_uri(path), headers: _headers).timeout(
            const Duration(seconds: 2),
          );
    } catch (_) {
      return null;
    }
  }

  Future<http.Response?> _post(String path, [Map<String, dynamic>? body]) async {
    try {
      return await http
          .post(
            _uri(path),
            headers: _headers,
            body: jsonEncode(body ?? {}),
          )
          .timeout(const Duration(seconds: 4));
    } catch (_) {
      return null;
    }
  }

  Future<void> _pingStatus() async {
    final res = await _get('/api/status');
    final ok = res != null && res.statusCode >= 200 && res.statusCode < 300;
    if (!mounted) return;
    setState(() {
      _online = ok;
      if (ok) {
        _sleepArmed = false;
      }
    });
  }

  Future<void> _refreshVolume() async {
    final res = await _get('/api/get_volume');
    if (res == null || res.statusCode >= 300) return;
    try {
      final data = jsonDecode(res.body);
      final level = data is Map
          ? (data['level'] ?? data['volume'] ?? data['value'])
          : data;
      final v = (level is num) ? level.round() : int.tryParse('$level');
      if (v != null && mounted) {
        setState(() => _volume = v.clamp(0, 100));
      }
    } catch (_) {}
  }

  Future<void> _sleep() async {
    final res = await _post('/api/system_sleep');
    if (!mounted) return;
    setState(() {
      _sleepArmed = res != null && res.statusCode < 300;
      _wakeArmed = false;
      _online = false;
      _stopPulse();
    });
    _toast(_sleepArmed ? 'ПК уходит в сон' : 'Не удалось усыпить');
  }

  Future<void> _wake() async {
    setState(() {
      _wakeArmed = true;
      _sleepArmed = false;
    });
    final wol = await _sendMagicPacket(_config.mac);
    for (var i = 0; i < 6; i++) {
      await _post('/api/wake_burst');
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
    if (!mounted) return;
    _startPulse();
    _toast(wol ? 'Magic Packet отправлен' : 'WoL не удался — проверьте MAC');
  }

  Future<bool> _sendMagicPacket(String mac) async {
    final bytes = _parseMac(mac);
    if (bytes == null) return false;
    final packet = Uint8List(102);
    packet.fillRange(0, 6, 0xFF);
    for (var i = 0; i < 16; i++) {
      packet.setRange(6 + i * 6, 12 + i * 6, bytes);
    }
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      socket.send(packet, InternetAddress('255.255.255.255'), 9);
      socket.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  List<int>? _parseMac(String mac) {
    final parts = mac.trim().split(RegExp(r'[:\-]'));
    if (parts.length != 6) return null;
    final out = <int>[];
    for (final p in parts) {
      final v = int.tryParse(p, radix: 16);
      if (v == null || v < 0 || v > 255) return null;
      out.add(v);
    }
    return out;
  }

  void _startPulse() {
    setState(() => _pulseUnlock = true);
    _pulse.repeat(reverse: true);
  }

  void _stopPulse() {
    _pulse.stop();
    _pulse.value = 0;
    setState(() => _pulseUnlock = false);
  }

  Future<void> _unlock() async {
    final password = _passwordCtrl.text;
    if (password.isEmpty) {
      _toast('Введите пароль или PIN');
      return;
    }
    final res = await _post('/api/unlock', {'password': password});
    final ok = res != null && res.statusCode < 300;
    if (ok) {
      _passwordCtrl.clear();
      _stopPulse();
    }
    _toast(ok ? 'Команда входа отправлена' : 'Ошибка разблокировки');
  }

  void _onVolume(double v) {
    setState(() => _volume = v.round());
    _volumeDebounce?.cancel();
    _volumeDebounce = Timer(const Duration(milliseconds: 55), () async {
      await _post('/api/set_volume', {'level': _volume});
    });
  }

  Future<void> _playPause() async {
    await _post('/api/playpause');
  }

  Future<void> _mute() async {
    await _post('/api/mute');
  }

  Future<void> _shutdown() async {
    final res = await _post('/api/shutdown', {'seconds': 7, 'delay': 7});
    if (res == null || res.statusCode >= 300) {
      _toast('Не удалось выключить');
      return;
    }
    _shutdownTimer?.cancel();
    setState(() => _shutdownLeft = 7);
    _shutdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_shutdownLeft <= 1) {
        t.cancel();
        setState(() => _shutdownLeft = 0);
      } else {
        setState(() => _shutdownLeft -= 1);
      }
    });
    _toast('Выключение через 7 сек');
  }

  Future<void> _cancelShutdown() async {
    await _post('/api/cancel_shutdown');
    _shutdownTimer?.cancel();
    setState(() => _shutdownLeft = 0);
    _toast('Выключение отменено');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: AppColors.button,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _openScanner() async {
    final result = await Navigator.of(context).push<PcConfig>(
      MaterialPageRoute(builder: (_) => const QrScanPage()),
    );
    if (result != null) {
      await _save(result);
      _toast('ПК «${result.name}» привязан');
    }
  }

  Future<void> _openSettings() async {
    final result = await Navigator.of(context).push<PcConfig>(
      MaterialPageRoute(builder: (_) => SettingsPage(config: _config)),
    );
    if (result != null) {
      await _save(result);
      _toast('Настройки сохранены');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          children: [
            _StatusBar(
              name: _config.name,
              online: _online,
              onScan: _openScanner,
              onSettings: _openSettings,
            ),
            const SizedBox(height: 18),
            _Card(
              title: 'СОСТОЯНИЕ ЭКРАНА',
              child: Row(
                children: [
                  Expanded(
                    child: _ActionButton(
                      label: 'Усыпить',
                      icon: Icons.nightlight_round,
                      active: _sleepArmed,
                      onTap: _sleep,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _ActionButton(
                      label: 'Разбудить',
                      icon: Icons.wb_sunny_outlined,
                      active: _wakeArmed,
                      dimmed: _sleepArmed,
                      onTap: _wake,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            AnimatedBuilder(
              animation: _pulse,
              builder: (context, child) {
                final t = _pulseUnlock ? _pulse.value : 0.0;
                return DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: _pulseUnlock
                        ? [
                            BoxShadow(
                              color: AppColors.accentSoft.withValues(alpha: 0.18 + t * 0.42),
                              blurRadius: 18 + t * 16,
                              spreadRadius: 1 + t * 3,
                            ),
                          ]
                        : null,
                  ),
                  child: child,
                );
              },
              child: _Card(
                title: 'ВВОД ПАРОЛЯ / PIN',
                accentBorder: _pulseUnlock,
                child: Column(
                  children: [
                    TextField(
                      controller: _passwordCtrl,
                      obscureText: true,
                      style: const TextStyle(color: AppColors.text),
                      onSubmitted: (_) => _unlock(),
                      decoration: InputDecoration(
                        hintText: 'Пароль или PIN',
                        hintStyle: const TextStyle(color: AppColors.muted),
                        filled: true,
                        fillColor: AppColors.button,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _ActionButton(
                      label: 'Вход ↵',
                      icon: Icons.keyboard_return,
                      active: true,
                      color: AppColors.confirm,
                      onTap: _unlock,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            _Card(
              title: 'МЕДИА',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.volume_up, color: AppColors.muted, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        '$_volume%',
                        style: const TextStyle(
                          color: AppColors.text,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 4,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                    ),
                    child: Slider(
                      value: _volume.toDouble(),
                      min: 0,
                      max: 100,
                      divisions: 100,
                      activeColor: AppColors.accentSoft,
                      inactiveColor: AppColors.button,
                      onChanged: _onVolume,
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: _ActionButton(
                          label: 'Пауза / Плей',
                          icon: Icons.play_arrow_rounded,
                          onTap: _playPause,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _ActionButton(
                          label: 'Звук',
                          icon: Icons.volume_off_rounded,
                          onTap: _mute,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _Card(
              title: 'ВЫКЛЮЧЕНИЕ',
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.shutdown,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onPressed: _shutdown,
                      icon: const Icon(Icons.power_settings_new),
                      label: Text(
                        _shutdownLeft > 0
                            ? 'Выключение через $_shutdownLeft сек'
                            : 'Выключить ноутбук',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.text,
                        side: const BorderSide(color: Color(0xFF3A4050)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onPressed: _cancelShutdown,
                      icon: const Icon(Icons.close),
                      label: const Text('Отменить выключение'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  final String name;
  final bool online;
  final VoidCallback onScan;
  final VoidCallback onSettings;

  const _StatusBar({
    required this.name,
    required this.online,
    required this.onScan,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: online ? AppColors.confirm : AppColors.shutdown,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: (online ? AppColors.confirm : AppColors.shutdown)
                      .withValues(alpha: 0.55),
                  blurRadius: 8,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.isEmpty ? 'ПК' : name,
                  style: const TextStyle(
                    color: AppColors.text,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
                Text(
                  online ? 'В сети' : 'Спит / Офлайн',
                  style: TextStyle(
                    color: online ? AppColors.confirm : AppColors.shutdown,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onScan,
            tooltip: 'Сканировать QR',
            icon: const Icon(Icons.qr_code_scanner, color: AppColors.text),
          ),
          IconButton(
            onPressed: onSettings,
            tooltip: 'Настройки',
            icon: const Icon(Icons.settings_outlined, color: AppColors.muted),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final String title;
  final Widget child;
  final bool accentBorder;

  const _Card({
    required this.title,
    required this.child,
    this.accentBorder = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: accentBorder ? AppColors.accentSoft : const Color(0xFF2A2F3A),
          width: accentBorder ? 1.6 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: AppColors.muted,
              fontSize: 12,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool active;
  final bool dimmed;
  final Color? color;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.active = false,
    this.dimmed = false,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final bg = active ? (color ?? AppColors.accent) : AppColors.button;
    return Opacity(
      opacity: dimmed && !active ? 0.38 : 1,
      child: SizedBox(
        height: 52,
        child: FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: bg,
            foregroundColor: AppColors.text,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          onPressed: dimmed && !active ? null : onTap,
          icon: Icon(icon, size: 20),
          label: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }
}

class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  final _controller = MobileScannerController();
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final code in capture.barcodes) {
      final raw = code.rawValue;
      if (raw == null) continue;
      final cfg = PcConfig.fromQr(raw);
      if (cfg != null) {
        _handled = true;
        Navigator.of(context).pop(cfg);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Сканер QR'),
        backgroundColor: Colors.black,
      ),
      body: Stack(
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    color: Colors.black54,
                    child: const Text(
                      'QR формата\nremotepc://IP:PORT?token=…&mac=…&name=…',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  final PcConfig config;
  const SettingsPage({super.key, required this.config});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _ip;
  late final TextEditingController _port;
  late final TextEditingController _mac;
  late final TextEditingController _token;
  late final TextEditingController _name;

  @override
  void initState() {
    super.initState();
    _ip = TextEditingController(text: widget.config.ip);
    _port = TextEditingController(text: '${widget.config.port}');
    _mac = TextEditingController(text: widget.config.mac);
    _token = TextEditingController(text: widget.config.token);
    _name = TextEditingController(text: widget.config.name);
  }

  @override
  void dispose() {
    _ip.dispose();
    _port.dispose();
    _mac.dispose();
    _token.dispose();
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final port = int.tryParse(_port.text.trim()) ?? 5050;
    Navigator.of(context).pop(
      PcConfig(
        ip: _ip.text.trim().isEmpty ? '192.168.0.10' : _ip.text.trim(),
        port: port,
        mac: _mac.text.trim().toUpperCase(),
        token: _token.text.trim(),
        name: _name.text.trim().isEmpty ? 'ПК' : _name.text.trim(),
      ),
    );
  }

  Widget _field(String label, TextEditingController c, {bool obscure = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        obscureText: obscure,
        style: const TextStyle(color: AppColors.text),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: AppColors.muted),
          filled: true,
          fillColor: AppColors.button,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Настройки ПК'),
        backgroundColor: AppColors.bg,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _field('Имя ПК', _name),
          _field('IP-адрес', _ip),
          _field('Порт', _port),
          _field('MAC-адрес (XX:XX:XX:XX:XX:XX)', _mac),
          _field('Токен', _token, obscure: true),
          const SizedBox(height: 8),
          SizedBox(
            height: 52,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: _save,
              child: const Text('Сохранить'),
            ),
          ),
        ],
      ),
    );
  }
}
