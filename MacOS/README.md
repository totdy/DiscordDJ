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

## Install and run

```bash
cd MacOS
pnpm install
export DISCORD_TOKEN="your token"
swift run DiscordDJMac
```

`npm install` also works if you do not use pnpm.

The first capture prompts for **Screen & System Audio Recording** permission.
Allow it in System Settings > Privacy & Security, then restart the program if
macOS requests a restart.

## Commands

Join a voice channel and send one of these in Discord:

```text
!stream DuckDuckGo
!stream Spotify
!stream com.apple.Music
!stopstream
```

The argument can be an application name or bundle identifier. It defaults to
`DuckDuckGo` when omitted. Start playback before running `!stream` so the app
appears in ScreenCaptureKit's list.

## Architecture

- `Sources/DiscordDJMac`: Swift application capture and PCM conversion
- `Bridge/index.js`: Discord gateway, voice, Opus, encryption, and DAVE

The bridge is deliberately isolated because Discord's voice protocol evolves
independently of macOS audio APIs. The capture pipeline remains native Swift.
