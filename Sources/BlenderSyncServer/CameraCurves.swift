/// Camera animation curves received from the Blender addon (`camera_curves`).
///
/// The evaluator below is a faithful port of Blender's `evaluate_fcurve` /
/// `fcurve_eval_keyframes_interpolate` / `fcurve_eval_keyframes_extrapolate`
/// from `source/blender/blenkernel/intern/fcurve.cc`, plus the easing functions
/// from `source/blender/blenlib/intern/easing.cc` (Robert Penner's set, as used
/// by Blender). Animation modifiers and drivers are not supported.
///
/// Coordinate conventions: keyframe `frame` is in Blender frames; handle `x/y`
/// are in absolute `(frame, value)` space, not deltas.

import Foundation
import simd

// MARK: - Payload types

/// All animation data needed to reproduce a Blender camera's motion offline.
///
/// Combines a `static` snapshot of every camera property at `frameStart` with
/// the raw fcurves so consumers can evaluate the camera at any frame without
/// a Blender runtime.
public struct CameraCurves: Codable, Sendable {
    /// Camera object name.
    public let name: String
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
    /// Snapshot of all camera properties at `frameStart`.
    ///
    /// Used as the fallback value for any property that isn't animated.
    public let `static`: CameraStatic
    /// Every fcurve found on the camera object and its data block.
    public let fcurves: [FCurve]

    /// Memberwise initializer.
    public init(name: String, frameStart: Int, frameEnd: Int, fps: Double,
                renderWidth: Int, renderHeight: Int, renderAspect: Double,
                static staticVals: CameraStatic, fcurves: [FCurve]) {
        self.name = name
        self.frameStart = frameStart
        self.frameEnd = frameEnd
        self.fps = fps
        self.renderWidth = renderWidth
        self.renderHeight = renderHeight
        self.renderAspect = renderAspect
        self.`static` = staticVals
        self.fcurves = fcurves
    }

    /// Convenience decoder configured with `convertFromSnakeCase`.
    public static func decode(from data: Data) throws -> CameraCurves {
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode(CameraCurves.self, from: data)
    }

    /// Look up an fcurve by source + data_path + array_index. Returns nil if absent.
    public func fcurve(source: String, dataPath: String, arrayIndex: Int = 0) -> FCurve? {
        fcurves.first { $0.source == source && $0.dataPath == dataPath && $0.arrayIndex == arrayIndex }
    }

    /// Compose camera state at the given frame.
    ///
    /// Pose is built as T·R·S from animated `location`, `rotation_euler`,
    /// `scale` fcurves on the camera object (each axis falls back to the
    /// `static` value if not animated). Intrinsics come from the animated
    /// `lens`/`clip_start`/`clip_end`/etc. on the camera data block.
    ///
    /// Limitation: this composition only sees keyed values on the camera
    /// itself. Parent transforms, drivers, and constraints are NOT applied.
    /// For accurate world-space pose under those conditions, use the
    /// `bakedKeyframes` on `CameraSnapshot` instead (which Blender evaluates
    /// against the depsgraph).
    public func sample(at frame: Double) -> CameraSample {
        // Pose
        let lx = fcurve(source: "object", dataPath: "location", arrayIndex: 0)?.evaluate(at: frame) ?? `static`.location[0]
        let ly = fcurve(source: "object", dataPath: "location", arrayIndex: 1)?.evaluate(at: frame) ?? `static`.location[1]
        let lz = fcurve(source: "object", dataPath: "location", arrayIndex: 2)?.evaluate(at: frame) ?? `static`.location[2]

        let rx = fcurve(source: "object", dataPath: "rotation_euler", arrayIndex: 0)?.evaluate(at: frame) ?? `static`.rotationEuler[0]
        let ry = fcurve(source: "object", dataPath: "rotation_euler", arrayIndex: 1)?.evaluate(at: frame) ?? `static`.rotationEuler[1]
        let rz = fcurve(source: "object", dataPath: "rotation_euler", arrayIndex: 2)?.evaluate(at: frame) ?? `static`.rotationEuler[2]

        let sx = fcurve(source: "object", dataPath: "scale", arrayIndex: 0)?.evaluate(at: frame) ?? `static`.scale[0]
        let sy = fcurve(source: "object", dataPath: "scale", arrayIndex: 1)?.evaluate(at: frame) ?? `static`.scale[1]
        let sz = fcurve(source: "object", dataPath: "scale", arrayIndex: 2)?.evaluate(at: frame) ?? `static`.scale[2]

        let location = SIMD3<Double>(lx, ly, lz)
        let rotationEuler = SIMD3<Double>(rx, ry, rz)
        let scale = SIMD3<Double>(sx, sy, sz)
        let matrix = trsXYZ(location: location, eulerXYZ: rotationEuler, scale: scale)

        // Intrinsics
        let focal = fcurve(source: "data", dataPath: "lens", arrayIndex: 0)?.evaluate(at: frame) ?? `static`.focalLength
        let sw    = fcurve(source: "data", dataPath: "sensor_width", arrayIndex: 0)?.evaluate(at: frame) ?? `static`.sensorWidth
        let sh    = fcurve(source: "data", dataPath: "sensor_height", arrayIndex: 0)?.evaluate(at: frame) ?? `static`.sensorHeight
        let cs    = fcurve(source: "data", dataPath: "clip_start", arrayIndex: 0)?.evaluate(at: frame) ?? `static`.clipStart
        let ce    = fcurve(source: "data", dataPath: "clip_end", arrayIndex: 0)?.evaluate(at: frame) ?? `static`.clipEnd

        // Vertical FOV is recomputed from the (possibly animated) intrinsics
        // following Blender's sensor_fit logic. We don't have a render aspect
        // mid-curve, so use the one captured at frame_start.
        let vfov = verticalFovDegrees(focal: focal, sensorWidth: sw, sensorHeight: sh,
                                      sensorFit: `static`.sensorFit, renderAspect: renderAspect)

        return CameraSample(
            frame: frame,
            location: location,
            rotationEuler: rotationEuler,
            scale: scale,
            matrixWorld: matrix,
            focalLength: focal,
            sensorWidth: sw,
            sensorHeight: sh,
            verticalFov: vfov,
            clipStart: cs,
            clipEnd: ce
        )
    }
}

