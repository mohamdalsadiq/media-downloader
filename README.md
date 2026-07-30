# Media Downloader

تطبيق أندرويد (Flutter) لتنزيل الميديا والروابط من منصات التواصل عبر زر "مشاركة" في النظام.

## ✨ المميزات

- **استقبال روابط المشاركة** من تيك توك، إنستغرام، يوتيوب، X وغيرها (SEND + text/plain).
- **نافذة ModalBottomSheet** منبثقة من الأسفل بخيارين:
  - تحميل فيديو MP4 بأعلى جودة (بدون علامة مائية).
  - تحميل صوت MP3 فقط.
- **التنزيل في الخلفية** مع انتقال فوري للمستخدم للعودة لتصفحه.
- **v2: مدير تنزيل ذكي** للملفات المباشرة (APK / ZIP / PDF / MP4...).
- **100% مجاني وبدون إعلانات**.

## 🛠 الإصلاحات المطبَّقة في هذا الإصدار

| المشكلة | السبب | الحل |
|---|---|---|
| `error: resource android:style/Theme.Light.NoActionBar not found` | الثيم `@android:style/Theme.Light.NoActionBar` **لا يوجد** ضمن ثيمات نظام أندرويد (الموجود هو `Theme.Light.NoTitleBar`). | تم استبداله بـ `@style/LaunchTheme` و `@style/NormalTheme` المُعرَّفين في `res/values/styles.xml` و `res/values-night/styles.xml`، وكلاهما يرث من ثيم نظامي صحيح. |
| `flutter create` يمسح الملفات المخصصة | `flutter create` يستبدل `AndroidManifest.xml` وملفات res/. | تم تحديث `build.yml` ليحفظ **كل** الملفات المخصصة (Manifest, styles.xml, styles-night.xml, launch_background.xml, lib/main.dart, pubspec.yaml) ويستعيدها بعد `flutter create`. |
| صلاحيات ناقصة | لا توجد صلاحيات الإشعارات/التخزين/الشبكة اللازمة. | أُضيفت INTERNET, ACCESS_NETWORK_STATE, POST_NOTIFICATIONS, FOREGROUND_SERVICE, WRITE/READ_EXTERNAL_STORAGE مع `maxSdkVersion` مناسب لكل إصدار. |

## 📁 هيكل المشروع

```
media-downloader/
├── .github/workflows/build.yml          # بناء APK سحابي (Flutter 3.19 + Java 17)
├── android/
│   └── app/src/main/
│       ├── AndroidManifest.xml          # مُصلَح (يستخدم @style/LaunchTheme)
│       ├── kotlin/.../MainActivity.kt   # نقطة دخول Flutter
│       └── res/
│           ├── values/styles.xml        # ثيم فاتح (سطر 4-5 مهم: parent صحيح)
│           ├── values-night/styles.xml  # ثيم داكن
│           ├── drawable/launch_background.xml
│           └── drawable-v21/launch_background.xml
├── lib/main.dart                        # واجهة + منطق share intent + BottomSheet
└── pubspec.yaml                         # الحزم: receive_sharing_intent, url_launcher, ...
```

## 🚀 التشغيل

1. ارفع المشروع على GitHub.
2. افتح تبويب **Actions** في الريبو.
3. شغّل workflow **Build Flutter APK** (يدوياً عبر `workflow_dispatch`، أو تلقائياً عند push على `main`).
4. بعد انتهاء البناء، حمّل الـ artifact باسم **app-release**.
5. ثبّت `app-release.apk` على جهاز أندرويد.
6. افتح تيك توك/إنستغرام/يوتيوب، اضغط **مشاركة** → **Media Downloader**، ستظهر النافذة العائمة.

## 🔌 دمج yt-dlp لاحقاً (v1.1)

النسخة الحالية تُجري **محاكاة** للتنزيل (تحلّل الرابط وتكتب ملف placeholder). لدمج yt-dlp الحقيقي، استبدل دالة `_simulateOrDirectDownload` في `lib/main.dart` بنداء HTTP لنهايتك:

```dart
// مثال: استدعاء cobalt.tools (مفتوح المصدر ويستخدم yt-dlp)
final res = await http.post(
  Uri.parse('https://api.cobalt.tools/api/json'),
  headers: {'Accept': 'application/json', 'Content-Type': 'application/json'},
  body: jsonEncode({
    'url': url,
    'vQuality': '1080',
    'aFormat': 'mp3',
    'isAudioOnly': kind == DownloadKind.audio,
  }),
);
```

أو شغّل yt-dlp محلياً عبر Termux:API على نفس الجهاز.

## 📦 الحزم المستخدمة

| الحزمة | الغرض |
|---|---|
| `receive_sharing_intent` | استقبال روابط المشاركة من تطبيقات أخرى |
| `url_launcher` | فتح الروابط في المتصفح الخارجي |
| `path_provider` | مسار التخزين على الجهاز |
| `permission_handler` | صلاحيات التخزين والإشعارات |
| `http` | تنزيل الملفات المباشرة (v2) |
| `flutter_localizations` | دعم اللغة العربية (RTL) |

## 📄 الترخيص

مشروع شخصي — استخدمه بحرية.
