// lib/ads_roas.dart  (versi mandiri untuk proyek e_katalog)
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/gestures.dart'
    show
        LongPressGestureRecognizer,
        LongPressMoveUpdateDetails,
        LongPressStartDetails;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'main.dart' as app show accent, cLine, cMute, cSurface, cText, isDark;

// ---------------------------------------------------------------------------
// Penghubung ke tema e_katalog (menggantikan config/theme.dart dkk. milik app
// lain). Semua warna diambil dari main.dart sehingga ikut mode terang/gelap.
// ---------------------------------------------------------------------------
bool omniIsDark(BuildContext c) => app.isDark;
Color omniText(BuildContext c) => app.cText;
Color omniMuted(BuildContext c) => app.cMute;
Color omniStroke(BuildContext c) => app.cLine;
Color omniElevated(BuildContext c) => app.cSurface;

class OmniText extends Text {
  const OmniText(
    String super.data, {
    super.key,
    super.style,
    super.textAlign,
    super.softWrap,
    super.overflow,
    super.maxLines,
  });
}

/// Format rupiah ala id-ID: Rp 1.234.567 (negatif: -Rp 1.234).
class Format {
  static const int maxInputDigits = 12;

  static String idr(num v) {
    final r = v.round();
    final d = r.abs().toString();
    final b = StringBuffer();
    for (var i = 0; i < d.length; i++) {
      if (i > 0 && (d.length - i) % 3 == 0) b.write('.');
      b.write(d[i]);
    }
    return '${r < 0 ? '-' : ''}Rp $b';
  }
}

/// Terjemahan teks (app ini hanya Bahasa Indonesia) -> teks apa adanya.
String ot(String s) => s;

class OmniLocaleController {
  static Locale effectiveLocale() => const Locale('id');
}

class OmniAccentController {
  static final ValueNotifier<String> accent = ValueNotifier<String>('default');
  static Color tint(bool dark) => app.accent;
}

/// Tab "Ads ROAS" di modul Satuan Shopee. Sebagian besar tetap stateless —
/// modal, harga jual, biaya admin/platform dikirim dari single_calc.dart
/// yang sudah menghitung ulang lewat _calculateExact()/setState bawaan.
///
/// UI di-refresh dengan gaya iOS modern: kartu tanpa border tebal (pakai
/// shadow tipis), ikon SF-style di dalam badge bulat bertinta warna, dan
/// dialog ala Cupertino untuk info tambahan (menggantikan Tooltip Material).
///
/// Widget ini StatefulWidget hanya untuk menampung input lokal "Budget
/// Iklan" — constructor & parameter publiknya tetap sama seperti
/// sebelumnya, jadi tidak perlu perubahan apa pun di single_calc.dart.
// v-AbuIOS-AdsRoas (permintaan user): aksen utama UI ini netral abu-abu
// (iOS systemGray). Hijau/merah HANYA untuk nilai plus/minus (mis. estimasi
// profit untung/rugi) dan status Rugi.
const Color _kIosGray = Color(0xFF8E8E93);

// v-WarnaLayak-AdsRoas (permintaan user): warna sinyal memakai warna sistem
// iOS asli (hijau/merah/oranye, varian lebih terang di mode gelap) supaya
// untung/rugi dan peringatan langsung terbaca jelas.
Color _iosGreen(BuildContext c) => omniIsDark(c)
    ? const Color(0xFF30D158)
    : const Color(0xFF34C759);
Color _iosRed(BuildContext c) => omniIsDark(c)
    ? const Color(0xFFFF453A)
    : const Color(0xFFFF3B30);
Color _iosOrange(BuildContext c) => omniIsDark(c)
    ? const Color(0xFFFF9F0A)
    : const Color(0xFFFF9500);

// v-MiniToggle-AdsRoas: opsi untuk kontrol segmen mini (ringkas).
class _MiniOpt<T> {
  final T value;
  final String? label;
  final IconData? icon;
  const _MiniOpt(this.value, {this.label, this.icon});
}

/// v-AutoSimpan: penyimpanan ringan untuk modul Ads. Data disimpan di memori
/// (aman saat pindah modul) DAN di perangkat lewat shared_preferences (aman
/// saat aplikasi ditutup). Penulisan ditunda 0,4 detik supaya tidak menulis
/// setiap ketukan.
class AdsPersist {
  AdsPersist._();
  static final Map<String, String> _cache = <String, String>{};
  static final Map<String, String> _pending = <String, String>{};
  static Timer? _timer;
  static Future<void>? _loading;
  static bool _loaded = false;

  static bool get loaded => _loaded;

  static Future<void> ensureLoaded() => _loading ??= _load();

  static Future<File> _file() async {
    final Directory base = await getApplicationSupportDirectory();
    final Directory d = Directory('${base.path}${Platform.pathSeparator}katalog');
    await d.create(recursive: true);
    return File('${d.path}${Platform.pathSeparator}ads_persist.json');
  }

  static Future<void> _load() async {
    try {
      final File f = await _file();
      if (await f.exists()) {
        final dynamic m = jsonDecode(await f.readAsString());
        if (m is Map) {
          m.forEach((dynamic k, dynamic v) {
            if (v is String) _cache['$k'] = v;
          });
        }
      }
    } catch (_) {}
    _loaded = true;
  }

  static String? read(String key) => _cache[key];

  static void write(String key, String value) {
    // Sebelum data lama selesai dibaca, jangan menimpa apa pun.
    if (!_loaded || _cache[key] == value) return;
    _cache[key] = value;
    _pending[key] = value;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 400), flushNow);
  }

  static Future<void> flushNow() async {
    _timer?.cancel();
    if (_pending.isEmpty) return;
    _pending.clear();
    try {
      final File f = await _file();
      await f.writeAsString(jsonEncode(_cache));
    } catch (_) {}
  }
}

class AdsRoasPanel extends StatefulWidget {
  final double modal;
  final double price;
  final double totalPlatformFee; // Total biaya admin/platform
  final Color brandColor;
  final bool landscape;
  // v-Android-SisiRapat: true -> padding horizontal kartu dipersempit
  // (khusus Android portrait, dikirim dari single_calc.dart). Default false
  // supaya pemakaian lain tidak berubah.
  final bool tightSides;

  // v-IsiLayar-AdsRoas: true -> pada layout lebar (>= 860 px) kartu "Target
  // profit" dan "Simulasi Anggaran" dibuat SAMA TINGGI dan memanjang sampai
  // dasar area gulir terdekat (dipakai modul Ads di Windows). Default false:
  // perilaku di modul Satuan tidak berubah sama sekali.
  final bool fillViewport;

  // Ruang yang disisakan di bawah kartu saat [fillViewport] aktif (padding
  // bawah milik pemanggil).
  final double fillBottomReserve;

  // v-AutoSimpan: kalau diisi, isian panel (target profit/ROAS, budget, mode)
  // disimpan otomatis dengan kunci ini dan dipulihkan saat panel dibuka lagi.
  // null (default) = tidak menyimpan apa pun, perilaku lama.
  final String? persistKey;

  // followPrice: true -> target profit (mode Rp, tidak otomatis) ikut berubah
  // proporsional saat harga berubah, termasuk saat panel dibuka lagi untuk harga lain
  // (persen terhadap harga dipertahankan). Default false = perilaku lama.
  final bool followPrice;

  const AdsRoasPanel({
    super.key,
    required this.modal,
    required this.price,
    required this.totalPlatformFee,
    required this.brandColor,
    required this.landscape,
    this.tightSides = false,
    this.fillViewport = false,
    this.fillBottomReserve = 0,
    this.persistKey,
    this.followPrice = false,
  });

  @override
  State<AdsRoasPanel> createState() => _AdsRoasPanelState();
}

class _AdsRoasPanelState extends State<AdsRoasPanel> {
  final TextEditingController _budgetCtrl = TextEditingController();
  final FocusNode _budgetFocus = FocusNode();

  // v-IsiLayar-AdsRoas: pengukuran tinggi dua kartu sejajar (lihat
  // [AdsRoasPanel.fillViewport]). Tanpa IntrinsicHeight -- kartu target
  // berisi LayoutBuilder. Kedua kartu diberi minHeight yang sama:
  //   minHeight = max(sisa tinggi layar, tinggi alami kartu terpanjang).
  final GlobalKey _cardsRowKey = GlobalKey();
  final GlobalKey _cardTargetKey = GlobalKey();
  final GlobalKey _cardSimKey = GlobalKey();
  double _minCardH = 0.0;
  double _natCardH = 0.0;
  double _lastRowW = -1;

