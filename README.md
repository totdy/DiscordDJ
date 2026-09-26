# DiscordDJ

DiscordDJ streams the audio of one local application into a Discord voice
channel. The repository now contains separate native capture implementations:

- [`Windows/`](Windows/) — C#/.NET 8 with WASAPI process loopback
- [`MacOS/`](MacOS/) — Swift with ScreenCaptureKit and a bundled Discord voice bridge

## Windows

Requires Windows 10 build 19041 or newer and .NET 8.

```powershell
cd Windows
dotnet restore
dotnet run
```

Examples:

```text
!stream Spotify.exe
!stream DuckDuckGo.exe
```

The Windows version selects the oldest matching process so multi-process
browsers are captured from their root process.

## macOS native app

Requires macOS 14+, Xcode Command Line Tools, Node.js 22.12+, and pnpm to
build. The completed app runs without Node, pnpm, or Terminal.

```bash
cd MacOS
pnpm install
./scripts/build-app.sh
```

Double-click `MacOS/dist/DiscordDJ.app`, set the bot token in Settings, and
choose a capture app from its menu-bar icon. From any other computer, join a
voice channel and send:

```text
!here
!stop
```

On first use, grant Screen & System Audio Recording permission in System
Settings > Privacy & Security. See [`MacOS/README.md`](MacOS/README.md) for the
complete macOS setup.

## Discord bot setup

Enable **Message Content Intent** in the Discord Developer Portal. Invite the
bot with `View Channels`, `Send Messages`, `Connect`, and `Speak` permissions.
Set `DISCORD_TOKEN` in the environment for Windows. The macOS app stores its
token securely in Keychain through Settings.

Only stream audio you have permission to share, and follow Discord's and the
source application's terms of service.
