import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';

const sheetId = '1K__3U0onqCGD7LWmqPgbCvnwlFKRV6rHXOJilaUN_BE';

class Product {
  Product({
    required this.sheet,
    required this.name,
    this.no,
    this.variants = const [],
    this.grosir,
    this.ds,
    this.kit,
    this.note,
    this.sold = false,
    this.image,
  });

  final String sheet, name;
  final String? no, kit, note, image;
  final List<String> variants;
  final int? grosir, ds;
  final bool sold;

  String get key => '$sheet|${name.toLowerCase().trim()}';

  Map<String, dynamic> toJson() => {
        'sheet': sheet, 'name': name, 'no': no, 'variants': variants,
        'grosir': grosir, 'ds': ds, 'kit': kit, 'note': note,
        'sold': sold, 'image': image,
      };

  factory Product.fromJson(Map<String, dynamic> j) => Product(
        sheet: j['sheet'], name: j['name'], no: j['no'],
        variants: List<String>.from(j['variants'] ?? []),
        grosir: j['grosir'], ds: j['ds'], kit: j['kit'], note: j['note'],
        sold: j['sold'] ?? false, image: j['image'],
      );
}

class Change {
  Change(this.type, this.product, this.detail, [DateTime? at]) : at = at ?? DateTime.now();
  final String type; // baru | harga | sold | tersedia | varian | hapus
  final String product, detail;
  final DateTime at;

  String get key => product;

  Map<String, dynamic> toJson() =>
      {'type': type, 'product': product, 'detail': detail, 'at': at.toIso8601String()};
  factory Change.fromJson(Map<String, dynamic> j) =>
      Change(j['type'], j['product'], j['detail'], DateTime.parse(j['at']));
}

String rp(int? v) {
  if (v == null) return '-';
  final s = v.toString();
  final b = StringBuffer('Rp');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write('.');
    b.write(s[i]);
  }
  return b.toString();
}

Iterable<XmlElement> _byLocal(XmlNode n, String l) =>
    n.descendants.whereType<XmlElement>().where((e) => e.name.local == l);

int? _money(String? v) {
  if (v == null) return null;
  if (RegExp(r'^\d+(\.\d+)?$').hasMatch(v)) return double.parse(v).round();
  final d = v.replaceAll(RegExp(r'[^0-9]'), '');
  return d.isEmpty ? null : int.parse(d);
}

class CatalogService {
  Future<Directory> _dir() async {
    final d = Directory(p.join((await getApplicationSupportDirectory()).path, 'katalog'));
    await Directory(p.join(d.path, 'img')).create(recursive: true);
    return d;
  }

