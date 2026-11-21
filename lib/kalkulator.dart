// kalkulator.dart — Kalkulator Shopee: laba bersih per pcs dari data biaya admin per kategori.
//
// Alur biaya (sesuai urutan di UI):
//   1. Admin toko (Non-Star/Star/Star+ atau Mall) + kategori produk + biaya proses
//      pesanan (tab "biaya wajib")                                   → WAJIB, selalu aktif
//   2. Gratis Ongkir XTRA (on/off, ukuran biasa/khusus)             → ikut kategori poin 1
//   3. Promo Iklan (on/off) → bila aktif MENGGANTIKAN poin 2, tarif sesuai
//      kode A–H milik kategori, ukuran biasa/khusus
//   4. Biaya layanan / program opsional (8 program, masing-masing on/off)
//   5. Pajak (PPh 22)
//
// Sumber data: file STATIS yang tertanam di aplikasi (tanpa internet / Google):
//   assets/kalkulator/biaya_admin.xlsx  — 6 TAB terpisah
//   star/star+ · Mall · biaya gratis ongkir · promo iklan · progam opsional · pajak
// Untuk memperbarui tarif: ganti file xlsx tersebut, naikkan versi di pubspec.yaml,
// lalu build ulang. Kolom dibaca berdasarkan NAMA HEADER (bukan urutan kolom).
// Lihat FeeDb._parse.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random, max, min;
import 'dart:ui' show FontFeature, ImageFilter;

import 'package:archive/archive.dart';
import 'package:flutter/cupertino.dart'
    show
        CupertinoAlertDialog,
        CupertinoDialogAction,
        CupertinoIcons,
        showCupertinoDialog;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show FilteringTextInputFormatter, rootBundle;
import 'package:path/path.dart' as pth;
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';

import 'main.dart'
    show accent, cLine, cMute, cSub, cSurface, cSurface2, cText, isDark, store;
import 'ads_roas.dart' show AdsRoasPanel;

// ============================================================================
// FORMAT ANGKA
// ============================================================================
String _rp(num v) {
  final r = v.round();
  final s = r.abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write('.');
    b.write(s[i]);
  }
  return '${r < 0 ? '-' : ''}Rp$b';
}

/// Pembulatan kebijakan Shopee: tiap potongan dibulatkan ke rupiah penuh,
/// setengah dibulatkan ke atas (2933,5 -> 2934).
double _rnd(double v) => double.parse(v.toStringAsFixed(6)).roundToDouble();

String _fmtPct(double v) {
  var s = v.toStringAsFixed(2);
  s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return '${s.replaceAll('.', ',')}%';
}

// ============================================================================
// MODEL DATA BIAYA
// ============================================================================

/// Satu tarif: persen dari harga jual, batas maksimal per item (opsional),
/// dan/atau biaya tetap.
class FeeRate {
  const FeeRate(this.pct, {this.cap, this.flat = 0});
  final double pct; // persen, mis. 5.25
  final double? cap; // maksimal Rp per item (null = tanpa batas)
  final double flat; // biaya tetap Rp

  double of(double base) {
    final v = base * pct / 100;
    return _rnd(flat + (cap == null ? v : min(v, cap!)));
  }

  /// Apakah batas maksimal per item sudah tercapai pada harga [base].
  bool isCapped(double base) => cap != null && base * pct / 100 > cap!;

  String get label {
    if (pct == 0 && flat > 0) return '${_rp(flat)} / pesanan';
    return cap == null ? _fmtPct(pct) : '${_fmtPct(pct)} (maks ${_rp(cap!)})';
  }
}

String _tagOf(FeeRate r) =>
    (r.pct == 0 && r.flat > 0) ? _rp(r.flat) : _fmtPct(r.pct);

String _noteOf(FeeRate r, double sell) {
  if (r.pct == 0 && r.flat > 0) return 'Biaya tetap ${_rp(r.flat)}';
  final base = '${_fmtPct(r.pct)} dari harga produk';
  if (r.cap == null) return base;
  return r.isCapped(sell)
      ? '$base · batas maks ${_rp(r.cap!)} tercapai'
      : '$base · maks ${_rp(r.cap!)}';
}

class PromoRates {
  const PromoRates(this.biasa, this.khusus);
  final FeeRate biasa;
  final FeeRate khusus;
}

class FeeCategory {
  FeeCategory({
    required this.name,
    required this.admin,
    required this.code,
    this.kode = '',
    this.mallName,
    this.adminMall,
    this.mallFee,
    this.goBiasa,
    this.goKhusus,
    this.group = '',
  }) : lname = name.toLowerCase(),
       lgroup = group.toLowerCase();

  final String name;
  final String lname;
  final String group; // "KATEGORI › SUB KATEGORI"
  final String lgroup;
  final double admin; // % Non-Star / Star / Star+
  final String kode; // "Kode Kategori" Shopee (angka, mis. 100145)
  final String?
  mallName; // nama kategori di tab Mall (bisa berbeda dari [name])
  final double? adminMall; // % Shopee Mall
  final FeeRate? mallFee; // "Fee MALL" + maksimalnya
  final FeeRate? goBiasa; // Gratis Ongkir, ukuran biasa
  final FeeRate? goKhusus; // Gratis Ongkir, ukuran khusus
  final String code; // "ID kat" (A–H) di tab ongkir → baris tarif Promo Iklan

  /// Kunci untuk mengingat kategori yang dipilih per produk.
  String get key => '$group|$name|$admin|$kode|$code';
}

enum KalkOpt {
  promoXtra('Promo XTRA'),
  promoXtraPlus('Promo XTRA+'),
  spayLater('SPayLater XTRA 0%'),
  live('Shopee Live XTRA'),
  video('Video XTRA'),
  preOrder('Produk pre-order'),
  asuransi('Asuransi pengiriman'),
  hemat('Program Hemat Biaya Kirim');

  const KalkOpt(this.title);
  final String title;
}

class OptionalFees {
  FeeRate? pph22;
  FeeRate? promoXtra;
  FeeRate? promoXtraPlus;
  final Map<int, double> spayLater = {}; // tenor (bulan) → %
  FeeRate? live;
  double?
  videoCap; // maksimal Rp per item (kolom "Maksimal" Video Xtra di sheet)
  // Video XTRA (sesuai tab "progam opsional"): 3% normal, 2% bila seller ikut
  // Promo XTRA / XTRA+. Maksimal Rp20.000 untuk keduanya.
  FeeRate? get video => FeeRate(3, cap: videoCap ?? 20000);
  FeeRate? get videoReduced => FeeRate(2, cap: videoCap ?? 20000);
  double? preOrder; // %
  double? asuransi; // %
  double? hemat; // Rp tetap
  FeeRate? proses; // Biaya proses pesanan (tab "biaya wajib")

  FeeRate? rate(KalkOpt o, {int tenor = 3, bool reducedVideo = false}) {
    switch (o) {
      case KalkOpt.promoXtra:
        return promoXtra;
      case KalkOpt.promoXtraPlus:
        return promoXtraPlus;
      case KalkOpt.spayLater:
        {
          final p = spayLater[tenor];
          return p == null ? null : FeeRate(p);
        }
      case KalkOpt.live:
        return live;
      case KalkOpt.video:
        return reducedVideo ? (videoReduced ?? video) : video;
      case KalkOpt.preOrder:
        {
          final p = preOrder;
          return p == null ? null : FeeRate(p);
        }
      case KalkOpt.asuransi:
        {
          final p = asuransi;
          return p == null ? null : FeeRate(p);
        }
      case KalkOpt.hemat:
        {
          final h = hemat;
          return h == null ? null : FeeRate(0, flat: h);
        }
    }
  }
}

/// Biaya tambahan buatan sendiri.
/// [seller] = false → biaya platform (masuk "Biaya Layanan").
/// [seller] = true  → biaya seller: voucher / subsidi (mengurangi harga jual).
/// [pct] = true → persen dari harga (+ batas maksimal [cap]); false → Rupiah tetap.
class CustomFee {
  CustomFee({
    required this.id,
    required this.name,
    required this.seller,
    required this.pct,
    required this.value,
    this.cap,
    this.on = true,
  });
  final String id, name;
  final bool seller, pct;
  final double value;
  final double? cap;
  bool on;

  FeeRate get rate => pct ? FeeRate(value, cap: cap) : FeeRate(0, flat: value);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'seller': seller,
    'pct': pct,
    'value': value,
    'cap': cap,
    'on': on,
  };

  factory CustomFee.fromJson(Map<String, dynamic> j) => CustomFee(
    id: '${j['id']}',
    name: '${j['name']}',
    seller: j['seller'] == true,
    pct: j['pct'] != false,
    value: (j['value'] as num?)?.toDouble() ?? 0,
    cap: (j['cap'] as num?)?.toDouble(),
    on: j['on'] != false,
  );
}

class _Parsed {
  final cats = <FeeCategory>[];
  final promo = <String, PromoRates>{};
  final opt = OptionalFees();
}

// ============================================================================
// PENYIMPANAN LOKAL (cache xlsx + pengaturan kalkulator)
// ============================================================================
class _KalkFiles {
  /// Folder yang sama dengan cache katalog (…/katalog di Application Support).
  static Future<Directory> _dir() async {
    final d = Directory(
      pth.join((await getApplicationSupportDirectory()).path, 'katalog'),
    );
    await d.create(recursive: true);
    return d;
  }

  static Future<File> cacheXlsx() async =>
      File(pth.join((await _dir()).path, 'kalkulator_biaya.xlsx'));