/// Camera state evaluated at a single (possibly fractional) frame.
///
/// Returned by ``CameraCurves/sample(at:)``. Pose is composed from animated
/// fcurves only; parents, drivers, and constraints are not honored — see the
/// note on ``CameraCurves/sample(at:)``.
public struct CameraSample: Sendable {
    /// Evaluated frame (may be fractional).
    public let frame: Double
    /// World-space location.
    public let location: SIMD3<Double>
    /// Euler rotation in radians, XYZ order (Blender default `rotation_mode`).
    public let rotationEuler: SIMD3<Double>
    /// Per-axis scale.
    public let scale: SIMD3<Double>
    /// Pose composed as `T · R(XYZ) · S` — see ``CameraCurves/sample(at:)`` limitations.
    public let matrixWorld: simd_double4x4
    /// Focal length in millimeters.
    public let focalLength: Double
    /// Sensor width in millimeters.
    public let sensorWidth: Double
    /// Sensor height in millimeters.
    public let sensorHeight: Double
    /// Vertical FOV in degrees.
    public let verticalFov: Double
    /// Near clip distance.
    public let clipStart: Double
    /// Far clip distance.
    public let clipEnd: Double
}

extension CameraStatic {
    /// `matrix_world` reassembled as a `simd_double4x4`.
    ///
    /// The wire form is row-major (Blender `Matrix` iteration yields rows);
    /// this transposes into simd's column-major convention.
    public var matrixWorldMatrix: simd_double4x4 {
        precondition(matrixWorld.count == 16)
        let r0 = SIMD4<Double>(matrixWorld[0],  matrixWorld[1],  matrixWorld[2],  matrixWorld[3])
        let r1 = SIMD4<Double>(matrixWorld[4],  matrixWorld[5],  matrixWorld[6],  matrixWorld[7])
        let r2 = SIMD4<Double>(matrixWorld[8],  matrixWorld[9],  matrixWorld[10], matrixWorld[11])
        let r3 = SIMD4<Double>(matrixWorld[12], matrixWorld[13], matrixWorld[14], matrixWorld[15])
        return simd_double4x4(rows: [r0, r1, r2, r3])
    }
}

// MARK: - Composition helpers

private func trsXYZ(location: SIMD3<Double>, eulerXYZ: SIMD3<Double>, scale: SIMD3<Double>) -> simd_double4x4 {
    // Blender's rotation_mode default is XYZ, which composes as Rz · Ry · Rx
    // applied to a column vector (i.e. rotate X first, then Y, then Z).
    let cx = cos(eulerXYZ.x), sx = sin(eulerXYZ.x)
    let cy = cos(eulerXYZ.y), sy = sin(eulerXYZ.y)
    let cz = cos(eulerXYZ.z), sz = sin(eulerXYZ.z)

    // 3x3 rotation Rz·Ry·Rx, column-major.
    let r00 = cy * cz
    let r01 = cz * sx * sy - cx * sz
    let r02 = cx * cz * sy + sx * sz
    let r10 = cy * sz
    let r11 = cx * cz + sx * sy * sz
    let r12 = -cz * sx + cx * sy * sz
    let r20 = -sy
    let r21 = cy * sx
    let r22 = cx * cy

    let c0 = SIMD4<Double>(r00 * scale.x, r10 * scale.x, r20 * scale.x, 0)
    let c1 = SIMD4<Double>(r01 * scale.y, r11 * scale.y, r21 * scale.y, 0)
    let c2 = SIMD4<Double>(r02 * scale.z, r12 * scale.z, r22 * scale.z, 0)
    let c3 = SIMD4<Double>(location.x, location.y, location.z, 1)
    return simd_double4x4(columns: (c0, c1, c2, c3))
}

