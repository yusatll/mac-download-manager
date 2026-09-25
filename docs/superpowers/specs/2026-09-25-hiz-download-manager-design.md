# Hiz Download Manager (HDM) — Tasarım Belgesi

- **Tarih:** 2026-09-25
- **Durum:** İnceleme bekliyor
- **Lisans:** MIT
- **Platform:** macOS 14 (Sonoma) ve üzeri, Universal (Apple Silicon + Intel)

## 1. Amaç

Windows'taki Internet Download Manager'ın (IDM) macOS için açık kaynak bir karşılığı. IDM'in düzeni ve iş akışı korunur (araç çubuğu, kategori ağacı, sütunlu liste, segmentli ilerleme penceresi, tarayıcıdan otomatik yakalama, video paneli); kontroller native macOS'tur. IDM'in adı, logosu ve ikonları kullanılmaz.

Hedef kitle: Windows'tan Mac'e geçmiş ve IDM'i özleyen kullanıcılar. Proje GitHub'da yayınlanacak, başkaları kurup kullanabilecek ve katkı verebilecek.

### Başarı ölçütleri

1. Chrome, Brave ve Safari'de bir dosya linkine tıklanınca "Dosya İndirme Bilgisi" penceresi açılır; dosya çok bağlantıyla, tarayıcının kendi indirmesinden belirgin şekilde hızlı iner.
2. Durdurulan bir indirme, uygulama kapatılıp açıldıktan sonra da kaldığı yerden devam eder.
3. YouTube'da ve standart video (mp4/webm/HLS/DASH) oynatan sitelerde videonun üzerinde "Bu videoyu indir" butonu çıkar; kalite seçilip indirilebilir.
4. GitHub Releases'tan indirilen notarize edilmiş DMG, temiz bir Mac'te Gatekeeper uyarısı olmadan kurulur; Safari uzantısı "İmzasız uzantılara izin ver" açmadan etkinleştirilebilir.

## 2. Kapsam

**Bu tur (4 aşama):**
1. İndirme motoru + ana pencere
2. Tarayıcı entegrasyonu (Chrome/Brave/diğer Chromium + Safari)
3. Video paneli + yardımcı program yöneticisi (yt-dlp, ffmpeg, deno)
4. Açık kaynak paketleme (README, CI, imzalı/notarize sürüm, otomatik güncelleme)