  /// Download seluruh spreadsheet sebagai xlsx, lalu parse semua tab.
  Future<List<Product>> fetch() async {
    final d = await _dir();
    final res = await http
        .get(Uri.parse('https://docs.google.com/spreadsheets/d/$sheetId/export?format=xlsx'));
    if (res.statusCode != 200) {
      throw Exception('Gagal download (HTTP ${res.statusCode}). '
          'Cek apakah sheet masih bisa diakses/diunduh.');
    }
    final zip = ZipDecoder().decodeBytes(res.bodyBytes);
    final files = {for (final f in zip.files) if (f.isFile) f.name: f};

    XmlDocument xml(String path) =>
        XmlDocument.parse(utf8.decode(files[path]!.content as List<int>));

    Map<String, Map<String, String>> rels(String part) {
      final rp = p.posix.join(p.posix.dirname(part), '_rels', '${p.posix.basename(part)}.rels');
      if (!files.containsKey(rp)) return {};
      return {
        for (final r in _byLocal(xml(rp), 'Relationship'))
          r.getAttribute('Id')!: {'t': r.getAttribute('Target')!, 'y': r.getAttribute('Type')!}
      };
    }

    String resolve(String part, String target) => target.startsWith('/')
        ? target.substring(1)
        : p.posix.normalize(p.posix.join(p.posix.dirname(part), target));

    final shared = <String>[];
    if (files.containsKey('xl/sharedStrings.xml')) {
      for (final si in _byLocal(xml('xl/sharedStrings.xml'), 'si')) {
        shared.add(_byLocal(si, 't').map((e) => e.innerText).join());
      }
    }

    final wbRels = rels('xl/workbook.xml');
    final out = <Product>[];

    for (final s in _byLocal(xml('xl/workbook.xml'), 'sheet')) {
      final sheetName = s.getAttribute('name')!;
      final rid = s.attributes.firstWhere((a) => a.name.local == 'id').value;
      final part = resolve('xl/workbook.xml', wbRels[rid]!['t']!);
      if (!files.containsKey(part)) continue;
      final doc = xml(part);

      // --- baca sel ---
      final grid = <int, Map<String, String>>{};
      final ref = RegExp(r'^([A-Z]+)(\d+)$');
      for (final c in _byLocal(doc, 'c')) {
        final m = ref.firstMatch(c.getAttribute('r')!)!;
        final t = c.getAttribute('t');
        String? v;
        if (t == 's') {
          final i = int.tryParse(c.getElement('v')?.innerText ?? '');
          v = i == null ? null : shared[i];
        } else if (t == 'inlineStr') {
          v = _byLocal(c, 't').map((e) => e.innerText).join();
        } else {
          v = c.getElement('v')?.innerText;
        }
        if (v == null || v.trim().isEmpty) continue;
        (grid[int.parse(m[2]!)] ??= {})[m[1]!] = v.trim();
      }

      // --- cari baris header ---
      final rowsSorted = grid.keys.toList()..sort();
      int? hr;
      for (final r in rowsSorted.take(10)) {
        if (grid[r]!.values.any((v) => v.toUpperCase() == 'NAMA PRODUK')) {
          hr = r;
          break;
        }
      }
      if (hr == null) continue; // tab bukan tabel produk
      final cols = {for (final e in grid[hr]!.entries) e.value.toUpperCase(): e.key};
      final cName = cols['NAMA PRODUK']!;
      final cNo = cols['NO'];
      final cVar = cols['VARIANT'] ?? cols['VARIAN'];
      final cG = cols['HARGA GROSIR'];
      final cD = cols['HARGA DS'];
      final cKit = cols['MARKETING KIT'];
      final cKet = cols['KET'];

      // --- gambar (anchor di drawing xlsx) ---
      final imgs = <int, String>{}; // baris (1-based) -> path file
      for (final r in rels(part).values.where((r) => r['y']!.endsWith('/drawing'))) {
        final dpart = resolve(part, r['t']!);
        if (!files.containsKey(dpart)) continue;
        final dr = rels(dpart);
        final dd = xml(dpart);
        for (final a in [..._byLocal(dd, 'oneCellAnchor'), ..._byLocal(dd, 'twoCellAnchor')]) {
          final from = _byLocal(a, 'from').firstOrNull;
          final row = from == null ? null : int.tryParse(_byLocal(from, 'row').first.innerText);
          final emb = _byLocal(a, 'blip')
              .firstOrNull
              ?.attributes
              .where((x) => x.name.local == 'embed')
              .firstOrNull
              ?.value;
          if (row == null || emb == null || dr[emb] == null) continue;
          final media = resolve(dpart, dr[emb]!['t']!);
          final f = files[media];
          if (f == null) continue;
          final bytes = f.content as List<int>;
          final file = File(p.join(d.path, 'img', '${md5.convert(bytes)}${p.extension(media)}'));
          if (!file.existsSync()) await file.writeAsBytes(bytes);
          imgs.putIfAbsent(row + 1, () => file.path);
        }
      }

      // --- kelompokkan baris jadi produk (baris varian = nama kosong) ---
      final dataRows = rowsSorted.where((r) => r > hr!).toList();
      final starts = dataRows.where((r) => grid[r]![cName] != null).toList();
      for (var i = 0; i < starts.length; i++) {
        final s0 = starts[i];
        final e0 = i + 1 < starts.length ? starts[i + 1] : 1 << 30;
        final range = dataRows.where((r) => r >= s0 && r < e0).toList();
        String? cell(String? col, [int? r]) => col == null ? null : grid[r ?? s0]![col];

        final variants = <String>[];
        var sold = false;
        final notes = <String>[];
        for (final r in range) {
          final v = cVar == null ? null : grid[r]![cVar];
          if (v != null && v != '-' && !variants.contains(v)) variants.add(v);
          if (grid[r]!.values.any((x) => x.toUpperCase() == 'SOLD')) sold = true;
          final n = cKet == null ? null : grid[r]![cKet];
          if (n != null && n.toUpperCase() != 'SOLD') notes.add(n);
        }
        final imgRow = imgs.keys.where((k) => k >= s0 && k < e0).toList()..sort();

        out.add(Product(
          sheet: sheetName,
          name: cell(cName)!,
          no: cell(cNo),
          variants: variants,
          grosir: _money(cell(cG)),
          ds: _money(cell(cD)),
          kit: cell(cKit),
          note: notes.isEmpty ? null : notes.join(' · '),
          sold: sold,
          image: imgRow.isEmpty ? null : imgs[imgRow.first],
        ));
      }
    }
    return out;
  }

