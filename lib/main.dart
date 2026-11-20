import 'dart:async';
import 'dart:io';
import 'dart:math' show max, min, pi;

import 'package:flutter/cupertino.dart' show
        CupertinoAlertDialog,
        CupertinoDialogAction,
        CupertinoIcons,
        CupertinoSlidingSegmentedControl,
        CupertinoSwitch,
        CupertinoTheme,
        CupertinoThemeData,
        showCupertinoDialog;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import 'catalog.dart';
import 'update.dart';

const brandPurple = Color(0xFF5B14C8);
const brandYellow = Color(0xFFFFE600);

/// Pilihan warna aksen (Pengaturan → Warna Aksen).
const accentChoices = <(String, Color)>[
  ('Ungu Importbox', Color(0xFF5B14C8)),
  ('Oranye', Color(0xFFEE4D2D)),
  ('Biru', Color(0xFF1E6FE0)),
  ('Hijau', Color(0xFF14A26B)),
  ('Merah Muda', Color(0xFFE0457B)),
  ('Tosca', Color(0xFF0E94A3)),
];

/// Warna aksen aktif. Di mode gelap dicerahkan sedikit agar tetap terbaca.
Color get accent {
  final c = accentChoices[store.accentIdx.clamp(0, accentChoices.length - 1)].$2;
  if (!isDark) return c;
  final h = HSLColor.fromColor(c);
  return h.withLightness(max(h.lightness, 0.56)).toColor();
}

Color get accentDark {
  final h = HSLColor.fromColor(accent);
  return h.withLightness((h.lightness - 0.09).clamp(0.0, 1.0)).toColor();
}
const pageSize = 40;

// ================= PALET (terang / gelap) =================
bool get isDark => store.dark;
Color get cBg => isDark ? const Color(0xFF121212) : const Color(0xFFF5F5F5);
Color get cSurface => isDark ? const Color(0xFF1E1E1E) : Colors.white;
Color get cSurface2 => isDark ? const Color(0xFF262626) : const Color(0xFFFAFAFA);
Color get cLine => isDark ? const Color(0xFF3A3A3A) : const Color(0xFFEEEEEE);
Color get cBar => isDark ? const Color(0xFF242424) : const Color(0xFFEDEDED);
Color get cText => isDark ? const Color(0xFFEEEEEE) : Colors.black87;
Color get cSub => isDark ? Colors.white60 : Colors.black54;
Color get cMute => isDark ? Colors.white38 : Colors.black45;
Color get cPriceBg => isDark ? const Color(0xFF2B1F1C) : const Color(0xFFFFF8F6);
Color get cPriceLine => isDark ? const Color(0xFF4A2E27) : const Color(0xFFFFE0D8);
Color get cPlaceholder => isDark ? const Color(0xFF2A2A2A) : const Color(0xFFEEEEEE);

String fmtTime(DateTime? d) => d == null
    ? '-'
    : '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

String intervalLabel(int m) => m >= 60 ? '${m ~/ 60} jam' : '$m menit';

// ================= LABEL PRODUK =================
/// Urutan tampil label pada kartu / detail produk.
const labelOrder = ['baru', 'harga', 'tersedia', 'varian'];

/// tipe perubahan -> (teks label, warna, ikon)
const Map<String, (String, Color, IconData)> labelStyle = {
  'baru': ('BARU', Color(0xFFEE4D2D), Icons.fiber_new),
  'harga': ('HARGA BERUBAH', Color(0xFF1E88E5), Icons.price_change),
  'tersedia': ('TERSEDIA LAGI', Color(0xFF43A047), Icons.check_circle),
  'varian': ('VARIAN BERUBAH', Color(0xFF8E24AA), Icons.palette),
};

// ================= STORE =================
/// Satu baris di keranjang pesanan (produk + varian + jumlah).
class CartLine {
  CartLine(this.pkey, this.name, this.variant, this.qty);
  final String pkey, name;
  final String? variant;
  int qty;

  Map<String, dynamic> toJson() => {'k': pkey, 'n': name, 'v': variant, 'q': qty};
  factory CartLine.fromJson(Map<String, dynamic> j) =>
      CartLine('${j['k']}', '${j['n']}', j['v'] as String?, (j['q'] as num?)?.toInt() ?? 1);
}

class CatalogStore extends ChangeNotifier {
  final svc = CatalogService();
  List<Product> products = [];
  List<Change> changes = [];
  int unread = 0;
  int intervalMin = 60;
  int labelDays = 3; // label produk hilang otomatis setelah N hari
  int accentIdx = 0;
  bool notif = true;
  bool dark = false;
  Set<String> favs = {};
  List<CartLine> cart = [];
  String waNumber = '';
  String defaultWa = ''; // nomor bawaan dari server (Apps Script)
  bool loading = false;
  String? error;
  DateTime? lastSync;
  Timer? _timer;
  Timer? _ticker;
  Map<String, Set<String>> _labels = {};
  String _labelSig = '';

  List<String> get sheets => products.map((e) => e.sheet).toSet().toList();

  /// Hitung label yang masih aktif (belum lewat [labelDays]).
  /// true bila ada label yang muncul / kedaluwarsa sejak hitungan terakhir.
  bool _refreshLabels() {
    final now = DateTime.now();
    final ttl = Duration(days: labelDays);
    final m = <String, Set<String>>{};
    for (final c in changes) {
      if (!labelStyle.containsKey(c.type) || now.difference(c.at) >= ttl) continue;
      (m[c.product.toLowerCase()] ??= {}).add(c.type);
    }
    final sig = (m.entries.map((e) => '${e.key}:${(e.value.toList()..sort()).join(',')}').toList()
          ..sort())
        .join(';');
    final changed = sig != _labelSig;
    _labels = m;
    _labelSig = sig;
    return changed;
  }

  /// Label aktif untuk satu produk, urut sesuai [labelOrder].
  List<String> labelsOf(Product p) {
    final s = _labels[p.name.toLowerCase()];
    if (s == null) return const [];
    return [
      for (final t in labelOrder)
        if (s.contains(t) && !(t == 'tersedia' && p.sold)) t,
    ];
  }

  Set<String> get newKeys => {
        for (final e in _labels.entries)
          if (e.value.contains('baru')) e.key,
      };

  Future<void> init() async {
    products = await svc.loadCache();
    changes = await svc.loadChanges();
    final m = await svc.loadMeta();
    intervalMin = m['v'] == 2 ? ((m['interval'] as int?) ?? 60) : 60;
    favs = {...((m['favs'] as List?) ?? []).map((e) => '$e')};
    cart = [
      for (final e in (m['cart'] as List?) ?? [])
        CartLine.fromJson(Map<String, dynamic>.from(e as Map))
    ];
    waNumber = (m['wa'] as String?) ?? '';
    defaultWa = (m['waDefault'] as String?) ?? '';
    dark = (m['dark'] as bool?) ?? false;
    unread = (m['unread'] as int?) ?? 0;
    labelDays = (m['labelDays'] as int?) ?? 3;
    notif = (m['notif'] as bool?) ?? true;
    accentIdx = (m['accent'] as int?) ?? 0;
    final ls = m['lastSync'] as String?;
    if (ls != null) lastSync = DateTime.tryParse(ls);
    _refreshLabels();
    notifyListeners();
    // cek tiap 30 detik: label yang sudah lewat waktunya hilang sendiri
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_refreshLabels()) notifyListeners();
    });
    await refresh();
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer.periodic(Duration(minutes: intervalMin), (_) => refresh());
  }

  void setInterval(int m) {
    intervalMin = m;
    _schedule();
    _saveMeta();
    notifyListeners();
  }

  void setDark(bool v) {
    dark = v;
    _saveMeta();
    notifyListeners();
  }

  void setLabelDays(int d) {
    labelDays = d;
    _refreshLabels();
    _saveMeta();
    notifyListeners();
  }

  void setAccent(int i) {
    accentIdx = i;
    _saveMeta();
    notifyListeners();
  }

  void setNotif(bool v) {
    notif = v;
    _saveMeta();
    notifyListeners();
  }

  Future<void> _saveMeta() => svc.saveMeta({
        'v': 2,
        'favs': favs.toList(),
        'cart': cart.map((e) => e.toJson()).toList(),
        'wa': waNumber,
        'waDefault': defaultWa,
        'dark': dark,
        'interval': intervalMin,
        'labelDays': labelDays,
        'notif': notif,
        'accent': accentIdx,
        'lastSync': lastSync?.toIso8601String(),
        'unread': unread,
      });

  Future<void> refresh() async {
    if (loading) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final neu = await svc.fetch();
      if (products.isNotEmpty) {
        final ch = diffCatalog(products, neu);
        if (ch.isNotEmpty) {
          changes = [...ch, ...changes].take(300).toList();
          unread += ch.length;
          await svc.saveChanges(changes);
          _notify(ch);
        }
      }
      _refreshLabels();
      products = neu;
      await svc.saveCache(neu);
      lastSync = DateTime.now();
      await _saveMeta();
    } catch (e) {
      error = '$e';
    }
    loading = false;
    notifyListeners();
  }

  void _notify(List<Change> ch) {
    if (!notif) return;
    if (ch.length <= 3) {
      for (final c in ch) {
        LocalNotification(title: '${_label(c.type)}: ${c.product}', body: c.detail).show();
      }
    } else {
      LocalNotification(
        title: '${ch.length} update katalog supplier',
        body: ch.take(3).map((c) => '${_label(c.type)}: ${c.product}').join('\n'),
      ).show();
    }
  }

  // ---------- keranjang pesanan (lokal) ----------
  int get cartCount => cart.fold(0, (a, l) => a + l.qty);

  Product? productOf(CartLine l) {
    for (final p in products) {
      if (p.key == l.pkey) return p;
    }
    return null;
  }

  void addToCart(Product p, String? variant, int qty) {
    final i = cart.indexWhere((l) => l.pkey == p.key && l.variant == variant);
    if (i >= 0) {
      cart[i].qty = (cart[i].qty + qty).clamp(1, 999);
    } else {
      cart.add(CartLine(p.key, p.name, variant, qty.clamp(1, 999)));
    }
    _saveMeta();
    notifyListeners();
  }

  void setQty(CartLine l, int q) {
    if (q < 1) {
      cart.remove(l);
    } else {
      l.qty = q.clamp(1, 999);
    }
    _saveMeta();
    notifyListeners();
  }

  void clearCart() {
    cart.clear();
    _saveMeta();
    notifyListeners();
  }

  void setDefaultWa(String v) {
    if (v == defaultWa) return;
    defaultWa = v;
    _saveMeta();
    notifyListeners();
  }

  void setWa(String v) {
    waNumber = v;
    _saveMeta();
  }

  void toggleFav(Product p) {
    favs.contains(p.key) ? favs.remove(p.key) : favs.add(p.key);
    _saveMeta();
    notifyListeners();
  }

  void markRead() {
    unread = 0;
    _saveMeta();
    notifyListeners();
  }
}