private func verticalFovDegrees(focal: Double, sensorWidth: Double, sensorHeight: Double,
                                sensorFit: String, renderAspect: Double) -> Double {
    let vFovRad: Double
    switch sensorFit.uppercased() {
    case "HORIZONTAL":
        let hFov = 2 * atan(sensorWidth / (2 * focal))
        vFovRad = 2 * atan(tan(hFov / 2) / renderAspect)
    case "VERTICAL":
        vFovRad = 2 * atan(sensorHeight / (2 * focal))
    default: // AUTO
        if renderAspect > (sensorWidth / sensorHeight) {
            let hFov = 2 * atan(sensorWidth / (2 * focal))
            vFovRad = 2 * atan(tan(hFov / 2) / renderAspect)
        } else {
            vFovRad = 2 * atan(sensorHeight / (2 * focal))
        }
    }
    return vFovRad * 180 / .pi
}

/// Snapshot of every camera property at `frameStart`.
///
/// Provides fallback values for properties that aren't animated, plus the
/// `sensorFit` mode needed to recompute vertical FOV as intrinsics change.
public struct CameraStatic: Codable, Sendable {
    /// 16-float row-major world matrix at `frameStart`.
    public let matrixWorld: [Double]
    /// Location at `frameStart` (`[x, y, z]`).
    public let location: [Double]
    /// Euler rotation at `frameStart` in radians, XYZ order.
    public let rotationEuler: [Double]
    /// Scale at `frameStart` (`[x, y, z]`).
    public let scale: [Double]
    /// Focal length in millimeters.
    public let focalLength: Double
    /// Sensor width in millimeters.
    public let sensorWidth: Double
    /// Sensor height in millimeters.
    public let sensorHeight: Double
    /// Blender's `sensor_fit`: `"AUTO"`, `"HORIZONTAL"`, or `"VERTICAL"`.
    public let sensorFit: String
    /// Near clip distance.
    public let clipStart: Double
    /// Far clip distance.
    public let clipEnd: Double
    /// Vertical FOV in degrees at `frameStart`.
    public let verticalFov: Double
}

/// A single Blender F-Curve: an animation channel targeting one scalar property.
public struct FCurve: Codable, Sendable {
    /// Owner tag: `"object"` (transform/visibility) or `"data"` (lens/sensor/clip).
    ///
    /// Modifier and constraint animations are folded onto the object's action,
    /// so they appear here with `source == "object"` and a `data_path` like
    /// `constraints["TrackTo"].influence`.
    public let source: String
    /// RNA data path of the animated property (e.g. `"location"`, `"lens"`).
    public let dataPath: String
    /// Index into the animated property when it's vector-valued (0 = x, etc.).
    public let arrayIndex: Int
    /// What to do outside the keyframe range.
    public let extrapolation: Extrapolation
    /// `true` if Blender reports animation modifiers on this curve.
    ///
    /// Modifiers (noise, cycles, …) are NOT replayed by ``evaluate(at:)`` —
    /// only the underlying keyframes are. Use baked keyframes for fidelity.
    public let hasModifiers: Bool
    /// Keyframes in frame order.
    public let keyframes: [Keyframe]

    /// Memberwise initializer.
    public init(source: String, dataPath: String, arrayIndex: Int,
                extrapolation: Extrapolation, hasModifiers: Bool,
                keyframes: [Keyframe]) {
        self.source = source
        self.dataPath = dataPath
        self.arrayIndex = arrayIndex
        self.extrapolation = extrapolation
        self.hasModifiers = hasModifiers
        self.keyframes = keyframes
    }
}

/// One keyframe in an ``FCurve``.
///
/// Stores both the value and the per-keyframe interpolation/easing settings
/// that govern the segment *leading out of* this keyframe.
public struct Keyframe: Codable, Sendable {
    /// X coordinate of the keyframe (Blender frame number, fractional allowed).
    public let frame: Double
    /// Y coordinate of the keyframe (the animated value).
    public let value: Double
    /// Interpolation type applied to the segment after this keyframe.
    public let interpolation: Interpolation
    /// Easing direction (`AUTO` / `EASE_IN` / `EASE_OUT` / `EASE_IN_OUT`).
    public let easing: Easing
    /// Left Bezier handle in absolute `(frame, value)` space.
    public let handleLeft: [Double]
    /// Right Bezier handle in absolute `(frame, value)` space.
    public let handleRight: [Double]
    /// Amplitude parameter for `ELASTIC` interpolation.
    public let amplitude: Double
    /// Period parameter for `ELASTIC` interpolation.
    public let period: Double
    /// Overshoot parameter for `BACK` interpolation.
    public let back: Double

