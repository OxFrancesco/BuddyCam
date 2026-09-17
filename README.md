# BuddyCam

A small SwiftUI app for recording an Android phone camera, alone or with a Mac screen. The phone connects over USB as a webcam, or over the network as an MJPEG stream on Wi-Fi or Tailscale.

Open `~/Applications/BuddyCam.app`. Pick USB or Network at the top.

- USB: connect the phone by cable and select Webcam on the phone. Choose a camera and microphone.
- Network: run an MJPEG server on the phone (IP Webcam's `/video` endpoint, DroidCam, or similar) and enter its URL, for example `http://192.168.1.10:8080/video` or `phone.tailnet.ts.net:8080/video`. The scheme defaults to `http`. Any reachable host works, including Tailscale `100.x` addresses and MagicDNS names.

Choose a microphone, recording mode, format, and destination folder. Start recording, then use Stop and save. Command-R starts and Command-period stops.

- 1:1 saves 1080×1080.
- 9:16 saves 1080×1920.
- 16:9 saves 1920×1080.
- The full camera image stays visible. Different aspect ratios add black borders rather than crop.
- Rotate turns the preview and saved camera video 90 degrees clockwise.
- Screen mode keeps the full selected display visible and places the camera at bottom right.
- Audio comes from the selected microphone. System audio is not captured.
- Settings and the chosen folder persist across launches. Filenames are unique and existing files are never overwritten.

## Network camera

The network source reads `multipart/x-mixed-replace` MJPEG over plain HTTP. Frames are decoded as they arrive, the preview always shows the newest one, and the Link row shows the measured resolution and frame rate. If the connection drops the app reconnects with backoff, so a Wi-Fi or Tailscale stream behaves like an unplugged-and-replugged cable rather than a failed session.

Recording waits for the first decoded frame before it starts. Video is written locally through AVAssetWriter while the microphone records to a separate file; FFmpeg muxes them on stop. Phone-side audio is not captured, so the microphone selection still matters in network mode.

For the closest thing to a cable: keep the phone and Mac on the same Tailscale tailnet or the same LAN, prefer a 5 GHz Wi-Fi link, and use a server that lets you pick resolution and JPEG quality (IP Webcam does both under Video preferences). MJPEG is intra-frame, so latency stays low and a lost frame never smears into the next one.

The USB formats set the output canvas. They do not change the phone's camera mode or the stream's resolution.

AVFoundation records the USB camera and microphone using the same session as the preview. ScreenCaptureKit records the display. After you stop, Homebrew FFmpeg combines the clips and fits them to the selected canvas. Saving may take a moment. macOS camera, microphone, and screen recording permission may be required. The network source needs only outbound HTTP.

## Interface

The UI follows the neo-brutalist system at oddofrancesco.com/design: black background, white borders, coral accent, hard offset shadows, zero radius, Chakra Petch headings, and IBM Plex Mono labels. Both fonts are bundled in the app.

Build with `./scripts/build.sh`. The script uses the existing Developer ID identity. Set `PHONE_RECORDER_SIGNING_IDENTITY=-` for ad-hoc signing on another Mac. Requires macOS 15 or later and FFmpeg at `/opt/homebrew/bin/ffmpeg` or `/usr/local/bin/ffmpeg`.

The black-and-white app icon was generated with the imagegen skill. Its original PNG and ICNS are in `Assets/`.

## Raycast

The local extension in `raycast/` provides Start Recording, Stop Recording, and Open BuddyCam. Start Recording lets you choose the camera source (USB or Network), the stream address for network mode, camera only or screen + camera, the aspect ratio, and a destination folder. Leaving the folder empty uses BuddyCam's saved folder. Camera, microphone, display, and rotation use the app's current settings.

Install BuddyCam in `~/Applications/BuddyCam.app`, then run `bun install` and `bun run dev` from `raycast/`. Search BuddyCam in Raycast. The extension is installed locally and has not been published to the Raycast Store. It sends `buddycam://record`, `buddycam://stop`, and `buddycam://open` commands to the Swift app.

Run `bun run typecheck` and `bun run build` from `raycast/` to validate the extension.