String _label(String t) => const {
      'baru': 'Produk baru',
      'harga': 'Harga berubah',
      'sold': 'SOLD',
      'tersedia': 'Tersedia lagi',
      'varian': 'Varian berubah',
      'hapus': 'Dihapus',
    }[t] ??
    t;

final store = CatalogStore();

/// Pasang ikon Importbox ke jendela & taskbar saat aplikasi berjalan.
/// (Tidak bergantung pada resource .exe, jadi langsung berlaku tanpa rebuild ikon.)
Future<void> _applyWindowIcon() async {
  try {
    final dir = File(Platform.resolvedExecutable).parent.path;
    final ico = '$dir\\data\\flutter_assets\\assets\\logo\\app_icon.ico';
    final ada = File(ico).existsSync();
    debugPrint('[ikon] $ico ada=$ada');
    if (ada) await windowManager.setIcon(ico);
  } catch (e) {
    debugPrint('[ikon] gagal: $e');
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // jendela tanpa title bar bawaan Windows: header aplikasi jadi title bar
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      title: 'Katalog Importbox',
      minimumSize: Size(1000, 640),
      center: true,
      titleBarStyle: TitleBarStyle.hidden,
    ),
    () async {
      await windowManager.maximize(); // layar penuh (ubah/hapus baris ini bila tidak mau)
      await windowManager.show();
      await windowManager.focus();
      await _applyWindowIcon();
    },
  );
  await localNotifier.setup(
    appName: 'Katalog Importbox',
    shortcutPolicy: ShortcutPolicy.requireCreate,
  );
  runApp(const App());
  store.init();
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (context, _) => MaterialApp(
          title: 'Katalog Importbox',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorSchemeSeed: accent,
            brightness: store.dark ? Brightness.dark : Brightness.light,
            scaffoldBackgroundColor: cBg,
            useMaterial3: true,
            fontFamily: 'Inter',
          ),
          home: const SplashGate(),
        ),
      );
}

Future<void> toggleMaximize() async => (await windowManager.isMaximized())
    ? windowManager.unmaximize()
    : windowManager.maximize();

// ================= TOMBOL KONTROL JENDELA (kustom) =================
enum _Glyph { minimize, maximize, restore, close }

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.g, this.color);
  final _Glyph g;
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final c = s.center(Offset.zero);
    const r = 5.0;
    switch (g) {
      case _Glyph.minimize:
        canvas.drawLine(Offset(c.dx - r, c.dy), Offset(c.dx + r, c.dy), p);
      case _Glyph.maximize:
        canvas.drawRRect(
            RRect.fromRectAndRadius(
                Rect.fromCenter(center: c, width: r * 2, height: r * 2), const Radius.circular(1.5)),
            p);
      case _Glyph.restore:
        canvas.drawRRect(
            RRect.fromRectAndRadius(
                Rect.fromLTWH(c.dx - r, c.dy - r + 2.2, r * 2 - 2.2, r * 2 - 2.2),
                const Radius.circular(1.5)),
            p);
        final path = Path()
          ..moveTo(c.dx - r + 2.2, c.dy - r + 2.2 - 0)
          ..lineTo(c.dx - r + 2.2, c.dy - r)
          ..lineTo(c.dx + r, c.dy - r)
          ..lineTo(c.dx + r, c.dy + r - 2.2)
          ..lineTo(c.dx + r - 2.2, c.dy + r - 2.2);
        canvas.drawPath(path, p);
      case _Glyph.close:
        canvas.drawLine(Offset(c.dx - r + 0.5, c.dy - r + 0.5), Offset(c.dx + r - 0.5, c.dy + r - 0.5), p);
        canvas.drawLine(Offset(c.dx + r - 0.5, c.dy - r + 0.5), Offset(c.dx - r + 0.5, c.dy + r - 0.5), p);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter o) => o.g != g || o.color != color;
}

class _WinBtn extends StatefulWidget {
  const _WinBtn(this.glyph, this.onTap, {this.danger = false, this.tooltip});
  final _Glyph glyph;
  final VoidCallback onTap;
  final bool danger;
  final String? tooltip;
  @override
  State<_WinBtn> createState() => _WinBtnState();
}

class _WinBtnState extends State<_WinBtn> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final bg = !_hover
        ? Colors.transparent
        : widget.danger
            ? const Color(0xFFE5484D)
            : Colors.white.withValues(alpha: 0.2);
    return Tooltip(
      message: widget.tooltip ?? '',
      waitDuration: const Duration(milliseconds: 700),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 110),
            width: 38,
            height: 30,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
            child: CustomPaint(painter: _GlyphPainter(widget.glyph, Colors.white)),
          ),
        ),
      ),
    );
  }
}

class _WinControls extends StatefulWidget {
  const _WinControls();
  @override
  State<_WinControls> createState() => _WinControlsState();
}

class _WinControlsState extends State<_WinControls> with WindowListener {
  bool _max = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((v) {
      if (mounted) setState(() => _max = v);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _max = true);
  @override
  void onWindowUnmaximize() => setState(() => _max = false);

  @override
  Widget build(BuildContext context) => _Glass(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _WinBtn(_Glyph.minimize, windowManager.minimize, tooltip: 'Kecilkan'),
          _WinBtn(_max ? _Glyph.restore : _Glyph.maximize, toggleMaximize,
              tooltip: _max ? 'Kembalikan' : 'Layar penuh'),
          _WinBtn(_Glyph.close, windowManager.close, danger: true, tooltip: 'Tutup'),
        ]),
      );
}

// ================= KOMPONEN HEADER (kapsul kaca ala iOS) =================
class _Glass extends StatelessWidget {
  const _Glass({required this.child, this.padding = const EdgeInsets.all(3)});
  final Widget child;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(24),
        ),
        child: child,
      );
}

class _HdrBtn extends StatefulWidget {
  const _HdrBtn({required this.child, required this.onTap, this.tooltip});
  final Widget child;
  final VoidCallback? onTap;
  final String? tooltip;
  @override
  State<_HdrBtn> createState() => _HdrBtnState();
}

class _HdrBtnState extends State<_HdrBtn> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) => Tooltip(
        message: widget.tooltip ?? '',
        waitDuration: const Duration(milliseconds: 600),
        child: MouseRegion(
          cursor: widget.onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 40,
              height: 40,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _hover && widget.onTap != null
                    ? Colors.white.withValues(alpha: 0.22)
                    : Colors.transparent,
              ),
              child: widget.child,
            ),
          ),
        ),
      );
}

// ================= TOMBOL SYNC (ikon berputar saat memuat) =================
class _SyncButton extends StatefulWidget {
  const _SyncButton();
  @override
  State<_SyncButton> createState() => _SyncButtonState();
}

class _SyncButtonState extends State<_SyncButton> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void initState() {
    super.initState();
    store.addListener(_onStore);
    _onStore();
  }

  void _onStore() {
    if (store.loading) {
      if (!_c.isAnimating) {
        _c.value = 0;
        _c.repeat();
      }
    } else if (_c.isAnimating) {
      _c.forward(); // selesaikan putaran yang berjalan, lalu berhenti mulus
    }
  }

  @override
  void dispose() {
    store.removeListener(_onStore);
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (context, _) => _HdrBtn(
          tooltip: store.loading
              ? 'Menyinkronkan data…'
              : 'Sync sekarang\nTerakhir: ${fmtTime(store.lastSync)}',
          onTap: store.loading ? null : store.refresh,
          child: SizedBox(
            width: 32,
            height: 32,
            child: Stack(alignment: Alignment.center, children: [
              if (store.loading)
                const SizedBox(
                  width: 32,
                  height: 32,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    strokeCap: StrokeCap.round,
                    color: brandYellow,
                    backgroundColor: Colors.white24,
                  ),
                ),
              RotationTransition(
                turns: _c,
                child: const Icon(Icons.sync, color: Colors.white, size: 20),
              ),
            ]),
          ),
        ),
      );
}

// ================= SPLASH SCREEN =================
class SplashGate extends StatefulWidget {
  const SplashGate({super.key});
  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate> {
  bool _done = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 2400), () {
      if (mounted) setState(() => _done = true);
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 550),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        child: _done
            ? const HomePage(key: ValueKey('home'))
            : const _Splash(key: ValueKey('splash')),
      );
}

class _Splash extends StatefulWidget {
  const _Splash({super.key});
  @override
  State<_Splash> createState() => _SplashState();
}

class _SplashState extends State<_Splash> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final logo = CurvedAnimation(parent: _c, curve: const Interval(0, 0.7, curve: Curves.easeOutBack));
    final fade = CurvedAnimation(parent: _c, curve: const Interval(0, 0.5, curve: Curves.easeOut));
    final text = CurvedAnimation(parent: _c, curve: const Interval(0.5, 1, curve: Curves.easeOut));
    return Scaffold(
      backgroundColor: const Color(0xFF0F0A22),
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.15),
            radius: 0.95,
            colors: [Color(0xFF2A1466), Color(0xFF0F0A22)],
          ),
        ),
        child: Column(children: [
          SizedBox(
            height: 46,
            child: Row(children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onDoubleTap: toggleMaximize,
                  child: const DragToMoveArea(child: SizedBox.expand()),
                ),
              ),
              const Padding(padding: EdgeInsets.only(right: 10), child: _WinControls()),
            ]),
          ),
          Expanded(
            child: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                FadeTransition(
                  opacity: fade,
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.8, end: 1).animate(logo),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(56),
                        boxShadow: [
                          BoxShadow(
                              color: brandPurple.withValues(alpha: 0.55),
                              blurRadius: 80,
                              spreadRadius: 4),
                        ],
                      ),
                      child: Image.asset('assets/logo/logo.png', width: 230, height: 230),
                    ),
                  ),
                ),
                const SizedBox(height: 36),
                FadeTransition(
                  opacity: text,
                  child: Column(children: [
                    const Text('Katalog Importbox',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.3)),
                    const SizedBox(height: 6),
                    const Text('Katalog supplier, selalu terbaru',
                        style: TextStyle(color: Colors.white60, fontSize: 13)),
                    const SizedBox(height: 28),
                    SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.5, color: brandYellow, backgroundColor: Colors.white12),
                    ),
                  ]),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

