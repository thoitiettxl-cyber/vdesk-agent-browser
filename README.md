# vdesk-agent-browser

Màn hình ảo cho agent: Chromium chạy trên Xvfb, người xem qua VNC hoặc noVNC, Pi điều khiển cùng trình duyệt đó bằng CDP. Không cài desktop XFCE đầy đủ. Chỉ có trình quản lý cửa sổ `xfwm4`.

Bản này dùng gói `chromium` của Debian, không dùng Google Chrome. Trên arm64 không có gói Chrome chính thức.

## Thành phần

```text
điện thoại / máy khác
        |  SSH tunnel, không mở cổng ra internet
        v
127.0.0.1:6080  websockify + noVNC
        |
127.0.0.1:5900  x11vnc  (-localhost)
        |
Xvfb :1  1920x1200x24  +GLX
   |-- xfwm4 --compositor=off
   '-- Chromium
         --remote-debugging-address=127.0.0.1
         --remote-debugging-port=9222
              |
              playwright-cli attach --cdp=http://127.0.0.1:9222
              |
              Pi
```

Mỗi phần là một service systemd. Service nào chết thì systemd bật lại service đó. Log nằm trong journal: `journalctl -u vdesk-vnc -f`.

## Yêu cầu

- Debian 13, amd64 hoặc arm64. Đây là bản đã thử.
- Ubuntu 24.04 chưa kiểm tra. Trên Ubuntu, gói `chromium` trong apt là gói ảo, và `chromium-browser` chỉ chuyển tiếp sang Snap. Snap không khớp `/usr/bin/chromium` và `--user-data-dir` trong service.
- systemd là PID 1
- tài khoản sẽ chạy service đã tồn tại
- quyền root để cài gói và unit

User thường an toàn hơn root. Tạo trước nếu chưa có:

```bash
sudo adduser --disabled-password --gecos "" vdesk
```

## Cài nhanh

```bash
git clone https://github.com/thoitiettxl-cyber/vdesk-agent-browser.git
cd vdesk-agent-browser
sudo ./install.sh
```

Script hỏi hai thứ, rồi hỏi mật khẩu VNC hai lần qua `x11vnc -storepasswd`:

- user chạy service, mặc định `vdesk`. Gõ `root` nếu cố ý chạy bằng root
- độ phân giải, mặc định `1920x1200`

Mật khẩu chỉ được ghi vào `~user/.vnc/passwd` trên máy đích. Repo không chứa mật khẩu.

Script cài các gói `xvfb xfwm4 x11vnc novnc websockify xdotool ffmpeg dbus-x11 chromium libpulse0`, thêm `nodejs`, `npm`, `curl` và `iproute2` để cài `playwright-cli` và in kết quả kiểm tra. Sau đó nó chép unit, `enable --now`, cài `@playwright/cli` và skill `playwright-cli`.

Nếu user service là root, script thêm `--no-sandbox`. User thường không có cờ này.

Thêm đoạn trong `pi/AGENTS.md.example` vào file hướng dẫn mà Pi đọc, thường là `~/.pi/agent/AGENTS.md`.

## Kết nối từ điện thoại

Cổng chỉ nghe `127.0.0.1`. Từ điện thoại, mở SSH tunnel rồi nối vào `localhost` của chính điện thoại.

### AVNC + tunnel cổng 5900

Trên máy có SSH client:

```bash
ssh -L 5900:127.0.0.1:5900 user@server
```

Trong Termius: tạo Port Forwarding, local port `5900`, destination `127.0.0.1`, destination port `5900`. Bật tunnel trước khi mở VNC.

AVNC: host `127.0.0.1`, port `5900`, nhập mật khẩu VNC đã đặt lúc cài.

### noVNC trên trình duyệt

```bash
ssh -L 6080:127.0.0.1:6080 user@server
```

Mở `http://127.0.0.1:6080/vnc.html` trên máy đang giữ tunnel. Không dùng IP công khai của server.

## Cho Pi dùng playwright-cli

Phiên `playwright-cli attach` mất khi Chromium khởi động lại. Pi phải gắn lại trước khi điều khiển trình duyệt:

```bash
playwright-cli attach --cdp=http://127.0.0.1:9222
```

Nếu lệnh lỗi, xem `systemctl status vdesk-browser` và `curl -s http://127.0.0.1:9222/json/version`.

