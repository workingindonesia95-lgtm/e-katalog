// update.dart — pembaruan aplikasi otomatis (Windows).
//
// Alur: aplikasi → Google Apps Script (JSON versi terbaru) → GitHub Releases (zip).
// Hanya memakai dart:io + PowerShell bawaan Windows, tanpa paket tambahan.
//
// WAJIB: samakan kAppVersion dengan `version:` di pubspec.yaml setiap rilis.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show max;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

/// Versi aplikasi yang sedang berjalan.
const kAppVersion = '1.1.1';

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
    await _cleanup();
    await _check(context, silent: true);
  }

  /// Dipanggil dari tombol "Cek pembaruan aplikasi".
  static Future<void> checkManual(BuildContext context) =>
      _check(context, silent: false);

  static Future<void> _cleanup() async {
    try {
      if (await _work.exists()) await _work.delete(recursive: true);
    } catch (_) {}
  }

  static Future<void> _check(
    BuildContext context, {
    required bool silent,
  }) async {
    if (_busy || !Platform.isWindows) return;
    if (!_configured) {
      if (!silent)
        await _msg(
          context,
          'Alamat server pembaruan belum diisi (kUpdateEndpoint).',
        );
      return;
    }
    _busy = true;
    try {
      final info = await fetchLatest();
      if (!context.mounted) return;
      if (compareVersions(info.version, kAppVersion) <= 0) {
        if (!silent)
          await _msg(context, 'Aplikasi sudah versi terbaru (v$kAppVersion).');
        return;
      }
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => _UpdateDialog(info),
      );
    } catch (e) {
      debugPrint('[update] gagal cek: $e');
      if (!silent && context.mounted)
        await _msg(context, 'Gagal mengecek pembaruan.\n$e');
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
      if (res.statusCode != 200)
        throw HttpException('Server membalas HTTP ${res.statusCode}');
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

  static Future<void> _powershell(String cmd) async {
    final r = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      cmd,
    ]);
    if (r.exitCode != 0)
      throw ProcessException(
        'powershell',
        [],
        '${r.stderr}'.trim(),
        r.exitCode,
      );
  }

  /// Unduh → verifikasi → ekstrak → jalankan updater → keluar dari aplikasi.
  static Future<void> downloadAndInstall(
    UpdateInfo info,
    void Function(double? progress, String status) onProgress,
  ) async {
    final exe = Platform.resolvedExecutable;
    if (kDebugMode || exe.toLowerCase().contains('\\build\\windows')) {
      throw 'Mode pengembangan terdeteksi. Pembaruan otomatis hanya untuk aplikasi hasil build rilis.';
    }
    final appDir = File(exe).parent.path;
    final exeName = exe.split('\\').last;

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
      if (res.statusCode != 200)
        throw HttpException('Unduhan gagal (HTTP ${res.statusCode})');
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

    // 2) verifikasi hash (bila server memberikan)
    if (info.sha256 != null && info.sha256!.isNotEmpty) {
      onProgress(null, 'Memeriksa keaslian file…');
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "(Get-FileHash -LiteralPath '${_ps(zip.path)}' -Algorithm SHA256).Hash",
      ]);
      if ('${r.stdout}'.trim().toLowerCase() != info.sha256) {
        throw 'File pembaruan rusak atau tidak cocok. Coba lagi nanti.';
      }
    }

    // 3) ekstrak
    onProgress(null, 'Menyiapkan pembaruan…');
    await _powershell(
      "Expand-Archive -LiteralPath '${_ps(zip.path)}' -DestinationPath '${_ps(out.path)}' -Force",
    );
    var src = out;
    final kids = out.listSync();
    if (kids.length == 1 && kids.first is Directory)
      src = kids.first as Directory; // zip berisi 1 folder
    if (!File('${src.path}\\$exeName').existsSync()) {
      throw 'Isi pembaruan tidak sesuai (tidak ada $exeName).';
    }

    // 4) skrip updater: tunggu app tutup → salin → buka lagi
    final bat = File('${_work.path}\\apply.bat');
    await bat.writeAsString('''@echo off
chcp 65001 >nul
set /a n=0
:wait
tasklist /FI "IMAGENAME eq $exeName" 2>nul | find /I "$exeName" >nul
if errorlevel 1 goto copy
set /a n+=1
if %n% GEQ 40 goto fail
timeout /t 1 /nobreak >nul
goto wait
:copy
robocopy "${src.path}" "$appDir" /E /IS /IT /R:3 /W:1 >nul
if errorlevel 8 goto fail
start "" "$appDir\\$exeName"
exit /b 0
:fail
exit /b 1
''');
    onProgress(1, 'Memasang & memulai ulang…');
    await Process.start('cmd.exe', [
      '/c',
      bat.path,
    ], mode: ProcessStartMode.detached);
    await Future.delayed(const Duration(milliseconds: 400));
    exit(0);
  }

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
  double? _progress;
  String _status = '';
  String? _error;

  Future<void> _start() async {
    setState(() {
      _working = true;
      _error = null;
      _progress = 0;
    });
    try {
      await UpdateService.downloadAndInstall(widget.info, (p, s) {
        if (mounted)
          setState(() {
            _progress = p;
            _status = s;
          });
      });
    } catch (e) {
      if (mounted)
        setState(() {
          _working = false;
          _error = '$e';
        });
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
            child: Text(_error != null ? 'Coba lagi' : 'Perbarui sekarang'),
          ),
        ],
      ),
    );
  }
}