    /// Memberwise initializer. `back` defaults to Blender's value of `1.70158`.
    public init(frame: Double, value: Double,
                interpolation: Interpolation, easing: Easing,
                handleLeft: [Double], handleRight: [Double],
                amplitude: Double = 0, period: Double = 0, back: Double = 1.70158) {
        self.frame = frame
        self.value = value
        self.interpolation = interpolation
        self.easing = easing
        self.handleLeft = handleLeft
        self.handleRight = handleRight
        self.amplitude = amplitude
        self.period = period
        self.back = back
    }
}

/// Per-keyframe interpolation mode. Mirrors Blender's `keyframe.interpolation`.
public enum Interpolation: String, Codable, Sendable {
    case constant = "CONSTANT"
    case linear   = "LINEAR"
    case bezier   = "BEZIER"
    case sine     = "SINE"
    case quad     = "QUAD"
    case cubic    = "CUBIC"
    case quart    = "QUART"
    case quint    = "QUINT"
    case expo     = "EXPO"
    case circ     = "CIRC"
    case back     = "BACK"
    case bounce   = "BOUNCE"
    case elastic  = "ELASTIC"
}

/// Easing direction for non-Bezier interpolations. Mirrors Blender's `keyframe.easing`.
public enum Easing: String, Codable, Sendable {
    case auto       = "AUTO"
    case easeIn     = "EASE_IN"
    case easeOut    = "EASE_OUT"
    case easeInOut  = "EASE_IN_OUT"
}

/// How the curve behaves outside its keyframe range.
/// Mirrors Blender's `fcurve.extrapolation`.
public enum Extrapolation: String, Codable, Sendable {
    case constant = "CONSTANT"
    case linear   = "LINEAR"
}

// MARK: - Evaluation

extension FCurve {
    /// Evaluate the curve at a frame. Mirrors Blender's `evaluate_fcurve`.
    public func evaluate(at frame: Double) -> Double {
        let bezts = keyframes
        guard !bezts.isEmpty else { return 0 }
        if bezts.count == 1 { return bezts[0].value }

        if frame <= bezts[0].frame {
            return extrapolateEndpoint(at: frame, endpointIndex: 0, neighborDirection: 1)
        }
        if frame >= bezts[bezts.count - 1].frame {
            return extrapolateEndpoint(at: frame, endpointIndex: bezts.count - 1, neighborDirection: -1)
        }
        return interpolate(at: frame)
    }

    // ----- extrapolation -----

    private func extrapolateEndpoint(at evaltime: Double, endpointIndex: Int, neighborDirection: Int) -> Double {
        let endpoint = keyframes[endpointIndex]
        let neighbor = keyframes[endpointIndex + neighborDirection]

        // Constant extrap, or this keyframe holds constant => hold value.
        if endpoint.interpolation == .constant || extrapolation == .constant {
            return endpoint.value
        }

        if endpoint.interpolation == .linear {
            let dx = endpoint.frame - evaltime
            let denom = neighbor.frame - endpoint.frame
            if denom == 0 { return endpoint.value }
            let slope = (neighbor.value - endpoint.value) / denom
            return endpoint.value - slope * dx
        }

        // Otherwise: extend using the gradient implied by the endpoint's relevant handle.
        // Direction +1 (leading edge of curve) → use left handle (vec[0]); direction -1 → right handle (vec[2]).
        let handle: [Double] = neighborDirection > 0 ? endpoint.handleLeft : endpoint.handleRight
        let dx = endpoint.frame - evaltime
        let denom = endpoint.frame - handle[0]
        if denom == 0 { return endpoint.value }
        let slope = (endpoint.value - handle[1]) / denom
        return endpoint.value - slope * dx
    }

    // ----- interpolation between two keyframes -----

    private func interpolate(at evaltime: Double) -> Double {
        let bezts = keyframes
        let eps = 1.0e-8

        // Binary search for the keyframe at or just after evaltime.
        var lo = 0
        var hi = bezts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if bezts[mid].frame <= evaltime + 0.0001 { lo = mid + 1 } else { hi = mid }
        }
        // lo is the first index where frame > evaltime (with threshold).
        let a = lo
        // Exact-hit check (Blender's `exact` path).
        if a > 0 && abs(bezts[a - 1].frame - evaltime) < 0.0001 {
            return bezts[a - 1].value
        }

        let bezt = bezts[min(a, bezts.count - 1)]
        let prevbezt = a > 0 ? bezts[a - 1] : bezt

        if abs(bezt.frame - evaltime) < eps { return bezt.value }
        if evaltime < prevbezt.frame || bezt.frame < evaltime { return 0 }

        let begin = prevbezt.value
        let change = bezt.value - prevbezt.value
        let duration = bezt.frame - prevbezt.frame
        let t = evaltime - prevbezt.frame

        if prevbezt.interpolation == .constant || duration == 0 {
            return prevbezt.value
        }

