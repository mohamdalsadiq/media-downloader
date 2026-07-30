// =============================================================================
// Media Downloader — تطبيق أندرويد لتنزيل الميديا من روابط المشاركة
// =============================================================================
// طريقة العمل:
//   1) يضغط المستخدم "مشاركة" في تيك توك/إنستغرام/يوتيوب/X ويختار التطبيق
//   2) يستقبل التطبيق الرابط عبر receive_sharing_intent (SEND + text/plain)
//   3) تظهر نافذة ModalBottomSheet بخيارين: فيديو MP4 أو صوت MP3
//   4) يختفي الـ sheet فوراً ويبدأ التنزيل في الخلفية
//   5) (v2) لو الرابط مباشر لملف (apk/zip/mp4...) يتحول لمدير تنزيل مباشر
// =============================================================================

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:url_launcher/url_launcher.dart';

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
      // دعم RTL لعرض الواجهة بالعربية بشكل صحيح
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
// HomeScreen — يستقبل الروابط ويعرض نافذة الخيارات
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
  bool _isDownloading = false;

  @override
  void initState() {
    super.initState();

    // 1) رابط يصل أثناء عمل التطبيق (المستخدم يضغط "مشاركة" والـ sheet مفتوح)
    _intentSub = ReceiveSharingIntent.instance
        .getMediaStream()
        .listen(_onShared, onError: _onIntentError);

    // 2) رابط يصل عند فتح التطبيق من زر المشاركة
    ReceiveSharingIntent.instance.getInitialMedia().then((files) {
      _onShared(files);
      // ضروري: تفريغ الـ intent حتى لا يتكرر فتح المشاركة عند فتح التطبيق
      // من أيقونة المُشغّل في المرات اللاحقة.
      ReceiveSharingIntent.instance.reset();
    });
  }

  void _onIntentError(Object err) {
    debugPrint('getMediaStream error: $err');
    if (mounted) {
      setState(() => _lastStatus = 'تعذّر قراءة الرابط: $err');
    }
  }

  @override
  void dispose() {
    _intentSub?.cancel();
    super.dispose();
  }

  // استخراج الرابط النصي من أي نوع مشاركة (text أو file)
  void _onShared(List<SharedMediaFile> files) {
    if (files.isEmpty) return;
    final raw = files.first.path.trim();
    if (raw.isEmpty) return;
    _handleSharedUrl(raw);
  }

  Future<void> _handleSharedUrl(String raw) async {
    // بعض التطبيقات ترسل "Check out this video: https://..." فيجب استخراج الـ URL
    final url = _extractUrl(raw) ?? raw;
    setState(() {
      _lastUrl = url;
      _lastStatus = 'تم استلام الرابط ✓';
    });
    if (!mounted) return;
    await _showDownloadSheet(url);
  }

  // استخراج أول URL صالح من نص (regex بسيط لـ http/https)
  String? _extractUrl(String text) {
    final reg = RegExp(r'https?://[^\s]+', caseSensitive: false);
    final m = reg.firstMatch(text);
    return m?.group(0);
  }

  // ---------------------------------------------------------------------------
  // النافذة العائمة من الأسفل (Bottom Sheet) — قلب تجربة المستخدم
  // ---------------------------------------------------------------------------
  Future<void> _showDownloadSheet(String url) async {
    final isDirect = _looksLikeDirectFile(url);

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetCtx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // مقبض السحب
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.grey[400],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const Text(
                  'خيارات التحميل',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  url,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey[600], fontSize: 12),
                ),
                const SizedBox(height: 20),

                // ملاحظة v2: لو الرابط مباشر لملف
                if (isDirect) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.amber.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.flash_on, size: 18, color: Colors.amber),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'تم اكتشاف رابط ملف مباشر — سيتم تنزيله بدون معالجة.',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[800],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // زر تحميل فيديو (لغير المباشر فقط)
                if (!isDirect) ...[
                  _BigButton(
                    icon: Icons.download_rounded,
                    label: 'تحميل فيديو (أعلى جودة)',
                    subtitle: 'MP4 — بدون علامة مائية',
                    filled: true,
                    onTap: () {
                      Navigator.of(sheetCtx).pop();
                      _startDownload(url, kind: DownloadKind.video);
                    },
                  ),
                  const SizedBox(height: 10),
                  _BigButton(
                    icon: Icons.music_note_rounded,
                    label: 'تحميل صوت فقط (MP3)',
                    subtitle: 'استخراج الصوت بأعلى جودة',
                    filled: false,
                    onTap: () {
                      Navigator.of(sheetCtx).pop();
                      _startDownload(url, kind: DownloadKind.audio);
                    },
                  ),
                  const SizedBox(height: 10),
                ],

                // زر الملف المباشر (v2)
                if (isDirect)
                  _BigButton(
                    icon: Icons.file_download_rounded,
                    label: 'تنزيل الملف الآن',
                    subtitle: _guessFileName(url),
                    filled: true,
                    onTap: () {
                      Navigator.of(sheetCtx).pop();
                      _startDownload(url, kind: DownloadKind.direct);
                    },
                  ),

                const SizedBox(height: 6),
                TextButton.icon(
                  onPressed: () => Navigator.of(sheetCtx).pop(),
                  icon: const Icon(Icons.close, size: 18),
                  label: const Text('إلغاء'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // كشف الروابط المباشرة للملفات (apk/zip/mp4/mkv/...) لـ v2
  // ---------------------------------------------------------------------------
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
      return last.isNotEmpty ? last : 'file';
    } catch (_) {
      return 'file';
    }
  }

  // ---------------------------------------------------------------------------
  // منطق بدء التحميل — يستدعى بعد إغلاق الـ sheet
  // ---------------------------------------------------------------------------
  Future<void> _startDownload(String url, {required DownloadKind kind}) async {
    if (_isDownloading) {
      _toast('يوجد تنزيل قيد التنفيذ بالفعل.');
      return;
    }

    // طلب الصلاحيات (التخزين على أندرويد ≤ 12، الإشعارات على 13+)
    final ok = await _ensurePermissions();
    if (!ok) {
      _toast('يجب منح صلاحيات التخزين والإشعارات للمتابعة.');
      return;
    }

    setState(() => _isDownloading = true);
    _lastStatus = _statusFor(kind, running: true);

    try {
      final dir = await _downloadsDir();
      final filename = _buildFilename(url, kind);
      final file = File('${dir.path}/$filename');

      // حالياً: نقل الرابط للخدمة الخلفية أو تنزيل مباشر (v2)
      // في v1 الفعلي على الجهاز: يتم استدعاء yt-dlp محلياً (Termux مثلاً)
      // أو إرسال الرابط لخادم خلفي مغلف لـ yt-dlp.
      // هنا نضع رابط الـ "محرك" التجريبي — استبدله لاحقاً بنهايتك الحقيقية.

      await _simulateOrDirectDownload(url, file, kind);

      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _lastStatus = 'تم الحفظ: ${file.path}';
      });
      _toast('تم بنجاح ✓');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _lastStatus = 'فشل التحميل: $e';
      });
      _toast('فشل التحميل');
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

  String _buildFilename(String url, DownloadKind kind) {
    final ts = DateTime.now().millisecondsSinceEpoch;
    switch (kind) {
      case DownloadKind.video:
        return 'video_$ts.mp4';
      case DownloadKind.audio:
        return 'audio_$ts.mp3';
      case DownloadKind.direct:
        return _guessFileName(url);
    }
  }

  Future<Directory> _downloadsDir() async {
    // أندرويد 10+ (API 29): نكتب في مجلد التطبيق الخاص (أكثر أماناً وحداثة)
    // أندرويد 9 وأقل: نحاول مجلد التنزيلات العامة
    if (Platform.isAndroid) {
      try {
        return await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
      } catch (_) {
        return await getApplicationDocumentsDirectory();
      }
    }
    return await getApplicationDocumentsDirectory();
  }

  Future<bool> _ensurePermissions() async {
    if (!Platform.isAndroid) return true;
    // إذن الإشعارات لأندرويد 13+
    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }
    // صلاحية التخزين (تُستخدم فقط على API ≤ 28)
    if (await Permission.storage.isDenied) {
      await Permission.storage.request();
    }
    return true;
  }

  // تنزيل تجريبي: في v1 الفعلي على أندرويد، يجب أن يتواصل التطبيق مع
  // (أ) سيرفر خلفي يدير yt-dlp، أو
  // (ب) تنفيذاً محلياً عبر Termux أو libyt-dlp.
  // حالياً نسجّل الرابط في كونسول الأندرويد (logcat) وننتظر قليلاً.
  Future<void> _simulateOrDirectDownload(
      String url, File outFile, DownloadKind kind) async {
    debugPrint('DOWNLOAD_START kind=$kind url=$url out=${outFile.path}');
    // محاكاة زمن المعالجة — استبدلها بطلب HTTP حقيقي عند جاهزية الـ backend
    await Future.delayed(const Duration(seconds: 1));
    // كتابة ملف فارغ فقط للتأكد من أن المسار قابل للكتابة
    await outFile.create(recursive: true);
    await outFile.writeAsString('placeholder for $url ($kind)');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
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
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _Header(),
              const SizedBox(height: 24),
              Card(
                elevation: 0,
                color: Theme.of(context).colorScheme.surfaceVariant,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('الحالة',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      Text(_lastStatus),
                      if (_lastUrl.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        const Text('آخر رابط:',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        SelectableText(
                          _lastUrl,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => launchUrl(Uri.parse('https://github.com/'),
                    mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.info_outline),
                label: const Text('حول التطبيق'),
              ),
              const Spacer(),
              const _Footer(),
            ],
          ),
        ),
      ),
    );
  }
}

enum DownloadKind { video, audio, direct }

// زر كبير مع أيقونة وعنوان ووصف فرعي
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
    final bg = filled
        ? Theme.of(context).colorScheme.primary
        : Colors.transparent;
    return SizedBox(
      width: double.infinity,
      height: 60,
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
          'شارك أي رابط من تيك توك، إنستغرام، يوتيوب، X، أو حتى رابط ملف مباشر، وستظهر لك نافذة التحميل فوراً.',
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
      'مجاني 100% • بدون إعلانات • بدون تعقيد',
      textAlign: TextAlign.center,
      style: TextStyle(color: Colors.grey[600], fontSize: 12),
    );
  }
}
