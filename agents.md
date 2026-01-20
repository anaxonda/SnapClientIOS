# SnapClientIOS Technical Architecture & Sync Analysis

## 1. System Overview
SnapClientIOS is a legacy Objective-C client for the Snapcast multi-room audio system, modernized to run on **iOS 12.0+** (specifically tested on iPad Air 1). It is built using a custom GitHub Actions pipeline that generates **unsigned IPAs** for deployment via tools like **Legacy-iOS-Kit**.

### Core Components
*   **SocketHandler (Port 1704)**: Manages the binary Snapstream protocol. It handles the initial handshake (Hello), parses server settings, processes time-synchronization pings, and extracts FLAC audio chunks and metadata (StreamTags).
*   **RpcHandler (Port 1705)**: Manages the JSON-RPC Control protocol. It allows the app to fetch server status, discover available streams, and change the source for the client's group.
*   **TimeProvider**: A monotonic clock synchronization engine. It calculates the offset between the server's clock and the iPad's `mach_absolute_time` using an NTP-style median filter (100-sample window).
*   **FlacDecoder**: A wrapper around `libFLAC` that decodes 16-bit interleaved audio chunks into Float32 non-interleaved PCM.
*   **AudioRenderer**: Built on `AVAudioEngine`. It uses an `AVAudioPlayerNode` to schedule decoded buffers at precise `AVAudioTime` (hostTime) points.

---

## 2. Synchronization Logic (Current Implementation)
The app calculates the target playback time for every audio chunk using the following formula:
`TargetMachTime = (ServerChunkTimestamp + ServerBufferMs + ServerLatency) - ClientClockOffset - HardwareDelay`

*   **ServerChunkTimestamp**: The 64-bit timestamp extracted from the `WIRE_CHUNK` message.
*   **ServerBufferMs**: The global buffer configured on the Snapserver (e.g., 3000ms).
*   **ClientClockOffset**: The calculated difference between the server's Unix clock and the local Mach clock.
*   **HardwareDelay**: The dynamic value from `AVAudioSession.outputLatency` (approx. 20-40ms).

---

## 2.1 Snapcast Time Sync Ground Truth (snapclient/snapserver)
Snapclient and snapserver use a monotonic/steady clock for all stream timestamps and time sync. The binary header order and time sync math are:
*   **Header layout**: bytes 6..13 = `sent` (sender time), bytes 14..21 = `received` (receiver time). This is the authoritative layout in `snapcast/common/message/message.hpp`.
*   **Client request**: snapclient sets `sent = tv()` right before serialization (steady clock).
*   **Server receive**: snapserver overwrites `received = tv()` when the request body is read.
*   **Time response payload**: `latency = received - sent` (server side).
*   **Client diff**: `diff = (c2s - s2c) / 2`, where `c2s = payload latency` and `s2c = client_recv - server_sent`.
*   **Note**: snapweb swaps `sent`/`received` when parsing; use snapcast source as the protocol authority.

---

## 3. Why Timing Fails (The "Ahead of Others" Problem)
Despite the math being theoretically sound, the app consistently plays **several seconds ahead** of other synchronized clients (Android, Web).

### Suspected Root Causes
1.  **Timeline Anchor Mismatch**: Snapcast servers often use a "Stream Start Time" or a specific monotonic reference for audio chunks that differs from the "System Time" returned in the `TIME` message header. If we sync to the wrong server clock, our `ClientClockOffset` is essentially garbage.
2.  **AVAudioEngine Scheduling Interpretation**: We schedule using `hostTime` (Mach absolute time). If the `AVAudioPlayerNode` has not been correctly "anchored" to the engine's timeline, it may treat future timestamps as "immediate" if they exceed a certain threshold, or it may interpret the hostTime starting from the moment `node play` was called.
3.  **The "Snapweb" Discrepancy**: Preliminary analysis of the Web Client suggests it does not add `bufferMs` to the target time in the same way. It relies on the browser's `AudioContext` timeline which might be implicitly delayed or managed differently.
4.  **Packet Buffer Overflow**: If chunks arrive faster than they are scheduled, and the `AVAudioPlayerNode` buffer queue grows too large, the OS may attempt to "flush" or play through them to recover, causing the "leader" effect.

---

## 4. Sync Investigation Log
Current HEAD: see `git rev-parse --short HEAD` (latest re-anchor + DAC logging)