  void _scheduleFillMeasure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final RenderObject? row = _cardsRowKey.currentContext?.findRenderObject();
      final double? t = _cardTargetKey.currentContext?.size?.height;
      final double? s2 = _cardSimKey.currentContext?.size?.height;
      final ScrollableState? sc = Scrollable.maybeOf(context);
      if (row is! RenderBox || !row.attached || t == null || s2 == null) {
        return;
      }
      if (sc == null) return;
      final RenderAbstractViewport? vp = RenderAbstractViewport.maybeOf(row);
      if (vp == null) return;
      final double top = vp.getOffsetToReveal(row, 0.0).offset;
      final double fill = sc.position.viewportDimension -
          top -
          widget.fillBottomReserve;
      final double m = math.max(t, s2);
      // Lebih tinggi dari minHeight yang dipaksakan = itu tinggi alaminya.
      if (m > _minCardH + 0.5) _natCardH = m;
      final double h = math.max(fill, _natCardH);
      if ((h - _minCardH).abs() > 0.5) setState(() => _minCardH = h);
    });
  }

  Widget _equalCard(GlobalKey key, Widget child) => KeyedSubtree(
        key: key,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: _minCardH),
          child: child,
        ),
      );
  // Key ditempel ke pembungkus field budget, dipakai buat Scrollable.ensureVisible
  // supaya field otomatis naik menghindari keyboard — jaga-jaga kalau parent
  // Scrollable tidak auto-scroll sendiri (mis. di dalam PageView/tab statis).
  final GlobalKey _budgetFieldKey = GlobalKey();
  bool _isFormatting = false;
  // Tooltip bantuan Ketik/Geser (popover ala iOS).
  OverlayEntry? _tipEntry;
  // v-HoverTip-AdsRoas: tooltip muncul saat kursor menyentuh ikon (jeda
  // singkat), hilang saat kursor menjauh atau diklik. Di layar sentuh, ketuk
  // membukanya ("sticky") dan ketuk di mana saja menutupnya.
  Timer? _tipTimer;
  bool _tipSticky = false;
  Object? _tipOwner;

  // v-ROAS-Ideal: input target profit setelah iklan. Default 10% dari harga.
  // _targetIsRp false = persen dari harga jual, true = nominal Rp per order.
  final TextEditingController _targetCtrl = TextEditingController();
  // v-Default-AdsRoas: target profit default berformat Rp (10% dari harga
  // jual, dihitung otomatis) dan input default mode Geser.
  bool _targetIsRp = true;
  // true = nilai Rp masih otomatis (10% harga jual) dan ikut berubah saat
  // harga jual berubah; jadi false begitu user mengubah target sendiri.
  bool _targetAuto = true;
  // Dasar ROAS untuk Simulasi Anggaran: false = Aman (default, perilaku
  // lama), true = Ideal.
  bool _simUseIdeal = false;

  // v-Geser-AdsRoas: tiap input bisa diisi dengan mengetik (default, perilaku
  // lama) atau menggeser slider. Nilai tetap disimpan di controller yang
  // sama, jadi pindah mode tidak menghilangkan angka.
  bool _targetSlide = true;
  bool _budgetSlide = true;

  // v-TargetROAS: mode "Target ROAS". Kalau aktif, user memilih ROAS yang
  // diinginkan (mis. 5x) dan target profit dihitung BALIK dari situ:
  //   Target Profit = Profit Bersih - Harga Jual / ROAS
  // sehingga ROAS Ideal pas persis di angka yang dipilih (tidak perlu
  // menebak-nebak nominal profit lagi).
  bool _roasMode = false;
  double _roasGoal = 5.0;
  final TextEditingController _roasGoalCtrl = TextEditingController();

  // Target ROAS "aman" disarankan di atas titik impas (BEP), supaya iklan
  // tidak sekadar balik modal tapi juga menyisakan profit. 30% adalah
  // asumsi buffer awal — bisa disesuaikan lagi kalau mau dibuat adjustable.
  static const double _targetAmanMultiplier = 1.3;

  // --- v-Desktop-macOS: mode kompatibel laptop -----------------------------
  // Panel ini awalnya didesain buat layar ponsel (font & padding kecil,
  // `landscape` cuma soal orientasi sempit-vs-lebar). Saat window app dibuka
  // di layar laptop/macOS, lebar window jauh lebih besar dari HP landscape
  // sekalipun, tapi teksnya ikut mini seperti di HP -- makanya dibedakan
  // lewat breakpoint lebar layar absolut di sini, independen dari flag
  // `landscape` yang dikirim dari parent.
  static const double _kDesktopBreakpoint = 700;
  static const double _kWideDesktopBreakpoint = 1200;

  bool _isDesktop(BuildContext context) =>
      MediaQuery.of(context).size.width >= _kDesktopBreakpoint;

  // Skala tambahan untuk UKURAN FONT & ikon -- dinaikkan lebih agresif
  // karena itu yang paling kelihatan "kekecilan" di layar besar.
  double _fontScale(BuildContext context) {
    final double w = MediaQuery.of(context).size.width;
    if (w >= _kWideDesktopBreakpoint) return 1.08;
    if (w >= _kDesktopBreakpoint) return 1.0;
    return 1.0;
  }

  // Skala untuk PADDING/GAP -- dibuat lebih halus dari skala font (60% dari
  // kenaikan font) supaya kartu tidak jadi kelewat lega/renggang, hanya
  // proporsional lebih longgar seperti UI desktop pada umumnya.
  double _spaceScale(BuildContext context) {
    final double fontScale = _fontScale(context);
    return 1.0 + (fontScale - 1.0) * 0.6;
  }

  double _fs(BuildContext context, double base) => base * _fontScale(context);

  double _sp(BuildContext context, double base) => base * _spaceScale(context);

  @override
  void initState() {
    super.initState();
    _restorePanel();
    if (widget.persistKey != null && !AdsPersist.loaded) {
      AdsPersist.ensureLoaded().then((_) {
        // Pulihkan hanya kalau user belum sempat mengisi apa pun.
        if (!mounted || !_targetAuto || _budgetCtrl.text.isNotEmpty) return;
        setState(() {
          _restorePanel();
          _applyAutoTarget();
        });
      });
    }
    _applyAutoTarget();
    _budgetCtrl.addListener(_onBudgetChanged);
    _budgetFocus.addListener(_onBudgetFocusChanged);
  }

  // --- v-AutoSimpan ---------------------------------------------------------
  String _panelSnapshot() => jsonEncode(<String, Object>{
        'target': _targetCtrl.text,
        'targetIsRp': _targetIsRp,
        'targetAuto': _targetAuto,
        'targetSlide': _targetSlide,
        'budget': _budgetCtrl.text,
        'budgetSlide': _budgetSlide,
        'simIdeal': _simUseIdeal,
        'roasMode': _roasMode,
        'roasGoal': _roasGoal,
        'basePrice': widget.price,
      });

  void _restorePanel() {
    final String? key = widget.persistKey;
    if (key == null) return;
    final String? raw = AdsPersist.read(key);
    if (raw == null) return;
    try {
      final Map<String, dynamic> m = jsonDecode(raw) as Map<String, dynamic>;
      _targetIsRp = (m['targetIsRp'] as bool?) ?? _targetIsRp;
      _targetAuto = (m['targetAuto'] as bool?) ?? _targetAuto;
      _targetSlide = (m['targetSlide'] as bool?) ?? _targetSlide;
      _budgetSlide = (m['budgetSlide'] as bool?) ?? _budgetSlide;
      _simUseIdeal = (m['simIdeal'] as bool?) ?? _simUseIdeal;
      _roasMode = (m['roasMode'] as bool?) ?? _roasMode;
      final num? g = m['roasGoal'] as num?;
      if (g != null && g > 0) _roasGoal = g.toDouble();
      _roasGoalCtrl.text = _fmtX(_roasGoal);
      _targetCtrl.text = (m['target'] as String?) ?? '';
      _budgetCtrl.text = (m['budget'] as String?) ?? '';
      // followPrice: skala ulang target Rp dari harga saat disimpan ke harga sekarang.
      final num? bp = m['basePrice'] as num?;
      if (widget.followPrice &&
          bp != null &&
          bp > 0 &&
          widget.price > 0 &&
          bp != widget.price &&
          !_targetAuto &&
          _targetIsRp &&
          !_roasMode) {
        final double cur =
            double.tryParse(_targetCtrl.text.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
        if (cur > 0) {
          _targetCtrl.text = _dotGroup((cur * widget.price / bp).round().toString());
        }
      }
    } catch (_) {}
  }

  void _applyAutoTarget() {
    if (!_targetAuto || !_targetIsRp || widget.price <= 0) return;
    _targetCtrl.text = _dotGroup((widget.price * 0.10).round().toString());
  }

  @override
  void didUpdateWidget(covariant AdsRoasPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.price != widget.price) {
      if (widget.followPrice &&
          !_targetAuto &&
          _targetIsRp &&
          !_roasMode &&
          oldWidget.price > 0 &&
          widget.price > 0) {
        final double cur =
            double.tryParse(_targetCtrl.text.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
        if (cur > 0) {
          _targetCtrl.text =
              _dotGroup((cur * widget.price / oldWidget.price).round().toString());
        }
      } else {
        _applyAutoTarget();
      }
    }
  }

  void _onBudgetFocusChanged() {
    if (!_budgetFocus.hasFocus) return;
    // Tunggu keyboard mulai muncul & layout selesai sebelum scroll, biar
    // hasil ensureVisible menghitung viewInsets keyboard yang sudah update.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 260), () {
        final ctx = _budgetFieldKey.currentContext;
        if (ctx == null || !mounted || !ctx.mounted) return;
        // v-Fix-GeserBundling: tanpa keyboard layar (Windows/macOS/Linux,
        // atau HP dengan keyboard fisik) tidak ada yang perlu dihindari.
        if (MediaQuery.viewInsetsOf(ctx).bottom <= 0) return;
        // Scrollable.ensureVisible menggulung SEMUA Scrollable induk,
        // termasuk PageView horizontal antar modul (Satuan/Bundling/...) --
        // itu yang bikin halaman ikut bergeser ke Bundling lalu pegas balik.
        // Cukup gulung Scrollable terdekat yang vertikal.
        final ScrollableState? scroll = Scrollable.maybeOf(ctx);
        final RenderObject? target = ctx.findRenderObject();
        if (scroll == null || target == null) return;
        if (scroll.axisDirection != AxisDirection.down &&
            scroll.axisDirection != AxisDirection.up) {
          return;
        }
        scroll.position.ensureVisible(
          target,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
          alignment: 0.2,
        );
      });
    });
  }

  @override
  void dispose() {
    _hideModeTip();
    _budgetCtrl.removeListener(_onBudgetChanged);
    _budgetCtrl.dispose();
    _budgetFocus.removeListener(_onBudgetFocusChanged);
    _budgetFocus.dispose();
    _targetCtrl.dispose();
    _roasGoalCtrl.dispose();
    unawaited(AdsPersist.flushNow());
    super.dispose();
  }

  void _onBudgetChanged() {
    if (_isFormatting) return;
    final String text = _budgetCtrl.text;
    if (text.isEmpty) return;
    final String clean = text.replaceAll(RegExp(r'[^0-9]'), '');
    final String formatted = _dotGroup(clean);
    _isFormatting = true;
    try {
      _budgetCtrl.value = TextEditingValue(
        text: formatted,
        selection: TextSelection.collapsed(offset: formatted.length),
      );
    } finally {
      _isFormatting = false;
    }
    setState(() {});
  }

  String _dotGroup(String digits) {
    if (digits.isEmpty) return '';
    final buffer = StringBuffer();
    for (int i = 0; i < digits.length; i++) {
      final int posFromEnd = digits.length - i;
      buffer.write(digits[i]);
      if (posFromEnd > 1 && (posFromEnd - 1) % 3 == 0) {
        buffer.write('.');
      }
    }
    return buffer.toString();
  }

  // v-Fix-i18n-AdsRoas: helper kecil untuk bentuk jamak "order"/"orders"
  // saat Bahasa Inggris aktif. Bahasa Indonesia tidak mengenal bentuk jamak
  // jadi tetap "order" berapa pun jumlahnya.
  String _orderUnitLabel(int count) {
    final bool isEnglish =
        OmniLocaleController.effectiveLocale().languageCode.toLowerCase() ==
            'en';
    if (!isEnglish) return 'order';
    return count == 1 ? 'order' : 'orders';
  }

  double get _budget {
    final String clean = _budgetCtrl.text.replaceAll(RegExp(r'[^0-9]'), '');
    return clean.isEmpty ? 0.0 : double.tryParse(clean) ?? 0.0;
  }

  // Target profit per order (Rp) dari input: persen dari harga jual atau
  // nominal Rp langsung.
  double _targetProfitRp(double price) {
    // v-TargetROAS: mode Target ROAS -> profit dihitung balik dari ROAS.
    if (_roasMode) {
      final double pb = price - widget.modal - widget.totalPlatformFee;
      if (price <= 0 || pb <= 0 || _roasGoal <= 0) return 0.0;
      return math.max(0.0, pb - price / _roasGoal);
    }
    final String raw = _targetCtrl.text.trim();
    if (raw.isEmpty) return 0.0;
    if (_targetIsRp) {
      final String digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
      return double.tryParse(digits) ?? 0.0;
    }
    final double pct = double.tryParse(raw.replaceAll(',', '.')) ?? 0.0;
    return price * pct.clamp(0.0, 100.0).toDouble() / 100.0;
  }

  void _onTargetChanged(String v) {
    _targetAuto = false;
    if (_targetIsRp) {
      final String clean = v.replaceAll(RegExp(r'[^0-9]'), '');
      final String formatted = _dotGroup(clean);
      if (formatted != v) {
        _targetCtrl.value = TextEditingValue(
          text: formatted,
          selection: TextSelection.collapsed(offset: formatted.length),
        );
      }
    }
    setState(() {});
  }

  String _bepInfoMessage(double roasBep, double roasAman) {
    return 'ROAS Impas (BEP) = Harga Jual / Profit Bersih'
        '${roasBep > 0 ? ' (${roasBep.toStringAsFixed(2)}x)' : ''}. '
        'Di bawah angka ini iklan menghabiskan seluruh profit.\n\n'
        'ROAS Aman = BEP + buffer 30%'
        '${roasAman > 0 ? ' (${roasAman.toStringAsFixed(2)}x)' : ''}. '
        'Saran umum agar masih ada sisa untung.\n\n'
        'ROAS Ideal = Harga Jual / (Profit Bersih - Target Profit). '
        'Ini ROAS minimum agar setelah iklan kamu tetap mendapat '
        'target profit yang kamu tentukan.';
  }

  // v-Tooltip-AdsRoas: ikon info kecil (i). Sentuh dengan kursor -> penjelasan
  // muncul; kursor menjauh atau klik -> hilang (lihat _tipTarget).
  Widget _infoDot(BuildContext context, String title, String message,
      {double? box, double? iconSize}) {
    final double b = box ?? _sp(context, 24);
    final double ic = iconSize ?? _sp(context, 16);
    return _tipTarget(
      label: title,
      estH: 50 + (message.length / 46).ceil() * 14.5,
      content: (BuildContext c) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OmniText(title,
              style: TextStyle(
                  fontSize: _fs(c, 11.5),
                  fontWeight: FontWeight.w700,
                  color: omniText(c))),
          const SizedBox(height: 3),
          OmniText(message,
              style: TextStyle(
                  fontSize: _fs(c, 10.5), height: 1.3, color: omniMuted(c))),
        ],
      ),
      child: SizedBox(
        width: b,
        height: b,
        child: Center(
          child: Icon(CupertinoIcons.info_circle,
              size: ic, color: omniMuted(context)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // v-AutoSimpan: tiap perubahan isian tercatat otomatis (ditulis hanya
    // kalau isinya berubah, dan ditunda sebentar).
    if (widget.persistKey != null) {
      AdsPersist.write(widget.persistKey!, _panelSnapshot());
    }
    final double modal = widget.modal;
    final double price = widget.price;
    final bool landscape = widget.landscape;

    // v-Desktop-macOS: shorthand lokal supaya pemanggilan di bawah tetap
    // ringkas -- fs() membesarkan ukuran font, sp() membesarkan
    // padding/gap/ukuran ikon, keduanya no-op (kembalikan nilai asli) kalau
    // window masih selebar HP.
    final bool desktop = _isDesktop(context);
    double fs(double base) => _fs(context, base);
    double sp(double base) => _sp(context, base);
    // v-Android-SisiRapat2: di HP (bukan window desktop) kartu selalu dibuat
    // mepet kiri-kanan, tidak tergantung parent mengirim tightSides atau tidak.
    final bool tight = widget.tightSides || !desktop;

    final double biayaAdmin = widget.totalPlatformFee;

    // Profit bersih per unit SEBELUM biaya iklan (harga - modal - admin).
    final double profitBersih = price - modal - biayaAdmin;
    final bool dataSiap = modal > 0 && price > 0 && biayaAdmin > 0;
    // ROAS Impas: BE ROAS = Harga Jual / Profit Bersih.
    final double roasTargetBep =
        dataSiap && profitBersih > 0 ? price / profitBersih : 0.0;
    // ROAS Aman (saran lama, tetap dipertahankan): BEP + buffer 30%.
    final double roasTargetAman = roasTargetBep * _targetAmanMultiplier;
    // v-ROAS-Ideal: ROAS minimum agar setelah iklan tetap dapat target
    // profit. Ideal = Harga Jual / (Profit Bersih - Target Profit).
    final double targetProfit = _targetProfitRp(price);
    final double sisaUntukIklan = profitBersih - targetProfit;
    final bool idealValid = dataSiap && profitBersih > 0 && sisaUntukIklan > 0;
    final double roasIdeal = idealValid ? price / sisaUntukIklan : 0.0;

    String status;
    String keterangan;
    IconData icon;
    Color statusColor;
    String heroLabel = 'ROAS';
    double heroRoas = 0.0;

    if (!dataSiap) {
      status = 'Belum Siap';
      keterangan =
          'Lengkapi modal, harga jual, dan pilih kategori agar biaya admin terhitung.';
      icon = CupertinoIcons.info_circle_fill;
      statusColor = omniMuted(context);
    } else if (profitBersih <= 0) {
      status = 'Rugi';
      keterangan =
          'Profit bersih sebelum iklan sudah ${Format.idr(profitBersih)} per produk. Naikkan harga atau turunkan modal dulu sebelum pasang iklan.';
      icon = CupertinoIcons.exclamationmark_triangle_fill;
      statusColor = _iosRed(context);
    } else if (!idealValid) {
      status = 'Target Tinggi';
      heroLabel = 'ROAS IMPAS (BEP)';
      heroRoas = roasTargetBep;
      keterangan =
          'Target profit ${Format.idr(targetProfit)} melebihi profit bersih sebelum iklan (${Format.idr(profitBersih)}). Turunkan target atau naikkan harga.';
      icon = CupertinoIcons.exclamationmark_circle_fill;
      statusColor = _iosOrange(context);
    } else {
      status = 'Layak Iklan';
      heroLabel = 'ROAS IDEAL';
      heroRoas = roasIdeal;
      keterangan =
          'Selama ROAS iklan minimal ${roasIdeal.toStringAsFixed(2)}x, kamu tetap dapat ${Format.idr(targetProfit)} per order. Biaya iklan maksimal ${Format.idr(sisaUntukIklan)} per order.';
      icon = CupertinoIcons.checkmark_seal_fill;
      statusColor = _iosGreen(context);
    }

    // Status "Layak Iklan" tidak lagi memakai aksen hijau -- netral abu-abu.
    final bool isGood = status == 'Layak Iklan';
    final Color tone = isGood ? _kIosGray : statusColor;
    // v-Ringkas-AdsRoas: keterangan status digabung ke kartu hero. Saat layak
    // iklan cukup satu kalimat pendek; status lain tetap penjelasan lengkap.
    final String heroNote = isGood
        ? 'Biaya iklan maks. ${Format.idr(sisaUntukIklan)} per order agar tetap dapat ${Format.idr(targetProfit)}.'
        : keterangan;

    final double gap = sp(landscape ? 10 : 12);
    final bool showRec = dataSiap && roasTargetBep > 0;

    // Judul halaman, di luar kartu (gaya header iOS).
    final Widget header = Padding(
      padding: EdgeInsets.symmetric(horizontal: tight ? 4 : sp(6)),
      child: Row(
        children: [
          _iconBadge(
              context: context,
              icon: CupertinoIcons.chart_bar_alt_fill,
              color: _kIosGray,
              size: landscape ? 28 : 32),
          SizedBox(width: sp(10)),
          Expanded(
            child: OmniText(
              'Analisis ROAS Iklan',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: fs(landscape ? 14 : 15),
                  letterSpacing: -0.2),
            ),
          ),
        ],
      ),
    );

    // Kartu hero: angka ROAS besar + status di satu baris, keterangan di
    // bawahnya, lalu dua angka acuan (BEP | Aman) dipisah garis tipis.
    final Widget statusGroup = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: _statusPill(context, status, tone, icon, landscape),
        ),
        _infoDot(
          context,
          'Apa itu ROAS Impas, Aman & Ideal?',
          _bepInfoMessage(roasTargetBep, roasTargetAman),
          box: sp(28),
          iconSize: sp(18),
        ),
      ],
    );

    final Widget heroLeft = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        OmniText(
          heroLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: fs(landscape ? 10 : 11),
              fontWeight: FontWeight.w600,
              color: omniMuted(context),
              letterSpacing: 0.4),
        ),
        SizedBox(height: sp(2)),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: OmniText(
            heroRoas > 0 ? '${heroRoas.toStringAsFixed(2)}x' : '-',
            maxLines: 1,
            style: TextStyle(
              fontSize: fs(landscape ? 24 : 30),
              fontWeight: FontWeight.w800,
              color: isGood ? omniText(context) : statusColor,
              letterSpacing: -0.8,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );

    // Layak iklan: satu kalimat polos. Status lain: kotak lembut berwarna.
    final Widget heroNoteW = isGood
        ? OmniText(
            heroNote,
            style: TextStyle(
                fontSize: fs(landscape ? 10 : 11.5),
                color: omniMuted(context),
                height: 1.35),
          )
        : Container(
            padding:
                EdgeInsets.symmetric(horizontal: sp(12), vertical: sp(10)),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: OmniText(
              heroNote,
              style: TextStyle(
                  fontSize: fs(landscape ? 10 : 11),
                  color: omniText(context),
                  height: 1.35),
            ),
          );

    // v-TooltipBEP-AdsRoas (permintaan user): penjelasan sederhana untuk
    // seller yang belum paham istilah BEP / ROAS Aman, lengkap dengan contoh
    // angka dari produk yang sedang dihitung.
    const double aman = _targetAmanMultiplier;
    final int amanLeftPct = ((1 - 1 / aman) * 100).round();
    final String bepTip = showRec
        ? 'BEP (Break Even Point) = titik impas. Ini ROAS paling rendah supaya iklan tidak membuat kamu rugi.\n\n'
            'ROAS ${roasTargetBep.toStringAsFixed(2)}x artinya tiap Rp 1 biaya iklan harus menghasilkan penjualan Rp ${roasTargetBep.toStringAsFixed(2)}.\n\n'
            'Tepat di angka ini, seluruh profit produk (${Format.idr(profitBersih)} per order) habis untuk bayar iklan: tidak untung, tidak rugi. Di bawah angka ini kamu rugi.'
        : 'BEP (Break Even Point) = titik impas. Ini ROAS paling rendah supaya iklan tidak membuat kamu rugi. Isi modal, harga, dan kategori dulu agar angkanya muncul.';
    final String amanTip = showRec
        ? 'ROAS Aman = BEP + buffer 30%. Ini angka yang disarankan jadi target iklan.\n\n'
            'Di ${roasTargetAman.toStringAsFixed(2)}x, biaya iklan sekitar ${Format.idr(price / roasTargetAman)} per order, jadi masih tersisa untung sekitar ${Format.idr(profitBersih - price / roasTargetAman)} (±$amanLeftPct% dari profit).\n\n'
            'Di antara BEP dan Aman: masih untung tapi tipis dan rawan rugi kalau performa iklan turun. Di atas Aman: untung lebih lega.'
        : 'ROAS Aman = BEP + buffer 30%. Ini angka yang disarankan jadi target iklan supaya masih ada sisa untung. Isi modal, harga, dan kategori dulu agar angkanya muncul.';
    Widget bepCell(EdgeInsetsGeometry pad) => _metric(
        context,
        'Minimum (BEP)',
        '${roasTargetBep.toStringAsFixed(2)}x',
        _iosOrange(context),
        landscape,
        padding: pad,
        trailing: _infoDot(context, 'Apa itu Minimum (BEP)?', bepTip,
            box: sp(20), iconSize: sp(13)));
    Widget amanCell(EdgeInsetsGeometry pad) => _metric(
        context,
        'Disarankan (Aman)',
        '${roasTargetAman.toStringAsFixed(2)}x',
        _iosGreen(context),
        landscape,
        padding: pad,
        trailing: _infoDot(context, 'Apa itu Disarankan (Aman)?', amanTip,
            box: sp(20), iconSize: sp(13)));

    // Layar lebar: ROAS | BEP | Aman | status dalam SATU baris (tidak ada
    // ruang kosong di kanan). Layar sempit: ROAS + status di atas, BEP | Aman
    // di bawah garis tipis.
    final Widget heroCard = _groupCard(
      context,
      child: LayoutBuilder(builder: (BuildContext ctx, BoxConstraints bc) {
        final bool wide = showRec && bc.maxWidth >= 640;
        if (wide) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 3,
                      child: Padding(
                        padding: EdgeInsets.only(right: sp(14)),
                        child: Align(
                            alignment: Alignment.centerLeft, child: heroLeft),
                      ),
                    ),
                    _vHairline(context),
                    Expanded(
                      flex: 3,
                      child: Align(
                          alignment: Alignment.centerLeft,
                          child: bepCell(
                              EdgeInsets.symmetric(horizontal: sp(16)))),
                    ),
                    _vHairline(context),
                    Expanded(
                      flex: 3,
                      child: Align(
                          alignment: Alignment.centerLeft,
                          child: amanCell(
                              EdgeInsets.symmetric(horizontal: sp(16)))),
                    ),
                    SizedBox(width: sp(8)),
                    Center(child: statusGroup),
                  ],
                ),
              ),
              SizedBox(height: sp(12)),
              heroNoteW,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: heroLeft),
                SizedBox(width: sp(8)),
                Flexible(
                  child: Align(
                      alignment: Alignment.centerRight, child: statusGroup),
                ),
              ],
            ),
            SizedBox(height: sp(10)),
            heroNoteW,
            if (showRec) ...[
              SizedBox(height: sp(12)),
              _hairline(context),
              SizedBox(height: sp(12)),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: bepCell(EdgeInsets.only(right: sp(12)))),
                    _vHairline(context),
                    Expanded(child: amanCell(EdgeInsets.only(left: sp(14)))),
                  ],
                ),
              ),
            ],
          ],
        );
      }),
    );

    final Widget card = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        SizedBox(height: sp(landscape ? 8 : 10)),
        heroCard,
        SizedBox(height: gap),

        // Data otomatis: daftar Modal / Harga Jual / Biaya Admin / Profit
        _statStrip(
            context,
            [
              ['Modal', Format.idr(modal)],
              ['Harga Jual', Format.idr(price)],
              ['Biaya Admin', Format.idr(biayaAdmin)],
              // Profit = hasil kalkulasi SEBELUM iklan (harga - modal - admin).
              ['Profit', dataSiap ? Format.idr(profitBersih) : '-'],
            ],
            landscape,
            valueColors: [
              null,
              null,
              null,
              if (dataSiap)
                profitBersih >= 0 ? _iosGreen(context) : _iosRed(context)
              else
                null,
            ]),

        if (dataSiap) ...[
          SizedBox(height: gap),
          LayoutBuilder(builder: (BuildContext ctx, BoxConstraints bc) {
            final Widget target = _roasTargetSection(
                context,
                roasTargetBep,
                roasTargetAman,
                profitBersih,
                roasIdeal,
                idealValid,
                targetProfit,
                sisaUntukIklan,
                landscape);
            final Widget sim = _budgetSimulationSection(context, price,
                profitBersih, roasTargetAman, roasIdeal, idealValid, landscape);
            if (bc.maxWidth >= 860) {
              // Tanpa IntrinsicHeight: kartu target berisi LayoutBuilder
              // (bar profit) yang tidak boleh berada di dalamnya.
              if (widget.fillViewport) {
                // Lebar berubah -> tinggi alami bisa berubah, ukur ulang.
                if (bc.maxWidth != _lastRowW) {
                  _lastRowW = bc.maxWidth;
                  _natCardH = 0.0;
                  _minCardH = 0.0;
                }
                _scheduleFillMeasure();
                return Row(
                  key: _cardsRowKey,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _equalCard(_cardTargetKey, target)),
                    SizedBox(width: gap),
                    Expanded(child: _equalCard(_cardSimKey, sim)),
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: target),
                  SizedBox(width: gap),
                  Expanded(child: sim),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [target, SizedBox(height: gap), sim],
            );
          }),
        ],
      ],
    );

    // v-LebarSelaras-AdsRoas: di desktop kartu TIDAK lagi dibatasi lebar
    // maksimum & ditengahkan, supaya lebarnya sama persis dengan tab Smart
    // Pricing / Seller Intelligence (penuh kiri-kanan kolom tengah).
    return card;
  }

  // --- Komponen kecil bergaya iOS -----------------------------------------

  // Tanda pembeda judul kartu: garis vertikal tipis (menggantikan badge ikon
  // bulat). Parameter [icon] dipertahankan supaya pemanggilan lama tetap jalan,
  // tetapi tidak digambar lagi.
  Widget _iconBadge(
      {required BuildContext context,
      required IconData icon,
      required Color color,
      double size = 36}) {
    final double h = _sp(context, size) * 0.78;
    return Container(
      width: _sp(context, 4),
      height: h,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }

  Widget _statusPill(BuildContext context, String label, Color color,
      IconData icon, bool landscape) {
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: _sp(context, landscape ? 8 : 10),
          vertical: _sp(context, landscape ? 5 : 6)),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon,
              size: _fs(context, landscape ? 12 : 13),
              color: CupertinoColors.white),
          SizedBox(width: _sp(context, 4)),
          // v-Fix-Overflow-AdsRoas: teks status dibungkus Flexible + ellipsis
          // supaya kalau pill ini diberi batas lebar sempit (lihat pemakaian
          // Flexible di hero stat row), teks otomatis terpotong "..." rapi
          // alih-alih overflow.
          Flexible(
            child: OmniText(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: _fs(context, landscape ? 10 : 11.5),
                fontWeight: FontWeight.w700,
                color: CupertinoColors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- Helper gaya iOS "inset grouped" --------------------------------------
  // Satu kartu putih membulat, tanpa border tebal, shadow tipis. Semua seksi
  // memakai kartu yang sama supaya jarak & sudut seragam.
  Widget _groupCard(BuildContext context,
      {required Widget child, EdgeInsetsGeometry? padding}) {
    return Container(
      width: double.infinity,
      padding: padding ??
          EdgeInsets.all(_isDesktop(context) ? _sp(context, 16) : 16),
      decoration: BoxDecoration(
        color: omniElevated(context),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
            color: omniStroke(context).withValues(alpha: 0.35), width: 0.5),
        boxShadow: [
          BoxShadow(
            color: omniStroke(context).withValues(alpha: 0.20),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }

  // Garis pemisah tipis (hairline) horizontal & vertikal.
  Widget _hairline(BuildContext context) => Container(
        height: 0.5,
        color: omniStroke(context).withValues(alpha: 0.6),
      );

  Widget _vHairline(BuildContext context) => Container(
        width: 0.5,
        color: omniStroke(context).withValues(alpha: 0.6),
      );

  // Daftar ringkas ala Pengaturan iOS: label di kiri, nilai di kanan, dipisah
  // garis tipis. Menggantikan strip 4 kolom yang sempit di layar HP.
  Widget _statStrip(
      BuildContext context, List<List<String>> items, bool landscape,
      {List<Color?>? valueColors}) {
    Color? colorAt(int i) =>
        (valueColors != null && i < valueColors.length) ? valueColors[i] : null;
    TextStyle valStyle(int i, double size) => TextStyle(
          fontSize: _fs(context, size),
          fontWeight:
              i == items.length - 1 ? FontWeight.w800 : FontWeight.w600,
          color: colorAt(i) ?? omniText(context),
          fontFeatures: const [FontFeature.tabularFigures()],
        );
    return _groupCard(
      context,
      padding: EdgeInsets.symmetric(
          horizontal: _isDesktop(context) ? _sp(context, 16) : 16),
      child: LayoutBuilder(builder: (BuildContext ctx, BoxConstraints bc) {
        if (bc.maxWidth >= 560) {
          // Lebar: satu baris, tiap kolom label di atas + nilai di bawah.
          return Padding(
            padding: EdgeInsets.symmetric(vertical: _sp(context, 12)),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (int i = 0; i < items.length; i++) ...[
                    if (i > 0) _vHairline(context),
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(
                            left: i == 0 ? 0 : _sp(context, 16)),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            OmniText(
                              items[i][0],
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: _fs(context, 10.5),
                                  color: omniMuted(context)),
                            ),
                            SizedBox(height: _sp(context, 3)),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: OmniText(items[i][1],
                                  maxLines: 1, style: valStyle(i, 14)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        }
        // Sempit: daftar ala Pengaturan iOS, label kiri & nilai rata kanan.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (int i = 0; i < items.length; i++) ...[
              if (i > 0) _hairline(context),
              Padding(
                padding: EdgeInsets.symmetric(vertical: _sp(context, 10)),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // v-RataKanan-AdsRoas (permintaan user): sebelumnya nilai
                    // (Rp 29.500 dst.) bergeser mengikuti panjang label karena
                    // label & nilai berbagi sisa lebar. Sekarang label
                    // mengisi sisa ruang (Expanded) dan nilai ada di kolom
                    // kanan yang ujungnya SELALU rata di tepi kanan kartu.
                    Expanded(
                      child: OmniText(
                        items[i][0],
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: _fs(context, landscape ? 11 : 12.5),
                            color: omniMuted(context)),
                      ),
                    ),
                    SizedBox(width: _sp(context, 8)),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 160),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: OmniText(items[i][1],
                            maxLines: 1,
                            textAlign: TextAlign.right,
                            style: valStyle(i, landscape ? 11.5 : 13)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        );
      }),
    );
  }

  // --- v-Geser-AdsRoas: helper slider ---------------------------------------
  // Pembulatan "cantik" ke atas (1/2/5 x 10^n) supaya ujung slider tidak
  // berupa angka acak.
  double _niceCeil(double v) {
    if (v <= 1) return 1;
    double m = 1;
    while (m * 10 <= v) {
      m *= 10;
    }
    for (final double f in const [1, 2, 5, 10]) {
      if (m * f >= v) return m * f;
    }
    return m * 10;
  }

  // Langkah geser disesuaikan dengan besar nilainya (target ~100 langkah).
  double _niceStep(double raw) {
    for (final double st in const [
      50, 100, 250, 500, 1000, 2500, 5000, 10000, 25000, 50000, 100000
    ]) {
      if (st >= raw) return st;
    }
    return 100000;
  }

  // v-MiniToggle-AdsRoas: kontrol segmen kecil berbentuk pil. Segmen aktif
  // terisi abu-abu; kalau punya ikon, hanya segmen aktif yang menampilkan
  // teks, jadi lebarnya jauh lebih ramping dari segmented control iOS biasa.
  Widget _miniToggle<T>(BuildContext context,
      {required T value,
      required List<_MiniOpt<T>> options,
      required ValueChanged<T> onChanged}) {
    final bool dark = omniIsDark(context);
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: omniStroke(context).withValues(alpha: dark ? 0.40 : 0.28),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final _MiniOpt<T> o in options)
            _miniSegment<T>(context, o, o.value == value, onChanged),
        ],
      ),
    );
  }

  Widget _miniSegment<T>(BuildContext context, _MiniOpt<T> o, bool on,
      ValueChanged<T> onChanged) {
    final bool showLabel = o.label != null && (on || o.icon == null);
    final Color fg = on ? omniText(context) : omniMuted(context);
    return Semantics(
      button: true,
      selected: on,
      label: o.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (on) return;
          HapticFeedback.selectionClick();
          onChanged(o.value);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          height: _sp(context, 26),
          alignment: Alignment.center,
          padding: EdgeInsets.symmetric(
              horizontal: _sp(context, o.icon != null && !showLabel ? 8 : 10)),
          decoration: BoxDecoration(
            // v-iOSThumb-AdsRoas: segmen aktif = "thumb" putih (mode gelap:
            // abu tua) dengan bayangan tipis, persis segmented control iOS.
            color: on
                ? (omniIsDark(context)
                    ? const Color(0xFF636366)
                    : CupertinoColors.white)
                : const Color(0x00000000),
            borderRadius: BorderRadius.circular(999),
            boxShadow: on
                ? [
                    BoxShadow(
                      color: const Color(0xFF000000).withValues(alpha: 0.14),
                      blurRadius: 4,
                      offset: const Offset(0, 1.5),
                    ),
                  ]
                : null,
          ),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (o.icon != null)
                  Icon(o.icon, size: _fs(context, 14), color: fg),
                if (o.icon != null && showLabel)
                  SizedBox(width: _sp(context, 4)),
                if (showLabel)
                  OmniText(
                    o.label!,
                    maxLines: 1,
                    style: TextStyle(
                        fontSize: _fs(context, 11.5),
                        fontWeight: FontWeight.w600,
                        color: fg),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Ketik / Geser: dua ikon kecil (keyboard & slider); teks muncul hanya di
  // pilihan yang aktif. Ikon (?) di sampingnya membuka tooltip bantuan.
  Widget _inputModeToggle(
      BuildContext context, bool slide, ValueChanged<bool> onChanged) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _miniToggle<bool>(
          context,
          value: slide,
          options: const <_MiniOpt<bool>>[
            _MiniOpt<bool>(false,
                label: 'Ketik', icon: CupertinoIcons.keyboard),
            _MiniOpt<bool>(true,
                label: 'Geser', icon: CupertinoIcons.slider_horizontal_3),
          ],
          onChanged: onChanged,
        ),
        _modeHelpDot(),
      ],
    );
  }

  // v-TooltipIOS-AdsRoas: ikon tanda tanya kecil -> popover bergaya iOS
  // (gelembung + panah) yang menjelaskan Ketik vs Geser. Ketuk di mana saja
  // untuk menutup; hilang sendiri setelah beberapa detik.
  Widget _modeHelpDot() {
    return Builder(
      builder: (BuildContext ctx) => _tipTarget(
        label: 'Bantuan Ketik dan Geser',
        estH: 120,
        content: _modeTipContent,
        child: Padding(
          padding: EdgeInsets.symmetric(
              horizontal: _sp(ctx, 5), vertical: _sp(ctx, 4)),
          child: Icon(CupertinoIcons.question_circle,
              size: _sp(ctx, 17), color: omniMuted(ctx)),
        ),
      ),
    );
  }

  // Pembungkus semua ikon bantuan: hover -> muncul, menjauh -> hilang,
  // klik -> tutup (kalau sedang terbuka) / buka tetap (kalau sentuh).
  Widget _tipTarget({
    required Widget child,
    required Widget Function(BuildContext anchor) content,
    required double estH,
    String? label,
  }) {
    return Builder(
      builder: (BuildContext ctx) => Semantics(
        button: true,
        label: label,
        child: MouseRegion(
          cursor: SystemMouseCursors.basic,
          onEnter: (_) {
            _tipTimer?.cancel();
            if (_tipEntry != null) return;
            _tipTimer = Timer(const Duration(milliseconds: 140), () {
              if (!mounted || !ctx.mounted || _tipEntry != null) return;
              _presentTip(ctx, content(ctx), estH, sticky: false);
            });
          },
          onExit: (_) {
            _tipTimer?.cancel();
            if (identical(_tipOwner, ctx) && !_tipSticky) _hideModeTip();
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              _tipTimer?.cancel();
              if (_tipEntry != null) {
                _hideModeTip();
                return;
              }
              _presentTip(ctx, content(ctx), estH, sticky: true);
            },
            child: child,
          ),
        ),
      ),
    );
  }

  void _hideModeTip() {
    _tipTimer?.cancel();
    _tipEntry?.remove();
    _tipEntry = null;
    _tipOwner = null;
    _tipSticky = false;
  }

  Widget _modeTipContent(BuildContext anchor) {
    final Color txt = omniText(anchor);
    final Color muted = omniMuted(anchor);
    Widget tipRow(IconData icon, String title, String body) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            decoration:
                const BoxDecoration(color: _kIosGray, shape: BoxShape.circle),
            child: Icon(icon, size: 12, color: CupertinoColors.white),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                OmniText(title,
                    style: TextStyle(
                        fontSize: _fs(anchor, 11.5),
                        fontWeight: FontWeight.w700,
                        color: txt)),
                const SizedBox(height: 1),
                OmniText(body,
                    style: TextStyle(
                        fontSize: _fs(anchor, 10.5),
                        height: 1.25,
                        color: muted)),
              ],
            ),
          ),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        tipRow(
            CupertinoIcons.keyboard,
            'Ketik',
            'Isi angka sendiri lewat keyboard. Pas kalau kamu sudah tahu nominal atau persen yang diinginkan.'),
        const SizedBox(height: 7),
        tipRow(
            CupertinoIcons.slider_horizontal_3,
            'Geser',
            (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
                ? 'Tahan slider sebentar sampai terasa getar, lalu geser untuk coba-coba angka. Hasilnya langsung berubah.'
                : 'Tarik slider untuk coba-coba angka. Hasilnya langsung berubah saat digeser.'),
        const SizedBox(height: 7),
        OmniText(
          'Angka tidak hilang saat kamu pindah mode.',
          style: TextStyle(fontSize: _fs(anchor, 10), color: muted),
        ),
      ],
    );
  }

  // Gelembung bergaya iOS (kartu + panah). Mode hover: tidak menangkap
  // pointer & tanpa penghalang layar. Mode sticky (sentuh): ketuk di mana
  // saja menutup, dan hilang sendiri setelah beberapa detik.
  void _presentTip(BuildContext anchor, Widget content, double estH,
      {required bool sticky}) {
    _hideModeTip();
    final RenderObject? ro = anchor.findRenderObject();
    if (ro is! RenderBox || !ro.attached) return;
    final OverlayState? overlay = Overlay.maybeOf(anchor, rootOverlay: true);
    if (overlay == null) return;

    final Offset pos = ro.localToGlobal(Offset.zero);
    final Size size = ro.size;
    final MediaQueryData mq = MediaQuery.of(anchor);
    final Size screen = mq.size;
    final double bubbleW = math.min(236.0, screen.width - 24);
    final double left = (pos.dx + size.width - bubbleW)
        .clamp(12.0, math.max(12.0, screen.width - bubbleW - 12))
        .toDouble();
    final double arrowX =
        (pos.dx + size.width / 2 - left).clamp(18.0, bubbleW - 18).toDouble();
    // v-TooltipPosisi-AdsRoas (permintaan user): sebelumnya popup selalu
    // memilih "di bawah" kalau estimasi tinggi muat, padahal estimasi bisa
    // meleset sehingga terpotong tepi bawah layar. Sekarang dibandingkan
    // ruang nyata di bawah vs di atas ikon: muat di bawah -> bawah; kalau
    // tidak, pakai sisi yang lebih lega (biasanya ke atas). Tinggi gelembung
    // juga dibatasi sebesar ruang sisi itu dan isinya bisa di-scroll, jadi
    // tidak pernah keluar layar walau jendela sangat pendek.
    final double spaceBelow = screen.height -
        mq.viewInsets.bottom -
        (pos.dy + size.height) -
        16;
    final double spaceAbove = pos.dy - mq.padding.top - 16;
    final bool below = estH <= spaceBelow || spaceBelow >= spaceAbove;
    final double maxBubbleH =
        math.max(120.0, below ? spaceBelow : spaceAbove);

    final bool dark = omniIsDark(anchor);
    // Bahan "ultra thin" iOS: latar buram (blur) + tint putih/gelap tembus
    // pandang, tepi tipis terang, panah menyatu dengan badan gelembung.
    // v-BayanganTip-AdsRoas: tint sedikit lebih pekat + tepi light mode
    // pakai hairline gelap tipis (sebelumnya putih di atas putih = tak
    // terlihat), supaya popup tidak melebur dengan latar dashboard.
    final Color tint = dark
        ? const Color(0xFF2C2C2E).withValues(alpha: 0.68)
        : const Color(0xFFFFFFFF).withValues(alpha: 0.72);
    final Color edge = dark
        ? const Color(0xFFFFFFFF).withValues(alpha: 0.20)
        : const Color(0xFF000000).withValues(alpha: 0.12);
    const double arrowH = 6;

    final Widget bubble = CustomPaint(
      painter: _BubblePainter(
          arrowX: arrowX, below: below, color: edge, shadow: true),
      foregroundPainter: _BubblePainter(
          arrowX: arrowX, below: below, color: edge, shadow: false),
      child: ClipPath(
        clipper: _BubbleClipper(arrowX: arrowX, below: below),
        child: BackdropFilter(
          // v-KacaSeragam: blur + saturasi 1.8x, sama dengan popup tip lain
          // (sebelumnya latar putih hampir padat).
          filter: ui.ImageFilter.compose(
            outer: const ColorFilter.matrix(<double>[
              1.7154, -0.7154, -0.0, 0, 0, //
              -0.2846, 1.2846, -0.0, 0, 0, //
              -0.2846, -0.7154, 1.9999, 0, 0, //
              0, 0, 0, 1, 0,
            ]),
            inner: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          ),
          child: Container(
            width: double.infinity,
            color: tint,
            padding: EdgeInsets.fromLTRB(10, 9 + (below ? arrowH : 0), 10,
                9 + (below ? 0 : arrowH)),
            child: SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              child: content,
            ),
          ),
        ),
      ),
    );

    final OverlayEntry entry = OverlayEntry(
      builder: (BuildContext ctx) => Stack(
        children: [
          if (sticky)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _hideModeTip,
                child: const SizedBox.expand(),
              ),
            ),
          Positioned(
            left: left,
            width: bubbleW,
            top: below ? pos.dy + size.height + 4 : null,
            bottom: below ? null : screen.height - pos.dy + 4,
            child: IgnorePointer(
              ignoring: !sticky,
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0.0, end: 1.0),
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOutCubic,
                builder: (BuildContext _, double t, Widget? child) => Opacity(
                  opacity: t,
                  child: Transform.scale(
                    scale: 0.94 + 0.06 * t,
                    alignment: Alignment(
                        (arrowX / bubbleW) * 2 - 1, below ? -1.0 : 1.0),
                    child: child,
                  ),
                ),
                child: Material(
                  type: MaterialType.transparency,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxBubbleH),
                    child: bubble,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    _tipEntry = entry;
    _tipOwner = anchor;
    _tipSticky = sticky;
    overlay.insert(entry);
    if (sticky) {
      Future.delayed(const Duration(seconds: 12), () {
        if (identical(_tipEntry, entry)) _hideModeTip();
      });
    }
  }

  // Blok geser: angka besar + keterangan kecil (+ kontrol mini di kanan atas),
  // slider, label ujung kiri/kanan, dan footer opsional.
  Widget _sliderBlock(
    BuildContext context, {
    required double value,
    required double min,
    required double max,
    required double step,
    required String readout,
    String? caption,
    required String minLabel,
    required String maxLabel,
    required ValueChanged<double> onChanged,
    Widget? trailing,
    Widget? footer,
    Color? activeColor,
  }) {
    final int divisions = ((max - min) / step).round();
    final double v = value.clamp(min, max).toDouble();
    // Tanpa kotak/border sendiri: blok ini menempel langsung di dalam kartu
    // (gaya iOS), jadi tidak ada lagi "kotak di dalam kotak".
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Angka besar di atas, keterangan kecil tepat di bawahnya.
            // FittedBox menjaga angka tidak overflow di jendela sempit.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: OmniText(
                      readout,
                      maxLines: 1,
                      style: TextStyle(
                          fontSize: _fs(context, 22),
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.5,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: omniText(context)),
                    ),
                  ),
                  if (caption != null) ...[
                    SizedBox(height: _sp(context, 2)),
                    OmniText(
                      caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: _fs(context, 12),
                          color: omniMuted(context)),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              SizedBox(width: _sp(context, 8)),
              trailing,
            ],
          ],
        ),
        SizedBox(height: _sp(context, 6)),
        // v-HoldKunci-AdsRoas: di Android slider ini dulu kalah rebutan gestur
        // dengan PageView antar modul / scroll vertikal, jadi geser malah
        // menggeser halaman. Sekarang memakai pola yang sama dengan slider
        // Target Margin di Smart Pricing (tahan ~0,25 detik -> terkunci ->
        // geser = ubah nilai). Platform lain tetap CupertinoSlider biasa.
        MouseRegion(
          cursor: SystemMouseCursors.click,
          // v-AksenWarna: track slider ikut warna aksen pilihan user.
          child: ValueListenableBuilder<String>(
            valueListenable: OmniAccentController.accent,
            builder: (BuildContext c, String _, Widget? __) => _HoldLockSlider(
              value: v,
              min: min,
              max: max,
              divisions: divisions < 1 ? null : divisions,
              activeColor: OmniAccentController.tint(omniIsDark(c)),
              onChanged: onChanged,
            ),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            OmniText(minLabel,
                style: TextStyle(
                    fontSize: _fs(context, 11), color: omniMuted(context))),
            OmniText(maxLabel,
                style: TextStyle(
                    fontSize: _fs(context, 11), color: omniMuted(context))),
          ],
        ),
        if (footer != null) ...[
          SizedBox(height: _sp(context, 14)),
          _hairline(context),
          SizedBox(height: _sp(context, 14)),
          footer,
        ],
      ],
    );
  }

  // v-GradienBrand-AdsRoas: brand merah-oranye (mis. Shopee) digeser sedikit
  // ke oranye supaya tidak terbaca "merah = rugi"; warna non-merah (biru,
  // hijau, dst) hanya diterangkan. amount 0..1 = seberapa jauh digeser ke
  // oranye, lightnessAdd = tambahan terang.
  Color _nudgeHue(Color c, double amount, {double lightnessAdd = 0}) {
    final HSLColor h = HSLColor.fromColor(c);
    double hue = h.hue;
    if (hue > 345) hue -= 360;
    if (hue < 25) hue = hue + (30 - hue) * amount;
    return h
        .withHue(((hue % 360) + 360) % 360)
        .withLightness((h.lightness + lightnessAdd).clamp(0.0, 0.85).toDouble())
        .toColor();
  }

  // v-TooltipSplit-AdsRoas: isi popover penjelasan bar "bawa pulang vs iklan".
  // Bahasa sengaja sederhana (untuk seller yang belum paham ROAS): dua skenario
  // berlawanan + dampaknya, lalu kondisi saat ini mengikuti posisi slider.
  Widget _splitTipContent(
      BuildContext anchor, double homeFrac, Color cHome, Color cAds) {
    final Color txt = omniText(anchor);
    final Color muted = omniMuted(anchor);
    final int homePct = (homeFrac * 100).round();
    Widget scenario(IconData icon, Color tone, String title, String body) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
            child: Icon(icon, size: 12, color: CupertinoColors.white),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                OmniText(title,
                    style: TextStyle(
                        fontSize: _fs(anchor, 11.5),
                        fontWeight: FontWeight.w700,
                        color: txt)),
                const SizedBox(height: 1),
                OmniText(body,
                    style: TextStyle(
                        fontSize: _fs(anchor, 10.5), height: 1.25, color: muted)),
              ],
            ),
          ),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OmniText('Profit dibagi dua',
            style: TextStyle(
                fontSize: _fs(anchor, 12),
                fontWeight: FontWeight.w800,
                color: txt)),
        const SizedBox(height: 3),
        OmniText(
            'Profit per order (setelah modal & biaya admin) dibagi: sebagian kamu bawa pulang, sisanya jadi jatah maksimal biaya iklan.',
            style: TextStyle(
                fontSize: _fs(anchor, 10.5), height: 1.25, color: muted)),
        const SizedBox(height: 8),
        scenario(
            CupertinoIcons.bag_fill,
            cHome,
            'Bawa pulang lebih banyak',
            'Untung per order lebih besar, tapi jatah iklan mengecil. ROAS yang dibutuhkan jadi lebih tinggi, jadi iklan harus menghasilkan lebih banyak penjualan dari tiap Rp 1 biaya iklan. Lebih sulit tercapai.'),
        const SizedBox(height: 7),
        scenario(
            CupertinoIcons.chart_bar_fill,
            cAds,
            'Jatah iklan lebih besar',
            'Kamu bisa membayar iklan lebih mahal per order dan ROAS yang dibutuhkan lebih rendah, jadi iklan lebih mudah untung. Tapi profit yang kamu bawa pulang per order lebih tipis.'),
        const SizedBox(height: 7),
        OmniText(
            'Kalau biaya iklan melebihi jatah, profit bawa pulang ikut berkurang. Sekarang: $homePct% dibawa pulang, ${100 - homePct}% untuk iklan.',
            style: TextStyle(fontSize: _fs(anchor, 10), color: muted)),
      ],
    );
  }

  // v-ProfitSplit-AdsRoas: membagi profit bersih per order (sebelum iklan)
  // jadi dua bagian: "bawa pulang" (= target profit) dan "untuk iklan"
  // (= sisanya, jatah biaya iklan maksimal). Ikut berubah live saat digeser.
  Widget _profitSplit(
      BuildContext context, double profitBersih, double targetProfit) {
    final double total = profitBersih;
    final double home = targetProfit.clamp(0.0, total).toDouble();
    final double ads = (total - home).clamp(0.0, total).toDouble();
    final double homeFrac = total > 0 ? home / total : 0.0;
    final Color cHome = _iosGreen(context);
    // v-WarnaBrand-AdsRoas: bagian "untuk iklan" memakai warna brand marketplace
    // (Shopee = oranye) yang dikirim dari single_calc.dart; bawa pulang tetap hijau.
    // Sisi iklan: warna brand yang diterangkan + digeser ke oranye, dibuat
    // gradien (lebih terang di kiri -> brand di kanan).
    final Color cAds = _nudgeHue(widget.brandColor, 0.45);
    final List<Color> adsGrad = [
      _nudgeHue(widget.brandColor, 0.9, lightnessAdd: 0.12),
      cAds,
    ];
    final List<Color> homeGrad = [
      _nudgeHue(cHome, 0, lightnessAdd: 0.08),
      cHome,
    ];

    Widget side({
      required String label,
      required String value,
      required String share,
      required Color color,
      required bool alignEnd,
      bool showInfo = false,
    }) {
      return Column(
        crossAxisAlignment:
            alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: _sp(context, 7),
                height: _sp(context, 7),
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              SizedBox(width: _sp(context, 5)),
              Flexible(
                child: OmniText(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: _fs(context, 10.5),
                      fontWeight: FontWeight.w600,
                      color: omniMuted(context)),
                ),
              ),
              // v-TooltipSplit-AdsRoas (permintaan user): ikon info kecil di
              // kedua label -- menjelaskan dampak membagi profit antara
              // "bawa pulang" vs "untuk iklan" untuk seller yang belum paham ROAS.
              if (showInfo)
                _tipTarget(
                  label: 'Penjelasan bagi profit bawa pulang dan iklan',
                  estH: 380,
                  content: (BuildContext c) =>
                      _splitTipContent(c, homeFrac, cHome, cAds),
                  child: Padding(
                    padding: EdgeInsets.all(_sp(context, 4)),
                    child: Icon(CupertinoIcons.info_circle,
                        size: _sp(context, 13), color: omniMuted(context)),
                  ),
                ),
            ],
          ),
          SizedBox(height: _sp(context, 2)),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: alignEnd ? Alignment.centerRight : Alignment.centerLeft,
            child: OmniText(
              value,
              maxLines: 1,
              style: TextStyle(
                  fontSize: _fs(context, 15),
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.2,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: color),
            ),
          ),
          OmniText(
            share,
            maxLines: 1,
            style: TextStyle(
                fontSize: _fs(context, 10), color: omniMuted(context)),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // v-BarKapsul-AdsRoas: dua kapsul terpisah celah kecil (gaya bar
        // penyimpanan iOS). Pakai Stack + AnimatedPositioned (bukan Row)
        // supaya saat lebar beranimasi / jendela di-resize tidak pernah
        // terjadi RenderFlex overflow.
        LayoutBuilder(builder: (BuildContext _, BoxConstraints c) {
          const double gap = 3;
          final double usable = math.max(0.0, c.maxWidth - gap);
          final double homeW = usable * homeFrac.clamp(0.0, 1.0).toDouble();
          final double adsW = math.max(0.0, usable - homeW);
          final double h = _sp(context, 10);
          Widget cap(List<Color> cols) => DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: cols),
                  borderRadius: BorderRadius.circular(999),
                ),
              );
          return SizedBox(
            height: h,
            width: c.maxWidth,
            child: Stack(
              children: [
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 120),
                  curve: Curves.easeOut,
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: homeW,
                  child: cap(homeGrad),
                ),
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 120),
                  curve: Curves.easeOut,
                  right: 0,
                  top: 0,
                  bottom: 0,
                  width: adsW,
                  child: cap(adsGrad),
                ),
              ],
            ),
          );
        }),
        SizedBox(height: _sp(context, 8)),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: side(
                label: 'Profit bawa pulang',
                value: Format.idr(home),
                share: '${(homeFrac * 100).round()}% dari profit',
                color: cHome,
                alignEnd: false,
                showInfo: true,
              ),
            ),
            SizedBox(width: _sp(context, 10)),
            Expanded(
              child: side(
                label: 'Profit untuk iklan',
                value: Format.idr(ads),
                share: '${((1 - homeFrac) * 100).round()}% dari profit',
                color: cAds,
                alignEnd: true,
                showInfo: true,
              ),
            ),
          ],
        ),
      ],
    );
  }

  double _targetValueNow() {
    final String raw = _targetCtrl.text.trim();
    if (raw.isEmpty) return 0;
    if (_targetIsRp) {
      return double.tryParse(raw.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
    }
    return double.tryParse(raw.replaceAll(',', '.')) ?? 0;
  }

  void _setTargetFromSlider(double v) {
    _targetAuto = false;
    setState(() {
      if (_targetIsRp) {
        _targetCtrl.text = v <= 0 ? '' : _dotGroup(v.round().toString());
      } else {
        _targetCtrl.text =
            v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);
      }
    });
  }

  void _setBudgetFromSlider(double v) {
    // Listener _onBudgetChanged ikut memformat titik ribuan + setState;
    // untuk nilai 0 (teks kosong) listener langsung return, jadi setState
    // dipanggil manual di sini.
    setState(() {
      _budgetCtrl.text = v <= 0 ? '' : _dotGroup(v.round().toString());
    });
  }

  // --- Fitur #2: Rekomendasi ROAS Target ---------------------------------
  Widget _targetQuickChip(BuildContext context, String label, bool active) {
    const Color tone = _kIosGray;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() {
        _targetAuto = false;
        _targetCtrl.text = label.replaceAll('%', '');
      }),
      child: Container(
        padding: EdgeInsets.symmetric(
            horizontal: _sp(context, 12), vertical: _sp(context, 6)),
        decoration: BoxDecoration(
          color: active
              ? tone
              : omniStroke(context).withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(999),
        ),
        child: OmniText(
          label,
          style: TextStyle(
              fontSize: _fs(context, 12),
              fontWeight: FontWeight.w700,
              color: active ? CupertinoColors.white : omniText(context)),
        ),
      ),
    );
  }

  Widget _targetProfitInput(BuildContext context, bool landscape) {
    final double fsz = _fs(context, landscape ? 12 : 13);
    final double price = widget.price;
    // Profit bersih per order sebelum iklan -- rumus sama dengan build().
    final double profitBersih =
        price - widget.modal - widget.totalPlatformFee;
    final bool canSlide = price > 0 && profitBersih > 0;

    // Rentang geser mengikuti nilai barang: maksimum = 95% profit bersih
    // (di atas itu target pasti "Target Tinggi" / tidak ada sisa untuk iklan).
    double sMax = 0;
    double sStep = 1;
    if (canSlide) {
      if (_targetIsRp) {
        final double cap = profitBersih * 0.95;
        sStep = _niceStep(cap / 100);
        sMax = (cap / sStep).floorToDouble() * sStep;
      } else {
        final double capPct =
            (profitBersih / price * 100 * 0.95).clamp(0, 100).toDouble();
        sStep = capPct <= 10 ? 0.5 : 1;
        sMax = (capPct / sStep).floorToDouble() * sStep;
      }
    }
    final bool slideOk = _targetSlide && canSlide && sMax >= sStep * 2;

    // v-MiniToggle-AdsRoas: Rp/% sekarang pil kecil yang menempel DI DALAM
    // blok geser (kanan atas) atau di dalam field ketik (ujung kanan),
    // bukan kolom terpisah lagi, jadi tidak memakan lebar.
    final Widget unitToggle = _miniToggle<bool>(
      context,
      value: _targetIsRp,
      options: const <_MiniOpt<bool>>[
        _MiniOpt<bool>(false, label: '%'),
        _MiniOpt<bool>(true, label: 'Rp'),
      ],
      onChanged: (bool v) {
        if (v == _targetIsRp) return;
        setState(() {
          _targetAuto = false;
          // Konversi nilai saat ini ke satuan baru (berdasarkan harga jual)
          // supaya angka tidak reset: 10% dari Rp 7.882 = Rp 788, dst.
          final double now = _targetValueNow();
          if (price > 0 && now > 0) {
            if (v) {
              _targetCtrl.text =
                  _dotGroup((price * now.clamp(0, 100) / 100).round().toString());
            } else {
              final double pct = (now / price * 100).clamp(0, 100).toDouble();
              _targetCtrl.text = pct == pct.roundToDouble()
                  ? pct.round().toString()
                  : pct.toStringAsFixed(1);
            }
          } else {
            _targetCtrl.text = v ? '' : '10';
          }
          _targetIsRp = v;
        });
      },
    );

    final double cur = _targetValueNow();
    final double curRp = _targetIsRp ? cur : price * cur.clamp(0, 100) / 100;
    final String caption = price <= 0
        ? ''
        : (_targetIsRp
            ? '≈ ${(cur / price * 100).toStringAsFixed(1)}% dari harga jual'
            : '≈ ${Format.idr(curRp)} per order');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header seragam dengan kartu Simulasi: badge + judul + kontrol.
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _iconBadge(
                context: context,
                icon: CupertinoIcons.chart_pie_fill,
                color: _kIosGray,
                size: 28),
            SizedBox(width: _sp(context, 8)),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: OmniText(
                      _roasMode
                          ? 'Target ROAS ideal'
                          : 'Target profit setelah iklan (per order)',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: _fs(context, landscape ? 11 : 12.5)),
                    ),
                  ),
                  _infoDot(
                    context,
                    'Apa itu Target Profit setelah iklan?',
                    'Ini untung bersih yang ingin tetap kamu kantongi per order, SETELAH dipotong biaya iklan.\n\n'
                    'Contoh: harga jual Rp100.000, profit bersih sebelum iklan Rp30.000. '
                    'Kamu isi target Rp10.000.\n'
                    '• Jatah untuk iklan = Rp30.000 - Rp10.000 = Rp20.000 per order.\n'
                    '• ROAS Ideal = Rp100.000 / Rp20.000 = 5x.\n\n'
                    'Artinya selama iklanmu menghasilkan minimal 5x dari biaya iklan, '
                    'kamu tetap untung Rp10.000 per order.\n\n'
                    'Makin besar target, makin tinggi ROAS yang dibutuhkan. '
                    'Kalau target melebihi profit bersih, iklan tidak mungkin mencapainya.',
                  ),
                ],
              ),
            ),
            SizedBox(width: _sp(context, 4)),
            _inputModeToggle(context, _targetSlide,
                (bool v) => setState(() => _targetSlide = v)),
          ],
        ),
        SizedBox(height: _sp(context, 12)),
        // v-TargetROAS: pilih mau mengatur lewat profit atau langsung ROAS.
        Align(
          alignment: Alignment.centerLeft,
          child: _miniToggle<bool>(
            context,
            value: _roasMode,
            options: const <_MiniOpt<bool>>[
              _MiniOpt<bool>(false, label: 'Target Profit'),
              _MiniOpt<bool>(true, label: 'Target ROAS'),
            ],
            onChanged: (bool v) => _setRoasMode(v, price, profitBersih),
          ),
        ),
        SizedBox(height: _sp(context, 12)),
        if (_roasMode)
          _roasGoalBlock(context, price, profitBersih, landscape)
        else ...[
        if (_targetSlide && !slideOk)
          Padding(
            padding: EdgeInsets.only(bottom: _sp(context, 6)),
            child: OmniText(
              'Geser aktif setelah modal, harga jual, dan kategori terisi. Sementara ketik manual dulu.',
              style: TextStyle(
                  fontSize: _fs(context, 10.5), color: omniMuted(context)),
            ),
          ),
        if (slideOk)
          _sliderBlock(
            context,
            value: cur,
            min: 0,
            max: sMax,
            step: sStep,
            readout: _targetIsRp
                ? Format.idr(cur)
                : '${cur == cur.roundToDouble() ? cur.round() : cur.toStringAsFixed(1)}%',
            caption: caption.isEmpty ? null : caption,
            minLabel: _targetIsRp ? 'Rp 0' : '0%',
            maxLabel: _targetIsRp
                ? 'Maks ${Format.idr(sMax)}'
                : 'Maks ${sMax == sMax.roundToDouble() ? sMax.round() : sMax}%',
            onChanged: _setTargetFromSlider,
            trailing: unitToggle,
            // Slider target = profit bawa pulang -> track aktif hijau, senada bar.
            activeColor: _iosGreen(context),
            // Nilai antara profit bawa pulang vs profit untuk iklan.
            footer: _profitSplit(context, profitBersih, _targetProfitRp(price)),
          )
        else
          CupertinoTextField(
            controller: _targetCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: _targetIsRp
                ? [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(Format.maxInputDigits),
                  ]
                : [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                    LengthLimitingTextInputFormatter(5),
                  ],
            placeholder: _targetIsRp ? ot('Contoh: 5.000') : ot('Contoh: 10'),
            padding: EdgeInsets.symmetric(
                horizontal: _sp(context, 12), vertical: _sp(context, 8)),
            style: TextStyle(fontSize: fsz, color: omniText(context)),
            placeholderStyle:
                TextStyle(fontSize: fsz, color: omniMuted(context)),
            suffix: Padding(
              padding: EdgeInsets.only(right: _sp(context, 6)),
              child: unitToggle,
            ),
            decoration: BoxDecoration(
              color: omniStroke(context).withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            onChanged: _onTargetChanged,
          ),
        if (!_targetIsRp) ...[
          SizedBox(height: _sp(context, 8)),
          Wrap(
            spacing: _sp(context, 8),
            runSpacing: _sp(context, 6),
            children: [
              for (final String q in const ['5%', '10%', '15%', '20%'])
                _targetQuickChip(
                    context,
                    q,
                    (double.tryParse(_targetCtrl.text.replaceAll(',', '.')) ??
                            -1) ==
                        double.parse(q.replaceAll('%', ''))),
            ],
          ),
        ],
        ],
      ],
    );
  }

  // --- v-TargetROAS: helper --------------------------------------------------
  String _fmtX(double v) {
    final double r = (v * 100).round() / 100;
    if (r == r.roundToDouble()) return r.round().toString();
    String t = r.toStringAsFixed(2);
    if (t.endsWith('0')) t = t.substring(0, t.length - 1);
    return t;
  }

  void _setRoasMode(bool on, double price, double profitBersih) {
    if (on == _roasMode) return;
    setState(() {
      _targetAuto = false;
      if (on) {
        // Mulai dari ROAS Ideal saat ini (dibulatkan ke 0,5) supaya tidak loncat.
        final double t = _targetProfitRp(price);
        final double sisa = profitBersih - t;
        double g = (price > 0 && sisa > 0) ? price / sisa : 5.0;
        g = (g * 2).round() / 2.0;
        if (g < 1) g = 1;
        _roasGoal = g;
        _roasGoalCtrl.text = _fmtX(g);
        _roasMode = true;
      } else {
        // Kembali ke mode profit: bawa nilai target profit yang sekarang.
        final double t = _targetProfitRp(price);
        if (_targetIsRp) {
          _targetCtrl.text = t <= 0 ? '' : _dotGroup(t.round().toString());
        } else {
          final double pct = price > 0 ? (t / price * 100) : 0.0;
          _targetCtrl.text = pct == pct.roundToDouble()
              ? pct.round().toString()
              : pct.toStringAsFixed(1);
        }
        _roasMode = false;
      }
    });
  }

  void _setRoasGoal(double v) {
    setState(() {
      _targetAuto = false;
      _roasGoal = v;
      _roasGoalCtrl.text = _fmtX(v);
    });
  }

  Widget _roasChip(BuildContext context, double v) {
    final bool active = (_roasGoal - v).abs() < 0.001;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        _setRoasGoal(v);
      },
      child: Container(
        padding: EdgeInsets.symmetric(
            horizontal: _sp(context, 12), vertical: _sp(context, 6)),
        decoration: BoxDecoration(
          color: active
              ? _kIosGray
              : omniStroke(context).withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(999),
        ),
        child: OmniText(
          '${_fmtX(v)}x',
          style: TextStyle(
              fontSize: _fs(context, 12),
              fontWeight: FontWeight.w700,
              color: active ? CupertinoColors.white : omniText(context)),
        ),
      ),
    );
  }

  // Blok Target ROAS: slider (kelipatan 0,5 -> 5x bisa pas), chip cepat,
  // atau ketik manual. Menampilkan sisa profit & biaya iklan maksimal.
  Widget _roasGoalBlock(BuildContext context, double price,
      double profitBersih, bool landscape) {
    if (price <= 0 || profitBersih <= 0) {
      return OmniText(
        'Isi modal, harga jual, dan kategori dulu agar Target ROAS bisa dipakai.',
        style: TextStyle(fontSize: _fs(context, 11), color: omniMuted(context)),
      );
    }
    final double bep = price / profitBersih;
    const double step = 0.5;
    final double minV = (bep / step).ceil() * step;
    final double maxV =
        math.max(((bep * 4).ceilToDouble()).clamp(10.0, 50.0).toDouble(), minV + 5);
    final double cur = _roasGoal.clamp(minV, maxV).toDouble();
    final double tp = _targetProfitRp(price);
    final bool bawahBep = _roasGoal > 0 && _roasGoal < bep - 0.0001;
    final bool slideOk = _targetSlide;
    final double fsz = _fs(context, landscape ? 12 : 13);

    final String caption = bawahBep
        ? 'Di bawah impas'
        : (tp > 0
            ? 'Sisa profit ≈ ${Format.idr(tp)} per order · biaya iklan maks. ${Format.idr(price / _roasGoal)}'
            : 'Pas di titik impas: profit setelah iklan Rp 0');

    final List<double> quick = <double>[
      for (final double q in const <double>[3, 4, 5, 6, 8, 10])
        if (q >= minV && q <= maxV) q
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (slideOk)
          _sliderBlock(
            context,
            value: cur,
            min: minV,
            max: maxV,
            step: step,
            readout: '${_fmtX(cur)}x',
            caption: caption,
            minLabel: '${_fmtX(minV)}x (impas)',
            maxLabel: '${_fmtX(maxV)}x',
            onChanged: _setRoasGoal,
            activeColor: _iosGreen(context),
            footer: _profitSplit(context, profitBersih, tp),
          )
        else ...[
          CupertinoTextField(
            controller: _roasGoalCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
              LengthLimitingTextInputFormatter(6),
            ],
            placeholder: ot('Contoh: 5'),
            padding: EdgeInsets.symmetric(
                horizontal: _sp(context, 12), vertical: _sp(context, 8)),
            style: TextStyle(fontSize: fsz, color: omniText(context)),
            placeholderStyle:
                TextStyle(fontSize: fsz, color: omniMuted(context)),
            suffix: Padding(
              padding: EdgeInsets.only(right: _sp(context, 12)),
              child: OmniText('x',
                  style: TextStyle(
                      fontSize: fsz, color: omniMuted(context))),
            ),
            decoration: BoxDecoration(
              color: omniStroke(context).withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            onChanged: (String t) {
              final double v =
                  double.tryParse(t.replaceAll(',', '.')) ?? 0.0;
              setState(() {
                _targetAuto = false;
                _roasGoal = v;
              });
            },
          ),
          SizedBox(height: _sp(context, 8)),
          OmniText(caption,
              style: TextStyle(
                  fontSize: _fs(context, 11.5), color: omniMuted(context))),
        ],
        if (quick.isNotEmpty) ...[
          SizedBox(height: _sp(context, 10)),
          Wrap(
            spacing: _sp(context, 8),
            runSpacing: _sp(context, 6),
            children: [for (final double q in quick) _roasChip(context, q)],
          ),
        ],
        if (bawahBep) ...[
          SizedBox(height: _sp(context, 8)),
          OmniText(
            'ROAS ${_fmtX(_roasGoal)}x di bawah titik impas (${bep.toStringAsFixed(2)}x), iklan akan rugi. Pilih minimal ${_fmtX(minV)}x.',
            style: TextStyle(
                fontSize: _fs(context, 11.5),
                color: _iosOrange(context),
                height: 1.35),
          ),
        ],
      ],
    );
  }

  Widget _roasTargetSection(
      BuildContext context,
      double roasTargetBep,
      double roasTargetAman,
      double profitBersih,
      double roasIdeal,
      bool idealValid,
      double targetProfit,
      double sisaUntukIklan,
      bool landscape) {
    final bool ada = roasTargetBep > 0;
    return _groupCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // v-ROAS-Padat: judul "Rekomendasi ROAS Target" & chip BEP/Aman
          // sudah pindah ke kartu hero (sejajar ROAS Ideal) -- di sini
          // tinggal input target profit.
          if (!ada)
            OmniText(
              'Margin belum cukup menutup modal & biaya admin, jadi iklan belum disarankan sebelum harga/margin dinaikkan.',
              style: TextStyle(
                  fontSize: _fs(context, landscape ? 11 : 12),
                  color: _iosRed(context)),
            )
          else ...[
            _targetProfitInput(context, landscape),
            // ROAS Ideal sudah tampil di kartu hero atas (penjelasannya ada di
            // ikon info), jadi chip & rumus duplikatnya dihapus. Hanya pesan
            // peringatan yang tersisa.
            if (!idealValid) ...[
              SizedBox(height: _sp(context, 8)),
              OmniText(
                targetProfit <= 0
                    ? 'Isi target profit untuk melihat ROAS ideal.'
                    : 'Target profit ${Format.idr(targetProfit)} melebihi profit bersih sebelum iklan (${Format.idr(profitBersih)}). Turunkan target atau naikkan harga.',
                style: TextStyle(
                    fontSize: _fs(context, landscape ? 11 : 12),
                    color: targetProfit <= 0
                        ? omniMuted(context)
                        : _iosOrange(context),
                    height: 1.35),
              ),
            ],
          ],
        ],
      ),
    );
  }

  // Angka ringkas datar (tanpa kotak/border): label kecil di atas, nilai
  // besar di bawah. Dipakai berdampingan dengan garis tipis pemisah.
  Widget _metric(BuildContext context, String label, String value, Color color,
      bool landscape,
      {EdgeInsetsGeometry padding = EdgeInsets.zero,
      double? valueSize,
      Widget? trailing}) {
    final bool neutral = color == _kIosGray;
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // v-TooltipBEP-AdsRoas: [trailing] = ikon info opsional di samping label.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: OmniText(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: _fs(context, landscape ? 9.5 : 10),
                      fontWeight: FontWeight.w600,
                      color: omniMuted(context)),
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
          SizedBox(height: _sp(context, 3)),
          // FittedBox scaleDown: angka panjang mengecil, tidak overflow.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: OmniText(
              value,
              maxLines: 1,
              style: TextStyle(
                fontSize:
                    _fs(context, valueSize ?? (landscape ? 15 : 17.5)),
                fontWeight: FontWeight.w800,
                color: neutral ? omniText(context) : color,
                letterSpacing: -0.3,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- Fitur #1: Simulasi Anggaran Iklan ----------------------------------
  Widget _budgetSimulationSection(
      BuildContext context,
      double price,
      double profitBersih,
      double roasTargetAman,
      double roasIdeal,
      bool idealValid,
      bool landscape) {
    // Shorthand lokal (lihat build()) -- method ini terpisah dari build()
    // jadi closure fs()/sp() di sana tidak ikut terlihat di sini, perlu
    // didefinisikan ulang lewat helper instance _fs()/_sp().
    double fs(double base) => _fs(context, base);
    double sp(double base) => _sp(context, base);
    final double budget = _budget;
    // v-ROAS-Ideal: dasar simulasi = Aman (default) atau Ideal (kalau valid).
    final bool pakaiIdeal = _simUseIdeal && idealValid;
    final double roasDipakai = pakaiIdeal ? roasIdeal : roasTargetAman;
    final bool bisaHitung = budget > 0 && roasDipakai > 0 && price > 0;

    double estimasiOmset = 0;
    int estimasiOrder = 0;
    double estimasiProfitBersih = 0;

    if (bisaHitung) {
      // Asumsi kampanye berjalan di ROAS terpilih (Aman / Ideal).
      estimasiOmset = budget * roasDipakai;
      estimasiOrder = (estimasiOmset / price).ceil();
      estimasiProfitBersih = (estimasiOrder * profitBersih) - budget;
    }

    // v-Desktop-macOS: field budget adalah keluhan utama user ("teks field
    // dll sangat kecil"), jadi font & padding-nya dinaikkan paling agresif
    // (dipakai fs()/sp() penuh, bukan cuma sebagian) supaya nyaman dibaca &
    // di-klik pakai mouse di layar laptop.
    final double fieldFontSize = fs(landscape ? 13 : 14.5);
    return _groupCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _iconBadge(
                  context: context,
                  icon: CupertinoIcons.money_dollar_circle_fill,
                  color: _kIosGray,
                  size: 28),
              SizedBox(width: sp(8)),
              // v-Fix-Overflow-AdsRoas: sama seperti fix di
              // _roasTargetSection -- judul dibungkus Expanded + ellipsis
              // supaya tidak overflow di window sempit/mini resolusi.
              Expanded(
                child: OmniText(
                  'Simulasi Anggaran Iklan',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: fs(landscape ? 11 : 12.5)),
                ),
              ),
              SizedBox(width: sp(8)),
              _inputModeToggle(context, _budgetSlide,
                  (bool v) => setState(() => _budgetSlide = v)),
            ],
          ),
          if (idealValid) ...[
            SizedBox(height: sp(10)),
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: OmniText(
                    'Dasar ROAS simulasi',
                    style: TextStyle(
                        fontSize: fs(landscape ? 10.5 : 11.5),
                        fontWeight: FontWeight.w600,
                        color: omniMuted(context)),
                  ),
                      ),
                      _infoDot(
                  context,
                  'Apa itu Dasar ROAS simulasi?',
                  'Memilih angka ROAS mana yang dipakai untuk menghitung estimasi omzet, order, dan profit dari budget iklan.\n\n'
                  '• Aman: ROAS Impas + buffer 30%. Pilihan hati-hati, cocok kalau kamu belum yakin performa iklanmu.\n'
                  '• Ideal: ROAS yang pas untuk mencapai target profit yang kamu isi di atas.\n\n'
                  'Contoh: budget Rp500.000 dengan ROAS 5x = estimasi omzet Rp2.500.000. '
                  'Ganti pilihan untuk membandingkan hasilnya.',
                ),
                    ],
                  ),
                ),
                SizedBox(width: sp(4)),
                _miniToggle<bool>(
                  context,
                  value: _simUseIdeal,
                  options: const <_MiniOpt<bool>>[
                    _MiniOpt<bool>(false, label: 'Aman'),
                    _MiniOpt<bool>(true, label: 'Ideal'),
                  ],
                  onChanged: (bool v) => setState(() => _simUseIdeal = v),
                ),
              ],
            ),
          ],
          SizedBox(height: sp(10)),
          if (_budgetSlide && price > 0)
            () {
              // Rentang geser mengikuti harga barang (~25x harga jual, min
              // Rp 50.000) dan otomatis melebar kalau angka yang diketik
              // lebih besar.
              double bMax = _niceCeil(price * 25 < 50000 ? 50000 : price * 25);
              if (budget > bMax) bMax = _niceCeil(budget);
              final double bStep = _niceStep(bMax / 100);
              bMax = (bMax / bStep).ceilToDouble() * bStep;
              return _sliderBlock(
                context,
                value: budget,
                min: 0,
                max: bMax,
                step: bStep,
                readout: Format.idr(budget),
                caption: bisaHitung
                    ? '≈ $estimasiOrder ${_orderUnitLabel(estimasiOrder)}'
                    : null,
                minLabel: 'Rp 0',
                maxLabel: Format.idr(bMax),
                onChanged: _setBudgetFromSlider,
              );
            }()
          else
          Container(
            key: _budgetFieldKey,
            child: CupertinoTextField(
              controller: _budgetCtrl,
              focusNode: _budgetFocus,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(Format.maxInputDigits),
              ],
              placeholder: ot('Contoh: 50.000'),
              padding:
                  EdgeInsets.symmetric(horizontal: sp(14), vertical: sp(12)),
              style:
                  TextStyle(fontSize: fieldFontSize, color: omniText(context)),
              placeholderStyle:
                  TextStyle(fontSize: fieldFontSize, color: omniMuted(context)),
              prefix: Padding(
                padding: EdgeInsets.only(left: sp(12)),
                child: OmniText('Rp',
                    style: TextStyle(
                        fontSize: fieldFontSize,
                        fontWeight: FontWeight.w600,
                        color: omniMuted(context))),
              ),
              decoration: BoxDecoration(
                color: omniStroke(context).withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12),
              ),
              onTap: () {
                // onTap juga dipasang, karena kadang event fokus terpicu
                // sebelum context final ter-attach ke tree (khususnya saat
                // field ini baru pertama kali dirender di layar).
                _onBudgetFocusChanged();
              },
            ),
          ),
          SizedBox(height: sp(12)),
          if (budget > 0 && roasDipakai <= 0)
            OmniText(
              'Belum bisa disimulasikan — lengkapi dulu modal, harga jual, dan biaya admin.',
              style: TextStyle(
                  fontSize: fs(landscape ? 11 : 12),
                  color: _iosRed(context)),
            )
          else if (bisaHitung) ...[
            _hairline(context),
            SizedBox(height: sp(12)),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _metric(context, 'Estimasi Omset',
                        Format.idr(estimasiOmset), _kIosGray, landscape,
                        padding: EdgeInsets.only(right: sp(12))),
                  ),
                  _vHairline(context),
                  Expanded(
                    child: _metric(
                        context,
                        'Estimasi Order',
                        // Bentuk jamak mengikuti bahasa aktif (lihat _orderUnitLabel).
                        '~$estimasiOrder ${_orderUnitLabel(estimasiOrder)}',
                        _kIosGray,
                        landscape,
                        padding: EdgeInsets.only(left: sp(14))),
                  ),
                ],
              ),
            ),
            SizedBox(height: sp(12)),
            _hairline(context),
            SizedBox(height: sp(12)),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: OmniText(
                    'Estimasi Profit Bersih',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: fs(landscape ? 10.5 : 12),
                        fontWeight: FontWeight.w600,
                        color: omniMuted(context)),
                  ),
                ),
                SizedBox(width: sp(8)),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: OmniText(
                      '${estimasiProfitBersih >= 0 ? '+' : '-'}${Format.idr(estimasiProfitBersih.abs())}',
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: fs(landscape ? 14.5 : 17),
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: estimasiProfitBersih >= 0
                            ? _iosGreen(context)
                            : _iosRed(context),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: sp(10)),
            OmniText(
              'Asumsi kampanye mencapai ${pakaiIdeal ? 'ROAS Ideal' : 'ROAS Disarankan (Aman)'} (${roasDipakai.toStringAsFixed(2)}x). Hasil aktual tergantung performa iklan sebenarnya.',
              style: TextStyle(
                  fontSize: fs(landscape ? 10 : 11),
                  color: omniMuted(context),
                  height: 1.3),
            ),
          ] else
            OmniText(
              'Masukkan budget iklan untuk melihat estimasi omset, order, dan profit bersih.',
              style: TextStyle(
                  fontSize: fs(landscape ? 11 : 12), color: omniMuted(context)),
            ),
        ],
      ),
    );
  }
}