  /// Hapus sisa cache xlsx dari versi lama (data sekarang tertanam di aplikasi).
  static Future<void> deleteOldXlsxCache() async {
    try {
      final f = await cacheXlsx();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  static Future<File> _prefsFile() async =>
      File(pth.join((await _dir()).path, 'kalkulator_prefs.json'));

  static Future<Map<String, dynamic>> readPrefs() async {
    try {
      final f = await _prefsFile();
      if (await f.exists()) {
        final m = jsonDecode(await f.readAsString());
        if (m is Map) return Map<String, dynamic>.from(m);
      }
    } catch (_) {}
    return {};
  }

  static Future<void> writePrefs(Map<String, dynamic> m) async {
    try {
      await (await _prefsFile()).writeAsString(jsonEncode(m));
    } catch (_) {}
  }
}

// ============================================================================
// PEMBACA XLSX — semua tab → baris × kolom (teks)
// ============================================================================

/// Nama/teks dinormalkan: huruf kecil, tanpa spasi/enter/tanda baca (tanda + tetap).
String _n(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9+]'), '');

Iterable<XmlElement> _byLocal(XmlNode n, String l) =>
    n.descendants.whereType<XmlElement>().where((e) => e.name.local == l);

String _numStr(double d) {
  final r = double.parse(d.toStringAsFixed(8));
  if (r == r.roundToDouble() && r.abs() < 1e15) return r.toInt().toString();
  return r.toStringAsFixed(8).replaceFirst(RegExp(r'0+$'), '');
}

int _colIndex(String letters) {
  var n = 0;
  for (final u in letters.codeUnits) {
    n = n * 26 + (u - 64);
  }
  return n - 1;
}

/// Nama tab → baris (tiap baris = daftar sel, indeks 0 = kolom A). Sel persen
/// (format % di Sheets) dikembalikan sebagai teks "9%" agar tidak ambigu.
Map<String, List<List<String>>> _readXlsx(List<int> bytes) {
  final zip = ZipDecoder().decodeBytes(bytes);
  final files = {
    for (final f in zip.files)
      if (f.isFile) f.name: f,
  };

  XmlDocument xml(String path) =>
      XmlDocument.parse(utf8.decode(files[path]!.content as List<int>));

  Map<String, Map<String, String>> rels(String part) {
    final rp = pth.posix.join(
      pth.posix.dirname(part),
      '_rels',
      '${pth.posix.basename(part)}.rels',
    );
    if (!files.containsKey(rp)) return {};
    return {
      for (final r in _byLocal(xml(rp), 'Relationship'))
        r.getAttribute('Id')!: {'t': r.getAttribute('Target')!},
    };
  }

  String resolve(String part, String target) => target.startsWith('/')
      ? target.substring(1)
      : pth.posix.normalize(pth.posix.join(pth.posix.dirname(part), target));

  // string bersama
  final shared = <String>[];
  if (files.containsKey('xl/sharedStrings.xml')) {
    for (final si in _byLocal(xml('xl/sharedStrings.xml'), 'si')) {
      // hanya <t> yang bukan bagian fonetik (rPh)
      shared.add(
        _byLocal(si, 't')
            .where(
              (t) =>
                  !(t.parent is XmlElement &&
                      (t.parent as XmlElement).name.local == 'rPh'),
            )
            .map((e) => e.innerText)
            .join(),
      );
    }
  }

  // gaya: indeks xf mana yang berformat persen
  final pctXf = <bool>[];
  if (files.containsKey('xl/styles.xml')) {
    final st = xml('xl/styles.xml');
    final custom = <int, String>{};
    for (final nf in _byLocal(st, 'numFmt')) {
      final id = int.tryParse(nf.getAttribute('numFmtId') ?? '');
      if (id != null) custom[id] = nf.getAttribute('formatCode') ?? '';
    }
    final xfs = _byLocal(st, 'cellXfs').firstOrNull;
    if (xfs != null) {
      for (final xf in xfs.children.whereType<XmlElement>()) {
        final id = int.tryParse(xf.getAttribute('numFmtId') ?? '') ?? 0;
        pctXf.add(id == 9 || id == 10 || (custom[id] ?? '').contains('%'));
      }
    }
  }

  final wbRels = rels('xl/workbook.xml');
  final out = <String, List<List<String>>>{};
  final ref = RegExp(r'^([A-Z]+)(\d+)$');

  for (final s in _byLocal(xml('xl/workbook.xml'), 'sheet')) {
    final name = s.getAttribute('name')!;
    final rid = s.attributes.firstWhere((a) => a.name.local == 'id').value;
    final target = wbRels[rid]?['t'];
    if (target == null) continue;
    final part = resolve('xl/workbook.xml', target);
    if (!files.containsKey(part)) continue;

    final grid = <int, Map<int, String>>{};
    var maxRow = 0, maxCol = 0;
    for (final c in _byLocal(xml(part), 'c')) {
      final m = ref.firstMatch(c.getAttribute('r') ?? '');
      if (m == null) continue;
      final t = c.getAttribute('t');
      String? v;
      if (t == 's') {
        final i = int.tryParse(c.getElement('v')?.innerText ?? '');
        v = (i == null || i >= shared.length) ? null : shared[i];
      } else if (t == 'inlineStr') {
        v = _byLocal(c, 't').map((e) => e.innerText).join();
      } else if (t == 'str') {
        v = c.getElement('v')?.innerText;
      } else if (t == 'b' || t == 'e') {
        continue;
      } else {
        final raw = c.getElement('v')?.innerText;
        final d = raw == null ? null : double.tryParse(raw);
        if (d != null) {
          final si = int.tryParse(c.getAttribute('s') ?? '');
          final isPct = si != null && si < pctXf.length && pctXf[si];
          v = isPct ? '${_numStr(d * 100)}%' : _numStr(d);
        } else {
          v = raw;
        }
      }
      if (v == null || v.trim().isEmpty) continue;
      final r = int.parse(m[2]!), col = _colIndex(m[1]!);
      (grid[r] ??= {})[col] = v.trim();
      maxRow = max(maxRow, r);
      maxCol = max(maxCol, col);
    }
    out[name] = [
      for (var r = 1; r <= maxRow; r++)
        [for (var c = 0; c <= maxCol; c++) grid[r]?[c] ?? ''],
    ];
  }
  return out;
}

// ============================================================================
// DATABASE BIAYA (singleton) — unduh, cache, parse
// ============================================================================
class _Tbl {
  _Tbl(this.rows, this.hr);
  final List<List<String>> rows;
  final int hr; // indeks baris header

  List<String> get head => rows[hr];
  Iterable<List<String>> get body => rows.skip(hr + 1);

  /// Indeks kolom header pertama yang memenuhi [test] (nama sudah dinormalkan).
  int col(bool Function(String h) test, {int from = 0}) {
    for (var i = from; i < head.length; i++) {
      if (test(_n(head[i]))) return i;
    }
    return -1;
  }

  /// Kolom [i]+1 bila header-nya "maksimal…" (batas per item), selain itu -1.
  int capAfter(int i) =>
      (i >= 0 && i + 1 < head.length && _n(head[i + 1]).contains('maks'))
      ? i + 1
      : -1;
}

_Tbl? _findTable(List<List<String>>? rows, bool Function(String h) isHead) {
  if (rows == null) return null;
  for (var i = 0; i < rows.length && i < 15; i++) {
    if (rows[i].any((c) => c.isNotEmpty && isHead(_n(c)))) return _Tbl(rows, i);
  }
  return null;
}

String _cell(List<String> r, int i) =>
    (i >= 0 && i < r.length) ? r[i].trim() : '';

T? _pick<T>(List<T>? l, int occ) =>
    (l == null || l.isEmpty) ? null : l[occ < l.length ? occ : 0];

/// Mengisi KATEGORI / SUB KATEGORI yang kosong (sel digabung) dari baris di atasnya.
class _Fill {
  String kat = '', sub = '';
  String step(List<String> r, int cKat, int cSub) {
    final k = _cell(r, cKat);
    if (k.isNotEmpty && k != kat) {
      kat = k;
      sub = '';
    }
    final s = _cell(r, cSub);
    if (s.isNotEmpty) sub = s;
    return kat.isEmpty ? sub : (sub.isEmpty ? kat : '$kat › $sub');
  }
}

class _MallRow {
  _MallRow(this.name, this.kode, this.adm, this.fee, this.group);
  final String name, kode, group;
  final double? adm;
  final FeeRate? fee;
}

class _GoRow {
  _GoRow(this.name, this.id, this.biasa, this.khusus, this.group);
  final String name, id, group;
  final FeeRate? biasa, khusus;
}

class FeeDb extends ChangeNotifier {
  FeeDb._();
  static final FeeDb instance = FeeDb._();

  /// File data biaya admin yang tertanam di aplikasi (daftar di pubspec.yaml).
  static const assetPath = 'assets/kalkulator/biaya_admin.xlsx';

  List<FeeCategory> categories = const [];
  Map<String, PromoRates> promo = const {};
  OptionalFees opt = OptionalFees();
  bool loading = false;
  String? error;
  Future<void>? _init;

  bool get ready => categories.isNotEmpty;

  /// Dipanggil sekali (idempoten): baca data dari file yang tertanam.
  Future<void> ensureLoaded() async {
    await (_init ??= _load());
  }

  /// Baca ulang file tertanam (dipakai tombol "Coba lagi" bila gagal baca).
  Future<void> refresh() async {
    loading = true;
    error = null;
    notifyListeners();
    await _loadAsset();
    loading = false;
    notifyListeners();
  }

  Future<void> _load() async {
    loading = true;
    notifyListeners();
    await _loadAsset();
    unawaited(_KalkFiles.deleteOldXlsxCache());
    loading = false;
    notifyListeners();
  }

  Future<bool> _loadAsset() async {
    try {
      final data = await rootBundle.load(assetPath);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      _apply(_parse(bytes));
      error = null;
      return true;
    } on FormatException catch (e) {
      error = e.message;
    } catch (e) {
      error =
          'Gagal membaca data biaya bawaan (${e.runtimeType}). '
          'Pastikan $assetPath ada di folder assets dan terdaftar di pubspec.yaml.';
    }
    return false;
  }

  void _apply(_Parsed p) {
    categories = List.unmodifiable(p.cats);
    promo = Map.unmodifiable(p.promo);
    opt = p.opt;
  }

  /// Cari kategori: semua kata harus ada di nama; yang diawali kata pertama
  /// diurutkan lebih dulu.
  List<FeeCategory> search(String q, {int limit = 10}) {
    final tokens = q
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.isEmpty) return const [];
    final hits = <(int, FeeCategory)>[];
    for (final c in categories) {
      final n = c.lname;
      final hay = '$n ${c.lgroup}';
      if (!tokens.every((t) => hay.contains(t))) continue;
      final score = n == q.toLowerCase().trim()
          ? 0
          : (n.startsWith(tokens.first) ? 1 : 2);
      hits.add((score, c));
    }
    hits.sort((a, b) {
      final d = a.$1.compareTo(b.$1);
      return d != 0 ? d : a.$2.name.compareTo(b.$2.name);
    });
    return [for (final h in hits.take(limit)) h.$2];
  }

  // ---------------- parser ----------------
  //
  // Tab (dikenali dari NAMA tab, tidak peka huruf besar/kecil):
  //   "star/star+"          JENIS PRODUK | BIAYA ADMIN | Kode Kategori
  //   "Mall"                JENIS PRODUK | BIAYA ADMINISTRASI SHOPEE MALL | Fee MALL |
  //                         Maks Fee Mall | Kode Kategori
  //   "biaya gratis ongkir" JENIS PRODUK | Admin Ukuran Biasa | Maksimal/Item |
  //                         Admin Ukuran Khusus | Maksimal/Item | ID kat (A–H)
  //   "promo iklan"         Kategori Produk (A–H) | Produk Ukuran Biasa | Maksimal |
  //                         Produk Ukuran Khusus | Maksimal
  //   "progam opsional"     Promo Xtra | Maksimal | Promo Xtra+ | Maksimal |
  //                         SPayLater XTRA 0% | Biaya layanan | Live xtra | Maksimal |
  //                         Video Xtra | Maksimal | Pre Order | Asuransi Pengiriman |
  //                         Program Hemat Biaya Kirim
  //   "pajak"               PPh 22
  //
  // Tab star/star+ adalah daftar kategori utama. Data Mall & Ongkir disambung ke
  // tiap kategori lewat nama (+ Kode Kategori) — kemunculan ke-n nama yang sama
  // di tab star dicocokkan dengan kemunculan ke-n di tab lain (mis. "Kalung"
  // ada dua: perhiasan fashion 9% dan perhiasan berharga 4,25%).
  static _Parsed _parse(List<int> bytes) {
    final book = _readXlsx(bytes);

    List<List<String>>? tab(bool Function(String n) test) {
      for (final e in book.entries) {
        if (test(_n(e.key))) return e.value;
      }
      return null;
    }

    final starRows = tab((n) => n.contains('star') && !n.contains('mall'));
    final mallRows = tab((n) => n.contains('mall'));
    final goRows = tab((n) => n.contains('ongkir'));
    final promoRows = tab((n) => n.contains('iklan'));
    final optRows = tab((n) => n.contains('opsi'));
    final taxRows = tab((n) => n.contains('pajak'));

    if (starRows == null) {
      throw FormatException(
        'Tab "star/star+" tidak ditemukan. Tab yang terbaca: '
        '${book.keys.join(', ')}.',
      );
    }

    // ----- tab star/star+ : kategori utama -----
    final st = _findTable(
      starRows,
      (h) => h.contains('jenis') || h == 'kategoriproduk',
    );
    if (st == null) {
      throw const FormatException(
        'Tab "star/star+": header JENIS PRODUK tidak ditemukan.',
      );
    }
    final sName = st.col((h) => h.contains('jenis') || h.contains('produk'));
    final sAdm = st.col((h) => h.contains('admin'));
    final sKode = st.col((h) => h.contains('kode') || h.contains('idkat'));
    final sKat = st.col((h) => h == 'kategori');
    final sSub = st.col((h) => h == 'subkategori');
    if (sName < 0 || sAdm < 0) {
      throw const FormatException(
        'Tab "star/star+": kolom JENIS PRODUK / BIAYA ADMIN tidak ditemukan.',
      );
    }

    // ----- tab Mall -----
    final malls = <_MallRow>[];
    final mt = _findTable(mallRows, (h) => h.contains('jenisproduk'));
    if (mt != null) {
      final mName = mt.col((h) => h.contains('jenis'));
      var mAdm = mt.col((h) => h.contains('administrasi'));
      if (mAdm < 0) {
        mAdm = mt.col(
          (h) =>
              h.contains('mall') &&
              !h.contains('fee') &&
              !h.contains('maks') &&
              !h.contains('kode'),
        );
      }
      final mFee = mt.col((h) => h.startsWith('fee') && !h.contains('maks'));
      var mCap = mFee < 0 ? -1 : mt.col((h) => h.contains('maks'), from: mFee);
      if (mCap < 0) mCap = mt.col((h) => h.contains('maks'));
      final mKode = mt.col((h) => h.contains('kode') || h.contains('idkat'));
      final mKat = mt.col((h) => h == 'kategori');
      final mSub = mt.col((h) => h == 'subkategori');
      final fill = _Fill();
      for (final r in mt.body) {
        final grp = fill.step(r, mKat, mSub);
        final name = _cell(r, mName);
        if (name.isEmpty) continue;
        malls.add(
          _MallRow(
            name,
            _cell(r, mKode),
            _parsePct(_cell(r, mAdm)),
            _rate(_cell(r, mFee), _cell(r, mCap)),
            grp,
          ),
        );
      }
    }
    final mallByNg = <String, List<_MallRow>>{};
    final mallByNc = <String, List<_MallRow>>{};
    final mallByName = <String, List<_MallRow>>{};
    for (final m in malls) {
      (mallByNg['${_n(m.name)}|${_n(m.group)}'] ??= []).add(m);
      (mallByNc['${_n(m.name)}|${m.kode}'] ??= []).add(m);
      (mallByName[_n(m.name)] ??= []).add(m);
    }

    // ----- tab biaya gratis ongkir -----
    final gos = <_GoRow>[];
    final gt = _findTable(goRows, (h) => h.contains('jenisproduk'));
    if (gt != null) {
      final gName = gt.col((h) => h.contains('jenis'));
      final gB = gt.col((h) => h.contains('biasa'));
      final gK = gt.col((h) => h.contains('khusus'));
      var gId = gt.col((h) => h.contains('idkat') || h.contains('kode'));
      if (gId < 0) gId = 7; // kolom H
      final gKat = gt.col((h) => h == 'kategori');
      final gSub = gt.col((h) => h == 'subkategori');
      final fill = _Fill();
      for (final r in gt.body) {
        final grp = fill.step(r, gKat, gSub);
        final name = _cell(r, gName);
        if (name.isEmpty) continue;
        gos.add(
          _GoRow(
            name,
            _cell(r, gId).toUpperCase(),
            _rate(_cell(r, gB), _cell(r, gt.capAfter(gB))),
            _rate(_cell(r, gK), _cell(r, gt.capAfter(gK))),
            grp,
          ),
        );
      }
    }
    final goByNg = <String, List<_GoRow>>{};
    final goByName = <String, List<_GoRow>>{};
    for (final g in gos) {
      (goByNg['${_n(g.name)}|${_n(g.group)}'] ??= []).add(g);
      (goByName[_n(g.name)] ??= []).add(g);
    }

    // ----- gabungkan -----
    final out = _Parsed();
    final starData = <(String, String, double, String)>[];
    final starFill = _Fill();
    for (final r in st.body) {
      final grp = starFill.step(r, sKat, sSub);
      final name = _cell(r, sName);
      final admin = _parsePct(_cell(r, sAdm));
      if (name.isEmpty || admin == null) continue;
      starData.add((name, _cell(r, sKode), admin, grp));
    }
    final nameSeen = <String, int>{};
    final ncSeen = <String, int>{};
    final ngSeen = <String, int>{};
    for (var i = 0; i < starData.length; i++) {
      final (name, kode, admin, group) = starData[i];
      final nn = _n(name);
      final occ = nameSeen[nn] ?? 0;
      nameSeen[nn] = occ + 1;
      final nc = '$nn|$kode';
      final occC = ncSeen[nc] ?? 0;
      ncSeen[nc] = occC + 1;
      final ng = '$nn|${_n(group)}';
      final occG = ngSeen[ng] ?? 0;
      ngSeen[ng] = occG + 1;

      // urutan pencocokan: nama+kategori+sub → nama+kode → nama → posisi baris
      final m =
          _pick(mallByNg[ng], occG) ??
          _pick(mallByNc[nc], occC) ??
          _pick(mallByName[nn], occ) ??
          (malls.length == starData.length ? malls[i] : null);
      final g =
          _pick(goByNg[ng], occG) ??
          _pick(goByName[nn], occ) ??
          (gos.length == starData.length ? gos[i] : null);

      out.cats.add(
        FeeCategory(
          name: name,
          admin: admin,
          kode: kode,
          code: g?.id ?? '',
          mallName: m?.name,
          adminMall: m?.adm,
          mallFee: m?.fee,
          goBiasa: g?.biasa,
          goKhusus: g?.khusus,
          group: group,
        ),
      );
    }
    if (out.cats.isEmpty) {
      throw const FormatException(
        'Tidak ada kategori yang terbaca dari tab "star/star+".',
      );
    }

    // ----- tab promo iklan -----
    final pt = _findTable(
      promoRows,
      (h) => h == 'kategoriproduk' || h.contains('jenisproduk'),
    );
    if (pt != null) {
      final pKey = pt.col((h) => h == 'kategoriproduk' || h.contains('jenis'));
      final pB = pt.col((h) => h.contains('biasa'));
      final pK = pt.col((h) => h.contains('khusus'));
      for (final r in pt.body) {
        final key = _cell(r, pKey).toUpperCase();
        if (key.isEmpty || out.promo.containsKey(key)) continue;
        final b = _rate(_cell(r, pB), _cell(r, pt.capAfter(pB)));
        final k = _rate(_cell(r, pK), _cell(r, pt.capAfter(pK)));
        if (b != null && k != null) out.promo[key] = PromoRates(b, k);
      }
    }

    // ----- tab progam opsional -----
    final o = out.opt;
    final ot = _findTable(
      optRows,
      (h) => h.contains('promoxtra') || h.contains('spaylater'),
    );
    if (ot != null) {
      final cPx = ot.col((h) => h == 'promoxtra');
      final cPxp = ot.col(
        (h) =>
            h.startsWith('promoxtra') &&
            (h.contains('+') || h.contains('plus')),
      );
      final cSp = ot.col((h) => h.contains('spaylater'));
      var cSpPct = ot.col((h) => h.contains('layanan'), from: max(cSp, 0));
      if (cSpPct < 0 && cSp >= 0) cSpPct = cSp + 1;
      final cLive = ot.col((h) => h.contains('live'));
      final vidCols = [
        for (var i = 0; i < ot.head.length; i++)
          if (_n(ot.head[i]).contains('video') &&
              !_n(ot.head[i]).contains('maks'))
            i,
      ];
      final vids = <FeeRate>[];
      final cPre = ot.col((h) => h.contains('preorder'));
      final cIns = ot.col((h) => h.contains('asuransi'));
      final cHem = ot.col((h) => h.contains('hemat'));
      for (final r in ot.body) {
        if (cPx >= 0)
          o.promoXtra ??= _rate(_cell(r, cPx), _cell(r, ot.capAfter(cPx)));
        if (cPxp >= 0)
          o.promoXtraPlus ??= _rate(
            _cell(r, cPxp),
            _cell(r, ot.capAfter(cPxp)),
          );
        if (cSp >= 0) {
          final tm = RegExp(r'(\d+)').firstMatch(_cell(r, cSp));
          final tp = _parsePct(_cell(r, cSpPct));
          if (tm != null && tp != null)
            o.spayLater[int.parse(tm.group(1)!)] = tp;
        }
        if (cLive >= 0)
          o.live ??= _rate(_cell(r, cLive), _cell(r, ot.capAfter(cLive)));
        for (final vc in vidCols) {
          final v = _rate(_cell(r, vc), _cell(r, ot.capAfter(vc)));
          if (v != null) vids.add(v);
        }
        if (cPre >= 0) o.preOrder ??= _parsePct(_cell(r, cPre));
        if (cIns >= 0) o.asuransi ??= _parsePct(_cell(r, cIns));
        if (cHem >= 0) o.hemat ??= _parseMoney(_cell(r, cHem));
      }
      // Video XTRA: 3% normal, 2% bila seller aktif Promo XTRA / XTRA+. Tarif
      // ditetapkan di sini (nilai di sheet pernah terbaca salah, mis. 0,22%);
      // batas maksimal tetap diambil dari sheet bila ada (default Rp20.000).
      double? vCap;
      for (final v in vids) {
        if (v.cap != null) vCap = max(vCap ?? 0, v.cap!);
      }
      o.videoCap = vCap;
    }

    // ----- tab pajak -----
    if (taxRows != null) {
      double? pph;
      int? hr, hc;
      for (var r = 0; r < taxRows.length && hr == null; r++) {
        for (var c = 0; c < taxRows[r].length; c++) {
          final h = _n(taxRows[r][c]);
          if (h.contains('pph') || h.contains('pajak')) {
            hr = r;
            hc = c;
            break;
          }
        }
      }
      if (hr != null && hc != null) {
        // sebelah kanan judul, lalu di bawahnya
        for (var c = hc + 1; c < taxRows[hr].length && pph == null; c++) {
          pph = _pctCell(taxRows[hr][c]);
        }
        for (var r = hr + 1; r < taxRows.length && pph == null; r++) {
          pph = _pctCell(_cell(taxRows[r], hc));
        }
      }
      if (pph == null) {
        for (final row in taxRows) {
          for (final c in row) {
            if (pph == null && c.contains('%')) pph = _pctCell(c);
          }
        }
      }
      if (pph != null) o.pph22 = FeeRate(pph);
    }

    // ----- tab biaya wajib : "Biaya proses pesanan" -----
    // Judul (mis. A1) berisi "proses pesanan"; nilainya di bawah judul pada kolom
    // yang sama (mis. A2 = 1250), atau di kanan judul bila di bawahnya kosong.
    // Tab "biaya wajib" dicoba dulu, lalu semua tab lain sebagai cadangan.
    FeeRate? findProses(List<List<String>> rows) {
      for (var r = 0; r < rows.length; r++) {
        for (var c = 0; c < rows[r].length; c++) {
          final h = _n(rows[r][c]);
          if (!(h.contains('proses') && h.contains('pesanan'))) continue;
          final cands = <String>[
            for (var k = r + 1; k < rows.length && k <= r + 6; k++)
              _cell(rows[k], c),
            for (var k = c + 1; k < rows[r].length; k++) _cell(rows[r], k),
          ];
          for (final v in cands) {
            if (!RegExp(r'\d').hasMatch(v)) continue;
            if (v.contains('%')) {
              final f = _rate(v, '');
              if (f != null) return f;
            } else {
              final m = _parseMoney(v);
              if (m != null && m > 0) return FeeRate(0, flat: m);
            }
          }
        }
      }
      return null;
    }

    final wajibFirst = [
      ...book.entries.where((e) => _n(e.key).contains('wajib')),
      ...book.entries.where((e) => !_n(e.key).contains('wajib')),
    ];
    for (final e in wajibFirst) {
      o.proses = findProses(e.value);
      if (o.proses != null) break;
    }
    return out;
  }

  /// Hanya sel yang murni angka / angka berpersen ("0,5%", "0.005", "1").
  static double? _pctCell(String s) {
    final t = s.trim();
    return RegExp(r'^[\d.,]+\s*%?$').hasMatch(t) ? _parsePct(t) : null;
  }

  static FeeRate? _rate(String pct, String cap) {
    final p = _parsePct(pct);
    return p == null ? null : FeeRate(p, cap: _parseMoney(cap));
  }

  /// "5,25%" / "5.25%" / "0.0525" → 5.25
  static double? _parsePct(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    final hasPct = t.contains('%');
    var s = t.replaceAll(RegExp(r'[^0-9,.]'), '');
    if (s.isEmpty) return null;
    if (s.contains(',') && s.contains('.')) {
      s = s.replaceAll('.', '').replaceAll(',', '.');
    } else {
      s = s.replaceAll(',', '.');
    }
    final v = double.tryParse(s);
    if (v == null) return null;
    final p = (!hasPct && v <= 1) ? v * 100 : v; // pecahan mentah 0.0525 → 5.25
    return double.parse(p.toStringAsFixed(4));
  }

  /// "50000" / "50.000" / "Rp 50.000" → 50000
  static double? _parseMoney(String raw) {
    var s = raw.replaceAll(RegExp(r'[^0-9,.]'), '');
    if (s.isEmpty) return null;
    if (RegExp(r'^\d{1,3}([.,]\d{3})+$').hasMatch(s)) {
      s = s.replaceAll(RegExp(r'[.,]'), '');
    } else {
      s = s.replaceAll(',', '.');
    }
    return double.tryParse(s);
  }
}

// ============================================================================
// ============================================================================
// PERHITUNGAN
// ============================================================================
// Judul kelompok biaya di kartu Rincian Penghasilan.
const String _gPlatform = 'Biaya Platform Shopee';
const String _gGo = 'Biaya Gratis Ongkir XTRA';
const String _gPromo = 'Biaya Promosi';
const String _gLayanan = 'Biaya Layanan';
const String _gPajak = 'Pajak';

/// Warna chip biaya: program/ongkir/iklan = oranye Shopee, pajak PPh = merah.
const Color _kShopeeOrange = Color(0xFFEE4D2D);
const Color _kPphRed = Color(0xFFC62828);

class FeeLine {
  FeeLine(
    this.label,
    double amount, {
    this.note,
    this.group = '',
    this.tag,
    this.promo = false,
    this.rate,
  }) : amount = _rnd(amount);
  final FeeRate?
  rate; // tarif sumber (untuk detail di tooltip Rincian Penghasilan)
  final String? tag; // tarif singkat di samping nama, mis. "9%" atau "Rp1.250"
  final String label;
  final double amount;
  final String? note;
  final String group; // judul kelompok di kartu rincian
  // true: tarif baris ini berasal dari Promo Iklan (menggantikan tarif Gratis Ongkir).
  final bool promo;
}

/// Satu potongan di grafik "Struktur Harga Jual" (halaman Analisis Harga).

class _Cfg {
  const _Cfg({
    required this.cat,
    required this.procRate,
    required this.affPct,
    required this.mall,
    required this.khusus,
    required this.goOn,
    required this.promoOn,
    required this.opts,
    required this.tenor,
    required this.pph,
    this.platform = const [],
    this.seller = const [],
  });
  final List<CustomFee> platform, seller; // biaya kustom aktif
  final FeeCategory? cat;
  final FeeRate? procRate; // biaya proses pesanan
  final double affPct; // komisi affiliasi (% dari harga jual)
  final bool mall, khusus, goOn, promoOn, pph;
  final Set<KalkOpt> opts;
  final int tenor;

