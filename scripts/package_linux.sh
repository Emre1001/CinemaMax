#!/usr/bin/env bash
# Baut CinemaMax für Linux und erzeugt .deb, .rpm und .AppImage in dist/.
# Voraussetzung (Ubuntu/Mint/Debian):
#   sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev libmpv-dev rpm file
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(grep '^version:' pubspec.yaml | sed 's/version: *//; s/+.*//')
ARCH=x86_64
BUNDLE=build/linux/x64/release/bundle
OUT=dist
WORK=build/pkg
rm -rf "$WORK" && mkdir -p "$OUT" "$WORK"

[ "${SKIP_BUILD:-0}" = 1 ] || flutter build linux --release

# Gemeinsame Dateistruktur: App unter /opt/cinemamax, Starter in /usr/bin
stage() {
  local root=$1
  mkdir -p "$root/opt/cinemamax" "$root/usr/bin" "$root/usr/share/applications" \
           "$root/usr/share/icons/hicolor/512x512/apps"
  cp -r "$BUNDLE"/. "$root/opt/cinemamax/"
  ln -sf /opt/cinemamax/cinemamax "$root/usr/bin/cinemamax"
  cp linux/packaging/cinemamax.desktop "$root/usr/share/applications/"
  cp assets/icon.png "$root/usr/share/icons/hicolor/512x512/apps/cinemamax.png"
}

# ---------- .deb ----------
DEB=$WORK/deb
stage "$DEB"
mkdir -p "$DEB/DEBIAN"
cat > "$DEB/DEBIAN/control" <<CTRL
Package: cinemamax
Version: $VERSION
Architecture: amd64
Maintainer: CinemaMax
Depends: libgtk-3-0, libmpv2 | libmpv1
Section: video
Priority: optional
Description: IPTV, M3U und Xtream-Codes Player
CTRL
dpkg-deb --build --root-owner-group "$DEB" "$OUT/cinemamax_${VERSION}_amd64.deb"

# ---------- .rpm ----------
RPMTOP=$(realpath "$WORK")/rpm
mkdir -p "$RPMTOP"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
stage "$RPMTOP/root"
cat > "$RPMTOP/SPECS/cinemamax.spec" <<SPEC
Name: cinemamax
Version: $VERSION
Release: 1
Summary: IPTV, M3U und Xtream-Codes Player
License: Proprietary
Requires: gtk3, mpv-libs
AutoReqProv: no
%description
IPTV, M3U und Xtream-Codes Player.
%install
cp -a $RPMTOP/root/. %{buildroot}/
%files
/opt/cinemamax
/usr/bin/cinemamax
/usr/share/applications/cinemamax.desktop
/usr/share/icons/hicolor/512x512/apps/cinemamax.png
SPEC
rpmbuild --define "_topdir $RPMTOP" --define "debug_package %{nil}" -bb "$RPMTOP/SPECS/cinemamax.spec"
cp "$RPMTOP"/RPMS/*/*.rpm "$OUT/"

# ---------- .AppImage (libmpv wird mitgeliefert) ----------
APPDIR=$WORK/AppDir
stage "$APPDIR"
rm "$APPDIR/usr/bin/cinemamax"
mkdir -p "$APPDIR/usr/lib" && mv "$APPDIR/opt/cinemamax" "$APPDIR/usr/lib/cinemamax" && rmdir "$APPDIR/opt"
# AppRun außerhalb des AppDir anlegen: linuxdeploy kopiert es selbst hinein
cat > "$WORK/AppRun" <<'RUN'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$HERE/usr/lib:$HERE/usr/lib/cinemamax/lib:${LD_LIBRARY_PATH:-}"
exec "$HERE/usr/lib/cinemamax/cinemamax" "$@"
RUN
chmod +x "$WORK/AppRun"
cp linux/packaging/cinemamax.desktop "$APPDIR/"
cp assets/icon.png "$APPDIR/cinemamax.png"
TOOLS=$WORK/tools && mkdir -p "$TOOLS"
LD=$TOOLS/linuxdeploy.AppImage
curl -fsSL -o "$LD" https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage
chmod +x "$LD"
# libmpv wird per dlopen geladen: explizit samt Abhängigkeiten einpacken
# awk liest alles (kein vorzeitiges Ende: sonst SIGPIPE mit pipefail)
LIBMPV=$(ldconfig -p | awk '/libmpv\.so\.[0-9] /{p=$NF} END{print p}')
APPIMAGE_EXTRACT_AND_RUN=1 ARCH=$ARCH VERSION=$VERSION LDAI_OUTPUT="$OUT/CinemaMax-${VERSION}-${ARCH}.AppImage" \
  "$LD" --appdir "$APPDIR" --executable "$APPDIR/usr/lib/cinemamax/cinemamax" \
  --library "$LIBMPV" --desktop-file "$APPDIR/cinemamax.desktop" --icon-file "$APPDIR/cinemamax.png" \
  --custom-apprun "$WORK/AppRun" --output appimage

ls -lh "$OUT"
