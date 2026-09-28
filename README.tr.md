# MacDM — Mac İndirme Yöneticisi

macOS için hızlı, yerli bir indirme yöneticisi — Windows'taki klasik indirme yöneticilerinden ilhamla, Swift 6 / SwiftUI çekirdeğiyle yeniden: çok bağlantılı indirme, uygulamayı kapatıp açsan bile bozulmayan duraklat/devam, video siteleri için kalite seçici (YouTube ve ~1800 site daha) ve indirmeleri MacDM'ye devreden tarayıcı eklentisi.

[English](README.md) · **Türkçe**

## Özellikler

- **Çok bağlantılı indirme** — dosya parçalara bölünüp paralel bağlantılarla dinamik biçimde çekilir; destekleyen sunucularda tam hız (bağlantı sayısı 1–32 arası ayarlanabilir).
- **Gerçek duraklat/devam** — parça durumu diske yazılır; uygulamayı kapat, makineyi yeniden başlat, sonra kaldığın yerden devam et. `ETag`/`Last-Modified` doğrulanır; sunucudaki dosya değiştiyse bozulmak yerine uyarı gelir.
- **Kalite seçicili video indirme** — bir YouTube (veya Vimeo, X/Twitter, TikTok, Instagram, SoundCloud, Bilibili, …) linki yapıştır ve `1080p · MP4 · ~450 MB`, `720p` ya da *sadece ses* arasından seç. Gösterilen boyut diske inenle uyuşur. Varsayılan olarak QuickTime dostu H.264/AAC tercih edilir.
- **Tam çalma listeleri** — çalma listesi linki yapıştır; her video kendi klasörüne `001 - Başlık.mp4` diye numaralanır, seçtiğin kaliteyle iner.
- **Tarayıcı entegrasyonu** — Chrome, Brave, Edge, Vivaldi ve Safari için eklenti: tarayıcıda başlayan indirmeler MacDM'ye aktarılır, linklerde "MacDM ile indir" sağ tük menüsü, videolarda oynatıcının üzerinde "⬇ Bu videoyu indir" düğmesi çıkar.
- **Klasik iş akışı** — kendi klasörleriyle kategoriler (Arşiv, Belgeler, Müzik, Programlar, Video), eşzamanlılık sınırli kuyruk, indirme başına ve genel hız sınırı, parçalı ilerleme penceresi, tamamlanma penceresi, menü çubuğu hız göstergesi, Dock ilerlemesi ve bildirimler.
- **Pano izleme** — bir dosya ya da video linkini herhangi bir yerde kopyala; MacDM indirmeyi önerir.
- **İngilizce + Türkçe** arayüz, sistem dilini takip eder.

## Gereksinimler

