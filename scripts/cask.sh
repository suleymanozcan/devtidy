#!/usr/bin/env bash
# Prints the Homebrew cask for a DevTidy release to stdout. The single source of the cask template:
# scripts/release.sh writes this output to Casks/devtidy.rb in the tap.
#
# Usage: scripts/cask.sh <version> <sha256 of dist/DevTidy-<version>.dmg>
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: scripts/cask.sh <version> <sha256>" >&2
    exit 2
fi

VERSION="$1"
SHA256="$2"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "cask.sh: version must look like 0.1.0 (got '$VERSION')" >&2
    exit 1
fi
if [[ ! "$SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "cask.sh: sha256 must be 64 lowercase hex characters (got '$SHA256')" >&2
    exit 1
fi

# The heredoc is quoted: `#{version}` is Ruby interpolation for the cask, not shell. VERSION and SHA256 are substituted below.
cat <<'CASK' | sed -e "s|__VERSION__|$VERSION|" -e "s|__SHA256__|$SHA256|"
cask "devtidy" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/suleymanozcan/devtidy/releases/download/v#{version}/DevTidy-#{version}.dmg"
  name "DevTidy"
  desc "Menu bar app to stop forgotten dev servers, Docker containers and build caches"
  homepage "https://github.com/suleymanozcan/devtidy"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "DevTidy.app"

  uninstall quit: "dev.minata.DevTidy"

  zap trash: [
    "~/Library/Logs/DevTidy",
    "~/Library/Preferences/dev.minata.DevTidy.plist",
  ]
end
CASK
