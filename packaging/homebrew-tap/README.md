# suleymanozcan/homebrew-tap

[DevTidy](https://github.com/suleymanozcan/devtidy) için Homebrew tap'i: unutulmuş geliştirme sunucularını, Docker konteynerlerini ve derleme önbelleklerini temizleyen menü çubuğu uygulaması.

## Kurulum

```sh
brew install --cask suleymanozcan/tap/devtidy
```

## Kaldırma

```sh
brew uninstall --zap --cask devtidy
```

## Notlar

- `Casks/devtidy.rb` elle düzenlenmez: her sürümde DevTidy deposundaki `scripts/release.sh` tarafından yazılır ve push edilir.
- `.github/workflows/audit.yml` her push ve pull request'te cask'i denetler (`brew style`, `brew audit --cask --strict --online`) ve gerçekten kurup imzayı doğrular.
