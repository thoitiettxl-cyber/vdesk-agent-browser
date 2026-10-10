# vdesk-agent-browser

Trình duyệt cho agent: Chromium giữ một profile, Pi điều khiển bằng CDP `127.0.0.1:9222`. Desktop và VNC chỉ bật khi cần, vì container Droidspaces trên Android thiếu RAM.

Bản này dùng gói `chromium` của Debian, không dùng Google Chrome. Trên arm64 không có gói Chrome chính thức.

## Chế độ

Boot mặc định là headless. Không có Xvfb, xfwm4, x11vnc hay websockify.

```text
headless (mặc định)
  Chromium --headless=new
  CDP 127.0.0.1:9222
       |
       playwright-cli attach --cdp=http://127.0.0.1:9222

gui    vdesk mode gui
  Xvfb :1  1920x1200x24 +GLX
  xfwm4 --compositor=off
  Chromium có giao diện, cùng --user-data-dir
  CDP 127.0.0.1:9222

view   vdesk view on
  x11vnc      127.0.0.1:5900
  websockify  127.0.0.1:6080
  Chromium không khởi động lại nếu đã ở gui
```

| Lệnh | Việc xảy ra |
|---|---|
| `vdesk mode headless` | Tắt VNC, xfwm4 và Xvfb. Mở lại Chromium headless. |
| `vdesk mode gui` | Bật Xvfb và xfwm4, mở lại Chromium có giao diện nếu nó đang headless. |
| `vdesk view on` | Bật x11vnc và websockify. Đang headless thì chuyển sang gui trước. |
| `vdesk view off` | Chỉ tắt x11vnc và websockify. PID Chromium giữ nguyên. |
| `vdesk status` | In mode, view, CDP và RSS. |

`vdesk mode gui` khi đã ở gui không mở lại Chromium. `vdesk view on` và `vdesk view off` cũng không mở lại Chromium, trừ lần `view on` phải rời headless: lần đó là đổi mode, Chromium khởi động lại một lần.

Profile vẫn là `~user/.chromium-profile`. Cookie và đăng nhập nằm ở đó. CDP vẫn là `127.0.0.1:9222`.

Sau mỗi lần Chromium khởi động lại, phiên `playwright-cli attach` mất. Phải gắn lại:

```bash
playwright-cli attach --cdp=http://127.0.0.1:9222
```

Output của `vdesk` có `restarted=yes` khi phải gắn lại, `restarted=no` khi không.

Không có client VNC và không có client CDP trong 10 phút thì `vdesk-idle.timer` đưa về headless. Chỉ không có người xem thì timer tắt view, không khởi động lại Chromium. Đặt `VDESK_IDLE_SEC=0` trong `/etc/vdesk/config` để tắt hành vi này, rồi `systemctl daemon-reload` không cần vì lệnh `vdesk` đọc file mỗi lần chạy.

## RAM

Launcher là `/usr/local/libexec/vdesk-chromium`. Nó gọi `/usr/lib/chromium/chromium`, không gọi wrapper `/usr/bin/chromium`, vì wrapper thêm `--enable-gpu-rasterization` và `--load-extension`.

Cờ giảm RAM: `--disable-extensions`, `--disable-component-extensions-with-background-pages`, `--disable-background-networking`, `--disable-component-update`, `--disable-sync`, `--renderer-process-limit` (mặc định 2), `--process-per-site`, cache đĩa 32MB. Headless thêm `--headless=new --disable-gpu --disable-software-rasterizer`. Trên profile tạm, tổ hợp đó dùng 351411 KB PSS khi mở example.com và ảnh chụp vẫn có chữ. `--use-angle=swiftshader --enable-unsafe-swiftshader` nặng hơn, 426327 KB. Extension đã cài, kể cả uBlock Origin Lite, vẫn nằm trong profile nhưng không được nạp.

## RAM đã đo

PSS tổng của Chromium, Xvfb, xfwm4, x11vnc và websockify. Cùng profile, cùng cách mở `https://vnexpress.net/` qua CDP HTTP. Đo khoảng 8 giây sau khi CDP lên, rồi khoảng 12 giây sau khi mở trang.