// ================= HOME =================
enum Sort { katalog, terbaru, murah, mahal }

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _q = '';
  String? _cat;
  Sort _sort = Sort.katalog;
  bool _hideSold = false;
  bool _onlySold = false; // tampilkan produk SOLD saja
  bool _favOnly = false;
  int _page = 0;
  int? _min, _max;
  final _minC = TextEditingController();
  final _maxC = TextEditingController();
  final _qC = TextEditingController();
  final _qF = FocusNode();

  @override
  void initState() {
    super.initState();
    _qF.addListener(() {
      if (mounted) setState(() {});
    });
    UpdateService.onSupplierWa = store.setDefaultWa;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) UpdateService.checkOnStart(context);
    });
  }

  @override
  void dispose() {
    _qC.dispose();
    _qF.dispose();
    _minC.dispose();
    _maxC.dispose();
    super.dispose();
  }

  void _set(VoidCallback f) => setState(() {
        f();
        _page = 0;
      });

  List<Product> get _view {
    final words = _q.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    var l = store.products.where((p) {
      if (_cat != null && p.sheet != _cat) return false;
      if (_onlySold && !p.sold) return false;
      if (_hideSold && !_onlySold && p.sold) return false;
      if (_favOnly && !store.favs.contains(p.key)) return false;
      if (_min != null && (p.grosir ?? 0) < _min!) return false;
      if (_max != null && (p.grosir == null || p.grosir! > _max!)) return false;
      final hay = '${p.name} ${p.variants.join(' ')} ${p.sheet} ${p.note ?? ''}'.toLowerCase();
      return words.every(hay.contains);
    }).toList();
    switch (_sort) {
      case Sort.murah:
        l.sort((a, b) => (a.grosir ?? (1 << 40)).compareTo(b.grosir ?? (1 << 40)));
      case Sort.mahal:
        l.sort((a, b) => (b.grosir ?? -1).compareTo(a.grosir ?? -1));
      case Sort.terbaru:
        final nk = store.newKeys;
        bool isNew(Product p) => nk.contains(p.name.toLowerCase());
        l = l.reversed.toList();
        l = [...l.where(isNew), ...l.where((p) => !isNew(p))];
      case Sort.katalog:
        break;
    }
    return l;
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): _qF.requestFocus,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): _qF.requestFocus,
      },
      child: Focus(autofocus: true, child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final items = _view;
        final pages = (items.length / pageSize).ceil().clamp(1, 9999);
        final page = _page.clamp(0, pages - 1);
        final shown = items.skip(page * pageSize).take(pageSize).toList();
        return Scaffold(
          body: Column(children: [
            _header(context),
            if (store.error != null)
              Container(
                width: double.infinity,
                color: Colors.red.shade50,
                padding: const EdgeInsets.all(8),
                child: Text(store.error!, style: TextStyle(color: Colors.red.shade800)),
              ),
            Expanded(
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _sidebar(),
                Expanded(
                  child: Column(children: [
                    _sortBar(pages, page, items.length),
                    Expanded(
                      child: store.products.isEmpty
                          ? Center(
                              child: store.loading
                                  ? const Column(mainAxisSize: MainAxisSize.min, children: [
                                      CircularProgressIndicator(),
                                      SizedBox(height: 12),
                                      Text('Mengunduh katalog… (pertama kali bisa agak lama)'),
                                    ])
                                  : const Text('Belum ada data'))
                          : shown.isEmpty
                              ? const Center(child: Text('Tidak ada produk yang cocok'))
                              : CustomScrollView(
                                  key: ValueKey('$page-$_cat-$_q-$_sort-$_onlySold-$_hideSold-$_favOnly'),
                                  slivers: [
                                    SliverPadding(
                                      padding: const EdgeInsets.fromLTRB(12, 8, 20, 8),
                                      sliver: SliverGrid(
                                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                                          maxCrossAxisExtent: 204,
                                          mainAxisExtent: 316,
                                          crossAxisSpacing: 16,
                                          mainAxisSpacing: 16,
                                        ),
                                        delegate: SliverChildBuilderDelegate(
                                          (_, i) => _Card(shown[i]),
                                          childCount: shown.length,
                                        ),
                                      ),
                                    ),
                                    if (pages > 1) SliverToBoxAdapter(child: _pager(pages, page)),
                                    const SliverToBoxAdapter(child: SizedBox(height: 32)),
                                  ],
                                ),
                    ),
                  ]),
                ),
              ]),
            ),
          ]),
        );
      },
    );
  }

  // ---------- kolom pencarian ----------
  Widget _searchBox() {
    final focus = _qF.hasFocus;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          _qC.clear();
          _set(() => _q = '');
          _qF.unfocus();
        },
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        height: 44,
        decoration: BoxDecoration(
          color: cSurface,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: focus
                  ? brandYellow.withValues(alpha: 0.6)
                  : Colors.black.withValues(alpha: 0.14),
              blurRadius: focus ? 0 : 10,
              spreadRadius: focus ? 3 : 0,
              offset: focus ? Offset.zero : const Offset(0, 2),
            ),
          ],
        ),
        child: Row(children: [
          const SizedBox(width: 14),
          Icon(CupertinoIcons.search, size: 18, color: focus ? accent : cMute),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _qC,
              focusNode: _qF,
              onChanged: (v) => _set(() => _q = v),
              cursorColor: accent,
              style: TextStyle(color: cText, fontSize: 14.5),
              decoration: InputDecoration(
                hintText: 'Cari nama produk, varian, atau kategori',
                hintStyle: TextStyle(color: cMute, fontSize: 14.5),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 13),
              ),
            ),
          ),
          if (_q.isNotEmpty) ...[
            Text('${_view.length} hasil', style: TextStyle(fontSize: 12, color: cSub)),
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Hapus pencarian (Esc)',
              visualDensity: VisualDensity.compact,
              onPressed: () {
                _qC.clear();
                _set(() => _q = '');
              },
              icon: Icon(CupertinoIcons.xmark_circle_fill, size: 18, color: cMute),
            ),
            const SizedBox(width: 4),
          ] else if (!focus)
            Container(
              margin: const EdgeInsets.only(right: 12),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                border: Border.all(color: cLine),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text('Ctrl K', style: TextStyle(fontSize: 11, color: cMute)),
            )
          else
            const SizedBox(width: 12),
        ]),
      ),
    );
  }

  // ---------- header (satu baris: logo · pencarian · aksi · kontrol jendela) ----------
  Widget _header(BuildContext context) => Container(
        height: 74,
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [accentDark, accent]),
        ),
        padding: const EdgeInsets.fromLTRB(24, 0, 16, 0),
        child: Row(children: [
          DragToMoveArea(
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Image.asset('assets/logo/logo_mark.png',
                  width: 42, height: 42, filterQuality: FilterQuality.high),
              const SizedBox(width: 10),
              const Text('Katalog Importbox',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 21,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.4)),
            ]),
          ),
          const DragToMoveArea(child: SizedBox(width: 40, height: 74)),
          // ruang kosong di sekitar kolom pencarian bisa dipakai untuk menyeret jendela
          Expanded(
            child: Stack(children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onDoubleTap: toggleMaximize,
                  child: const DragToMoveArea(child: SizedBox.expand()),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1100),
                  child: _searchBox(),
                ),
              ),
            ]),
          ),
          const DragToMoveArea(child: SizedBox(width: 32, height: 74)),
          _Glass(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const _SyncButton(),
              Builder(
                builder: (ctx) => _HdrBtn(
                  tooltip: 'Interval cek otomatis',
                  onTap: () => showPopover(ctx,
                      width: 230,
                      height: 232,
                      arrowColor: cSurface,
                      builder: (_) => const _IntervalPanel()),
                  child: const Icon(CupertinoIcons.clock, color: Colors.white, size: 20),
                ),
              ),
              _Bump(
                key: cartKey,
                child: Badge(
                isLabelVisible: store.cartCount > 0,
                label: Text('${store.cartCount}'),
                backgroundColor: brandYellow,
                textColor: Colors.black87,
                offset: const Offset(-2, 2),
                child: Builder(
                  builder: (ctx) => _HdrBtn(
                    tooltip: 'Keranjang pesanan',
                    onTap: () => showPopover(ctx,
                        width: 480,
                        height: 4000, // otomatis dipotong sampai batas bawah layar
                        arrowColor: cSurface,
                        builder: (_) => const _CartPanel()),
                    child: const Icon(CupertinoIcons.cart_fill, color: Colors.white, size: 20),
                  ),
                ),
              )),
              Badge(
                isLabelVisible: store.unread > 0,
                label: Text('${store.unread}'),
                backgroundColor: brandYellow,
                textColor: Colors.black87,
                offset: const Offset(-2, 2),
                child: Builder(
                  builder: (ctx) => _HdrBtn(
                    tooltip: 'Update produk',
                    onTap: () {
                      showPopover(ctx,
                          width: 460,
                          height: 4000, // otomatis sampai batas bawah layar
                          arrowColor: accent,
                          builder: (_) => const _UpdatesPanel());
                      store.markRead();
                    },
                    child: const Icon(CupertinoIcons.bell_fill, color: Colors.white, size: 19),
                  ),
                ),
              ),
              Builder(
                builder: (ctx) => _HdrBtn(
                  tooltip: 'Pengaturan',
                  onTap: () => showPopover(ctx,
                      width: 400,
                      height: 4000, // batas maks.; tinggi sebenarnya mengikuti isi
                      fit: true,
                      arrowColor: cSurface,
                      builder: (_) => const _SettingsPanel()),
                  child: const Icon(CupertinoIcons.gear_alt_fill, color: Colors.white, size: 20),
                ),
              ),
            ]),
          ),
          const DragToMoveArea(child: SizedBox(width: 20, height: 74)),
          const _WinControls(),
        ]),
      );

  // ---------- sidebar (gaya iOS) ----------
  Widget _sidebar() {
    final counts = <String, int>{};
    for (final p in store.products) {
      counts[p.sheet] = (counts[p.sheet] ?? 0) + 1;
    }

    Widget header(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 8, 8),
          child: Text(t,
              style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.7, color: cSub)),
        );

    Widget navItem(bool sel, VoidCallback onTap, String label, String count, {Widget? leading}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Material(
            color: sel ? accent.withValues(alpha: 0.12) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(children: [
                  if (leading != null) ...[leading, const SizedBox(width: 8)],
                  Expanded(
                    child: Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                            color: sel ? accent : cText)),
                  ),
                  Text(count, style: TextStyle(fontSize: 11, color: sel ? accent : cMute)),
                ]),
              ),
            ),
          ),
        );

    return Container(
      width: 244,
      height: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 18, 6, 16),
      child: ListView(children: [
        header('KATEGORI'),
        navItem(_cat == null && !_favOnly, () => _set(() {
              _cat = null;
              _favOnly = false;
            }), 'Semua Produk', '${store.products.length}'),
        navItem(_favOnly, () => _set(() {
              _favOnly = true;
              _cat = null;
            }), 'Favorit Saya', '${store.favs.length}',
            leading: Icon(CupertinoIcons.heart_fill, size: 15, color: Colors.red.shade400)),
        for (final s in store.sheets)
          navItem(_cat == s && !_favOnly, () => _set(() {
                _cat = s;
                _favOnly = false;
              }), s, '${counts[s] ?? 0}'),
        const SizedBox(height: 20),
        header('FILTER'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Harga Grosir (Rp)', style: TextStyle(fontSize: 13, color: cText)),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: _priceField(_minC, 'Min')),
              Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text('–', style: TextStyle(color: cMute))),
              Expanded(child: _priceField(_maxC, 'Maks')),
            ]),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: accent,
                  minimumSize: const Size.fromHeight(40),
                  textStyle: const TextStyle(fontWeight: FontWeight.w600),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () => _set(() {
                  _min = int.tryParse(_minC.text.replaceAll('.', ''));
                  _max = int.tryParse(_maxC.text.replaceAll('.', ''));
                }),
                child: const Text('Terapkan'),
              ),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                  child: Text('Sembunyikan SOLD', style: TextStyle(fontSize: 13, color: cText))),
              Transform.scale(
                scale: 0.85,
                child: CupertinoSwitch(
                  value: _hideSold,
                  activeTrackColor: accent,
                  onChanged: (v) => _set(() {
                    _hideSold = v;
                    if (v) _onlySold = false;
                  }),
                ),
              ),
            ]),
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                style: TextButton.styleFrom(
                  backgroundColor: accent.withValues(alpha: 0.10),
                  foregroundColor: accent,
                  minimumSize: const Size.fromHeight(40),
                  textStyle: const TextStyle(fontWeight: FontWeight.w600),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () {
                  _minC.clear();
                  _maxC.clear();
                  _set(() {
                    _min = _max = null;
                    _cat = null;
                    _hideSold = false;
                    _onlySold = false;
                    _sort = Sort.katalog;
                    _favOnly = false;
                  });
                },
                child: const Text('Hapus semua filter'),
              ),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _priceField(TextEditingController c, String hint) => SizedBox(
        height: 38,
        child: TextField(
          controller: c,
          keyboardType: TextInputType.number,
          style: TextStyle(fontSize: 13, color: cText),
          cursorColor: accent,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: cMute),
            isDense: true,
            filled: true,
            fillColor: cSurface,
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: accent, width: 1.5)),
          ),
        ),
      );

  // ---------- sort bar ----------
  Widget _sortBar(int pages, int page, int total) {
    final soldCount = store.products.where((p) => p.sold).length;
    const soldRed = Color(0xFFE5484D);

    Widget chipBox(String label, bool sel,
        {Color? on, IconData? icon, Widget? trailing}) {
      final c = on ?? accent;
      return AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: sel ? c : cSurface,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: sel
                  ? c.withValues(alpha: 0.35)
                  : Colors.black.withValues(alpha: isDark ? 0.3 : 0.06),
              blurRadius: sel ? 10 : 6,
              offset: Offset(0, sel ? 3 : 1),
            ),
          ],
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[
            Icon(icon, size: 15, color: sel ? Colors.white : cSub),
            const SizedBox(width: 6),
          ],
          Text(label,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: sel ? Colors.white : cText)),
          if (trailing != null) ...[const SizedBox(width: 6), trailing],
        ]),
      );
    }

    Widget chip(String label, bool sel, VoidCallback onTap,
            {Color? on, IconData? icon, Widget? trailing}) =>
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: onTap,
            child: chipBox(label, sel, on: on, icon: icon, trailing: trailing),
          ),
        );

    final priceSel = _sort == Sort.murah || _sort == Sort.mahal;
    return Container(
      margin: const EdgeInsets.only(right: 20),
      padding: const EdgeInsets.fromLTRB(16, 16, 0, 8),
      child: Row(children: [
        Text('Urutkan', style: TextStyle(color: cSub, fontSize: 13)),
        const SizedBox(width: 14),
        chip('Katalog', _sort == Sort.katalog, () => _set(() => _sort = Sort.katalog)),
        const SizedBox(width: 8),
        chip('Terbaru', _sort == Sort.terbaru, () => _set(() => _sort = Sort.terbaru)),
        const SizedBox(width: 8),
        PopupMenuButton<Sort>(
          color: cSurface,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          onSelected: (s) => _set(() => _sort = s),
          itemBuilder: (_) => const [
            PopupMenuItem(value: Sort.murah, child: Text('Harga: Rendah ke Tinggi')),
            PopupMenuItem(value: Sort.mahal, child: Text('Harga: Tinggi ke Rendah')),
          ],
          child: chipBox(
            _sort == Sort.murah
                ? 'Harga: Rendah ke Tinggi'
                : _sort == Sort.mahal
                    ? 'Harga: Tinggi ke Rendah'
                    : 'Harga',
            priceSel,
            trailing: Icon(CupertinoIcons.chevron_down,
                size: 12, color: priceSel ? Colors.white : cSub),
          ),
        ),
        Container(
          width: 1,
          height: 20,
          margin: const EdgeInsets.symmetric(horizontal: 14),
          color: cLine,
        ),
        // filter: tampilkan hanya produk SOLD
        chip(
          'SOLD',
          _onlySold,
          () => _set(() {
            _onlySold = !_onlySold;
            if (_onlySold) _hideSold = false;
          }),
          on: soldRed,
          icon: Icons.block_rounded,
          trailing: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: _onlySold ? Colors.white24 : soldRed.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('$soldCount',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: _onlySold ? Colors.white : soldRed)),
          ),
        ),
        const Spacer(),
        Text('$total produk', style: TextStyle(color: cSub, fontSize: 13)),
        const SizedBox(width: 12),
        Text('${page + 1}',
            style: TextStyle(color: accent, fontSize: 16, fontWeight: FontWeight.w700)),
        Text('/$pages', style: TextStyle(color: cSub)),
        const SizedBox(width: 8),
        _arrow(Icons.chevron_left, page > 0, () => setState(() => _page = page - 1)),
        _arrow(Icons.chevron_right, page < pages - 1, () => setState(() => _page = page + 1)),
      ]),
    );
  }

  Widget _arrow(IconData i, bool on, VoidCallback f) => Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Material(
          color: cSurface,
          shape: const CircleBorder(),
          elevation: on ? 1.5 : 0,
          shadowColor: Colors.black45,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: on ? f : null,
            child: SizedBox(
              width: 34,
              height: 34,
              child: Icon(i, size: 20, color: on ? cText : cMute),
            ),
          ),
        ),
      );

  // ---------- pagination angka di bawah daftar produk ----------
  List<int?> _pageWindow(int pages, int page) {
    if (pages <= 7) return [for (var i = 0; i < pages; i++) i];
    final s = <int>{0, pages - 1, page - 1, page, page + 1};
    if (page < 3) s.addAll([1, 2, 3, 4]);
    if (page > pages - 4) s.addAll([pages - 5, pages - 4, pages - 3, pages - 2]);
    final l = s.where((e) => e >= 0 && e < pages).toList()..sort();
    final out = <int?>[];
    for (var i = 0; i < l.length; i++) {
      if (i > 0) {
        final gap = l[i] - l[i - 1];
        if (gap == 2) {
          out.add(l[i] - 1);
        } else if (gap > 2) {
          out.add(null); // elipsis
        }
      }
      out.add(l[i]);
    }
    return out;
  }

  Widget _pager(int pages, int page) {
    Widget pageBtn(int n) {
      final sel = n == page;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Material(
          color: sel ? accent : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: sel ? null : () => setState(() => _page = n),
            child: Container(
              constraints: const BoxConstraints(minWidth: 38),
              height: 38,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text('${n + 1}',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                      color: sel ? Colors.white : cSub)),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        _arrow(Icons.chevron_left, page > 0, () => setState(() => _page = page - 1)),
        const SizedBox(width: 10),
        for (final n in _pageWindow(pages, page))
          n == null
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text('…', style: TextStyle(color: cMute, fontSize: 14)))
              : pageBtn(n),
        const SizedBox(width: 10),
        _arrow(Icons.chevron_right, page < pages - 1, () => setState(() => _page = page + 1)),
      ]),
    );
  }
}

