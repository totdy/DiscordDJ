# Spotify (or any app) → Discord Voice Bot — C# / .NET 8

Streams audio from a **specific process** (e.g. `Spotify.exe`) into a
Discord voice channel, using the native Windows WASAPI process-loopback
API. No virtual audio cable, no VB-Cable, nothing for end users to
install beyond the bot itself.

## Requirements
- Windows 10 build 19041 (2004) or later, or Windows 11
- .NET 8 SDK: https://dotnet.microsoft.com/download
- A Discord bot application + token: https://discord.com/developers/applications

## Discord.Net voice natives
Discord.Net's voice support needs two native libraries available at
runtime: `libsodium.dll` and `opus.dll`. This project references NuGet
packages for the Windows x64 builds of both libraries and targets
`win-x64`, so `dotnet build`, `dotnet run`, and `dotnet publish` copy
them into the app output automatically.

If voice fails with `DllNotFoundException` for `opus` or `libsodium`,
run `dotnet restore` and rebuild from a normal terminal so NuGet can
download the native packages.

## Build & run
```powershell
cd spotify-discord-bot-csharp
copy .env.example .env
# then edit .env and paste your real token in place of the placeholder
dotnet restore
dotnet run
```
`.env` is loaded automatically at startup (via the `DotNetEnv` package) and
is already gitignored, so your token never ends up in source control.
If you'd rather not use a `.env` file, setting `DISCORD_TOKEN` as a normal
environment variable (`setx DISCORD_TOKEN "..."`, new terminal required)
still works too — the code falls back to whatever's already in the
process environment.

For a distributable single-file exe (what you'd actually hand to users):
```powershell
dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true
```
This produces the app in
`bin\Release\net8.0-windows10.0.19041.0\win-x64\publish\` with no .NET
runtime install required on the target machine.

## Usage
In a Discord text channel, while you're in a voice channel:
```
!stream Spotify.exe
!stopstream
```
If you omit the process name, it defaults to `Spotify.exe`. You can
target any running process this way — browsers, games, other music
apps — since this isn't Spotify-specific at all.

## Where this is most likely to need debugging
This is native COM interop territory, so if it doesn't work first try,
these are the highest-probability failure points, roughly in order:
1. **`PROPVARIANT_BLOB` layout** — if `ActivateAudioInterfaceAsync`
   throws or the completion handler never fires, the blob struct offset
   assumptions are the first thing to check with a debugger/`sizeof`.
2. **Completion handler threading** — `ActivateCompleted` fires on a
   COM worker thread; if you see hangs, confirm the `TaskCompletionSource`
   continuation isn't deadlocking against the UI/main thread.
3. **`CreatePCMStream` pacing** — the `Task.Delay(20, ct)` in the stream
   loop is a simple pacer, not a precise clock; under load this can drift
   and cause audible stutter. A `PeriodicTimer` or a dedicated high-priority
   thread would be a more robust version if you notice choppiness.
4. **Process exits mid-stream** — if the target process closes while
   `IAudioClient` is active, expect the capture to start returning silence
   or throw; there's no reconnect logic yet, `!stopstream` + `!stream`
   again is the manual recovery path.

## Note
This captures whatever audio the target process is producing at the OS
level, regardless of which output device it's routed to. Keep in mind
Spotify's and Discord's terms of service and applicable copyright law
for how and where you use this, particularly if the bot will be audible
to people outside your own private use.
