# detour

![Linux](https://img.shields.io/badge/Linux-only-FCC624?logo=linux&logoColor=black)
![Bash](https://img.shields.io/badge/bash-4.4%2B-4EAA25?logo=gnubash&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-blue)

**Vesktop and Discord on Linux, always on the fastest connection that works.**

Each time you open Vesktop or Discord, detour checks every way of reaching Discord and uses the fastest one that gets through:

- a direct connection
- any proxy or VPN app running on your computer (v2rayN, Hiddify, Throne/NekoRay, Clash/mihomo, sing-box, Cloudflare WARP...)
- your own proxies, if you add any

Nothing to configure, no system-wide VPN, no root.

On Windows? [discord-drover](https://github.com/hdrover/discord-drover) does the same job there.

## Install

Paste this in a terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/svytl/detour/main/get.sh | bash
```

Then **fully quit** Vesktop/Discord (tray icon → **Quit**) and open it again. That's it: your normal Vesktop/Discord icon now picks the best connection by itself.

<details>
<summary>Install without the one-liner</summary>

Download `detour.zip` from [Releases](../../releases/latest), extract it, open a terminal in the folder and run `bash install.sh`.
</details>

## How "auto" picks

1. It looks for proxy apps running on your computer: their usual ports, and any port a known proxy app is listening on.
2. It tests a direct connection and every proxy it found at the same time, by actually reaching Discord through each one.
3. It opens the app through the fastest one. If direct is about as fast, direct wins, so things keep working if you close your proxy app.

If nothing gets through, it waits up to 20 seconds for a proxy app to start (handy at login), then tells you.

See what it finds right now:

```sh
detour --check
```

```
Testing routes to Discord...
  direct                             can't reach Discord
  socks5://127.0.0.1:10808           ok, 142 ms   <- best
  http://127.0.0.1:10809             ok, 158 ms
Vesktop will connect through: socks5://127.0.0.1:10808
```

## No proxy app yet?

Any of the apps above works. **Cloudflare WARP** is free and detour finds it automatically in proxy mode:

```sh
warp-cli registration new
warp-cli mode proxy
warp-cli connect
```

## Your own proxies (optional)

Have a proxy from a friend or a provider? Add it, and it joins the race:

```sh
detour --set-proxy "auto, socks5://1.2.3.4:1080"
detour --set-proxy "auto, http://user:password@proxy.example.com:3128"
```

SOCKS5, SOCKS4, HTTP and HTTPS work, including ones with a login. Separate several with commas. Other settings:

```sh
detour --set-proxy auto     # back to the default
detour --set-proxy off      # never use a proxy
```

The config lives in `~/.config/detour/detour.ini` if you'd rather edit it by hand.

## Voice chat

Voice and video always use UDP **directly**. Chromium doesn't send them through a proxy, and Discord's voice servers don't accept voice over TCP. Everything else (chat, images, login, updates) goes through the chosen route.

If voice is blocked where you are, turn on **TUN mode** in your proxy app (v2rayN, Throne, Hiddify, sing-box and mihomo all have it). That covers UDP too, and detour sees the connection as "direct" and works with it.

## Uninstall

```sh
bash ~/.local/share/detour/uninstall.sh
```

This puts your app icons back exactly as they were. Add `--purge` to delete the config too.

## Troubleshooting

**"Vesktop is already open without Detour"**: it was still running in the tray from before. Quit it from the tray icon and open it again.

**Stuck on "Connecting"**: run `detour --check`. If nothing says `ok`, no route gets through. Start your proxy app or WARP.

**Want to keep the original icons untouched?** Reinstall with `bash install.sh --separate-icon`. You'll get a separate "Vesktop (Detour)" entry instead.

## Details

Vesktop and Discord are Electron (Chromium) apps, so they accept Chromium's `--proxy-server` switch. Detour starts them with it, or with `--no-proxy-server` when direct is best. For a proxy with a login it also runs `detour-auth-proxy.py`. Chromium can't take a username and password on the command line, so this tiny local proxy on `127.0.0.1` adds the login for it, and it stops when the app does.

| | Flatpak | Native (AUR, .deb, .rpm, tar) |
|---|---|---|
| Vesktop | ✅ | ✅ |
| Discord / PTB / Canary | ✅ | ✅ |

What the installer touches (all in your home folder):

- `~/.local/share/detour/`: the program
- `~/.local/bin/detour`: the `detour` command
- `~/.config/detour/detour.ini`: settings
- `~/.local/share/applications/`: copies of your Vesktop/Discord icons that start through detour. Any icon you had customized is backed up.
- `~/.config/autostart/`: only if Vesktop/Discord already starts on login

Needs `bash`, `curl`, and `python3` (only for proxies with a login). Most distros have all three.

## License

MIT
