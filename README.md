# DevTidy

Yerel geliştirme ortamı için macOS menü çubuğu uygulaması. Üç iş yapar:

- Çalışan yerel sunucuları (Next.js, Vite, Python, Laravel vb.) listeler ve süreç ağacıyla birlikte durdurur.
- Projelerdeki yeniden üretilebilir derleme önbelleklerini (`.next`, `.nuxt`, `target`, `DerivedData` vb.) siler.
- Docker konteynerlerini listeler; durdurur, siler, Compose projelerini `stop`/`down` yapar, build önbelleğini temizler.

Uygulama yalnızca menü çubuğunda yaşar (Dock simgesi yok, `LSUIElement`). Uzak bir sunucuya bağlanmaz, telemetri göndermez; makineden dışarı giden bir şey yoktur. İki yerel kanalı vardır: Docker unix soketi ve, Sunucular sekmesi açıkken, her geliştirme sunucusunun kendi `127.0.0.1` / `::1` adresine gönderilen tek bir `GET /` isteği (sayfa başlığını okumak için; ayardan kapatılabilir, aşağıya bakın). Arayüz Türkçedir.

## Ne gösterir

**Menü çubuğu özeti.** `server.rack` simgesi; bir şey çalışıyorsa yanında `N · BELLEK` görünür (N = çalışan sunucu + çalışan konteyner sayısı, bellek = ikisinin toplamı). Bellek kısmı Ayarlar > Genel'den kapatılabilir. Boşta işaretli kaynak varsa sonuna uyku emojisiyle birlikte sayısı eklenir.

**Sunucular sekmesi.** Kullanıcıya ait süreçlerin dinleyen TCP soketlerinden bulunan geliştirme sunucuları **proje klasörüne göre** gruplanır: her proje kökü ayrı bir bölümdür (bölümler başlığa göre sıralanır; projesi bulunamayan sunucular her zaman en sonda "Proje bulunamadı" bölümündedir). Bölüm başlığı `depo › paket/yolu` biçimindedir (örn. `redalert › packages/client`; depo yoksa klasör adı; bağlı bir git çalışma ağacında ana deponun adı ve çalışma ağacının klasörü: `redalert (wt feature-x) › packages/client`) ve yanında git dalı etiketi bulunur (ayrık HEAD'de 7 karakterlik commit; uzun dal adı ortadan kısaltılır, tamamı ipucunda); başlığın üstüne gelince tam yol görünür. Satır başlığı, varsa sunucunun **sayfa başlığı** (`<title>`), yoksa manifest adı, o da yoksa klasör adıdır; altındaki satırda manifest `ad@sürüm` (başlıktan farklıysa) ve Framework adı yer alır (örn. `client@0.0.0 · Vite`). Aynı klasör adını taşıyan iki proje (iki `client`) bölüm başlıklarındaki depo/yol ile ayırt edilir. **Aynı satır başlığını taşıyan iki sunucu** (aynı depoyu iki farklı klasöre çıkarmış, ikisi de aynı sayfayı sunan iki checkout) için alt satır ayrıca neyin farklı olduğunu söyler: klasörler farklıysa `depo › yol`, dallar farklıysa `(dal)` ve her zaman port; örn. `redalert-perf › packages/client (perf-fx) · :5182 · @redalert/client@0.1.0 · Vite`. Satırda ayrıca port etiketleri, komut (gizli değerler maskelenir, aşağıya bakın), CPU, bellek ve çalışma süresi vardır. Varsayılan olarak kapalı **Ayrıntılar** bölümü şunları gösterir: Tam yol (`~` kısaltmalı, "Finder'da Göster" düğmesiyle), Git dalı, Paket (`ad@sürüm · dosya`), varsa Çalışma alanı (monorepo kök paketi), Sayfa başlığı (okunuyor / yok / okunamadı / kapalı / boşta olduğu için okunmadı), Framework, PID'ler (adlarıyla), Başlangıç (yerel saatle tarih ve geçen süre), Komut satırı (seçilebilir, kopyala düğmesiyle; **Durdur kartıyla aynı kuralla maskelenir ve kopyalanan metin de maskelidir**: `--token x`, `--pass`, `--auth`, `API_KEY=…` gibi `AD=değer` biçimleri, URL kullanıcı bilgisi, `?token=…` ve `sh -c '…'` betiğinin içindeki değerler `•••` olur; kontrol, biçim ve çift yönlü yazı karakterleri `�` ile değiştirilir; en çok 4000 karakter) ve denetleyici/geçici portlar dahil tüm portlar rolleriyle. Port etiketine tıklamak `http://localhost:PORT` adresini tarayıcıda açar; tüm arayüzlere açık (`0.0.0.0`) portta ağ simgesi çıkar. Geçici portlar (49152 ve üstü) ve denetleyici (inspector) portları etiket olmaz, `+N dahili` olarak sayılır: 9229–9231 ile sürecin `--inspect[-brk|-wait][=[host:]port]`, `--inspect-port` veya `--inspector-port` bayraklarıyla bildirdiği portlar. Sağ tık menüsü: Klasörü Finder'da Göster, Komutu Kopyala, Portu Kopyala. Sunucu sayılmayan dinleyiciler (araç, uygulama, sistem) Ayarlar > Genel'de "Diğer dinleyicileri göster" açılırsa salt okunur bir listede görünür; bunlar için durdurma düğmesi yoktur. Ekrana giden, dışarıdan gelen her ad (klasör, depo, çalışma alanı, süreç, paket, sayfa başlığı) önce temizlenir (görünmez karakterler atılır, bileşik karakter yığınları sınırlanır) ve düz metin olarak çizilir; Markdown olarak yorumlanmaz.

**Proje kimliği.** Başlık, dal ve paket bilgisi dosya sisteminden okunur; hiçbir süreç (git dahil) başlatılmaz. Depo kökü, proje klasöründen yukarı doğru ilk `.git` klasörü veya dosyasıdır (ev dizininde durur; sembolik bağlantı olan `.git` sayılmaz); git çalışma ağaçlarında `.git` dosyasındaki `gitdir:` işaret edilen klasörün `HEAD` dosyası okunur. Dal `HEAD`'den okunur (`ref: refs/heads/…`; ayrık HEAD'de 7 karakterlik commit). Çalışma alanı adı, projenin üstündeki (depo kökünü aşmayan) ilk `workspaces` içeren `package.json` ya da `pnpm-workspace.yaml` bulunan klasörün paket adıdır. Manifest adı şu sırayla ilk bulunandır: `package.json` (`displayName` > `productName` > `name`, sürüm `version`), `composer.json` `name`, `app.json` `expo.name`, `Cargo.toml` `[package] name`, `pyproject.toml` `[project] name`, `*.xcodeproj` adı, `settings.gradle(.kts)` `rootProject.name`. Her dosya en çok 256 KB, normal dosya olmalı (sembolik bağlantı izlenmez, yok sayılır); okunan ad kontrol karakterlerinden arındırılır ve 120 karakterle sınırlanır. Sonuçlar proje başına 30 saniye önbelleğe alınır (dal değişikliği en geç o kadar sonra görünür).