// --- Gelembung tooltip ala iOS: badan membulat + panah dalam SATU bentuk ----
Path _bubblePath(Size size, double arrowX, bool below) {
  const double r = 12;
  const double aw = 13;
  const double ah = 6;
  final double top = below ? ah : 0;
  final double bottom = below ? size.height : size.height - ah;
  final double ax = arrowX.clamp(r + aw / 2, size.width - r - aw / 2).toDouble();
  final Path body = Path()
    ..addRRect(RRect.fromLTRBR(0, top, size.width, bottom, const Radius.circular(r)));
  final Path tip = Path();
  if (below) {
    tip
      ..moveTo(ax - aw / 2, top + 0.5)
      ..quadraticBezierTo(ax - 1.5, top - 0.5, ax, 0)
      ..quadraticBezierTo(ax + 1.5, top - 0.5, ax + aw / 2, top + 0.5)
      ..close();
  } else {
    tip
      ..moveTo(ax - aw / 2, bottom - 0.5)
      ..quadraticBezierTo(ax - 1.5, bottom + 0.5, ax, size.height)
      ..quadraticBezierTo(ax + 1.5, bottom + 0.5, ax + aw / 2, bottom - 0.5)
      ..close();
  }
  return Path.combine(PathOperation.union, body, tip);
}

