#!/usr/bin/env bash
# Install the virtual display, localhost VNC/noVNC, and Chromium CDP stack.
# Boot starts Chromium headless only. GUI and VNC stay stopped until `vdesk`.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENABLED_UNITS=(
  vdesk-apply
  vdesk-browser
)
DISPLAY_UNITS=(
  vdesk-xvfb
  vdesk-wm
  vdesk-vnc
  vdesk-novnc
)
RENDER_UNITS=(
  vdesk-apply
  vdesk-browser
  vdesk-idle
  vdesk-xvfb
  vdesk-wm
  vdesk-vnc
  vdesk-novnc
)

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need_root() {
  if [[ ${EUID} -ne 0 ]]; then
    die "run as root: sudo ./install.sh"
  fi
}

need_systemd() {
  local init_comm
  init_comm=$(ps -p 1 -o comm=)
  if [[ ${init_comm} != "systemd" ]]; then
    die "PID 1 is ${init_comm}, not systemd"
  fi
}

need_tty() {
  if [[ ! -t 0 || ! -t 1 ]]; then
    die "a terminal is required so the VNC password can be entered interactively"
  fi
}

prompt() {
  local label=$1
  local default=$2
  local value
  read -r -p "${label} [${default}]: " value
  if [[ -z ${value} ]]; then
    printf '%s' "${default}"
  else
    printf '%s' "${value}"
  fi
}

