using System;
using System.Threading;
using System.Threading.Tasks;
using Discord;
using Discord.Audio;
using Discord.WebSocket;

namespace SpotifyDiscordBot;

public static class Program
{
    private const string CommandPrefix = "!";
    private const int VoiceConnectAttempts = 3;
    private static string _token = "";

    private static DiscordSocketClient _client = null!;
    private static ProcessLoopbackCapture? _capture;
    private static CancellationTokenSource? _streamCts;
    private static Discord.Audio.IAudioClient? _voiceClient;
    private static SocketVoiceChannel? _connectedChannel;

    public static async Task Main()
    {
        DotNetEnv.Env.Load(); // reads .env in the working directory into process env vars, if present

        _token = Environment.GetEnvironmentVariable("DISCORD_TOKEN") ?? "";
        if (string.IsNullOrWhiteSpace(_token))
        {
            Console.WriteLine("DISCORD_TOKEN is not set. Add it to a .env file or set it as an environment variable.");
            return;
        }

        var config = new DiscordSocketConfig
        {
            GatewayIntents = GatewayIntents.Guilds
                | GatewayIntents.GuildMessages
                | GatewayIntents.GuildVoiceStates
                | GatewayIntents.MessageContent,
            EnableVoiceDaveEncryption = true,
        };

        _client = new DiscordSocketClient(config);
        _client.Log += msg => { Console.WriteLine(msg); return Task.CompletedTask; };
        _client.MessageReceived += msg =>
        {
            _ = Task.Run(async () =>
            {
                try
                {
                    await OnMessageReceived(msg);
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"Unhandled exception in message handler: {ex}");
                }
            });
            return Task.CompletedTask;
        };

        await _client.LoginAsync(TokenType.Bot, _token);
        await _client.StartAsync();

        await Task.Delay(-1);
    }

    private static async Task OnMessageReceived(SocketMessage message)
    {
        if (message.Author.IsBot) return;
        if (message is not SocketUserMessage userMessage) return;
        if (!userMessage.Content.StartsWith(CommandPrefix)) return;

        string command = userMessage.Content[CommandPrefix.Length..].Trim();
        var channel = message.Channel as SocketTextChannel;
        var guildUser = message.Author as SocketGuildUser;

        if (command.StartsWith("stream"))
        {
            // Usage: !stream Spotify.exe   (defaults to Spotify.exe)
            var parts = command.Split(' ', 2);
            string processName = parts.Length > 1 ? parts[1].Trim() : "Spotify.exe";
            await HandleStream(channel, guildUser, processName);
        }
        else if (command.StartsWith("stopstream"))
        {
            await HandleStop(channel);
        }
    }

    private static async Task HandleStream(SocketTextChannel? channel, SocketGuildUser? user, string processName)
    {
        if (channel is null || user is null) return;

        var voiceChannel = user.VoiceChannel;
        if (voiceChannel is null)
        {
            await channel.SendMessageAsync("You need to be in a voice channel first.");
            return;
        }

        if (_voiceClient is not null)
        {
            await channel.SendMessageAsync("Already streaming. Use `!stopstream` first.");
            return;
        }

        int pid;
        try
        {
            pid = ProcessLoopbackCapture.FindProcessId(processName);
        }
        catch (Exception ex)
        {
            await channel.SendMessageAsync($"Couldn't find process `{processName}`: {ex.Message}");
            return;
        }

        try
        {
            _voiceClient = await ConnectVoiceWithRetryAsync(voiceChannel);
        }
        catch (Exception ex)
        {
            await channel.SendMessageAsync($"Failed to connect to voice after {VoiceConnectAttempts} attempts: {ex.Message}");
            return;
        }

        _connectedChannel = voiceChannel;
        _capture = new ProcessLoopbackCapture();

        try
        {
            await _capture.StartAsync(pid);
        }
        catch (Exception ex)
        {
            await channel.SendMessageAsync($"Failed to start audio capture: {ex.Message}");
            await voiceChannel.DisconnectAsync();
            _voiceClient = null;
            _connectedChannel = null;
            _capture = null;
            return;
        }

        _streamCts = new CancellationTokenSource();
        _ = Task.Run(() => StreamLoop(_streamCts.Token));

        await channel.SendMessageAsync($"Streaming `{processName}` into **{voiceChannel.Name}**.");
    }

    private static async Task<Discord.Audio.IAudioClient> ConnectVoiceWithRetryAsync(SocketVoiceChannel voiceChannel)
    {
        Exception? lastError = null;

        for (var attempt = 1; attempt <= VoiceConnectAttempts; attempt++)
        {
            try
            {
                return await voiceChannel.ConnectAsync(
                    selfDeaf: true,
                    selfMute: false,
                    external: false,
                    disconnect: true);
            }
            catch (Exception ex) when (IsRetryableVoiceConnectError(ex))
            {
                lastError = ex;
                Console.WriteLine($"Voice connect attempt {attempt}/{VoiceConnectAttempts} failed: {ex.Message}");

                try
                {
                    await voiceChannel.DisconnectAsync();
                }
                catch (Exception disconnectEx)
                {
                    Console.WriteLine($"Voice disconnect cleanup failed: {disconnectEx.Message}");
                }

                if (attempt < VoiceConnectAttempts)
                {
                    await Task.Delay(TimeSpan.FromSeconds(attempt * 2));
                }
            }
        }

        throw lastError ?? new TimeoutException("Discord voice connection did not complete.");
    }

    private static bool IsRetryableVoiceConnectError(Exception ex)
    {
        return ex is TimeoutException
            || ex is System.Net.WebSockets.WebSocketException
            || ex.GetType().Name == "WebSocketClosedException";
    }

    private static async Task StreamLoop(CancellationToken ct)
    {
        if (_voiceClient is null || _capture is null) return;

        using var pcmStream = _voiceClient.CreateDirectPCMStream(AudioApplication.Music);
        using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(20));

        try
        {
            _capture.WaitForPrebuffer(ct);

            while (await timer.WaitForNextTickAsync(ct))
            {
                byte[] frame = _capture.ReadFrame();
                await pcmStream.WriteAsync(frame, 0, frame.Length, ct);
            }
        }
        catch (OperationCanceledException)
        {
            // expected on stop
        }
        finally
        {
            await pcmStream.FlushAsync(CancellationToken.None);
        }
    }

    private static async Task HandleStop(SocketTextChannel? channel)
    {
        if (channel is null) return;

        if (_voiceClient is null)
        {
            await channel.SendMessageAsync("Not currently streaming.");
            return;
        }

        _streamCts?.Cancel();
        _capture?.Dispose();
        _capture = null;

        if (_connectedChannel is not null)
        {
            await _connectedChannel.DisconnectAsync();
            _connectedChannel = null;
        }
        _voiceClient = null;

        await channel.SendMessageAsync("Stopped streaming.");
    }
}