| Trạng thái | Rảnh | Đang mở trang |
|---|---:|---:|
| Stack cũ, headed, Xvfb + xfwm4 + VNC luôn chạy | 662889 KB | 894581 KB |
| Headless mới, không X và không VNC | 415212 KB | 678169 KB |
| GUI mới, Xvfb + xfwm4, VNC tắt | 493632 KB | 700053 KB |

Headless nhẹ hơn stack cũ ở cả hai lần đo, nên boot vẫn là headless. GUI chỉ bật khi cần giao diện thật. VNC chỉ bật khi có người xem.

Cờ thêm, một cờ mỗi dòng, để trong `/etc/vdesk/chromium-extra`. `install.sh` không ghi đè file này.

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

Script cài các gói `xvfb xfwm4 x11vnc novnc websockify xdotool ffmpeg dbus-x11 chromium libpulse0`, thêm `nodejs`, `npm`, `curl` và `iproute2` để cài `playwright-cli` và in kết quả kiểm tra. Sau đó nó chép unit, cài `vdesk`, bật Chromium headless, cài `@playwright/cli` và skill `playwright-cli`.

Xvfb, xfwm4, x11vnc và websockify được cài nhưng không `enable`. Boot không bật chúng.

Nếu user service là root, `/etc/vdesk/config` có `VDESK_NO_SANDBOX=1` và launcher thêm `--no-sandbox`. User thường không có cờ này.

Thêm đoạn trong `pi/AGENTS.md.example` vào file hướng dẫn mà Pi đọc, thường là `~/.pi/agent/AGENTS.md`.

## Kết nối từ điện thoại

Cổng chỉ nghe `127.0.0.1`. Từ điện thoại, mở SSH tunnel rồi nối vào `localhost` của chính điện thoại. Trước đó chạy `vdesk view on` trên server. Headless không có màn hình để xem.

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

Xem xong: `vdesk view off`. Chromium vẫn chạy.

## Cho Pi dùng playwright-cli

Phiên `playwright-cli attach` mất khi Chromium khởi động lại, kể cả khi `vdesk mode` hoặc `vdesk view on` phải rời headless. Pi phải gắn lại trước khi điều khiển trình duyệt:

```bash
playwright-cli attach --cdp=http://127.0.0.1:9222
```

Nếu lệnh lỗi, xem `vdesk status`, `systemctl status vdesk-browser` và `curl -s http://127.0.0.1:9222/json/version`.

Đoạn cần có trong hướng dẫn của Pi nằm ở `pi/AGENTS.md.example`.

## Xử lý sự cố

| Triệu chứng | Việc kiểm tra |
|---|---|
| Chromium báo không nối được dbus | Unit vẫn bọc `dbus-run-session`. Restart `vdesk-browser`. Không chạy Chromium trần ngoài session bus. |
| Chromium thoát ngay khi user là root | Thiếu `--no-sandbox`. `VDESK_NO_SANDBOX=1` chỉ dành cho root. User thường thì để `0`. |
| `9222` bị chiếm | `ss -ltnp \| grep 9222`. Dừng tiến trình Chromium khác đang giữ cổng, rồi `systemctl restart vdesk-browser`. |
| VNC từ xa không vào | Đúng như thiết kế. Tunnel SSH trước. `ss` phải thấy `127.0.0.1:5900`, không thấy `0.0.0.0:5900` hay `[::]:5900`. |
| VNC báo server không chạy | Chạy `vdesk view on`. Client dùng `127.0.0.1`, cổng `5900`. Headless không mở cổng 5900. x11vnc dùng `-localhost -no6 -noipv6`. |
| Sau reboot desktop cũng lên | Không đúng với bản này. `systemctl is-enabled vdesk-xvfb` phải là `disabled`. `vdesk status` lúc boot là `mode=headless`. |
| Sau reboot không có CDP | `systemctl is-enabled vdesk-browser vdesk-apply vdesk-idle.timer` và `vdesk status`. |
| Đổi mode xong Pi không bấm được | Attach cũ đã chết. Chạy lại `playwright-cli attach --cdp=http://127.0.0.1:9222`. |
| Mở nhạc không có tiếng | Container không có `/dev/snd`. Nếu có socket `/tmp/.pulse-socket`, hoặc `PULSE_SERVER` trong `/etc/profile.d/droidspaces_env.sh`, `install.sh` ghi `/etc/pulse/client.conf.d/vdesk.conf` (`enable-shm = no`) và drop-in `PULSE_SERVER` cho `vdesk-browser`. Chromium xóa environment sau khi khởi động, nên chỉ đặt biến trong unit là không đủ. `journalctl -u vdesk-browser` không được còn `PcmOpen: default`. Đổi mode không xóa cấu hình này. |
| Nhạc nghe kém | Sink AAudio mặc định là 48000 Hz, chế độ low-latency, và resample `speex-float-1`. `vdesk-audio` chỉnh sink về 44100 Hz, `pm=0`, buffer 120 ms. `pactl list sink-inputs` phải thấy `Resample method: copy`. |

