#!/usr/bin/env bash
# Stop and remove the vdesk systemd units. Does not delete profiles or packages.
set -euo pipefail

UNIT_NAMES=(
  vdesk-idle.timer
  vdesk-idle.service
  vdesk-browser
  vdesk-apply
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
  rm -f "/etc/systemd/system/${name}" "/etc/systemd/system/${name}.service"
  rm -f "/etc/systemd/system/multi-user.target.wants/${name}" "/etc/systemd/system/multi-user.target.wants/${name}.service"
  rm -f "/etc/systemd/system/timers.target.wants/${name}"
done

rm -f /etc/systemd/system/vdesk-browser.service.d/pulse.conf
rmdir /etc/systemd/system/vdesk-browser.service.d 2>/dev/null || true
rm -f /etc/pulse/client.conf.d/vdesk.conf
systemctl disable --now vdesk-audio.service || true
rm -f /etc/systemd/system/vdesk-audio.service /usr/local/sbin/vdesk-aaudio.sh
rm -f /usr/local/bin/vdesk /usr/local/libexec/vdesk-chromium /etc/sudoers.d/vdesk
rm -rf /etc/vdesk /var/lib/vdesk

systemctl daemon-reload
systemctl reset-failed "${UNIT_NAMES[@]}" || true
printf 'removed vdesk systemd units and the vdesk command\n'
printf 'left in place: VNC password file, Chromium profile, apt packages, playwright-cli\n'
printf 'removed PulseAudio client drop-in if install.sh created one\n'
printf 'left /etc/hosts unchanged\n'
