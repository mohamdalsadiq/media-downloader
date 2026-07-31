// =============================================================================
// Media Downloader — تطبيق أندرويد لتنزيل الميديا من روابط المشاركة
// =============================================================================
//   1) يستقبل الرابط من زر المشاركة في تيك توك/إنستغرام/يوتيوب/X
//   2) تظهر نافذة عائمة بخيارين: فيديو MP4 / صوت MP3
//   3) يستدعي الـ API المعرّف في الإعدادات (افتراضياً cobalt.tools)
//   4) لو فشل → fallback: يفتح الرابط في المتصفح
//
//   الإعدادات تسمح بتغيير الـ API إلى سيرفر خاص فيك (مثل yt-dlp على Render)
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

// =============================================================================
// مفاتيح الإعدادات + الافتراضات
// =============================================================================
const String _kApiUrlKey = 'api_base_url';
const String _kDefaultApiUrl = 'https://api.cobalt.tools/';

void main() {
  runApp(const MediaDownloaderApp());
}

class MediaDownloaderApp extends StatelessWidget {
  const MediaDownloaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Media Downloader',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('ar'), Locale('en')],
      locale: const Locale('ar'),
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4)),
        useMaterial3: true,
        fontFamily: 'sans',
      ),
      home: const HomeScreen(),
    );
  }
}