  /// Salinan dengan komisi affiliasi [p] % (untuk simulasi tier affiliasi).
  _Cfg withAff(double p) => _Cfg(
    cat: cat,
    procRate: procRate,
    affPct: p,
    mall: mall,
    khusus: khusus,
    goOn: goOn,
    promoOn: promoOn,
    opts: opts,
    tenor: tenor,
    pph: pph,
    platform: platform,
    seller: seller,
  );
}

/// Semua potongan (di luar "biaya lain per pcs") untuk harga jual [sell].
List<FeeLine> _computeFees(double sell, _Cfg c) {
  final db = FeeDb.instance;
  final cat = c.cat;
  final out = <FeeLine>[];

  // 1. Biaya wajib: admin kategori + biaya proses pesanan
  const gAdmin = _gPlatform;
  if (cat != null) {
    final pct = c.mall ? (cat.adminMall ?? cat.admin) : cat.admin;
    out.add(
      FeeLine(
        c.mall
            ? 'Biaya admin Shopee Mall'
            : 'Biaya admin Non-Star / Star / Star+',
        sell * pct / 100,
        note: '${_fmtPct(pct)} dari harga produk',
        group: gAdmin,
        tag: _fmtPct(pct),
        rate: FeeRate(pct),
      ),
    );
    final mf = cat.mallFee;
    if (c.mall && mf != null) {
      out.add(
        FeeLine(
          'Fee Mall',
          mf.of(sell),
          note: _noteOf(mf, sell),
          group: gAdmin,
          tag: _tagOf(mf),
          rate: mf,
        ),
      );
    }
  }
  final proc = c.procRate;
  if (proc != null) {
    out.add(
      FeeLine(
        'Biaya proses pesanan',
        proc.of(sell),
        note: proc.pct == 0 ? 'Biaya tetap per pesanan' : _noteOf(proc, sell),
        group: gAdmin,
        tag: _tagOf(proc),
        rate: proc,
      ),
    );
  }

  // 2 / 3. Gratis Ongkir XTRA (ukuran biasa/khusus). Bila Promo Iklan aktif, tarif
  // Promo Iklan pada ID kategori (A–H) yang sama MENGGANTIKAN tarif Gratis Ongkir,
  // mengikuti ukuran yang sama.
  const gShip = _gGo;
  const gPromo = _gPromo;
  if (cat != null && (c.goOn || c.promoOn)) {
    final size = c.khusus ? 'Khusus' : 'Biasa';
    final go = c.khusus ? cat.goKhusus : cat.goBiasa;
    final pr = db.promo[cat.code];
    final pRate = pr == null ? null : (c.khusus ? pr.khusus : pr.biasa);
    final kat = cat.code.isEmpty ? '' : 'Kategori ${cat.code} · ';
    final katTxt = cat.code.isEmpty ? '' : ' untuk Kategori ${cat.code}';
    final goTxt = go == null ? '' : ' ${_fmtPct(go.pct)}';
    if (c.promoOn && pRate != null) {
      // Promo Iklan aktif: tarifnya MENGGANTIKAN tarif Gratis Ongkir, tetap di kartu
      // "Biaya Gratis Ongkir XTRA"; penjelasannya ada di tombol (?).
      out.add(
        FeeLine(
          'Ukuran $size',
          pRate.of(sell),
          note:
              'Promo Iklan sedang aktif. Tarif Promo Iklan ukuran $size$katTxt '
              '(${_noteOf(pRate, sell)}) menggantikan tarif Gratis Ongkir XTRA$goTxt.',
          group: gShip,
          tag: '($kat${_tagOf(pRate)})',
          promo: true,
          rate: pRate,
        ),
      );
    } else if (go != null) {
      out.add(
        FeeLine(
          'Ukuran $size',
          go.of(sell),
          note: 'Gratis Ongkir XTRA ukuran $size · ${_noteOf(go, sell)}',
          group: gShip,
          tag: '($kat${_tagOf(go)})',
          rate: go,
        ),
      );
    }
  }

  // 4. Biaya layanan (program opsional)
  const gOpt = _gLayanan;
  final reduced =
      c.opts.contains(KalkOpt.promoXtra) ||
      c.opts.contains(KalkOpt.promoXtraPlus);
  for (final o in KalkOpt.values) {
    if (!c.opts.contains(o)) continue;
    final r = db.opt.rate(o, tenor: c.tenor, reducedVideo: reduced);
    if (r != null) {
      var note = _noteOf(r, sell);
      if (o == KalkOpt.spayLater) note = '$note · ${c.tenor} bulan';
      if (o == KalkOpt.video && reduced && db.opt.videoReduced != null) {
        note = '$note · tarif turun karena Promo XTRA aktif';
      }
      out.add(
        FeeLine(
          o.title,
          r.of(sell),
          note: note,
          group: gOpt,
          tag: _tagOf(r),
          rate: r,
        ),
      );
    }
  }

  // 4b. Biaya platform kustom (ikut "Biaya Layanan")
  for (final f in c.platform) {
    final r = f.rate;
    out.add(
      FeeLine(
        f.name,
        r.of(sell),
        note: _noteOf(r, sell),
        group: gOpt,
        tag: _tagOf(r),
        rate: r,
      ),
    );
  }

  // 5. Pajak
  if (c.pph) {
    final r = db.opt.pph22;
    if (r != null) {
      out.add(
        FeeLine(
          'PPh 22',
          r.of(sell),
          note: _noteOf(r, sell),
          group: 'Pajak',
          tag: _tagOf(r),
          rate: r,
        ),
      );
    }
  }

  // 6. Komisi affiliasi
  if (c.affPct > 0) {
    out.add(
      FeeLine(
        'Komisi affiliasi',
        sell * c.affPct / 100,
        note: '${_fmtPct(c.affPct)} dari harga produk',
        group: gPromo,
        tag: _fmtPct(c.affPct),
        rate: FeeRate(c.affPct),
      ),
    );
  }
  return out;
}

/// Biaya seller (voucher / subsidi): mengurangi harga jual pembeli [price].
List<FeeLine> _sellerLines(double price, _Cfg c) => [
  for (final f in c.seller)
    FeeLine(
      f.name,
      min(f.rate.of(price), price),
      note: _noteOf(f.rate, price),
      group: 'Voucher & Subsidi',
      tag: _tagOf(f.rate),
    ),
];

double _sumFees(List<FeeLine> l) => l.fold<double>(0, (a, e) => a + e.amount);

/// Harga jual terendah agar laba >= 0 (biner, karena ada batas maksimal per biaya).
double? _minSell(double modal, double extra, _Cfg c) {
  double net(double s) {
    final p = max(s - _sumFees(_sellerLines(s, c)), 0.0);
    return p - _sumFees(_computeFees(p, c)) - extra - modal;
  }

  var hi = max(1000.0, (modal + extra) * 2);
  var guard = 0;
  while (net(hi) < 0 && guard++ < 40) {
    hi *= 2;
  }
  if (net(hi) < 0) return null;
  var lo = 0.0;
  for (var i = 0; i < 60; i++) {
    final mid = (lo + hi) / 2;
    if (net(mid) >= 0) {
      hi = mid;
    } else {
      lo = mid;
    }
  }
  return hi;
}

/// Harga jual terendah agar margin (laba / harga jual) mencapai [marginPct].
/// null bila target tidak mungkin tercapai dengan biaya yang aktif.
double? _sellForMargin(double modal, double extra, _Cfg c, double marginPct) {
  double f(double sell) {
    final p = max(sell - _sumFees(_sellerLines(sell, c)), 0.0);
    return p -
        _sumFees(_computeFees(p, c)) -
        extra -
        modal -
        sell * marginPct / 100;
  }

  var hi = max(1000.0, (modal + extra) * 2);
  var guard = 0;
  while (f(hi) < 0 && guard++ < 40) {
    hi *= 2;
  }
  if (f(hi) < 0) return null;
  var lo = 0.0;
  for (var i = 0; i < 60; i++) {
    final mid = (lo + hi) / 2;
    if (f(mid) >= 0) {
      hi = mid;
    } else {
      lo = mid;
    }
  }
  return hi;
}

/// Laba per pcs pada harga jual [sell] (sama persis dengan hitungan kalkulator).
double _profitAt(double sell, double modal, double extra, _Cfg c) {
  final p = max(sell - _sumFees(_sellerLines(sell, c)), 0.0);
  return p - _sumFees(_computeFees(p, c)) - extra - modal;
}

/// Profil margin menurut jenis kategori. Barang seperti fashion/kecantikan
/// biasanya bermargin tebal, sedangkan alat tulis/pena atau elektronik sangat
/// tipis, jadi target margin tiap tingkat harga ikut menyesuaikan.
class _MarginProfile {
  const _MarginProfile(this.label, this.tipis, this.sedang, this.tinggi);
  final String label; // mis. "Margin tebal"
  final double tipis, sedang, tinggi; // target margin (% dari harga jual)
}

const _kProfTebal = _MarginProfile('Margin tebal', 12, 25, 40);
const _kProfSedang = _MarginProfile('Margin sedang', 8, 15, 25);
const _kProfTipis = _MarginProfile('Margin tipis', 4, 8, 14);
const _kProfReceh = _MarginProfile('Margin receh', 3, 6, 10);

_MarginProfile _profileOf(FeeCategory? cat) {
  if (cat == null) return _kProfSedang;
  final t = '${cat.lgroup} ${cat.lname}';
  bool has(List<String> ks) => ks.any(t.contains);
  // 1) receh: alat tulis, pena, buku, perlengkapan kantor
  if (has([
    'alat tulis',
    'pena',
    'pulpen',
    'stationery',
    'buku',
    'kertas',
    'perlengkapan kantor',
    'perlengkapan sekolah',
  ])) {
    return _kProfReceh;
  }
  // aksesoris barang elektronik/gadget: margin menengah, bukan tipis
  final aksElek =
      t.contains('aksesoris') &&
      has(['handphone', 'elektronik', 'komputer', 'kamera', 'gadget']);
  if (aksElek) return _kProfSedang;
  // 2) tipis: elektronik, gadget, makanan-minuman, voucher
  if (has([
    'elektronik',
    'handphone',
    'tablet',
    'komputer',
    'laptop',
    'kamera',
    'gadget',
    'makanan',
    'minuman',
    'groceries',
    'sembako',
    'voucher',
    'pulsa',
    'tiket',
    'konsol',
    'game',
  ])) {
    return _kProfTipis;
  }
  // 3) tebal: fashion, kecantikan, tas, sepatu, perhiasan
  if (has([
    'fashion',
    'pakaian',
    'muslim',
    'hijab',
    'batik',
    'kecantikan',
    'perawatan',
    'kosmetik',
    'skincare',
    'parfum',
    'tas ',
    'sepatu',
    'perhiasan',
    'aksesoris',
    'jam tangan',
  ])) {
    return _kProfTebal;
  }
  return _kProfSedang;
}

class _PriceTier {
  const _PriceTier(this.name, this.price, this.profit, this.margin);
  final String name;
  final double price, profit, margin;
}

// ============================================================================
// WIDGET KALKULATOR UNTUNG
// ============================================================================
class KalkulatorUntung extends StatelessWidget {
  const KalkulatorUntung({
    super.key,
    required this.grosir,
    required this.ds,
    this.productKey,
    this.title,
  });

  /// Harga modal grosir / dropship per pcs (null = tidak tersedia).
  final num? grosir;
  final num? ds;

  /// Pengenal produk (mis. Product.key) untuk mengingat kategori yang dipilih.
  final String? productKey;

  /// Nama produk, ditampilkan di judul dialog.
  final String? title;

  @override
  Widget build(BuildContext context) => Material(
    color: cSurface2,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
      side: BorderSide(color: cLine),
    ),
    child: InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => showDialog<void>(
        context: context,
        useRootNavigator: true,
        builder: (_) => _KalkBody(
          grosir: grosir,
          ds: ds,
          productKey: productKey,
          title: title,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: Row(
          children: [
            const _CalcLogo(size: 28),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Kalkulator Shopee',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: cText,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    'Hitung laba setelah admin, ongkir, promo & pajak',
                    style: TextStyle(fontSize: 11.5, color: cSub),
                  ),
                ],
              ),
            ),
            Icon(Icons.open_in_full, size: 16, color: cSub),
          ],
        ),
      ),
    ),
  );
}

/// Isi dialog kalkulator (layar lebar: kiri input, kanan hasil).
class _KalkBody extends StatefulWidget {
  const _KalkBody({
    required this.grosir,
    required this.ds,
    this.productKey,
    this.title,
  });
  final num? grosir;
  final num? ds;
  final String? productKey;
  final String? title;

  @override
  State<_KalkBody> createState() => _KalkBodyState();
}

class _KalkBodyState extends State<_KalkBody> {
  final _db = FeeDb.instance;

  bool _useDs = false;

  final _sell = TextEditingController();
  final _extra = TextEditingController(
    text: store.calcExtra > 0 ? '${store.calcExtra}' : '',
  );
  bool _sellAuto = true; // Auto: harga jual mengikuti tingkat saran [_autoTier]
  String _autoTier = 'Tinggi'; // Impas | Tipis | Sedang | Tinggi
  Timer? _saveTimer;
  final _aff = TextEditingController(); // affiliasi (%)
  final _q = TextEditingController();
  final _qFocus = FocusNode();

  FeeCategory? _cat;
  bool _mall = false;
  bool _khusus = false;
  bool _goOn = false;
  bool _promoOn = false;
  bool _pph = false;
  bool _full = false; // mode layar penuh dialog kalkulator
  int _tenor = 3;
  final Set<KalkOpt> _opts = {};

  Map<String, dynamic> _prefs = {};
  bool _prefsLoaded = false;
  List<CustomFee> _customs = [];
  bool _customSeller = false; // tab aktif: false = platform, true = seller

