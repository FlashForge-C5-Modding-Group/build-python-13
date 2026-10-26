#!/bin/sh
# On a K1 (SimpleAF): run Klippy on /usr/data/python-hf instead of
# /usr/share/klippy-env, with the same arguments and PID file as
# /etc/init.d/S55klipper_service. The Kalico tree isn't modified: Klippy runs
# from a copy of klippy/ with the bundle's c_helper.so.
#
# Undo: /etc/init.d/S55klipper_service restart (a reboot does the same).
set -e
HF=/usr/data/python-hf
COPY=/usr/data/python-hf-klippy
[ -x $HF/bin/python3.13 ] || { echo "extract python-hf-k1.tar.gz into /usr/data first"; exit 1; }
state=$(curl -s "http://127.0.0.1:7125/printer/objects/query?print_stats=state" | grep -o '"state": *"[a-z]*"' || true)
case "$state" in *printing*|*paused*) echo "printing; not restarting Klipper"; exit 1 ;; esac
if command -v git >/dev/null 2>&1; then
    have=$(git -C /usr/data/klipper rev-parse HEAD 2>/dev/null || true)
    [ -z "$have" ] || [ "$have" = "$(cat $HF/chelper/kalico-commit)" ] ||
        echo "note: printer Kalico is $have, c_helper.so was built from $(cat $HF/chelper/kalico-commit)"
fi
/etc/init.d/S55klipper_service stop
rm -rf $COPY && cp -a /usr/data/klipper/klippy $COPY
rm -f $COPY/chelper/c_helper.so
sleep 1   # c_helper.so must be newer than the sources or Klippy rebuilds it
cp $HF/chelper/c_helper.so $COPY/chelper/c_helper.so
D=/usr/data/printer_data
TMPDIR=/usr/data/tmp HOME=/root start-stop-daemon -S -q -b -m -p /var/run/klippy.pid \
    --exec $HF/bin/python3.13 -- $COPY/klippy.py \
    $D/config/printer.cfg -l $D/logs/klippy.log --rotate-log-at-restart -a /tmp/klippy_uds
echo "Klippy started on $($HF/bin/python3.13 -c 'import sys; print(sys.version.split()[0])'); log: $D/logs/klippy.log"