        switch prevbezt.interpolation {
        case .constant:
            return prevbezt.value

        case .linear:
            return BlenderEasing.linear(t, begin, change, duration)

        case .bezier:
            // (v1, v2) prev key and its right handle, (v3, v4) next key's left handle and itself.
            var v1 = SIMD2<Double>(prevbezt.frame, prevbezt.value)
            var v2 = SIMD2<Double>(prevbezt.handleRight[0], prevbezt.handleRight[1])
            var v3 = SIMD2<Double>(bezt.handleLeft[0], bezt.handleLeft[1])
            var v4 = SIMD2<Double>(bezt.frame, bezt.value)

            // Flat-handle optimization.
            if abs(v1.y - v4.y) < Double.ulpOfOne &&
               abs(v2.y - v3.y) < Double.ulpOfOne &&
               abs(v3.y - v4.y) < Double.ulpOfOne {
                return v1.y
            }
            correctBezpart(v1: v1, v2: &v2, v3: &v3, v4: v4)
            if let s = findZero(evaltime, v1.x, v2.x, v3.x, v4.x) {
                return bereKeny(v1.y, v2.y, v3.y, v4.y, t: s)
            }
            return 0

        case .back:
            switch prevbezt.easing {
            case .easeIn:    return BlenderEasing.backIn(t, begin, change, duration, prevbezt.back)
            case .easeOut, .auto:
                             return BlenderEasing.backOut(t, begin, change, duration, prevbezt.back)
            case .easeInOut: return BlenderEasing.backInOut(t, begin, change, duration, prevbezt.back)
            }
        case .bounce:
            switch prevbezt.easing {
            case .easeIn:    return BlenderEasing.bounceIn(t, begin, change, duration)
            case .easeOut, .auto:
                             return BlenderEasing.bounceOut(t, begin, change, duration)
            case .easeInOut: return BlenderEasing.bounceInOut(t, begin, change, duration)
            }
        case .circ:
            switch prevbezt.easing {
            case .easeIn, .auto:
                             return BlenderEasing.circIn(t, begin, change, duration)
            case .easeOut:   return BlenderEasing.circOut(t, begin, change, duration)
            case .easeInOut: return BlenderEasing.circInOut(t, begin, change, duration)
            }
        case .cubic:
            switch prevbezt.easing {
            case .easeIn, .auto:
                             return BlenderEasing.cubicIn(t, begin, change, duration)
            case .easeOut:   return BlenderEasing.cubicOut(t, begin, change, duration)
            case .easeInOut: return BlenderEasing.cubicInOut(t, begin, change, duration)
            }
        case .elastic:
            switch prevbezt.easing {
            case .easeIn:    return BlenderEasing.elasticIn(t, begin, change, duration, prevbezt.amplitude, prevbezt.period)
            case .easeOut, .auto:
                             return BlenderEasing.elasticOut(t, begin, change, duration, prevbezt.amplitude, prevbezt.period)
            case .easeInOut: return BlenderEasing.elasticInOut(t, begin, change, duration, prevbezt.amplitude, prevbezt.period)
            }
        case .expo:
            switch prevbezt.easing {
            case .easeIn, .auto:
                             return BlenderEasing.expoIn(t, begin, change, duration)
            case .easeOut:   return BlenderEasing.expoOut(t, begin, change, duration)
            case .easeInOut: return BlenderEasing.expoInOut(t, begin, change, duration)
            }
        case .quad:
            switch prevbezt.easing {
            case .easeIn, .auto:
                             return BlenderEasing.quadIn(t, begin, change, duration)
            case .easeOut:   return BlenderEasing.quadOut(t, begin, change, duration)
            case .easeInOut: return BlenderEasing.quadInOut(t, begin, change, duration)
            }
        case .quart:
            switch prevbezt.easing {
            case .easeIn, .auto:
                             return BlenderEasing.quartIn(t, begin, change, duration)
            case .easeOut:   return BlenderEasing.quartOut(t, begin, change, duration)
            case .easeInOut: return BlenderEasing.quartInOut(t, begin, change, duration)
            }
        case .quint:
            switch prevbezt.easing {
            case .easeIn, .auto:
                             return BlenderEasing.quintIn(t, begin, change, duration)
            case .easeOut:   return BlenderEasing.quintOut(t, begin, change, duration)
            case .easeInOut: return BlenderEasing.quintInOut(t, begin, change, duration)
            }
        case .sine:
            switch prevbezt.easing {
            case .easeIn, .auto:
                             return BlenderEasing.sineIn(t, begin, change, duration)
            case .easeOut:   return BlenderEasing.sineOut(t, begin, change, duration)
            case .easeInOut: return BlenderEasing.sineInOut(t, begin, change, duration)
            }
        }
    }
}

// MARK: - Bezier helpers (ported from BKE_fcurve_correct_bezpart, findzero, berekeny, solve_cubic)