  static String _numText(double v) =>
      v == v.roundToDouble() ? '${v.toInt()}' : '$v';
  static int _num(String s) =>
      int.tryParse(s.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
  static double _pctIn(String s) =>
      (double.tryParse(s.replaceAll(',', '.')) ?? 0).clamp(0, 99.9).toDouble();

  @override
  void initState() {
    super.initState();
    _db.addListener(_onDb);
    _loadPrefs();
    WidgetsBinding.instance.addPostFrameCallback((_) => _db.ensureLoaded());
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _savePrefs();
    _saveStore();
    _db.removeListener(_onDb);
    _sell.dispose();
    _extra.dispose();
    _aff.dispose();
    _q.dispose();
    _qFocus.dispose();
    super.dispose();
  }

  // ---------- state & penyimpanan ----------
  void _onDb() {
    if (!mounted) return;
    setState(() {
      _restoreCat();
    });
  }

  Future<void> _loadPrefs() async {
    final m = await _KalkFiles.readPrefs();
    if (!mounted) return;
    setState(() {
      _prefs = m;
      _mall = (m['mall'] as bool?) ?? false;
      _khusus = (m['khusus'] as bool?) ?? false;
      _goOn = (m['go'] as bool?) ?? false;
      _promoOn = (m['promo'] as bool?) ?? false;
      _pph = (m['pph'] as bool?) ?? false;
      if (_promoOn) _goOn = true; // Promo Iklan mengikuti ukuran Gratis Ongkir
      _tenor = (m['tenor'] as num?)?.toInt() ?? 3;
      final names = ((m['opts'] as List?) ?? const []).map((e) => '$e').toSet();
      _opts
        ..clear()
        ..addAll(KalkOpt.values.where((o) => names.contains(o.name)));
      _aff.text = (m['aff'] as String?) ?? '';
      _customs = [
        for (final e in (m['custom'] as List?) ?? const [])
          if (e is Map) CustomFee.fromJson(Map<String, dynamic>.from(e)),
      ];
      // Tab "Biaya tambahan": tampilkan yang sudah terisi (platform dulu), bukan tab kosong.
      final hasP = _customs.any((e) => !e.seller);
      final hasS = _customs.any((e) => e.seller);
      _customSeller = !hasP && hasS;
      // Harga jual terakhir untuk produk ini (auto-simpan).
      final pkk = widget.productKey;
      final sm = m['sells'];
      final am = m['autos'];
      final hasSell =
          pkk != null &&
          sm is Map &&
          sm[pkk] is String &&
          (sm[pkk] as String).isNotEmpty;
      if (pkk != null && am is Map && am[pkk] is String) {
        // Auto aktif untuk produk ini: ikuti tingkat saran yang terakhir dipilih.
        _autoTier = am[pkk] as String;
        _sellAuto = true;
        if (hasSell) _sell.text = sm[pkk] as String;
      } else if (hasSell) {
        _sell.text = sm[pkk] as String;
        _sellAuto = false;
      }
      _prefsLoaded = true;
      _restoreCat();
    });
  }

  void _restoreCat() {
    if (_cat != null || !_prefsLoaded || !_db.ready) return;
    final pk = widget.productKey;
    if (pk == null) return;
    final k = (_prefs['cats'] as Map?)?[pk];
    if (k is! String) return;
    for (final c in _db.categories) {
      if (c.key == k) {
        _cat = c;
        return;
      }
    }
  }

  void _savePrefs() {
    if (!_prefsLoaded) return;
    final sells = Map<String, dynamic>.from(
      (_prefs['sells'] as Map?) ?? const {},
    );
    final cats = Map<String, dynamic>.from(
      (_prefs['cats'] as Map?) ?? const {},
    );
    final autos = Map<String, dynamic>.from(
      (_prefs['autos'] as Map?) ?? const {},
    );
    final pk = widget.productKey;
    if (pk != null) {
      if (_sellAuto) {
        autos[pk] = _autoTier;
      } else {
        autos.remove(pk);
      }
    }
    if (pk != null) {
      if (_cat != null) {
        cats[pk] = _cat!.key;
      } else {
        cats.remove(pk);
      }
    }
    if (pk != null) {
      if (_sell.text.isNotEmpty) {
        sells[pk] = _sell.text;
      } else {
        sells.remove(pk);
      }
    }
    while (sells.length > 500) {
      sells.remove(sells.keys.first);
    }
    while (cats.length > 500) {
      cats.remove(cats.keys.first);
    }
    while (autos.length > 500) {
      autos.remove(autos.keys.first);
    }
    _prefs = {
      'mall': _mall,
      'khusus': _khusus,
      'go': _goOn,
      'promo': _promoOn,
      'pph': _pph,
      'tenor': _tenor,
      'aff': _aff.text,
      'custom': [for (final f in _customs) f.toJson()],
      'opts': [for (final o in _opts) o.name],
      'cats': cats,
      'sells': sells,
      'autos': autos,
    };
    unawaited(_KalkFiles.writePrefs(_prefs));
  }

  /// Auto-simpan (tertunda 0,5 dtk): harga jual, biaya lain, affiliasi, pilihan biaya.
  void _autoSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      _savePrefs();
      _saveStore();
    });
  }

  void _saveStore() => store.setCalc(store.calcAdmin, _num(_extra.text));

  /// Biaya proses pesanan SELALU mengikuti data biaya tertanam (tab "biaya wajib");
  /// user tidak bisa mengubahnya.
  FeeRate? get _procRate => _db.opt.proses;

  String get _procText {
    final r = _db.opt.proses;
    if (r == null) return 'Rp 0';
    final parts = <String>[
      if (r.pct > 0) _fmtPct(r.pct),
      if (r.flat > 0) _rp(r.flat).replaceFirst('Rp', 'Rp '),
    ];
    return parts.isEmpty ? 'Rp 0' : parts.join(' + ');
  }

  void _set(VoidCallback f) {
    setState(f);
    _savePrefs();
  }

  void _toggleOpt(KalkOpt o, bool v) => _set(() {
    if (v) {
      _opts.add(o);
      if (o == KalkOpt.promoXtra) _opts.remove(KalkOpt.promoXtraPlus);
      if (o == KalkOpt.promoXtraPlus) _opts.remove(KalkOpt.promoXtra);
    } else {
      _opts.remove(o);
    }
  });

  int get _effTenor {
    final t = _db.opt.spayLater;
    if (t.isEmpty || t.containsKey(_tenor)) return _tenor;
    return (t.keys.toList()..sort()).first;
  }

  _Cfg get _cfg => _Cfg(
    cat: _cat,
    procRate: _procRate,
    affPct: _pctIn(_aff.text),
    mall: _mall,
    khusus: _khusus,
    goOn: _goOn,
    promoOn: _promoOn,
    opts: _opts,
    tenor: _effTenor,
    pph: _pph,
    platform: [
      for (final f in _customs)
        if (!f.seller && f.on) f,
    ],
    seller: [
      for (final f in _customs)
        if (f.seller && f.on) f,
    ],
  );

  // ---------- potongan kecil ----------
  Widget _sec(String n, String t, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      children: [
        Container(
          width: 18,
          height: 18,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Text(
            n,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: accent,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            t.toUpperCase(),
            style: TextStyle(
              fontSize: 11.5,
              letterSpacing: 0.5,
              fontWeight: FontWeight.w700,
              color: cSub,
            ),
          ),
        ),
        if (trailing != null) trailing,
      ],
    ),
  );

  Widget _choice(String t, bool sel, VoidCallback f) => InkWell(
    borderRadius: BorderRadius.circular(6),
    onTap: f,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: sel ? accent.withValues(alpha: 0.10) : null,
        border: Border.all(color: sel ? accent : cLine, width: sel ? 1.5 : 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        t,
        style: TextStyle(
          fontSize: 12.5,
          color: sel ? accent : cText,
          fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
    ),
  );

  Widget _field(
    String label,
    TextEditingController c, {
    String? prefix,
    String? suffix,
    String? hint,
    bool decimal = false,
    VoidCallback? onEdit,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: cSub),
      ),
      const SizedBox(height: 4),
      SizedBox(
        height: 38,
        child: TextField(
          controller: c,
          onChanged: (_) {
            onEdit?.call();
            setState(() {});
          },
          keyboardType: TextInputType.numberWithOptions(decimal: decimal),
          inputFormatters: [
            FilteringTextInputFormatter.allow(
              RegExp(decimal ? r'[0-9.,]' : r'[0-9]'),
            ),
          ],
          style: TextStyle(fontSize: 14, color: cText),
          decoration: InputDecoration(
            isDense: true,
            prefixText: prefix,
            suffixText: suffix,
            hintText: hint,
            hintStyle: TextStyle(fontSize: 14, color: cMute),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 10,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: cLine),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: accent, width: 1.5),
            ),
          ),
        ),
      ),
    ],
  );

  /// Kolom hanya-baca (terkunci) — nilai dari Google Sheet, tidak bisa diketik.
  Widget _lockedField(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: cSub),
      ),
      const SizedBox(height: 4),
      MouseRegion(
        cursor: SystemMouseCursors.forbidden,
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: cSurface2,
            border: Border.all(color: cLine),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, color: cSub),
                ),
              ),
              Icon(CupertinoIcons.lock_fill, size: 14, color: cMute),
            ],
          ),
        ),
      ),
    ],
  );

  Widget _hint(String t, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            t,
            style: TextStyle(fontSize: 11, height: 1.25, color: cMute),
          ),
        ),
        if (trailing != null) trailing,
      ],
    ),
  );

  Widget _line(
    String k,
    String v, {
    String? sub,
    Color? color,
    bool bold = false,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(k, style: TextStyle(fontSize: 13, color: cSub)),
              if (sub != null)
                Text(
                  sub,
                  style: TextStyle(fontSize: 11.5, color: cMute, height: 1.25),
                ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Text(
          v,
          style: TextStyle(
            fontSize: bold ? 16 : 13.5,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
            color: color ?? cText,
          ),
        ),
      ],
    ),
  );

  // ---------- 1. kategori & admin ----------
  Widget _catBlock() {
    if (!_db.ready) {
      if (_db.loading) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Text(
                'Memuat data biaya admin…',
                style: TextStyle(fontSize: 12.5, color: cSub),
              ),
            ],
          ),
        );
      }
      return Row(
        children: [
          Expanded(
            child: Text(
              _db.error ?? 'Data biaya admin belum dimuat.',
              style: TextStyle(fontSize: 12.5, color: cSub, height: 1.35),
            ),
          ),
          TextButton(onPressed: _db.refresh, child: const Text('Coba lagi')),
        ],
      );
    }

    final cat = _cat;
    final children = <Widget>[];

    if (cat != null) {
      final pct = _mall ? (cat.adminMall ?? cat.admin) : cat.admin;
      final mallDiff =
          _mall && cat.mallName != null && cat.mallName != cat.name;
      children.add(
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.08),
            border: Border.all(color: accent.withValues(alpha: 0.35)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      cat.name,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: cText,
                      ),
                    ),
                    if (cat.group.isNotEmpty)
                      Text(
                        cat.group,
                        style: TextStyle(fontSize: 11.5, color: cMute),
                      ),
                    const SizedBox(height: 2),
                    Text(
                      '${_mall ? 'Mall' : 'Admin'} ${_fmtPct(pct)}'
                      '${cat.kode.isEmpty ? '' : ' · Kode ${cat.kode}'}'
                      '${cat.code.isEmpty ? '' : ' · ID kategori ${cat.code}'}'
                      '${mallDiff ? '\nNama di tab Mall: ${cat.mallName}' : ''}'
                      '${_mall && cat.adminMall == null ? '\nData Mall untuk kategori ini tidak ditemukan — memakai tarif Non-Star.' : ''}',
                      style: TextStyle(fontSize: 12, color: cSub, height: 1.35),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Ganti kategori',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.close, size: 18, color: cSub),
                onPressed: () {
                  _set(() => _cat = null);
                  _qFocus.requestFocus();
                },
              ),
            ],
          ),
        ),
      );
    } else {
      final results = _db.search(_q.text);
      children.add(
        SizedBox(
          height: 38,
          child: TextField(
            controller: _q,
            focusNode: _qFocus,
            onChanged: (_) => setState(() {}),
            style: TextStyle(fontSize: 13.5, color: cText),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Cari kategori produk (mis. "Sepatu bayi")',
              hintStyle: TextStyle(fontSize: 13, color: cMute),
              prefixIcon: Icon(CupertinoIcons.search, size: 16, color: cSub),
              prefixIconConstraints: const BoxConstraints(minWidth: 34),
              suffixIcon: _q.text.isEmpty
                  ? null
                  : IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.close, size: 16, color: cSub),
                      onPressed: () => setState(_q.clear),
                    ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: cLine),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: accent, width: 1.5),
              ),
            ),
          ),
        ),
      );
      if (_q.text.trim().isNotEmpty) {
        children.add(const SizedBox(height: 6));
        children.add(
          Container(
            constraints: const BoxConstraints(maxHeight: 250),
            decoration: BoxDecoration(
              color: cSurface,
              border: Border.all(color: cLine),
              borderRadius: BorderRadius.circular(8),
            ),
            child: results.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'Kategori tidak ditemukan.',
                      style: TextStyle(fontSize: 12.5, color: cSub),
                    ),
                  )
                : ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [
                      for (final c in results)
                        InkWell(
                          onTap: () {
                            _q.clear();
                            _qFocus.unfocus();
                            _set(() => _cat = c);
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        c.name,
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: cText,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      if (c.group.isNotEmpty)
                                        Text(
                                          c.group,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: cMute,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '${_fmtPct(_mall ? (c.adminMall ?? c.admin) : c.admin)}'
                                  '${c.code.isEmpty ? '' : ' · ID ${c.code}'}',
                                  style: TextStyle(fontSize: 12, color: cSub),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        );
      }
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'Pilih kategori produk untuk menghitung biaya admin.',
            style: TextStyle(fontSize: 12, color: cMute),
          ),
        ),
      );
    }

    children.add(
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          'Data biaya bawaan aplikasi · ${_db.categories.length} kategori',
          style: TextStyle(fontSize: 11, color: cMute),
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  // ---------- 2. program & biaya tambahan (tombol dengan rincian) ----------
  String _rateSub(FeeRate r) {
    if (r.pct == 0 && r.flat > 0) return _rp(r.flat);
    final p = _fmtPct(r.pct);
    return r.cap == null ? p : '$p • maks ${_rp(r.cap!)}';
  }

  Widget _tile({
    required String title,
    required String sub,
    required bool on,
    double? amount,
    VoidCallback? onTap,
    Color tone = _kShopeeOrange,
    _TileTip? tip,
  }) {
    final tile = Opacity(
      opacity: onTap != null ? 1 : 0.5,
      child: Material(
        color: on ? tone.withValues(alpha: 0.10) : cSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: on ? tone : cLine, width: on ? 1.5 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              children: [
                on
                    ? Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          color: tone,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.check,
                          size: 12,
                          color: Colors.white,
                        ),
                      )
                    : Icon(Icons.add, size: 18, color: cSub),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.25,
                          fontWeight: FontWeight.w600,
                          color: cText,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        sub,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.25,
                          color: on ? tone : cSub,
                        ),
                      ),
                    ],
                  ),
                ),
                if (on && amount != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Text(
                      '-${_rp(amount)}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: tone,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (tip == null) return tile;
    return _IosTip(
      title: title,
      subtitle: tip.group,
      sections: [
        MapEntry('Apa ini?', tip.what),
        MapEntry('Pilih jika', tip.when),
      ],
      rowsTitle: 'DATA SAAT INI',
      rows: tip.rows,
      message:
          'Ketentuan program bisa berubah. Cek "Pengelolaan Program Saya" di Seller Centre.',
      delay: const Duration(milliseconds: 450),
      child: tile,
    );
  }

  /// Isi tooltip tiap program (muncul saat kursor diarahkan / ditekan lama).
  _TileTip _tipOf(String key, {FeeRate? r, String group = 'Program Opsional'}) {
    final t = _kTipTexts[key]!;
    return _TileTip(group, t.$1, t.$2, [
      if (_cat != null) MapEntry('Kategori Aktif', _cat!.name),
      if (r != null) MapEntry('Tarif', _rateSub(r)),
    ]);
  }

  /// Tombol disusun 2 kolom; bila jumlahnya ganjil, yang terakhir selebar penuh.
  Widget _grid(List<Widget> t) {
    final rows = <Widget>[];
    for (var i = 0; i < t.length; i += 2) {
      final single = i == t.length - 1;
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: t[i]),
              if (!single) ...[
                const SizedBox(width: 8),
                Expanded(child: t[i + 1]),
              ],
            ],
          ),
        ),
      );
      if (i + 2 < t.length) rows.add(const SizedBox(height: 8));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }

  Widget _cap(String t, {bool first = false, Widget? trailing}) => Padding(
    padding: EdgeInsets.only(top: first ? 0 : 12, bottom: 6),
    child: Row(
      children: [
        Text(
          t.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 0.5,
            fontWeight: FontWeight.w700,
            color: cMute,
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 2), trailing],
      ],
    ),
  );

  Widget _programGrid(double sell, double price) {
    final cat = _cat;
    final reduced =
        _opts.contains(KalkOpt.promoXtra) ||
        _opts.contains(KalkOpt.promoXtraPlus);
    double? amt(FeeRate? r) => (r == null || sell <= 0) ? null : r.of(sell);

    // --- Gratis Ongkir XTRA: pilih ukuran Biasa / Khusus (tarif ikut kategori) ---
    Widget go(bool khusus) {
      final r = cat == null ? null : (khusus ? cat.goKhusus : cat.goBiasa);
      final on = _goOn && _khusus == khusus;
      final replaced = on && _promoOn;
      return _tile(
        title: 'Gratis Ongkir XTRA · Ukuran ${khusus ? 'Khusus' : 'Biasa'}',
        sub: cat == null
            ? 'Pilih kategori dulu'
            : replaced
            ? 'Diganti tarif Promo Iklan'
            : (r == null ? 'Tarif tidak ada di data biaya' : _rateSub(r)),
        on: on,
        amount: replaced ? null : amt(r),
        tip: _tipOf(
          khusus ? 'go_khusus' : 'go_biasa',
          r: r,
          group: 'Program Layanan / Pengiriman',
        ),
        onTap: (cat == null || (r == null && !on))
            ? null
            : () => _set(() {
                if (on) {
                  _goOn = false;
                  _promoOn =
                      false; // tanpa Gratis Ongkir, Promo Iklan ikut mati
                } else {
                  _goOn = true;
                  _khusus = khusus;
                }
              }),
      );
    }

    // --- Promo Iklan: tanpa pilihan ukuran sendiri; ikut ukuran Gratis Ongkir ---
    final pr = cat == null ? null : _db.promo[cat.code];
    final pr0 = pr == null ? null : (_khusus ? pr.khusus : pr.biasa);
    final goR = cat == null ? null : (_khusus ? cat.goKhusus : cat.goBiasa);
    final size = _khusus ? 'Khusus' : 'Biasa';
    final promoOn = _promoOn && _goOn;
    final promoTile = _tile(
      title: 'Promo Iklan',
      sub: cat == null
          ? 'Pilih kategori dulu'
          : !_goOn
          ? 'Pilih ukuran Gratis Ongkir XTRA dulu'
          : (pr0 == null
                ? (cat.code.isEmpty
                      ? 'ID kategori kosong (kolom H tab gratis ongkir)'
                      : 'ID kategori ${cat.code} tidak ada di tab promo iklan')
                : 'Kategori ${cat.code} · ukuran $size\n${_rateSub(pr0)}'
                      '${goR == null ? '' : ' · menggantikan Gratis Ongkir ${_fmtPct(goR.pct)}'}'),
      on: promoOn,
      amount: amt(pr0),
      tip: _tipOf('promo_iklan', r: pr0, group: 'Program Layanan / Pengiriman'),
      onTap: (cat == null || !_goOn || (pr0 == null && !promoOn))
          ? null
          : () => _set(() => _promoOn = !promoOn),
    );

    // --- Program opsional ---
    Widget optTile(KalkOpt o) {
      final r = _db.opt.rate(o, tenor: _effTenor, reducedVideo: reduced);
      final on = _opts.contains(o);
      var sub = r == null ? 'Tarif tidak ada di data biaya' : _rateSub(r);
      if (o == KalkOpt.video &&
          _db.opt.videoReduced != null &&
          _db.opt.video != null) {
        sub += reduced
            ? '\nTurun dari ${_fmtPct(_db.opt.video!.pct)} karena Promo XTRA aktif'
            : '\nJadi ${_fmtPct(_db.opt.videoReduced!.pct)} bila Promo XTRA aktif';
      }
      return _tile(
        title: o.title,
        sub: sub,
        on: on,
        amount: amt(r),
        tip: _tipOf(o.name, r: r),
        onTap: (r == null && !on) ? null : () => _toggleOpt(o, !on),
      );
    }

    final tenors = _db.opt.spayLater.keys.toList()..sort();
    Widget spayTile(int t) {
      final r = FeeRate(_db.opt.spayLater[t]!);
      final on = _opts.contains(KalkOpt.spayLater) && _effTenor == t;
      return _tile(
        title: 'SPayLater XTRA $t Bulan',
        sub: _rateSub(r),
        on: on,
        amount: amt(r),
        tip: _tipOf('spayLater', r: r),
        onTap: () => _set(() {
          if (on) {
            _opts.remove(KalkOpt.spayLater);
          } else {
            _opts.add(KalkOpt.spayLater);
            _tenor = t;
          }
        }),
      );
    }

    final optTiles = <Widget>[];
    for (final o in KalkOpt.values) {
      if (o == KalkOpt.spayLater && tenors.isNotEmpty) {
        for (final t in tenors) {
          optTiles.add(spayTile(t));
        }
      } else {
        optTiles.add(optTile(o));
      }
    }

    // --- Pajak ---
    final pph = _db.opt.pph22;
    final pajak = _tile(
      title: 'Pajak PPh 22',
      sub: pph == null
          ? 'Tarif tidak ada di data biaya'
          : '${_rateSub(pph)} dari harga jual',
      on: _pph,
      amount: amt(pph),
      tip: _tipOf('pph', r: pph, group: 'Pajak'),
      onTap: (pph == null && !_pph) ? null : () => _set(() => _pph = !_pph),
      tone: _kPphRed,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _cap(
          'Ongkir & iklan',
          first: true,
          trailing: const _IosTip(
            title: 'Gratis Ongkir & Promo Iklan',
            message:
                'Pilih ukuran Gratis Ongkir XTRA (Biasa atau Khusus). Tarifnya mengikuti '
                'kategori produk di langkah 1.\n\n'
                'Promo Iklan tidak punya pilihan ukuran sendiri. Jika diaktifkan, tarif Promo '
                'Iklan pada ID kategori yang sama menggantikan tarif Gratis Ongkir XTRA '
                'dengan ukuran yang sama.',
          ),
        ),
        _grid([go(false), go(true), promoTile]),
        _cap('Program opsional'),
        _grid(optTiles),
        _cap('Pajak'),
        _grid([pajak]),
        _customSection(sell, price),
      ],
    );
  }

  // ---------- biaya tambahan kustom (tab: platform / seller) ----------
  String _customSub(CustomFee f) {
    if (!f.pct) return _rp(f.value);
    final p = _fmtPct(f.value);
    return f.cap == null ? p : '$p • maks ${_rp(f.cap!)}';
  }

  Widget _customSection(double net, double price) {
    final seller = _customSeller;
    final items = [
      for (final f in _customs)
        if (f.seller == seller) f,
    ];

    Widget item(CustomFee f) {
      final base = seller ? price : net;
      final amt = base > 0 ? min(f.rate.of(base), base) : null;
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: f.on ? accent.withValues(alpha: 0.10) : cSurface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(
              color: f.on ? accent : cLine,
              width: f.on ? 1.5 : 1,
            ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _set(() => f.on = !f.on),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 2, 4),
              child: Row(
                children: [
                  f.on
                      ? Container(
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                            color: accent,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.check,
                            size: 12,
                            color: Colors.white,
                          ),
                        )
                      : Icon(Icons.add, size: 18, color: cSub),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            f.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: cText,
                            ),
                          ),
                          Text(
                            _customSub(f),
                            style: TextStyle(
                              fontSize: 11.5,
                              color: f.on ? accent : cSub,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (f.on && amt != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 6, right: 2),
                      child: Text(
                        '-${_rp(amt)}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: accent,
                        ),
                      ),
                    ),
                  IconButton(
                    tooltip: 'Ubah',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 30,
                      minHeight: 30,
                    ),
                    icon: Icon(CupertinoIcons.pencil, size: 16, color: cSub),
                    onPressed: () => _editCustom(f),
                  ),
                  IconButton(
                    tooltip: 'Hapus',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 30,
                      minHeight: 30,
                    ),
                    icon: Icon(CupertinoIcons.trash, size: 16, color: cSub),
                    onPressed: () =>
                        _set(() => _customs.removeWhere((e) => e.id == f.id)),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _cap('Biaya tambahan'),
        _SegControl(
          labels: const ['Biaya platform', 'Biaya seller'],
          index: seller ? 1 : 0,
          onChanged: (i) => setState(() => _customSeller = i == 1),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 8),
          child: Text(
            seller
                ? 'Voucher, subsidi, atau diskon dari seller. Masuk ke "Voucher & Subsidi" '
                      'dan mengurangi harga jual.'
                : 'Biaya dari platform di luar daftar di atas. Masuk ke "Biaya Layanan" '
                      'dan dihitung dari harga setelah diskon seller.',
            style: TextStyle(fontSize: 11.5, height: 1.3, color: cMute),
          ),
        ),
        for (final f in items) item(f),
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => _editCustom(),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              border: Border.all(color: cLine),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(CupertinoIcons.add_circled, size: 16, color: accent),
                const SizedBox(width: 6),
                Text(
                  'Tambah biaya ${seller ? 'seller' : 'platform'}',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: accent,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Dialog tambah / ubah biaya kustom (nilai dalam % + maksimal, atau Rp).
  Future<void> _editCustom([CustomFee? f]) async {
    final name = TextEditingController(text: f?.name ?? '');
    final val = TextEditingController(text: f == null ? '' : _numText(f.value));
    final cap = TextEditingController(
      text: f?.cap == null ? '' : _numText(f!.cap!),
    );
    var pct = f?.pct ?? true;
    var seller = f?.seller ?? _customSeller;

    final res = await showDialog<CustomFee>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) {
          final v = double.tryParse(val.text.replaceAll(',', '.')) ?? 0;
          final cp = int.tryParse(cap.text.replaceAll(RegExp(r'[^0-9]'), ''));
          final ok = name.text.trim().isNotEmpty && v > 0 && (!pct || v <= 100);

          Widget label(String t) => Padding(
            padding: const EdgeInsets.only(bottom: 4, top: 12),
            child: Text(t, style: TextStyle(fontSize: 12, color: cSub)),
          );
          Widget box(
            TextEditingController c, {
            String? prefix,
            String? suffix,
            String? hint,
            bool dec = false,
            bool text = false,
          }) => SizedBox(
            height: 38,
            child: TextField(
              controller: c,
              onChanged: (_) => set(() {}),
              keyboardType: text
                  ? TextInputType.text
                  : TextInputType.numberWithOptions(decimal: dec),
              inputFormatters: text
                  ? null
                  : [
                      FilteringTextInputFormatter.allow(
                        RegExp(dec ? r'[0-9.,]' : r'[0-9]'),
                      ),
                    ],
              style: TextStyle(fontSize: 14, color: cText),
              decoration: InputDecoration(
                isDense: true,
                prefixText: prefix,
                suffixText: suffix,
                hintText: hint,
                hintStyle: TextStyle(fontSize: 14, color: cMute),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 10,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: cLine),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: accent, width: 1.5),
                ),
              ),
            ),
          );

          return Dialog(
            backgroundColor: cSurface,
            insetPadding: const EdgeInsets.all(20),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      f == null ? 'Tambah biaya' : 'Ubah biaya',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                        color: cText,
                      ),
                    ),
                    label('Nama biaya'),
                    box(name, hint: 'mis. Voucher toko', text: true),
                    label('Kelompok'),
                    _SegControl(
                      labels: const ['Biaya platform', 'Biaya seller'],
                      index: seller ? 1 : 0,
                      onChanged: (i) => set(() => seller = i == 1),
                    ),
                    label('Jenis nilai'),
                    _SegControl(
                      labels: const ['Persen (%)', 'Rupiah (Rp)'],
                      index: pct ? 0 : 1,
                      onChanged: (i) => set(() => pct = i == 0),
                    ),
                    label(pct ? 'Nilai (%)' : 'Nilai (Rp)'),
                    box(
                      val,
                      prefix: pct ? null : 'Rp ',
                      suffix: pct ? '%' : null,
                      dec: pct,
                      hint: '0',
                    ),
                    if (pct) ...[
                      label('Biaya maksimal (opsional)'),
                      box(cap, prefix: 'Rp ', hint: 'Tanpa batas'),
                    ],
                    const SizedBox(height: 18),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Batal'),
                        ),
                        const SizedBox(width: 6),
                        FilledButton(
                          onPressed: !ok
                              ? null
                              : () => Navigator.pop(
                                  ctx,
                                  CustomFee(
                                    id:
                                        f?.id ??
                                        '${DateTime.now().microsecondsSinceEpoch}',
                                    name: name.text.trim(),
                                    seller: seller,
                                    pct: pct,
                                    value: v,
                                    cap: (pct && cp != null && cp > 0)
                                        ? cp.toDouble()
                                        : null,
                                    on: f?.on ?? true,
                                  ),
                                ),
                          child: const Text('Simpan'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );

    // controller dilepas setelah animasi tutup dialog selesai
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      name.dispose();
      val.dispose();
      cap.dispose();
    });
    if (res == null || !mounted) return;
    _set(() {
      final i = _customs.indexWhere((e) => e.id == res.id);
      if (i >= 0) {
        _customs[i] = res;
      } else {
        _customs.add(res);
      }
      _customSeller = res.seller;
    });
  }

  // ---------- rincian penghasilan (kartu per bagian, gaya aplikasi Shopee/iOS) ----------
  Widget _breakdownCard({
    required double sell,
    required double net,
    required List<FeeLine> discLines,
    required List<FeeLine> lines,
    required double extra,
    required double modal,
    required double profit,
    required Color profitColor,
    required Color good,
    required Color bad,
  }) {
    final fees = _sumFees(lines);
    final cut = fees + extra;
    final disc = _sumFees(discLines);
    final income = net - cut; // dana yang diterima seller (sebelum modal)

    String sp(num v) => _rp(v).replaceFirst('Rp', 'Rp ');
    final base = net > 0 ? net : sell;
    String pctOf(double v) => _fmtPct(v * 100 / base);
    final modalName = (_useDs || widget.grosir == null) ? 'dropship' : 'grosir';

    const order = [_gPlatform, _gGo, _gPromo, _gLayanan, _gPajak];
    final groups = <String, List<FeeLine>>{};
    for (final l in lines) {
      (groups[l.group] ??= []).add(l);
    }
    final names = [
      ...order.where(groups.containsKey),
      ...groups.keys.where((k) => !order.contains(k)),
    ];

    Widget box(List<Widget> children) => Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: cSurface,
        border: Border.all(color: cLine),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );

    Widget line() => Divider(height: 1, thickness: 1, color: cLine);

    /// Baris judul kartu: nama bagian (kiri) + total (kanan).
    Widget head(
      String t,
      String v, {
      Color? color,
      Color? bg,
      Color? labelColor,
    }) => Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              t,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w800,
                color: labelColor ?? color ?? cText,
              ),
            ),
          ),
          Text(
            v,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: color ?? cText,
            ),
          ),
        ],
      ),
    );

    /// Baris isi: nama + tarif kecil + ikon bantuan (ⓘ → penjelasan) | nominal.
    Widget row(
      String k,
      String v, {
      String? tag,
      String? help,
      String? helpTitle,
      String? helpSub,
      List<MapEntry<String, String>>? details,
      Color? helpColor,
      Color? vColor,
      bool bold = false,
    }) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              children: [
                Text(
                  k,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
                    color: bold ? cText : cSub,
                  ),
                ),
                if (tag != null)
                  Text(
                    tag.startsWith('Rp') ? tag.replaceFirst('Rp', 'Rp ') : tag,
                    style: TextStyle(fontSize: 11.5, color: cMute),
                  ),
                if (help != null)
                  _IosTip(
                    title: helpTitle ?? k,
                    message: help,
                    subtitle: helpSub ?? 'Rincian Penghasilan',
                    rows: details ?? [MapEntry('Nominal', v)],
                    icon: CupertinoIcons.question_circle,
                    size: 15,
                    pad: 3,
                    color: helpColor ?? accent,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            v,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: vColor ?? (bold ? cText : cSub),
            ),
          ),
        ],
      ),
    );

    Widget feeRow(FeeLine l) {
      final r = l.rate;
      final isGo = l.group == _gGo;
      return row(
        l.label,
        '-${sp(l.amount)}',
        tag: l.tag,
        helpTitle: isGo ? 'Gratis Ongkir XTRA · ${l.label}' : null,
        helpSub: l.group,
        helpColor: l.promo ? accent : null,
        details: [
          if (_cat != null) MapEntry('Kategori Aktif', _cat!.name),
          MapEntry(
            'Program Aktif',
            isGo
                ? '${l.promo ? 'Promo Iklan' : 'Gratis Ongkir XTRA'} · ${l.label}'
                : l.label,
          ),
          if (r != null && r.pct > 0) MapEntry('Persentase', _fmtPct(r.pct)),
          if (r != null && r.flat > 0) MapEntry('Biaya Tetap', sp(r.flat)),
          if (r?.cap != null) MapEntry('Batas Maksimal', sp(r!.cap!)),
          MapEntry('Perhitungan', sp(l.amount)),
        ],
        help: '${l.note ?? ''} (${pctOf(l.amount)} dari harga jual).',
      );
    }

    List<Widget> rows(List<Widget> r) => [
      for (final w in r) ...[line(), w],
    ];

    // ----- kartu paling atas: dana akan diterima -----
    final profitPill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: profitColor.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        profit >= 0 ? 'Profit +${sp(profit)}' : 'Rugi ${sp(profit)}',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: profitColor,
        ),
      ),
    );

    final top = box([
      Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'DANA AKAN DITERIMA',
              style: TextStyle(fontSize: 11, letterSpacing: 0.4, color: cSub),
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      sp(income),
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.5,
                        color: cText,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                profitPill,
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Estimasi dana masuk seller setelah potongan platform',
              style: TextStyle(fontSize: 11.5, color: cSub),
            ),
          ],
        ),
      ),
    ]);

    // ----- total pesanan -----
    final orderBox = box([
      head('Total Pesanan', sp(net)),
      line(),
      Container(
        margin: const EdgeInsets.fromLTRB(10, 8, 10, 2),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: isDark ? 0.16 : 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 18,
              height: 18,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: Color(0xFFFF9800),
                shape: BoxShape.circle,
              ),
              child: const Text(
                '!',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Hasil kalkulasi mengikuti ketentuan biaya platform yang berlaku, dan '
                'kebijakan tersebut dapat berubah sewaktu-waktu. Pastikan data tarif '
                'selalu diperbarui.',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.35,
                  color: isDark
                      ? Colors.orange.shade200
                      : const Color(0xFF7A4A12),
                ),
              ),
            ),
          ],
        ),
      ),
      row('Harga Jual Pembeli', sp(sell), bold: true),
      if (disc > 0)
        ...rows([row('Harga Setelah Diskon Seller', sp(net), bold: true)]),
    ]);

    // ----- voucher & subsidi (biaya seller: mengurangi harga jual) -----
    final discBox = discLines.isEmpty
        ? const SizedBox.shrink()
        : box([
            head(
              'Voucher & Subsidi',
              '-${sp(disc)}',
              color: bad,
              labelColor: cText,
            ),
            ...rows([
              for (final l in discLines)
                row(
                  l.label,
                  '-${sp(l.amount)}',
                  tag: l.tag,
                  help:
                      '${l.note ?? ''}\n\nNominal: -${sp(l.amount)} '
                      '(${_fmtPct(l.amount * 100 / sell)} dari harga jual).',
                ),
            ]),
          ]);

    // ----- kartu biaya per bagian -----
    final feeBoxes = [
      for (final n in names)
        box([
          head(
            n,
            '-${sp(_sumFees(groups[n]!))}',
            color: bad,
            labelColor: cText,
          ),
          ...rows([for (final l in groups[n]!) feeRow(l)]),
        ]),
    ];

    final otherBox = extra > 0
        ? box([
            head('Biaya Lain', '-${sp(extra)}', color: bad, labelColor: cText),
            ...rows([
              row(
                'Biaya lain per pcs',
                '-${sp(extra)}',
                help:
                    'Biaya tambahan yang Anda isi sendiri, mis. kemasan atau ongkos lain. '
                    '(${pctOf(extra)} dari harga jual)',
              ),
            ]),
          ])
        : const SizedBox.shrink();

    // ----- ringkasan & hasil akhir -----
    final tint = good.withValues(alpha: 0.12);
    final summary = box([
      head('Ringkasan Penghasilan', sp(income), color: good, bg: tint),
      ...rows([
        row('Total Biaya Platform', '-${sp(fees)}', vColor: bad),
        if (extra > 0) row('Biaya Lain', '-${sp(extra)}', vColor: bad),
        row(
          'Omset',
          sp(income),
          bold: true,
          help:
              'Dana yang masuk ke seller: harga jual dikurangi semua biaya platform '
              'dan biaya lain. Belum dikurangi modal.',
        ),
      ]),
    ]);

    final result = box([
      head(
        'Hasil Akhir',
        'Margin ${_fmtPct(profit * 100 / sell)}',
        color: good,
        bg: tint,
      ),
      line(),
      row(
        'Modal / HPP',
        '-${sp(modal)}',
        vColor: bad,
        help: 'Harga $modalName per pcs.',
      ),
      Container(
        margin: const EdgeInsets.fromLTRB(8, 2, 8, 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: profitColor.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Profit Bersih Estimasi',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: profitColor,
                ),
              ),
            ),
            Text(
              sp(profit),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: profitColor,
              ),
            ),
          ],
        ),
      ),
    ]);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        top,
        orderBox,
        discBox,
        ...feeBoxes,
        otherBox,
        summary,
        result,
      ],
    );
  }

  /// Harga tingkat saran [name] (Impas / Tipis / Sedang / Tinggi), dibulatkan seperti
  /// kartu Saran Harga Jual. null bila tidak tercapai dengan biaya yang aktif.
  double? _tierPrice(
    String name,
    double modal,
    double extra,
    _Cfg cfg,
    double? minSell,
  ) {
    if (name == 'Impas') return minSell?.ceilToDouble();
    final p = _profileOf(cfg.cat);
    final m = name == 'Tipis'
        ? p.tipis
        : (name == 'Sedang' ? p.sedang : p.tinggi);
    final raw = _sellForMargin(modal, extra, cfg, m);
    return raw == null ? null : (raw / 100).ceil() * 100.0;
  }

  // ---------- saran harga jual (harga cepat) ----------
  Widget _priceSuggestions({
    required double modal,
    required double extra,
    required _Cfg cfg,
    required double sell,
    required double? minSell,
  }) {
    final prof = _profileOf(cfg.cat);
    double roundUp(double v) => (v / 100).ceil() * 100.0;

    _PriceTier? tier(String name, double? raw, {bool exact = false}) {
      if (raw == null) return null;
      final price = exact ? raw.ceilToDouble() : roundUp(raw);
      final pf = _profitAt(price, modal, extra, cfg);
      return _PriceTier(name, price, pf, price > 0 ? pf * 100 / price : 0);
    }

    final tiers = <_PriceTier>[];
    void add(_PriceTier? t) {
      if (t != null) tiers.add(t);
    }

    add(tier('Impas', minSell, exact: true));
    add(tier('Tipis', _sellForMargin(modal, extra, cfg, prof.tipis)));
    add(tier('Sedang', _sellForMargin(modal, extra, cfg, prof.sedang)));
    add(tier('Tinggi', _sellForMargin(modal, extra, cfg, prof.tinggi)));
    if (tiers.isEmpty) return const SizedBox.shrink();

    final cname = cfg.cat?.name;
    Widget row(int i) {
      final t = tiers[i];
      final on = _sellAuto && t.name == _autoTier; // tingkat Auto yang aktif
      final c = t.name == 'Impas' ? cSub : accent;
      return InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () {
          setState(() {
            if (on) {
              _sellAuto =
                  false; // ketuk lagi tingkat yang aktif -> Auto mati, harga tetap
            } else {
              _autoTier = t.name;
              _sellAuto = true;
              _sell.text = '${t.price.round()}';
            }
          });
          _autoSave();
        },
        child: Container(
          margin: const EdgeInsets.only(top: 6),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: on ? c.withValues(alpha: 0.10) : null,
            border: Border.all(color: on ? c : cLine, width: on ? 1.2 : 1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.name,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: cText,
                      ),
                    ),
                    Text(
                      t.name == 'Impas'
                          ? 'balik modal, belum untung'
                          : 'untung ${_rp(t.profit)} · margin ${_fmtPct(t.margin)}',
                      style: TextStyle(fontSize: 11, color: cMute),
                    ),
                  ],
                ),
              ),
              Text(
                _rp(t.price),
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                  color: on ? c : cText,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: cSurface,
        border: Border.all(color: cLine),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Text(
                      'SARAN HARGA JUAL',
                      style: TextStyle(
                        fontSize: 11.5,
                        letterSpacing: 0.5,
                        fontWeight: FontWeight.w700,
                        color: cSub,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: (_sellAuto ? accent : cMute).withValues(
                          alpha: 0.14,
                        ),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        _sellAuto ? 'AUTO · $_autoTier' : 'MANUAL',
                        style: TextStyle(
                          fontSize: 9.5,
                          letterSpacing: 0.4,
                          fontWeight: FontWeight.w700,
                          color: _sellAuto ? accent : cSub,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              _IosTip(
                title: 'Saran harga jual',
                message:
                    'Harga dihitung dari modal, biaya platform, program, dan pajak yang aktif '
                    'sekarang, lalu dibulatkan ke atas per Rp100.\n\n'
                    'Target margin menyesuaikan jenis kategori: '
                    '${_fmtPct(prof.tipis)} / ${_fmtPct(prof.sedang)} / ${_fmtPct(prof.tinggi)} '
                    'untuk Tipis / Sedang / Tinggi (${prof.label.toLowerCase()}). '
                    'Barang seperti fashion bermargin lebih tebal, sedangkan alat tulis atau '
                    'elektronik jauh lebih tipis.\n\nAUTO: harga jual mengikuti tingkat yang dipilih setiap '
                    'kategori atau program berubah. Ketik harga sendiri, atau ketuk lagi tingkat '
                    'yang aktif, untuk mematikan Auto.',
                size: 15,
                pad: 2,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              cname == null
                  ? 'Pilih kategori agar target margin pas · ketuk untuk Auto'
                  : '${prof.label} · $cname · ketuk untuk Auto, ketuk lagi untuk mematikan',
              style: TextStyle(fontSize: 11, color: cMute),
            ),
          ),
          for (var i = 0; i < tiers.length; i++) row(i),
        ],
      ),
    );
  }

  // ---------- gerbang kategori: halaman 2-4 buram sampai kategori dipilih ----------
  void _askCategory() {
    showCupertinoDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Pilih kategori dulu'),
        content: const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text(
            'Silakan pilih kategori produk yang sesuai pada "Biaya admin (wajib)" '
            'terlebih dahulu. Program, hasil, dan analisis iklan akan terbuka setelah itu.',
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Nanti'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () {
              Navigator.pop(ctx);
              _qFocus.requestFocus();
            },
            child: const Text('Pilih kategori'),
          ),
        ],
      ),
    );
  }

  void _notice(String title, String msg) {
    showCupertinoDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text(title),
        content: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(msg),
        ),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  final _affKey = GlobalKey(); // posisi tombol Affiliasi (tempat popover menempel)

  /// Tombol Affiliasi: simulasi komisi affiliator per tier terhadap laba produk ini.
  void _openAffiliate(
    double sell,
    double net,
    double? modal,
    double extra,
    _Cfg cfg,
  ) {
    if (_cat == null) return _askCategory();
    if (modal == null || sell <= 0) {
      return _notice(
        'Isi harga jual dulu',
        'Simulasi affiliasi membutuhkan modal dan harga jual untuk menghitung profit.',
      );
    }
    final start = _pctIn(_aff.text);
    // Popover menempel di tombol Affiliasi (bukan dialog di tengah layar).
    final box = _affKey.currentContext?.findRenderObject() as RenderBox?;
    final anchor = (box != null && box.hasSize)
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
    showGeneralDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: true,
      barrierLabel: 'Tutup',
      barrierColor: Colors.transparent,
      transitionDuration: Duration.zero,
      pageBuilder: (_, __, ___) => _AffiliateSheet(
        sell: sell,
        net: net,
        modal: modal,
        extra: extra,
        cfg: cfg,
        initialPct: start > 0 ? start : 10,
        anchor: anchor,
      ),
    );
  }

  Widget _gate(Widget child, {required bool locked}) {
    if (!locked) return child;
    return Stack(
      children: [
        child,
        Positioned.fill(
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _askCategory,
              child: ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: 1.5,
                    sigmaY: 1.5,
                    tileMode: TileMode.decal,
                  ),
                  child: Container(color: cSurface.withValues(alpha: 0.25)),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ---------- build ----------
  @override
  Widget build(BuildContext context) {
    final modal = (_useDs ? widget.ds : widget.grosir)?.toDouble();
    final sell = _num(_sell.text).toDouble();
    final extra = _num(_extra.text).toDouble();
    final cfg = _cfg;
    final sellerLines = _sellerLines(sell, cfg);
    final net = max(
      sell - _sumFees(sellerLines),
      0.0,
    ); // harga setelah diskon seller
    final lines = _computeFees(net, cfg);
    final total = _sumFees(lines);
    final profit = modal == null ? null : net - total - extra - modal;
    final margin = (profit != null && sell > 0) ? profit * 100 / sell : null;
    final profitV = profit ?? 0.0;
    final marginV = margin ?? 0.0;
    final minSell = modal == null ? null : _minSell(modal, extra, cfg);
    final good = isDark ? Colors.green.shade300 : Colors.green.shade700;
    final bad = isDark ? Colors.red.shade300 : Colors.red.shade600;
    final profitColor = sell > 0 ? (profitV >= 0 ? good : bad) : cMute;

    // Auto: harga jual selalu mengikuti tingkat saran yang aktif (bawaan Tinggi) setiap
    // kategori / program / biaya berubah. Mati bila user mengetik harga sendiri atau
    // mengetuk lagi tingkat yang aktif. Cadangan bila tingkat tak tercapai: Impas.
    final defSell = (_sellAuto && _prefsLoaded && _db.ready && modal != null)
        ? (_tierPrice(_autoTier, modal, extra, cfg, minSell) ?? minSell)
        : null;
    if (defSell != null) {
      final t = defSell.ceil().toString();
      if (_sell.text != t) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _sellAuto && _sell.text != t)
            setState(() => _sell.text = t);
        });
      }
    }

    final locked =
        _prefsLoaded && _db.ready && _cat == null; // kategori belum dipilih

    final scr = MediaQuery.sizeOf(context);
    final wide4 =
        scr.width >= 1480; // 4 kolom: input · program · analisis ROAS · hasil
    final wide3 =
        scr.width >= 1180; // 3 kolom: input · program · (analisis ROAS + hasil)
    final wide2 = scr.width >= 760; // 2 kolom: input · (analisis ROAS + hasil)
    final full = _full; // layar penuh: dialog memenuhi seluruh layar
    final dw = full ? scr.width : min(scr.width - 24, wide4 ? 1700.0 : 1240.0);
    final dh = full ? scr.height : min(scr.height - 24, 820.0);

    // ----- kolom input -----
    final inputsA = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.grosir != null || widget.ds != null)
          Row(
            children: [
              Text('Modal:', style: TextStyle(fontSize: 12.5, color: cSub)),
              const SizedBox(width: 8),
              if (widget.grosir != null)
                _choice(
                  'Grosir ${_rp(widget.grosir!)}',
                  !_useDs && widget.grosir != null,
                  () => setState(() => _useDs = false),
                ),
              if (widget.ds != null) ...[
                const SizedBox(width: 6),
                _choice(
                  'DS ${_rp(widget.ds!)}',
                  _useDs || widget.grosir == null,
                  () => setState(() => _useDs = true),
                ),
              ],
            ],
          ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _field(
                    'Harga jual',
                    _sell,
                    prefix: 'Rp ',
                    onEdit: () {
                      _sellAuto = false;
                      _autoSave();
                    },
                  ),
                  const SizedBox(height: 12),
                  _lockedField('Biaya proses pesanan', _procText),
                  _hint(
                    _db.opt.proses == null
                        ? 'Tidak ada di data "biaya wajib"'
                        : 'Terkunci · mengikuti data "biaya wajib"',
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _field(
                    'Biaya lain per pcs',
                    _extra,
                    prefix: 'Rp ',
                    onEdit: _autoSave,
                  ),
                  const SizedBox(height: 12),
                  _field(
                    'Affiliasi',
                    _aff,
                    suffix: '%',
                    hint: '0',
                    decimal: true,
                    onEdit: _savePrefs,
                  ),
                  _hint(
                    sell > 0 && _pctIn(_aff.text) > 0
                        ? '= ${_rp(sell * _pctIn(_aff.text) / 100)} per pcs'
                        : 'Komisi affiliasi dari harga jual',
                  ),
                ],
              ),
            ),
          ],
        ),
        if (modal != null) ...[
          const SizedBox(height: 12),
          _priceSuggestions(
            modal: modal,
            extra: extra,
            cfg: cfg,
            sell: sell,
            minSell: minSell,
          ),
        ],
        const SizedBox(height: 16),
        _sec('1', 'Biaya admin (wajib)'),
        Row(
          children: [
            _choice(
              'Non-Star / Star / Star+',
              !_mall,
              () => _set(() => _mall = false),
            ),
            const SizedBox(width: 6),
            _choice('Mall', _mall, () => _set(() => _mall = true)),
          ],
        ),
        const SizedBox(height: 10),
        _catBlock(),
      ],
    );

    final inputsB = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sec('2', 'Program & biaya tambahan'),
        _programGrid(net, sell),
      ],
    );

    // ----- kolom hasil -----
    final result = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (modal == null)
          Text(
            'Harga modal tidak tersedia untuk produk ini.',
            style: TextStyle(fontSize: 12.5, color: cSub),
          )
        else ...[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: (sell > 0 ? profitColor : accent).withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'LABA PER PCS',
                  style: TextStyle(
                    fontSize: 11.5,
                    letterSpacing: 0.5,
                    fontWeight: FontWeight.w700,
                    color: cSub,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  sell > 0 ? _rp(profitV) : '–',
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    color: profitColor,
                  ),
                ),
                if (sell > 0)
                  Text(
                    'Margin ${_fmtPct(marginV)} dari harga jual',
                    style: TextStyle(fontSize: 12.5, color: cSub),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (sell > 0) ...[
            const SizedBox(height: 14),
            _breakdownCard(
              sell: sell,
              net: net,
              discLines: sellerLines,
              lines: lines,
              extra: extra,
              modal: modal,
              profit: profitV,
              profitColor: profitColor,
              good: good,
              bad: bad,
            ),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                'Isi harga jual untuk melihat rincian dan laba.',
                style: TextStyle(fontSize: 12.5, color: cMute),
              ),
            ),
        ],
      ],
    );

    // Halaman 3 sekarang = Ads ROAS (dulu halaman 4), halaman 4 = rincian hasil. Laba sebelum iklan dibuat SAMA dengan laba
    // kalkulator: harga = harga setelah diskon seller, modal = modal + biaya lain
    // per pcs, biaya platform = total biaya dari sheet.
    final analysis = (modal != null && modal > 0 && sell > 0)
        ? AdsRoasPanel(
            modal: modal + extra,
            price: net,
            totalPlatformFee: total,
            brandColor: const Color(0xFFEE4D2D),
            landscape: false,
            persistKey: 'kalkulator_ads_roas',
            followPrice: true,
          )
        : Padding(
            padding: const EdgeInsets.all(4),
            child: Text(
              modal == null
                  ? 'Pilih modal (Grosir / DS) dan isi harga jual untuk memakai Ads ROAS.'
                  : 'Isi harga jual untuk memakai Ads ROAS.',
              style: TextStyle(fontSize: 12.5, color: cMute),
            ),
          );

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 6, 8),
      child: Row(
        children: [
          const _CalcLogo(size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Kalkulator Shopee',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: cText,
                  ),
                ),
                if (widget.title != null)
                  Text(
                    widget.title!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: cSub),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Material(
              key: _affKey,
              color: const Color(0xFFEF4444).withValues(alpha: 0.12),
              shape: const StadiumBorder(),
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: () => _openAffiliate(sell, net, modal, extra, cfg),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        CupertinoIcons.heart_fill,
                        size: 14,
                        color: Color(0xFFEF4444),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Affiliasi',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: isDark
                              ? const Color(0xFFFCA5A5)
                              : const Color(0xFFDC2626),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: full ? 'Keluar layar penuh' : 'Layar penuh',
            icon: Icon(
              full ? Icons.fullscreen_exit : Icons.fullscreen,
              color: cSub,
            ),
            onPressed: () => setState(() => _full = !_full),
          ),
          IconButton(
            tooltip: 'Tutup',
            icon: Icon(Icons.close, color: cSub),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );

    Widget scroll(
      Widget child, {
      Color? bg,
      double pad = 14,
      bool lock = false,
    }) => _gate(
      Container(
        color: bg,
        child: SingleChildScrollView(
          padding: EdgeInsets.all(pad),
          child: child,
        ),
      ),
      locked: lock && locked,
    );

    final Widget body;
    if (wide4) {
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 9, child: scroll(inputsA)),
          VerticalDivider(width: 1, color: cLine),
          Expanded(flex: 9, child: scroll(inputsB, lock: true)),
          VerticalDivider(width: 1, color: cLine),
          Expanded(flex: 9, child: scroll(analysis, bg: cSurface2, lock: true)),
          VerticalDivider(width: 1, color: cLine),
          Expanded(flex: 10, child: scroll(result, bg: cSurface2, lock: true)),
        ],
      );
    } else if (wide3) {
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 9, child: scroll(inputsA)),
          VerticalDivider(width: 1, color: cLine),
          Expanded(flex: 9, child: scroll(inputsB, lock: true)),
          VerticalDivider(width: 1, color: cLine),
          Expanded(
            flex: 10,
            child: scroll(
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [analysis, const SizedBox(height: 16), result],
              ),
              bg: cSurface2,
              lock: true,
            ),
          ),
        ],
      );
    } else if (wide2) {
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 11,
            child: scroll(
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  inputsA,
                  const SizedBox(height: 16),
                  _gate(inputsB, locked: locked),
                ],
              ),
            ),
          ),
          VerticalDivider(width: 1, color: cLine),
          Expanded(
            flex: 9,
            child: scroll(
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [analysis, const SizedBox(height: 16), result],
              ),
              bg: cSurface2,
              lock: true,
            ),
          ),
        ],
      );
    } else {
      body = scroll(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            inputsA,
            const SizedBox(height: 16),
            _gate(inputsB, locked: locked),
            const SizedBox(height: 16),
            Divider(height: 1, color: cLine),
            const SizedBox(height: 16),
            _gate(
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [analysis, const SizedBox(height: 16), result],
              ),
              locked: locked,
            ),
          ],
        ),
        pad: 16,
      );
    }

    return _iosTooltipTheme(
      child: Dialog(
        backgroundColor: cSurface,
        insetPadding: full ? EdgeInsets.zero : const EdgeInsets.all(12),
        insetAnimationDuration: const Duration(milliseconds: 220),
        insetAnimationCurve: Curves.easeOutCubic,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(full ? 0 : 16),
        ),
        clipBehavior: Clip.antiAlias,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          width: dw,
          height: dh,
          child: SafeArea(
            top: full,
            bottom: full,
            left: full,
            right: full,
            child: Column(
              children: [
                header,
                Divider(height: 1, color: cLine),
                Expanded(child: body),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// LOGO KALKULATOR SHOPEE (aset: assets/kalkulator/kalkulator_shopee.png)
// ============================================================================
class _CalcLogo extends StatelessWidget {
  const _CalcLogo({this.size = 32});
  final double size;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(size * 0.24),
    child: Image.asset(
      'assets/kalkulator/kalkulator_shopee.png',
      width: size,
      height: size,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.high,
      errorBuilder: (_, __, ___) => Container(
        width: size,
        height: size,
        color: const Color(0xFFEE4D2D),
        child: Icon(Icons.calculate, size: size * 0.62, color: Colors.white),
      ),
    ),
  );
}

// ============================================================================
// TOOLTIP GAYA iOS (popover dengan panah, kaca blur, bayangan dua lapis,
// tutup dengan ketuk di luar)
// ============================================================================
const double _kTipW = 300;
const double _kTipArrowW = 18;
const double _kTipArrowH = 9;
const double _kTipRadius = 14;

/// Tooltip bawaan Material (tahan lama / arahkan kursor) disamakan gayanya:
/// kaca putih/gelap, sudut membulat, dan bayangan lembut ala iOS.
Widget _iosTooltipTheme({required Widget child}) => TooltipTheme(
  data: TooltipThemeData(
    waitDuration: const Duration(milliseconds: 350),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    margin: const EdgeInsets.all(8),
    textStyle: TextStyle(
      fontSize: 12.5,
      fontWeight: FontWeight.w500,
      color: cText,
    ),
    decoration: BoxDecoration(
      color: isDark ? const Color(0xF52C2C2E) : const Color(0xF7FFFFFF),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: cLine, width: 0.5),
      boxShadow: [
        BoxShadow(
          color: Color(isDark ? 0x66000000 : 0x38000000),
          blurRadius: 22,
          offset: const Offset(0, 8),
        ),
        BoxShadow(
          color: Color(isDark ? 0x4D000000 : 0x1F000000),
          blurRadius: 4,
          offset: const Offset(0, 1),
        ),
      ],
    ),
  ),
  child: child,
);

class _IosTip extends StatefulWidget {
  const _IosTip({
    required this.title,
    required this.message,
    this.icon = CupertinoIcons.info_circle,
    this.size = 16,
    this.pad = 6,
    this.color,
    this.subtitle,
    this.rows,
    this.rowsTitle = 'DATA AKTIF DARI DATABASE',
    this.sections,
    this.child,
    this.delay = const Duration(milliseconds: 120),
  });
  // [child] != null: popover menempel pada widget ini (hover / tekan lama), bukan ikon.
  final Widget? child;
  final Duration delay;
  final List<MapEntry<String, String>>?
  sections; // paragraf berlabel (Apa ini? / Pilih jika)
  final String title, message;
  // Mode kartu (gaya Rincian Penghasilan): bila [subtitle] / [rows] diisi, popover
  // tampil dengan header ikon + judul + subjudul, tabel data, dan catatan [message].
  final String? subtitle;
  final List<MapEntry<String, String>>? rows;
  final String rowsTitle;
  final IconData icon;
  final double size, pad;
  final Color? color;

  @override
  State<_IosTip> createState() => _IosTipState();
}

class _IosTipState extends State<_IosTip> {
  final _key = GlobalKey();
  OverlayEntry? _entry;
  Timer? _hoverTimer;
  bool _sticky = false; // dibuka lewat ketuk -> tetap terbuka sampai ketuk lagi

  void _hide() {
    _hoverTimer?.cancel();
    _sticky = false;
    _entry?.remove();
    _entry = null;
  }

  @override
  void dispose() {
    _hide();
    super.dispose();
  }

  /// Isi popover mode kartu: header (ikon ?, judul, subjudul, tombol tutup),
  /// tabel "data aktif", lalu catatan kecil.
  Widget _richBody() {
    final tone = widget.color ?? accent;
    final rows = widget.rows ?? const <MapEntry<String, String>>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: tone,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                CupertinoIcons.question,
                size: 16,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                      height: 1.2,
                      color: cText,
                    ),
                  ),
                  if (widget.subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        widget.subtitle!,
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.25,
                          color: cSub,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (_sticky) ...[
              const SizedBox(width: 8),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _hide,
                child: Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: cLine.withValues(alpha: 0.8),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(CupertinoIcons.xmark, size: 11, color: cSub),
                ),
              ),
            ],
          ],
        ),
        if (widget.sections != null)
          for (final sec in widget.sections!) ...[
            const SizedBox(height: 12),
            Text(
              sec.key.toUpperCase(),
              style: TextStyle(
                fontSize: 10.5,
                letterSpacing: 0.6,
                fontWeight: FontWeight.w700,
                color: tone,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              sec.value,
              style: TextStyle(fontSize: 12, height: 1.4, color: cText),
            ),
          ],
        if (rows.isNotEmpty) ...[
          const SizedBox(height: 12),
          Divider(height: 1, thickness: 1, color: cLine),
          const SizedBox(height: 10),
          Text(
            widget.rowsTitle,
            style: TextStyle(
              fontSize: 10.5,
              letterSpacing: 0.6,
              fontWeight: FontWeight.w600,
              color: cMute,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: cSurface2,
              border: Border.all(color: cLine, width: 0.5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0) Divider(height: 1, thickness: 0.5, color: cLine),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          rows[i].key,
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.25,
                            color: cSub,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            rows[i].value,
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontSize: 11.5,
                              height: 1.25,
                              fontWeight: FontWeight.w700,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                              color: cText,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
        if (widget.message.trim().isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(CupertinoIcons.info_circle, size: 13, color: cMute),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.message.trim(),
                  style: TextStyle(fontSize: 11.5, height: 1.35, color: cSub),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  void _show({bool sticky = true}) {
    if (_entry != null) return _hide();
    _sticky = sticky;
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final o = box.localToGlobal(Offset.zero);
    final scr = MediaQuery.sizeOf(context);
    const w = _kTipW;
    final cx = o.dx + box.size.width / 2;
    final left = (cx - w / 2)
        .clamp(12.0, max(12.0, scr.width - w - 12))
        .toDouble();
    final arrowX = (cx - left).clamp(22.0, w - 22).toDouble();
    final rich =
        widget.subtitle != null ||
        widget.rows != null ||
        widget.sections != null;
    final below =
        scr.height - (o.dy + box.size.height) >
        (widget.sections != null ? 430 : (rich ? 340 : 260));
    final dark = isDark;
    final fill = (dark ? const Color(0xFF2C2C2E) : Colors.white).withValues(
      alpha: 0.97,
    );

    _entry = OverlayEntry(
      builder: (_) => Stack(
        children: [
          // Latar penangkap ketuk hanya untuk mode ketuk (layar sentuh); saat hover
          // popover tidak boleh menghalangi mouse.
          if (_sticky)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _hide,
              ),
            ),
          Positioned(
            left: left,
            width: w,
            top: below ? o.dy + box.size.height + 6 : null,
            bottom: below ? null : scr.height - o.dy + 6,
            child: IgnorePointer(
              ignoring: !_sticky,
              child: Material(
                type: MaterialType.transparency,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  builder: (_, v, child) => Opacity(
                    opacity: v,
                    child: Transform.scale(
                      scale: 0.92 + 0.08 * v,
                      alignment: Alignment(
                        ((arrowX / w) * 2) - 1,
                        below ? -1 : 1,
                      ),
                      child: child,
                    ),
                  ),
                  // Urutan lukis: bayangan (paling belakang) → badan kaca → panah.
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CustomPaint(
                            painter: _TipShadow(
                              arrowX: arrowX,
                              below: below,
                              dark: dark,
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: EdgeInsets.only(
                          top: below ? _kTipArrowH : 0,
                          bottom: below ? 0 : _kTipArrowH,
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(_kTipRadius),
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                            child: Container(
                              padding: EdgeInsets.fromLTRB(
                                16,
                                14,
                                16,
                                rich ? 14 : 16,
                              ),
                              decoration: BoxDecoration(
                                color: fill,
                                border: Border.all(color: cLine, width: 0.5),
                                borderRadius: BorderRadius.circular(
                                  _kTipRadius,
                                ),
                              ),
                              child: rich
                                  ? _richBody()
                                  : Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          widget.title,
                                          style: TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600,
                                            letterSpacing: -0.2,
                                            color: cText,
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          widget.message,
                                          style: TextStyle(
                                            fontSize: 13.5,
                                            height: 1.4,
                                            color: cSub,
                                          ),
                                        ),
                                      ],
                                    ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: arrowX - _kTipArrowW / 2,
                        top: below ? 0.0 : null,
                        bottom: below ? null : 0.0,
                        child: CustomPaint(
                          size: const Size(_kTipArrowW, _kTipArrowH),
                          painter: _Arrow(fill, up: below),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_entry!);
  }

  void _onTap() {
    _hoverTimer?.cancel();
    if (_entry != null && !_sticky) {
      // sedang tampil karena hover -> klik menjadikannya tetap terbuka
      _sticky = true;
      _entry!.markNeedsBuild();
      return;
    }
    _show();
  }

  @override
  Widget build(BuildContext context) {
    final anchor = widget.child;
    return MouseRegion(
      // Arahkan mouse -> popover muncul; mouse menjauh -> hilang.
      // Ikon: ketuk (layar sentuh / klik) -> buka tetap, ketuk lagi untuk menutup.
      // Mode [child]: ketuk biasa tetap milik widget-nya; tekan lama -> buka tetap.
      onEnter: (_) {
        _hoverTimer?.cancel();
        if (_entry != null) return;
        _hoverTimer = Timer(widget.delay, () {
          if (!mounted || _entry != null) return;
          _show(sticky: false);
        });
      },
      onExit: (_) {
        _hoverTimer?.cancel();
        if (_entry != null && !_sticky) _hide();
      },
      child: anchor != null
          ? Listener(
              onPointerDown: (_) {
                _hoverTimer?.cancel();
                if (_entry != null && !_sticky) _hide();
              },
              child: GestureDetector(
                key: _key,
                behavior: HitTestBehavior.translucent,
                onLongPress: _onTap,
                child: anchor,
              ),
            )
          : GestureDetector(
              key: _key,
              behavior: HitTestBehavior.opaque,
              onTap: _onTap,
              child: Padding(
                padding: EdgeInsets.all(widget.pad),
                child: Icon(
                  widget.icon,
                  size: widget.size,
                  color: widget.color ?? accent,
                ),
              ),
            ),
    );
  }
}

class _Arrow extends CustomPainter {
  _Arrow(this.color, {required this.up});
  final Color color;
  final bool up;

  @override
  void paint(Canvas canvas, Size s) {
    final p = Path()
      ..moveTo(0, up ? s.height : 0)
      ..lineTo(s.width / 2, up ? 0 : s.height)
      ..lineTo(s.width, up ? s.height : 0)
      ..close();
    canvas.drawPath(p, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_Arrow o) => o.color != color || o.up != up;
}

/// Bayangan dua lapis untuk popover (badan + panah jadi satu bentuk): lapis lebar
/// & lembut memberi kedalaman, lapis rapat memberi kontur. Dilukis hanya DI LUAR
/// bentuk, supaya kaca blur di dalamnya tidak ikut menggelap (dan tidak terpotong
/// oleh ClipRRect seperti boxShadow biasa).
class _TipShadow extends CustomPainter {
  const _TipShadow({
    required this.arrowX,
    required this.below,
    required this.dark,
  });
  final double arrowX;
  final bool below;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final top = below ? _kTipArrowH : 0.0;
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, top, size.width, size.height - _kTipArrowH),
      const Radius.circular(_kTipRadius),
    );
    final tri = Path();
    if (below) {
      tri
        ..moveTo(arrowX - _kTipArrowW / 2, top)
        ..lineTo(arrowX, 0)
        ..lineTo(arrowX + _kTipArrowW / 2, top)
        ..close();
    } else {
      final y = size.height - _kTipArrowH;
      tri
        ..moveTo(arrowX - _kTipArrowW / 2, y)
        ..lineTo(arrowX, size.height)
        ..lineTo(arrowX + _kTipArrowW / 2, y)
        ..close();
    }
    final shape = Path.combine(
      PathOperation.union,
      Path()..addRRect(body),
      tri,
    );
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Rect.fromLTWH(-120, -120, size.width + 240, size.height + 240))
      ..addPath(shape, Offset.zero);

    canvas.save();
    canvas.clipPath(outside);
    canvas.drawPath(
      shape.shift(const Offset(0, 12)),
      Paint()
        ..color = Color(dark ? 0x80000000 : 0x47000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 15),
    );
    canvas.drawPath(
      shape.shift(const Offset(0, 2)),
      Paint()
        ..color = Color(dark ? 0x66000000 : 0x30000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.5),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TipShadow o) =>
      o.arrowX != arrowX || o.below != below || o.dark != dark;
}

/// Kontrol segmen gaya iOS (2+ pilihan).
class _SegControl extends StatelessWidget {
  const _SegControl({
    required this.labels,
    required this.index,
    required this.onChanged,
  });
  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(2),
    decoration: BoxDecoration(
      color: cLine.withValues(alpha: 0.7),
      borderRadius: BorderRadius.circular(9),
    ),
    child: Row(
      children: [
        for (var i = 0; i < labels.length; i++)
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onChanged(i),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 6),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: i == index ? cSurface : null,
                  borderRadius: BorderRadius.circular(7),
                  boxShadow: i == index
                      ? const [
                          BoxShadow(
                            color: Color(0x1F000000),
                            blurRadius: 3,
                            offset: Offset(0, 1),
                          ),
                        ]
                      : null,
                ),
                child: Text(
                  labels[i],
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: i == index ? FontWeight.w600 : FontWeight.w400,
                    color: i == index ? cText : cSub,
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

// ============================================================================
// SIMULASI AFFILIASI (komisi affiliator per tier vs profit)
// ============================================================================
class _AffiliateSheet extends StatefulWidget {
  const _AffiliateSheet({
    required this.sell,
    required this.net,
    required this.modal,
    required this.extra,
    required this.cfg,
    required this.initialPct,
    this.anchor,
  });
  final double sell, net, modal, extra, initialPct;
  final _Cfg cfg;
  final Rect? anchor; // posisi tombol Affiliasi di layar (null = tengah layar)

  @override
  State<_AffiliateSheet> createState() => _AffiliateSheetState();
}

class _AffiliateSheetState extends State<_AffiliateSheet> {
  static const _tiers = <double>[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 15, 20, 25, 30];
  static const _maxPct = 55.0;
  late final TextEditingController _custom;
  late double _slide;

  @override
  void initState() {
    super.initState();
    _custom = TextEditingController(text: _fmtNum(widget.initialPct));
    _slide = 20;
  }

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  static String _fmtNum(double v) {
    final r =
        (v * 100).round() /
        100; // buang sisa desimal floating point (6.9999999 -> 7)
    return r == r.roundToDouble() ? '${r.toInt()}' : '$r';
  }

  double get _customPct =>
      (double.tryParse(_custom.text.replaceAll(',', '.')) ?? 0)
          .clamp(0, 99.9)
          .toDouble();

  double _komisi(double p) => _rnd(widget.net * p / 100);
  double _profit(double p) =>
      _profitAt(widget.sell, widget.modal, widget.extra, widget.cfg.withAff(p));

  /// komisi > profit -> Tipis; profit negatif -> Rugi.
  (String, Color) _status(double p) {
    final pf = _profit(p);
    if (pf < 0)
      return ('RUGI', isDark ? Colors.red.shade300 : Colors.red.shade600);
    if (_komisi(p) > pf)
      return (
        'TIPIS',
        isDark ? Colors.orange.shade300 : Colors.orange.shade800,
      );
    return ('AMAN', isDark ? Colors.green.shade300 : Colors.green.shade700);
  }

  @override
  Widget build(BuildContext context) {
    final good = isDark ? Colors.green.shade300 : Colors.green.shade700;
    final base = _profit(0); // profit sebelum komisi
    String sp(num v) => _rp(v).replaceFirst('Rp', 'Rp ');
    final custom = _customPct;
    final list = <double>{..._tiers, if (custom > 0) custom}.toList()..sort();

    // ---- lebar otomatis: ukur teks nominal terpanjang, lebarkan popup supaya
    // angka tidak turun baris / menumpuk. Bila layar tak cukup, angka diperkecil.
    final scr = MediaQuery.sizeOf(context);
    const tierW = 52.0, statusW = 64.0, colGap = 8.0, padTotal = 56.0;
    final mst = (Theme.of(context).textTheme.bodyMedium ?? const TextStyle())
        .copyWith(
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        );
    double tw(String t) {
      final tp = TextPainter(
        text: TextSpan(text: t, style: mst),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      return tp.width;
    }

    double widest(Iterable<String> l) => l.fold(0.0, (m, t) => max(m, tw(t)));
    // nilai terbesar mungkin di 0% atau 99,9% -> lebar tidak melompat saat input
    final kwRaw =
        widest([sp(_komisi(99.9)), sp(_komisi(_maxPct)), sp(_komisi(custom))]) *
        1.06;
    final pwRaw =
        widest([sp(_profit(0)), sp(_profit(99.9)), sp(base), sp(_profit(custom))]) *
        1.06;
    const fixedW = padTotal + tierW + statusW + colGap * 2;
    final maxW = max(280.0, scr.width - 24);
    final popW = max(min(440.0, maxW), min(kwRaw + pwRaw + fixedW, maxW));
    final room = popW - fixedW;
    final shrink = (kwRaw + pwRaw) > room ? room / (kwRaw + pwRaw) : 1.0;
    final kwUse = kwRaw * shrink;

    Widget bigVal(String t, Color c) => FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text(
        t,
        maxLines: 1,
        softWrap: false,
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: c),
      ),
    );

    Widget pill(String t, Color c) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        t,
        style: TextStyle(
          fontSize: 10.5,
          letterSpacing: 0.3,
          fontWeight: FontWeight.w800,
          color: c,
        ),
      ),
    );

    Widget cell(
      String t, {
      double? w,
      Color? c,
      bool bold = false,
      TextAlign? a,
    }) {
      final txt = Text(
        t,
        textAlign: a,
        maxLines: 1,
        softWrap: false,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
          fontFeatures: const [FontFeature.tabularFigures()],
          color: c ?? cText,
        ),
      );
      final fitted = FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: txt,
      );
      return w == null
          ? Expanded(child: fitted)
          : SizedBox(width: w, child: fitted);
    }

    Widget hcell(String t, {double? w}) {
      final txt = Text(
        t,
        style: TextStyle(
          fontSize: 10.5,
          letterSpacing: 0.5,
          fontWeight: FontWeight.w700,
          color: cMute,
        ),
      );
      return w == null ? Expanded(child: txt) : SizedBox(width: w, child: txt);
    }

    Widget row(double p, {bool hi = false}) {
      final st = _status(p);
      return InkWell(
        onTap: () => setState(() => _custom.text = _fmtNum(p)),
        child: Container(
          color: hi ? accent.withValues(alpha: 0.10) : null,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(
            children: [
              cell('${_fmtNum(p)}%', w: tierW, bold: true, c: hi ? accent : cText),
              cell(sp(_komisi(p)), w: kwUse),
              const SizedBox(width: colGap),
              cell(sp(_profit(p)), c: st.$2, bold: true),
              const SizedBox(width: colGap),
              SizedBox(
                width: statusW,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: pill(st.$1, st.$2),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final sp0 = _slide;
    final stS = _status(sp0);

    final body = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0xFFEF4444),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: const Icon(
                      CupertinoIcons.heart_fill,
                      size: 22,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Affiliasi',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.3,
                            color: cText,
                          ),
                        ),
                        Text(
                          'Simulasi komisi affiliator per tier',
                          style: TextStyle(fontSize: 12, color: cSub),
                        ),
                      ],
                    ),
                  ),
                  _CloseDot(onTap: () => Navigator.pop(context)),
                ],
              ),
            ),
            Divider(height: 1, color: cLine),
            // komisi custom
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              'Komisi Custom',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: cText,
                              ),
                            ),
                            const _IosTip(
                              title: 'Komisi Custom',
                              message:
                                  'Ketik persentase komisi sendiri. Barisnya ditandai di tabel '
                                  'dan dihitung ulang terhadap profit produk ini.',
                              size: 14,
                              pad: 4,
                            ),
                          ],
                        ),
                        Text(
                          'Uji persentase komisi di luar tier standar',
                          style: TextStyle(fontSize: 11.5, color: cSub),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    width: 82,
                    height: 34,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: cSurface2,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: TextField(
                      controller: _custom,
                      onChanged: (_) => setState(() {}),
                      textAlign: TextAlign.right,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                      ],
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: cText,
                      ),
                      decoration: InputDecoration(
                        isCollapsed: true,
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(vertical: 9),
                        suffixText: ' %',
                        suffixStyle: TextStyle(fontSize: 12, color: cSub),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // ringkas
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: cSurface2,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'HARGA JUAL',
                          style: TextStyle(
                            fontSize: 10,
                            letterSpacing: 0.5,
                            fontWeight: FontWeight.w700,
                            color: cSub,
                          ),
                        ),
                        const SizedBox(height: 2),
                        bigVal(sp(widget.sell), cText),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'PROFIT SEBELUM KOMISI',
                          style: TextStyle(
                            fontSize: 10,
                            letterSpacing: 0.5,
                            fontWeight: FontWeight.w700,
                            color: cSub,
                          ),
                        ),
                        const SizedBox(height: 2),
                        bigVal(
                          sp(base),
                          base >= 0 ? good : Colors.red.shade600,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            // header tabel
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  hcell('TIER', w: tierW),
                  hcell('KOMISI', w: kwUse),
                  const SizedBox(width: colGap),
                  hcell('PROFIT'),
                  const SizedBox(width: colGap),
                  SizedBox(
                    width: statusW,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        'STATUS',
                        style: TextStyle(
                          fontSize: 10.5,
                          letterSpacing: 0.5,
                          fontWeight: FontWeight.w700,
                          color: cMute,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Divider(height: 1, color: cLine),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final p in list) ...[
                      row(p, hi: custom > 0 && (p - custom).abs() < 0.0001),
                      Divider(height: 1, thickness: 0.5, color: cLine),
                    ],
                  ],
                ),
              ),
            ),
            // hasil geser
            Container(
              margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              decoration: BoxDecoration(
                color: stS.$2.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  cell('${_fmtNum(sp0)}%', w: tierW, bold: true),
                  cell(sp(_komisi(sp0)), w: kwUse),
                  const SizedBox(width: colGap),
                  cell(sp(_profit(sp0)), c: stS.$2, bold: true),
                  const SizedBox(width: colGap),
                  SizedBox(
                    width: statusW,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: pill(stS.$1, stS.$2),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Jelajahi persentase lain',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: cText,
                      ),
                    ),
                  ),
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => setState(
                      () => _slide = (1 + Random().nextInt(_maxPct.toInt()))
                          .toDouble(),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 4,
                      ),
                      child: Row(
                        children: [
                          Icon(CupertinoIcons.shuffle, size: 14, color: accent),
                          const SizedBox(width: 4),
                          Text(
                            'Acak',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: accent,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
              child: Slider(
                value: _slide,
                min: 0,
                max: _maxPct,
                divisions: _maxPct.toInt(),
                onChanged: (v) => setState(() => _slide = v.roundToDouble()),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 0, 22, 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('0%', style: TextStyle(fontSize: 11, color: cMute)),
                  Text(
                    '${_maxPct.toInt()}%',
                    style: TextStyle(fontSize: 11, color: cMute),
                  ),
                ],
              ),
            ),
          ],
        );
    return _popover(context, body, popW, scr);
  }

  /// Popover menempel di tombol Affiliasi (muncul di bawahnya, atau di atasnya
  /// bila ruang bawah kurang), dengan panah menunjuk ke tombol.
  Widget _popover(BuildContext context, Widget body, double w, Size scr) {
    final a = widget.anchor;
    if (a == null) {
      // tombol tidak ditemukan -> tengah layar
      return Material(
        type: MaterialType.transparency,
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: w,
              maxHeight: scr.height * 0.92,
            ),
            child: Material(
              color: cSurface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              clipBehavior: Clip.antiAlias,
              child: body,
            ),
          ),
        ),
      );
    }
    const m = 12.0, gap = 6.0;
    final pad = MediaQuery.paddingOf(context);
    final spaceBelow =
        scr.height - a.bottom - pad.bottom - m - gap - _kTipArrowH;
    final spaceAbove = a.top - pad.top - m - gap - _kTipArrowH;
    final below = spaceBelow >= 460 || spaceBelow >= spaceAbove;
    final maxH = max(240.0, below ? spaceBelow : spaceAbove);
    final left = a.left.clamp(m, max(m, scr.width - w - m)).toDouble();
    final arrowX = (a.center.dx - left).clamp(24.0, w - 24).toDouble();
    final dark = isDark;
    final fill = cSurface;

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.pop(context),
            ),
          ),
          Positioned(
            left: left,
            width: w,
            top: below ? a.bottom + gap : null,
            bottom: below ? null : scr.height - a.top + gap,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              builder: (_, v, child) => Opacity(
                opacity: v,
                child: Transform.scale(
                  scale: 0.94 + 0.06 * v,
                  alignment: Alignment(((arrowX / w) * 2) - 1, below ? -1 : 1),
                  child: child,
                ),
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _TipShadow(
                          arrowX: arrowX,
                          below: below,
                          dark: dark,
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.only(
                      top: below ? _kTipArrowH : 0,
                      bottom: below ? 0 : _kTipArrowH,
                    ),
                    child: Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: fill,
                        border: Border.all(color: cLine, width: 0.5),
                        borderRadius: BorderRadius.circular(_kTipRadius + 4),
                      ),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: maxH),
                        child: body,
                      ),
                    ),
                  ),
                  Positioned(
                    left: arrowX - _kTipArrowW / 2,
                    top: below ? 0.0 : null,
                    bottom: below ? null : 0.0,
                    child: CustomPaint(
                      size: const Size(_kTipArrowW, _kTipArrowH),
                      painter: _Arrow(fill, up: below),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Tombol tutup bulat: berubah merah saat disentuh / ditekan / di-hover mouse.
class _CloseDot extends StatefulWidget {
  const _CloseDot({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_CloseDot> createState() => _CloseDotState();
}

class _CloseDotState extends State<_CloseDot> {
  bool _hover = false, _down = false;

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFEF4444);
    final on = _hover || _down;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTap: () async {
          // jeda singkat supaya warna merah sempat terlihat saat ketuk
          await Future<void>.delayed(const Duration(milliseconds: 90));
          if (mounted) widget.onTap();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? red.withValues(alpha: 0.14) : cLine.withValues(alpha: 0.8),
            shape: BoxShape.circle,
          ),
          child: Icon(CupertinoIcons.xmark, size: 14, color: on ? red : cSub),
        ),
      ),
    );
  }
}

