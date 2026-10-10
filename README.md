# vdesk-agent-browser

Trình duyệt cho agent: Chromium giữ một profile, Pi điều khiển bằng CDP `127.0.0.1:9222`. Desktop và VNC chỉ bật khi cần, vì container Droidspaces trên Android thiếu RAM.

Bản này dùng gói `chromium` của Debian, không dùng Google Chrome. Trên arm64 không có gói Chrome chính thức.

## Chế độ

Boot mặc định là headless. Không có Xvfb, xfwm4, x11vnc hay websockify.

```text
headless (mặc định)
  Chromium --ozone-platform=headless
  không có --headless=new, để UA không thành HeadlessChrome
  CDP 127.0.0.1:9222
       |
       patchright-cli attach --cdp=http://127.0.0.1:9222 --context=host

gui    vdesk mode gui
  Xvfb :1  1920x1200x24 +GLX
  xfwm4 --compositor=off
  Chromium có giao diện, cùng --user-data-dir
  CDP 127.0.0.1:9222

view   vdesk view on
  x11vnc      127.0.0.1:5900
  websockify  127.0.0.1:6080
  mạng NAT thêm IPv4 hiện tại của eth0:5900
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

Sau mỗi lần Chromium khởi động lại, phiên `patchright-cli attach` mất. Phải gắn lại:

```bash
patchright-cli attach --cdp=http://127.0.0.1:9222 --context=host
```

Output của `vdesk` có `restarted=yes` khi phải gắn lại, `restarted=no` khi không.

Không có client VNC và không có client CDP trong 10 phút thì `vdesk-idle.timer` đưa về headless. Chỉ không có người xem thì timer tắt view, không khởi động lại Chromium. Đặt `VDESK_IDLE_SEC=0` trong `/etc/vdesk/config` để tắt hành vi này, rồi `systemctl daemon-reload` không cần vì lệnh `vdesk` đọc file mỗi lần chạy.

## RAM

Launcher là `/usr/local/libexec/vdesk-chromium`. Nó gọi `/usr/lib/chromium/chromium`, không gọi wrapper `/usr/bin/chromium`, vì wrapper thêm `--enable-gpu-rasterization` và `--load-extension`.

Cờ giảm RAM: `--disable-extensions`, `--disable-component-extensions-with-background-pages`, `--disable-background-networking`, `--disable-component-update`, `--disable-sync`, `--renderer-process-limit` (mặc định 2), `--process-per-site`, cache đĩa 32MB. Headless thêm `--ozone-platform=headless --disable-gpu --disable-software-rasterizer` và `--ozone-override-screen-size` bằng độ phân giải đã cài. Không dùng `--headless=new`: trên Chromium Debian này cờ đó đổi UA thành `HeadlessChrome`. Headless không dùng SwiftShader. Extension đã cài, kể cả uBlock Origin Lite, vẫn nằm trong profile nhưng không được nạp.

Điều kiện Turnip và cách cài Mesa nằm ở mục GPU Adreno (tùy chọn). Khi probe đạt, GUI dùng Mesa kgsl/Turnip, không dùng llvmpipe. Gói Debian 25.0.7 không có Adreno 840. Giải `mesa-for-android-container_26.3.0-devel-20260824_debian_trixie_arm64.tar.gz` từ [mesa-for-android-container](https://github.com/lfdevs/mesa-for-android-container/releases/tag/mesa-26.3.0-devel-20260824) vào `/`, chạy `ldconfig`, rồi `apt-mark hold libegl-mesa0 libgbm1 libgl1-mesa-dri libglx-mesa0 mesa-libgallium mesa-vulkan-drivers`. Khi probe đạt, launcher GUI đặt `MESA_LOADER_DRIVER_OVERRIDE=kgsl` và `TU_DEBUG=noconform` trước `exec`, rồi thêm `--use-angle=vulkan`. Zygote không chuyển hai biến này sang tiến trình GPU; ICD Vulkan vẫn chọn Turnip. `--use-gl=egl` bị Chromium 154 từ chối vì chỉ cho `gl=egl-angle`. `--use-angle=gl` đi qua GLX; với `kgsl` thì kết nối Xvfb bị cắt. Xvfb không có DRI3, GLX vẫn là llvmpipe, nhưng WebGL qua Turnip vẫn báo `Adreno (TM) 840`. Không cần Termux:X11 cho đường này. Headless giữ `--disable-gpu`. Trên máy này, PSS Chromium GUI khi mở https://vnexpress.net/ là 663977 KB trước Mesa (llvmpipe) và 693431 KB sau Turnip, cùng cách đo cgroup `smaps_rollup` 12 giây sau CDP HTTP.

Launcher cũng đặt `TZ=Asia/Ho_Chi_Minh`, `--lang=vi-VN`, `--accept-lang=vi-VN,vi,en-US,en` và `--disable-blink-features=AutomationControlled`. Unit `vdesk-browser` đặt cùng `TZ`. `--enable-automation` và `--headless` trong `/etc/vdesk/chromium-extra` bị từ chối. Độ phân giải cửa sổ và màn hình headless lấy từ `/etc/vdesk/config`, mặc định `1920x1200`.

Trên Chromium này, `Intl` báo múi giờ là `Asia/Saigon`. Đó là tên ICU của cùng múi `Asia/Ho_Chi_Minh`, lệch UTC +7. `bot.sannysoft.com` trước đây đỏ ở WebGL vì không bật SwiftShader. GUI nay có WebGL qua Turnip; headless vẫn tắt GPU. Chưa đo lại trang đó sau khi đổi. `browserscan.net/bot-detection` không dùng mục đó để kết luận robot.

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

Script cài các gói `xvfb xfwm4 x11vnc novnc websockify xdotool ffmpeg dbus-x11 chromium libpulse0`, thêm `curl` và `iproute2` để in kết quả kiểm tra. Sau đó nó chép unit, cài `vdesk`, bật Chromium headless, cài `patchright-cli` 0.7.0 vào `/usr/local/lib/vdesk-patchright` và skill `patchright-cli`. Không tải Chromium của Patchright. Nếu chưa có `uv`, script cài `uv` cho root rồi dùng nó tạo venv.

Xvfb, xfwm4, x11vnc và websockify được cài nhưng không `enable`. Boot không bật chúng.

Nếu user service là root, `/etc/vdesk/config` có `VDESK_NO_SANDBOX=1` và launcher thêm `--no-sandbox`. User thường không có cờ này.

Thêm đoạn trong `pi/AGENTS.md.example` vào file hướng dẫn mà Pi đọc, thường là `~/.pi/agent/AGENTS.md`.

## Kết nối từ điện thoại

Trước đó chạy `vdesk view on` trên server. Headless không có màn hình để xem.

### AVNC thẳng vào IP container

`vdesk view on` đọc `net_mode` trong `/run/droidspaces/container.config`. Không ghi IP vào `/etc/vdesk/config`.

- `nat`: lấy IPv4 global hiện tại của `eth0` và chuyển tiếp đúng địa chỉ đó. `vdesk status` in địa chỉ trong `vnc_listen`. AVNC dùng địa chỉ đó, cổng `5900`, mật khẩu VNC đã đặt lúc cài. Không cần tunnel SSH cho cổng 5900.
- `host`: không chạy chuyển tiếp. `127.0.0.1` đã là loopback của điện thoại.
- `none`, không có IP, hoặc `net_mode` không đọc được: lệnh báo lỗi và không mở forwarder.

CDP `9222` và noVNC `6080` vẫn chỉ nghe `127.0.0.1`. `vdesk view on` từ chối nếu cổng 5900 không đúng các địa chỉ vừa chọn, hoặc nếu có `0.0.0.0:5900` hay `[::]:5900`. x11vnc vẫn dùng `-localhost -no6 -noipv6`. Không dùng `-listen`: trên x11vnc 0.9.17, `-listen` vẫn mở `[::]:5900`. Forwarder chỉ bind IPv4 của `eth0` và nối vào `127.0.0.1:5900`, nên mật khẩu VNC vẫn bắt buộc.

### AVNC + tunnel cổng 5900

Dùng khi `net_mode=host`, hoặc khi không muốn AVNC nối thẳng vào IP NAT.

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

## Cho Pi dùng patchright-cli

Pi điều khiển Chromium đang chạy bằng Patchright, qua `patchright-cli` 0.7.0. Lệnh giống `playwright-cli`, nhưng driver không gửi `Runtime.enable` lúc gắn trang. Đó là bản vá chống phát hiện CDP của Patchright, và nó vẫn có tác dụng khi `connect_over_cdp` vào Chromium có sẵn. Các cờ khởi động thì không: Patchright chỉ sửa cờ khi chính nó mở trình duyệt, nên launcher tự bỏ `--enable-automation` và `--headless`.

Không chạy `patchright-cli open`. Lệnh đó mở trình duyệt khác, không dùng profile và CDP của vdesk. Không chạy `playwright-cli`.

Phiên attach mất khi Chromium khởi động lại, kể cả khi `vdesk mode` hoặc `vdesk view on` phải rời headless. Pi phải gắn lại trước khi điều khiển trình duyệt:

```bash
patchright-cli attach --cdp=http://127.0.0.1:9222 --context=host
```

`--context=host` bắt buộc. Context mới, mặc định của lệnh attach, không thấy cookie trong profile. `close` bị từ chối trên context này. `patchright-cli detach` chỉ ngắt phiên, không tắt Chromium.

Nếu lệnh lỗi, xem `vdesk status`, `systemctl status vdesk-browser` và `curl -s http://127.0.0.1:9222/json/version`.

