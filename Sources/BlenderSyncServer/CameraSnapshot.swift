/// Live per-frame camera state sent by the Blender addon as `camera_update`.
///
/// Mirrors the dict produced by `snapshot_camera()` in the addon. Snake-case
/// wire fields are mapped to camelCase via
/// `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase`, configured by
/// ``BlenderSyncServer``.

import Foundation
import simd

/// One frame of evaluated camera state from Blender.
///
/// Includes pose (location/rotation/scale + world matrix), intrinsics
/// (focal length, sensor, FOV, clip), render dimensions, the current frame,
/// and an optional sequence of pre-baked world matrices over the timeline.
public struct CameraSnapshot: Sendable, Codable {
    /// Blender object name (`bpy.types.Object.name`).
    public let name: String
    /// World-space camera location in Blender units (meters by default).
    public let location: SIMD3<Double>
    /// Euler rotation in radians, XYZ order — Blender's default `rotation_mode`.
    public let rotationEuler: SIMD3<Double>
    /// Quaternion in `(w, x, y, z)` order — matches Blender's `mathutils.Quaternion`.
    public let quaternion: SIMD4<Double>
    /// Per-axis scale factor.
    public let scale: SIMD3<Double>

    /// Evaluated world matrix — composed from the wire's 16-float row-major array
    /// and stored as a column-major `simd_double4x4`.
    public let matrixWorld: simd_double4x4
    /// Focal length in millimeters (`camera.data.lens`).
    public let focalLength: Double
    /// Sensor width in millimeters (`camera.data.sensor_width`).
    public let sensorWidth: Double
    /// Sensor height in millimeters (`camera.data.sensor_height`).
    public let sensorHeight: Double
    /// Vertical field of view in degrees, computed via Blender's `sensor_fit` logic.
    public let verticalFov: Double
    /// Near clip distance in Blender units.
    public let clipStart: Double
    /// Far clip distance in Blender units.
    public let clipEnd: Double

    /// Render output width in pixels.
    public let renderWidth: Int
    /// Render output height in pixels.
    public let renderHeight: Int
    /// Render aspect ratio (`renderWidth / renderHeight`).
    public let renderAspect: Double

    /// Current playhead frame at the moment of the snapshot.
    public let frame: Int
    /// Optional pre-baked world matrices, one per requested frame.
    ///
    /// When the addon is asked to include keyframes, it evaluates the camera
    /// against the depsgraph at each frame in the timeline (or only at frames
    /// containing explicit keyframes when `send_only_explicit_keyframes` is on).
    /// This is the only safe source of truth for cameras driven by parents,
    /// constraints, or drivers.
    public let bakedKeyframes: [BakedKeyframe]

    /// A single baked frame: `(frame, world_matrix)` from the evaluated depsgraph.
    public struct BakedKeyframe: Sendable, Codable {
        /// Blender frame number.
        public let frame: Int
        /// Evaluated world matrix at that frame.
        public let matrixWorld: simd_double4x4

        private enum CodingKeys: String, CodingKey { case frame, matrixWorld }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.frame = try c.decode(Int.self, forKey: .frame)
            let row = try c.decode([Double].self, forKey: .matrixWorld)
            self.matrixWorld = Self.matrix(from: row)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(frame, forKey: .frame)
            try c.encode(Self.flatten(matrixWorld), forKey: .matrixWorld)
        }

        /// Memberwise initializer.
        public init(frame: Int, matrixWorld: simd_double4x4) {
            self.frame = frame
            self.matrixWorld = matrixWorld
        }

        static func matrix(from row: [Double]) -> simd_double4x4 {
            CameraSnapshot.matrix(from: row)
        }
        static func flatten(_ m: simd_double4x4) -> [Double] {
            CameraSnapshot.flatten(m)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name, location
        case rotationEuler = "rotation"   // addon sends `rotation` (it's already euler)
        case quaternion, scale
        case matrixWorld
        case focalLength, sensorWidth, sensorHeight, verticalFov
        case clipStart, clipEnd
        case renderWidth, renderHeight, renderAspect
        case frame, bakedKeyframes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)