// =============================================================================
// HomeScreen
// =============================================================================
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  StreamSubscription? _intentSub;
  String _lastUrl = '';
  String _lastStatus = 'في انتظار مشاركة رابط...';
  String _apiBaseUrl = _kDefaultApiUrl;
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  int _receivedBytes = 0;
  int _totalBytes = 0;
  bool _apiOnline = true;
  bool _checkingApi = false;

  @override
  void initState() {
    super.initState();

    // تحميل الإعدادات المحفوظة
    _loadSettings();

    // 1) رابط يصل أثناء عمل التطبيق
    _intentSub = ReceiveSharingIntent.instance
        .getMediaStream()
        .listen(_processSharedFiles, onError: _onIntentError);

    // 2) رابط يصل عند فتح التطبيق من زر المشاركة
    ReceiveSharingIntent.instance.getInitialMedia().then((files) {
      if (!mounted) return;
      _processSharedFiles(files);
      ReceiveSharingIntent.instance.reset();
    });
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString(_kApiUrlKey);
    if (url != null && url.isNotEmpty) {
      setState(() => _apiBaseUrl = url);
    }
  }

  Future<void> _saveApiUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kApiUrlKey, url);
    setState(() => _apiBaseUrl = url);
  }

  void _onIntentError(Object err) {
    debugPrint('getMediaStream error: $err');
    if (mounted) {
      setState(() => _lastStatus = 'تعذّر قراءة المشاركة: $err');
    }
  }

  @override
  void dispose() {
    _intentSub?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // معالجة الملف/النص المشارك
  // ---------------------------------------------------------------------------
  void _processSharedFiles(List<SharedMediaFile> files) {
    if (files.isEmpty) return;
    final raw = files.first.path.trim();
    if (raw.isEmpty) return;
    _handleSharedUrl(raw);
  }

  void _handleSharedUrl(String raw) {
    final url = _extractUrl(raw) ?? raw;
    setState(() {
      _lastUrl = url;
      _lastStatus = 'تم استلام الرابط ✓';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _showDownloadSheet(url);
      }
    });
  }

  String? _extractUrl(String text) {
    // ابحث عن أول URL صالح (http/https)
    final reg = RegExp(r'https?://[^\s\u0000-\u001F]+', caseSensitive: false);
    final m = reg.firstMatch(text);
    if (m == null) return null;
    var url = m.group(0)!;
    // إزالة أي علامات ترتيب في البداية (=, :, فاصلة، إلخ)
    while (url.isNotEmpty &&
        !RegExp(r'^[a-zA-Z]').hasMatch(url[0]) &&
        !url.startsWith('http')) {
      url = url.substring(1);
    }
    // إزالة علامات في النهاية (.,;!? إلخ)
    while (url.isNotEmpty && '.,;!?)]}\'"'.contains(url[url.length - 1])) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  // ---------------------------------------------------------------------------
  // النافذة العائمة
  // ---------------------------------------------------------------------------
  Future<void> _showDownloadSheet(String url) async {
    final isDirect = _looksLikeDirectFile(url);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) => _DownloadSheet(
        url: url,
        isDirect: isDirect,
        onVideo: () {
          Navigator.of(sheetCtx).pop();
          _startDownload(url, kind: DownloadKind.video);
        },
        onAudio: () {
          Navigator.of(sheetCtx).pop();
          _startDownload(url, kind: DownloadKind.audio);
        },
        onDirect: () {
          Navigator.of(sheetCtx).pop();
          _startDownload(url, kind: DownloadKind.direct);
        },
        onOpenInBrowser: () {
          Navigator.of(sheetCtx).pop();
          launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
        },
        onCancel: () => Navigator.of(sheetCtx).pop(),
      ),
    );
  }

  bool _looksLikeDirectFile(String url) {
    final lower = url.toLowerCase().split('?').first;
    const exts = [
      '.apk', '.zip', '.rar', '.7z',
      '.mp4', '.mkv', '.mov', '.avi', '.webm',
      '.mp3', '.m4a', '.flac', '.wav',
      '.pdf', '.jpg', '.png', '.jpeg',
    ];
    return exts.any(lower.endsWith);
  }

  String _guessFileName(String url) {
    try {
      final uri = Uri.parse(url);
      final last = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : 'file';
      return (last.isNotEmpty ? last : 'file').split('?').first;
    } catch (_) {
      return 'file';
    }
  }

  // ---------------------------------------------------------------------------
  // اختبار اتصال الـ API
  // ---------------------------------------------------------------------------
  Future<void> _testApi() async {
    setState(() => _checkingApi = true);
    try {
      final connectivity = await Connectivity().checkConnectivity();
      final hasNet = connectivity.any((r) => r != ConnectivityResult.none);
      if (!hasNet) {
        setState(() {
          _apiOnline = false;
          _checkingApi = false;
          _lastStatus = 'لا يوجد اتصال إنترنت على الجهاز';
        });
        return;
      }
      // جرّب ping بسيط على الـ API
      final res = await http
          .get(Uri.parse(_apiBaseUrl), headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 10));
      setState(() {
        _apiOnline = res.statusCode < 500;
        _checkingApi = false;
        _lastStatus = _apiOnline
            ? '✓ الـ API شغّال (HTTP ${res.statusCode})'
            : '⚠ الـ API راجع خطأ: HTTP ${res.statusCode}';
      });
    } catch (e) {
      setState(() {
        _apiOnline = false;
        _checkingApi = false;
        _lastStatus = '✗ لا يمكن الوصول للـ API: ${_shortError(e)}';
      });
    }
  }

  String _shortError(Object e) {
    final s = e.toString();
    if (s.length > 120) return '${s.substring(0, 120)}…';
    return s;
  }

  // ---------------------------------------------------------------------------
  // منطق التحميل
  // ---------------------------------------------------------------------------
  Future<void> _startDownload(String url, {required DownloadKind kind}) async {
    if (_isDownloading) {
      _toast('يوجد تنزيل قيد التنفيذ بالفعل.');
      return;
    }

    // 1) فحص الاتصال
    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.every((r) => r == ConnectivityResult.none)) {
      _toast('لا يوجد اتصال إنترنت. شغّل الواي فاي أو البيانات.');
      return;
    }

    // 2) فحص الصلاحيات
    final ok = await _ensurePermissions();
    if (!ok) {
      _toast('يجب منح صلاحيات التخزين والإشعارات للمتابعة.');
      return;
    }

    setState(() {
      _isDownloading = true;
      _downloadProgress = 0.0;
      _receivedBytes = 0;
      _totalBytes = 0;
      _lastStatus = _statusFor(kind, running: true);
    });

    File? outFile;
    try {
      final dir = await _downloadsDir();
      final ts = DateTime.now().millisecondsSinceEpoch;

      if (kind == DownloadKind.direct) {
        outFile = File('${dir.path}/${_guessFileName(url)}');
        await _streamDownload(url, outFile);
      } else {
        final directUrl =
            await _cobaltExtract(url, audioOnly: kind == DownloadKind.audio);
        final ext = kind == DownloadKind.audio ? 'mp3' : 'mp4';
        outFile = File('${dir.path}/media_$ts.$ext');
        await _streamDownload(directUrl, outFile);
      }

      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _downloadProgress = 0.0;
        _lastStatus = 'تم الحفظ: ${outFile!.path}';
      });
      _toast('تم بنجاح ✓');
    } catch (e, st) {
      debugPrint('Download error: $e\n$st');
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _downloadProgress = 0.0;
        _lastStatus = 'فشل التحميل: ${_shortError(e)}';
      });
      // Fallback: افتح الرابط في المتصفح
      _toast('فشل — سيتم فتح المتصفح');
      try {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      } catch (_) {}
    }
  }

  String _statusFor(DownloadKind k, {required bool running}) {
    final verb = running ? 'جارٍ التحميل' : 'اكتمل التحميل';
    switch (k) {
      case DownloadKind.video:
        return '$verb (فيديو MP4)...';
      case DownloadKind.audio:
        return '$verb (صوت MP3)...';
      case DownloadKind.direct:
        return '$verb (ملف مباشر)...';
    }
  }

  // ---------------------------------------------------------------------------
  // استدعاء الـ API (افتراضياً cobalt.tools، أو سيرفر مخصّص)
  // ---------------------------------------------------------------------------
  Future<String> _cobaltExtract(String url, {required bool audioOnly}) async {
    final body = jsonEncode({
      'url': url,
      'videoQuality': '1080',
      'audioFormat': 'mp3',
      'downloadMode': audioOnly ? 'audio' : 'auto',
      'filenameStyle': 'classic',
    });

    final apiUri = Uri.parse(_apiBaseUrl);
    final response = await http
        .post(apiUri, headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        }, body: body)
        .timeout(const Duration(seconds: 30));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('API HTTP ${response.statusCode}\n${_shortError(response.body)}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final status = (data['status'] as String?) ?? '';
    if (status == 'redirect' || status == 'tunnel') {
      return data['url'] as String;
    } else if (status == 'picker') {
      final picker = data['picker'] as List?;
      if (picker != null && picker.isNotEmpty) {
        return picker.first['url'] as String;
      }
      throw Exception('لم يتم العثور على رابط مباشر');
    } else {
      throw Exception('API status: $status — ${data['text'] ?? ''}');
    }
  }

  // ---------------------------------------------------------------------------
  // تنزيل HTTP مع شريط تقدّم
  // ---------------------------------------------------------------------------
  Future<void> _streamDownload(String url, File outFile) async {
    final request = http.Request('GET', Uri.parse(url));
    final response =
        await request.send().timeout(const Duration(minutes: 15));

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }

    final total = response.contentLength ?? 0;
    var received = 0;
    final completer = Completer<void>();
    final sink = outFile.openWrite();

    if (mounted) {
      setState(() {
        _totalBytes = total;
      });
    }

    response.stream.listen(
      (chunk) {
        sink.add(chunk);
        received += chunk.length;
        if (mounted) {
          setState(() {
            _receivedBytes = received;
            _downloadProgress = total > 0 ? received / total : 0.0;
          });
        }
      },
      onDone: () async {
        await sink.close();
        if (!completer.isCompleted) completer.complete();
      },
      onError: (e) {
        sink.close();
        if (!completer.isCompleted) completer.completeError(e);
      },
      cancelOnError: true,
    );

    return completer.future;
  }

  Future<Directory> _downloadsDir() async {
    if (Platform.isAndroid) {
      try {
        return await getExternalStorageDirectory() ??
            await getApplicationDocumentsDirectory();
      } catch (_) {
        return await getApplicationDocumentsDirectory();
      }
    }
    return await getApplicationDocumentsDirectory();
  }

  Future<bool> _ensurePermissions() async {
    if (!Platform.isAndroid) return true;
    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }
    if (await Permission.storage.isDenied) {
      await Permission.storage.request();
    }
    return true;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  // ---------------------------------------------------------------------------
  // الإعدادات (تغيير رابط الـ API)
  // ---------------------------------------------------------------------------
  Future<void> _openSettings() async {
    final controller = TextEditingController(text: _apiBaseUrl);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إعدادات الـ API'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'أدخل رابط السيرفر الخلفي الذي يستخدم yt-dlp.\n'
              'الافتراضي: cobalt.tools (مجاني لكن قد يكون محجوباً).\n\n'
              'للحصول على سيرفر خاص، انشر المشروع المرفق yt-dlp-server '
              'على Render.com (مجاني).',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'رابط الـ API',
                border: OutlineInputBorder(),
                hintText: 'https://your-server.onrender.com/',
              ),
              keyboardType: TextInputType.url,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              controller.text = _kDefaultApiUrl;
            },
            child: const Text('استعادة الافتراضي'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      await _saveApiUrl(result);
      _toast('تم الحفظ ✓');
      // اختبار بعد الحفظ
      _testApi();
    }
  }

  // ---------------------------------------------------------------------------
  // شرح كيفية تشغيل سيرفر خاص
  // ---------------------------------------------------------------------------
  Future<void> _showServerGuide() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('سيرفر yt-dlp خاص'),
        content: const SingleChildScrollView(
          child: Text(
            'لماذا تحتاج سيرفر خاص؟\n'
            '• cobalt.tools قد يكون محجوباً في بعض الدول\n'
            '• سيرفرك يكون أسرع وأكثر استقراراً\n'
            '• تتحكم في الإعدادات بنفسك\n\n'
            '────────────────────────────────────\n\n'
            'خطوات النشر (مجاني على Render.com):\n\n'
            '1) ارفع مجلد yt-dlp-server/ على GitHub\n'
            '2) ادخل render.com → New Web Service\n'
            '3) اختر الريبو → اضغط Deploy\n'
            '4) انسخ الرابط (مثل: my-app.onrender.com)\n'
            '5) في التطبيق: افتح الإعدادات والصق الرابط\n\n'
            '────────────────────────────────────\n\n'
            'بعدها التطبيق يتصل بسيرفرك الخاص بدل cobalt،\n'
            'وتقدر تنزّل بلا قيود أو حجب.',
            style: TextStyle(fontSize: 13),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('حسناً'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // الواجهة الرئيسية
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('مُنزّل الميديا'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'إعدادات الـ API',
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _Header(),
              const SizedBox(height: 20),
              if (_isDownloading) _ProgressCard(
                progress: _downloadProgress,
                received: _receivedBytes,
                total: _totalBytes,
                status: _lastStatus,
              ),
              if (_isDownloading) const SizedBox(height: 16),
              Card(
                elevation: 0,
                color: Theme.of(context).colorScheme.surfaceVariant,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _apiOnline
                                ? Icons.check_circle
                                : Icons.error_outline,
                            color: _apiOnline ? Colors.green : Colors.orange,
                            size: 18,
                          ),
                          const SizedBox(width: 6),
                          const Text('الحالة',
                              style: TextStyle(fontWeight: FontWeight.bold)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(_lastStatus,
                          style: const TextStyle(fontSize: 13)),
                      if (_lastUrl.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        const Text('آخر رابط:',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        SelectableText(
                          _lastUrl,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                      const SizedBox(height: 10),
                      Text(
                        'الـ API: $_apiBaseUrl',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey[700],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _checkingApi ? null : _testApi,
                    icon: _checkingApi
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.wifi_find, size: 18),
                    label: const Text('اختبار الاتصال'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _showManualInput,
                    icon: const Icon(Icons.link, size: 18),
                    label: const Text('اختبار برابط يدوي'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _openSettings,
                    icon: const Icon(Icons.tune, size: 18),
                    label: const Text('إعدادات API'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _showServerGuide,
                    icon: const Icon(Icons.cloud_outlined, size: 18),
                    label: const Text('سيرفر خاص'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _isDownloading
                        ? null
                        : () {
                            setState(() {
                              _lastUrl = '';
                              _lastStatus = 'في انتظار مشاركة رابط...';
                            });
                          },
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('إعادة'),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              const _Footer(),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showManualInput() async {
    final controller = TextEditingController(text: _lastUrl);
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('اختبار برابط'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'https://vt.tiktok.com/...',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.url,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('متابعة'),
          ),
        ],
      ),
    );
    if (url != null && url.isNotEmpty) {
      _handleSharedUrl(url);
    }
  }
}

enum DownloadKind { video, audio, direct }

// =============================================================================
// بطاقة التقدّم
// =============================================================================
class _ProgressCard extends StatelessWidget {
  const _ProgressCard({
    required this.progress,
    required this.received,
    required this.total,
    required this.status,
  });

  final double progress;
  final int received;
  final int total;
  final String status;

  @override
  Widget build(BuildContext context) {
    final pct = (progress * 100).toStringAsFixed(0);
    final mb = (received / 1024 / 1024).toStringAsFixed(1);
    final totalMb = total > 0 ? (total / 1024 / 1024).toStringAsFixed(1) : '?';
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    value: total > 0 ? progress : null,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    status,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(value: total > 0 ? progress : null),
            const SizedBox(height: 6),
            Text(
              total > 0 ? '$pct%  •  $mb / $totalMb MB' : '$mb MB تم تنزيلها',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// النافذة العائمة
// =============================================================================
class _DownloadSheet extends StatelessWidget {
  const _DownloadSheet({
    required this.url,
    required this.isDirect,
    required this.onVideo,
    required this.onAudio,
    required this.onDirect,
    required this.onOpenInBrowser,
    required this.onCancel,
  });

  final String url;
  final bool isDirect;
  final VoidCallback onVideo;
  final VoidCallback onAudio;
  final VoidCallback onDirect;
  final VoidCallback onOpenInBrowser;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.grey[400],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Text('خيارات التحميل',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(
              url,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
            ),
            const SizedBox(height: 20),
            if (isDirect)
              _BigButton(
                icon: Icons.file_download_rounded,
                label: 'تنزيل الملف الآن',
                subtitle: 'رابط مباشر لملف',
                filled: true,
                onTap: onDirect,
              )
            else ...[
              _BigButton(
                icon: Icons.download_rounded,
                label: 'تحميل فيديو (أعلى جودة)',
                subtitle: 'MP4 — بدون علامة مائية',
                filled: true,
                onTap: onVideo,
              ),
              const SizedBox(height: 10),
              _BigButton(
                icon: Icons.music_note_rounded,
                label: 'تحميل صوت فقط (MP3)',
                subtitle: 'استخراج الصوت بأعلى جودة',
                filled: false,
                onTap: onAudio,
              ),
            ],
            const SizedBox(height: 14),
            TextButton.icon(
              onPressed: onOpenInBrowser,
              icon: const Icon(Icons.open_in_browser, size: 18),
              label: const Text('فتح في المتصفح'),
            ),
            TextButton.icon(
              onPressed: onCancel,
              icon: const Icon(Icons.close, size: 18),
              label: const Text('إلغاء'),
            ),
          ],
        ),
      ),
    );
  }
}

class _BigButton extends StatelessWidget {
  const _BigButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
    this.filled = true,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final bool filled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = filled
        ? Theme.of(context).colorScheme.onPrimary
        : Theme.of(context).colorScheme.primary;
    final bg = filled ? Theme.of(context).colorScheme.primary : Colors.transparent;
    return SizedBox(
      width: double.infinity,
      height: 64,
      child: filled
          ? ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: bg,
                foregroundColor: fg,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: onTap,
              child: _content(context, fg),
            )
          : OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: fg,
                side: BorderSide(color: Theme.of(context).colorScheme.primary),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: onTap,
              child: _content(context, fg),
            ),
    );
  }

  Widget _content(BuildContext context, Color color) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, color: color),
        const SizedBox(width: 10),
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(color: color, fontSize: 15)),
            if (subtitle != null)
              Text(subtitle!,
                  style: TextStyle(color: color.withOpacity(0.75), fontSize: 11)),
          ],
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('أهلاً بك 👋',
            style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          'شارك أي رابط من تيك توك، إنستغرام، يوتيوب، X، أو حتى ملف مباشر. النافذة ستظهر فوراً.',
          style: TextStyle(color: Colors.grey[700], fontSize: 14),
        ),
      ],
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer();
  @override
  Widget build(BuildContext context) {
    return Text(
      'مجاني 100% • بدون إعلانات • افتح "إعدادات API" لاستخدام سيرفر خاص',
      textAlign: TextAlign.center,
      style: TextStyle(color: Colors.grey[600], fontSize: 12),
    );
  }
}
