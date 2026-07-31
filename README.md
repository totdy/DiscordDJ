# DiscordDJ

DiscordDJ streams the audio of one local application into a Discord voice
channel. The repository now contains separate native capture implementations:

- [`Windows/`](Windows/) — C#/.NET 8 with WASAPI process loopback
- [`MacOS/`](MacOS/) — Swift with ScreenCaptureKit and a bundled Discord voice bridge

Both versions use the same Discord commands:

```text
!stream <application>
!stopstream
```

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

## macOS v2

Requires macOS 14+, Swift/Xcode Command Line Tools, and Node.js 22.12+.

```bash
cd MacOS
pnpm install
export DISCORD_TOKEN="your token"
swift run DiscordDJMac
```

Examples:

```text
!stream DuckDuckGo
!stream Spotify
!stream com.apple.Music
```

On first use, grant Screen & System Audio Recording permission in System
Settings > Privacy & Security. See [`MacOS/README.md`](MacOS/README.md) for the
complete macOS setup.

## Discord bot setup

Enable **Message Content Intent** in the Discord Developer Portal. Invite the
bot with `View Channels`, `Send Messages`, `Connect`, and `Speak` permissions.
Set `DISCORD_TOKEN` in the environment before launching either version.

Only stream audio you have permission to share, and follow Discord's and the
source application's terms of service.
