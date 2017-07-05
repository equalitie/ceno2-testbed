#!/bin/sh

# Load our own config
. /usr/local/etc/ooniconf.sh

cd "$PROBE_SRC"

. "${PROBE_VENV}/bin/activate"

python ooni/scripts/ooniprobe.py -n \
  ooni/nettests/experimental/peer_http_reachable.py --file="$PROBE_PEERLIST"