// ============================================================================
// TEKS TOOLTIP PROGRAM & BIAYA (muncul saat tombol program disentuh / diarahkan)
// ============================================================================
class _TileTip {
  const _TileTip(this.group, this.what, this.when, this.rows);
  final String group, what, when;
  final List<MapEntry<String, String>> rows;
}

/// key -> (Apa ini?, Pilih jika). Kunci opsional = KalkOpt.name.
const Map<String, (String, String)> _kTipTexts = {
  'go_biasa': (
    'Program opsional Shopee yang memberi pembeli bebas ongkir. Seller membayar biaya layanan '
        'berupa persen dari harga produk (setelah diskon seller), dengan batas maksimal per produk.',
    'Produk berukuran biasa: berat di bawah 5 kg, panjang/lebar/tinggi tiap sisi tidak lebih '
        'dari sekitar 60 cm, dan volume sekitar 20.000 cm³ ke bawah.',
  ),
  'go_khusus': (
    'Gratis Ongkir XTRA untuk produk yang besar atau berat. Tarif dan batas maksimalnya lebih '
        'tinggi daripada ukuran biasa.',
    'Berat produk 5 kg atau lebih, atau salah satu sisinya lebih dari sekitar 60 cm, atau '
        'volumenya di atas sekitar 20.000 cm³.',
  ),
  'promo_iklan': (
    'Tarif Gratis Ongkir XTRA yang lebih rendah untuk toko yang aktif beriklan. Saat aktif, '
        'tarif ini menggantikan tarif Gratis Ongkir XTRA (bukan ditambahkan) dan mengikuti '
        'ukuran yang sama.',
    'Toko Anda memakai iklan Shopee dan memenuhi syarat program. Aktifkan Gratis Ongkir XTRA '
        'terlebih dahulu.',
  ),
  'promoXtra': (
    'Program promosi Shopee dengan voucher untuk pembeli, hanya untuk seller yang memenuhi '
        'kriteria. Biaya layanan dikenakan pada pesanan yang selesai, dengan batas maksimal '
        'per produk.',
    'Toko sudah masuk program dan margin cukup untuk menanggung biayanya. Tidak bisa dipakai '
        'bersamaan dengan Promo XTRA+ (pilih salah satu).',
  ),
  'promoXtraPlus': (
    'Tingkat lanjutan dari Promo XTRA dengan biaya lebih tinggi. Hanya untuk seller yang sudah '
        'ada di Promo XTRA, dan biayanya dikenakan ke semua pesanan selesai, bukan hanya yang '
        'memakai voucher.',
    'Anda ingin ikut periode promo besar dan margin masih aman setelah biaya tambahannya. '
        'Untuk keadaan normal, Promo XTRA biasa lebih hemat.',
  ),
  'spayLater': (
    'Pembeli bisa mencicil 3 atau 6 bulan dengan bunga 0%. Seller membayar biaya layanan dari '
        'total penjualan pesanan yang dibayar lewat SPayLater (tenor 6 bulan lebih mahal).',
    'Produk berharga cukup tinggi dan Anda ingin pembeli bisa mencicil. Pilih tenor sesuai yang '
        'ingin ditawarkan.',
  ),
  'live': (
    'Program eksposur lewat Shopee Live: produk diberi label Live XTRA. Biaya layanan dikenakan '
        'pada pesanan selesai, dengan batas maksimal per produk.',
    'Toko Anda rutin live streaming di Shopee Live.',
  ),
  'video': (
    'Program eksposur lewat Shopee Video. Biaya layanan dikenakan pada pesanan selesai, dengan '
        'batas maksimal per produk. Tarifnya turun bila Promo XTRA aktif.',
    'Toko Anda rutin memakai Shopee Video untuk menjual produk.',
  ),
  'preOrder': (
    'Biaya layanan untuk produk pre-order (waktu kirim lebih lama dari biasa), dipotong otomatis '
        'setelah pesanan selesai.',
    'Produk yang Anda jual berstatus pre-order.',
  ),
  'asuransi': (
    'Biaya asuransi pengiriman yang melindungi paket bila rusak atau hilang di perjalanan.',
    'Produk bernilai tinggi atau mudah rusak. Cek syarat klaim di Seller Centre.',
  ),
  'hemat': (
    'Biaya tetap per pesanan untuk program yang membantu menekan ongkir yang dibayar pembeli.',
    'Toko Anda ikut Program Hemat Biaya Kirim.',
  ),
  'pph': (
    'Potongan pajak PPh 22 yang dipungut marketplace dari harga jual (persen kecil dari nilai '
        'transaksi).',
    'Toko Anda dikenai pemotongan PPh 22 oleh Shopee sesuai status pajak toko.',
  ),
};
