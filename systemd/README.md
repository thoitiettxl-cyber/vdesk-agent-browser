# systemd units

These files are templates. `install.sh` copies them to `/etc/systemd/system/` and replaces:

| Placeholder | Meaning |
|---|---|
| `@VDESK_USER@` | Account that runs Xvfb, the window manager, VNC, noVNC, and Chromium |
| `@VDESK_HOME@` | Home directory of that account |
| `@VDESK_GEOMETRY@` | `WIDTHxHEIGHT`, default `1920x1200` |
| `@VDESK_WIDTH@` / `@VDESK_HEIGHT@` | Same size, split for Chromium `--window-size` |

## Run as a normal user

Prefer a dedicated unprivileged account, for example `vdesk`. Create it before `install.sh`:

```bash
sudo adduser --disabled-password --gecos "" vdesk
```

Then run `sudo ./install.sh` and enter `vdesk` when asked. The script stores the VNC password in `~vdesk/.vnc/passwd` and the Chromium profile in `~vdesk/.chromium-profile`.

Do not add `--no-sandbox` for that account. Chromium's sandbox should stay on.

`/tmp/.X11-unix` is normally `1777`, so a normal user can create display socket `X1`. If a previous root-owned `X1` socket remains, stop `vdesk-xvfb` and remove the stale socket before switching users.

## Root

If the service user is `root`, `install.sh` inserts `--no-sandbox` into `vdesk-browser.service`. That is required for Chromium to start, and it is less safe. Use root only on a disposable test machine.

## PulseAudio

`install.sh` does not change audio unless `/tmp/.pulse-socket` exists or `/etc/profile.d/droidspaces_env.sh` exports `PULSE_SERVER`. In that case it writes:

- `/etc/pulse/client.conf.d/vdesk.conf` with `default-server` and `enable-shm = no`
- `/etc/systemd/system/vdesk-browser.service.d/pulse.conf`

The client file is the one Chromium uses. The browser clears its environment after startup, so a systemd `Environment=` line alone does not reach the audio process. Shared memory must stay off because the socket is bind-mounted from another mount namespace.

On that same host, `vdesk-audio.service` reloads `module-aaudio-sink` at 44100 Hz with `pm=0` and a 120 ms buffer. The default sink is 48000 Hz in low-latency mode, and PulseAudio then resamples Chromium's 44100 Hz stream with `speex-float-1`. After the retune, `pactl list sink-inputs` should show `Resample method: copy`.

## VNC

`vdesk-vnc.service` listens with `-listen localhost -no6`. That binds `127.0.0.1:5900`. It does not listen on the Wi-Fi address.

`vdesk-novnc.service` proxies to `127.0.0.1:5900`, not the hostname `localhost`. On a host with IPv6 disabled, that hostname can still resolve to `::1` and the connection fails.

If `/proc/sys/net/ipv6/conf/all/disable_ipv6` is `1`, `install.sh` removes `localhost` from the `::1` line in `/etc/hosts`. `uninstall.sh` does not restore that line.
