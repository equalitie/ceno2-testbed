#!/bin/sh
TORRENT=/opt/transmission/NOOBS_lite_v2_4.zip.torrent
CLIENT=/opt/transmission/bin/transmission-cli
DIR=`mktemp -d`
CURRENT="$pwd"
rm -rf ~/.config/transmission
cd "$DIR"
"$CLIENT" --download-dir . "$TORRENT" >/dev/null 2>/dev/null
cat transmission-instrumentation.log.json
cd "$CURRENT"
rm -rf "$DIR"