// ================= CARD =================
class _Card extends StatefulWidget {
  const _Card(this.p);
  final Product p;
  @override
  State<_Card> createState() => _CardState();
}

class _CardState extends State<_Card> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    final labels = store.labelsOf(p);
    final margin = (p.ds != null && p.grosir != null) ? p.ds! - p.grosir! : null;
    final fav = store.favs.contains(p.key);

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        onTap: () => showDialog(context: context, builder: (_) => _Detail(p)),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          transformAlignment: Alignment.center,
          transform: Matrix4.translationValues(0, _hover ? -6 : 0, 0)..scale(_down ? 0.985 : 1.0),
          decoration: BoxDecoration(
            color: cSurface,
            borderRadius: BorderRadius.circular(14),
            boxShadow: _hover
                ? [
                    BoxShadow(
                        color: Colors.black.withValues(alpha: isDark ? 0.55 : 0.16),
                        blurRadius: 28,
                        offset: const Offset(0, 14)),
                    BoxShadow(
                        color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.06),
                        blurRadius: 6,
                        offset: const Offset(0, 2)),
                  ]
                : [
                    BoxShadow(
                        color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.07),
                        blurRadius: 10,
                        offset: const Offset(0, 3)),
                  ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AspectRatio(
              aspectRatio: 1,
              child: Stack(fit: StackFit.expand, children: [
                _Img(p.image),
                if (p.sold)
                  Container(
                    color: Colors.black38,
                    alignment: Alignment.center,
                    child: Container(
                      width: 70,
                      height: 70,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.black54,
                          border: Border.all(color: Colors.white54, width: 2)),
                      child: const Text('SOLD',
                          style: TextStyle(
                              color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                    ),
                  ),
                Positioned(
                  top: 0,
                  left: 0,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    for (final t in labels) _tag(labelStyle[t]!.$1, labelStyle[t]!.$2, labelStyle[t]!.$3),
                  ]),
                ),
                Positioned(
                  top: 6,
                  right: 6,
                  child: AnimatedOpacity(
                    opacity: (_hover || fav) ? 1 : 0,
                    duration: const Duration(milliseconds: 120),
                    child: InkWell(
                      onTap: () => store.toggleFav(p),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration:
                            const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                        child: Icon(fav ? Icons.favorite : Icons.favorite_border,
                            size: 17, color: Colors.red.shade400),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(p.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13, height: 1.3)),
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(p.grosir == null ? 'Hubungi supplier' : rp(p.grosir),
                            style: TextStyle(
                                color: accent, fontSize: 17, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Row(children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                                color: accent.withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(6)),
                            child: Text('DS ${rp(p.ds)}',
                                style: TextStyle(fontSize: 10, color: accent)),
                          ),
                          const Spacer(),
                          if (margin != null && margin > 0)
                            Text('+${rp(margin)}',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: isDark ? Colors.green.shade300 : Colors.green.shade700)),
                        ]),
                        if (p.variants.isNotEmpty)
                          Text('${p.variants.length} varian',
                              style: TextStyle(fontSize: 10, color: cMute)),
                      ]),
                    ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _tag(String t, Color c, IconData i) => Container(
        decoration: BoxDecoration(
          color: c,
          borderRadius: const BorderRadius.only(bottomRight: Radius.circular(6)),
        ),
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(i, color: Colors.white, size: 11),
          const SizedBox(width: 3),
          Text(t,
              style: const TextStyle(
                  color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600)),
        ]),
      );
}

