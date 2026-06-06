// Curve / spline geometry attached to CURVE objects in the object graph.
//
// The addon serializes a CURVE object's data-block under each object's `curve`
// field (see `_export_curve` / `_export_spline` in the Blender addon). This is
// the control geometry a Follow Path constraint evaluates against; unlike the
// camera's `CameraCurves` message (animation f-curves only), these are the
// actual splines (control points, handles, knots-basis inputs).
//
// All decoding uses the object graph's `.convertFromSnakeCase` strategy, so
// wire keys like `use_cyclic_u` map to `useCyclicU`. Coordinate arrays stay as
// flat `[Double]` to match the rest of the package (`ObjectBase`, matrices).

import Foundation

/// A CURVE object's data-block: its splines plus path/timing settings.
///
/// `usePath` / `pathDuration` / `evalTime` drive Follow Path timing; `splines`
/// is the control geometry. `fcurves` (source `"data"`) carries the animated
/// `eval_time` channel when the path is keyed.
public struct BlenderCurve: Codable, Sendable {
    /// `"2D"` or `"3D"`. A 2-D curve is planar (z fixed) but still a valid path.
    public let dimensions: String
    /// Preview/evaluation samples per segment (Blender `resolution_u`).
    public let resolutionU: Int
    /// Whether path animation is enabled (Blender `use_path`).
    public let usePath: Bool
    /// Length of the path animation in frames (Blender `path_duration`).
    public let pathDuration: Int
    /// Current path evaluation time in frames (Blender `eval_time`); the static
    /// value, overridden per-frame by the `eval_time` f-curve when present.
    public let evalTime: Double
    public let bevelDepth: Double
    public let extrude: Double
    /// The control splines. A curve data-block may hold several.
    public let splines: [BlenderSpline]
    /// Data-block f-curves (source `"data"`), notably the animated `eval_time`.
    public let fcurves: [FCurve]

    /// Look up a data-block f-curve by data_path + array_index.
    public func fcurve(dataPath: String, arrayIndex: Int = 0) -> FCurve? {
        fcurves.first { $0.dataPath == dataPath && $0.arrayIndex == arrayIndex }
    }

    /// `eval_time` at `frame`: the animated `eval_time` f-curve if keyed, else
    /// the static ``evalTime``. This is Blender's path position in frame units;
    /// divide by ``pathDuration`` for a normalized `0…1` factor.
    public func evaluatedEvalTime(atFrame frame: Double) -> Double {
        fcurve(dataPath: "eval_time")?.evaluate(at: frame) ?? evalTime
    }
}

/// One spline within a ``BlenderCurve``.
///
/// Geometry is split by ``type``: BEZIER splines populate ``bezierPoints`` (with
/// handles); POLY and NURBS populate ``points`` (4-D `co` carrying the rational
/// weight, plus an explicit ``SplinePoint/weight``). The knot-basis inputs
/// (``orderU``, ``useEndpointU``, ``useCyclicU``, ``useBezierU``) are what a
/// consumer needs to reproduce Blender's knot vector for NURBS evaluation.
public struct BlenderSpline: Codable, Sendable {
    /// `"POLY"`, `"BEZIER"`, or `"NURBS"`. Kept as the raw string (rather than a
    /// strict enum) so an unfamiliar value never breaks decoding.
    public let type: String
    public let useCyclicU: Bool
    public let resolutionU: Int
    /// NURBS basis order (`degree + 1`); benign for POLY/BEZIER.
    public let orderU: Int
    /// NURBS clamps to its end points when true (Blender `use_endpoint_u`).
    public let useEndpointU: Bool
    /// NURBS uses a Bézier-style knot vector when true (Blender `use_bezier_u`).
    public let useBezierU: Bool
    /// Present for BEZIER splines: control points with handles.
    public let bezierPoints: [BezierPoint]?
    /// Present for POLY / NURBS splines: control points (4-D `co`).
    public let points: [SplinePoint]?
}

/// A BEZIER control point: an anchor (`co`, 3-D) plus its two handles.
public struct BezierPoint: Codable, Sendable {
    /// Anchor position `[x, y, z]`, curve-local space.
    public let co: [Double]
    public let handleLeft: [Double]
    public let handleRight: [Double]
    /// Blender handle types, e.g. `"FREE"`, `"ALIGNED"`, `"VECTOR"`, `"AUTO"`.
    public let handleLeftType: String
    public let handleRightType: String
    public let tilt: Double
    public let radius: Double
}

/// A POLY or NURBS control point.
public struct SplinePoint: Codable, Sendable {
    /// Homogeneous position `[x, y, z, w]`; `w` is the legacy rational weight.
    public let co: [Double]
    public let tilt: Double
    public let radius: Double
    /// The NURBS rational weight used in evaluation (Blender `point.weight`).
    public let weight: Double

    /// The Cartesian position `[x, y, z]` (first three components of ``co``).
    public var position: [Double] { Array(co.prefix(3)) }
}
