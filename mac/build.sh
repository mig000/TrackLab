#!/bin/zsh
# Gera build/TrackLab.app: SwiftPM mais um bundle feito à mão, assinado ad hoc; sem Xcode. O bundle leva a página
# da partitura (web/) e grava onde está este repositório, para iniciar o motor (engine/.venv) a partir dele.
set -euo pipefail
script=${0:A}
cd "${script:h}"
swift build -c release
app="build/TrackLab.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/TrackLab "$app/Contents/MacOS/"
mkdir -p "$app/Contents/Resources/web/vendor/alphatab"
cp ../web/score.html ../web/score.css ../web/score.js ../web/score-core.js ../web/score-edit.js "$app/Contents/Resources/web/"
cp ../web/vendor/alphatab/alphaTab.js ../web/vendor/alphatab/Bravura.woff2 ../web/vendor/alphatab/Bravura-OFL.txt \
  "$app/Contents/Resources/web/vendor/alphatab/"
build=$(git rev-list --count HEAD 2>/dev/null || echo 1)
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>TrackLab</string>
  <key>CFBundleDisplayName</key><string>TrackLab</string>
  <key>CFBundleIdentifier</key><string>local.tracklab.app</string>
  <key>CFBundleExecutable</key><string>TrackLab</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>${build}</string>
  <key>NSHumanReadableCopyright</key><string>TrackLab — uso pessoal</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>TLRepoPath</key><string>${script:h:h}</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
echo "built $app"
