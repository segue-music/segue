#!/bin/sh
# Adds Segue to this user's application menu, with its icon: a .desktop file that points at this
# folder, in ~/.local/share/applications. On Wayland the window takes its icon from that file too,
# found by the application id. Run it again after moving the folder; delete the file it prints to
# take Segue off the menu.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
apps=${XDG_DATA_HOME:-$HOME/.local/share}/applications
mkdir -p "$apps"
cat > "$apps/@APPLICATION_ID@.desktop" <<END
[Desktop Entry]
Type=Application
Name=Segue
Comment=Player de música do Navidrome, com Segue Connect
Exec="$dir/@BINARY_NAME@"
Icon=$dir/data/app_icon.png
Terminal=false
Categories=AudioVideo;Audio;Player;
StartupWMClass=@APPLICATION_ID@
END
echo "$apps/@APPLICATION_ID@.desktop"