Đoạn cần có trong hướng dẫn của Pi nằm ở `pi/AGENTS.md.example`.

## GPU Adreno (tùy chọn)

vdesk không cài Mesa. GUI chỉ dùng Turnip khi Droidspaces bật GPU Access, có `/dev/kgsl-3d0`, và `vulkaninfo` hoặc `eglinfo` in `turnip`. Thiếu điều kiện nào thì launcher dùng SwiftShader. Headless vẫn tắt GPU.

Bản trên máy này là `Mesa 26.3.0-devel (git-98f3d6229d)`, lấy từ tarball `mesa-for-android-container_26.3.0-devel-20260824_debian_trixie_arm64.tar.gz` của [mesa-for-android-container](https://github.com/lfdevs/mesa-for-android-container). File đã giải được liệt kê trong `/root/mesa-android.files`. Chúng đè lên gói Debian `25.0.7-2+deb13u1`, không phải gói deb riêng.

Cài, chỉ trên arm64 khi container đã bật GPU Access và tắt VirGL:

```bash
sudo apt-mark hold libegl-mesa0 libgbm1 libgl1-mesa-dri libglx-mesa0 mesa-libgallium mesa-vulkan-drivers
sudo tar -C / -xzf mesa-for-android-container_26.3.0-devel-20260824_debian_trixie_arm64.tar.gz
sudo tar -tzf mesa-for-android-container_26.3.0-devel-20260824_debian_trixie_arm64.tar.gz > /root/mesa-android.files
sudo ldconfig
```

Kiểm tra:

```bash
test -c /dev/kgsl-3d0
awk -F= '$1=="enable_gpu_mode"{print}' /run/droidspaces/container.config
timeout 8 env MESA_LOADER_DRIVER_OVERRIDE=kgsl TU_DEBUG=noconform vulkaninfo --summary | grep -i turnip
```

Dòng cần thấy gồm `driverName = turnip` hoặc `DRIVER_ID_MESA_TURNIP`. `apt-mark showhold` phải còn đúng sáu gói ở trên.

Gỡ overlay bằng danh sách đã lưu, không gỡ bằng apt khi các file Turnip vẫn đang là bản muốn giữ:

```bash
while IFS= read -r rel; do
  sudo rm -f "/${rel#./}"
done < /root/mesa-android.files
```

Không chạy `apt-get install --reinstall` cho sáu gói đang hold. Lệnh đó thay file Turnip bằng Mesa Debian `25.0.7` và GUI hết Adreno. Chỉ unhold rồi cài lại các gói Debian sau khi đã xóa overlay và cố ý muốn driver của Debian.

## Xử lý sự cố

| Triệu chứng | Việc kiểm tra |
|---|---|
| Chromium báo không nối được dbus | Unit vẫn bọc `dbus-run-session`. Restart `vdesk-browser`. Không chạy Chromium trần ngoài session bus. |
| Chromium thoát ngay khi user là root | Thiếu `--no-sandbox`. `VDESK_NO_SANDBOX=1` chỉ dành cho root. User thường thì để `0`. |
| `9222` bị chiếm | `ss -ltnp \| grep 9222`. Dừng tiến trình Chromium khác đang giữ cổng, rồi `systemctl restart vdesk-browser`. |
| VNC từ xa không vào | Host mode: tunnel SSH, `ss` chỉ thấy `127.0.0.1:5900`. NAT: AVNC dùng `vnc_listen` từ `vdesk status`, cổng `5900`; `ss` phải thấy cả `127.0.0.1:5900` lẫn IP đó. Không được thấy `0.0.0.0:5900` hay `[::]:5900`. |
| VNC báo server không chạy | Chạy `vdesk view on`. Headless không mở cổng 5900. x11vnc dùng `-localhost -no6 -noipv6`. |
| Sau reboot desktop cũng lên | Không đúng với bản này. `systemctl is-enabled vdesk-xvfb` phải là `disabled`. `vdesk status` lúc boot là `mode=headless`. |
| Sau reboot không có CDP | `systemctl is-enabled vdesk-browser vdesk-apply vdesk-idle.timer` và `vdesk status`. |
| Đổi mode xong Pi không bấm được | Attach cũ đã chết. Chạy lại `patchright-cli attach --cdp=http://127.0.0.1:9222 --context=host`. |
| Mở nhạc không có tiếng | Container không có `/dev/snd`. Nếu có socket `/tmp/.pulse-socket`, hoặc `PULSE_SERVER` trong `/etc/profile.d/droidspaces_env.sh`, `install.sh` ghi `/etc/pulse/client.conf.d/vdesk.conf` (`enable-shm = no`). Không đặt lại `PULSE_SERVER` trên unit. Chromium xóa environment sau khi khởi động, nên file client là phần còn hiệu lực. `journalctl -u vdesk-browser` không được còn `PcmOpen: default`. Nếu socket mất lúc boot, file này bị xóa và `vdesk-audio` không chạy. |
| Nhạc nghe kém | Sink AAudio mặc định là 48000 Hz, chế độ low-latency, và resample `speex-float-1`. `vdesk-audio` chỉnh sink về 44100 Hz, `pm=0`, buffer 120 ms. `pactl list sink-inputs` phải thấy `Resample method: copy`. |

## Gỡ

```bash
sudo ./uninstall.sh
```

Script dừng, disable và xoá unit, lệnh `vdesk`, launcher, `/etc/vdesk`, `/var/lib/vdesk`, symlink `patchright-cli` và `/usr/local/lib/vdesk-patchright`. Không xoá profile Chromium, file mật khẩu VNC, gói apt (kể cả Debian `chromium`), `uv`, `/etc/hosts`, hay skill `~/.agents/skills/patchright-cli`.

## Bảo mật

- x11vnc dùng `-localhost -no6 -noipv6`, nên chỉ bind `127.0.0.1:5900`. `-listen`, kể cả kèm `-no6 -noipv6`, vẫn mở `[::]:5900`. noVNC nối thẳng `127.0.0.1:5900` và chỉ nghe `127.0.0.1:6080`. CDP cũng chỉ bind `127.0.0.1`.
- Host mode chỉ bind `127.0.0.1:5900`. NAT thêm đúng IPv4 hiện tại của `eth0`. Không đặt `0.0.0.0`.
- Không publish `6080` hoặc `9222`. Không publish `5900` ra `0.0.0.0`. Host mode chỉ vào VNC bằng SSH tunnel.
- CDP cho phép điều khiển trình duyệt đang đăng nhập. Lộ `9222` ra ngoài là trao quyền đó cho người khác.
- Đặt mật khẩu VNC lúc cài. Không viết mật khẩu vào unit, README, script, hay `/etc/vdesk/config`.
- Chạy bằng user thường. `--no-sandbox` với root chỉ dành cho máy thử.

## English summary

Boot starts Debian Chromium on the ozone headless platform, without `--headless=new`, with `--disable-gpu` and CDP on `127.0.0.1:9222` and the same `--user-data-dir` used later for the headed browser. The launcher sets `TZ=Asia/Ho_Chi_Minh`, `--lang=vi-VN`, and a fixed screen size. `vdesk mode gui` starts Xvfb and `xfwm4`, then relaunches Chromium headed. Turnip is used only when the GPU probe passes; otherwise gui mode uses SwiftShader. `--use-gl=egl` is not allowed by this Chromium, and `--use-angle=gl` drops the Xvfb connection when kgsl is forced. Xvfb has no DRI3, so GLX stays llvmpipe. Termux:X11 is not required for the Vulkan path. `vdesk view on` starts x11vnc on `127.0.0.1:5900` and noVNC/websockify on `127.0.0.1:6080`, switching to gui first if needed. `vdesk view off` stops only those two processes and does not restart Chromium. After a mode change, attach again with `patchright-cli attach --cdp=http://127.0.0.1:9222 --context=host`. Do not run `patchright-cli open` or `playwright-cli`.

An idle timer returns to headless after 10 minutes with no VNC client and no CDP client. View alone turns off after 10 minutes with no VNC client.

Tested on Debian 13. Ubuntu 24.04 is not verified: its apt `chromium` package is a transitional Snap wrapper. `sudo ./install.sh` installs the packages, asks for the service user and resolution, prompts for a VNC password, and does not enable the display units. On this host, headless PSS was 415212 KB idle and 678169 KB with the same page open, against 662889 KB and 894581 KB for the old always-on headed stack, so headless stays the boot default. x11vnc uses `-localhost -no6 -noipv6` because `-listen` still opened `[::]:5900`. In NAT, `vdesk view on` forwards port 5900 to eth0's current IPv4; host mode stays on loopback. The VNC password still applies. If IPv6 is disabled, the script removes `localhost` from the `::1` line in `/etc/hosts`. PulseAudio client configuration is unchanged: if `/tmp/.pulse-socket` or Droidspaces `PULSE_SERVER` is present, Chromium still uses that socket with shared memory disabled. Do not expose ports `6080` or `9222`, and do not bind VNC to `0.0.0.0`.
