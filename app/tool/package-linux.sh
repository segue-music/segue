#!/bin/sh
# Builds the Linux version with tool/flutter.sh and packs it as build/segue-linux-x64.tar.gz, to run
# on another computer without Flutter. That computer needs glibc 2.38 or newer, GTK 3, libsecret
# and libmpv (libmpv.so.2 is enough: mpv-libs on Fedora, libmpv2 on Debian).
set -e
cd "$(dirname "$0")/.."
# The whole icon font, not one trimmed to the icons in use: an incremental release build can keep
# the trimmed font of the build before, so an icon added since shows as an empty button.
tool/flutter.sh build linux --release --no-tree-shake-icons
tar -C build/linux/x64/release -czf build/segue-linux-x64.tar.gz --transform 's,^bundle,segue,' bundle
echo "$(pwd)/build/segue-linux-x64.tar.gz"
