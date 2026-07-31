// =============================================================================
// Media Downloader Flutter App - Version 2.0
// =============================================================================
// A comprehensive video downloader app supporting YouTube, TikTok, Instagram,
// Twitter, Facebook, and many other platforms.
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
// Configuration
// =============================================================================
const String _kApiUrlKey = 'api_base_url';
// تم تعيين رابط سيرفرك الخاص على Render كافتراضي
const String _kDefaultApiUrl = 'https://media-downloader-api-xndz.onrender.com/';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
// Data Models
// =============================================================================

class VideoFormat {
  final String quality;
  final String qualityLabel;
  final String formatId;
  final String ext;
  final String? url;
  final int? filesize;
  final int? width;
  final int? height;
  final double? fps;
  final bool hasAudio;

  VideoFormat({
    required this.quality,
    required this.qualityLabel,
    required this.formatId,
    required this.ext,
    this.url,
    this.filesize,
    this.width,
    this.height,
    this.fps,
    this.hasAudio = false,
  });

  factory VideoFormat.fromJson(Map<String, dynamic> json) {
    return VideoFormat(
      quality: json['quality'] ?? 'unknown',
      qualityLabel: json['quality_label'] ?? json['quality'] ?? 'unknown',
      formatId: json['format_id'] ?? 'unknown',
      ext: json['ext'] ?? 'mp4',
      url: json['url'],
      filesize: json['filesize'],
      width: json['width'],
      height: json['height'],
      fps: json['fps']?.toDouble(),
      hasAudio: json['has_audio'] ?? false,
    );
  }

  String get displaySize {
    if (filesize == null || filesize == 0) return 'حجم غير معروف';
    final mb = filesize! / (1024 * 1024);
    if (mb < 1) return '${(filesize! / 1024).toStringAsFixed(0)} KB';
    return '${mb.toStringAsFixed(1)} MB';
  }
}

class VideoInfo {
  final String title;
  final int? duration;
  final String thumbnail;
  final String? uploader;
  final String platform;
  final String webpageUrl;
  final List<VideoFormat> formats;
  final VideoFormat? bestAudio;

  VideoInfo({
    required this.title,
    this.duration,
    required this.thumbnail,
    this.uploader,
    required this.platform,
    required this.webpageUrl,
    required this.formats,
    this.bestAudio,
  });

  factory VideoInfo.fromJson(Map<String, dynamic> json) {
    final formatsList = (json['formats'] as List? ?? [])
        .map((f) => VideoFormat.fromJson(f))
        .toList();

    return VideoInfo(
      title: json['title'] ?? 'فيديو بدون عنوان',
      duration: json['duration'],
      thumbnail: json['thumbnail'] ?? '',
      uploader: json['uploader'],
      platform: json['platform'] ?? 'ميديا',
      webpageUrl: json['webpage_url'] ?? '',
      formats: formatsList,
      bestAudio: json['best_audio'] != null
          ? VideoFormat.fromJson(json['best_audio'])
          : null,
    );
  }

  String get durationDisplay {
    if (duration == null) return '';
    final minutes = duration! ~/ 60;
    final seconds = duration! % 60;
    return '${minutes}m ${seconds}s';
  }
}