/// Clamp Bezier inner handles so they don't form a loop. Mirrors `BKE_fcurve_correct_bezpart`.
private func correctBezpart(v1: SIMD2<Double>, v2: inout SIMD2<Double>,
                            v3: inout SIMD2<Double>, v4: SIMD2<Double>) {
    var h1 = SIMD2<Double>(v1.x - v2.x, v1.y - v2.y)
    var h2 = SIMD2<Double>(v4.x - v3.x, v4.y - v3.y)
    let len = v4.x - v1.x
    let len1 = abs(h1.x)
    let len2 = abs(h2.x)
    if (len1 + len2) == 0 { return }
    if len1 > len {
        let fac = len / len1
        v2 = SIMD2<Double>(v1.x - fac * h1.x, v1.y - fac * h1.y)
        h1 = SIMD2<Double>(v1.x - v2.x, v1.y - v2.y)
    }
    if len2 > len {
        let fac = len / len2
        v3 = SIMD2<Double>(v4.x - fac * h2.x, v4.y - fac * h2.y)
        h2 = SIMD2<Double>(v4.x - v3.x, v4.y - v3.y)
    }
    _ = h1; _ = h2
}

/// Find Bezier parameter t where x(t) == target. Mirrors `findzero` over cubic Bernstein form.
private func findZero(_ x: Double, _ q0: Double, _ q1: Double, _ q2: Double, _ q3: Double) -> Double? {
    let c0 = q0 - x
    let c1 = 3.0 * (q1 - q0)
    let c2 = 3.0 * (q0 - 2.0 * q1 + q2)
    let c3 = q3 - q0 + 3.0 * (q1 - q2)
    return solveCubicInUnitInterval(c0, c1, c2, c3)
}

/// Evaluate cubic Bernstein polynomial at parameter t. Mirrors `berekeny`.
private func bereKeny(_ f1: Double, _ f2: Double, _ f3: Double, _ f4: Double, t: Double) -> Double {
    let c0 = f1
    let c1 = 3.0 * (f2 - f1)
    let c2 = 3.0 * (f1 - 2.0 * f2 + f3)
    let c3 = f4 - f1 + 3.0 * (f2 - f3)
    return c0 + t * (c1 + t * (c2 + t * c3))
}

/// Solve `c0 + c1·t + c2·t² + c3·t³ = 0` and return a root in [SMALL, 1.000001]. Mirrors `solve_cubic`.
private let kSmall: Double = -1.0e-10

private func solveCubicInUnitInterval(_ c0: Double, _ c1: Double, _ c2: Double, _ c3: Double) -> Double? {
    if c3 != 0 {
        var a = c2 / c3
        let b = c1 / c3
        let c = c0 / c3
        a = a / 3
        let p = b / 3 - a * a
        let q = (2 * a * a * a - a * b + c) / 2
        let d = q * q + p * p * p

        if d > 0 {
            let t = sqrt(d)
            let r = cbrt(-q + t) + cbrt(-q - t) - a
            return inUnit(r)
        }
        if d == 0 {
            let t = cbrt(-q)
            let r1 = 2 * t - a
            if let v = inUnit(r1) { return v }
            return inUnit(-t - a)
        }
        let phi = acos(-q / sqrt(-(p * p * p)))
        let tt = sqrt(-p)
        let cp = cos(phi / 3)
        let sq = sqrt(3 - 3 * cp * cp)
        let r1 = 2 * tt * cp - a
        if let v = inUnit(r1) { return v }
        let r2 = -tt * (cp + sq) - a
        if let v = inUnit(r2) { return v }
        return inUnit(-tt * (cp - sq) - a)
    }

    // Quadratic
    let a = c2, b = c1, c = c0
    if a != 0 {
        let p = b * b - 4 * a * c
        if p > 0 {
            let sp = sqrt(p)
            let r1 = (-b - sp) / (2 * a)
            if let v = inUnit(r1) { return v }
            return inUnit((-b + sp) / (2 * a))
        }
        if p == 0 { return inUnit(-b / (2 * a)) }
        return nil
    }
    if b != 0 { return inUnit(-c / b) }
    if c == 0 { return 0 }
    return nil
}

@inline(__always)
private func inUnit(_ r: Double) -> Double? {
    (r >= kSmall && r <= 1.000001) ? r : nil
}

// MARK: - Easing (port of BLI_easing_*, all signatures: time, begin, change, duration, [extras])

enum BlenderEasing {
    static func linear(_ time: Double, _ begin: Double, _ change: Double, _ duration: Double) -> Double {
        change * time / duration + begin
    }

    // back
    static func backIn(_ time: Double, _ begin: Double, _ change: Double, _ duration: Double, _ overshoot: Double) -> Double {
        let t = time / duration
        return change * t * t * ((overshoot + 1) * t - overshoot) + begin
    }
    static func backOut(_ time: Double, _ begin: Double, _ change: Double, _ duration: Double, _ overshoot: Double) -> Double {
        let t = time / duration - 1
        return change * (t * t * ((overshoot + 1) * t + overshoot) + 1) + begin
    }
    static func backInOut(_ time: Double, _ begin: Double, _ change: Double, _ duration: Double, _ overshootIn: Double) -> Double {
        let overshoot = overshootIn * 1.525
        var t = time / (duration / 2)
        if t < 1 { return change / 2 * (t * t * ((overshoot + 1) * t - overshoot)) + begin }
        t -= 2
        return change / 2 * (t * t * ((overshoot + 1) * t + overshoot) + 2) + begin
    }

