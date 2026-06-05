/// Animated object graph received from the Blender addon (`object_graph`).
///
/// Unlike ``CameraCurves`` (a single camera, evaluated here in the package),
/// ``ObjectGraph`` is a **transport-only** payload: it carries every animated
/// object's authoring data (keyframes, parenting, constraints) plus an optional
/// depsgraph-baked matrix fallback. The actual evaluation — a dependency-ordered
/// transform engine + constraint solver — lives in WABFCoreKit, which sketches
/// link directly; this package only decodes the wire format.
///
/// Matrices are 16-float **row-major** (Blender `Matrix` iterates rows), matching
/// ``CameraStatic/matrixWorld``. Transforms are in Blender's Z-up space; the
/// WABFEngine bridge converts to Satin Y-up at import.
///
/// The Python producer is `blender-addon/bl_camera_sync/export.py`.

import Foundation
import simd

// MARK: - Top level

/// All animated objects in a scene scope, captured at one moment.
public struct ObjectGraph: Codable, Sendable {
    /// Inclusive timeline start frame.
    public let frameStart: Int
    /// Inclusive timeline end frame.
    public let frameEnd: Int
    /// Scene frame rate (`fps / fps_base`).
    public let fps: Double
    /// Render width in pixels.
    public let renderWidth: Int
    /// Render height in pixels.
    public let renderHeight: Int
    /// Render aspect ratio.
    public let renderAspect: Double
    /// Every exported object, in scene order.
    public let objects: [AnimObject]

    /// Convenience decoder configured with `convertFromSnakeCase`.
    public static func decode(from data: Data) throws -> ObjectGraph {
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode(ObjectGraph.self, from: data)
    }

    /// Look up an object by its stable id (defaults to the Blender object name).
    public func object(id: String) -> AnimObject? {
        objects.first { $0.id == id }
    }
}

// MARK: - Object

/// One object's transform authoring data + optional baked fallback.
public struct AnimObject: Codable, Sendable {
    /// Blender object name.
    public let name: String
    /// Stable identifier (defaults to ``name``).
    public let id: String
    /// Blender object type (`"MESH"`, `"EMPTY"`, `"CAMERA"`, …).
    public let type: String
    /// How the object's rotation channels compose into a basis.
    public let rotationMode: RotationMode
    /// Static pose at `frameStart` — fallback for any unanimated channel.
    public let base: ObjectBase
    /// Parent object name, or nil if unparented.
    public let parent: String?
    /// `matrix_parent_inverse`, 16-float row-major.
    public let parentInverse: [Double]
    /// `"OBJECT"`, `"BONE"`, or `"VERTEX"`. Only `OBJECT` is solved natively.
    public let parentType: String
    /// Constraint stack in evaluation order.
    public let constraints: [BlenderConstraint]
    /// Object-level fcurves (transform + constraint-influence channels).
    public let fcurves: [FCurve]
    /// Camera intrinsics (static + animated lens/sensor/clip) for CAMERA objects.
    public let camera: CameraIntrinsicsDTO?
    /// Depsgraph-baked per-frame matrices, present when ``needsBake`` is true.
    public let baked: BakedTrack?
    /// Addon's verdict: the Core engine can't reproduce this object from raw
    /// data and should replay ``baked`` instead.
    public let needsBake: Bool

    /// Look up an fcurve by data_path + array_index (object source only).
    public func fcurve(dataPath: String, arrayIndex: Int = 0) -> FCurve? {
        fcurves.first { $0.dataPath == dataPath && $0.arrayIndex == arrayIndex }
    }
}

/// Static pose + rotation variants captured at `frameStart`.
///
/// Blender always emits all three rotation representations plus deltas; consumers
/// read the one matching ``AnimObject/rotationMode``.
public struct ObjectBase: Codable, Sendable {
    public let location: [Double]
    public let scale: [Double]
    /// Euler radians in the object's rotation order.
    public let rotationEuler: [Double]
    /// Quaternion `[w, x, y, z]`.
    public let rotationQuaternion: [Double]
    /// Axis-angle `[angle, x, y, z]` (Blender order).
    public let rotationAxisAngle: [Double]
    public let deltaLocation: [Double]
    public let deltaScale: [Double]
    public let deltaRotationEuler: [Double]
    public let deltaRotationQuaternion: [Double]
    /// `matrix_local`, 16-float row-major.
    public let matrixLocal: [Double]
    /// `matrix_world` at `frameStart`, 16-float row-major.
    public let matrixWorld: [Double]
}

