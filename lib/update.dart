// update.dart — pembaruan aplikasi otomatis (Windows).
//
// Alur: aplikasi → Google Apps Script (JSON versi terbaru) → GitHub Releases (zip).
// Paket diunduh & diekstrak di latar belakang; pemasangan = tutup, timpa, buka lagi
// (tersembunyi, tanpa jendela cmd). Butuh paket: archive, crypto, path.
//
// WAJIB: samakan kAppVersion dengan `version:` di pubspec.yaml setiap rilis.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' show max;

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as pth;

/// Versi aplikasi yang sedang berjalan.
const kAppVersion = '2.0.1';

/// URL Web App Apps Script (Deploy → Web app → Salin URL yang berakhiran /exec).
const kUpdateEndpoint =
    'https://script.google.com/macros/s/AKfycbwXBvpaEmOlscV6vUygVCL15z1uj_mf4p4CdDsHR_DtJX168YHtPB8zF9Hbr9uauaUf9Q/exec';

// ------------------------------------------------------------------ model

class UpdateInfo {
  UpdateInfo({
    required this.version,
    required this.url,
    this.size,
    this.sha256,
    this.notes = '',
    this.minVersion = '0.0.0',
    this.supplierWa = '',
  });

  final String version;
  final String url;
  final int? size;
  final String? sha256;
  final String notes;
  final String minVersion;
  final String supplierWa;

  /// Wajib update bila versi terpasang di bawah versi minimum.
  bool get mandatory => compareVersions(kAppVersion, minVersion) < 0;

  factory UpdateInfo.fromJson(Map<String, dynamic> m) => UpdateInfo(
    version: '${m['version']}',
    url: '${m['url']}',
    size: (m['size'] as num?)?.toInt(),
    sha256: (m['sha256'] as String?)?.toLowerCase(),
    notes: (m['notes'] as String?) ?? '',
    minVersion: (m['minVersion'] as String?) ?? '0.0.0',
    supplierWa: ((m['supplierWa'] as String?) ?? '').trim(),
  );
}

List<int> _parts(String v) => v
    .replaceFirst(RegExp(r'^[vV]'), '')
    .split('+')
    .first
    .split('-')
    .first
    .split('.')
    .map((e) => int.tryParse(e) ?? 0)
    .toList();

/// <0 bila a lebih lama dari b, 0 bila sama, >0 bila a lebih baru.
int compareVersions(String a, String b) {
  final x = _parts(a), y = _parts(b);
  for (var i = 0; i < max(x.length, y.length); i++) {
    final p = i < x.length ? x[i] : 0, q = i < y.length ? y[i] : 0;
    if (p != q) return p.compareTo(q);
  }
  return 0;
}

// ---------------------------------------------------------------- service

class UpdateService {
  static bool _busy = false;

  /// Dipanggil tiap kali info dari server terbaca; berisi nomor WhatsApp supplier
  /// bawaan (kosong bila tidak diatur di Apps Script).
  static void Function(String wa)? onSupplierWa;
  static final _work = Directory(
    '${Directory.systemTemp.path}\\katalog_update',
  );

  static bool get _configured => !kUpdateEndpoint.contains('GANTI_');

  /// Panggil sekali saat aplikasi dibuka. Diam bila gagal / tidak ada update.
  static Future<void> checkOnStart(BuildContext context) async {
    await _cleanupStale();
    if (!context.mounted) return;
    await _check(context, silent: true);
  }

  /// Dipanggil dari tombol "Cek pembaruan aplikasi".
  static Future<void> checkManual(BuildContext context) =>
      _check(context, silent: false);

  static File get _readyFile => File('${_work.path}\\ready.json');

  static Future<void> _cleanup() async {
    try {
      if (await _work.exists()) await _work.delete(recursive: true);
    } catch (_) {}
  }

  /// Saat aplikasi dibuka: hapus sisa pembaruan lama, tapi simpan paket yang
  /// sudah siap dan masih lebih baru dari versi terpasang.
  static Future<void> _cleanupStale() async {
    try {
      if (await _readyFile.exists()) {
        final m = jsonDecode(await _readyFile.readAsString()) as Map;
        if (compareVersions('${m['version']}', kAppVersion) > 0) return;
      }
    } catch (_) {}
    await _cleanup();
  }

  /// Folder paket versi [info] bila sudah diunduh & diekstrak (tinggal dipasang).
  static Future<String?> _stagedSrc(UpdateInfo info) async {
    try {
      if (!await _readyFile.exists()) return null;
      final m = jsonDecode(await _readyFile.readAsString()) as Map;
      final src = '${m['src']}';
      if ('${m['version']}' == info.version && Directory(src).existsSync()) {
        return src;
      }
    } catch (_) {}
    return null;
  }

