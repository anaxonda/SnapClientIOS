# SnapClientIOS
An iOS client for the excellent [Snapcast](https://github.com/badaix/snapcast), a multiroom client-server audio player. I initially wanted to port the C++ client bits from the original Snapcast code, but I could not get Boost to build in Xcode, so I decided on a clean Objective-C reimplementation instead. Hobby project, right?

Currently a very early work in progress. Streaming works with the FLAC audio codec, but synchronization is not implemented.

## Timing Fix Notes
The client was playing several seconds ahead of snapweb/other clients. The root cause was that server settings were parsed incorrectly: the Snapstream SERVER_SETTINGS payload is a 4-byte length-prefixed JSON blob, but the app attempted to decode the raw payload directly. That caused the JSON parse to fail and left `bufferMs` stuck at its default (1000ms), so playback was effectively scheduled too early when the server buffer was larger (e.g., 3000ms).

Fix applied:
- Parse SERVER_SETTINGS as length-prefixed JSON and update `bufferMs`/`latency` from that payload.

Possible further refinements (if timing or stability regresses):
- Align TIME message handling with the reference clients (latency payload + header field ordering).
- Reconcile buffer/latency math with snapweb/snapclient (`bufferMs = serverBufferMs - clientLatency`) and local audio latency handling.
- Add prebuffering/safety margin and improve AVAudioEngine anchoring/scheduling if needed.
