import XCTest
import Foundation
import Logging
import simd
@testable import BlenderSyncServer

final class BlenderSyncServerTests: XCTestCase {

    // MARK: - BlenderMessage Codable

    func testCameraSnapshotRoundTrip() throws {
        // Identity matrix as 16 row-major doubles.
        let identityRow: [Double] = [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        ]
        let json = """
        {
          "type": "camera_update",
          "timestamp": 12345.0,
          "payload": {
            "name": "Camera",
            "location": [1.0, 2.0, 3.0],
            "rotation": [0.0, 0.0, 0.0],
            "quaternion": [1.0, 0.0, 0.0, 0.0],
            "scale": [1.0, 1.0, 1.0],
            "matrix_world": \(identityRow),
            "focal_length": 50.0,
            "sensor_width": 36.0,
            "sensor_height": 24.0,
            "vertical_fov": 27.0,
            "render_aspect": 1.777,
            "render_width": 1920,
            "render_height": 1080,
            "clip_start": 0.1,
            "clip_end": 1000.0,
            "frame": 42,
            "baked_keyframes": []
          }
        }
        """

        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        let msg = try dec.decode(BlenderMessage.self, from: Data(json.utf8))

        guard case .cameraSnapshot(let snap) = msg else {
            return XCTFail("expected .cameraSnapshot, got \(msg)")
        }
        XCTAssertEqual(snap.name, "Camera")
        XCTAssertEqual(snap.frame, 42)
        XCTAssertEqual(snap.focalLength, 50.0)
        XCTAssertEqual(snap.matrixWorld, matrix_identity_double4x4)
    }

    func testUnknownTypeIsSurfaced() throws {
        let json = #"{"type":"future_thing","timestamp":0,"payload":{}}"#
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        let msg = try dec.decode(BlenderMessage.self, from: Data(json.utf8))
        guard case .unknown(let t) = msg else {
            return XCTFail("expected .unknown, got \(msg)")
        }
        XCTAssertEqual(t, "future_thing")
    }

    // MARK: - CameraCurves.sample(at:)

    func testSampleFallsBackToStaticWhenNoFcurves() {
        let staticVals = CameraStatic(
            matrixWorld: Array(repeating: 0.0, count: 16),  // unused here
            location: [10, 20, 30],
            rotationEuler: [0, 0, 0],
            scale: [2, 2, 2],
            focalLength: 35,
            sensorWidth: 36,
            sensorHeight: 24,
            sensorFit: "AUTO",
            clipStart: 0.1,
            clipEnd: 100,
            verticalFov: 0
        )
        let curves = CameraCurves(
            name: "Camera", frameStart: 1, frameEnd: 10, fps: 24,
            renderWidth: 1920, renderHeight: 1080, renderAspect: 16.0/9.0,
            static: staticVals, fcurves: []
        )
        let s = curves.sample(at: 5)
        XCTAssertEqual(s.location, SIMD3(10, 20, 30))
        XCTAssertEqual(s.scale, SIMD3(2, 2, 2))
        XCTAssertEqual(s.focalLength, 35)
        // Translation column should be (10, 20, 30).
        XCTAssertEqual(s.matrixWorld[3], SIMD4(10, 20, 30, 1))
        // Scale columns x/y/z norms = 2.
        XCTAssertEqual(simd_length(SIMD3(s.matrixWorld[0].x, s.matrixWorld[0].y, s.matrixWorld[0].z)), 2, accuracy: 1e-12)
    }

    func testSampleOverridesWithLinearFcurve() {
        let kfs: [Keyframe] = [
            Keyframe(frame: 0, value: 0, interpolation: .linear, easing: .auto,
                     handleLeft: [-1, 0], handleRight: [1, 0]),
            Keyframe(frame: 10, value: 100, interpolation: .linear, easing: .auto,
                     handleLeft: [9, 100], handleRight: [11, 100]),
        ]
        let fc = FCurve(source: "object", dataPath: "location", arrayIndex: 0,
                        extrapolation: .constant, hasModifiers: false, keyframes: kfs)
        let staticVals = CameraStatic(
            matrixWorld: Array(repeating: 0.0, count: 16),
            location: [999, 0, 0],     // would be wrong if fcurve is ignored
            rotationEuler: [0, 0, 0],
            scale: [1, 1, 1],
            focalLength: 50, sensorWidth: 36, sensorHeight: 24,
            sensorFit: "AUTO", clipStart: 0.1, clipEnd: 100, verticalFov: 0
        )
        let curves = CameraCurves(
            name: "Camera", frameStart: 0, frameEnd: 10, fps: 24,
            renderWidth: 1920, renderHeight: 1080, renderAspect: 16.0/9.0,
            static: staticVals, fcurves: [fc]
        )
        let s = curves.sample(at: 5)
        XCTAssertEqual(s.location.x, 50, accuracy: 1e-9)
        XCTAssertEqual(s.location.y, 0)
    }

    // MARK: - Server smoke

    func testServerInitDoesNotStart() async {
        let server = BlenderSyncServer(host: "127.0.0.1", port: 8765)
        let state = await server.latestState()
        XCTAssertNil(state.cameraSnapshot)
        XCTAssertNil(state.cameraCurves)
        XCTAssertNil(state.sceneInfo)
    }
}