  static Future<void> _check(
    BuildContext context, {
    required bool silent,
  }) async {
    if (_busy || !Platform.isWindows) return;
    if (!_configured) {
      if (!silent) {
        await _msg(
          context,
          'Alamat server pembaruan belum diisi (kUpdateEndpoint).',
        );
      }
      return;
    }
    _busy = true;
    try {
      final info = await fetchLatest();
      if (!context.mounted) return;
      if (compareVersions(info.version, kAppVersion) <= 0) {
        if (!silent) {
          await _msg(context, 'Aplikasi sudah versi terbaru (v$kAppVersion).');
        }
        return;
      }
      // Saat dibuka: unduh diam-diam di latar belakang, supaya begitu pengguna
      // menekan tombol, pembaruan langsung terpasang tanpa menunggu.
      if (silent && !info.mandatory && await _stagedSrc(info) == null) {
        await _stage(info, (_, _) {});
      }
      if (!context.mounted) return;
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => _UpdateDialog(info),
      );
    } catch (e) {
      debugPrint('[update] gagal cek: $e');
      if (!silent && context.mounted) {
        await _msg(context, 'Gagal mengecek pembaruan.\n$e');
      }
    } finally {
      _busy = false;
    }
  }

  static Future<void> _msg(BuildContext context, String text) => showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      content: Text(text),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('OK'),
        ),
      ],
    ),
  );

  /// Ambil info versi terbaru dari Apps Script.
  static Future<UpdateInfo> fetchLatest() async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await c.getUrl(Uri.parse(kUpdateEndpoint));
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        throw HttpException('Server membalas HTTP ${res.statusCode}');
      }
      final body = await res.transform(utf8.decoder).join();
      final m = jsonDecode(body) as Map<String, dynamic>;
      if (m['error'] != null) throw HttpException('${m['error']}');
      final info = UpdateInfo.fromJson(m);
      _checkHost(info.url);
      onSupplierWa?.call(info.supplierWa);
      return info;
    } finally {
      c.close(force: true);
    }
  }

  /// Pengaman: file pembaruan hanya boleh dari GitHub.
  static void _checkHost(String url) {
    final h = Uri.parse(url).host;
    final ok =
        Uri.parse(url).scheme == 'https' &&
        (h == 'github.com' || h.endsWith('.githubusercontent.com'));
    if (!ok) throw const HttpException('Alamat unduhan tidak dipercaya.');
  }

  static String _ps(String s) => s.replaceAll("'", "''");

  static void _ensureRelease() {
    final exe = Platform.resolvedExecutable;
    if (kDebugMode || exe.toLowerCase().contains('\\build\\windows')) {
      throw 'Mode pengembangan terdeteksi. Pembaruan otomatis hanya untuk aplikasi hasil build rilis.';
    }
  }

  /// Unduh → verifikasi → ekstrak ke folder sementara (tanpa menutup aplikasi).
  /// Hasilnya ditandai di ready.json agar tidak perlu diunduh ulang.
  static Future<String> _stage(
    UpdateInfo info,
    void Function(double? progress, String status) onProgress,
  ) async {
    _ensureRelease();
    final existing = await _stagedSrc(info);
    if (existing != null) return existing;

    final exeName = Platform.resolvedExecutable.split('\\').last;
    await _cleanup();
    await _work.create(recursive: true);
    final zip = File('${_work.path}\\update.zip');
    final out = Directory('${_work.path}\\new');

    // 1) unduh
    onProgress(0, 'Mengunduh…');
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await c.getUrl(Uri.parse(info.url));
      final res = await req.close();
      if (res.statusCode != 200) {
        throw HttpException('Unduhan gagal (HTTP ${res.statusCode})');
      }
      final total = res.contentLength > 0
          ? res.contentLength
          : (info.size ?? 0);
      final sink = zip.openWrite();
      var got = 0;
      await for (final chunk in res) {
        sink.add(chunk);
        got += chunk.length;
        onProgress(
          total > 0 ? got / total : null,
          'Mengunduh… ${_mb(got)}${total > 0 ? ' / ${_mb(total)}' : ''}',
        );
      }
      await sink.close();
    } finally {
      c.close(force: true);
    }

    // 2) verifikasi hash (di dalam Dart, tanpa PowerShell)
    if (info.sha256 != null && info.sha256!.isNotEmpty) {
      onProgress(null, 'Memeriksa keaslian file…');
      final digest = await sha256.bind(zip.openRead()).first;
      if ('$digest'.toLowerCase() != info.sha256) {
        throw 'File pembaruan rusak atau tidak cocok. Coba lagi nanti.';
      }
    }

    // 3) ekstrak di isolate terpisah (UI tidak macet)
    onProgress(null, 'Menyiapkan pembaruan…');
    final zipPath = zip.path, outPath = out.path;
    await Isolate.run(() {
      final arc = ZipDecoder().decodeBytes(File(zipPath).readAsBytesSync());
      for (final f in arc.files) {
        final target = pth.normalize(pth.join(outPath, f.name));
        if (!pth.isWithin(outPath, target)) continue; // tolak path berbahaya
        if (f.isFile) {
          File(target)
            ..createSync(recursive: true)
            ..writeAsBytesSync(f.content as List<int>);
        } else {
          Directory(target).createSync(recursive: true);
        }
      }
    });
    try {
      zip.deleteSync();
    } catch (_) {}

    var src = out;
    final kids = out.listSync();
    if (kids.length == 1 && kids.first is Directory) {
      src = kids.first as Directory; // zip berisi 1 folder
    }
    if (!File('${src.path}\\$exeName').existsSync()) {
      throw 'Isi pembaruan tidak sesuai (tidak ada $exeName).';
    }
    await _readyFile.writeAsString(
      jsonEncode({'version': info.version, 'src': src.path}),
    );
    return src.path;
  }

  /// Pasang paket yang sudah siap: aplikasi tutup, file ditimpa, lalu terbuka
  /// lagi otomatis. Berjalan tersembunyi (tanpa jendela cmd).
  static Future<void> _applyAndRestart(String src) async {
    _ensureRelease();
    final exe = Platform.resolvedExecutable;
    final appDir = File(exe).parent.path;
    final exeName = exe.split('\\').last;

    // PowerShell menunggu proses ini berakhir (instan, tanpa polling), lalu salin & buka.
    // BOM (\uFEFF) agar path dengan karakter non-ASCII terbaca benar.
    final ps1 = File('${_work.path}\\apply.ps1');
    await ps1.writeAsString(
      '\uFEFF\$ErrorActionPreference = "SilentlyContinue"\r\n'
      'Wait-Process -Id $pid -Timeout 30\r\n'
      "robocopy '${_ps(src)}' '${_ps(appDir)}' /E /IS /IT /R:3 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null\r\n"
      "if (\$LASTEXITCODE -lt 8) { Start-Process -FilePath '${_ps(appDir)}\\$exeName' }\r\n",
      encoding: utf8,
    );

    // wscript = aplikasi GUI, jadi tidak ada jendela konsol yang muncul sama sekali.
    final vbs = File('${_work.path}\\apply.vbs');
    await vbs.writeAsString(
      'CreateObject("WScript.Shell").Run '
      '"powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""${ps1.path}""", 0, False\r\n',
    );
    await Process.start('wscript.exe', [
      '//B',
      '//Nologo',
      vbs.path,
    ], mode: ProcessStartMode.detached);
    exit(0);
  }

  /// Dipanggil tombol "Perbarui": unduh (bila belum), lalu langsung pasang & mulai ulang.
  static Future<void> downloadAndInstall(
    UpdateInfo info,
    void Function(double? progress, String status) onProgress,
  ) async {
    final src = await _stage(info, onProgress);
    onProgress(1, 'Memulai ulang…');
    await _applyAndRestart(src);
  }

  /// Paket sudah diunduh sebelumnya (pemasangan akan instan)?
  static Future<bool> isStaged(UpdateInfo info) async =>
      await _stagedSrc(info) != null;

  static String _mb(int b) => '${(b / 1048576).toStringAsFixed(1)} MB';
}