**Sonraki tur:** Zamanlayıcı (belirli saatte başlat/durdur, bitince Mac'i kapat/uyut), birden fazla kuyruk, Site Grabber.

**Kapsam dışı:** FTP (macOS'un `URLSession`'ı artık desteklemiyor), torrent, DRM korumalı içerik (Widevine/FairPlay/PlayReady), siteye özel koruma atlatma kodu, Mac App Store dağıtımı.

## 3. Kararlar ve varsayımlar

| Konu | Karar |
|---|---|
| Dil | Swift 6 (strict concurrency), SwiftUI + gerektiği yerde AppKit |
| Eklenti | Tek JS kod tabanı, Manifest V3, bundler yok. Ortak kod (`lib/*.js`) klasik betik olarak `globalThis.HDM` altına tanımlanır: content script'lerde manifest'te önce listelenir, Chrome service worker'ında `importScripts()`, Safari'de `background.scripts` ile yüklenir, Node testlerinde `vm` ile çalıştırılır |
| Arayüz dili | İngilizce (temel) + Türkçe, String Catalog (`.xcstrings`) ile; sistem diline göre açılır |
| Sandbox | Ana uygulama sandbox'sız; hardened runtime + Developer ID + notarization. Safari uzantısı (.appex) sandbox'lı (Apple zorunluluğu) |
| Proje dosyası | XcodeGen (`project.yml`); `.xcodeproj` depoya girmez |
| Takım kimliği | `Local.xcconfig` (gitignore'da) içinde `DEVELOPMENT_TEAM`; depoda `Local.xcconfig.example` |
| Bundle ID'ler | `com.hizdm.HizDownloadManager` (app), `com.hizdm.HizDownloadManager.SafariExtension` (appex), `com.hizdm.bridge` (native messaging host adı) |
| App Group | `$(DEVELOPMENT_TEAM).com.hizdm.shared` (takım önekli; Developer ID uygulamalarında provisioning profile gerektirmez) |
| Güncelleme | Sparkle 2 (MIT), appcast GitHub Releases'ta |
| Harici araçlar | yt-dlp (Unlicense), ffmpeg (LGPL/GPL, ayrı indirilir, HDM ile birlikte dağıtılmaz), deno (MIT) |

## 4. Mimari

```
┌──────────── Tarayıcı (Chrome / Brave / Safari) ────────────┐
│  HDM Eklentisi — tek JS kod tabanı (Manifest V3)           │
│   • background: indirme yakalama, sağ tık menüsü, medya     │
│     listesi, ayar önbelleği                                 │
│   • content script (tüm frame'ler): link tıklama (Safari),  │
│     video/akış algılama, "Bu videoyu indir" paneli          │
│   • popup: yakalama aç/kapa, bağlantı durumu, sekme medyası │
└───────┬───────────────────────────────────┬────────────────┘
        │ Chrome/Brave: native messaging     │ Safari: sendNativeMessage
        │ (stdio, 4 bayt uzunluk + JSON)     │
        ▼                                   ▼
  hdm-bridge (CLI, app bundle içinde)   SafariWebExtensionHandler (.appex)
        └──────────────┬────────────────────┘
                       │ Unix domain socket (App Group container)
                       │ 4 bayt uzunluk + JSON, istek/yanıt
                       ▼
┌────────────────── Hiz Download Manager.app ─────────────────┐
│  App (SwiftUI/AppKit)  pencereler, menü çubuğu, Dock, bildirim│
│  ───────────── HDMCore (Swift paketi) ─────────────          │
│  DownloadStore   öğeler, kategoriler, kuyruk, kalıcılık      │
│  HTTPEngine      segmentli indirme, devam, hız sınırı        │
│  MediaEngine     yt-dlp/ffmpeg süreçleri                     │
│  Components      yt-dlp/ffmpeg/deno bul → indir → güncelle   │
│  IPCServer       socket dinler, mesajları işler              │
│  ───────────── HDMIPC (ince modül) ─────────────             │
│  mesaj tipleri + çerçeveleme (app, bridge, appex ortak)      │
└──────────────────────────────────────────────────────────────┘
```

### Birimler ve sorumlulukları

| Birim | Ne yapar | Neye bağlı |
|---|---|---|
| `HDMIPC` | Mesaj tipleri (`Codable`), uzunluk önekli çerçeveleme, socket yolu | Sadece Foundation |
| `HDMCore/Model` | `DownloadItem`, `Segment`, `Category`, `Settings` | — |
| `HDMCore/Store` | Öğeleri tutar, diske yazar/okur, kuyruğu yönetir | Model |
| `HDMCore/HTTP` | `SegmentPlanner` (saf mantık), `Connection`, `HTTPDownload`, `SpeedLimiter`, `FilenameResolver` | Model, URLSession |
| `HDMCore/Media` | `YTDLPRunner`, `FormatMapper`, `ProgressParser` | Components |
| `HDMCore/Components` | Araçları bulma, indirme, doğrulama, güncelleme | — |
| `HDMCore/IPC` | `IPCServer`: socket dinler, `HDMIPC` mesajlarını Store'a çevirir | HDMIPC, Store |
| `App` | Tüm arayüz; HDMCore'u kullanır | HDMCore |
| `Bridge` | stdio ↔ socket aktarıcı, gerekirse uygulamayı başlatır | HDMIPC |
| `SafariExtension` | `sendNativeMessage` ↔ socket aktarıcı | HDMIPC |
| `Extension/` | Tarayıcı tarafı JS | — |

`HDMCore` arayüzden bağımsızdır; arayüzün bağlandığı model tipleri `@Observable` ve `@MainActor`'dür, motorun iç kısımları `actor`'dür.

## 5. İndirme motoru (HTTPEngine)

### 5.1 Veri modeli

`DownloadItem`:
- `id: UUID`, `kind: .http | .media`
- `url`, `finalURL?`, `pageURL?`, `referrer?`
- `requestHeaders`: `Cookie`, `User-Agent`, `Referer` ve Basic auth (tarayıcıdan gelen veya kullanıcının girdiği)
- `fileName`, `saveDirectory`, `category`
- `totalBytes?`, `receivedBytes`, `resumable: Bool?`, `etag?`, `lastModified?`
- `segments: [Segment]` — `Segment { start, end, received }` (bayt aralığı `[start, end)`)
- `status`: `queued`, `connecting`, `downloading`, `paused`, `merging` (medya), `completed`, `failed(reason)`, `needsRefresh`
- `maxConnections?`, `speedLimit?` (öğe bazında geçersiz kılma), `onComplete: .nothing | .open | .revealInFinder`
- `createdAt`, `lastTryAt?`, `completedAt?`, `userDescription`
- `media: MediaJob?` — yt-dlp girdisi (sayfa/akış URL'si, format seçici, başlıklar)

### 5.2 Kalıcılık

- Tüm öğeler `~/Library/Application Support/HDM/downloads.json` dosyasında tutulur. Dosya atomik yazılır (geçici dosya + rename). Değişiklik olduğunda en geç 2 saniyede bir kaydedilir; duraklatma, tamamlanma ve uygulamadan çıkışta hemen kaydedilir. Dosya izinleri `0600`, çünkü içinde cookie bulunabilir.
- Ayarlar `UserDefaults` içinde tutulur.
- Yarım dosya hedef klasörde `<dosya>.hdmpart` adıyla durur. Toplam boyut biliniyorsa başta `ftruncate` ile o boyuta getirilir (APFS'te seyrek dosya olur). Başlamadan önce boş disk alanı kontrol edilir, yetmiyorsa uyarı verilir.
- Tamamlanınca `.hdmpart` asıl adına taşınır. Aynı adda dosya varsa ayardaki davranış uygulanır: `dosya (2).zip` / üzerine yaz / sor.

### 5.3 Segmentleme algoritması (dinamik)

1. **Yoklama:** İlk bağlantı `GET` + `Range: bytes=0-` ile açılır (bazı sunucular `HEAD`'i yanlış yanıtladığı için HEAD kullanılmaz).
   - `206` + `Content-Range: bytes 0-X/TOPLAM` → devam destekli, boyut belli.
   - `200` + `Content-Length` → devam desteksiz: tek bağlantı, bu bağlantı dosyanın tamamını akıtır.
   - `200` ve uzunluk yok → devam desteksiz, boyut bilinmiyor.
   - ETag ve Last-Modified kaydedilir. Dosya adı bu yanıttan çözülür (§5.6).
2. **İlk plan:** Devam destekliyse ve `TOPLAM ≥ 2 × minSegment` (varsayılan `minSegment` = 1 MiB) ise dosya `min(maxConnections, TOPLAM / minSegment)` parçaya bölünür. İlk bağlantı kapatılmaz: 0. segmenti o devam ettirir ve kendi segment sınırına ulaşınca durur. Diğer bağlantılar `Range: bytes=a-(b-1)` ile açılır.
3. **Her bağlantı kendi `URLSession`'ını kullanır** (ephemeral yapılandırma, `httpMaximumConnectionsPerHost = 1`). Böylece HTTP/2 çoklaması bütün parçaları tek TCP bağlantısında toplayamaz; hızlanmanın kaynağı gerçekten ayrı TCP bağlantılarıdır.
4. **Dinamik bölme:** Bir bağlantı segmentini bitirdiğinde kalan baytı en çok olan segment bulunur. Kalan miktar `2 × minSegment`'ten büyükse o segment kalan kısmın ortasından ikiye bölünür. Eski bağlantı yeni (kısalmış) sınırında durur, boşalan bağlantı ikinci yarıyı alır. Bölünecek segment kalmadıysa bağlantı kapanır.
5. **Uyarlanır bağlantı sayısı:** Ek bir bağlantı `429`/`503` alırsa veya reddedilirse o bağlantı kapatılır ve bu indirme için `maxConnections` bir azaltılır. En az 1 bağlantı her zaman kalır.
6. **Sınır kesimi:** Bir veri parçası segment sınırını aşarsa fazlası atılır ve bağlantı iptal edilir. `SegmentPlanner` saf bir tiptir (I/O yok); bölme ve sınır kararlarının hepsi onda verilir ve tamamen birim testle doğrulanır.

### 5.4 Devam ettirme

- Kaydedilmiş segmentlerden devam edilir: her segment `Range: bytes=(start+received)-(end-1)` ile yeniden istenir. İsteklere ETag varsa `If-Range: <etag>`, yoksa `If-Range: <Last-Modified>` eklenir.
- Sunucu `206` yerine `200` dönerse veya `Content-Range` toplamı kayıtlı toplamla uyuşmazsa dosya değişmiş sayılır. Kullanıcıya "Dosya sunucuda değişmiş. Baştan başlansın mı?" diye sorulur.
- Devam desteksiz bir indirme duraklatılırsa, devam ederken baştan başlar. Arayüzde IDM'deki gibi "Devam desteği: Yok" yazar ve duraklatmadan önce kullanıcı uyarılır.

### 5.5 Hatalar ve yeniden deneme

- **Ağ hataları** (zaman aşımı, bağlantı koptu): yalnızca o segment yeniden denenir. Bekleme süresi her denemede katlanır: 1, 2, 4, … en fazla 30 sn; varsayılan en fazla 10 deneme. Başarılı veri gelince sayaç sıfırlanır.
- **Ağ tamamen koparsa** (`NWPathMonitor`): denemeler askıya alınır, ağ gelince kendiliğinden sürer.
- **`401`:** Kimlik bilgisi yoksa kullanıcı adı/şifre istenir (Basic auth).
- **`403`/`404`/`410`, veya imzalı link süresi dolmuş:** Öğe `needsRefresh` durumuna geçer.
  - **Link yenileme:** Sağ tık → "Link Yenile" seçilince `pageURL` (yoksa `referrer`) varsayılan tarayıcıda açılır ve öğe "yeni link bekleniyor" olarak işaretlenir.
  - Sonra yakalanan bir indirmenin dosya adı veya toplam boyutu eşleşirse "Bu, bekleyen 'x.zip' indirmesinin yeni linki mi?" diye sorulur. Evet denirse URL ve başlıklar güncellenir ve §5.4'teki doğrulamayla devam edilir.
- **Disk dolu / yazma hatası:** Tüm bağlantılar durur, öğe `failed(diskFull)` olur, kullanıcıya bildirilir.
- Diğer tüm hatalar `failed(reason)` olur. "Son Deneme" sütununda ve Özellikler penceresinde okunabilir bir mesaj gösterilir.

### 5.6 Dosya adı çözümleme (`FilenameResolver`)

Öncelik sırası:
1. Kullanıcının dialogda girdiği ad
2. `Content-Disposition` (`filename*` RFC 5987 dahil)
3. Tarayıcının önerdiği ad
4. Yönlendirme sonrası URL'nin son yol parçası (percent-decode edilmiş)
5. `index` + `Content-Type`'tan türetilen uzantı

Ad temizlenir: `/`, `:` ve kontrol karakterleri atılır, `..` ile başlayamaz, en fazla 255 bayt olur. Kategori klasörünün dışına yazılamaz.

### 5.7 Hız sınırı ve kuyruk

- **`SpeedLimiter`:** Token bucket yöntemi. Genel bir kova ve isteğe bağlı öğe başına bir kova vardır. Her `didReceive data` çağrısında token harcanır. Kova eksiye düşerse görev `suspend()` edilir ve açık kapanacak kadar süre sonra `resume()` edilir. Askıya alınan görev soketten okumayı bıraktığı için TCP geri basıncı oluşur. Saat (clock) enjekte edilir, böylece testlerde sahte saat kullanılabilir.
- **Kuyruk:** Aynı anda en fazla `maxConcurrentDownloads` indirme çalışır (varsayılan 4). "Sonra İndir" diye eklenen veya sırası gelmeyen öğeler `queued` durumunda bekler. "Kuyruğu Başlat" bekleyenleri sırayla başlatır, "Kuyruğu Durdur" yenilerinin başlamasını durdurur.

### 5.8 Kategoriler

| Kategori | Uzantılar (varsayılan, ayarlardan düzenlenebilir) | Klasör |
|---|---|---|
| Arşiv | zip rar 7z tar gz bz2 xz tgz iso | `~/Downloads/HDM/Compressed` |
| Belgeler | pdf doc docx xls xlsx ppt pptx odt txt rtf epub csv | `~/Downloads/HDM/Documents` |
| Müzik | mp3 m4a aac flac wav ogg opus wma | `~/Downloads/HDM/Music` |
| Programlar | dmg pkg app exe msi apk deb rpm appimage | `~/Downloads/HDM/Programs` |
| Video | mp4 mkv webm mov avi m4v flv wmv ts 3gp | `~/Downloads/HDM/Video` |
| Genel | diğer her şey | `~/Downloads/HDM/General` |

- Bir uzantı kullanıcı düzenlemesiyle birden fazla kategoriye girerse tablodaki sıraya göre ilk kategori kazanır. Varsayılan listede her uzantı tek kategoridedir (dmg/pkg yalnızca Programlar'da).
- Klasör adları dile göre yerelleştirilmez; her dilde aynıdır ki yollar değişmesin. Arayüzde kategori adları yerelleştirilir.

## 6. Arayüz

### 6.1 Ana pencere

- **Araç çubuğu** (büyük ikon + etiket): URL Ekle (⌘N), Devam, Durdur, Tümünü Durdur, Sil (⌫), Bitenleri Sil, Ayarlar (⌘,), Kuyruğu Başlat, Kuyruğu Durdur. İkonlar SF Symbols'tan seçilir.
- **Kenar çubuğu** (`NavigationSplitView`):
  - Tüm İndirmeler → kategoriler
  - Bitmemiş → kategoriler
  - Bitmiş → kategoriler
  - Kuyruklar → Ana Kuyruk
- **Liste** (SwiftUI `Table`):
  - Sütunlar: Dosya Adı (dosya türü ikonuyla), Boyut, Durum (yüzde veya durum metni, ince ilerleme çubuğuyla), Kalan Süre, Hız, Son Deneme, Açıklama. Sıralanabilir ve çoklu seçim destekler; araç çubuğunda arama alanı vardır.
  - Sağ tık menüsü: Aç, Birlikte Aç, Klasörde Göster, Devam, Durdur, Yeniden İndir, Link Yenile, Kuyruğa Ekle, Sil, Dosyayla Birlikte Sil, Özellikler.
- **Etkileşimler:**
  - Çift tıklayınca biten dosya açılır, bitmemiş öğenin ilerleme penceresi açılır.
  - Pencereye link veya `.webloc` sürüklenirse "Dosya İndirme Bilgisi" açılır.

### 6.2 URL Ekle ve Dosya İndirme Bilgisi

- **URL Ekle:** URL alanı açılır (panodaki link önceden doldurulur). İsteğe bağlı "Yetkilendirme kullan" (kullanıcı adı/şifre) seçeneği vardır. Tamam'a basılınca Dosya İndirme Bilgisi açılır.
- **Dosya İndirme Bilgisi:**
  - Alanlar: URL, Kategori (açılır menü), Farklı Kaydet (yol + Gözat), "Bu yolu kategori için hatırla", Açıklama, Boyut (arka plandaki yoklamayla dolar; bilinmiyorsa "Bilinmiyor").
  - Butonlar: İndirmeyi Başlat / Sonra İndir / İptal.
  - Pencere öne gelir ama uygulamanın ana penceresini açmaz.
  - Ayarlardan "Dialog göstermeden hemen başlat" seçilebilir.

### 6.3 İndirme ilerleme penceresi

Her indirme kendi penceresini açar (`WindowGroup(for: DownloadItem.ID)`). Başlık: `%43 ubuntu.iso`.

- **İndirme durumu sekmesi:**
  - Bilgiler: URL, Durum, Dosya boyutu, İnen (yüzde), Hız, Kalan süre, Devam desteği (Evet/Hayır).
  - Büyük ilerleme çubuğu.
  - **Segment çubuğu:** dosyanın tam genişliği; her segmentin inen kısmı renkli, aktif bağlantılar vurgulu (Canvas ile çizilir).
  - "Detayları göster": bağlantı tablosu (No, İnen, Bilgi — örn. "Veri alınıyor…", "Yeniden deneme 3/10").
- **Hız Sınırı sekmesi:** Bu indirme için hız sınırı aç/kapat ve değer.
- **Bitince sekmesi:** Hiçbir şey / Dosyayı aç / Klasörü göster.
- **Butonlar:** Duraklat/Devam, İptal.
- **Tamamlanınca:** "İndirme tamamlandı" penceresi açılır (Aç, Birlikte Aç, Klasörü Aç, Kapat, "Bir daha gösterme" onay kutusu). Aynı anda bildirim de gönderilir.

### 6.4 Mac'e özgü

- **Menü çubuğu ikonu (`MenuBarExtra`):** aktif indirme varken toplam hızı gösterir. Menüsünde aktif indirmeler, URL Ekle, Tümünü Durdur, HDM'yi Aç, Çık bulunur. Ana pencere kapatılsa bile uygulama menü çubuğunda çalışmaya devam eder (varsayılan açık, ayarlanabilir).
- **Dock:** toplam ilerleme çubuğu ve aktif indirme sayısı rozeti.
- **Bildirimler:** tamamlandı, başarısız, link yenilenmeli.
- **Uyku engelleme:** aktif indirme varken sistem uykusu engellenir (`ProcessInfo.beginActivity`, ayarlanabilir).

### 6.5 Pano izleme

- `NSPasteboard.changeCount` saniyede bir kontrol edilir.
- Değişiklik olduğunda önce içeriği okumadan "URL var mı" tespiti yapılır (macOS'un pano gizlilik API'si); sadece URL varsa içerik okunur. Böylece gereksiz gizlilik uyarısı çıkmaz. Sistem bir kere izin isteyebilir.
- URL'nin uzantısı yakalanacak türler listesindeyse Dosya İndirme Bilgisi açılır.
- Varsayılan: açık.

### 6.6 Ayarlar sekmeleri

- **Genel:** Yakalanacak dosya türleri, pano izleme (varsayılan açık), girişte başlat (Login Item), menü çubuğunda kal (varsayılan açık), uyku engelleme (varsayılan açık), dialog göstermeden başlat (varsayılan kapalı).
- **Tarayıcılar:** Bağlantı durumu (Chrome/Brave/Edge/Vivaldi/Safari için "bağlı / son görülme"), eklenti kurulum linkleri, Safari'de etkinleştir butonu, "köprüyü yeniden kur".
- **Kayıt Yerleri:** Kategori başına klasör; varsayılan klasör; aynı ad davranışı (varsayılan: `dosya (2).zip` gibi yeni ad).
- **Bağlantı:** Bağlantı sayısı (1–32, varsayılan 8), eşzamanlı indirme (1–10, varsayılan 4), genel hız sınırı, deneme sayısı, zaman aşımı.
- **Video:** Yardımcı programların durumu (sürüm, konum, Kur/Güncelle), varsayılan kalite, "QuickTime uyumlu format tercih et", paneli göster/gizle.
- **İstisnalar:** Yakalanmayacak siteler (joker destekli, örn. `*.apple.com`), yakalanmayacak minimum boyut.

### 6.7 İlk açılış

"Tarayıcı entegrasyonu" karşılama penceresi:
- Chrome/Brave için eklenti linki (Web Store; yayınlanana kadar "Paketlenmemiş yükle" talimatı).
- Safari için "Safari'de etkinleştir" butonu (`SFSafariApplication.showPreferencesForExtension`).
- Pano izleme hakkında kısa bilgi.
- "Mac'e giriş yapınca HDM'yi başlat" onay kutusu (varsayılan işaretli). Safari uzantısının app kapalıyken çalışabilmesi için önerilir.

## 7. Tarayıcı entegrasyonu

### 7.1 IPC protokolü (`HDMIPC`)

- **Çerçeveleme:** 4 bayt uzunluk (little-endian `UInt32`) + UTF-8 JSON. Chrome native messaging ile aynı biçim kullanıldığından köprü mesajı dönüştürmeden aktarır. Yanıtlar (app → eklenti) en fazla 1 MiB (Chrome'un host→tarayıcı sınırı); istekler (eklenti → app) en fazla 16 MiB.
- **Model:** Her mesaj istek/yanıttır. `{ "v": 1, "id": "<uuid>", "type": "...", ... }` → `{ "v": 1, "id": "<aynı>", "ok": true|false, "error"?: "...", ... }`.

**Mesajlar:**

| Tip | Yön | İçerik | Yanıt |
|---|---|---|---|
| `hello` | eklenti → app | `browser`, `extensionVersion` | `appVersion`, `settings` (yakalama açık mı, dosya türleri, istisnalar, min boyut, panel açık mı) |
| `download` | eklenti → app | `url`, `finalUrl?`, `referrer?`, `pageUrl?`, `filename?`, `mime?`, `size?`, `cookies?`, `userAgent?`, `source` (`capture`/`context`/`click`) | `ok`; app dialogu gösterir |
| `downloadLinks` | eklenti → app | `links: [{url, text}]`, `pageUrl`, `cookies?`, `userAgent?` | `ok`; app "Tüm linkler" dialogunu gösterir |
| `mediaQuery` | eklenti → app | `pageUrl`, `title?`, `streams: [{url, kind: file/hls/dash, mime?}]`, `cookies?`, `userAgent?`, `referrer` | `queryId`, `formats: [{id, label, ext, approxSize?, note?}]`, `drm?: bool` |
| `mediaDownload` | eklenti → app | `queryId`, `formatId` | `ok` |
| `ping` | eklenti → app | — | `ok` (popup'taki bağlantı durumu için) |

- Ayarlar `hello` yanıtında gelir. Eklenti bunları `storage` içinde önbelleğe alır ve 60 saniyede bir (ya da popup açıldığında) `hello` ile tazeler.
- `mediaQuery` yt-dlp çalıştırdığı için birkaç saniye sürebilir. Bu sürede eklentideki panel "Kaliteler alınıyor…" gösterir. Zaman aşımı 30 saniyedir.

### 7.2 Socket ve köprüler

- **Socket yolu:** `~/Library/Group Containers/<TEAM>.com.hizdm.shared/hdm.sock`, izinler `0600`. App açılışta eski soketi silip yeniden bağlar.
- **`hdm-bridge`:** App bundle içinde `Contents/Helpers/hdm-bridge` konumunda. Chrome her `sendNativeMessage` çağrısında bunu başlatır; köprü stdin'den bir mesaj okur, sokete yazar, yanıtı stdout'a yazar ve çıkar.
  - Soket yoksa app'i arka planda başlatır (`NSWorkspace.openApplication`, `activates = false`) ve 5 saniye boyunca bağlanmayı dener.
  - Başarısız olursa `{ok:false, error:"app_unavailable"}` döner.
- **Native messaging manifest'i (`com.hizdm.bridge.json`):** App her açılışta aşağıdaki klasörlerden var olanlara yazar. `path` o anki bundle konumunu gösterir (uygulama taşınırsa düzelir).
  - `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/`
  - `…/Google/Chrome Beta/…`, `…/Google/Chrome Canary/…`
  - `~/Library/Application Support/Chromium/NativeMessagingHosts/`
  - `~/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts/`
  - `~/Library/Application Support/Microsoft Edge/NativeMessagingHosts/`
  - `~/Library/Application Support/Vivaldi/NativeMessagingHosts/`
  - Arc'ın NativeMessagingHosts klasörü; tam konumu uygulama sırasında Arc kuruluyken doğrulanır, bulunamazsa Arc desteklenmez olarak belgelenir.
  - `allowed_origins`: geliştirme kimliği (manifest'teki `key` ile sabitlenir) + Chrome Web Store kimliği (yayınlanınca eklenir).
- **Safari:** `SafariWebExtensionHandler.beginRequest` gelen mesajı aynı sokete aktarır; app kapalıysa köprüyle aynı şekilde başlatmayı dener. Sandbox app'i başlatmaya izin vermezse `app_unavailable` döner ve eklenti "HDM'yi açın" uyarısı gösterir.

### 7.3 Chrome / Brave / Chromium eklentisi

- **İzinler:** `downloads`, `cookies`, `contextMenus`, `nativeMessaging`, `storage`, `webRequest`, `scripting`, host izni `<all_urls>`.
- **Yakalama:** `chrome.downloads.onDeterminingFilename` dinlenir. Aşağıdakilerin hepsi doğruysa indirme yakalanır:
  - yakalama açık,
  - URL şeması `http`/`https` (`blob:`/`data:` sayfanın içinde üretildiği için app'e aktarılamaz, tarayıcıya bırakılır),
  - uzantı veya MIME yakalanacak türler listesinde,
  - boyut bilinmiyor veya minimum boyutun üstünde,
  - site istisnalarda değil,
  - son 2 saniyede o URL'ye ⌥ ile tıklanmamış (content script bildirir).
- **Yakalanınca:** Önce `download` mesajı gönderilir (cookie'ler `chrome.cookies.getAll({url})` ile, HttpOnly dahil). `ok` gelirse tarayıcı indirmesi `cancel` + `erase` edilir. Hata gelirse tarayıcının indirmesine dokunulmaz (hiçbir indirme kaybolmaz).
- **Sağ tık menüsü:**
  - Link üzerinde: "HDM ile indir".
  - Sayfa/seçim üzerinde: "Tüm linkleri HDM ile indir". Seçim varsa seçimdeki linkler, yoksa sayfadaki tüm linkler gönderilir.
- **Popup:** Yakalama aç/kapa, "bu siteyi istisnalara ekle", HDM bağlantı durumu, bu sekmede bulunan medyalar.

### 7.4 Safari eklentisi

- Aynı JS dosyaları kullanılır; `manifest.safari.json` ayrıdır. Safari'de olmayan API'ler (`downloads`) özellik kontrolüyle devre dışı kalır.
- **Yakalama:** Content script `click` olaylarını (capture aşamasında) dinler. Tıklanan `<a>`'nın href'inin uzantısı listedeyse veya `download` niteliği varsa, `preventDefault` yapılır ve background'a `download` mesajı gönderilir. Mesaj başarısız olursa link normal şekilde açılır (fallback).
- **Cookie'ler:** `browser.cookies.getAll` destekleniyorsa o kullanılır. Desteklenmiyorsa content script'teki `document.cookie` alınır (HttpOnly cookie'ler hariç).
- **Bilinen sınır:** JavaScript veya form POST ile tetiklenen, ya da URL'sinde uzantı olmayan indirmeler Safari'de otomatik yakalanamaz. Bunlar için sağ tık "HDM ile indir" kullanılır. Bu durum README'de açıkça yazılır.
- Safari 18.4+ gereklidir (Developer ID ile imzalanmış uzantı desteği).

### 7.5 Tüm linkler dialogu

- Tablo sütunları: onay kutusu, Dosya adı, Tür, URL.
- Üstte tür filtreleri (Video, Arşiv, Belgeler, Müzik, Programlar, Resimler, Hepsi) ve metin filtresi.
- "Seçilenleri indir" butonu seçilenleri kategori klasörlerine, kuyruğa ekler.

## 8. Video paneli

### 8.1 Algılama (content script, `all_frames: true`)

- **Video elemanları:** `<video>`/`<audio>` elemanlarının `currentSrc` ve `<source>` değerleri. `blob:` kaynaklar (MSE) doğrudan kullanılamaz; bu durumda aynı frame'in ağ kayıtlarındaki akış adresi eşleştirilir.
- **Ağ kayıtları:** `PerformanceObserver` (`resource`) ile `.m3u8`, `.mpd`, `.mp4`, `.webm`, `.m4a`, `.mp3` adresleri toplanır. Parça dosyaları (`.ts`, `.m4s`, `seg-*`, `/range/`) atılır.
- **Chrome/Brave ek olarak:** `webRequest.onResponseStarted` ile yanıtı `Content-Type` `video/*`, `audio/*`, `application/vnd.apple.mpegurl`, `application/x-mpegurl` veya `application/dash+xml` olan istekler yakalanır. Bu, uzantısız akış adreslerini bulmayı sağlar.
- **DRM tespiti:** Sayfa ortamına (MAIN world) küçük bir betik enjekte edilir ve `navigator.requestMediaKeySystemAccess` sarmalanır. Widevine/FairPlay/PlayReady istenirse o frame "DRM" olarak işaretlenir.
- **Kayıt:** Bulunan medya, `tabId → [{url, kind, mime, frameUrl, referrer}]` olarak background'da tutulur (Chrome'da `storage.session`).

### 8.2 Panel

- Görünür bir `<video>` 200×120 px'ten büyükse ve oynatılıyorsa (veya fareyle üzerine gelindiyse) sağ üst köşesinde "⬇ Bu videoyu indir" butonu çıkar. Buton Shadow DOM içinde olduğundan sayfanın CSS'i onu etkilemez. Kapatma (×) butonu o video için paneli gizler.
- **Tıklayınca:** `mediaQuery` gönderilir ve açılır listede "Kaliteler alınıyor…" gösterilir. Sonuç gelince her satırda şu bilgiler yer alır: `1080p · MP4 · ~450 MB`, `720p …`, `Sadece ses · M4A`. >1080p gibi QuickTime'ın açamayabileceği kodekler için satıra "(VP9/AV1 — VLC/IINA önerilir)" notu eklenir.
- Satıra tıklanınca `mediaDownload` gönderilir ve indirme ana listeye eklenir.
- **DRM'li sayfada** butonun yerine "Bu video DRM ile korunuyor, indirilemez" notu çıkar.
- Popup'ta sekmedeki tüm medya aynı biçimde listelenir. Panel, video elemanı olmayan sayfalarda da (örn. sadece ses) popup üzerinden kullanılabilir.

### 8.3 Çözümleme ve indirme (MediaEngine)

`mediaQuery` geldiğinde sırasıyla şunlar denenir:
1. **Sayfa URL'si yt-dlp'ye verilir:** `yt-dlp -J --no-playlist <pageUrl>` + cookie dosyası + User-Agent. Başarılıysa formatlar buradan gelir. YouTube ve yt-dlp'nin desteklediği diğer siteler bu yoldan çözülür.
2. **Sayfa desteklenmiyorsa her HLS/DASH akışı yt-dlp'ye verilir:** `yt-dlp -J <streamUrl> --add-header "Referer: <frameUrl>" --add-header "Origin: …"` + cookie + UA. Varyantlar (çözünürlükler) formatlara dönüşür.
3. **Doğrudan dosyalar** (`kind: file`): yt-dlp çağrılmaz. Tek bir format satırı oluşur ve `HTTPEngine`'e `kind: .http` öğesi olarak gider (çok bağlantılı ve en hızlı yol).

**Format eşleme (`FormatMapper`, yt-dlp JSON → kullanıcı listesi):**
- Yükseklik başına (2160, 1440, 1080, 720, 480, 360) en iyi seçenek bir satır olur. Seçici: `bv*[height<=H]+ba/b[height<=H]`.
- "QuickTime uyumlu tercih et" açıksa (varsayılan) sıralamaya `-S vcodec:h264,acodec:aac` eklenir. Bu, yalnızca H.264 bulunan çözünürlüklerde etkilidir.
- Artı bir satır "Sadece ses" (`ba`, `-x --audio-format m4a`).
- Boyut, `filesize` veya `filesize_approx` toplamından hesaplanır.

**İndirme komutu:**
```
yt-dlp -f <seçici> -N 8 --newline --no-playlist --continue
       --progress-template "download:HDM|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s"
       --ffmpeg-location <ffmpeg> --js-runtimes <deno|node>:<yol>
       --merge-output-format mp4 --cookies <geçici dosya> --user-agent <ua>
       [--add-header ...] -o "<klasör>/<dosya>.%(ext)s" <url>
```
- `ProgressParser` `HDM|` satırlarını okur. Diğer çıktılar öğenin günlüğüne yazılır; son hata satırı `failed(reason)` olur. `[Merger]` satırı `merging` durumuna geçirir.
- **Duraklatma:** sürece `SIGINT` gönderilir. **Devam:** aynı komut yeniden çalıştırılır; yt-dlp `.part` ve `.ytdl` dosyalarıyla kaldığı yerden sürer.
- Geçici cookie dosyası Netscape biçimindedir, `0600` izinle `NSTemporaryDirectory` altına yazılır, süreç bitince silinir.
- Kalite sorgulama sonuçları (`queryId`) 10 dakika bellekte tutulur.

## 9. Yardımcı program yöneticisi (Components)

| Araç | Arama sırası | İndirme kaynağı | Doğrulama |
|---|---|---|---|
| yt-dlp | `~/Library/Application Support/HDM/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `PATH` | `github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos` | Aynı sürümün `SHA2-256SUMS` dosyası |
| ffmpeg | aynı sıra | arm64: `ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffmpeg.zip`; Intel: `evermeet.cx/ffmpeg` sürüm zip'i | Yayımlanan `.sha256` + `codesign --verify` (arm64 için imzalı) |
| deno | aynı sıra (+ `node` ≥ 22 yedek olarak kabul edilir) | `github.com/denoland/deno/releases/latest/download/deno-<arch>-apple-darwin.zip` | Yayımlanan `.sha256sum` |

- **Durum:** Ayarlar > Video'da her araç için sürüm ve konum gösterilir. Bulunamazsa "Kur" butonu çıkar. Kurulum `HDM/bin`'e yapılır: dosya çalıştırılabilir yapılır, quarantine niteliği kaldırılır.
- **Güncelleme:** HDM'nin kendi kurduğu yt-dlp haftada bir `yt-dlp -U` ile güncellenir. Homebrew kopyası kullanılıyorsa sadece "`brew upgrade yt-dlp` önerilir" bildirimi gösterilir, HDM onu değiştirmez.
- **Eksik araçla video indirme:** Kullanıcı eksik araç gerektiren bir video indirmeye çalışırsa "Bu video için yt-dlp gerekli — şimdi kur?" dialogu çıkar.

## 10. Güvenlik

- Socket kullanıcıya özel bir container'dadır ve izinleri `0600`'dır. Sadece aynı kullanıcının süreçleri bağlanabilir; güven sınırı kullanıcının kendisidir.
- Gelen tüm mesajlar doğrulanır: şema `v`, URL'ler yalnızca `http`/`https`, boyut sınırları. Mesajlardan hiçbir komut ya da yol doğrudan çalıştırılmaz veya kullanılmaz; kayıt yolu her zaman app tarafında belirlenir.
- Yakalanan indirmeler varsayılan olarak kullanıcı onayı (Dosya İndirme Bilgisi) ile başlar.
- Cookie'ler yalnızca ilgili öğenin kaydında (`0600`) ve yt-dlp'nin geçici dosyasında tutulur. Öğe silinince kaydından da silinir.
- İndirilen dosyalara `com.apple.quarantine` niteliği eklenir (tarayıcılarla aynı Gatekeeper davranışı). Bunun istisnası, Components'in kendi indirdiği ve doğruladığı araçlardır.
- yt-dlp'ye verilen argümanlar dizi olarak geçilir (`Process.arguments`); kabuk (shell) kullanılmaz.

## 11. Test stratejisi

**Birim testleri (Swift Testing, `HDMCore`):**
- `SegmentPlanner`: ilk bölme, dinamik bölme, minimum segment, sınır kesimi, uyarlanır bağlantı azaltma
- `FilenameResolver`: RFC 5987, percent-encoding, temizleme, çakışma adlandırma
- `CategoryResolver`, `SpeedLimiter` (sahte saat), Store kalıcılığı (yaz → oku eşitliği, bozuk dosya durumunda yedekten dönüş)
- `HDMIPC`: çerçeveleme ve JSON kodlama gidiş-dönüş testleri
- `ProgressParser` ve `FormatMapper`: gerçek yt-dlp JSON örnekleri (fixture) ile

**Entegrasyon testleri (`HDMTestSupport.TestHTTPServer`, Network.framework üzerinde):**
- Sunucu modları: Range/206, sadece 200, ETag değişimi, bağlantı başına hız kısma, akış ortasında bağlantı koparma, bir kez 403 sonra 200, 2'den fazla bağlantıya 429.
- Her senaryoda inen dosyanın SHA-256'sı kaynakla karşılaştırılır.
- **Hız testi:** bağlantı başına 1 MB/s kısmada 8 bağlantı, tek bağlantıdan en az 4 kat hızlı olmalı.
- **Kalıcılık testi:** duraklat → motor örneğini yok et → kayıttan yeni örnek oluştur → devam et → hash eşit.

**Eklenti (Node'un yerleşik `node --test` aracı, bağımlılık yok):**
- `shouldCapture()`, `classifyMediaUrl()`, `matchesException()`, mesaj oluşturucular.

**Uçtan uca (elle):**
- `swift run hdm-testserver` ile yerel test sitesi açılır: örnek dosyalar, ffmpeg ile üretilmiş HLS akışı (Referer ister), cookie ister bir link, uzantısız bir indirme.
- `docs/testing/e2e-checklist.md` içinde her tarayıcı için adım adım kontrol listesi bulunur.

**CI:** Her push ve PR'da `swift test` (HDMCore), `node --test` (Extension) ve `xcodebuild build` (app, imzasız) çalışır.

## 12. Depo yapısı ve derleme

```
HizDownloadManager/
  Packages/HDMCore/
    Package.swift            HDMIPC, HDMCore, HDMTestSupport, hdm-testserver
    Sources/…  Tests/…
  App/                       SwiftUI/AppKit kaynakları, Assets, Localizable.xcstrings
  Bridge/                    hdm-bridge main.swift
  SafariExtension/           SafariWebExtensionHandler.swift, Info.plist, entitlements
  Extension/
    src/                     background.js, content.js, page-hook.js, popup/, lib/
    manifest.chrome.json     manifest.safari.json
    tests/                   *.test.js
  TestSite/                  e2e test sayfası ve örnek içerik üretme betikleri
  scripts/                   build-extension.sh, make-dmg.sh, notarize.sh
  project.yml                XcodeGen
  Local.xcconfig.example
  Makefile                   bootstrap, project, test, app, extension, dmg
  .github/workflows/         ci.yml, release.yml
  README.md  README.tr.md  LICENSE  CONTRIBUTING.md
  docs/
```

- **`make bootstrap`:** XcodeGen yoksa kurar ve `Local.xcconfig`'i örnekten oluşturur.
- **`make project`:** `xcodegen generate` çalıştırır.
- **`make test`:** `swift test` ve `node --test` çalıştırır.
- **`make extension`:** Chrome zip'ini (`dist/hdm-chrome.zip`) üretir. Safari için JS dosyaları derleme sırasında appex'in `Resources/`'una kopyalanır.
- **`make app`:** `xcodebuild` ile Release derlemesi yapar.

## 13. Sürüm yayınlama

- **Tetikleyici:** `v*` etiketi `release.yml`'i çalıştırır.
- **Adımlar:**
  1. GitHub Secrets'tan Developer ID Application sertifikası geçici bir keychain'e aktarılır.
  2. `xcodebuild archive` → Developer ID ile export.
  3. `notarytool submit --wait` (App Store Connect API anahtarı) → `stapler staple`.
  4. `hdiutil` ile DMG oluşturulur; DMG imzalanır, notarize edilir ve staple edilir.
  5. Sparkle `sign_update` (EdDSA özel anahtarı secret'ta) → `appcast.xml`.
  6. GitHub Release'e yüklenenler: `HizDownloadManager-<sürüm>.dmg`, `appcast.xml`, `hdm-chrome-<sürüm>.zip`.
- **Sparkle feed URL'si:** `https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml` (`<owner>/<repo>`, GitHub deposu açılınca `project.yml`'e yazılır).
- Chrome Web Store'a yükleme elle yapılır (ilk yayında inceleme gerekir). Brave ve Edge kullanıcıları Chrome Web Store'dan kurar.
- **Ön koşul:** Proje sahibinin Developer ID Application sertifikası oluşturması gerekir (mevcut Apple Distribution sertifikası sadece App Store içindir).

## 14. Aşamalar ve kabul ölçütleri

Her aşama için ayrı bir uygulama planı yazılır; sonraki aşamanın planı, önceki aşama bitip kabul edildikten sonra yazılır.

**Aşama 1 — Motor + ana pencere**
- URL Ekle / sürükle-bırak / pano ile indirme başlar. Çok bağlantılı indirme, duraklatma ve uygulama yeniden açıldıktan sonra devam çalışır.
- Kategoriler, kuyruk (eşzamanlı sınır), hız sınırı, ilerleme penceresi ve segment çubuğu, tamamlandı dialogu, menü çubuğu, Dock, bildirimler hazır.
- Ayarlar: Genel, Kayıt Yerleri ve Bağlantı sekmeleri.
- İngilizce ve Türkçe arayüz.
- `HDMCore` birim ve entegrasyon testlerinin tamamı geçer.

**Aşama 2 — Tarayıcı entegrasyonu**
- Chrome/Brave eklentisi, `hdm-bridge`, Safari uzantısı ve socket sunucusu çalışır.
- Yakalama, sağ tık menüleri, Tüm linkler dialogu, popup, istisnalar ve ilk açılış ekranı hazır.
- Link yenileme yakalama üzerinden çalışır.
- Ayarlar: Tarayıcılar ve İstisnalar sekmeleri.
- E2E kontrol listesi Chrome, Brave ve Safari'de geçer.

**Aşama 3 — Video paneli**
- Algılama, panel, DRM notu, popup medya listesi, `mediaQuery`/`mediaDownload` akışı, doğrudan medya dosyalarının HTTPEngine'e yönlendirilmesi ve Components yöneticisi çalışır.
- Ayarlar: Video sekmesi.
- **Kabul:**
  - Bir YouTube videosu 1080p indirilir ve QuickTime'da oynar.
  - Test sitesindeki Referer isteyen HLS akışı indirilir.
  - Doğrudan bir mp4 çok bağlantılı iner.

**Aşama 4 — Açık kaynak paketleme**
- README (EN/TR, ekran görüntüleriyle), LICENSE, CONTRIBUTING, CI, release iş akışı, Sparkle ve Chrome eklentisi paketi hazır.
- **Kabul:** Etiket atılınca oluşan DMG temiz bir Mac'te kurulur, Gatekeeper'dan geçer, Safari uzantısı imzasız uzantı ayarı açılmadan etkinleşir, Sparkle bir sonraki sürümü bulur.

## 15. Riskler

| Risk | Etki | Önlem |
|---|---|---|
| YouTube'un yt-dlp'yi kırması | Video indirme geçici durur | yt-dlp haftalık otomatik güncelleme; hata mesajında "yt-dlp'yi güncelle" butonu |
| Chrome Web Store'un geniş izinlerde (`<all_urls>`, `cookies`) incelemeyi uzatması | Kolay kurulum gecikir | README'de "Paketlenmemiş yükle" talimatı; izin gerekçeleri mağaza açıklamasında |
| Safari'nin indirme API'si olmaması | Bazı indirmeler Safari'de yakalanamaz | Link tıklama + sağ tık + README'de açık sınır notu |
| Sandbox'lı appex'in app'i başlatamaması | Safari'den ilk istek app kapalıyken başarısız olabilir | İlk açılışta "girişte başlat" varsayılan işaretli (§6.7); eklentide "HDM'yi açın" uyarısı |
| Sunucuların çoklu bağlantıyı kısıtlaması | Hızlanma olmaz, 429/503 hataları | Uyarlanır bağlantı sayısı (§5.3.5) |
| macOS pano gizlilik uyarısı | Kullanıcıyı rahatsız edebilir | Önce içerik okumayan URL tespiti; ayardan kapatılabilir |
