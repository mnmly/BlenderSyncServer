# BlenderSyncServer

Real-time WebSocket bridge between Blender and a Swift host. The
`bl_camera_sync` Blender addon snapshots the active camera (pose, intrinsics,
optional baked keyframes, raw fcurves) and ships it as JSON; the Swift package
decodes those messages into strongly-typed values and fans them out on an
`AsyncStream`.

Built with Swift NIO and Swift concurrency. macOS-only (NIO transport
services).

## Repo layout

```
Sources/BlenderSyncServer/     Swift package (library)
Tests/BlenderSyncServerTests/  Swift tests
blender-addon/bl_camera_sync/  Blender addon (Python, GPL-2.0-or-later)
debug-server/                  Optional Node WebSocket server for testing
scripts/generate_api_docs.py   Generates API.md from doc comments
API.md                         Generated reference docs
```

## Requirements

- Swift 5.9+, macOS 13+
- Blender 4.2+ (addon target)

## Installation

Swift package — add to `Package.swift`:

```swift
.package(url: "https://github.com/mnmly/BlenderSyncServer.git", from: "0.1.0")
```

Then depend on the `BlenderSyncServer` product.

Blender addon — install `blender-addon/bl_camera_sync/` as a Blender
extension (Edit → Preferences → Add-ons → Install from Disk, pointed at the
folder), or zip the folder and install the archive. On first launch the addon
auto-installs the `websockets` Python package into your user scripts dir.

## Quick start (Swift)

```swift
import BlenderSyncServer
import Logging

let server = BlenderSyncServer(host: "127.0.0.1", port: 8765)
try await server.start()

for await message in await server.messages() {
    switch message {
    case .cameraSnapshot(let cam):
        print("frame \(cam.frame): \(cam.location), focal \(cam.focalLength)mm")
    case .cameraCurves(let curves):
        let sample = curves.sample(at: 42.0)
        print("interpolated at frame 42: \(sample.location)")
    case .sceneInfo(let scene):
        print("render \(scene.resolutionWidth)×\(scene.resolutionHeight) @ \(scene.frameRate)fps")
    case .unknown(let type):
        print("unknown message type: \(type)")
    }
}
```

A late subscriber can prime itself from the last seen values:

```swift
let state = await server.latestState()
if let cam = state.cameraSnapshot { /* ... */ }
```

## Wire protocol

All messages share the envelope:

```json
{ "type": "<snake_case>", "payload": { ... }, "timestamp": 1735689600.0 }
```

| `type`          | Swift case                          | Source                  |
|-----------------|-------------------------------------|-------------------------|
| `camera_update` | `BlenderMessage.cameraSnapshot`     | `snapshot_camera()`     |
| `camera_curves` | `BlenderMessage.cameraCurves`       | `snapshot_camera_curves()` |
| `scene_update`  | `BlenderMessage.sceneInfo`          | `snapshot_scene()`      |

Unknown types decode as `.unknown(type:)` so the server is forward-compatible
with future addon additions.

See [API.md](./API.md) for the full reference, generated from source doc
comments.

## Architecture

- **`BlenderSyncServer`** — actor that hosts the WebSocket, decodes messages,
  caches the latest of each kind, and fans out to multiple `AsyncStream`
  subscribers with newest-buffering (slow consumers drop old frames rather
  than backing up the pipeline).
- **`WebSocketServer<Incoming, Outgoing>`** — generic Swift NIO WebSocket
  actor. Reusable for other protocols.
- **`CameraCurves`** — faithful port of Blender's `evaluate_fcurve` and the
  Robert Penner easing set, so the host can resample camera animation
  off-thread without Blender running. Parent transforms, constraints, and
  drivers are NOT honored by fcurve evaluation — use the `bakedKeyframes` on
  `CameraSnapshot` for those.

## Testing

```bash
swift test
```

The `debug-server/` directory contains a Node WebSocket server useful for
poking at the addon without involving the Swift side:

```bash
cd debug-server && npm install && npm start
```

## Regenerating API docs

`API.md` is generated from `///` Swift doc comments and Python docstrings:

```bash
python3 scripts/generate_api_docs.py
```

No external dependencies. Edit the source comments, not `API.md`.

## License

- Swift package (`Sources/`, `Tests/`): **MIT** — see [LICENSE](./LICENSE).
- Blender addon (`blender-addon/bl_camera_sync/`): **GPL-2.0-or-later** —
  required because Blender addons link `bpy`. See
  [`blender-addon/bl_camera_sync/LICENSE`](./blender-addon/bl_camera_sync/LICENSE).
- `debug-server/`: dev tool, MIT (matches the Swift package).