// ----------------------------------------------------------------- dialog

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog(this.info);
  final UpdateInfo info;
  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool _working = false;
  bool _ready = false; // paket sudah diunduh → pemasangan instan
  double? _progress;
  String _status = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    UpdateService.isStaged(widget.info).then((v) {
      if (mounted && v) setState(() => _ready = true);
    });
  }

  Future<void> _start() async {
    setState(() {
      _working = true;
      _error = null;
      _progress = 0;
    });
    try {
      await UpdateService.downloadAndInstall(widget.info, (p, s) {
        if (mounted) {
          setState(() {
            _progress = p;
            _status = s;
          });
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _working = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.info;
    final cs = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_working && !i.mandatory,
      child: AlertDialog(
        title: Text(i.mandatory ? 'Pembaruan wajib' : 'Pembaruan tersedia'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'v$kAppVersion  →  v${i.version}'
                '${i.size != null ? '   (${UpdateService._mb(i.size!)})' : ''}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (i.mandatory) ...[
                const SizedBox(height: 6),
                Text(
                  'Versi ini sudah tidak didukung. Perbarui untuk melanjutkan.',
                  style: TextStyle(color: cs.error, fontSize: 13),
                ),
              ],
              if (i.notes.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                Flexible(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 180),
                    child: SingleChildScrollView(
                      child: Text(
                        i.notes.trim(),
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ),
                ),
              ],
              if (_working) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(value: _progress),
                const SizedBox(height: 6),
                Text(_status, style: const TextStyle(fontSize: 12)),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: cs.error, fontSize: 13)),
              ],
            ],
          ),
        ),
        actions: [
          if (!i.mandatory && !_working)
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Nanti'),
            ),
          FilledButton(
            onPressed: _working ? null : _start,
            child: Text(
              _error != null
                  ? 'Coba lagi'
                  : _ready
                  ? 'Mulai ulang & perbarui'
                  : 'Perbarui sekarang',
            ),
          ),
        ],
      ),
    );
  }
}
