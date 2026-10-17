#!/usr/bin/env bash
# DevTidy sürüm yayını: test -> evrensel + imzalı .app -> notarization -> DMG -> notarization -> etiket -> GitHub release -> Homebrew tap.
#
# Kullanım: scripts/release.sh <sürüm>        (örn. scripts/release.sh 0.1.0)
#
# Ortam değişkenleri:
#   SIGN_TEAM       İmzalayan Developer ID sahibinin adı (varsayılan "Minata Entertainment, LLC"). Kimlik yalnızca bu adla seçilir.
#   SIGN_IDENTITY   Aynı ada ait birden fazla sertifika varsa seçilecek olanın SHA-1'i ya da tam adı.
#   NOTARY_PROFILE  notarytool anahtarlık profili (varsayılan devtidy-notary).
#
# Sıra bilinçli seçildi: etiket, release ve tap en sona kalır. Etiket push edilene kadar her hata dışarıda HİÇBİR şey bırakmaz
# (yalnızca build/, dist/ ve geçici dizin). Ön kontrol (preflight) hiçbir yan etki üretmez.
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "kullanım: scripts/release.sh <sürüm>   (örn. scripts/release.sh 0.1.0)" >&2
    exit 2
fi

VERSION="$1"
if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "release.sh: HATA: sürüm MAJOR.MINOR.PATCH biçiminde olmalı (örn. 0.1.0); verilen: '$VERSION'" >&2
    exit 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"

SRC_REPO="suleymanozcan/devtidy"
TAP_REPO="suleymanozcan/homebrew-tap"
TAG="v$VERSION"
NOTARY_PROFILE="${NOTARY_PROFILE:-devtidy-notary}"
SIGN_TEAM="${SIGN_TEAM:-Minata Entertainment, LLC}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
APP="build/DevTidy.app"
DMG="dist/DevTidy-$VERSION.dmg"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ -d "$DEVELOPER_DIR" ]]; then
    export DEVELOPER_DIR
else
    unset DEVELOPER_DIR
fi

# ---------------------------------------------------------------------------------------------------------------------
# Ön kontrol: hiçbir şey oluşturmaz, değiştirmez, yayınlamaz. Tüm sorunları toplar, sonda hepsini birlikte bildirir.
# ---------------------------------------------------------------------------------------------------------------------
PROBLEMS=0
problem() { # problem <mesaj> [çözüm satırları...]
    PROBLEMS=$((PROBLEMS + 1))
    echo "  [HATA] $1" >&2
    shift
    local line
    for line in "$@"; do echo "         $line" >&2; done
}

echo "==> Ön kontrol (yan etkisiz)"

for tool in git gh swift ditto lipo hdiutil codesign shasum security spctl plutil ruby; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        if [[ "$tool" == "gh" ]]; then
            problem "'gh' (GitHub CLI) bulunamadı." "Çözüm: brew install gh && gh auth login"
        else
            problem "'$tool' bulunamadı." "Çözüm: xcode-select --install"
        fi
    fi