class _Img extends StatelessWidget {
  const _Img(this.path, {this.fit = BoxFit.cover, this.cache = 600});
  final String? path;
  final BoxFit fit;
  final int cache;
  @override
  Widget build(BuildContext context) {
    if (path != null && File(path!).existsSync()) {
      return Image.file(File(path!), fit: fit, cacheWidth: cache);
    }
    return Container(
        color: cPlaceholder, child: Icon(Icons.image_outlined, size: 48, color: cMute));
  }
}

// ================= DETAIL =================
class _Detail extends StatefulWidget {
  const _Detail(this.p);
  final Product p;
  @override
  State<_Detail> createState() => _DetailState();
}

class _DetailState extends State<_Detail> {
  bool _copied = false;
  bool _added = false;
  final _imgKey = GlobalKey();
  String? _selVar;
  int _qty = 1;

  Widget _qtyStepper() => Container(
        height: 46,
        decoration: BoxDecoration(
            border: Border.all(color: cLine), borderRadius: BorderRadius.circular(10)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: _qty > 1 ? () => setState(() => _qty--) : null,
            icon: const Icon(Icons.remove, size: 16),
          ),
          SizedBox(
              width: 28,
              child: Center(
                  child: Text('$_qty', style: const TextStyle(fontWeight: FontWeight.w600)))),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: _qty < 999 ? () => setState(() => _qty++) : null,
            icon: const Icon(Icons.add, size: 16),
          ),
        ]),
      );

  /// Konfirmasi gaya iOS sebelum membuka Marketing Kit di browser.
  Future<void> _confirmOpenKit() async {
    const font = 'Inter';
    final ok = await showCupertinoDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => CupertinoTheme(
        data: CupertinoThemeData(
          brightness: isDark ? Brightness.dark : Brightness.light,
          primaryColor: accent,
        ),
        child: CupertinoAlertDialog(
          title: const Text('Buka Marketing Kit?',
              style: TextStyle(fontFamily: font, fontWeight: FontWeight.w600)),
          content: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Folder marketing kit untuk "${widget.p.name}" akan dibuka di browser. Lanjutkan?',
              style: const TextStyle(fontFamily: font, fontSize: 13, height: 1.35),
            ),
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Tidak', style: TextStyle(fontFamily: font)),
            ),
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Ya, Buka',
                  style: TextStyle(fontFamily: font, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
    if (ok == true) await launchUrl(Uri.parse(widget.p.kit!));
  }

  ButtonStyle _outlineStyle(Color fg, {bool tint = false}) => OutlinedButton.styleFrom(
        foregroundColor: fg,
        backgroundColor: tint ? fg.withValues(alpha: 0.08) : null,
        minimumSize: const Size.fromHeight(44),
        side: BorderSide(color: tint ? fg.withValues(alpha: 0.5) : cLine),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      );

  String get _info {
    final p = widget.p;
    return [
      p.name,
      'Kategori: ${p.sheet}',
      'Harga grosir: ${rp(p.grosir)}',
      'Harga DS: ${rp(p.ds)}',
      if (p.variants.isNotEmpty) 'Varian: ${p.variants.join(', ')}',
      if (p.note != null) 'Ket: ${p.note}',
      if (p.kit != null) 'Marketing kit: ${p.kit}',
    ].join('\n');
  }

  Widget _pill(String t, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(3)),
        child: Text(t, style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w600)),
      );

  Widget _cell(String label, String value, Color c, {String? sub}) => Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(fontSize: 12, color: cSub)),
            const SizedBox(height: 4),
            Text(value, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: c)),
            if (sub != null) Text(sub, style: TextStyle(fontSize: 11, color: cMute)),
          ]),
        ),
      );

  Widget _row(String label, Widget child) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 110, child: Text(label, style: TextStyle(color: cSub, fontSize: 13))),
          Expanded(child: child),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    final margin = (p.ds != null && p.grosir != null) ? p.ds! - p.grosir! : null;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final fav = store.favs.contains(p.key);
        final okColor = isDark ? Colors.green.shade300 : Colors.green.shade700;
        return Dialog(
          backgroundColor: cSurface,
          surfaceTintColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(32),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 940, maxHeight: 580),
            child: Stack(children: [
              Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(
                key: _imgKey,
                width: 400,
                color: cSurface2,
                padding: const EdgeInsets.all(20),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: _Img(p.image, fit: BoxFit.contain),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(28, 14, 14, 20),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Text('Katalog  ›  ${p.sheet}', style: TextStyle(fontSize: 12, color: cSub)),
                    ]),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.only(right: 14),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(p.name,
                              style: const TextStyle(
                                  fontSize: 22, fontWeight: FontWeight.w600, height: 1.3)),
                          const SizedBox(height: 10),
                          Wrap(spacing: 6, runSpacing: 6, children: [
                            p.sold
                                ? _pill('SOLD', Colors.red.shade400)
                                : _pill('Tersedia', okColor),
                            for (final t in store.labelsOf(p))
                              _pill(labelStyle[t]!.$1, labelStyle[t]!.$2),
                          ]),
                          const SizedBox(height: 18),
                          Container(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            decoration: BoxDecoration(
                              color: cPriceBg,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: cPriceLine),
                            ),
                            child: IntrinsicHeight(
                              child: Row(children: [
                                _cell('Harga Grosir', rp(p.grosir), accent),
                                const VerticalDivider(width: 1),
                                _cell('Harga DS', rp(p.ds), cText),
                                if (margin != null) ...[
                                  const VerticalDivider(width: 1),
                                  _cell('Selisih', rp(margin), okColor,
                                      sub: (p.grosir ?? 0) > 0
                                          ? 'Markup ${(margin * 100 / p.grosir!).toStringAsFixed(0)}%'
                                          : null),
                                ],
                              ]),
                            ),
                          ),
                          const SizedBox(height: 22),
                          _row('Kategori', Text(p.sheet)),
                          if (p.no != null) _row('No. Katalog', Text(p.no!)),
                          if (p.variants.isNotEmpty)
                            _row(
                              'Varian',
                              Wrap(spacing: 8, runSpacing: 8, children: [
                                for (final v in p.variants)
                                  InkWell(
                                    borderRadius: BorderRadius.circular(3),
                                    onTap: () =>
                                        setState(() => _selVar = _selVar == v ? null : v),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 6),
                                      decoration: BoxDecoration(
                                          color: _selVar == v
                                              ? accent.withValues(alpha: 0.10)
                                              : null,
                                          border: Border.all(
                                              color: _selVar == v ? accent : cLine,
                                              width: _selVar == v ? 1.5 : 1),
                                          borderRadius: BorderRadius.circular(3)),
                                      child: Text(v,
                                          style: TextStyle(
                                              fontSize: 13,
                                              color: _selVar == v ? accent : null,
                                              fontWeight: _selVar == v
                                                  ? FontWeight.w600
                                                  : FontWeight.w400)),
                                    ),
                                  ),
                              ]),
                            ),
                          if (p.note != null) _row('Keterangan', Text(p.note!)),
                        ]),
                      ),
                    ),
                    const Divider(height: 24),
                    Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Row(children: [
                        _qtyStepper(),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextButton.icon(
                            style: TextButton.styleFrom(
                              backgroundColor: accent.withValues(alpha: 0.10),
                              foregroundColor: accent,
                              minimumSize: const Size.fromHeight(46),
                              textStyle:
                                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                            ),
                            onPressed: (p.sold || (p.variants.isNotEmpty && _selVar == null))
                                ? null
                                : () {
                                    store.addToCart(p, _selVar, _qty);
                                    flyToCart(context, from: _imgKey, imagePath: p.image);
                                    setState(() => _added = true);
                                    Future.delayed(const Duration(seconds: 2), () {
                                      if (mounted) setState(() => _added = false);
                                    });
                                  },
                            icon: Icon(
                                _added ? Icons.check_rounded : Icons.add_shopping_cart_rounded,
                                size: 18),
                            label: Text(p.sold
                                ? 'Stok habis (SOLD)'
                                : (p.variants.isNotEmpty && _selVar == null)
                                    ? 'Pilih varian dulu'
                                    : _added
                                        ? 'Masuk keranjang'
                                        : 'Tambah ke keranjang'),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 10),
                      if (p.kit != null) ...[
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: accent,
                            foregroundColor: Colors.white,
                            minimumSize: const Size.fromHeight(46),
                            textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          onPressed: _confirmOpenKit,
                          icon: const Icon(Icons.folder_open, size: 18),
                          label: const Text('Buka Marketing Kit'),
                        ),
                        const SizedBox(height: 10),
                      ],
                      Row(children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            style: _outlineStyle(_copied ? const Color(0xFF2E9E5B) : cText,
                                tint: _copied),
                            onPressed: () async {
                              await Clipboard.setData(ClipboardData(text: _info));
                              setState(() => _copied = true);
                              Future.delayed(const Duration(seconds: 2), () {
                                if (mounted) setState(() => _copied = false);
                              });
                            },
                            icon: Icon(_copied ? Icons.check_rounded : Icons.copy_rounded, size: 17),
                            label: Text(_copied ? 'Tersalin' : 'Salin info'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            style: _outlineStyle(fav ? Colors.red.shade400 : cText, tint: fav),
                            onPressed: () => store.toggleFav(p),
                            icon: Icon(fav ? Icons.favorite : Icons.favorite_border,
                                size: 17, color: Colors.red.shade400),
                            label: Text(fav ? 'Favorit' : 'Tambah favorit',
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                        ),
                      ]),
                    ]),
                  ]),
                ),
              ),
              ]),
              Positioned(
                top: 4,
                right: 4,
                child: IconButton(
                  tooltip: 'Tutup',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, size: 20),
                  style: ButtonStyle(
                    backgroundColor: WidgetStateProperty.resolveWith((st) =>
                        st.contains(WidgetState.hovered)
                            ? Colors.red.shade600
                            : Colors.transparent),
                    foregroundColor: WidgetStateProperty.resolveWith((st) =>
                        st.contains(WidgetState.hovered) ? Colors.white : cText),
                    overlayColor: WidgetStateProperty.all(Colors.transparent),
                  ),
                ),
              ),
            ]),
          ),
        );
      },
    );
  }
}

