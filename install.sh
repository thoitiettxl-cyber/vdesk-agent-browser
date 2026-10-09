#!/usr/bin/env bash
# Install the virtual display, localhost VNC/noVNC, and Chromium CDP stack.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
UNIT_NAMES=(
  vdesk-xvfb
  vdesk-wm
  vdesk-vnc
  vdesk-novnc
  vdesk-browser
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
    nodejs \
    npm \
    curl \
    iproute2
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

add_root_sandbox_flag() {
  local dst=/etc/systemd/system/vdesk-browser.service
  if grep -q -- '--no-sandbox' "${dst}"; then
    return 0
  fi
  sed -i 's|/usr/bin/chromium |/usr/bin/chromium --no-sandbox |' "${dst}"
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

install_playwright() {
  local skill_user=$1
  local skill_home=$2

  npm install -g @playwright/cli@latest
  command -v playwright-cli >/dev/null 2>&1 || die "playwright-cli was not installed onto PATH"
  runuser -u "${skill_user}" -- env PATH="${PATH}" playwright-cli install --skills=agents -g
  if [[ ! -f ${skill_home}/.agents/skills/playwright-cli/SKILL.md ]]; then
    die "playwright-cli skill was not installed for ${skill_user}"
  fi
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

enable_units() {
  local name
  systemctl daemon-reload
  systemctl enable --now "${UNIT_NAMES[@]}"
  for name in "${UNIT_NAMES[@]}"; do
    systemctl is-active --quiet "${name}" || die "${name} is not active"
  done
}

print_checks() {
  local ready=0
  local attempt
  printf '\n== service status ==\n'
  systemctl --no-pager --full status "${UNIT_NAMES[@]}" || true
  printf '\n== listeners ==\n'
  ss -ltnp | grep -E '127\.0\.0\.1:(5900|6080|9222)' || true
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
  local service_user geometry width height home skill_user skill_home

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

  local name
  for name in "${UNIT_NAMES[@]}"; do
    render_unit "${name}" "${service_user}" "${home}" "${geometry}" "${width}" "${height}"
  done
  if [[ ${service_user} == "root" ]]; then
    add_root_sandbox_flag
    printf 'warning: Chromium is running as root with --no-sandbox\n' >&2
  fi

  configure_pulse
  enable_units
  install_playwright "${skill_user}" "${skill_home}"
  print_checks

  cat <<EOF

Installed.
Append pi/AGENTS.md.example to ${skill_home}/.pi/agent/AGENTS.md before Pi uses the browser.
Connect only through an SSH tunnel. Do not publish ports 5900, 6080, or 9222.
EOF
}

main "$@"