done
if ! xcrun --find notarytool >/dev/null 2>&1 || ! xcrun --find stapler >/dev/null 2>&1; then
    problem "xcrun notarytool / stapler bulunamadı (Xcode 13+ gerekir)." \
        "Çözüm: Xcode'u kurun ya da güncelleyin, sonra: sudo xcode-select -s /Applications/Xcode.app"
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    problem "Bu dizin bir git deposu değil." "Çözüm: git init -b main && git add -A && git commit -m 'İlk commit'"
else
    branch="$(git symbolic-ref --short -q HEAD || true)"
    if [[ "$branch" != "main" ]]; then
        problem "Geçerli dal 'main' değil (${branch:-detached HEAD})." "Çözüm: git switch main"
    fi
    if ! git rev-parse --verify -q HEAD >/dev/null 2>&1; then
        problem "Depoda hiç commit yok." "Çözüm: git add -A && git commit -m 'İlk commit'"
    elif [[ -n "$(git status --porcelain)" ]]; then
        problem "Çalışma ağacı temiz değil (commit edilmemiş ya da izlenmeyen dosyalar var)." \
            "Çözüm: git status   # sonra commit edin ya da: git stash -u"
    fi
    if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
        problem "'$TAG' etiketi yerelde zaten var." "Çözüm: git tag -d $TAG   (ya da başka bir sürüm numarası verin)"
    fi

    origin_url="$(git remote get-url origin 2>/dev/null || true)"
    if [[ -z "$origin_url" ]]; then
        problem "'origin' uzak deposu tanımlı değil (etiket buraya push edilecek)." \
            "Çözüm: gh repo create $SRC_REPO --public --source=. --remote=origin --push"
    elif [[ ! "$origin_url" =~ [:/]suleymanozcan/devtidy(\.git)?/?$ ]]; then
        problem "'origin' $SRC_REPO değil: $origin_url" \
            "Çözüm: git remote set-url origin https://github.com/$SRC_REPO.git"
    else
        rc=0
        git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1 || rc=$?
        case "$rc" in
            0)
                problem "'$TAG' etiketi uzakta (origin) zaten var." \
                    "Çözüm: başka bir sürüm numarası verin (uzaktaki etiketi silmek yayınlanmış sürümü bozar)."
                ;;
            2)
                # Etiket yok: beklenen durum. Etiketlenecek commit uzaktaki main ile aynı olmalı.
                remote_main="$(git ls-remote origin refs/heads/main 2>/dev/null | awk '{print $1}')"
                if [[ -z "$remote_main" || "$remote_main" != "$(git rev-parse HEAD 2>/dev/null || true)" ]]; then
                    problem "origin/main yerel main ile aynı değil (push edilmemiş ya da uzak depo boş)." \
                        "Çözüm: git push -u origin main"
                fi
                ;;
            *)
                problem "origin'e erişilemedi (git ls-remote çıkış kodu $rc)." \
                    "Çözüm: ağı ve kimlik doğrulamayı kontrol edin: git ls-remote origin"
                ;;
        esac
    fi
fi

if command -v gh >/dev/null 2>&1 && ! gh auth status >/dev/null 2>&1; then
    problem "GitHub CLI oturumu açık değil (gh auth status başarısız)." "Çözüm: gh auth login"
fi

IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
# Yalnızca SIGN_TEAM adına düzenlenmiş Developer ID Application kimlikleri aday olur; başka takımla imzalama sessizce olmaz.
DEVID_LINES="$(grep -F "\"Developer ID Application: $SIGN_TEAM (" <<<"$IDENTITIES" || true)"
if [[ -n "$SIGN_IDENTITY" ]]; then
    DEVID_LINES="$(grep -F -- "$SIGN_IDENTITY" <<<"$DEVID_LINES" || true)"
fi
DEVID_COUNT="$(grep -c . <<<"$DEVID_LINES" || true)"
if [[ "$DEVID_COUNT" -eq 0 ]]; then
    problem "'Developer ID Application: $SIGN_TEAM' sertifikası bulunamadı${SIGN_IDENTITY:+ (SIGN_IDENTITY='$SIGN_IDENTITY' ile eşleşen)}." \
        "Çözüm: Xcode › Settings › Accounts › $SIGN_TEAM takımı › Manage Certificates › + › Developer ID Application (yalnızca Account Holder oluşturabilir)." \
        "Kontrol: security find-identity -v -p codesigning"
elif [[ "$DEVID_COUNT" -gt 1 ]]; then
    problem "'$SIGN_TEAM' adına birden fazla Developer ID Application sertifikası var; hangisinin kullanılacağı belirsiz." \
        "Çözüm: SIGN_IDENTITY='<SHA-1>' scripts/release.sh $VERSION   (SHA-1 listesi: security find-identity -v -p codesigning)"