validate_user() {
  local name=$1
  if [[ ! ${name} =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    die "invalid username: ${name}"
  fi
  if ! id "${name}" >/dev/null 2>&1; then
    die "user ${name} does not exist; create it before running this script"
  fi
}

user_home() {
  local name=$1
  local home
  home=$(getent passwd "${name}" | cut -d: -f6)
  if [[ -z ${home} || ! -d ${home} ]]; then
    die "no home directory for ${name}"
  fi
  if printf '%s' "${home}" | grep -q '[|&\\ ]'; then
    die "home path contains unsupported characters"
  fi
  printf '%s' "${home}"
}

validate_geometry() {
  local geometry=$1
  if [[ ! ${geometry} =~ ^[0-9]{3,5}x[0-9]{3,5}$ ]]; then
    die "resolution must look like 1920x1200"
  fi
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y \
    xvfb \
    xfwm4 \
    x11vnc \
    novnc \
    websockify \
    xdotool \
    ffmpeg \
    dbus-x11 \
    chromium \
    libpulse0 \
    curl \
    iproute2
  if [[ ! -x /usr/lib/chromium/chromium && ! -x /usr/bin/chromium ]]; then
    die "chromium binary not found"
  fi
}

render_unit() {
  local name=$1
  local user=$2
  local home=$3
  local geometry=$4
  local width=$5
  local height=$6
  local src=${SCRIPT_DIR}/systemd/${name}.service
  local dst=/etc/systemd/system/${name}.service

  [[ -f ${src} ]] || die "missing template ${src}"
  sed \
    -e "s|@VDESK_USER@|${user}|g" \
    -e "s|@VDESK_HOME@|${home}|g" \
    -e "s|@VDESK_GEOMETRY@|${geometry}|g" \
    -e "s|@VDESK_WIDTH@|${width}|g" \
    -e "s|@VDESK_HEIGHT@|${height}|g" \
    "${src}" >"${dst}"
  chmod 644 "${dst}"
}

write_config() {
  local user=$1
  local home=$2
  local geometry=$3
  local width=$4
  local height=$5
  local sandbox=0
  local listen=""

  if [[ ${user} == root ]]; then
    sandbox=1
  fi
  if [[ -f /etc/vdesk/config ]]; then
    listen=$(awk -F= '$1 == "VDESK_VNC_LISTEN" { print substr($0, index($0, "=") + 1) }' /etc/vdesk/config | tail -1)
    if [[ -n ${listen} && ! ${listen} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      listen=""
    fi
  fi
  install -d -m 755 /etc/vdesk /var/lib/vdesk
  cat > /etc/vdesk/config <<EOF
VDESK_USER=${user}
VDESK_HOME=${home}
VDESK_GEOMETRY=${geometry}
VDESK_WIDTH=${width}
VDESK_HEIGHT=${height}
VDESK_NO_SANDBOX=${sandbox}
VDESK_RENDERER_LIMIT=2
VDESK_IDLE_SEC=600
VDESK_VNC_LISTEN=${listen}
EOF
  chmod 644 /etc/vdesk/config
  if [[ ! -f /etc/vdesk/chromium-extra ]]; then
    cat > /etc/vdesk/chromium-extra <<'EOF'
# Optional extra Chromium flags, one per line. Lines starting with # are ignored.
# Do not put secrets here. install.sh does not overwrite this file.
# The launcher already sets --lang=vi-VN, Asia/Ho_Chi_Minh, and
# --disable-blink-features=AutomationControlled. Do not add --enable-automation
# or --headless here; vdesk-chromium refuses those.
EOF
    chmod 644 /etc/vdesk/chromium-extra
  fi
  printf 'headless\n' > /var/lib/vdesk/mode
  printf 'off\n' > /var/lib/vdesk/view
  chmod 644 /var/lib/vdesk/mode /var/lib/vdesk/view
}

install_commands() {
  install -d -m 755 /usr/local/bin /usr/local/libexec
  install -m 755 "${SCRIPT_DIR}/scripts/vdesk" /usr/local/bin/vdesk
  install -m 755 "${SCRIPT_DIR}/scripts/vdesk-chromium" /usr/local/libexec/vdesk-chromium
  install -m 755 "${SCRIPT_DIR}/scripts/vdesk-x11vnc" /usr/local/libexec/vdesk-x11vnc
}

install_sudoers() {
  local service_user=$1
  local skill_user=$2
  local tmp
  local wrote=0
  tmp=$(mktemp)
  printf '# vdesk mode switches. Installed by vdesk-agent-browser.\n' > "${tmp}"
  if [[ ${service_user} != root ]]; then
    printf '%s ALL=(root) NOPASSWD: /usr/local/bin/vdesk\n' "${service_user}" >> "${tmp}"
    wrote=1
  fi
  if [[ ${skill_user} != root && ${skill_user} != "${service_user}" ]]; then
    printf '%s ALL=(root) NOPASSWD: /usr/local/bin/vdesk\n' "${skill_user}" >> "${tmp}"
    wrote=1
  fi
  if [[ ${wrote} -eq 0 ]]; then
    rm -f "${tmp}" /etc/sudoers.d/vdesk
    return 0
  fi
  visudo -cf "${tmp}" >/dev/null
  install -m 440 "${tmp}" /etc/sudoers.d/vdesk
  rm -f "${tmp}"
}

store_vnc_password() {
  local user=$1
  local home=$2
  local pass_file=${home}/.vnc/passwd

  local group
  group=$(id -gn "${user}")
  install -d -m 700 -o "${user}" -g "${group}" "${home}/.vnc"
  install -d -m 700 -o "${user}" -g "${group}" "${home}/.chromium-profile"
  printf 'Enter a new VNC password. It is stored only in %s\n' "${pass_file}"
  if [[ ${user} == "root" ]]; then
    x11vnc -storepasswd "${pass_file}"
  else
    runuser -u "${user}" -- x11vnc -storepasswd "${pass_file}"
  fi
  chown "${user}:${group}" "${pass_file}"
  chmod 600 "${pass_file}"
}

ensure_uv() {
  if command -v uv >/dev/null 2>&1; then
    return 0
  fi
  if [[ -x /root/.local/bin/uv ]]; then
    export PATH="/root/.local/bin:${PATH}"
    return 0
  fi
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="/root/.local/bin:${PATH}"
  command -v uv >/dev/null 2>&1 || die "uv was not installed"
}

install_patchright() {
  local skill_user=$1
  local skill_home=$2
  local py=/usr/bin/python3.13
  local root=/usr/local/lib/vdesk-patchright
  local skill_src=""
  local skill_dst=${skill_home}/.agents/skills/patchright-cli
  local group

  ensure_uv
  if [[ ! -x ${py} ]]; then
    py=$(uv python find 3.13)
  fi
  uv venv "${root}" --python "${py}"
  # Attach uses the Debian Chromium already started by vdesk. Do not run
  # `patchright install chromium`; that downloads a second browser.
  uv pip install --python "${root}/bin/python" 'patchright-cli==0.7.0'
  ln -sfn "${root}/bin/patchright-cli" /usr/local/bin/patchright-cli
  command -v patchright-cli >/dev/null 2>&1 || die "patchright-cli was not installed onto PATH"

  if command -v npm >/dev/null 2>&1; then
    npm uninstall -g @playwright/cli >/dev/null 2>&1 || true # patchright-cli replaces it
  fi
  rm -f /usr/local/bin/playwright-cli /usr/bin/playwright-cli # patchright-cli is the CLI on PATH

  skill_src=$(find "${root}" -type d -path '*/patchright_cli/_skills/patchright-cli' -print -quit)
  [[ -n ${skill_src} && -f ${skill_src}/SKILL.md ]] || die "patchright-cli skill files were not installed"
  group=$(id -gn "${skill_user}")
  rm -rf "${skill_home}/.agents/skills/playwright-cli" # skill dir is now patchright-cli
  install -d -o "${skill_user}" -g "${group}" "${skill_home}/.agents/skills"
  rm -rf "${skill_dst}"
  cp -a "${skill_src}" "${skill_dst}"
  if [[ -f ${SCRIPT_DIR}/pi/patchright-host.md ]]; then
    python3 -c 'import pathlib,sys; skill,note=map(pathlib.Path, sys.argv[1:]); text=skill.read_text(); extra=note.read_text().rstrip()+"\n";
end=text.find("\n---", 3) if text.startswith("---") else -1
if end != -1:
    end=text.find("\n", end+1)+1
    text=text[:end]+"\n"+extra+text[end:]
else:
    text=extra+text
skill.write_text(text)' "${skill_dst}/SKILL.md" "${SCRIPT_DIR}/pi/patchright-host.md"
  fi
  chown -R "${skill_user}:${group}" "${skill_dst}"
  [[ -f ${skill_dst}/SKILL.md ]] || die "patchright-cli skill was not installed for ${skill_user}"
}

configure_localhost() {
  local hosts=/etc/hosts
  local disabled=""

  if [[ ! -f ${hosts} ]]; then
    return 0
  fi
  if [[ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ]]; then
    disabled=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)
  fi
  if [[ ${disabled} != "1" ]]; then
    return 0
  fi

  # IPv6 is off, but Debian still lists localhost on ::1. Clients that try
  # that address fail before reaching x11vnc. Keep ip6-localhost on the line.
  sed -i -E 's/^(::1[[:space:]]+)localhost[[:space:]]+/\1/' "${hosts}"
  if ! grep -qE '^127\.0\.0\.1[[:space:]]+localhost([[:space:]]|$)' "${hosts}"; then
    printf '127.0.0.1\tlocalhost\n' >> "${hosts}"
  fi
  printf 'localhost is 127.0.0.1 only; IPv6 is disabled\n'
}

configure_aaudio() {
  if [[ ! -S /tmp/.pulse-socket && ! -f /etc/profile.d/droidspaces_env.sh ]]; then
    return 0
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y pulseaudio-utils
  install -d -m 755 /usr/local/sbin
  install -m 755 "${SCRIPT_DIR}/scripts/vdesk-aaudio.sh" /usr/local/sbin/vdesk-aaudio.sh
  install -m 644 "${SCRIPT_DIR}/systemd/vdesk-audio.service" /etc/systemd/system/vdesk-audio.service
  ENABLED_UNITS+=(vdesk-audio)
  printf 'AAudio sink will be tuned to 44100 Hz on boot\n'
}

configure_pulse() {
  local server=""
  local from_profile=""

  if [[ -S /tmp/.pulse-socket ]]; then
    server="unix:/tmp/.pulse-socket"
  fi
  if [[ -f /etc/profile.d/droidspaces_env.sh ]]; then
    from_profile=$(sed -n "s/^export PULSE_SERVER='\\([^']*\\)'$/\\1/p" /etc/profile.d/droidspaces_env.sh | head -n 1)
    if [[ -n ${from_profile} ]]; then
      server=${from_profile}
    fi
  fi
  if [[ -z ${server} ]]; then
    return 0
  fi
  if [[ ! ${server} =~ ^unix:/[^[:space:]\'\"]+$ ]]; then
    die "unsupported PULSE_SERVER: ${server}"
  fi

  # Chromium clears its environment after start, so the unit Environment= line
  # is not enough. libpulse still reads this file. Shared memory is unusable
  # when the server socket is bind-mounted from another mount namespace.
  install -d -m 755 /etc/pulse/client.conf.d
  cat > /etc/pulse/client.conf.d/vdesk.conf <<EOF
default-server = ${server}
enable-shm = no
EOF
  chmod 644 /etc/pulse/client.conf.d/vdesk.conf

  install -d -m 755 /etc/systemd/system/vdesk-browser.service.d
  cat > /etc/systemd/system/vdesk-browser.service.d/pulse.conf <<EOF
[Service]
Environment=PULSE_SERVER=${server}
EOF
  chmod 644 /etc/systemd/system/vdesk-browser.service.d/pulse.conf
  printf 'PulseAudio client set to %s\n' "${server}"
}

stop_old_display() {
  local name
  if [[ ! -d /run/systemd/system ]]; then
    return 0
  fi
  # Disable while the previous unit files still have [Install], so the
  # multi-user.target.wants symlinks are removed. New display units are
  # started only by `vdesk`.
  systemctl disable --now "${DISPLAY_UNITS[@]}" || true
  for name in "${DISPLAY_UNITS[@]}"; do
    rm -f "/etc/systemd/system/multi-user.target.wants/${name}.service"
  done
}

enable_units() {
  local name
  systemctl daemon-reload
  systemctl enable "${ENABLED_UNITS[@]}" vdesk-idle.timer
  systemctl start vdesk-apply.service
  /usr/local/bin/vdesk mode headless
  systemctl restart vdesk-idle.timer
  for name in "${ENABLED_UNITS[@]}" vdesk-idle.timer; do
    systemctl is-active --quiet "${name}" || die "${name} is not active"
  done
  for name in "${DISPLAY_UNITS[@]}"; do
    if systemctl is-active --quiet "${name}"; then
      die "${name} is active; headless boot should leave it stopped"
    fi
  done
}

print_checks() {
  local ready=0
  local attempt
  printf '\n== vdesk status ==\n'
  /usr/local/bin/vdesk status || true
  printf '\n== listeners ==\n'
  ss -ltnp | grep -E ':(5900|6080|9222)' || true
  if ss -ltn | awk '$4 ~ /:(5900|6080|9222)$/ && $4 !~ /^127\.0\.0\.1:/ { found = 1 } END { exit found ? 0 : 1 }'; then
    die "a vdesk port is not bound to 127.0.0.1 only"
  fi
  printf '\n== CDP ==\n'
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS http://127.0.0.1:9222/json/version; then
      printf '\n'
      ready=1
      break
    fi
    sleep 1
    printf 'waiting for CDP (%s/10)\n' "${attempt}" >&2
  done
  if [[ ${ready} -ne 1 ]]; then
    die "Chromium CDP did not answer on 127.0.0.1:9222"
  fi
}

main() {
  local service_user geometry width height home skill_user skill_home name

  need_root
  need_systemd
  need_tty

  service_user=$(prompt "Service user" "vdesk")
  validate_user "${service_user}"
  home=$(user_home "${service_user}")

  geometry=$(prompt "Resolution" "1920x1200")
  validate_geometry "${geometry}"
  width=${geometry%x*}
  height=${geometry#*x}

  if [[ -n ${SUDO_USER:-} ]]; then
    skill_user=${SUDO_USER}
  else
    skill_user=${service_user}
  fi
  validate_user "${skill_user}"
  skill_home=$(user_home "${skill_user}")

  install_packages
  store_vnc_password "${service_user}" "${home}"
  stop_old_display

  write_config "${service_user}" "${home}" "${geometry}" "${width}" "${height}"
  install_commands
  install_sudoers "${service_user}" "${skill_user}"

  for name in "${RENDER_UNITS[@]}"; do
    render_unit "${name}" "${service_user}" "${home}" "${geometry}" "${width}" "${height}"
  done
  install -m 644 "${SCRIPT_DIR}/systemd/vdesk-idle.timer" /etc/systemd/system/vdesk-idle.timer
  if [[ ${service_user} == "root" ]]; then
    printf 'warning: Chromium is running as root with --no-sandbox\n' >&2
  fi

  configure_aaudio
  configure_localhost
  configure_pulse
  enable_units
  install_patchright "${skill_user}" "${skill_home}"
  print_checks

  cat <<EOF

Installed. Boot mode is headless: Chromium only, CDP on 127.0.0.1:9222.
  vdesk mode gui       start Xvfb and xfwm4, relaunch Chromium headed
  vdesk mode headless  stop the desktop and return to headless
  vdesk view on|off    start or stop VNC without restarting Chromium
  vdesk status
After a mode change, run: patchright-cli attach --cdp=http://127.0.0.1:9222 --context=host
Append pi/AGENTS.md.example to ${skill_home}/.pi/agent/AGENTS.md before Pi uses the browser.
Leave VDESK_VNC_LISTEN empty unless AVNC should connect to one IPv4 on this host. Do not set 0.0.0.0. Do not publish ports 6080 or 9222.
EOF
}

main "$@"