// ================= POPOVER (menempel di ikon) =================
/// Menampilkan panel yang "menempel" di bawah ikon [anchor] dengan panah kecil
/// yang menunjuk ke ikon tersebut (gaya popover iOS).
/// Teks pesanan siap kirim ke supplier: satu baris per item, mis. "2x  alat ngorok".
String buildOrderText(List<CartLine> cart, [DateTime? now]) {
  const bulan = ['Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun', 'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des'];
  final t = now ?? DateTime.now();
  final tgl = '${t.day} ${bulan[t.month - 1]} ${t.year}, '
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  final b = StringBuffer('Tanggal: $tgl\n\nHalo, saya mau pesan:\n\n');
  for (final l in cart) {
    b.write('${l.qty}x  ${l.name}');
    if (l.variant != null) b.write(' - varian ${l.variant}');
    b.write('\n');
  }
  b.write('\nMohon dicek ketersediaan stoknya. Terima kasih.');
  return b.toString();
}

// ================= EFEK TERBANG KE KERANJANG =================
final cartKey = GlobalKey(); // posisi ikon keranjang di header
final cartBump = ValueNotifier<int>(0); // dipicu saat thumbnail mendarat

/// Menerbangkan thumbnail produk dari [from] ke ikon keranjang di header.
void flyToCart(BuildContext context, {required GlobalKey from, String? imagePath}) {
  final fromBox = from.currentContext?.findRenderObject() as RenderBox?;
  final toBox = cartKey.currentContext?.findRenderObject() as RenderBox?;
  if (fromBox == null || toBox == null || !fromBox.attached || !toBox.attached) {
    cartBump.value++;
    return;
  }
  final start = fromBox.localToGlobal(fromBox.size.center(Offset.zero));
  final end = toBox.localToGlobal(toBox.size.center(Offset.zero));
  final overlay = Overlay.of(context, rootOverlay: true);
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _FlyingThumb(
      start: start,
      end: end,
      imagePath: imagePath,
      onDone: () {
        entry.remove();
        cartBump.value++;
      },
    ),
  );
  overlay.insert(entry);
}

class _FlyingThumb extends StatefulWidget {
  const _FlyingThumb(
      {required this.start, required this.end, required this.onDone, this.imagePath});
  final Offset start, end;
  final String? imagePath;
  final VoidCallback onDone;
  @override
  State<_FlyingThumb> createState() => _FlyingThumbState();
}

class _FlyingThumbState extends State<_FlyingThumb> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 720))
        ..addStatusListener((st) {
          if (st == AnimationStatus.completed) widget.onDone();
        })
        ..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// Lintasan melengkung (kurva Bezier) dari awal ke ikon keranjang.
  Offset _at(double t) {
    final a = widget.start, b = widget.end;
    final c = Offset((a.dx + b.dx) / 2, min(a.dy, b.dy) - 150);
    final u = 1 - t;
    return a * (u * u) + c * (2 * u * t) + b * (t * t);
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, _) {
            final t = Curves.easeInOutCubic.transform(_c.value);
            final pos = _at(t);
            final size = 120 + (26 - 120) * t;
            final fade = _c.value < 0.8 ? 1.0 : (1 - (_c.value - 0.8) / 0.2).clamp(0.0, 1.0);
            return Stack(children: [
              Positioned(
                left: pos.dx - size / 2,
                top: pos.dy - size / 2,
                width: size,
                height: size,
                child: Opacity(
                  opacity: fade,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: const [
                        BoxShadow(color: Colors.black38, blurRadius: 16, offset: Offset(0, 6))
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: widget.imagePath != null
                          ? _Img(widget.imagePath, cache: 240)
                          : Container(
                              color: accent,
                              child: const Icon(Icons.shopping_cart,
                                  color: Colors.white, size: 40)),
                    ),
                  ),
                ),
              ),
            ]);
          },
        ),
      ),
    );
  }
}

/// Membungkus ikon keranjang agar "membal" saat barang mendarat.
class _Bump extends StatefulWidget {
  const _Bump({super.key, required this.child});
  final Widget child;
  @override
  State<_Bump> createState() => _BumpState();
}

class _BumpState extends State<_Bump> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 460));
  late final Animation<double> _s = TweenSequence<double>([
    TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 1.35).chain(CurveTween(curve: Curves.easeOut)), weight: 30),
    TweenSequenceItem(
        tween: Tween(begin: 1.35, end: 1.0).chain(CurveTween(curve: Curves.elasticOut)),
        weight: 70),
  ]).animate(_c);

  void _go() => _c.forward(from: 0);

  @override
  void initState() {
    super.initState();
    cartBump.addListener(_go);
  }

  @override
  void dispose() {
    cartBump.removeListener(_go);
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ScaleTransition(scale: _s, child: widget.child);
}

// ================= KERANJANG (ikon keranjang) — gaya iOS =================
class _CartPanel extends StatefulWidget {
  const _CartPanel();
  @override
  State<_CartPanel> createState() => _CartPanelState();
}

class _CartPanelState extends State<_CartPanel> {
  late final TextEditingController _wa = TextEditingController(text: store.waNumber);
  String? _status;
  bool _copied = false;