else
    SIGN_IDENTITY="$(awk '{print $2}' <<<"$DEVID_LINES")"
    IDENTITY_NAME="$(sed -E 's/^[^"]*"([^"]*)".*$/\1/' <<<"$DEVID_LINES")"
fi

if xcrun --find notarytool >/dev/null 2>&1; then
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        problem "notarytool anahtarlık profili '$NOTARY_PROFILE' çalışmıyor (kayıtlı değil, hatalı ya da ağ yok)." \
            "Çözüm: xcrun notarytool store-credentials $NOTARY_PROFILE --key ~/.private_keys/AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUER_UUID>" \
            "Kontrol: xcrun notarytool history --keychain-profile $NOTARY_PROFILE"
    fi
fi

if [[ "$PROBLEMS" -gt 0 ]]; then
    echo >&2
    echo "release.sh: ön kontrol BAŞARISIZ ($PROBLEMS sorun). Hiçbir şey yapılmadı: etiket, release, tap ya da depo oluşturulmadı." >&2
    exit 1
fi
echo "    sürüm $VERSION, kimlik: ${IDENTITY_NAME:-$SIGN_IDENTITY}, notary profili: $NOTARY_PROFILE"

# ---------------------------------------------------------------------------------------------------------------------
# Yayın öncesi aşama: burada başarısız olan her şey dışarıda hiçbir iz bırakmaz.
# ---------------------------------------------------------------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/devtidy-release.XXXXXX")"
PHASE=hazirlik       # hazirlik -> yayin
TAG_PUSHED=0
RELEASE_CREATED=0
SHA256=""

on_exit() {
    local rc=$?
    trap - EXIT
    if [[ "$rc" -ne 0 ]]; then
        echo >&2
        if [[ "$PHASE" == "hazirlik" ]]; then
            echo "release.sh: BAŞARISIZ. Henüz hiçbir şey yayınlanmadı (etiket, release ve tap yok); düzeltip yeniden çalıştırabilirsiniz." >&2
        else
            echo "release.sh: yayın aşamasında BAŞARISIZ. Durum: etiket push edildi=$TAG_PUSHED, GitHub release=$RELEASE_CREATED." >&2
            if [[ "$TAG_PUSHED" == 1 && "$RELEASE_CREATED" != 1 ]]; then
                echo "  Release'i elle tamamlayın: gh release create $TAG $DMG --repo $SRC_REPO --verify-tag --title 'DevTidy $VERSION' --generate-notes" >&2
            fi
            if [[ "$RELEASE_CREATED" == 1 && -n "$SHA256" ]]; then
                echo "  Tap'i elle güncelleyin: scripts/cask.sh $VERSION $SHA256 > Casks/devtidy.rb   (suleymanozcan/homebrew-tap içinde commit + push)" >&2
            fi
        fi
    fi
    case "$WORK" in
        */devtidy-release.*) rm -rf "$WORK" ;;
    esac
    exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# notarize <dosya>: notarytool'a gönderir, "Accepted" olmadıkça hata verir (çıkış kodu tek başına güvenilir değil).
notarize() {
    local file="$1" out id
    out="$WORK/notary-$(basename "$file").txt"
    echo "==> notarytool submit $(basename "$file")  (Apple'ın yanıtı birkaç dakika sürebilir)"
    if ! xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee "$out"; then
        echo "release.sh: notarytool submit başarısız ($file)" >&2
        exit 1
    fi
    if ! grep -qE '^[[:space:]]*status: Accepted[[:space:]]*$' "$out"; then
        id="$(sed -nE 's/^[[:space:]]*id: ([0-9a-fA-F-]{36}).*$/\1/p' "$out" | head -n 1)"
        echo "release.sh: notarization 'Accepted' olmadı ($file)." >&2
        [[ -n "$id" ]] && echo "  Ayrıntı: xcrun notarytool log $id --keychain-profile $NOTARY_PROFILE" >&2
        exit 1
    fi
}

