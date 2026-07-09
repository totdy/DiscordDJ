using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace SpotifyDiscordBot;

/// <summary>
/// Captures audio from a single process (and its child processes) via
/// WASAPI process-loopback activation, and exposes it as a rolling
/// buffer of 48kHz/16-bit/stereo PCM — matching exactly what Discord's
/// voice pipeline requires, so no resampling step is needed downstream.
/// </summary>
public sealed class ProcessLoopbackCapture : IDisposable
{
    public const int TargetSampleRate = 48000;
    public const int TargetChannels = 2;
    public const int BytesPerSample = 2;
    private const int FrameMs = 20;
    public const int FrameBytes = TargetSampleRate * FrameMs / 1000 * TargetChannels * BytesPerSample; // 3840

    private readonly object _bufferLock = new();
    private byte[] _buffer = Array.Empty<byte>();
    private int _bufferLen;

    private INativeAudioClient? _audioClient;
    private IAudioCaptureClient? _captureClient;
    private WAVEFORMATEX _format;
    private volatile bool _running;
    private Thread? _pumpThread;

    public static int FindProcessId(string processName)
    {
        string bare = processName.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)
            ? processName[..^4]
            : processName;

        var procs = Process.GetProcessesByName(bare);
        if (procs.Length == 0)
            throw new InvalidOperationException($"No running process named '{processName}' found.");

        return procs[0].Id;
    }

    public async Task StartAsync(int processId)
    {
        _audioClient = await ActivateForProcessAsync(processId);

        _format = new WAVEFORMATEX
        {
            wFormatTag = 1, // WAVE_FORMAT_PCM
            nChannels = TargetChannels,
            nSamplesPerSec = TargetSampleRate,
            wBitsPerSample = 16,
        };
        _format.nBlockAlign = (ushort)(_format.nChannels * _format.wBitsPerSample / 8);
        _format.nAvgBytesPerSec = _format.nSamplesPerSec * _format.nBlockAlign;
        _format.cbSize = 0;

        _audioClient.Initialize(
            NativeMethods.AUDCLNT_SHAREMODE_SHARED,
            NativeMethods.AUDCLNT_STREAMFLAGS_LOOPBACK,
            10_000_000, // 1s buffer, 100ns units
            0,
            ref _format,
            IntPtr.Zero);

        var iidCapture = NativeMethods.IID_IAudioCaptureClient;
        _audioClient.GetService(ref iidCapture, out IntPtr captureClientPtr);
        _captureClient = (IAudioCaptureClient)Marshal.GetObjectForIUnknown(captureClientPtr);

        _audioClient.Start();
        _running = true;
        _pumpThread = new Thread(PumpLoop) { IsBackground = true, Name = "LoopbackPump" };
        _pumpThread.Start();
    }

    private static Task<INativeAudioClient> ActivateForProcessAsync(int processId)
    {
        var activationParams = new AUDIOCLIENT_ACTIVATION_PARAMS
        {
            ActivationType = AudioClientActivationType.ProcessLoopback,
            ProcessLoopbackParams = new AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS
            {
                TargetProcessId = (uint)processId,
                ProcessLoopbackMode = ProcessLoopbackMode.IncludeTargetProcessTree,
            },
        };

        IntPtr paramsPtr = Marshal.AllocHGlobal(Marshal.SizeOf<AUDIOCLIENT_ACTIVATION_PARAMS>());
        IntPtr propvariantPtr = Marshal.AllocHGlobal(Marshal.SizeOf<PROPVARIANT_BLOB>());

        try
        {
            Marshal.StructureToPtr(activationParams, paramsPtr, false);

            var propvariant = new PROPVARIANT_BLOB
            {
                vt = NativeMethods.VT_BLOB,
                blobSize = (uint)Marshal.SizeOf<AUDIOCLIENT_ACTIVATION_PARAMS>(),
                blobData = paramsPtr,
            };
            Marshal.StructureToPtr(propvariant, propvariantPtr, false);

            var handler = new ActivationCompletionHandler();
            var riid = NativeMethods.IID_IAudioClient;

            NativeMethods.ActivateAudioInterfaceAsync(
                NativeMethods.VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK,
                ref riid,
                propvariantPtr,
                handler,
                out _);

            // Note: paramsPtr/propvariantPtr must stay alive until the
            // completion callback has fired; the caller awaits Result
            // before this method returns control, but since we free them
            // in a finally block AFTER the await below, that's handled by
            // wrapping this whole thing in an async local function.
            return AwaitAndCleanup(handler, paramsPtr, propvariantPtr);
        }
        catch
        {
            Marshal.FreeHGlobal(paramsPtr);
            Marshal.FreeHGlobal(propvariantPtr);
            throw;
        }

        static async Task<INativeAudioClient> AwaitAndCleanup(
            ActivationCompletionHandler handler, IntPtr p1, IntPtr p2)
        {
            try
            {
                return await handler.Result;
            }
            finally
            {
                Marshal.FreeHGlobal(p1);
                Marshal.FreeHGlobal(p2);
            }
        }
    }

    private void PumpLoop()
    {
        while (_running)
        {
            _captureClient!.GetNextPacketSize(out uint packetSize);
            if (packetSize == 0)
            {
                Thread.Sleep(5);
                continue;
            }

            _captureClient.GetBuffer(
                out IntPtr dataPtr,
                out uint numFrames,
                out uint flags,
                out _,
                out _);

            int byteCount = (int)numFrames * _format.nBlockAlign;
            if (byteCount > 0 && dataPtr != IntPtr.Zero)
            {
                var chunk = new byte[byteCount];
                Marshal.Copy(dataPtr, chunk, 0, byteCount);
                AppendToBuffer(chunk);
            }

            _captureClient.ReleaseBuffer(numFrames);
        }
    }

    private void AppendToBuffer(byte[] chunk)
    {
        lock (_bufferLock)
        {
            int needed = _bufferLen + chunk.Length;
            if (_buffer.Length < needed)
                Array.Resize(ref _buffer, Math.Max(needed, Math.Max(_buffer.Length * 2, FrameBytes * 4)));

            Buffer.BlockCopy(chunk, 0, _buffer, _bufferLen, chunk.Length);
            _bufferLen += chunk.Length;

            int maxBytes = FrameBytes * 50; // ~1s headroom
            if (_bufferLen > maxBytes)
            {
                int drop = _bufferLen - maxBytes;
                Buffer.BlockCopy(_buffer, drop, _buffer, 0, _bufferLen - drop);
                _bufferLen -= drop;
            }
        }
    }

    /// <summary>
    /// Returns exactly FrameBytes of PCM (silence-padded on underrun).
    /// Call this every 20ms to feed Discord's voice stream.
    /// </summary>
    public byte[] ReadFrame()
    {
        lock (_bufferLock)
        {
            if (_bufferLen >= FrameBytes)
            {
                var frame = new byte[FrameBytes];
                Buffer.BlockCopy(_buffer, 0, frame, 0, FrameBytes);
                Buffer.BlockCopy(_buffer, FrameBytes, _buffer, 0, _bufferLen - FrameBytes);
                _bufferLen -= FrameBytes;
                return frame;
            }
        }
        return new byte[FrameBytes]; // silence
    }

    public void Dispose()
    {
        _running = false;
        try { _audioClient?.Stop(); } catch { /* best effort */ }
        _pumpThread?.Join(500);
    }
}