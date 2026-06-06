import XCTest
import Foundation
import simd
@testable import BlenderSyncServer

/// Decodes the golden fixtures produced by `tools/blender_fixtures/gen_fixtures.py`
/// (run against a real Blender runtime) through the production ``ObjectGraph``
/// DTOs. This proves the Swift wire schema matches exactly what the shipped
/// addon exporter emits — no drift between producer and consumer.
///
/// Regenerate fixtures:
///   "$WABF_BLENDER" --background --factory-startup \
///       --python tools/blender_fixtures/gen_fixtures.py
///
/// The `golden` per-frame matrices are carried through for the future
/// WABFCoreKit `TransformGraph` evaluator comparison; this target only asserts
/// they decode and are well-formed.
final class ObjectGraphFixtureTests: XCTestCase {

    struct GoldenSample: Codable {
        let frame: Int
        let object: String
        let matrixWorld: [Double]
    }
    struct Fixture: Codable {
        let scene: String
        let wire: ObjectGraph
        let golden: [GoldenSample]
    }

    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    private func loadFixtures() throws -> [Fixture] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: fixturesDir,
                                                      includingPropertiesForKeys: nil) else {
            return []
        }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try dec.decode(Fixture.self, from: Data(contentsOf: $0)) }
    }

    func testFixturesPresent() throws {
        let fixtures = try loadFixtures()
        XCTAssertFalse(fixtures.isEmpty,
                       "No fixtures found in \(fixturesDir.path). Run gen_fixtures.py.")
    }

    /// Every fixture decodes and is internally consistent.
    func testAllFixturesDecode() throws {
        let fixtures = try loadFixtures()
        try XCTSkipIf(fixtures.isEmpty, "fixtures not generated")

        for fx in fixtures {
            XCTAssertFalse(fx.wire.objects.isEmpty, "\(fx.scene): no objects")
            XCTAssertLessThanOrEqual(fx.wire.frameStart, fx.wire.frameEnd, fx.scene)

            for o in fx.wire.objects {
                XCTAssertEqual(o.parentInverse.count, 16, "\(fx.scene)/\(o.name) parentInverse")
                XCTAssertEqual(o.base.matrixWorld.count, 16, "\(fx.scene)/\(o.name) base.matrixWorld")
                XCTAssertEqual(o.base.rotationQuaternion.count, 4)
                XCTAssertEqual(o.base.rotationAxisAngle.count, 4)

                // needs_bake objects must carry a usable baked track.
                if o.needsBake {
                    let baked = try XCTUnwrap(o.baked, "\(fx.scene)/\(o.name) baked missing")
                    XCTAssertFalse(baked.frames.isEmpty)
                    for f in baked.frames {
                        XCTAssertEqual(f.matrixWorld.count, 16)
                    }
                }
                // No constraint should decode as `.unsupported` for the types we export.
                for c in o.constraints {
                    XCTAssertNotEqual(c.type, .unsupported,
                                      "\(fx.scene)/\(o.name) constraint decoded as unsupported")
                }
            }

            // Golden samples cover the frame range for every object.
            let expected = (fx.wire.frameEnd - fx.wire.frameStart + 1) * fx.wire.objects.count
            XCTAssertEqual(fx.golden.count, expected, "\(fx.scene) golden sample count")
        }
    }

    /// Rotation modes round-trip (none fall back to a default).
    func testEulerOrdersDecode() throws {
        let fixtures = try loadFixtures()
        guard let fx = fixtures.first(where: { $0.scene == "euler_orders" }) else {
            throw XCTSkip("euler_orders fixture missing")
        }
        let modes = Set(fx.wire.objects.map { $0.rotationMode })
        XCTAssertTrue(modes.isSuperset(of: [.xyz, .xzy, .yxz, .yzx, .zxy, .zyx]),
                      "missing euler orders: \(modes)")
        // Each cube animates location/rotation/scale → 9 transform fcurves.
        for o in fx.wire.objects {
            XCTAssertNotNil(o.fcurve(dataPath: "location", arrayIndex: 0))
            XCTAssertNotNil(o.fcurve(dataPath: "rotation_euler", arrayIndex: 2))
            XCTAssertNotNil(o.fcurve(dataPath: "scale", arrayIndex: 1))
        }
    }

    func testQuaternionAndAxisAngleDecode() throws {
        let fixtures = try loadFixtures()
        guard let fx = fixtures.first(where: { $0.scene == "quat_axisangle" }) else {
            throw XCTSkip("quat_axisangle fixture missing")
        }
        let q = try XCTUnwrap(fx.wire.object(id: "Cube_Quat"))
        XCTAssertEqual(q.rotationMode, .quaternion)
        XCTAssertNotNil(q.fcurve(dataPath: "rotation_quaternion", arrayIndex: 0))
        let a = try XCTUnwrap(fx.wire.object(id: "Cube_Axis"))
        XCTAssertEqual(a.rotationMode, .axisAngle)
        XCTAssertNotNil(a.fcurve(dataPath: "rotation_axis_angle", arrayIndex: 0))
    }

    /// Parent links + OBJECT parenting (the natively-evaluated path) decode.
    func testParentChainDecodes() throws {
        let fixtures = try loadFixtures()
        guard let fx = fixtures.first(where: { $0.scene == "parent_chain" }) else {
            throw XCTSkip("parent_chain fixture missing")
        }
        let child = try XCTUnwrap(fx.wire.object(id: "Child"))
        XCTAssertEqual(child.parent, "Root")
        XCTAssertEqual(child.parentType, "OBJECT")
        XCTAssertFalse(child.needsBake, "OBJECT-parented keyed object should not need bake")
        let grand = try XCTUnwrap(fx.wire.object(id: "Grandchild"))
        XCTAssertEqual(grand.parent, "Child")
    }

    /// Track To constraint + its params decode, and the owner is baked.
    func testTrackToConstraintDecodes() throws {
        let fixtures = try loadFixtures()
        guard let fx = fixtures.first(where: { $0.scene == "track_to" }) else {
            throw XCTSkip("track_to fixture missing")
        }
        let tracker = try XCTUnwrap(fx.wire.object(id: "Tracker"))
        let con = try XCTUnwrap(tracker.constraints.first)
        XCTAssertEqual(con.type, .trackTo)
        XCTAssertEqual(con.target, "Target")
        XCTAssertEqual(con.params.trackAxis, "TRACK_NEGATIVE_Z")
        XCTAssertEqual(con.params.upAxis, "UP_Y")
        // Track To is now solved natively by the Core engine → not baked.
        XCTAssertFalse(tracker.needsBake)
        XCTAssertNil(tracker.baked)
    }

    /// Driver objects are flagged for bake and carry a track.
    func testDriverObjectBaked() throws {
        let fixtures = try loadFixtures()
        guard let fx = fixtures.first(where: { $0.scene == "driver" }) else {
            throw XCTSkip("driver fixture missing")
        }
        let driven = try XCTUnwrap(fx.wire.object(id: "Driven"))
        XCTAssertTrue(driven.needsBake)
        XCTAssertEqual(driven.baked?.frames.count, fx.wire.frameEnd - fx.wire.frameStart + 1)
    }

    /// The full envelope decodes via `BlenderMessage` (the production path).
    func testObjectGraphEnvelopeDecodes() throws {
        let fixtures = try loadFixtures()
        try XCTSkipIf(fixtures.isEmpty, "fixtures not generated")
        let fx = fixtures[0]

        // Re-wrap the wire payload in the message envelope and decode it the way
        // the server does.
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        let payload = try enc.encode(fx.wire)
        let payloadObj = try JSONSerialization.jsonObject(with: payload)
        let envelope: [String: Any] = ["type": "object_graph",
                                       "timestamp": 0.0,
                                       "payload": payloadObj]
        let data = try JSONSerialization.data(withJSONObject: envelope)

        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        let msg = try dec.decode(BlenderMessage.self, from: data)
        guard case .objectGraph(let g) = msg else {
            return XCTFail("expected .objectGraph, got \(msg.typeString)")
        }
        XCTAssertEqual(g.objects.count, fx.wire.objects.count)
    }

    // MARK: - Curve geometry

    /// A CURVE data-block decodes from the addon's snake_case wire form, with
    /// BEZIER and NURBS splines split into their respective point arrays.
    func testCurveGeometryDecodes() throws {
        let json = """
        {
          "dimensions": "3D",
          "resolution_u": 12,
          "use_path": true,
          "path_duration": 100,
          "eval_time": 25.0,
          "bevel_depth": 0.0,
          "extrude": 0.0,
          "splines": [
            {
              "type": "BEZIER",
              "use_cyclic_u": false, "resolution_u": 12, "order_u": 4,
              "use_endpoint_u": true, "use_bezier_u": false,
              "bezier_points": [
                {"co":[0,0,0],"handle_left":[-1,0,0],"handle_right":[1,0,0],
                 "handle_left_type":"ALIGNED","handle_right_type":"ALIGNED","tilt":0.0,"radius":1.0},
                {"co":[2,0,0],"handle_left":[1,0,0],"handle_right":[3,0,0],
                 "handle_left_type":"ALIGNED","handle_right_type":"ALIGNED","tilt":0.0,"radius":1.0}
              ]
            },
            {
              "type": "NURBS",
              "use_cyclic_u": false, "resolution_u": 12, "order_u": 3,
              "use_endpoint_u": true, "use_bezier_u": false,
              "points": [
                {"co":[0,0,0,1],"tilt":0.0,"radius":1.0,"weight":1.0},
                {"co":[1,2,0,2],"tilt":0.0,"radius":1.0,"weight":2.0},
                {"co":[3,0,0,1],"tilt":0.0,"radius":1.0,"weight":1.0}
              ]
            }
          ],
          "fcurves": []
        }
        """
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        let curve = try dec.decode(BlenderCurve.self, from: Data(json.utf8))

        XCTAssertEqual(curve.dimensions, "3D")
        XCTAssertEqual(curve.pathDuration, 100)
        XCTAssertEqual(curve.evalTime, 25.0, accuracy: 1e-9)
        XCTAssertEqual(curve.splines.count, 2)

        let bez = curve.splines[0]
        XCTAssertEqual(bez.type, "BEZIER")
        XCTAssertNil(bez.points)
        let bp = try XCTUnwrap(bez.bezierPoints)
        XCTAssertEqual(bp.count, 2)
        XCTAssertEqual(bp[0].handleRight, [1, 0, 0])
        XCTAssertEqual(bp[0].handleLeftType, "ALIGNED")

        let nurbs = curve.splines[1]
        XCTAssertEqual(nurbs.type, "NURBS")
        XCTAssertEqual(nurbs.orderU, 3)
        XCTAssertTrue(nurbs.useEndpointU)
        XCTAssertNil(nurbs.bezierPoints)
        let pts = try XCTUnwrap(nurbs.points)
        XCTAssertEqual(pts.count, 3)
        XCTAssertEqual(pts[1].weight, 2.0, accuracy: 1e-9)        // rational weight preserved
        XCTAssertEqual(pts[1].position, [1, 2, 0])               // 4-D co → 3-D position

        // No eval_time f-curve → static eval_time.
        XCTAssertEqual(curve.evaluatedEvalTime(atFrame: 50), 25.0, accuracy: 1e-9)
    }

    /// `evaluatedEvalTime` follows the animated `eval_time` f-curve when keyed,
    /// and falls back to the static value otherwise.
    func testCurveEvalTimeFollowsFcurve() {
        let kf = Keyframe(frame: 10, value: 4.0, interpolation: .linear, easing: .auto,
                          handleLeft: [9, 4], handleRight: [11, 4])
        let fc = FCurve(source: "data", dataPath: "eval_time", arrayIndex: 0,
                        extrapolation: .constant, hasModifiers: false, keyframes: [kf])
        let keyed = BlenderCurve(dimensions: "3D", resolutionU: 12, usePath: true,
                                 pathDuration: 100, evalTime: 25, bevelDepth: 0, extrude: 0,
                                 splines: [], fcurves: [fc])
        // At the keyframe frame the f-curve wins over the static value.
        XCTAssertEqual(keyed.evaluatedEvalTime(atFrame: 10), 4.0, accuracy: 1e-9)

        let unkeyed = BlenderCurve(dimensions: "3D", resolutionU: 12, usePath: true,
                                   pathDuration: 100, evalTime: 25, bevelDepth: 0, extrude: 0,
                                   splines: [], fcurves: [])
        XCTAssertEqual(unkeyed.evaluatedEvalTime(atFrame: 10), 25.0, accuracy: 1e-9)
    }
}