Đoạn cần có trong hướng dẫn của Pi nằm ở `pi/AGENTS.md.example`.

## Xử lý sự cố

| Triệu chứng | Việc kiểm tra |
|---|---|
| Chromium báo không nối được dbus | Unit đã dùng `dbus-run-session`. Restart `vdesk-browser`. Không chạy Chromium trần ngoài session bus. |
| Chromium thoát ngay khi user là root | Thiếu `--no-sandbox`. Chỉ thêm cờ này cho root. User thường thì bỏ cờ đó. |
| `9222` bị chiếm | `ss -ltnp \| grep 9222`. Dừng tiến trình Chromium khác đang giữ cổng, rồi `systemctl restart vdesk-browser`. |
| VNC từ xa không vào | Đúng như thiết kế. Tunnel SSH trước. `ss` phải thấy `127.0.0.1:5900`, không thấy `0.0.0.0:5900`. |
| VNC báo server không chạy | Client dùng `localhost` hoặc `127.0.0.1`, cổng `5900`. Không dùng IP Wi-Fi. x11vnc dùng `-listen localhost -no6`. noVNC nối `127.0.0.1:5900`. Nếu IPv6 tắt, `install.sh` gỡ `localhost` khỏi dòng `::1` trong `/etc/hosts`. |
| Sau reboot không lên | `systemctl is-enabled vdesk-xvfb vdesk-wm vdesk-vnc vdesk-novnc vdesk-browser` |
| Mở nhạc không có tiếng | Container không có `/dev/snd`. Nếu có socket `/tmp/.pulse-socket`, hoặc `PULSE_SERVER` trong `/etc/profile.d/droidspaces_env.sh`, `install.sh` ghi `/etc/pulse/client.conf.d/vdesk.conf` (`enable-shm = no`) và drop-in `PULSE_SERVER` cho `vdesk-browser`. Chromium xóa environment sau khi khởi động, nên chỉ đặt biến trong unit là không đủ. `journalctl -u vdesk-browser` không được còn `PcmOpen: default`. |

## Gỡ

```bash
sudo ./uninstall.sh
```

Script dừng, disable và xoá năm unit. Không xoá profile Chromium, file mật khẩu VNC, gói apt, hay `playwright-cli`.

## Bảo mật

- `x11vnc` dùng `-listen localhost -no6`, nên chỉ bind `127.0.0.1:5900`. noVNC nối thẳng `127.0.0.1:5900`. CDP cũng chỉ bind `127.0.0.1`.
- Chỉ vào bằng SSH tunnel. Không publish `5900`, `6080`, hoặc `9222`.
- CDP cho phép điều khiển trình duyệt đang đăng nhập. Lộ `9222` ra ngoài là trao quyền đó cho người khác.
- Đặt mật khẩu VNC lúc cài. Không viết mật khẩu vào unit, README, hoặc script.
- Chạy bằng user thường. `--no-sandbox` với root chỉ dành cho máy thử.

## English summary

This repository reproduces a headless agent desktop: Xvfb display `:1`, `xfwm4`, Chromium with a localhost CDP port `9222`, `x11vnc` on `127.0.0.1:5900`, and noVNC/websockify on `127.0.0.1:6080`. Pi attaches with `playwright-cli attach --cdp=http://127.0.0.1:9222`.

Tested on Debian 13. Ubuntu 24.04 is not verified: its apt `chromium` package is a transitional Snap wrapper, so `/usr/bin/chromium` and `--user-data-dir` in the service may not work.

`sudo ./install.sh` installs the packages, asks for the service user (default `vdesk`) and resolution, prompts for a VNC password, installs the systemd units, and installs `@playwright/cli`. x11vnc listens on `localhost` with `-no6`, and noVNC connects to `127.0.0.1:5900`. If IPv6 is disabled, the script removes `localhost` from the `::1` line in `/etc/hosts`. If `/tmp/.pulse-socket` exists, or Droidspaces exports `PULSE_SERVER`, the script points PulseAudio clients at that socket and disables shared memory. Chromium has no ALSA device in that container, and it clears its process environment, so the client config is required for audio. Access the desktop only through an SSH tunnel. Do not expose ports `5900`, `6080`, or `9222`.