class _BubbleClipper extends CustomClipper<Path> {
  final double arrowX;
  final bool below;
  const _BubbleClipper({required this.arrowX, required this.below});

  @override
  Path getClip(Size size) => _bubblePath(size, arrowX, below);

  @override
  bool shouldReclip(covariant _BubbleClipper old) =>
      old.arrowX != arrowX || old.below != below;
}

class _BubblePainter extends CustomPainter {
  final double arrowX;
  final bool below;
  final Color color;
  final bool shadow; // true: bayangan di belakang, false: garis tepi di depan
  const _BubblePainter({
    required this.arrowX,
    required this.below,
    required this.color,
    required this.shadow,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Path path = _bubblePath(size, arrowX, below);
    if (shadow) {
      // v-BayanganTip-AdsRoas (permintaan user): bayangan dua lapis yang
      // lebih tegas supaya popup terpisah jelas dari dashboard di belakangnya.
      // Lapis 1 = bayangan jatuh lebar & lembut (memberi kedalaman), lapis 2 =
      // bayangan rapat di tepi (memberi kontur). Keduanya dipotong di LUAR
      // bentuk gelembung, supaya latar kaca (blur) di dalamnya tidak ikut
      // menggelap.
      final Path outside = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Rect.fromLTWH(-120, -120, size.width + 240, size.height + 240))
        ..addPath(path, Offset.zero);
      canvas.save();
      canvas.clipPath(outside);
      canvas.save();
      canvas.translate(0, 12);
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xFF000000).withValues(alpha: 0.42)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16),
      );
      canvas.restore();
      canvas.save();
      canvas.translate(0, 2);
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xFF000000).withValues(alpha: 0.30)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.5),
      );
      canvas.restore();
      canvas.restore();
    } else {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8
          ..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BubblePainter old) =>
      old.arrowX != arrowX ||
      old.below != below ||
      old.color != color ||
      old.shadow != shadow;
}

