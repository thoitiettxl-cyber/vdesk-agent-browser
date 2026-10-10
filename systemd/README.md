# systemd units

`install.sh` copies these files to `/etc/systemd/system/` and replaces the placeholders below. It also writes `/etc/vdesk/config` and installs `/usr/local/bin/vdesk`.

Boot enables only `vdesk-apply`, `vdesk-browser`, and `vdesk-idle.timer`. Xvfb, xfwm4, x11vnc, and websockify are installed but not enabled. `vdesk mode gui` starts the display. `vdesk view on` starts VNC. Both leave the Chromium profile at `~user/.chromium-profile`.

| Placeholder | Meaning |
|---|---|
| `@VDESK_USER@` | Account that runs Xvfb, the window manager, VNC, noVNC, and Chromium |
| `@VDESK_HOME@` | Home directory of that account. Used for the VNC password path |
| `@VDESK_GEOMETRY@` | `WIDTHxHEIGHT`, default `1920x1200` |
| `@VDESK_WIDTH@` / `@VDESK_HEIGHT@` | Written to `/etc/vdesk/config` for Chromium `--window-size` |

`/etc/vdesk/config` also sets `VDESK_NO_SANDBOX` (1 only when the service user is root), `VDESK_RENDERER_LIMIT` (default 2), and `VDESK_IDLE_SEC` (default 600). Set `VDESK_IDLE_SEC=0` to disable the idle return to headless. The VNC address is not stored here. `vdesk view on` reads `net_mode` from `/run/droidspaces/container.config`.

`/etc/vdesk/chromium-extra` is optional, one Chromium flag per line. `install.sh` does not overwrite it. The launcher already sets `--lang=vi-VN`, `TZ=Asia/Ho_Chi_Minh`, and `--disable-blink-features=AutomationControlled`. It refuses `--enable-automation` and `--headless`.

## Modes

| Command | What stays running |
|---|---|
| `vdesk mode headless` | Chromium on `--ozone-platform=headless`, without `--headless=new`, and CDP `127.0.0.1:9222`. This is the boot default. |
| `vdesk mode gui` | Xvfb `:1`, `xfwm4`, headed Chromium, same profile and CDP port. |
| `vdesk view on` | x11vnc on `127.0.0.1:5900` and websockify on `127.0.0.1:6080`. In NAT, also forwards eth0's current IPv4 port 5900. Host mode does not add that forwarder. Starts gui first if needed. |
| `vdesk view off` | Stops only x11vnc and websockify. Chromium keeps its PID. |

`vdesk-idle.timer` runs `vdesk idle` every minute. With no VNC client for `VDESK_IDLE_SEC`, it turns view off and does not restart Chromium. With no VNC client and no CDP client for that long, it switches to headless, which does restart Chromium.

## Run as a normal user

Prefer a dedicated unprivileged account, for example `vdesk`. Create it before `install.sh`:

```bash
sudo adduser --disabled-password --gecos "" vdesk
```

Then run `sudo ./install.sh` and enter `vdesk` when asked. The script stores the VNC password in `~vdesk/.vnc/passwd` and the Chromium profile in `~vdesk/.chromium-profile`. It also installs a sudoers drop-in so that account can run `/usr/local/bin/vdesk` without a password.

Do not add `--no-sandbox` for that account. Chromium's sandbox should stay on.

`/tmp/.X11-unix` is normally `1777`, so a normal user can create display socket `X1`. If a previous root-owned `X1` socket remains, stop `vdesk-xvfb` and remove the stale socket before switching users.

## Root

If the service user is `root`, `install.sh` sets `VDESK_NO_SANDBOX=1`. The launcher adds `--no-sandbox`. That is required for Chromium to start, and it is less safe. Use root only on a disposable test machine.

## Chromium flags

The launcher is `/usr/local/libexec/vdesk-chromium`. It execs `/usr/lib/chromium/chromium`, not `/usr/bin/chromium`, so Debian's `/etc/chromium.d` flags do not turn GPU rasterization and extension loading back on.

RAM flags include `--disable-extensions`, `--disable-background-networking`, `--disable-component-update`, `--disable-sync`, and `--renderer-process-limit`. Headless adds `--ozone-platform=headless --disable-gpu --disable-software-rasterizer` and a fixed `--ozone-override-screen-size`. It does not pass `--headless=new`, because that flag made this Chromium advertise `HeadlessChrome`. GUI uses `--ozone-platform=x11` and `DISPLAY=:1`. It adds kgsl, `TU_DEBUG=noconform`, and `--use-angle=vulkan` only when `enable_gpu_mode=1`, `/dev/kgsl-3d0` exists, and `vulkaninfo` or `eglinfo` reports Turnip. Otherwise it uses SwiftShader and unsets `GALLIUM_DRIVER`. `--use-gl=egl` is rejected by this Chromium. `--use-angle=gl` breaks the Xvfb connection under kgsl. Installed extensions such as uBlock Origin Lite stay in the profile and are not loaded.

## PulseAudio

`install.sh` does not change audio unless `/tmp/.pulse-socket` exists or `/etc/profile.d/droidspaces_env.sh` exports `PULSE_SERVER`. In that case it writes `/etc/pulse/client.conf.d/vdesk.conf` with `default-server` and `enable-shm = no`. It does not set `PULSE_SERVER` again on `vdesk-browser`. Droidspaces already exports that variable, and Chromium clears its environment after startup, so the client file is what libpulse still reads. Shared memory must stay off because the socket is bind-mounted from another mount namespace.

On boot, if `/tmp/.pulse-socket` is gone, `vdesk boot` removes that client file and stops `vdesk-audio`. The audio script does the same if the socket never appears, and every `pactl` call has a 5 second timeout. When the socket is present, `vdesk-audio.service` reloads `module-aaudio-sink` at 44100 Hz with `pm=0` and a 120 ms buffer. The default sink is 48000 Hz in low-latency mode, and PulseAudio then resamples Chromium's 44100 Hz stream with `speex-float-1`. After the retune, `pactl list sink-inputs` should show `Resample method: copy`.

## VNC

`vdesk-vnc.service` runs `/usr/local/libexec/vdesk-x11vnc`. x11vnc itself always uses `-localhost -no6 -noipv6`, which binds `127.0.0.1:5900` only. `-listen` still opened `[::]:5900` on x11vnc 0.9.17 even with `-no6 -noipv6`, so the unit does not use `-listen`. In NAT the helper also binds a forwarder to eth0's current global IPv4. Host mode leaves VNC on `127.0.0.1` only, because that is the phone's loopback. `net_mode=none`, a missing address, or an unsupported mode prints an error and does not start the forwarder. `vdesk view on` stops the units unless those are the only port 5900 listeners.

`vdesk-novnc.service` proxies to `127.0.0.1:5900`, not the hostname `localhost`. On a host with IPv6 disabled, that hostname can still resolve to `::1` and the connection fails. noVNC stays on `127.0.0.1:6080` in every network mode.

If `/proc/sys/net/ipv6/conf/all/disable_ipv6` is `1`, `install.sh` removes `localhost` from the `::1` line in `/etc/hosts`. `uninstall.sh` does not restore that line.