**Sayfa başlığı.** Her sunucu için, sunucu kimliği başına (kök PID + başlangıç zamanı + port) en çok bir `GET /` isteği gönderilir ve yanıttaki `<title>` satır başlığı olur. Kurallar:

- Yalnızca Sunucular sekmesi görünürken (temizlik ekranı açıkken değil) ve Ayarlar > Genel'deki **"Sayfa başlığını oku (localhost'a tek GET isteği)"** açıkken başlar; pencere kapalıyken ya da başka sekmedeyken yeni istek başlamaz. Kapatılınca hiç istek gitmez ve gösterilen başlıklar silinir. **Seçenek varsayılan olarak AÇIKTIR (kullanıcı tercihi); kapatmak isteyen Ayarlar > Genel'den kapatır.**
- **Yan etki:** istek, sunucunun kendi günlüğünde bir `GET /` olarak görünür ve Next.js gibi çalışırken derleyen sunucularda ilk istek o sayfanın derlenmesini başlatabilir. Bu yüzden DevTidy (a) boşta işaretli ("Boşta" / "Muhtemelen boşta") bir sunucuya hiç istek göndermez, etkinleşince okur; (b) isteğin kendi bağlantısını ve CPU'sunu, yanıttan sonraki 5 saniyeyle birlikte, sunucunun etkinliği saymaz: sayfa başlığı okumak "boşta" sayacını sıfırlamaz ve işaretli bir sunucunun etiketini kaldırmaz.
- Adres sunucunun kendi dinleme adresidir: önce `127.0.0.1`, bağlanamazsa `::1` (ayrı IPv4/IPv6 soketlerinden hangisine bağlıysa). İsimler çözümlenmez; loopback olmayan hiçbir adrese bağlanılmaz. Yalnızca `127.0.0.1`/`::1`'e ya da tüm arayüzlere bağlı portlar sorulur; belirli bir ağ adresine bağlı portlar, denetleyici (inspector) portları ve sunucu sayılmayan dinleyiciler sorulmaz.
- `Accept: text/html`, `Connection: close`; çerez yok, önbellek yok, vekil sunucu yok (ham soket istemcisi; bu yüzden `Info.plist`'e App Transport Security istisnası gerekmez). Bağlanma zaman aşımı adres başına 1,5 sn, toplam 3 sn, gövde en çok 256 KB; `<title>` bulunup `</head>` geçilince okuma durur.
- Yalnızca 2xx ve `text/html` yanıtlar ayrıştırılır (sıkıştırılmış yanıt istenmez ve yok sayılır). En çok 2 yönlendirme izlenir, yalnızca `http://` ve aynı portta loopback adresine (`127.x.y.z`, `localhost`, `[::1]`); başka bir ana makineye, başka porta, `https`'e yönlendirme izlenmez.
- `<title>` büyük/küçük harfe ve satır sonlarına bakmadan bulunur (yorum, `<script>`, `<style>` içindekiler ve `<body>` sonrası sayılmaz), yaygın HTML varlıkları çözülür (`&amp;`, `&#8212;`, `&mdash;` …), boşluklar tek boşluğa indirilir, en çok 120 karakterle (ve 480 Unicode skalerle) sınırlanır; görünmez karakterler (sıfır genişlikli, çift yönlü, etiket karakterleri), temelsiz ve 4'ten fazla birleştirme işareti ve 3'ten uzun sıfır genişlikli birleştirici zincirleri atılır; görünür hiçbir şey kalmazsa başlık yoktur. Şablon/yer tutucu başlıklar başlık sayılmaz: `Vite App`, her `Vite + <çerçeve>` (`Vite + React`, `Vite + Vue`, `Vite + React + TS` …), `React App`, `Create Next App`, `Next.js`, `Document`, `Untitled`, `Error`, `localhost[:port]`, `127.0.0.1[:port]`, `Index of /`, `Directory listing for /` ve boş başlıklar.
- Sonuç sunucu kimliği başına bir kez alınır ve saklanır; bağlanılamazsa / zaman aşımı olursa / 5xx dönerse 60 saniye sonra en çok bir kez daha denenir (HTTPS kullanan bir sunucu düz bir isteğe yanıt vermez; Ayrıntılar bunu ipucuyla söyler). Sunucu kapanınca DevTidy'nin tuttuğu kayıt silinir; okuyucunun kendi önbelleği (en çok 256 hedef) ise en eski kayıt atılarak sınırlı kalır. Ara `1xx` yanıtları (`103 Early Hints`) atlanır.

**Docker sekmesi.** Compose projeleri ve tek başına konteynerler; durum noktası, imaj, yayımlanan port etiketleri, CPU/bellek/süre, sağlıksız konteyner işareti. Üstte "Build önbelleği: toplam (en çok X temizlenebilir)" satırı bulunur; "ölçülüyor…" yalnızca istek sürerken görünür, ölçüm başarısız olursa nedeni ve "Yeniden Dene" düğmesi gösterilir. Docker kurulu değilse veya çalışmıyorsa sekme bunu söyler ("Docker Desktop'ı Aç" düğmesi `/Applications/Docker.app` uygulamasını açar); uzak/ssh bağlamı gibi desteklenmeyen bir yapılandırmada nedenini, Colima/OrbStack ipucunu ve "Yeniden Dene" düğmesini gösterir.

**Derlemeler sekmesi.** Taranan klasörlerdeki projeler ve silinebilir önbelleklerinin toplam boyutu. Çalışan bir sunucusu/Compose projesi olan satır soluk görünür, "Çalışıyor" etiketi taşır ve listenin sonuna gider. Boyutlar tembel hesaplanır; tarama sınırı nedeniyle eksik ölçülen boyut `≥` ile gösterilir.

**Boşta işaretleri.** Bir kaynak, ayarlardaki süre boyunca sessiz kaldıysa "Boşta" etiketi alır:

- Sunucu aktiftir: CPU eşiğe eşit veya üstündeyse **veya** en az bir kurulmuş bağlantısı varsa. DevTidy'nin kendi sayfa başlığı isteği (bağlantısı, Next.js gibi sunucularda tetiklediği derleme ve yanıttan sonraki 5 saniye) etkinlik sayılmaz: istek boşta sayacını sıfırlamaz. Boşta işaretli bir sunucuya hiç istek gönderilmez (etkinleşince okunur).
- Konteyner aktiftir: CPU eşiğe eşit veya üstündeyse. CPU değeri henüz ölçülmemiş konteyner değerlendirilmez.
- DevTidy yeni açıldıysa ve kaynağın çalışma süresi eşiği aşmış ama DevTidy onu henüz o kadar süre gözlemlememişse etiket "Muhtemelen boşta" olur.

## Gereksinimler

- macOS 14 (Sonoma) veya üstü (`Package.swift`: `.macOS(.v14)`, `LSMinimumSystemVersion` 14.0).
- Xcode ve Swift 6 araç zinciri (`swift-tools-version: 6.0`; Swift 6.3 ile geliştirildi). `scripts/bundle.sh` varsayılan olarak `/Applications/Xcode.app/Contents/Developer` yolunu kullanır; yoksa mevcut `DEVELOPER_DIR`/`xcode-select` ayarı geçerlidir.
- Evrensel ikili: `scripts/bundle.sh` `arm64` ve `x86_64`'ü ayrı ayrı derleyip `lipo` ile birleştirir (Apple Silicon ve Intel). Hedef çalıştırma ortamı macOS 14+.
- `/usr/bin/git`: önbellek temizliğindeki git denetimleri için gereklidir.
- Docker Desktop isteğe bağlıdır. Soket sırayla şuralarda aranır: Ayarlar'daki yol, `$DOCKER_HOST`, geçerli Docker bağlamı, `~/.docker/run/docker.sock`, `/var/run/docker.sock`, `~/.colima/default/docker.sock`, `~/.orbstack/run/docker.sock`. Ayarlar'daki yol veya `$DOCKER_HOST` kullanılabilir bir soket değilse arama durur ve hata gösterilir; başka bir yerel daemon'a geçilmez. Compose işlemleri için ayrıca `docker` komutu `~/.docker/bin/docker`, `/usr/local/bin/docker`, `/opt/homebrew/bin/docker` veya `/Applications/Docker.app/Contents/Resources/bin/docker` yollarından birinde bulunmalıdır (`PATH` okunmaz); Docker alt sürecinin `PATH`'i `~/.docker/bin`'i en sona koyar.

## Kurulum

### Homebrew (önerilen)

```bash
brew install --cask suleymanozcan/tap/devtidy
```

Uygulama Developer ID ile imzalı ve Apple tarafından notarize edilmiş evrensel bir pakettir; Gatekeeper uyarısı çıkmaz. Kurulum sonrası uygulamayı Launchpad'den ya da `open -a DevTidy` ile açın.

### DMG

[Releases](https://github.com/suleymanozcan/devtidy/releases/latest) sayfasından `DevTidy-<sürüm>.dmg` dosyasını indirin, açın ve `DevTidy.app`'i `Applications` kısayoluna sürükleyin.

### Kaynaktan

Depo kökünden:

```bash
scripts/bundle.sh      # release derler, build/DevTidy.app üretir, imzalar
scripts/install.sh     # bundle.sh'ı çalıştırır, sonucu ~/Applications/DevTidy.app'e kopyalar
open ~/Applications/DevTidy.app
```

Menü çubuğunda `server.rack` simgesi belirir. Kapatmak için açılır pencerede "Çıkış" (⌘Q) kullanılır.

`scripts/bundle.sh` ortam değişkenleri:

| Değişken | Varsayılan | Anlamı |
|---|---|---|
| `VERSION` | `0.1.0` | `CFBundleShortVersionString` |
| `BUILD` | `date +%Y%m%d%H%M` | `CFBundleVersion` |
| `BUNDLE_ID` | `dev.minata.DevTidy` | `CFBundleIdentifier` |
| `SIGN` | `adhoc` | `adhoc`, `none` veya bir codesign kimliği (kimlik verilirse `--options runtime --timestamp` ile imzalanır ve `codesign --verify --strict --deep` ile doğrulanır) |
| `DEVELOPER_DIR` | `/Applications/Xcode.app/Contents/Developer` (varsa) | Kullanılacak Xcode |

`VERSION`, `BUILD` ve `BUNDLE_ID` yalnızca `[A-Za-z0-9._-]` karakterlerini içerebilir; aksi halde betik hata verir. `Resources/AppIcon.icns` dosyası varsa pakete eklenir (depoda yoktur).

`scripts/install.sh` yalnızca `~/Applications` altına yazar, `/Applications`'a dokunmaz; `HOME` boşsa, göreli bir yolsa, `/` ise veya var olmayan bir klasörse hiçbir şey çalıştırmadan çıkar. `~/Applications` sembolik bağlantıysa (veya fiziksel yolu `$HOME/Applications` değilse) reddeder. Mevcut `~/Applications/DevTidy.app`, ancak `CFBundleIdentifier` değeri `BUNDLE_ID` ile aynıysa değiştirilir; sembolik bağlantı veya başka bir paket ise reddedilir. Yeni paket önce aynı klasörde hazırlanıp yeniden adlandırılarak yerine konur: kopyalama başarısız olursa eski uygulama yerinde kalır; Ctrl-C / `SIGTERM` / `SIGHUP` iki yeniden adlandırmanın arasına denk gelirse çıkış işleyicisi eski uygulamayı geri koyar. Çalışan DevTidy'yi sonlandırmaz: güncelleme sonrasında "Çıkış" ile kapatıp yeniden açın.

Oturum açılışında otomatik başlatma uygulamada yoktur.

## Kaldırma

Homebrew ile kurduysanız:

```bash
brew uninstall --zap --cask devtidy
```

`--zap` uygulamayla birlikte denetim günlüğünü (`~/Library/Logs/DevTidy/`) ve tercihleri (`~/Library/Preferences/dev.minata.DevTidy.plist`) de siler; `--zap` olmadan yalnızca uygulama kaldırılır.

DMG ile kurduysanız DevTidy'den çıkın ve `/Applications/DevTidy.app` klasörünü silin; kaynaktan kurduysanız `~/Applications/DevTidy.app` klasörünü silin. Bu iki durumda denetim günlüğü `~/Library/Logs/DevTidy/` altında kalır, isterseniz elle silin.

## Kullanım

Menü çubuğu simgesine tıklayınca sabit genişlikli bir pencere açılır: üstte `Sunucular` / `Docker` / `Derlemeler` sekmeleri (rozetlerde sayılar), altta `Yenile` (⌘R), `Ayarlar…` (⌘,), `Çıkış` (⌘Q). `Yenile` açık sekmeyi yeniler (Derlemeler'de yeniden tarar). İşlem hataları pencerenin üstünde kapatılabilir bir bantta gösterilir. Bir durdurma, Docker eylemi, build önbelleği temizliği veya silme sürerken `Çıkış` devre dışıdır (yarım kalan SIGKILL yükseltmesi ve yarım silinmiş klasör olmasın diye).

### Sunucuyu durdurma

- **Durdur**: onay kartı projeyi (klasör adı; kimlik biliniyorsa `depo › yol ⎇ dal` ve `~/…` biçiminde klasör yolu — aynı adlı iki checkout'u ayırt etmek için), sunucunun kök sürecini (PID, ad ve tam komut satırı), sonlandırılacak tüm süreçleri (PID ve ad), sinyalin süreç grubuna mı tek tek mi gideceğini ve iç içe ağaçlar birleştirilmişse her sunucuyu (proje, port, PID) listeler; dokunulmayacak tarayıcı/uygulama/editör/terminal/ajan süreçleri ayrıca "Dokunulmayacak" başlığı altında gösterilir. Komut satırında gizli görünen değerler (`--token x`, `--pass`, `--auth`, `API_KEY=…` gibi `AD=değer`, URL kullanıcı bilgisi, `?token=…`, `sh -c '…'` betiğinin içi) `•••` ile maskelenir; sunucu satırındaki komut ve Ayrıntılar → Komut satırı (ve kopyalanan metin) aynı kuralla maskelenir. Karttaki proje, süreç ve sunucu adları ekrana varmadan temizlenir (görünmez/çift yönlü karakterler atılır). Onaydan sonra süreç ağacına önce `SIGTERM` gider; 5 saniye içinde kapanmayanlara `SIGKILL`, ardından en fazla 2 saniye beklenir. Kapanmayan süreç olursa hata bandı PID'leri gösterir.
- **Durdur + Temizle…**: sunucuyu durdurmadan önce o projenin önbellek planını açar (aşağıdaki "Derlemeler" akışıyla aynı ekran). Ekran, **Durdur ve Temizle** düğmesinden önce düz **Durdur**'daki kartın içeriğini de gösterir: kök sürecin PID'i/adı/tam komut satırı, sinyal yolu, sonlandırılacak PID'ler ve "Dokunulmayacak" süreçler. Hiçbir şey, ekrandaki **Durdur ve Temizle** düğmesine basılana kadar yapılmaz. Basılınca sırasıyla: sunucu durdurulur; hâlâ yaşayan süreç varsa temizlik yapılmaz; plan yeniden çıkarılır; seçili öğeleri hâlâ engelleyen bir çalışan varsa iptal edilir; yalnızca sizin seçtiğiniz öğeler silinir. Plan yeniden çıkarıldığında listeye sonradan eklenen bir yol (örn. durdurma sırasında oluşan yeni bir `__pycache__`) silinmez: yalnızca incelediğiniz yollar silinir. "Docker durumu doğrulanamadı" bir çalışan süreç değil, ayrı bir uyarı olarak gösterilir ("Çalışıyor" altında değil). Proje bulunamayan sunucularda düğme kapalıdır.

### Önbellek temizliği (Derlemeler sekmesi ve Durdur + Temizle…)

Sekme ilk açılışta, sonra **Yeniden Tara** ile taranır; sekme açıkken en fazla 30 dakikada bir kendiliğinden yenilenir. Bir proje satırındaki **Temizle…** düğmesi, açılır pencerenin içinde (sekmelerin yerine) temizlik ekranını açar. Ekran her öğe için şunu gösterir: onay kutusu, **tam mutlak yol**, boyut, silme biçimi ("Kalıcı sil" veya "Çöp Kutusu'na taşı"; seçili satırda menüden değiştirilebilir), notlar ve "Neden uygun" satırı (örn. git tarafından yok sayılıyor). Altta toplam boyut yer alır; Çöp Kutusu'na gidenler için "Çöp Kutusu'nu boşaltınca X boşalır" uyarısı çıkar. Silme yalnızca **Temizle** düğmesiyle başlar.

| Katman | Ekrandaki başlık | Örnekler | Varsayılan silme | Önceden seçili |
|---|---|---|---|---|
| A | Her zaman güvenli | `.next`, `.nuxt`, `.svelte-kit`, `.astro`, `node_modules/.vite`, `.turbo`, `.nx/cache`, `.parcel-cache`, `.angular/cache`, `node_modules/.cache`, `.wrangler/tmp`, `.expo`, Laravel derlenmiş görünümler, `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `.gradle`, `.kotlin`, `.dart_tool`, `.godot`, Xcode DerivedData | Kalıcı sil | Evet |
| B | Koşullu | `dist`, `out`, `.output`, `.open-next`, test raporları (`coverage` vb.), Rust/Maven `target`, SwiftPM `.build`, Xcode/Flutter/Gradle `build`, `ios/build`, `android/build`, `public/build`, Laravel `bootstrap/cache` dosyaları | Çöp Kutusu | Hayır |
| C | Bağımlılıklar | `node_modules`, Composer `vendor`, `ios/Pods` | Kalıcı sil | Hayır |

- **B katmanı**: ekrandaki "Koşullu öğeleri kalıcı sil (Çöp Kutusu yerine)" kutusu tüm koşullu satırların varsayılanını değiştirir; ayar kalıcıdır, varsayılanı kapalıdır. Çöp Kutusu'na taşıma başarısız olursa öğe silinmez, hata olarak raporlanır; kalıcı silmeye dönülmez.
- **C katmanı (`node_modules` seçeneği)**: Ayarlar > Tarama'daki "node_modules ve diğer bağımlılıkları listele" açılmadıkça listelenmez. Açıkken bile hiçbiri önceden seçili gelmez; temizlemek için "Anladım: bağımlılıklar silinecek, yeniden kurulum ağ gerektirir" kutusu işaretlenmelidir. Satırda yeniden kurulum komutu görünür (`npm ci`, `pnpm install --frozen-lockfile`, `yarn install --immutable`, `bun install --frozen-lockfile`, `composer install`, `pod install`). `node_modules` yalnızca bir kilit dosyası varsa ve Yarn PnP kullanılmıyorsa sunulur.
- **Çalışan süreçler**: projenin klasöründe çalışan süreçler listelenir. A katmanını yalnızca "sert" engeller (sunucu/çalışma zamanı süreçleri ve dinleyen süreçler) durdurur; B ve C katmanını, kabuk/terminal/IDE/Finder dışındaki her süreç ve proje klasörünü bağlayan çalışan konteynerler de durdurur. Engel varken ilgili seçili öğeler temizlenemez, düğme kapalıdır.
- **Sahipsiz DerivedData**: Derlemeler sekmesinin sonunda, çalışma alanı artık diskte olmayan Xcode DerivedData klasörleri için ayrı bir satır çıkar; hiçbiri önceden seçili gelmez. Xcode açıksa ekranda bilgi notu görünür (engel değildir).

### Docker

- **Durdur** (çalışan konteyner): onay sorulmadan çalışır; Engine API ile durdurur (10 sn bekleme süresi), silmez.
- **Başlat** / **Sil…** (durmuş veya oluşturulmuş konteyner): `Sil…` onay ister; zorla silmez, birimleri (volume) silmez.
- **Compose projesi**: başlıktaki **Durdur** (`docker compose -p ADI stop`) ve **Kaldır (down)** (`docker compose -p ADI down`) onay ister. `down` konteynerleri ve ağları kaldırır; birimleri ve imajları silmez.
- **Boştakileri Durdur (N)**: yalnızca "Boşta" olan çalışan konteynerleri durdurur ("Muhtemelen boşta" olanlar dahil değildir). Onay kartı, kart açıldığı anda boşta olan konteynerlerin adlarını listeler ve yalnızca bunlar durdurulur: kart açıkken boşta kalan başka bir konteyner listede yoksa durdurulmaz, kart açıkken yeniden etkinleşen de atlanır. Silmez. Açık bir onay kartı, pencere kapanınca iptal edilir.
- **Build önbelleği > Temizle…**: "7 günden eskiler" veya "Tümü (kullanılmayan)". Yalnızca Docker build önbelleğini temizler; imajlara, konteynerlere ve birimlere dokunmaz. Kazanılan alan satırın altında gösterilir.

## Güvenlik garantileri

Aşağıdakiler kodda uygulanır ve testlerle sınanır; dosya adları parantez içindedir.

### Süreçleri durdurma (`Processes/ProcessTerminator.swift`, `TreeRootResolver.swift`, `ProcessNames.swift`)

- Yalnızca sizin kullanıcınıza ait süreçler görülür ve sinyal alır; sinyalden hemen önce `uid` yeniden doğrulanır.
- PID 0/1'e, DevTidy'nin kendisine ve DevTidy'nin üst süreçlerine (DevTidy'yi başlatan kabuk/terminal dahil) asla sinyal gönderilmez. Üst zincir çekirdekten canlı okunur; arada başka kullanıcıya ait `login`/`sudo` gibi bir süreç olsa bile `iTermServer`/`iTerm2` korunur.
- PID yeniden kullanımına karşı her sinyalden hemen önce süreç kimliği (PID + başlangıç zamanı) kaydedilenle karşılaştırılır; uyuşmazlıkta sinyal gönderilmez.
- Sinyal yalnızca sunucunun süreç ağacına gider (kök, torunları, hâlâ aynı kimlikteki özgün üyeler). Kök olarak interaktif kabuklar, terminaller (`tmux`, `screen`, `ssh`, `zellij`, …), IDE'ler ve editörler (`code`, `cursor`, `xcode`, `zed`, JetBrains ürünleri, `nvim`, `vim`, `emacs`, …) ve ajanlar (`omp`, `claude`, `codex`, `aider`, `gemini`, `opencode`, …; `node`/`bun`/`deno`/`python` altında mutlak yolla çalışan betik/paket olarak çalışanlar ve `python -m aider` gibi bilinen ajan modülleri dahil) asla seçilmez; `node gemini.js` gibi göreli bir betik ya da `python -m copilot` projenin kendi dosyası sayılır, ajan değil. Bu denetim sinyalden hemen önce `TreeTerminator` içinde de yinelenir. Bir süreç grubunu yöneten çalışma zamanı (`node`, `deno` vb.), dinleyenin proje klasörüne ya da içinde bulunduğu git deposunun köküne ait değilse kök seçilmez; 'ait' demek, sürecin kendi çalışma klasörünün veya kendi çalıştırılabilir dosyasının bu klasörlerin içinde olmasıdır (argv'deki bir yol yetmez; depo kökündeki bir monorepo yöneticisi kabul edilir). Tarayıcılar (Chrome, Firefox, Edge, …), `.app` paketi içinde çalışan süreçler (Electron uygulamaları, Xcode araçları; paket içindeki `node`/`python` çalışma zamanları hariç) ve kökün altındaki terminal/IDE/ajan süreçleri bir sunucunun alt süreci olsalar bile sunucu ağacına alınmaz, listelenmez, sinyal almaz (atlama nedeni `protected-role`) ve grup sinyalini engeller; dinleyen bir sunucu süreci (yalnızca editör/IDE adı kuralından) muaftır: `fleet`, `hx`, `nova`, `studio` adlı bir proje ikilisi hem kök hem alt süreç olarak durdurulabilir; terminal (`tmux`, `ssh`, …), ajan, kabuk, tarayıcı ve `.app` kuralları dinleyen kök için de geçerlidir. Kök yalnızca `npm`, `pnpm`, `turbo`, `sh -c` gibi başlatıcılar üzerinden yukarı çıkabilir.
- Grup sinyali (`kill(-pgid)`) yalnızca kök kendi süreç grubunun lideriyse, grup DevTidy'nin grubu değilse ve gruptaki **her** süreç (tüm kullanıcılar dahil) doğrulanmış üyeyse kullanılır; aksi halde süreçlere tek tek sinyal gider. Gruptaki okunamayan ama canlı bir süreç "çıkmış" sayılmaz; tek tek sinyale geçilir.
- `EPERM` raporlanır; yeniden denenmez, yükseltilmez. Süreç sonlandırmada kabuk, `killall`, `pkill`, `lsof` veya `ps` kullanılmaz. `git`/`docker` alt süreçleri kendi süreç grubunda çalışır; zaman aşımında veya akış başına 16 MiB çıktı sınırında yalnızca o grup sonlandırılır, sonuç başarısız sayılır (kesik çıktı asla sonuç olarak kullanılmaz); boru uçlarını elinde tutan bir torun sonucu en çok 2 saniye geciktirir.
- Docker'ın arka uç süreçleri sunucu listesine alınmaz; konteynerler süreç sinyaliyle değil Engine API ile yönetilir.

### Dosya silme (`Projects/CacheCleaner.swift`, `CacheCatalogData.swift`, `PathPolicy.swift`, `SafeFS.swift`, `CacheEvaluator.swift`)

- Kapalı katalog: katalogda olmayan yol hiçbir zaman silinmez. Silinecek hedefler yürütme anında `(kural, paket klasörü, örnek)` üçlüsünden yeniden türetilir; arayüzdeki metinler hiçbir hedef ekleyemez ve bir yol oluşturmaz: ekrandaki yol listesi (`displayPath`) yalnızca bu yeniden türetilen hedef kümesini **daraltabilir** (liste boşsa ya da uydurmaysa hedef bulunamaz).
- Asla sunulmayanlar (katalog başlığında listelidir): `.wrangler` (yalnızca `.wrangler/tmp` sunulur; `.wrangler/state` yerel D1/KV/DO verisi olduğu için asla), genel `public` (yalnızca Gatsby çıktısı, `public/build` ve Laravel `public/hot`), `tmp`, `.tmp`, `temp`, `.release`, `release`, `releases`, `bin`, `obj`, `lib`, `.data`, `.vercel`, `.venv`, `venv`, `env`, `.tox`, `.ipynb_checkpoints`, `.hypothesis`, `.swiftpm`, `.yarn`, `pnpm-store`, `storage/app`, `storage/logs`, `storage/framework/sessions`, `storage/framework/cache/data`, `public/storage`, `.env*`, tek dosya glob'ları ve genel Go önbellekleri.
- `dist` yalnızca `package.json`'da derleme betiği veya bir paketleyici yapılandırması varsa ve git koşulları sağlanıyorsa (B katmanı) sunulur; kardeş çalışma alanı paketi bu pakete bağımlıysa ekranda uyarı notu çıkar. Paketin kendi `package.json`'ı (`main`/`module`/`types`/`typings`/`browser`/`exports` (iç içe koşullar dahil)/`bin`/`files`/`directories`/`typesVersions`) `dist` içine işaret ediyorsa `dist` hiç sunulmaz ve silinmez. Var olan ama okunamayan bir `package.json` (geçersiz JSON, 1 MiB'tan büyük, sembolik bağlantı) da B katmanı çıktılarının sunulmasını/silinmesini engeller ("paketin yayın çıktısı olabilir").
- Proje klasörü ev dizininin altında, en az 2 seviye derinlikte (`~/developer/proje` gibi), gerçek bir dizin ve ev dizini ile aynı diskte olmalıdır. `~/Library`, `~/.Trash`, `~/Applications`, `~/Public` ve ev dizinindeki tüm gizli klasörler (`~/.config` vb.) reddedilir.
- Hedef, projenin (git kökünün) kesinlikle içinde olmalıdır; `.git` ve ev dizininin kendisi hiçbir zaman silinmez. İçinde iç içe bir depo/çalışma ağacı (herhangi bir derinlikte, herhangi bir harf büyüklüğünde `.git` dosyası, klasörü veya sembolik bağlantısı: `.GIT`, `.Git`, … çünkü APFS varsayılan olarak büyük/küçük harfe duyarsızdır; sınırlı ön tarama, sınırlar aşılırsa reddedilir) bulunan hedef A, B ve C katmanlarında reddedilir (DerivedData hariç). Hedef başına sıra: ölçüm → çalışan denetimi → iç içe depo taraması (Laravel görünümleri gibi yalnızca-içerik kurallarında bunun yerine alt öğelerin git ile yeniden doğrulanması) → çalışan denetimi yeniden (tarama saniyeler sürebilir; o sırada başlayan bir sunucu da silmeyi durdurur) → `intent` satırı → silme; engellenmiş bir hedef taramaya girmez (ilk denetim taramanın önündedir) ve ikinci denetim doğrudan kimlik ön denetiminin önündedir. Ekranda gösterilen red nedenleri: "içinde başka bir git deposu var" / "içinde depo olmadığı doğrulanamadı".
- Sembolik bağlantı: yolun herhangi bir bileşeni sembolik bağlantıysa hedef atlanır; bağlantının kendisi de silinmez (`O_NOFOLLOW_ANY`, dosya tanıtıcısına göreli `openat`/`unlinkat`).
- Silme başka bir diske geçmez; değiştirilemez/yalnızca-ekle bayrağı (`UF_IMMUTABLE`, `UF_APPEND`, `SF_IMMUTABLE`, `SF_APPEND`) olan hedef atlanır, bayrak asla kaldırılmaz.
- Git denetimi (`/usr/bin/git`): A katmanı için hedefin içinde git tarafından izlenen dosya olmamalı (git deposu olmayan klasörde A katmanı geçer); B ve C için ayrıca klasör bir depoda olmalı, git tarafından yok sayılmalı ve içinde izlenmeyen-yok sayılmayan dosya bulunmamalıdır. Git çalıştırılamıyorsa veya zaman aşımına uğrarsa hedef silinmez.
- Silmeden hemen önce her hedef için engelleyici süreçler yeniden taranır; hedefin `(aygıt, inode)` kimliği doğrulama anıyla karşılaştırılır, değiştiyse bir kez yeniden doğrulanır, yine değiştiyse atlanır.
- Laravel `storage/framework/views` ve `bootstrap/cache` için klasör değil, yalnızca koşulları sağlayan dosyalar silinir; klasör kalır. `public/hot` yalnızca en fazla 512 bayt boyutunda, içeriği `http(s)://` ile başlayan normal dosyaysa sunulur.
- Denetim günlüğü yazılamıyorsa hiçbir şey silinmez; bir satır ortada yazılamaz hale gelirse kalan öğeler silinmeden çalışma durur. 30 dakikadan eski planlar reddedilir (yeniden planlayın). Docker durumu doğrulanamıyorsa (liste isteği başarısız) etkinlik denetimi güvenli tarafta kalır ve "Docker durumu doğrulanamadı" yumuşak engeli ekler; `xcodebuild` de etkinlik sayılır.

### Docker (`Docker/DockerClient.swift`, `ComposeCLI.swift`)

- Konteyner kimliği (12–64 küçük onaltılık karakter) ve Compose proje adı (`^[A-Za-z0-9][A-Za-z0-9_.-]*$`) istek oluşturulmadan/süreç başlatılmadan önce doğrulanır.
- Konteyner silme `force=false`, `v=false` ile yapılır: çalışan konteyner silinmez, birimler silinmez.
- `docker compose` çağrısı yalnızca `-p ADI stop` veya `-p ADI down` taşır; `--volumes`, `--rmi` gibi bayraklar eklenmez.
- Tek prune çağrısı `POST /build/prune` (yalnızca build önbelleği) olarak kodlanmıştır; imaj, birim, konteyner veya sistem prune'u yoktur. Listeleme ve build önbelleği ölçümü yalnızca `GET` kullanır.
- Uzak Docker bağlamları (`ssh://`, `tcp://`) desteklenmez; bu durumda "Uzak Docker bağlamı desteklenmiyor" hatası gösterilir.

### Sayfa başlığı okuma (`Web/LoopbackHTTP.swift`, `Web/PageTitleFetcher.swift`, `Web/HTMLTitle.swift`)

- Ağdan dışarı hiçbir şey gitmez: istemci yalnızca `127.0.0.0/8` sayısal adreslerine, `localhost`'a ve `::1`'e bağlanır; ana makine adları çözümlenmez. Yönlendirmeler başka bir ana makineye, başka bir porta, `https`'e, kullanıcı bilgili (`user@`) adrese ya da kontrol karakteri içeren hedefe izlenmez (bağlantı kurulmadan önce reddedilir).
- Her istek sınırlıdır: toplam 3 sn, adres başına 1,5 sn bağlanma, en çok 256 KB gövde, en çok 2 yönlendirme; gövde sınırında veya `</head>` sonrasında bağlantı kapatılır. Çerez, önbellek, kimlik bilgisi ve vekil sunucu kullanılmaz (BSD soketi; URLSession/ATS yok).
- Sunucu kimliği başına en çok bir istek (+ başarısızlık için 60 sn sonra bir yeniden deneme); yalnızca Sunucular sekmesi görünürken ve Ayarlar > Genel'deki seçenek açıkken. Seçenek kapalıyken hiçbir istek gönderilmez.
- Dışarıdan gelen metin (sayfa başlığı, manifest adı, klasör/depo/çalışma alanı/süreç adı, dal) ekrana varmadan önce temizlenir: kontrol, biçim (sıfır genişlikli, çift yönlü, etiket) karakterleri ve satır sonları atılır, boşluklar tek boşluğa iner, birleştirme işareti yığınları (taban başına en çok 4) ve sıfır genişlikli birleştirici zincirleri (en çok 3) kısaltılır, uzunluk karakterle değil Unicode skaler sayısıyla sınırlanır (120 karakter, en çok 480 skaler); görünür bir şey kalmayan ad ya da başlık gösterilmez (yerine manifest/klasör adı gelir). Yollar ve komut satırları boşlukları korunarak gösterilir, görünmez karakterler `�` ile değiştirilir. Metin `Text(verbatim:)` ile çizilir (Markdown/yerelleştirme anahtarı olarak yorumlanmaz); HTML hiçbir zaman çalıştırılmaz veya görüntülenmez.

### Denetim günlüğü

Her silme, süreç sonlandırma ve Docker eylemi `~/Library/Logs/DevTidy/cleanup.log` dosyasına JSON satırı olarak yazılır (`time`, `kind`, `subject`, `result`, `detail`; `kind`: `cleanup`, `terminate`, `dockerContainer`, `dockerCompose`, `dockerPrune`). Her silmeden önce bir `intent` satırı, sonra sonuç satırı yazılır (hedef başına iki satır: niyet + sonuç); Çöp Kutusu'na taşımalarda sonuç satırı `trashURL` değerini de taşır — en çok 50 konum ve 8 KiB (UTF-8), taşınan öğelerin bir önekidir, kalanı son bir `+N more` satırıyla sayılır —, bir yalnızca-içerik Çöp Kutusu taşıması yarıda başarısız olursa `failed:` satırı da (taşınabilen alt öğelerin yerlerini aynı sınırla listeleyerek) `trashURL` taşır. Atlanan ve reddedilen işlemler de nedeniyle birlikte kaydedilir; hiçbir şeye dokunulmadan reddedilen bir plan (30 dakikadan eski ya da kök artık geçerli değil) `refused:planStale` veya `refused:rootRejected` sonuçlu, reddedilen plan başına tek bir satır yazar (`subject` = plan kökü, `detail` = plan/öğeler). Docker hata metni günlüğe en çok 2 KB, Compose stderr'i en çok 4 KB olarak yazılır. Bir satır yazılamazsa çalışma durur ve kalan öğeler `denetim günlüğü yazılamıyor` ile raporlanır. Klasör `0700`, dosya `0600` izniyle oluşturulur; dosya 1 MiB'ı aşınca `cleanup.log.1` adına döndürülür ve son 5 nesil (`cleanup.log.1`…`.5`) saklanır. Ayarlar penceresindeki "Denetim günlüğünü Finder'da göster" düğmesi dosyayı açar. Hata kayıtları ayrıca `os.Logger` ile (`dev.minata.DevTidy`) yazılır; sayfa başlığı okuma yalnızca sonuç sınıfını ve deneme sayısını (`pagetitle` kategorisi, hata ayıklama düzeyi) kaydeder, başlığın kendisini asla.

## Ayarlar

Açılır pencerede `Ayarlar…` (⌘,). Değerler `UserDefaults` içinde `devtidy.settings.v1` anahtarında JSON olarak saklanır.

| Sekme | Ayar | Varsayılan | Aralık |
|---|---|---|---|
| Genel | Menü çubuğunda bellek kullanımını göster | açık | |
| Genel | Diğer dinleyicileri göster | kapalı | |
| Genel | Sayfa başlığını oku (localhost'a tek GET isteği) | açık | |
| Tarama | Taranan klasörler | boşsa `~/developer` | `+`/`−` ile eklenir/çıkarılır; ev dizininin altında olmalı |
| Tarama | Tarama derinliği | 4 | 2–6 |
| Tarama | node_modules ve diğer bağımlılıkları listele | kapalı | |
| Boşta | Sunucu: sessiz kalma süresi | 30 dk | 5–480 dk |
| Boşta | Konteyner: sessiz kalma süresi | 15 dk | 1–480 dk |
| Boşta | CPU eşiği | %1 | %0,5–%20 |
| Docker | Docker soket yolu | boş (otomatik bulunur) | |

"Koşullu öğeleri kalıcı sil" seçeneği ayrı bir ayar sekmesinde değil, temizlik ekranında bulunur (yukarıya bakın).

Tarama sınırları sabittir: en çok 25 000 klasör, 15 saniye, 300 git sorgusu. Sınıra ulaşılırsa sekmede "Tarama sınırına ulaşıldı" yazar. Tarama gizli klasörlere, `node_modules`, `dist`, `build`, `target`, `vendor`, `Library` gibi derlenmiş/bağımlılık klasörlerine ve `.app`/`.xcodeproj` gibi paketlere girmez; başka bir diske geçmez. Bir tarama kökü açılamıyorsa sekme, Sistem Ayarları > Gizlilik ve Güvenlik > Dosyalar ve Klasörler'den izin verilmesini ister.

Yoklama sıklığı (pencere açıkken / kapalıyken; Düşük Güç Modu'nda süreler ikiye katlanır):

| Döngü | Açık | Kapalı |
|---|---|---|
| Süreç taraması | 2 sn | 10 sn |
| Docker listesi | 3 sn | 30 sn |
| Docker istatistikleri (CPU/bellek) | 10 sn | 120 sn |

İstatistik döngüsü yalnızca çalışan konteyner varsa çalışır. Docker kapalıyken liste aralığı 15 sn / 60 sn olur. Docker sekmesi açıkken build önbelleği özeti en fazla 5 dakikada bir yenilenir. Süreç ve Docker sonuçlarının sırası duvar saatine değil isteğin yapıldığı ana bağlıdır: yavaş biten eski bir istek yeni bir sonucun üstüne yazmaz ve sistem saati geri alınsa da listeler donmaz.

## Testler

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # xcode-select Xcode'u göstermiyorsa
swift test
```

Testler swift-testing ile yazılmıştır (`Tests/DevTidyCoreTests`). Docker testleri sahte taşıyıcı kullanır, gerçek Docker soketine istek atmaz; canlı süreç testleri yalnızca kendi başlattıkları süreçleri sonlandırır; ayar testleri gerçek tercihlere yazmaz. Sayfa başlığı testleri yalnızca kendi başlattıkları loopback HTTP sunucularına istek atar (gerçek geliştirme sunucularına asla); kimlik testleri geçici klasör ağaçlarında çalışır; kurulum betiği testleri betiğin bir kopyasını geçici bir `HOME` ile çalıştırır.

`scripts/smoke.sh` canlı uçtan uca denemedir: `$HOME` altında geçici bir proje (`~/devtidy-smoke-XXXXXXXX`) ve kendi başlattığı bir `python3 -m http.server` ile `swift test --filter LiveSmokeTests` komutunu iki durumda (sunucu kendi süreç grubunda / betiğin grubunda) çalıştırır; başarıda `SMOKE OK` yazar. Proje kimliğini (depo, manifest adı, dal) ve betiğin kendi sunucusundan `GET /` ile okunan sayfa başlığını da doğrular. Docker'a yalnızca okuma amaçlı bağlanır. `python3` ve `git` gerektirir; `HOME` boşsa/göreliyse hiçbir şey oluşturmadan çıkar; geçici proje ve sunucu betik çıkışında temizlenir. Denetim satırlarını gerçek `~/Library/Logs/DevTidy/cleanup.log` yerine geçici bir dosyaya yazar ve onu da siler.

## Mimari

| Hedef | Klasör | İçerik |
|---|---|---|
| `CDevTidyShim` | `Sources/CDevTidyShim` | Çok küçük C katmanı: `openat`/`fstatat` için `O_NOFOLLOW_ANY` sarmalayıcıları (3 fonksiyon) |
| `DevTidyCore` | `Sources/DevTidyCore` | Arayüzsüz mantık. `Shared/` (modeller, protokoller, komut çalıştırıcı), `Processes/` (libproc tarama, sunucu sınıflandırma, süreç ağacı sonlandırma), `Projects/` (proje tespiti ve kimliği, önbellek kataloğu, tarayıcı, temizleyici, `SafeFS`, denetim günlüğü), `Web/` (yalnızca loopback HTTP istemcisi, sayfa başlığı ayrıştırıcı ve `PageTitleFetcher`), `Docker/` (Engine API istemcisi, unix soket HTTP, Compose CLI, `ToolLocator`), `Store/` (`DevTidyStore`, ayarlar, yoklama, boşta takibi, temizlik akışı) |
| `DevTidy` | `Sources/DevTidy` | SwiftUI menü çubuğu uygulaması: `DevTidyApp`, `MenuBarLabel`, `PopoverRoot`, `ServersTab`, `DockerTab`, `BuildsTab`, `CleanupSheet`, `SettingsView`, `Components`, `Formatting` |
| `DevTidyCoreTests` | `Tests/DevTidyCoreTests` | `Processes/`, `Projects/`, `Docker/`, `Web/`, `Store/`, `Smoke/` |

Ayrıca `Resources/Info.plist` (paket şablonu), `scripts/` (`bundle.sh`, `dmg.sh`, `cask.sh`, `release.sh`, `install.sh`, `smoke.sh`) ve `packaging/homebrew-tap/` (tap deposunun ilk içeriği: README ve `audit.yml` iş akışı) vardır.

## Sürüm yayınlama (bakımcı)

Sürümler yerel Mac'ten `scripts/release.sh` ile yayınlanır (GitHub Actions derleme hattı yoktur). Hat: Developer ID ile imzalı evrensel `.app` → notarization + staple → imzalı DMG → notarization + staple → etiket + GitHub release → `suleymanozcan/homebrew-tap` içindeki `Casks/devtidy.rb`.

### Bir kerelik hazırlık

1. **Developer ID Application sertifikasını** oluşturun: Xcode › Settings › Accounts › Manage Certificates › **+** › Developer ID Application (yalnızca Account Holder oluşturabilir). Kontrol: `security find-identity -v -p codesigning`.
2. **Notarization kimlik bilgilerini** anahtarlığa kaydedin (App Store Connect API anahtarı; `.p8` dosyası depoya girmez, `.gitignore`'da `*.p8` vardır):

   ```bash
   xcrun notarytool store-credentials devtidy-notary --key ~/.private_keys/AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUER_UUID>
   ```

3. `gh auth login` ile GitHub CLI oturumu açın.
4. Depo GitHub'da `suleymanozcan/devtidy` olarak bulunmalı, `origin` ona bakmalı ve `main` push edilmiş olmalı.

### Yayınlama

```bash
scripts/release.sh 0.1.0
```

Önce yan etkisiz bir ön kontrol çalışır; eksik her şey Türkçe mesaj ve düzeltme komutuyla birlikte topluca listelenir: sürüm biçimi (`MAJOR.MINOR.PATCH`), temiz çalışma ağacı ve `main` dalı, `v<sürüm>` etiketinin yerelde ve `origin`'de olmaması, `origin/main`'in yerel `main` ile aynı olması, `gh auth status`, Developer ID Application kimliği ve `notarytool` profili. Ön kontrol geçerse sırayla: `swift test`, `scripts/bundle.sh` (imzalı), `.app` notarization + staple + `spctl`, `scripts/dmg.sh` (imzalı), DMG notarization + staple + `spctl`, sha256, etiket + push, `gh release create`, tap güncellemesi (tap yoksa `packaging/homebrew-tap/` içeriğinden public olarak oluşturulur). Etiket push edilene kadar herhangi bir adım başarısız olursa dışarıda hiçbir şey yayınlanmamıştır.

Ortam değişkenleri: `SIGN_IDENTITY` (otomatik bulunan kimliği geçersiz kılar; SHA-1 ya da tam ad), `NOTARY_PROFILE` (varsayılan `devtidy-notary`).

Parçalar tek başına da kullanılabilir: `scripts/dmg.sh <app> <sürüm>` → `dist/DevTidy-<sürüm>.dmg` (`SIGN=<kimlik>` DMG'yi imzalar); `scripts/cask.sh <sürüm> <sha256>` cask'i stdout'a yazar (cask şablonunun tek kaynağı).

## Bilinen sınırlamalar

- `bundle.sh`'ın varsayılan imzası ad hoc'tur (kaynaktan kurulumda Gatekeeper onayı yoktur); noter onaylı sürüm yalnızca `scripts/release.sh` ile yayınlanır. Uygulama sandbox içinde çalışmaz.
- Oturum açılışında otomatik başlatma yoktur; isterseniz `~/Applications/DevTidy.app` macOS'taki Login Items listesine elle eklenebilir.
- Yalnızca sizin kullanıcınıza ait süreçlerin dinleyen TCP soketleri görülür. UDP, unix soketleri ve henüz dinlemeye başlamamış süreçler görünmez.
- Önbellek temizliği yalnızca ev dizini altında en az 2 seviye derindeki projeler için çalışır (`~/proje` reddedilir); tarama kökleri de ev dizininin altında olmalıdır. Başka bir diskteki projeler taranmaz.
- Önbellek kataloğu kapalıdır; katalogda olmayan klasörler (özel derleme klasörleriniz dahil) hiçbir zaman sunulmaz. Git kullanılamıyorsa öğe sunulmaz veya silinmez.
- Docker için yalnızca yerel unix soketi desteklenir. Compose eylemleri `docker` komutunu yukarıdaki sabit yollarda arar ve proje adıyla, compose dosyası verilmeden çalıştırır; komut her zaman çözümlenen yerel sokete (`DOCKER_HOST=unix://…`) sabitlenir, reddedilen/uzak bağlamda ya da soket yokken hiçbir `docker` süreci başlatılmaz. Başarısız olursa `docker`'ın hata çıktısı hata bandında gösterilir.
- Sayfa başlığı ilk HTML yanıtından okunur; JavaScript çalıştırılmaz. İstemci tarafında `document.title` ayarlayan sayfalar şablon başlığıyla (yok sayılan `Vite App` gibi) görünür, yani başlık yoktur. Yalnızca belirli bir sanal ana makine adıyla yanıt veren sunucular `127.0.0.1` / `localhost` ile okunamaz; HTTPS ile çalışan bir sunucu düz isteğe yanıt vermediği için okunamaz. İstek sunucunuzun kendi günlüğünde bir `GET /` olarak görünür ve Next.js gibi çalışırken derleyen sunucularda ilk istek sayfa derlemesini başlatabilir (bu yüzden boşta işaretli sunuculara istek gönderilmez, istek boşta sayacını etkilemez). IPv4 önce denendiği için, aynı portun `::1`'inde başka bir sunucu, `127.0.0.1`'inde başka bir süreç dinliyorsa başlık yanlış süreçten okunabilir (nadir; yalnızca yanlış eşleştirme).
- Boşta tespiti DevTidy'nin gözlemine dayanır: DevTidy'yi yeni açtıysanız uzun süredir sessiz bir konteyner, eşik kadar gözlemlenene dek "Muhtemelen boşta" kalır ve "Boştakileri Durdur" kapsamına girmez.
- Bellek: pencere kapalı ve boştayken `ps` ile ölçülen RSS ≈ 80 MiB (QA2: 78,6–80,5 MiB), `phys_footprint` ≈ 17–18 MiB. Tasarım hedefi olan 60 MB RSS aşılıyor; farkın büyük ölçüde SwiftUI/AppKit tabanından geldiği tahmin edilir (ölçülmedi). Boşta CPU ≈ %0,21 (hedef < %0,5). Süreç taraması + sınıflandırma ≈ 19 ms (10 + 9 ms, 423 süreç, tek örnek; p95 değil); tasarım hedefi olan p95 < 15 ms aşılıyor: sınıflandırma her kullanıcı sürecinin yürütülebilir yolunu (`proc_pidpath`) okuyor, çünkü tarayıcı/`.app` alt süreçlerini tanımak yürütülebilir yolu tarama bittikten sonra gerektiriyor. Ana iş parçacığında çalışmaz; kabul edilmiş sapma.
- Silinen önbellekler, kalıcı silinenler dahil, geri getirilemez; Çöp Kutusu'na taşınanların disk alanı Çöp Kutusu boşaltılınca açılır.
- Arayüz yalnızca Türkçedir.

## Lisans

MIT, bkz. `LICENSE`.
