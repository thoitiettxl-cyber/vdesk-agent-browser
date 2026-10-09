#!/usr/bin/env bash
# Stop and remove the vdesk systemd units. Does not delete profiles or packages.
set -euo pipefail

UNIT_NAMES=(
  vdesk-browser
  vdesk-novnc
  vdesk-vnc
  vdesk-wm
  vdesk-xvfb
)

if [[ ${EUID} -ne 0 ]]; then
  printf 'error: run as root: sudo ./uninstall.sh\n' >&2
  exit 1
fi

systemctl disable --now "${UNIT_NAMES[@]}" || true

name=""
for name in "${UNIT_NAMES[@]}"; do
  rm -f "/etc/systemd/system/${name}.service"
done

rm -f /etc/systemd/system/vdesk-browser.service.d/pulse.conf
rmdir /etc/systemd/system/vdesk-browser.service.d 2>/dev/null || true
rm -f /etc/pulse/client.conf.d/vdesk.conf
systemctl disable --now vdesk-audio.service || true
rm -f /etc/systemd/system/vdesk-audio.service /usr/local/sbin/vdesk-aaudio.sh

systemctl daemon-reload
systemctl reset-failed "${UNIT_NAMES[@]}" || true
printf 'removed vdesk systemd units\n'
printf 'left in place: VNC password file, Chromium profile, apt packages, playwright-cli\n'
printf 'removed PulseAudio client drop-in if install.sh created one\n'
printf 'left /etc/hosts unchanged\n'