/// v-HoldKunci-AdsRoas: slider yang aman di dalam PageView/scroll.
///
/// Android: slider hanya tampilan (IgnorePointer). Gestur ditangani
/// [LongPressGestureRecognizer] 250 ms -> saat "terkunci" dia menang di arena
/// gestur sehingga PageView/scroll induk batal, lalu geser jari = ubah nilai.
/// Sebelum ditahan, sentuhan diteruskan ke halaman (swipe halaman normal).
/// Platform lain: CupertinoSlider biasa tanpa perubahan perilaku.
class _HoldLockSlider extends StatefulWidget {
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final Color activeColor;
  final ValueChanged<double> onChanged;

  const _HoldLockSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.activeColor,
    required this.onChanged,
  });

  @override
  State<_HoldLockSlider> createState() => _HoldLockSliderState();
}

class _HoldLockSliderState extends State<_HoldLockSlider> {
  // CupertinoSlider: padding 8 + radius thumb 14 di tiap sisi track.
  static const double _kTrackInset = 22.0;

  bool _locked = false;
  double? _lastEmitted;

  bool get _holdMode =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  double _valueAt(double dx, double width) {
    final double extent = width - 2 * _kTrackInset;
    if (extent <= 0) return widget.min;
    final double t = ((dx - _kTrackInset) / extent).clamp(0.0, 1.0).toDouble();
    final double range = widget.max - widget.min;
    final int? d = widget.divisions;
    // Snap ke kelipatan step, sama seperti CupertinoSlider dengan divisions.
    final double snapped = (d == null || d < 1) ? t : (t * d).round() / d;
    return widget.min + snapped * range;
  }