- macOS 14 (Sonoma) veya üzeri; Apple Silicon ya da Intel
- Video indirmeleri için PATH üzerindeki üç açık kaynak araç ([Homebrew](https://brew.sh) ile tek satır):

```sh
brew install yt-dlp ffmpeg deno
```

> yt-dlp'yi güncel tut (`brew upgrade yt-dlp`) — siteler sürekli değişiyor, eski sürümler formatları kaybediyor.

## Kurulum

### 1. Uygulama

1. [Releases](../../releases) sayfasından `MacDM.dmg` dosyasını indirip aç.
2. **MacDM**'yi **Applications**'a sürükle.
3. İlk açılış: sürümler henüz notarize edilmediği için Gatekeeper soracak. **MacDM'ye sağ tıkla → Aç → Aç** (ya da bir kez `xattr -cr /Applications/MacDM.app` çalıştır). İmzalı + notarize sürümler yol haritasında.
4. İlk açılışta MacDM kısa bir kurulum penceresi gösterir ve kendini menü çubuğuna yerleştirir.

### 2. Tarayıcı eklentisi (Chrome / Brave / Edge / Vivaldi)

Eklenti depoyla birlikte gelir; MacDM çalıştığında bağlantıyı otomatik kaydeder.

1. Tarayıcıda `chrome://extensions` (Brave: `brave://extensions`) adresini aç.
2. Sağ üstteki **Geliştirici modu**nu (Developer mode) etkinleştir.
3. **Paketlenmemiş yükle** (Load unpacked) düğmesine bas ve depodaki `Extension/dist/macdm-chrome` klasörünü seç (ya da release eklerindeki `macdm-chrome.zip`i açıp o klasörü seç).
4. Bir sekmeyi yenile — dosya indirmeleri artık MacDM'ye önerilir, videolarda "⬇ Bu videoyu indir" düğmesi çıkar, linklerde sağ tık menüsü çalışır.

Chrome Web Store kaydı planlı; o güne kadar yukarıdaki kurulum geçerli.

### 3. Safari

1. **Safari → Ayarlar → Uzantılar** bölümünden **MacDM**'yi etkinleştir.
2. Sorulduğunda sayfaları okuma iznini ver.

Safari her indirmeyi yakalayamaz (orada `chrome.downloads` muadili yok) — link tıklamaları ve video düğmesi çalışır; geri kalan için sağ tık menüsünü kullan.

## Kullanım

- **URL Ekle** (⌘N), yapıştır ya da sadece bir linki kopyala — dosya penceresi başlamadan boyutu, kategoriyi ve klasörü gösterir.
- **Video linkleri** HTML indirmek yerine kalite seçicisini açar. Çalma listesi linkleri video sayısını gösterir ve tamamını indirir.
- Listeden, ilerleme penceresinden ya da menü çubuğundan **Duraklat/Devam**; durum uygulama yeniden başlatılsa da korunur.
- İndirme başına ya da genel **hız sınırı** (Ayarlar → Bağlantı).
- **İstisnalar**: `*.apple.com` tarzı desenler ve minimum boyut, istemediğin site/dosya türlerini tarayıcıda bırakır.

## Kaynaktan derleme

```sh
make bootstrap   # xcodegen yoksa kurar, Local.xcconfig oluşturur
make app         # Debug derleme → build/Build/Products/Debug/MacDM.app
make dmg         # Release derleme → dist/MacDM.dmg
make test        # Swift (HDMCore + HDMIPC) ve Node eklenti testleri
```

Xcode 16+, Swift 6. Xcode projesi XcodeGen ile üretilir (`make project`). Dahili modül adları (`HDMCore`, `HDMIPC`) projenin ilk adından kalma; yol kararlılığı için öyle kalıyor.

## Nasıl çalışır

```
Tarayıcı eklentisi ── native messaging ──> macdm-bridge ─┐
Safari uzantısı    ── sendNativeMessage ──> appex ───────┤
                                                         ▼
                              Unix-domain soket (HDMIPC, çerçeveli JSON)
                                                         ▼
   MacDM.app — DownloadManager · HTTPEngine (parçalı HTTP) · MediaEngine (yt-dlp) · IPCServer
```

- `HTTPEngine` `Range` ile yoklar, parçaları dinamik böler, geri çekilmeli yeniden dener, devamları doğrular.
- `MediaEngine` yt-dlp'yi sürer (kalite sorgusu + indirme), format başına ilerlemeyi tek bir ilerleyen çubukta birleştirir ve ffmpeg ile MP4'e birleştirir.
- Tamamı için tasarım belgesi: [`docs/superpowers/specs/...`](docs/superpowers/specs/2026-09-25-hiz-download-manager-design.md)

## Yol haritası

- [ ] Chrome Web Store kaydı + imzalı & notarize DMG'ler
- [ ] Zamanlayıcı (belirli saatte başlat/durdur, bitince kapat)
- [ ] Site Grabber, çoklu kuyruk
- [ ] yt-dlp'yi Ayarlar'dan güncelleme

## Teşekkürler ve lisans

MacDM MIT lisanslıdır. Sürüklediği, minnettar olduğu araçlar: [yt-dlp](https://github.com/yt-dlp/yt-dlp) (Unlicense), [ffmpeg](https://ffmpeg.org) (LGPL/GPL) ve [deno](https://deno.com) (MIT) — bunları Homebrew ile kendin kurarsın; pakete dahil değiller.