// =============================================================================
// Home Screen
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
  bool _isLoading = false;
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  int _receivedBytes = 0;
  int _totalBytes = 0;
  bool _apiOnline = true;
  bool _checkingApi = false;
  VideoInfo? _videoInfo;

  String get _normalizedApiUrl {
    return _apiBaseUrl.endsWith('/') ? _apiBaseUrl : '$_apiBaseUrl/';
  }

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _checkApiHealth();

    _intentSub = ReceiveSharingIntent.instance
        .getMediaStream()
        .listen(_processSharedFiles, onError: _onIntentError);

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
    _checkApiHealth();
  }

  Future<void> _saveApiUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kApiUrlKey, url);
    setState(() => _apiBaseUrl = url);
  }

  Future<void> _checkApiHealth() async {
    setState(() => _checkingApi = true);
    try {
      final response = await http
          .get(
            Uri.parse('${_normalizedApiUrl}health'),
          )
          .timeout(const Duration(seconds: 10));

      setState(() {
        _apiOnline = response.statusCode == 200;
        _checkingApi = false;
        _lastStatus = _apiOnline ? 'متصل بالسيرفر الخاص ✓' : 'فشل الاتصال بالسيرفر';
      });
    } catch (e) {
      setState(() {
        _apiOnline = false;
        _checkingApi = false;
        _lastStatus = 'فشل الاتصال: ${e.toString().substring(0, min(50, e.toString().length))}';
      });
    }
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
      _videoInfo = null;
    });

    _fetchVideoInfo(url);
  }

  String? _extractUrl(String text) {
    final reg = RegExp(r'https?://[^\s\u0000-\u001F]+', caseSensitive: false);
    final m = reg.firstMatch(text);
    if (m == null) return null;
    var url = m.group(0)!;
    while (url.isNotEmpty &&
        !RegExp(r'^[a-zA-Z]').hasMatch(url[0]) &&
        !url.startsWith('http')) {
      url = url.substring(1);
    }
    while (url.isNotEmpty && '.,;!?)]}\'"'.contains(url[url.length - 1])) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  Future<void> _fetchVideoInfo(String url) async {
    setState(() {
      _isLoading = true;
      _lastStatus = 'جارٍ معالجة رابط الميديا...';
    });

    try {
      final response = await http.post(
        Uri.parse('${_normalizedApiUrl}extract'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'url': url, 'audio_only': false}),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == 'success' || data['url'] != null) {
          final title = data['title'] ?? 'Media Video';
          final directUrl = data['url'];
          final ext = data['ext'] ?? 'mp4';

          final info = VideoInfo(
            title: title,
            thumbnail: data['thumbnail'] ?? '',
            platform: data['site'] ?? 'Direct',
            webpageUrl: url,
            formats: [
              VideoFormat(
                quality: 'best',
                qualityLabel: 'جودة عالية (MP4)',
                formatId: 'best',
                ext: ext,
                url: directUrl,
              )
            ],
            bestAudio: VideoFormat(
              quality: 'audio',
              qualityLabel: 'صوت (MP3)',
              formatId: 'audio',
              ext: 'mp3',
            ),
          );

          setState(() {
            _videoInfo = info;
            _isLoading = false;
            _lastStatus = 'تم تجهيز رابط التحميل ✓';
          });

          if (mounted) {
            _showQualitySelectionSheet(url);
          }
        } else {
          throw Exception(data['error'] ?? 'فشل استخراج الفيديو');
        }
      } else {
        throw Exception('HTTP ${response.statusCode}');
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _lastStatus = 'فشل معالجة الرابط: ${e.toString()}';
      });
      _toast('فشل جلب معلومات التحميل');
    }
  }

  Future<void> _showQualitySelectionSheet(String url) async {
    if (_videoInfo == null) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => QualitySelectionSheet(
        videoInfo: _videoInfo!,
        onQualitySelected: (quality, audioOnly) {
          Navigator.pop(context);
          _startDownload(url, quality: quality, audioOnly: audioOnly);
        },
        onCancel: () => Navigator.pop(context),
      ),
    );
  }

  Future<void> _startDownload(String url, {required String quality, required bool audioOnly}) async {
    if (_isDownloading) {
      _toast('يوجد تنزيل قيد التنفيذ بالفعل');
      return;
    }

    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.every((r) => r == ConnectivityResult.none)) {
      _toast('لا يوجد اتصال إنترنت');
      return;
    }

    final ok = await _ensurePermissions();
    if (!ok) {
      _toast('يجب منح صلاحيات التخزين');
      return;
    }

    setState(() {
      _isDownloading = true;
      _downloadProgress = 0.0;
      _receivedBytes = 0;
      _totalBytes = 0;
      _lastStatus = audioOnly ? 'جارٍ تحميل الصوت...' : 'جارٍ تحميل الفيديو...';
    });

    File? outFile;
    try {
      final extractResponse = await http.post(
        Uri.parse('${_normalizedApiUrl}extract'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'url': url,
          'quality': quality,
          'audio_only': audioOnly,
        }),
      ).timeout(const Duration(seconds: 30));

      if (extractResponse.statusCode != 200) {
        throw Exception('Failed to extract URL: HTTP ${extractResponse.statusCode}');
      }

      final extractData = jsonDecode(extractResponse.body);
      final directUrl = extractData['url'] as String?;
      if (directUrl == null) {
        throw Exception(extractData['error'] ?? 'تعذر الحصول على رابط التنزيل المباشر');
      }

      final ext = audioOnly ? 'mp3' : (extractData['ext'] ?? 'mp4');
      final title = extractData['title'] ?? 'Media_File';

      final dir = await _downloadsDir();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final safeTitle = title.replaceAll(RegExp(r'[<>"/\\|?*]'), '_');
      final truncatedTitle = safeTitle.substring(0, min(30, safeTitle.length));
      outFile = File('${dir.path}/${truncatedTitle}_$ts.$ext');

      await _streamDownload(directUrl, outFile);

      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _downloadProgress = 0.0;
        _lastStatus = 'تم الحفظ في المعرض / التنزيلات';
      });
      _toast('تم التحميل بنجاح ✓');
    } catch (e, st) {
      debugPrint('Download error: $e\n$st');
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _downloadProgress = 0.0;
        _lastStatus = 'فشل التحميل المباشر';
      });
      _toast('فشل التحميل - جاري الفتح عبر المتصفح');
      try {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      } catch (_) {}
    }
  }

  Future<void> _streamDownload(String url, File outFile) async {
    final request = http.Request('GET', Uri.parse(url));
    final response = await request.send().timeout(const Duration(minutes: 15));

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }

    final total = response.contentLength ?? 0;
    var received = 0;
    final completer = Completer<void>();
    final sink = outFile.openWrite();

    if (mounted) {
      setState(() => _totalBytes = total);
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

  Future<void> _openSettings() async {
    final controller = TextEditingController(text: _apiBaseUrl);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إعدادات السيرفر (API)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'رابط سيرفر Render الخاص بك مضبوط تلقائياً.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'رابط الـ API',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => controller.text = _kDefaultApiUrl,
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
      _toast('تم حفظ الإعدادات ✓');
    }
  }

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
              if (_isLoading)
                const _LoadingCard()
              else if (_isDownloading)
                _ProgressCard(
                  progress: _downloadProgress,
                  received: _receivedBytes,
                  total: _totalBytes,
                  status: _lastStatus,
                ),
              if (_isLoading || _isDownloading) const SizedBox(height: 16),
              _StatusCard(
                status: _lastStatus,
                apiOnline: _apiOnline,
                lastUrl: _lastUrl,
                apiBaseUrl: _normalizedApiUrl,
                isChecking: _checkingApi,
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _checkingApi ? null : _checkApiHealth,
                    icon: _checkingApi
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.wifi_find, size: 18),
                    label: const Text('فحص السيرفر'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _showManualInput,
                    icon: const Icon(Icons.link, size: 18),
                    label: const Text('تحميل رابط يدوي'),
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
        title: const Text('لصق رابط للتنزيل'),
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
            child: const Text('تنزيل'),
          ),
        ],
      ),
    );
    if (url != null && url.isNotEmpty) {
      _handleSharedUrl(url);
    }
  }
}