Crash cluster (post `b855421`):
- `cf34ee5`, `bc23e38`, `4f89a0b`, `2702439` socket read queue refactor; reverted in `19b08b4`

Tried (commit -> summary):
- `b855421` snapclient-style sync + drift correction (AudioRenderer/TimeProvider/SocketHandler/ClientSession)
- `f53f6ba` TIME payload for clock sync (SocketHandler/TimeProvider)
- `4413e34` monotonic timebase + quick sync (TimeProvider/ClientSession)
- `76d2005` queue-based DAC estimate + local latency subtraction (AudioRenderer)
- `cb2ff38` IO buffer duration in playback buffer; dropped queue-based DAC; cadence 20ms (AudioRenderer)
- `03822d1` restore queue-based DAC estimate like snapclient; remove local latency subtraction (AudioRenderer)
- `e57d6a7` cadence 40ms (AudioRenderer)
- `659a789` remove IO buffer term from DAC estimate (AudioRenderer)
- `028d398`, `4404acc`, `7a557ba` interruption/resume handling + time sync gating (AudioRenderer/ClientSession/TimeProvider)
- `65bb165` off-main sync timers + sync logging (ClientSession)
- `9ef41cc` log sync stats for drift diagnosis (AudioRenderer)
- `5acde08` log DAC estimate details (AudioRenderer)
- `d0057ba` re-anchor DAC queue estimate when behind/periodically (AudioRenderer)

Snapclient parity notes:
- Uses steady timer for TIME sync; median offset smoothing; baseline drift correction thresholds
- Uses per-callback output latency in players (e.g., Oboe/ALSA/Pipewire)
- No explicit TIME vs WIRE_CHUNK timebase validation; no sample-time re-anchoring
Architecture note:
- Snapclient pulls audio per callback and measures output latency from the backend timestamp.
- This client schedules buffers ahead of time and infers queue depth from `nextPlayTimeMs`/`nextPlaySampleTime`, so stale estimates can drift unless re-anchored.

Completed checklist:
- [x] Move sync timers off main runloop (dispatch_source_t on dedicated queue) (`65bb165`)
- [x] Re-anchor `nextPlaySampleTime` when behind and periodically (`d0057ba`)

Next experiments (untried):
- [ ] Validate TIME vs WIRE_CHUNK timebase alignment; add targeted logging for `serverNowMs`, `chunk.startMs`, `ageMs`, `outputBufferDacTimeMs`
- [ ] Add skew/clock-rate estimation or reduce median window in `TimeProvider`
- [ ] Measure output latency per callback (AVAudioTime/AudioUnit) to align with snapclient
- [ ] Add drift watchdog or more aggressive correction thresholds

## 5. Agent Roles
*   **@BuildMaster**: Manages the `macos-14` CI environment, ensuring `CODE_SIGNING_ALLOWED=NO` and manual IPA packaging remains functional.
*   **@ObjC_Dev**: Handles the migration from `AudioQueue` to `AVAudioEngine` and the manual Int16 -> Float32 conversion logic.
*   **@Guide**: Architectures the synchronization math and reverse-engineers the Snapcast protocol variations.

---

## 6. Build & Download Workflow
Since the app is built on GitHub Actions (macOS runner) but managed from Linux, use the following sequence to build and retrieve the IPA:

### 1. Trigger Build
Commit and push your changes to trigger the GitHub Actions workflow:
```bash
git add .
git commit -m "Your description"
git push
```

### 2. Monitor Run
Find the ID of the latest run and wait for it to complete:
```bash
# List latest run to get the ID
gh run list --limit 1 --workflow build.yml

# Watch the run until it finishes (replace <RUN_ID> with the ID from above)
gh run view <RUN_ID> --exit-status
```

### 3. Download IPA
Once successful, download the built artifact into the current project directory:
```bash
# Rename old IPA if it exists to avoid extraction conflicts
mv SnapClientIOS.ipa SnapClientIOS.ipa.old

# Download the new build
gh run download <RUN_ID> -n SnapClientIOS-Unsigned --dir .
```

The resulting `SnapClientIOS.ipa` is now ready for installation via **Legacy-iOS-Kit**.

---

## 7. Rollback Notes
- If we need to revert the local prebuffer/queue guard experiment, roll back to commit `d81fbd6` (the last build before `3b071d5`).
