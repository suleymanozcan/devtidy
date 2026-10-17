#!/usr/bin/env bash
# Prints the Sparkle appcast (one item: the release being published) to stdout. The single source of the appcast template:
# scripts/release.sh writes this output to dist/appcast.xml and uploads it as a release asset next to the DMG, which is what the
# app's SUFeedURL (.../releases/latest/download/appcast.xml) resolves to.
#
# Usage: scripts/appcast.sh <version> <build> <length of dist/DevTidy-<version>.dmg> <sparkle:edSignature of that DMG>
#   version  CFBundleShortVersionString (MAJOR.MINOR.PATCH)
#   build    CFBundleVersion of the bundled app: Sparkle compares it with the installed app's, so it must grow with every release
#   length / edSignature   from `sign_update dist/DevTidy-<version>.dmg`, run AFTER the DMG was notarized and stapled
set -euo pipefail

if [[ $# -ne 4 ]]; then
    echo "usage: scripts/appcast.sh <version> <build> <length> <edSignature>" >&2
    exit 2
fi

VERSION="$1"
BUILD="$2"
LENGTH="$3"
ED_SIGNATURE="$4"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "appcast.sh: version must look like 0.1.0 (got '$VERSION')" >&2
    exit 1
fi
if [[ ! "$BUILD" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "appcast.sh: build must be 1-3 dot-separated integers, like CFBundleVersion (got '$BUILD')" >&2
    exit 1
fi
if [[ ! "$LENGTH" =~ ^[1-9][0-9]*$ ]]; then
    echo "appcast.sh: length must be a positive byte count (got '$LENGTH')" >&2
    exit 1
fi
# Base64 alphabet only: nothing here needs XML escaping, which the checks above and this one guarantee.
if [[ ! "$ED_SIGNATURE" =~ ^[A-Za-z0-9+/]+={0,2}$ ]]; then
    echo "appcast.sh: edSignature must be base64 (got '$ED_SIGNATURE')" >&2
    exit 1
fi

# RFC 822 date in English regardless of the caller's locale.
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
URL="https://github.com/suleymanozcan/devtidy/releases/download/v$VERSION/DevTidy-$VERSION.dmg"

cat <<APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>DevTidy</title>
    <link>https://github.com/suleymanozcan/devtidy</link>
    <description>DevTidy sürümleri</description>
    <language>tr</language>
    <item>
      <title>DevTidy $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="$URL" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$ED_SIGNATURE"/>
    </item>
  </channel>
</rss>
APPCAST