/// Object rotation mode (mirrors Blender's `rotation_mode`).
public enum RotationMode: String, Codable, Sendable {
    case xyz = "XYZ", xzy = "XZY", yxz = "YXZ"
    case yzx = "YZX", zxy = "ZXY", zyx = "ZYX"
    case quaternion = "QUATERNION"
    case axisAngle = "AXIS_ANGLE"
}

// MARK: - Constraints

/// One constraint in an object's stack. Params are a flattened union (§docs);
/// only the keys relevant to ``type`` are populated.
public struct BlenderConstraint: Codable, Sendable {
    public let type: ConstraintType
    public let name: String
    public let influence: Double
    public let mute: Bool
    /// Target object name, or nil.
    public let target: String?
    /// Bone subtarget name (forces bake fallback when present).
    public let subtarget: String?
    public let params: ConstraintParams
}

/// Constraint kind. Unknown wire values decode to ``unsupported`` so a newer
/// addon never breaks decoding (the object will carry a baked fallback anyway).
public enum ConstraintType: String, Codable, Sendable {
    case childOf = "CHILD_OF"
    case copyLocation = "COPY_LOCATION"
    case copyRotation = "COPY_ROTATION"
    case copyScale = "COPY_SCALE"
    case copyTransforms = "COPY_TRANSFORMS"
    case trackTo = "TRACK_TO"
    case dampedTrack = "DAMPED_TRACK"
    case lockedTrack = "LOCKED_TRACK"
    case limitLocation = "LIMIT_LOCATION"
    case limitRotation = "LIMIT_ROTATION"
    case limitScale = "LIMIT_SCALE"
    case followPath = "FOLLOW_PATH"
    case unsupported

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ConstraintType(rawValue: raw) ?? .unsupported
    }
}

/// Flattened, all-optional constraint parameters. The producer omits keys that
/// don't apply to a given constraint type; absent keys decode to nil.
public struct ConstraintParams: Codable, Sendable {
    // Track / Damped / Locked
    public let trackAxis: String?
    public let upAxis: String?
    public let lockAxis: String?
    public let targetSpace: String?
    public let ownerSpace: String?
    public let headTail: Double?
    // Copy*
    public let useX: Bool?
    public let useY: Bool?
    public let useZ: Bool?
    public let invertX: Bool?
    public let invertY: Bool?
    public let invertZ: Bool?
    public let useOffset: Bool?
    public let mixMode: String?
    public let eulerOrder: String?
    public let power: Double?
    // Limit*
    public let useMinX: Bool?
    public let useMaxX: Bool?
    public let useMinY: Bool?
    public let useMaxY: Bool?
    public let useMinZ: Bool?
    public let useMaxZ: Bool?
    public let minX: Double?
    public let maxX: Double?
    public let minY: Double?
    public let maxY: Double?
    public let minZ: Double?
    public let maxZ: Double?
    public let useLimitX: Bool?
    public let useLimitY: Bool?
    public let useLimitZ: Bool?
    public let useTransformLimit: Bool?
    // Child Of
    public let useLocationX: Bool?
    public let useLocationY: Bool?
    public let useLocationZ: Bool?
    public let useRotationX: Bool?
    public let useRotationY: Bool?
    public let useRotationZ: Bool?
    public let useScaleX: Bool?
    public let useScaleY: Bool?
    public let useScaleZ: Bool?
    /// Child Of correction matrix, 16-float row-major.
    public let inverseMatrix: [Double]?
    // Follow Path
    public let useCurveFollow: Bool?
    public let useFixedLocation: Bool?
    public let useCurveRadius: Bool?
    public let offset: Double?
    public let offsetFactor: Double?
    public let forwardAxis: String?
}

/// Camera intrinsics: static lens/sensor/clip + their data-block fcurves.
public struct CameraIntrinsicsDTO: Codable, Sendable {
    public let focalLength: Double
    public let sensorWidth: Double
    public let sensorHeight: Double
    public let clipStart: Double
    public let clipEnd: Double
    public let sensorFit: String
    public let fcurves: [FCurve]
}

// MARK: - Baked fallback

/// Per-frame depsgraph-evaluated world matrices for objects the Core engine
/// can't reproduce natively.
public struct BakedTrack: Codable, Sendable {
    /// Why the object was baked (`"unsupported"`, `"forced"`, …).
    public let reason: String
    /// One entry per integer frame in `[frameStart, frameEnd]`.
    public let frames: [BakedObjectFrame]
}

/// A single baked frame.
public struct BakedObjectFrame: Codable, Sendable {
    public let frame: Int
    /// `matrix_world`, 16-float row-major.
    public let matrixWorld: [Double]
}
