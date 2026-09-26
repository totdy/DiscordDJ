# DiscordDJ macOS v2

The macOS implementation captures audio from one running application with
ScreenCaptureKit, converts it to 48 kHz/16-bit/stereo PCM in Swift, and sends
it to Discord through the bundled voice/DAVE bridge.

## Requirements

- macOS 14 or newer
- Xcode Command Line Tools (`xcode-select --install`)
- Node.js 22.12 or newer
- A Discord bot with Message Content Intent enabled and permission to view,
  send, connect, and speak

## Build a native app

```bash
cd MacOS
pnpm install
./scripts/build-app.sh
```

Open `dist/DiscordDJ.app` by double-clicking it. The finished app includes its
own Node runtime and Discord bridge; the Mac running it does not need Terminal,
Node, or pnpm after the build. On the first launch, macOS may require approval
in System Settings > Privacy & Security because this local build is ad-hoc
signed.

The first capture prompts for **Screen & System Audio Recording** permission.
Allow it in System Settings > Privacy & Security, then restart the program if
macOS requests a restart.

## Commands

Choose a running app from DiscordDJ’s menu-bar icon. Then, from any computer,
join a voice channel and send:

```text
!here
!stop
```

`!here` makes the bot join the sender’s voice channel and stream the app selected
on the capture Mac. Anyone in a server where the bot is present can use these
commands.

## Architecture

- `Sources/DiscordDJMac`: native menu-bar app, secure token storage, capture,
  and PCM conversion
- `Bridge/index.js`: Discord gateway, voice, Opus, encryption, and DAVE

The bridge is deliberately isolated because Discord's voice protocol evolves
independently of macOS audio APIs. The capture pipeline remains native Swift.