  // v-GetarAndroid-AdsRoas: efek getar khusus Android (jalur tahan-geser).
  // - Terkunci: getar kuat (heavyImpact)
  // - Tiap pindah step: getar ringan, dibatasi ~25x/detik supaya tidak
  //   "bergemuruh" saat jari digeser cepat di slider dengan banyak step
  // - Mentok ujung kiri/kanan: getar kuat sebagai penanda batas
  // - Lepas: getar ringan
  DateTime _lastTick = DateTime.fromMillisecondsSinceEpoch(0);

  void _emit(double nv) {
    if (_lastEmitted == nv) return;
    final double? prev = _lastEmitted;
    _lastEmitted = nv;
    final bool atEdge = nv <= widget.min || nv >= widget.max;
    final bool edgeJustHit = atEdge && prev != nv;
    if (edgeJustHit) {
      HapticFeedback.heavyImpact();
      _lastTick = DateTime.now();
    } else {
      final DateTime now = DateTime.now();
      if (now.difference(_lastTick).inMilliseconds >= 40) {
        HapticFeedback.lightImpact();
        _lastTick = now;
      }
    }
    widget.onChanged(nv);
  }

  void _start(double dx, double width) {
    HapticFeedback.heavyImpact();
    setState(() => _locked = true);
    _lastEmitted = widget.value;
    _lastTick = DateTime.now();
    _emit(_valueAt(dx, width));
  }