    // bounce
    static func bounceOut(_ time: Double, _ begin: Double, _ change: Double, _ duration: Double) -> Double {
        var t = time / duration
        if t < 1 / 2.75 { return change * (7.5625 * t * t) + begin }
        if t < 2 / 2.75 { t -= 1.5 / 2.75; return change * ((7.5625 * t) * t + 0.75) + begin }
        if t < 2.5 / 2.75 { t -= 2.25 / 2.75; return change * ((7.5625 * t) * t + 0.9375) + begin }
        t -= 2.625 / 2.75
        return change * ((7.5625 * t) * t + 0.984375) + begin
    }
    static func bounceIn(_ time: Double, _ begin: Double, _ change: Double, _ duration: Double) -> Double {
        change - bounceOut(duration - time, 0, change, duration) + begin
    }
    static func bounceInOut(_ time: Double, _ begin: Double, _ change: Double, _ duration: Double) -> Double {
        if time < duration / 2 { return bounceIn(time * 2, 0, change, duration) * 0.5 + begin }
        return bounceOut(time * 2 - duration, 0, change, duration) * 0.5 + change * 0.5 + begin
    }

    // circ
    static func circIn(_ time: Double, _ begin: Double, _ change: Double, _ duration: Double) -> Double {
        let t = time / duration
        return -change * (sqrt(1 - t * t) - 1) + begin
    }
    static func circOut(_ time: Double, _ begin: Double, _ change: Double, _ duration: Double) -> Double {
        let t = time / duration - 1
        return change * sqrt(1 - t * t) + begin
    }
    static func circInOut(_ time: Double, _ begin: Double, _ change: Double, _ duration: Double) -> Double {
        var t = time / (duration / 2)
        if t < 1 { return -change / 2 * (sqrt(1 - t * t) - 1) + begin }
        t -= 2
        return change / 2 * (sqrt(1 - t * t) + 1) + begin
    }

    // cubic
    static func cubicIn(_ time: Double, _ begin: Double, _ change: Double, _ duration: Double) -> Double {
        let t = time / duration; return change * t * t * t + begin
    }
    static func cubicOut(_ time: Double, _ begin: Double, _ change: Double, _ duration: Double) -> Double {
        let t = time / duration - 1; return change * (t * t * t + 1) + begin
    }
    static func cubicInOut(_ time: Double, _ begin: Double, _ change: Double, _ duration: Double) -> Double {
        var t = time / (duration / 2)
        if t < 1 { return change / 2 * t * t * t + begin }
        t -= 2
        return change / 2 * (t * t * t + 2) + begin
    }

    // elastic
    private static func elasticBlend(_ time: Double, _ change: Double, _ duration: Double,
                                     _ amplitude: Double, _ s: Double, _ fIn: Double) -> Double {
        var f = fIn
        if change != 0 {
            let t = abs(s)
            if amplitude != 0 { f *= amplitude / abs(change) } else { f = 0 }
            if abs(time * duration) < t {
                let l = abs(time * duration) / t
                f = (f * l) + (1 - l)
            }
        }
        return f
    }
    static func elasticIn(_ time: Double, _ begin: Double, _ change: Double, _ duration: Double,
                          _ amplitudeIn: Double, _ periodIn: Double) -> Double {
        if time == 0 { return begin }
        var t = time / duration
        if t == 1 { return begin + change }
        t -= 1
        var period = periodIn == 0 ? duration * 0.3 : periodIn
        var amplitude = amplitudeIn
        let s: Double
        var f = 1.0
        if amplitude == 0 || amplitude < abs(change) {
            s = period / 4
            f = elasticBlend(t, change, duration, amplitude, s, f)
            amplitude = change
        } else {
            s = period / (2 * .pi) * asin(change / amplitude)
        }
        _ = period
        return -f * (amplitude * pow(2, 10 * t) * sin((t * duration - s) * (2 * .pi) / period)) + begin
    }
    static func elasticOut(_ time: Double, _ begin: Double, _ change: Double, _ duration: Double,
                           _ amplitudeIn: Double, _ periodIn: Double) -> Double {
        if time == 0 { return begin }
        var t = time / duration
        if t == 1 { return begin + change }
        t = -t
        var period = periodIn == 0 ? duration * 0.3 : periodIn
        var amplitude = amplitudeIn
        let s: Double
        var f = 1.0
        if amplitude == 0 || amplitude < abs(change) {
            s = period / 4
            f = elasticBlend(t, change, duration, amplitude, s, f)
            amplitude = change
        } else {
            s = period / (2 * .pi) * asin(change / amplitude)
        }
        _ = period
        return f * (amplitude * pow(2, 10 * t) * sin((t * duration - s) * (2 * .pi) / period)) + change + begin
    }
    static func elasticInOut(_ time: Double, _ begin: Double, _ change: Double, _ duration: Double,
                             _ amplitudeIn: Double, _ periodIn: Double) -> Double {
        if time == 0 { return begin }
        var t = time / (duration / 2)
        if t == 2 { return begin + change }
        t -= 1
        var period = periodIn == 0 ? duration * (0.3 * 1.5) : periodIn
        var amplitude = amplitudeIn
        let s: Double
        var f = 1.0
        if amplitude == 0 || amplitude < abs(change) {
            s = period / 4
            f = elasticBlend(t, change, duration, amplitude, s, f)
            amplitude = change
        } else {
            s = period / (2 * .pi) * asin(change / amplitude)
        }
        _ = period
        if t < 0 {
            f *= -0.5
            return f * (amplitude * pow(2, 10 * t) * sin((t * duration - s) * (2 * .pi) / period)) + begin
        }
        t = -t
        f *= 0.5
        return f * (amplitude * pow(2, 10 * t) * sin((t * duration - s) * (2 * .pi) / period)) + change + begin
    }

