# SnapClientIOS
An iOS client for the excellent [Snapcast](https://github.com/badaix/snapcast), a multiroom client-server audio player. I initially wanted to port the C++ client bits from the original Snapcast code, but I could not get Boost to build in Xcode, so I decided on a clean Objective-C reimplementation instead. Hobby project, right?

Currently a very early work in progress. Streaming works with the FLAC audio codec, but synchronization is not implemented.

## Timing Fix Notes (Current State)
At the start of this work the client played several seconds ahead of snapweb/other clients. The main root cause was incorrect parsing of SERVER_SETTINGS: the Snapstream payload is a 4-byte length-prefixed JSON blob, but the app attempted to decode the raw payload directly. That failed and left `bufferMs` at its default (1000ms), so playback was scheduled too early when the server buffer was larger (e.g., 3000ms).

Changes applied in this session:
- SERVER_SETTINGS parsing now supports length-prefixed JSON, so `bufferMs` and `latency` are populated correctly from the server.
- FLAC decoder input buffer increased to 256 KB and a throttled drop counter was added to detect circular buffer overflows.
- AudioRenderer now logs immediate-schedule fallbacks (late/future/zero targets) to diagnose underruns.
- AVAudioSession is configured with the stream sample rate and a 40 ms preferred IO buffer duration; actual session values are logged at startup.

Outcome:
- Timing now matches snapweb, and stutter frequency is reduced on device.

Possible future refinements (if timing or stability regresses):
- Align TIME message handling with reference clients (latency payload + header field ordering) for tighter clock sync.
- Reconcile buffer/latency math with snapweb/snapclient (`bufferMs = serverBufferMs - clientLatency`) and local audio latency handling.
- Add prebuffering/minimum queue depth or a schedule-ahead guard to absorb network jitter.
