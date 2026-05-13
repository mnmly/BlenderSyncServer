/// Scene-level render and timeline metadata sent by the addon as `scene_update`.
///
/// Mirrors the dict produced by `snapshot_scene()` in the Blender addon.

import Foundation

/// Render resolution and frame-range info for the active Blender scene.
public struct SceneInfo: Sendable, Codable {
    /// Render resolution width in pixels (`scene.render.resolution_x`).
    public let resolutionWidth: Int
    /// Render resolution height in pixels (`scene.render.resolution_y`).
    public let resolutionHeight: Int
    /// Effective frame rate (`fps / fps_base`).
    public let frameRate: Double
    /// Inclusive timeline start (`scene.frame_start`).
    public let frameStart: Int
    /// Inclusive timeline end (`scene.frame_end`).
    public let frameEnd: Int
    /// Current playhead frame at the moment of snapshot (`scene.frame_current`).
    public let frameCurrent: Int

    /// Memberwise initializer.
    public init(resolutionWidth: Int, resolutionHeight: Int, frameRate: Double,
                frameStart: Int, frameEnd: Int, frameCurrent: Int) {
        self.resolutionWidth = resolutionWidth
        self.resolutionHeight = resolutionHeight
        self.frameRate = frameRate
        self.frameStart = frameStart
        self.frameEnd = frameEnd
        self.frameCurrent = frameCurrent
    }
}