## Gỡ

```bash
sudo ./uninstall.sh
```

Script dừng, disable và xoá unit, lệnh `vdesk`, `/etc/vdesk` và `/var/lib/vdesk`. Không xoá profile Chromium, file mật khẩu VNC, gói apt, hay `playwright-cli`.

## Bảo mật

- x11vnc dùng `-localhost -no6 -noipv6`, nên chỉ bind `127.0.0.1:5900`. `-listen 127.0.0.1` vẫn mở `[::]:5900` trên cổng 5900. noVNC nối thẳng `127.0.0.1:5900` và chỉ nghe `127.0.0.1:6080`. CDP cũng chỉ bind `127.0.0.1`.
- `vdesk view on` từ chối tiếp nếu cổng VNC không còn đúng `127.0.0.1`.
- Chỉ vào bằng SSH tunnel. Không publish `5900`, `6080`, hoặc `9222`.
- CDP cho phép điều khiển trình duyệt đang đăng nhập. Lộ `9222` ra ngoài là trao quyền đó cho người khác.
- Đặt mật khẩu VNC lúc cài. Không viết mật khẩu vào unit, README, script, hay `/etc/vdesk/config`.
- Chạy bằng user thường. `--no-sandbox` với root chỉ dành cho máy thử.

## English summary

Boot starts Chromium headless with CDP on `127.0.0.1:9222` and the same `--user-data-dir` used later for the headed browser. `vdesk mode gui` starts Xvfb and `xfwm4`, then relaunches Chromium headed. `vdesk view on` starts x11vnc on `127.0.0.1:5900` and noVNC/websockify on `127.0.0.1:6080`, switching to gui first if needed. `vdesk view off` stops only those two processes and does not restart Chromium. After a mode change, attach again with `playwright-cli attach --cdp=http://127.0.0.1:9222`.

An idle timer returns to headless after 10 minutes with no VNC client and no CDP client. View alone turns off after 10 minutes with no VNC client.

Tested on Debian 13. Ubuntu 24.04 is not verified: its apt `chromium` package is a transitional Snap wrapper. `sudo ./install.sh` installs the packages, asks for the service user and resolution, prompts for a VNC password, and does not enable the display units. On this host, headless PSS was 415212 KB idle and 678169 KB with the same page open, against 662889 KB and 894581 KB for the old always-on headed stack, so headless stays the boot default. x11vnc uses `-localhost -no6 -noipv6` because `-listen 127.0.0.1` still opened `[::]:5900`. If IPv6 is disabled, the script removes `localhost` from the `::1` line in `/etc/hosts`. PulseAudio client configuration is unchanged: if `/tmp/.pulse-socket` or Droidspaces `PULSE_SERVER` is present, Chromium still uses that socket with shared memory disabled. Access the desktop only through an SSH tunnel. Do not expose ports `5900`, `6080`, or `9222`.