  // ---------- cache lokal ----------
  Future<File> _f(String n) async => File(p.join((await _dir()).path, n));

  Future<List<Product>> loadCache() async {
    final f = await _f('catalog.json');
    if (!f.existsSync()) return [];
    return (jsonDecode(await f.readAsString()) as List)
        .map((e) => Product.fromJson(e))
        .toList();
  }

  Future<void> saveCache(List<Product> l) async =>
      (await _f('catalog.json')).writeAsString(jsonEncode(l.map((e) => e.toJson()).toList()));

  Future<Map<String, dynamic>> loadMeta() async {
    final f = await _f('meta.json');
    if (!f.existsSync()) return {};
    try {
      return Map<String, dynamic>.from(jsonDecode(await f.readAsString()));
    } catch (_) {
      return {};
    }
  }

  Future<void> saveMeta(Map<String, dynamic> m) async =>
      (await _f('meta.json')).writeAsString(jsonEncode(m));

  Future<List<Change>> loadChanges() async {
    final f = await _f('changes.json');
    if (!f.existsSync()) return [];
    return (jsonDecode(await f.readAsString()) as List).map((e) => Change.fromJson(e)).toList();
  }

  Future<void> saveChanges(List<Change> l) async =>
      (await _f('changes.json')).writeAsString(jsonEncode(l.map((e) => e.toJson()).toList()));
}

/// Bandingkan katalog lama vs baru.
List<Change> diffCatalog(List<Product> old, List<Product> neu) {
  final o = {for (final x in old) x.key: x};
  final n = {for (final x in neu) x.key: x};
  final out = <Change>[];
  for (final x in neu) {
    final b = o[x.key];
    if (b == null) {
      out.add(Change('baru', x.name, 'Produk baru di ${x.sheet} · ${rp(x.grosir)}'));
      continue;
    }
    if (b.grosir != x.grosir || b.ds != x.ds) {
      out.add(Change('harga', x.name,
          'Grosir ${rp(b.grosir)} → ${rp(x.grosir)} · DS ${rp(b.ds)} → ${rp(x.ds)}'));
    }
    if (!b.sold && x.sold) out.add(Change('sold', x.name, 'Ditandai SOLD'));
    if (b.sold && !x.sold) out.add(Change('tersedia', x.name, 'Tersedia lagi (SOLD dihapus)'));
    if (b.variants.join('|') != x.variants.join('|')) {
      out.add(Change('varian', x.name, 'Varian berubah: ${x.variants.join(', ')}'));
    }
  }
  for (final x in old) {
    if (!n.containsKey(x.key)) out.add(Change('hapus', x.name, 'Dihapus dari katalog (${x.sheet})'));
  }
  return out;
}