  @override
  void dispose() {
    _wa.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: buildOrderText(store.cart)));
    if (!mounted) return;
    setState(() {
      _copied = true;
      _status = null;
    });
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Future<void> _sendWa() async {
    final text = buildOrderText(store.cart);
    final raw = _wa.text.trim().isNotEmpty ? _wa.text : store.defaultWa;
    var n = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (n.startsWith('0')) n = '62${n.substring(1)}';
    final uri = Uri.parse('https://wa.me/$n?text=${Uri.encodeComponent(text)}');
    bool ok = false;
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (!mounted) return;
    if (!ok) {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      setState(() => _status =
          'WhatsApp tidak bisa dibuka. Pesanan sudah disalin, tempel manual di chat.');
    } else {
      setState(() => _status = null);
    }
  }

  Future<void> _confirmClear() async {
    const font = 'Inter';
    final ok = await showCupertinoDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => CupertinoTheme(
        data: CupertinoThemeData(
          brightness: isDark ? Brightness.dark : Brightness.light,
          primaryColor: accent,
        ),
        child: CupertinoAlertDialog(
          title: const Text('Kosongkan keranjang?',
              style: TextStyle(fontFamily: font, fontWeight: FontWeight.w600)),
          content: const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('Semua barang di keranjang akan dihapus.',
                style: TextStyle(fontFamily: font, fontSize: 13, height: 1.35)),
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Batal', style: TextStyle(fontFamily: font)),
            ),
            CupertinoDialogAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Kosongkan',
                  style: TextStyle(fontFamily: font, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
    if (ok == true) store.clearCart();
  }

  // --- potongan UI ---
  BoxDecoration get _card => BoxDecoration(
        color: cSurface,
        borderRadius: BorderRadius.circular(12),
      );

  Widget _thumb(Product? p) => ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(width: 54, height: 54, child: _Img(p?.image, cache: 140)),
      );

  /// Stepper ala iOS: [ − | 2 | + ]. Saat jumlah 1, tombol "−" menjadi ikon tong sampah.
  Widget _stepper(CartLine l) {
    Widget btn(IconData ic, VoidCallback onTap, {Color? color}) => InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: SizedBox(
              width: 30, height: 30, child: Icon(ic, size: 16, color: color ?? cText)),
        );
    return Container(
      decoration: BoxDecoration(color: cBar, borderRadius: BorderRadius.circular(8)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        l.qty <= 1
            ? btn(CupertinoIcons.trash, () => store.setQty(l, 0), color: Colors.red.shade400)
            : btn(CupertinoIcons.minus, () => store.setQty(l, l.qty - 1)),
        SizedBox(
            width: 28,
            child: Center(
                child: Text('${l.qty}',
                    style: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600, color: cText)))),
        btn(CupertinoIcons.plus, () => store.setQty(l, l.qty + 1)),
      ]),
    );
  }

  Widget _lineRow(CartLine l) {
    final p = store.productOf(l);
    final pr = p?.grosir;
    return Dismissible(
      key: ValueKey('${l.pkey}#${l.variant}'),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => store.setQty(l, 0),
      background: Container(
        color: Colors.red.shade500,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 22),
        child: const Text('Hapus',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
      ),
      child: Container(
        color: cSurface,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(children: [
          _thumb(p),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: cText)),
              if (l.variant != null) ...[
                const SizedBox(height: 2),
                Text(l.variant!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: cSub)),
              ],
              const SizedBox(height: 3),
              Text(pr == null ? 'Harga belum tersedia' : '${rp(pr)} / pcs',
                  style: TextStyle(fontSize: 12.5, color: cMute)),
            ]),
          ),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            _stepper(l),
            const SizedBox(height: 6),
            Text(pr == null ? '-' : rp(pr * l.qty),
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: accent)),
          ]),
        ]),
      ),
    );
  }

  Widget _bigButton({
    required String label,
    required IconData icon,
    required VoidCallback? onTap,
    required Color bg,
    required Color fg,
  }) =>
      SizedBox(
        height: 48,
        child: TextButton.icon(
          style: TextButton.styleFrom(
            backgroundColor: bg,
            foregroundColor: fg,
            disabledBackgroundColor: bg.withValues(alpha: 0.4),
            disabledForegroundColor: fg.withValues(alpha: 0.7),
            textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onPressed: onTap,
          icon: Icon(icon, size: 18),
          label: Text(label),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final cart = store.cart;
        var total = 0;
        for (final l in cart) {
          final pr = store.productOf(l)?.grosir;
          if (pr != null) total += pr * l.qty;
        }
        return Container(
          color: cBg,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // ----- bilah judul ala iOS -----
            Container(
              height: 52,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: cSurface,
                border: Border(bottom: BorderSide(color: cLine)),
              ),
              child: Row(children: [
                const SizedBox(width: 104),
                Expanded(
                  child: Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text('Keranjang',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600, color: cText)),
                      if (cart.isNotEmpty)
                        Text('${store.cartCount} barang',
                            style: TextStyle(fontSize: 11.5, color: cSub)),
                    ]),
                  ),
                ),
                SizedBox(
                  width: 104,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: cart.isEmpty
                        ? const SizedBox.shrink()
                        : TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.red.shade400,
                              textStyle:
                                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                            ),
                            onPressed: _confirmClear,
                            child: const Text('Kosongkan', maxLines: 1, softWrap: false),
                          ),
                  ),
                ),
              ]),
            ),
            // ----- isi -----
            Expanded(
              child: cart.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Icon(CupertinoIcons.cart, size: 46, color: cMute),
                          const SizedBox(height: 12),
                          Text('Keranjang kosong',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w600, color: cText)),
                          const SizedBox(height: 6),
                          Text(
                            'Buka produk lalu pilih\n"Tambah ke keranjang".',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 13, color: cSub, height: 1.4),
                          ),
                        ]),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                      children: [
                        Container(
                          decoration: _card,
                          clipBehavior: Clip.antiAlias,
                          child: Column(children: [
                            for (var i = 0; i < cart.length; i++) ...[
                              if (i > 0)
                                Padding(
                                  padding: const EdgeInsets.only(left: 78),
                                  child: Divider(height: 1, thickness: 0.6, color: cLine),
                                ),
                              _lineRow(cart[i]),
                            ],
                          ]),
                        ),
                      ],
                    ),
            ),
            // ----- ringkasan + kirim -----
            if (cart.isNotEmpty)
              Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Container(
                    decoration: _card,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    child: Column(children: [
                      Row(children: [
                        Expanded(
                            child: Text('Jumlah barang',
                                style: TextStyle(fontSize: 13.5, color: cSub))),
                        Text('${store.cartCount} pcs',
                            style: TextStyle(fontSize: 13.5, color: cText)),
                      ]),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Divider(height: 1, thickness: 0.6, color: cLine),
                      ),
                      Row(children: [
                        Expanded(
                            child: Text('Total harga grosir',
                                style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: cText))),
                        Text(rp(total),
                            style: TextStyle(
                                fontSize: 19, fontWeight: FontWeight.w700, color: accent)),
                      ]),
                    ]),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    decoration: _card,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(children: [
                      Icon(CupertinoIcons.phone, size: 17, color: cMute),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _wa,
                          onChanged: store.setWa,
                          keyboardType: TextInputType.phone,
                          style: TextStyle(fontSize: 14, color: cText),
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(vertical: 14),
                            isDense: true,
                            hintText: store.defaultWa.isNotEmpty
                                ? 'Supplier: ${store.defaultWa} (ketik untuk ganti)'
                                : 'No. WhatsApp supplier (opsional)',
                            hintStyle: TextStyle(fontSize: 13, color: cMute),
                          ),
                        ),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 12),
                  _bigButton(
                    label: 'Kirim ke WhatsApp',
                    icon: CupertinoIcons.paperplane_fill,
                    onTap: _sendWa,
                    bg: const Color(0xFF25D366),
                    fg: Colors.white,
                  ),
                  const SizedBox(height: 8),
                  _bigButton(
                    label: _copied ? 'Tersalin' : 'Salin pesanan',
                    icon: _copied ? CupertinoIcons.checkmark_alt : CupertinoIcons.doc_on_doc,
                    onTap: _copy,
                    bg: _copied
                        ? const Color(0xFF2E9E5B).withValues(alpha: 0.14)
                        : accent.withValues(alpha: 0.10),
                    fg: _copied ? const Color(0xFF2E9E5B) : accent,
                  ),
                  if (_status != null) ...[
                    const SizedBox(height: 8),
                    Text(_status!,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: Colors.red.shade400)),
                  ],
                ]),
              ),
          ]),
        );
      },
    );
  }
}

Widget _popMaterial(Widget child) => Material(
      color: cBg,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.black54,
      elevation: 16,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: child,
    );

Future<void> showPopover(
  BuildContext anchor, {
  required double width,
  required double height,
  required Color arrowColor,
  required WidgetBuilder builder,
  bool fit = false, // true: tinggi panel mengikuti isi (maks. [height] / batas layar)
}) {
  final box = anchor.findRenderObject() as RenderBox;
  final rect = box.localToGlobal(Offset.zero) & box.size;
  final screen = MediaQuery.sizeOf(anchor);

  final w = min(width, screen.width - 24);
  final top = rect.bottom + 12;
  final h = min(height, max(160.0, screen.height - top - 12));
  final left = (rect.right + 14 - w).clamp(12.0, screen.width - w - 12).toDouble();
  final ax = (rect.center.dx - left).clamp(24.0, w - 24).toDouble();
  final origin = Alignment(
    (rect.center.dx / screen.width) * 2 - 1,
    (rect.bottom / screen.height) * 2 - 1,
  );

  return showGeneralDialog(
    context: anchor,
    barrierDismissible: true,
    barrierLabel: 'Tutup',
    barrierColor: Colors.black38,
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (ctx, _, _) => Stack(fit: StackFit.expand, children: [
      Positioned(
        left: left,
        top: top,
        width: w,
        height: fit ? null : h,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: h),
          child: Stack(
            clipBehavior: Clip.none,
            fit: fit ? StackFit.passthrough : StackFit.loose,
            children: [
          // panah penunjuk ke ikon
          Positioned(
            left: ax - 8,
            top: -7,
            child: Transform.rotate(
              angle: pi / 4,
              child: Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: arrowColor,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
          fit
              ? _popMaterial(builder(ctx))
              : Positioned.fill(child: _popMaterial(builder(ctx))),
        ]),
        ),
      ),
    ]),
    transitionBuilder: (ctx, anim, _, child) {
      final c = CurvedAnimation(
          parent: anim, curve: Curves.easeOutCubic, reverseCurve: Curves.easeIn);
      return FadeTransition(
        opacity: c,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.9, end: 1).animate(c),
          alignment: origin,
          child: child,
        ),
      );
    },
  );
}

// ================= INTERVAL (ikon jam) =================
class _IntervalPanel extends StatelessWidget {
  const _IntervalPanel();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => Container(
        color: cSurface,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Text('CEK OTOMATIS',
                style: TextStyle(fontSize: 12, color: cSub, letterSpacing: 0.4)),
          ),
          for (final m in const [30, 60, 180, 360])
            InkWell(
              onTap: () {
                store.setInterval(m);
                Navigator.pop(context);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                child: Row(children: [
                  Expanded(
                    child: Text('Tiap ${intervalLabel(m)}',
                        style: TextStyle(fontSize: 15, color: cText)),
                  ),
                  if (store.intervalMin == m)
                    Icon(CupertinoIcons.checkmark_alt, size: 18, color: accent),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
}

// ================= UPDATES (ikon lonceng) =================
class _UpdatesPanel extends StatelessWidget {
  const _UpdatesPanel();

  static const Map<String, (IconData, Color)> _meta = {
    'baru': (Icons.fiber_new, Color(0xFFEE4D2D)),
    'harga': (Icons.price_change, Color(0xFF1E88E5)),
    'sold': (Icons.block, Color(0xFFE53935)),
    'tersedia': (Icons.check_circle, Color(0xFF43A047)),
    'varian': (Icons.palette, Color(0xFF8E24AA)),
    'hapus': (Icons.delete_outline, Color(0xFF757575)),
  };

  Widget _leading(Change c, Product? target) {
    final m = _meta[c.type] ?? (Icons.info, Colors.grey);
    return SizedBox(
      width: 54,
      height: 54,
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned.fill(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: target?.image != null
                ? _Img(target!.image, cache: 160)
                : Container(
                    color: m.$2.withValues(alpha: 0.14),
                    child: Icon(m.$1, color: m.$2, size: 26),
                  ),
          ),
        ),
        // lencana jenis perubahan di pojok foto
        Positioned(
          right: -5,
          bottom: -5,
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: m.$2,
              shape: BoxShape.circle,
              border: Border.all(color: cSurface, width: 2),
            ),
            child: Icon(m.$1, color: Colors.white, size: 12),
          ),
        ),
      ]),
    );
  }

  Widget _tile(BuildContext context, Change c, Product? target) {
    final color = (_meta[c.type] ?? (Icons.info, Colors.grey)).$2;
    return InkWell(
      onTap: target == null
          ? null
          : () {
              final nav = Navigator.of(context);
              nav.pop();
              showDialog(context: nav.context, builder: (_) => _Detail(target));
            },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(children: [
          _leading(c, target),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(c.product,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                ),
                const SizedBox(width: 8),
                Text(fmtTime(c.at), style: TextStyle(fontSize: 11, color: cMute)),
              ]),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(_label(c.type).toUpperCase(),
                    style: TextStyle(
                        fontSize: 10, fontWeight: FontWeight.w700, color: color)),
              ),
              const SizedBox(height: 4),
              Text(c.detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: cSub, height: 1.3)),
            ]),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final byName = {for (final p in store.products) p.name: p};
        return Container(
          color: cSurface,
          child: Column(children: [
            Container(
              color: accent,
              padding: const EdgeInsets.fromLTRB(18, 6, 6, 6),
              child: Row(children: [
                const Icon(Icons.notifications, color: Colors.white, size: 20),
                const SizedBox(width: 10),
                const Text('Update Produk',
                    style: TextStyle(
                        color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
                const Spacer(),
                Text('Sync terakhir ${fmtTime(store.lastSync)}',
                    style: const TextStyle(color: Colors.white70, fontSize: 11.5)),
                IconButton(
                  tooltip: 'Tutup',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, size: 20),
                  style: ButtonStyle(
                    backgroundColor: WidgetStateProperty.resolveWith((st) =>
                        st.contains(WidgetState.hovered)
                            ? Colors.red.shade600
                            : Colors.transparent),
                    foregroundColor: WidgetStateProperty.all(Colors.white),
                    overlayColor: WidgetStateProperty.all(Colors.transparent),
                  ),
                ),
              ]),
            ),
            Expanded(
              child: store.changes.isEmpty
                  ? Center(
                      child: Text('Belum ada perubahan terdeteksi',
                          style: TextStyle(color: cSub)))
                  : ListView.separated(
                      itemCount: store.changes.length,
                      separatorBuilder: (_, _) => Divider(height: 1, indent: 86, color: cLine),
                      itemBuilder: (_, i) {
                        final c = store.changes[i];
                        return _tile(context, c, byName[c.product]);
                      },
                    ),
            ),
          ]),
        );
      },
    );
  }
}