// =============================================================================
// Quality Selection Sheet
// =============================================================================

class QualitySelectionSheet extends StatelessWidget {
  final VideoInfo videoInfo;
  final Function(String quality, bool audioOnly) onQualitySelected;
  final VoidCallback onCancel;

  const QualitySelectionSheet({
    super.key,
    required this.videoInfo,
    required this.onQualitySelected,
    required this.onCancel,
  });

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
            Text(
              videoInfo.title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 12),
            _QualityButton(
              icon: Icons.high_quality,
              label: 'تحميل الفيديو (MP4)',
              subtitle: 'أفضل جودة متوفرة',
              filled: true,
              onTap: () => onQualitySelected('best', false),
            ),
            const SizedBox(height: 8),
            _QualityButton(
              icon: Icons.music_note,
              label: 'تحميل الصوت فقط (MP3)',
              subtitle: 'ملف صوتي فقط',
              filled: false,
              onTap: () => onQualitySelected('audio', true),
            ),
            const SizedBox(height: 16),
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

class _QualityButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final bool filled;
  final VoidCallback onTap;

  const _QualityButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = filled
        ? Theme.of(context).colorScheme.onPrimary
        : Theme.of(context).colorScheme.primary;
    final bg = filled ? Theme.of(context).colorScheme.primary : Colors.transparent;

    return SizedBox(
      width: double.infinity,
      height: 56,
      child: filled
          ? ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: bg,
                foregroundColor: fg,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
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
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: onTap,
              child: _content(context, fg),
            ),
    );
  }

  Widget _content(BuildContext context, Color color) {
    return Row(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (subtitle != null)
                Text(
                  subtitle!,
                  style: TextStyle(
                    color: color.withOpacity(0.7),
                    fontSize: 11,
                  ),
                ),
            ],
          ),
        ),
        Icon(Icons.download, color: color.withOpacity(0.5), size: 18),
      ],
    );
  }
}

// =============================================================================
// UI Components
// =============================================================================

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'أهلاً بك 👋',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 4),
        Text(
          'شارك أي رابط من تيك توك، إنستغرام، يوتيوب، X، أو اضغط زر "تحميل رابط يدوي".',
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
      'تطبيق متصل بسيرفرك الخاص بنجاح • بدون إعلانات',
      textAlign: TextAlign.center,
      style: TextStyle(color: Colors.grey[600], fontSize: 12),
    );
  }
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.primaryContainer,
      child: const Padding(
        padding: EdgeInsets.all(16),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text('جارٍ معالجة التنزيل من السيرفر...'),
          ],
        ),
      ),
    );
  }
}

class _ProgressCard extends StatelessWidget {
  final double progress;
  final int received;
  final int total;
  final String status;

  const _ProgressCard({
    required this.progress,
    required this.received,
    required this.total,
    required this.status,
  });

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

class _StatusCard extends StatelessWidget {
  final String status;
  final bool apiOnline;
  final String lastUrl;
  final String apiBaseUrl;
  final bool isChecking;

  const _StatusCard({
    required this.status,
    required this.apiOnline,
    required this.lastUrl,
    required this.apiBaseUrl,
    required this.isChecking,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceVariant,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                isChecking
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        apiOnline ? Icons.check_circle : Icons.error_outline,
                        color: apiOnline ? Colors.green : Colors.orange,
                        size: 18,
                      ),
                const SizedBox(width: 6),
                const Text('حالة السيرفر', style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 6),
            Text(status, style: const TextStyle(fontSize: 13)),
            if (lastUrl.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text('آخر رابط:', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              SelectableText(
                lastUrl,
                style: const TextStyle(fontSize: 12),
              ),
            ],
            const SizedBox(height: 10),
            Text(
              'الـ API: $apiBaseUrl',
              style: TextStyle(fontSize: 11, color: Colors.grey[700]),
            ),
          ],
        ),
      ),
    );
  }
}

int min(int a, int b) => a < b ? a : b;