  void _move(double dx, double width) {
    if (!_locked) return;
    _emit(_valueAt(dx, width));
  }

  void _end() {
    _lastEmitted = null;
    if (!mounted || !_locked) return;
    HapticFeedback.lightImpact();
    setState(() => _locked = false);
  }

  @override
  Widget build(BuildContext context) {
    final Widget slider = CupertinoSlider(
      value: widget.value,
      min: widget.min,
      max: widget.max,
      divisions: widget.divisions,
      activeColor: widget.activeColor,
      onChanged: (double nv) {
        if (nv != widget.value) HapticFeedback.selectionClick();
        widget.onChanged(nv);
      },
    );
    if (!_holdMode) return slider;

    return LayoutBuilder(builder: (BuildContext context, BoxConstraints bc) {
      final double w = bc.maxWidth;
      return RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: <Type, GestureRecognizerFactory>{
          LongPressGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
            () => LongPressGestureRecognizer(
                duration: const Duration(milliseconds: 250)),
            (LongPressGestureRecognizer r) {
              r.onLongPressStart =
                  (LongPressStartDetails d) => _start(d.localPosition.dx, w);
              r.onLongPressMoveUpdate = (LongPressMoveUpdateDetails d) =>
                  _move(d.localPosition.dx, w);
              r.onLongPressEnd = (_) => _end();
              r.onLongPressCancel = _end;
            },
          ),
        },
        // Sedikit membesar saat terkunci sebagai tanda slider siap digeser.
        child: AnimatedScale(
          scale: _locked ? 1.03 : 1.0,
          duration: const Duration(milliseconds: 120),
          child: IgnorePointer(child: slider),
        ),
      );
    });
  }
}