    // expo
    private static let powMin: Double = 0.0009765625      // 2^-10
    private static let powScale: Double = 1 / (1 - 0.0009765625)
    static func expoIn(_ time: Double, _ begin: Double, _ change: Double, _ duration: Double) -> Double {
        if time == 0 { return begin }
        return change * (pow(2, 10 * (time / duration - 1)) - powMin) * powScale + begin
    }
    static func expoOut(_ time: Double, _ begin: Double, _ change: Double, _ duration: Double) -> Double {
        if time == 0 { return begin }
        return change * (1 - (pow(2, -10 * time / duration) - powMin) * powScale) + begin
    }
    static func expoInOut(_ time: Double, _ begin: Double, _ change: Double, _ duration: Double) -> Double {
        let dh = duration / 2, ch = change / 2
        if time <= dh { return expoIn(time, begin, ch, dh) }
        return expoOut(time - dh, begin + ch, ch, dh)
    }

    // quad
    static func quadIn(_ time: Double, _ begin: Double, _ change: Double, _ duration: Double) -> Double {
        let t = time / duration; return change * t * t + begin
    }
    static func quadOut(_ time: Double, _ begin: Double, _ change: Double, _ duration: Double) -> Double {
        let t = time / duration; return -change * t * (t - 2) + begin
    }
    static func quadInOut(_ time: Double, _ begin: Double, _ change: Double, _ duration: Double) -> Double {
        var t = time / (duration / 2)
        if t < 1 { return change / 2 * t * t + begin }
        t -= 1
        return -change / 2 * (t * (t - 2) - 1) + begin
    }

    // quart
    static func quartIn(_ time: Double, _ begin: Double, _ change: Double, _ duration: Double) -> Double {
        let t = time / duration; return change * t * t * t * t + begin
    }
    static func quartOut(_ time: Double, _ begin: Double, _ change: Double, _ duration: Double) -> Double {
        let t = time / duration - 1; return -change * (t * t * t * t - 1) + begin
    }
    static func quartInOut(_ time: Double, _ begin: Double, _ change: Double, _ duration: Double) -> Double {
        var t = time / (duration / 2)
        if t < 1 { return change / 2 * t * t * t * t + begin }
        t -= 2
        return -change / 2 * (t * t * t * t - 2) + begin
    }

    // quint
    static func quintIn(_ time: Double, _ begin: Double, _ change: Double, _ duration: Double) -> Double {
        let t = time / duration; return change * t * t * t * t * t + begin
    }
    static func quintOut(_ time: Double, _ begin: Double, _ change: Double, _ duration: Double) -> Double {
        let t = time / duration - 1; return change * (t * t * t * t * t + 1) + begin
    }
    static func quintInOut(_ time: Double, _ begin: Double, _ change: Double, _ duration: Double) -> Double {
        var t = time / (duration / 2)
        if t < 1 { return change / 2 * t * t * t * t * t + begin }
        t -= 2
        return change / 2 * (t * t * t * t * t + 2) + begin
    }

    // sine
    static func sineIn(_ time: Double, _ begin: Double, _ change: Double, _ duration: Double) -> Double {
        -change * cos(time / duration * .pi / 2) + change + begin
    }
    static func sineOut(_ time: Double, _ begin: Double, _ change: Double, _ duration: Double) -> Double {
        change * sin(time / duration * .pi / 2) + begin
    }
    static func sineInOut(_ time: Double, _ begin: Double, _ change: Double, _ duration: Double) -> Double {
        -change / 2 * (cos(.pi * time / duration) - 1) + begin
    }
}