        let loc = try c.decode([Double].self, forKey: .location)
        let rot = try c.decode([Double].self, forKey: .rotationEuler)
        let quat = try c.decode([Double].self, forKey: .quaternion)
        let scl = try c.decode([Double].self, forKey: .scale)

        location = SIMD3(loc[0], loc[1], loc[2])
        rotationEuler = SIMD3(rot[0], rot[1], rot[2])
        quaternion = SIMD4(quat[0], quat[1], quat[2], quat[3])
        scale = SIMD3(scl[0], scl[1], scl[2])

        let row = try c.decode([Double].self, forKey: .matrixWorld)
        matrixWorld = Self.matrix(from: row)

        focalLength = try c.decode(Double.self, forKey: .focalLength)
        sensorWidth = try c.decode(Double.self, forKey: .sensorWidth)
        sensorHeight = try c.decode(Double.self, forKey: .sensorHeight)
        verticalFov = try c.decode(Double.self, forKey: .verticalFov)
        clipStart = try c.decode(Double.self, forKey: .clipStart)
        clipEnd = try c.decode(Double.self, forKey: .clipEnd)

        renderWidth = try c.decode(Int.self, forKey: .renderWidth)
        renderHeight = try c.decode(Int.self, forKey: .renderHeight)
        renderAspect = try c.decode(Double.self, forKey: .renderAspect)

        frame = try c.decode(Int.self, forKey: .frame)
        bakedKeyframes = try c.decodeIfPresent([BakedKeyframe].self, forKey: .bakedKeyframes) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode([location.x, location.y, location.z], forKey: .location)
        try c.encode([rotationEuler.x, rotationEuler.y, rotationEuler.z], forKey: .rotationEuler)
        try c.encode([quaternion.x, quaternion.y, quaternion.z, quaternion.w], forKey: .quaternion)
        try c.encode([scale.x, scale.y, scale.z], forKey: .scale)
        try c.encode(Self.flatten(matrixWorld), forKey: .matrixWorld)
        try c.encode(focalLength, forKey: .focalLength)
        try c.encode(sensorWidth, forKey: .sensorWidth)
        try c.encode(sensorHeight, forKey: .sensorHeight)
        try c.encode(verticalFov, forKey: .verticalFov)
        try c.encode(clipStart, forKey: .clipStart)
        try c.encode(clipEnd, forKey: .clipEnd)
        try c.encode(renderWidth, forKey: .renderWidth)
        try c.encode(renderHeight, forKey: .renderHeight)
        try c.encode(renderAspect, forKey: .renderAspect)
        try c.encode(frame, forKey: .frame)
        try c.encode(bakedKeyframes, forKey: .bakedKeyframes)
    }

    /// Blender's `matrix_world` is serialized row-major (Matrix iteration yields rows).
    /// simd matrices are column-major, so we transpose at the boundary.
    fileprivate static func matrix(from row: [Double]) -> simd_double4x4 {
        precondition(row.count == 16, "matrix_world must be 16 doubles, got \(row.count)")
        let r0 = SIMD4<Double>(row[0],  row[1],  row[2],  row[3])
        let r1 = SIMD4<Double>(row[4],  row[5],  row[6],  row[7])
        let r2 = SIMD4<Double>(row[8],  row[9],  row[10], row[11])
        let r3 = SIMD4<Double>(row[12], row[13], row[14], row[15])
        return simd_double4x4(rows: [r0, r1, r2, r3])
    }

    fileprivate static func flatten(_ m: simd_double4x4) -> [Double] {
        let t = m.transpose
        var out: [Double] = []
        out.reserveCapacity(16)
        for i in 0..<4 { let col = t[i]; out += [col.x, col.y, col.z, col.w] }
        return out
    }
}
