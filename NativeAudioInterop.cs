// Native COM interop for the Windows WASAPI "process loopback" API.
// This lets us capture audio from ONE specific process (e.g. Spotify.exe)
// regardless of which output device it's actually playing through, with
// no virtual audio cable or other third-party software.
//
// Requires Windows 10 build 19041 (2004) or later / Windows 11.
//
// Reference: audioclientactivationparams.h, mmdeviceapi.h, audioclient.h
// (Microsoft's own "ApplicationLoopback" C++ sample uses this same API.)

using System;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

namespace SpotifyDiscordBot;

#region Structs

[StructLayout(LayoutKind.Sequential)]
internal struct WAVEFORMATEX
{
    public ushort wFormatTag;
    public ushort nChannels;
    public uint nSamplesPerSec;
    public uint nAvgBytesPerSec;
    public ushort nBlockAlign;
    public ushort wBitsPerSample;
    public ushort cbSize;
}

internal enum ProcessLoopbackMode : int
{
    IncludeTargetProcessTree = 0,
    ExcludeTargetProcessTree = 1,
}

internal enum AudioClientActivationType : int
{
    Default = 0,
    ProcessLoopback = 1,
}

[StructLayout(LayoutKind.Sequential)]
internal struct AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS
{
    public uint TargetProcessId;
    public ProcessLoopbackMode ProcessLoopbackMode;
}

// Mirrors the C union { ProcessLoopbackParams } inside
// AUDIOCLIENT_ACTIVATION_PARAMS. Since there's currently only one union
// member we care about, sequential layout with the activation type first
// is equivalent to the C struct.
[StructLayout(LayoutKind.Sequential)]
internal struct AUDIOCLIENT_ACTIVATION_PARAMS
{
    public AudioClientActivationType ActivationType;
    public AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS ProcessLoopbackParams;
}

// PROPVARIANT, restricted to the VT_BLOB shape we actually need.
// Header is 8 bytes (vt + 3 reserved WORDs); the blob union follows,
// naturally aligned to 8 bytes for the pointer on x64.
[StructLayout(LayoutKind.Sequential)]
internal struct PROPVARIANT_BLOB
{
    public ushort vt;
    public ushort wReserved1;
    public ushort wReserved2;
    public ushort wReserved3;
    public uint blobSize;
    public IntPtr blobData;
}

#endregion

#region COM interfaces

[ComImport]
[Guid("72A22D78-CDE4-431D-B8CC-843A71199B6D")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IActivateAudioInterfaceAsyncOperation
{
    void GetActivateResult(
        out int activateResult,
        [MarshalAs(UnmanagedType.IUnknown)] out object activatedInterface);
}

[ComImport]
[Guid("41D949AB-9862-444A-80F6-C261334DA5EB")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IActivateAudioInterfaceCompletionHandler
{
    void ActivateCompleted(IActivateAudioInterfaceAsyncOperation activateOperation);
}

[ComImport]
[Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface INativeAudioClient
{
    void Initialize(
        int shareMode,
        uint streamFlags,
        long bufferDuration,
        long periodicity,
        ref WAVEFORMATEX format,
        IntPtr audioSessionGuid);

    void GetBufferSize(out uint numBufferFrames);
    void GetStreamLatency(out long latency);
    void GetCurrentPadding(out uint numPaddingFrames);
    void IsFormatSupported(int shareMode, ref WAVEFORMATEX format, out IntPtr closestMatch);
    void GetMixFormat(out IntPtr deviceFormat);
    void GetDevicePeriod(out long defaultDevicePeriod, out long minimumDevicePeriod);
    void Start();
    void Stop();
    void Reset();
    void SetEventHandle(IntPtr eventHandle);
    void GetService(ref Guid riid, out IntPtr ppv);
}

[ComImport]
[Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioCaptureClient
{
    void GetBuffer(
        out IntPtr dataPtr,
        out uint numFramesToRead,
        out uint flags,
        out ulong devicePosition,
        out ulong qpcPosition);

    void ReleaseBuffer(uint numFramesRead);
    void GetNextPacketSize(out uint numFramesInNextPacket);
}

#endregion

/// <summary>
/// Receives the async result of ActivateAudioInterfaceAsync on a COM
/// worker thread and hands it back via a TaskCompletionSource.
/// </summary>
[ComVisible(true)]
internal sealed class ActivationCompletionHandler : IActivateAudioInterfaceCompletionHandler
{
    private readonly TaskCompletionSource<INativeAudioClient> _tcs =
        new(TaskCreationOptions.RunContinuationsAsynchronously);

    public Task<INativeAudioClient> Result => _tcs.Task;

    public void ActivateCompleted(IActivateAudioInterfaceAsyncOperation activateOperation)
    {
        try
        {
            activateOperation.GetActivateResult(out int hr, out object iface);
            if (hr != 0)
            {
                _tcs.TrySetException(Marshal.GetExceptionForHR(hr) ?? new COMException("Activation failed", hr));
                return;
            }
            _tcs.TrySetResult((INativeAudioClient)iface);
        }
        catch (Exception ex)
        {
            _tcs.TrySetException(ex);
        }
    }
}

internal static class NativeMethods
{
    // Well-known device interface path for process-loopback activation.
    public const string VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK = "VAD\\Process_Loopback";

    public const int AUDCLNT_SHAREMODE_SHARED = 0;
    public const uint AUDCLNT_STREAMFLAGS_LOOPBACK = 0x00020000;
    public const ushort VT_BLOB = 65;

    public static readonly Guid IID_IAudioClient = typeof(INativeAudioClient).GUID;
    public static readonly Guid IID_IAudioCaptureClient = typeof(IAudioCaptureClient).GUID;

    [DllImport("Mmdevapi.dll", ExactSpelling = true, PreserveSig = false)]
    public static extern void ActivateAudioInterfaceAsync(
        [MarshalAs(UnmanagedType.LPWStr)] string deviceInterfacePath,
        ref Guid riid,
        IntPtr activationParams, // PROPVARIANT*
        IActivateAudioInterfaceCompletionHandler completionHandler,
        out IActivateAudioInterfaceAsyncOperation activationOperation);
}