// ================= PENGATURAN (gaya iOS, ikon gear) =================
class _SettingsPanel extends StatefulWidget {
  const _SettingsPanel();
  @override
  State<_SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<_SettingsPanel> {
  bool _about = false;

  // warna aksen ala iOS
  static const _indigo = Color(0xFF5856D6);
  static const _red = Color(0xFFFF3B30);
  static const _green = Color(0xFF34C759);
  static const _blue = Color(0xFF007AFF);
  static const _orange = Color(0xFFFF9500);
  static const _purple = Color(0xFFAF52DE);
  static const _teal = Color(0xFF5AC8FA);
  static const _gray = Color(0xFF8E8E93);

  Widget _group(List<Widget> rows) => Container(
        decoration: BoxDecoration(color: cSurface, borderRadius: BorderRadius.circular(10)),
        clipBehavior: Clip.antiAlias,
        child: Column(children: rows),
      );

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
        child: Text(t, style: TextStyle(fontSize: 12, color: cSub, letterSpacing: 0.4)),
      );

  Widget _iconBox(IconData i, Color c) => Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(7)),
        child: Icon(i, color: Colors.white, size: 18),
      );

  Widget _div() => Divider(height: 1, indent: 56, color: cLine);

  Widget _point(IconData i, Color c, String title, String text) => Padding(
        padding: const EdgeInsets.all(14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _iconBox(i, c),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
              const SizedBox(height: 3),
              Text(text, style: TextStyle(fontSize: 13, color: cSub, height: 1.4)),
            ]),
          ),
        ]),
      );

  Widget _switchRow(IconData i, Color c, String title, bool v, ValueChanged<bool> f) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(children: [
          _iconBox(i, c),
          const SizedBox(width: 12),
          Expanded(child: Text(title, style: const TextStyle(fontSize: 15))),
          CupertinoSwitch(value: v, activeTrackColor: c, onChanged: f),
        ]),
      );

  Widget _segRow<T extends Object>(IconData i, Color c, String title, String sub, T value,
          Map<T, String> opts, ValueChanged<T> f) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            _iconBox(i, c),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontSize: 15)),
                Text(sub, style: TextStyle(fontSize: 12, color: cSub)),
              ]),
            ),
          ]),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: CupertinoSlidingSegmentedControl<T>(
              groupValue: value,
              thumbColor: isDark ? const Color(0xFF636366) : Colors.white,
              backgroundColor: isDark ? const Color(0xFF3A3A3C) : const Color(0xFFEEEEF0),
              children: {
                for (final e in opts.entries)
                  e.key: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(e.value, style: TextStyle(fontSize: 13, color: cText)),
                  ),
              },
              onValueChanged: (v) {
                if (v != null) f(v);
              },
            ),
          ),
        ]),
      );

  Widget _accentRow() => Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            _iconBox(CupertinoIcons.paintbrush_fill, accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Warna Aksen', style: TextStyle(fontSize: 15)),
                Text(accentChoices[store.accentIdx.clamp(0, accentChoices.length - 1)].$1,
                    style: TextStyle(fontSize: 12, color: cSub)),
              ]),
            ),
          ]),
          const SizedBox(height: 14),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            for (var i = 0; i < accentChoices.length; i++)
              GestureDetector(
                onTap: () => store.setAccent(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  width: 40,
                  height: 40,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: store.accentIdx == i ? accentChoices[i].$2 : Colors.transparent,
                        width: 2),
                  ),
                  child: Container(
                    decoration:
                        BoxDecoration(color: accentChoices[i].$2, shape: BoxShape.circle),
                    child: store.accentIdx == i
                        ? const Icon(CupertinoIcons.checkmark_alt, color: Colors.white, size: 18)
                        : null,
                  ),
                ),
              ),
          ]),
        ]),
      );

  Widget _settingsBody() => ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
        _label('TAMPILAN'),
        _group([
          _switchRow(CupertinoIcons.moon_fill, _indigo, 'Mode Gelap', store.dark, store.setDark),
          _div(),
          _accentRow(),
        ]),
        _label('PEMBERITAHUAN'),
        _group([
          _switchRow(CupertinoIcons.bell_fill, _red, 'Notifikasi Desktop', store.notif,
              store.setNotif),
          _div(),
          _segRow<int>(
            CupertinoIcons.tag_fill,
            accent,
            'Label Produk',
            'Label BARU, HARGA BERUBAH, dll hilang sendiri setelah',
            store.labelDays,
            const {1: '1 hari', 3: '3 hari', 7: '7 hari'},
            store.setLabelDays,
          ),
        ]),
        _label('SINKRONISASI'),
        _group([
          _segRow<int>(
            CupertinoIcons.arrow_2_circlepath,
            _green,
            'Cek Otomatis',
            'Jeda pengecekan katalog supplier',
            store.intervalMin,
            const {30: '30 mnt', 60: '1 jam', 180: '3 jam', 360: '6 jam'},
            store.setInterval,
          ),
        ]),
        _label('INFORMASI'),
        _group([
          InkWell(
            onTap: () => setState(() => _about = true),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(children: [
                _iconBox(CupertinoIcons.info, _blue),
                const SizedBox(width: 12),
                const Expanded(child: Text('Tentang', style: TextStyle(fontSize: 15))),
                Text('v$kAppVersion', style: TextStyle(color: cSub, fontSize: 13)),
                const SizedBox(width: 6),
                Icon(CupertinoIcons.chevron_forward, size: 16, color: cMute),
              ]),
            ),
          ),
        ]),
        const SizedBox(height: 24),
        Center(child: Text('Katalog Importbox', style: TextStyle(fontSize: 12, color: cMute))),
      ]);

  Widget _aboutBody() {
    return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
      _label('TENTANG APLIKASI'),
      _group([
        Padding(
          padding: const EdgeInsets.all(14),
          child: Text(
            'Katalog Importbox membantu Anda melihat katalog produk dari supplier dengan '
            'tampilan seperti toko online, lengkap dengan pencarian, filter harga, dan '
            'pemberitahuan bila ada produk yang berubah.',
            style: TextStyle(fontSize: 13, color: cSub, height: 1.45),
          ),
        ),
      ]),
      _label('YANG PERLU ANDA KETAHUI'),
      _group([
        _point(CupertinoIcons.lock_fill, _green, 'Hanya untuk dibaca',
            'Aplikasi ini hanya menampilkan katalog. Aplikasi tidak bisa mengubah, menghapus, '
                'atau menambah isi file milik supplier.'),
        _div(),
        _point(CupertinoIcons.cloud_download, _blue, 'Dari mana datanya',
            'Data diambil dari Google Sheets katalog supplier yang dibagikan kepada Anda. '
                'Aplikasi hanya mengambil salinannya, bukan mengedit file aslinya.'),
        _div(),
        _point(CupertinoIcons.link, _orange, 'Link lihat atau link edit',
            'Cukup link yang bisa dilihat. Memakai link edit tidak membuat aplikasi bisa '
                'mengubah data. Untuk mengelola data sumber diperlukan izin editor dari pemilik '
                'file dan pengaturan khusus.'),
        _div(),
        _point(CupertinoIcons.folder_fill, _gray, 'Tersimpan di komputer ini',
            'Katalog, foto, dan favorit disimpan di komputer Anda, jadi data terakhir tetap '
                'bisa dibuka walau sedang tidak ada internet.'),
        _div(),
        _point(CupertinoIcons.arrow_2_circlepath, _purple, 'Cek pembaruan otomatis',
            'Aplikasi mengecek pembaruan setiap kali dibuka dan secara berkala selama '
                'aplikasi terbuka. Jedanya bisa diatur di Pengaturan atau lewat ikon jam '
                'di bagian atas (bawaan: 1 jam).'),
        _div(),
        _point(CupertinoIcons.bell_fill, _red, 'Pemberitahuan',
            'Anda diberi tahu bila ada produk baru, perubahan harga, produk SOLD atau '
                'tersedia lagi, perubahan varian, atau produk yang dihapus. Riwayatnya bisa '
                'dilihat di ikon lonceng, lengkap dengan foto produknya.'),
        _div(),
        _point(CupertinoIcons.tag_fill, accent, 'Label pada produk',
            'Produk yang baru atau berubah diberi label di fotonya. Label hilang sendiri '
                'setelah beberapa hari (bawaan: 3 hari) dan bisa diatur di Pengaturan.'),
        _div(),
        _point(CupertinoIcons.shield_fill, _teal, 'Privasi',
            'Favorit hanya tersimpan di komputer Anda. Aplikasi tidak memakai akun dan tidak '
                'mengirim data pribadi Anda ke mana pun.'),
      ]),
      const SizedBox(height: 20),
      Center(child: Text('Versi $kAppVersion', style: TextStyle(fontSize: 12, color: cMute))),
      Center(
        child: TextButton(
          onPressed: () => UpdateService.checkManual(context),
          child: const Text('Cek pembaruan aplikasi'),
        ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => Container(
        color: cBg,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            color: cSurface,
            height: 48,
            child: Stack(alignment: Alignment.center, children: [
              Text(_about ? 'Tentang' : 'Pengaturan',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              if (_about)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10)),
                    onPressed: () => setState(() => _about = false),
                    icon: Icon(CupertinoIcons.back, size: 18, color: accent),
                    label: Text('Pengaturan',
                        maxLines: 1,
                        softWrap: false,
                        style: TextStyle(color: accent, fontSize: 14)),
                  ),
                ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 14)),
                  onPressed: () => Navigator.pop(context),
                  child: Text('Selesai',
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(color: accent, fontWeight: FontWeight.w600)),
                ),
              ),
            ]),
          ),
          Divider(height: 1, color: cLine),
          Flexible(child: _about ? _aboutBody() : _settingsBody()),
        ]),
      ),
    );
  }
}