echo "==> [1/8] swift test"
swift test

echo "==> [2/8] evrensel imzalı $APP"
SIGN="$SIGN_IDENTITY" VERSION="$VERSION" scripts/bundle.sh
if ! codesign -dv --verbose=4 "$APP" 2>&1 | grep -qF "Authority=Developer ID Application: $SIGN_TEAM ("; then
    echo "release.sh: HATA: $APP '$SIGN_TEAM' Developer ID ile imzalanmamış; yayın durduruldu (dışarıda hiçbir şey oluşturulmadı)." >&2
    exit 1
fi

echo "==> [3/8] .app notarization + staple"
ditto -c -k --keepParent "$APP" "$WORK/DevTidy-$VERSION-app.zip"
notarize "$WORK/DevTidy-$VERSION-app.zip"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv "$APP"

echo "==> [4/8] DMG"
SIGN="$SIGN_IDENTITY" scripts/dmg.sh "$APP" "$VERSION"

echo "==> [5/8] DMG notarization + staple"
notarize "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -vv -t open --context context:primary-signature "$DMG"

# Staple DMG'yi değiştirir: sha256 ondan SONRA hesaplanır.
SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "    sha256: $SHA256"

# ---------------------------------------------------------------------------------------------------------------------
# Yayın aşaması: artık dışarıya yazılır.
# ---------------------------------------------------------------------------------------------------------------------
PHASE=yayin

echo "==> [6/8] etiket $TAG"
git tag -a "$TAG" -m "DevTidy $VERSION"
if ! git push origin "refs/tags/$TAG"; then
    git tag -d "$TAG" >/dev/null
    echo "release.sh: etiket push edilemedi; yerel etiket geri alındı, dışarıda hiçbir şey yok." >&2
    exit 1
fi
TAG_PUSHED=1

echo "==> [7/8] GitHub release"
gh release create "$TAG" "$DMG" --repo "$SRC_REPO" --verify-tag --title "DevTidy $VERSION" --generate-notes
RELEASE_CREATED=1

echo "==> [8/8] Homebrew tap ($TAP_REPO)"
TAP_DIR="$WORK/tap"
if tap_probe="$(gh api "repos/$TAP_REPO" --jq .full_name 2>&1)"; then
    gh repo clone "$TAP_REPO" "$TAP_DIR" -- --quiet
elif [[ "$tap_probe" == *"Not Found"* || "$tap_probe" == *"HTTP 404"* ]]; then
    echo "    tap yok; packaging/homebrew-tap/ içeriğinden public olarak oluşturuluyor"
    mkdir -p "$TAP_DIR"
    cp -R "$ROOT/packaging/homebrew-tap/." "$TAP_DIR/"
    git -C "$TAP_DIR" init -q -b main
    git -C "$TAP_DIR" add -A
    git -C "$TAP_DIR" commit -q -m "İlk tap içeriği"
    gh repo create "$TAP_REPO" --public --description "Homebrew tap: DevTidy" --source "$TAP_DIR" --remote origin --push
else
    echo "release.sh: tap deposu sorgulanamadı: $tap_probe" >&2
    exit 1
fi

mkdir -p "$TAP_DIR/Casks"
"$ROOT/scripts/cask.sh" "$VERSION" "$SHA256" > "$TAP_DIR/Casks/devtidy.rb"
ruby -c "$TAP_DIR/Casks/devtidy.rb" >/dev/null
git -C "$TAP_DIR" add Casks/devtidy.rb
if git -C "$TAP_DIR" diff --cached --quiet; then
    echo "    Casks/devtidy.rb zaten güncel"
else
    git -C "$TAP_DIR" commit -q -m "devtidy $VERSION"
    git -C "$TAP_DIR" push -q origin HEAD:main
fi

echo
echo "==> DevTidy $VERSION yayınlandı."
echo "    Kurulum: brew install --cask suleymanozcan/tap/devtidy"
