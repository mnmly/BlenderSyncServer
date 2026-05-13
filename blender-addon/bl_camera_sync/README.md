# Blender Camera Sync Addon

A Blender addon for real-time camera synchronization with external applications via WebSocket.

## Features

- **Real-time Camera Sync**: Automatically sync camera position, rotation, and properties
- **WebSocket Connection**: Connect to any WebSocket server for real-time communication
- **Keyframe Support**: Sync camera animation keyframes
- **Auto-Reconnect**: Automatically reconnect when connection is lost
- **Rate Limiting**: Configurable sync rate to optimize performance
- **Connection Testing**: Test server connectivity before connecting

## Installation

1. Copy the `bl_camera_sync` folder to your Blender extensions directory
2. Enable the addon in Blender Preferences > Extensions
3. The addon will automatically install required dependencies (websockets)

## Usage

### Basic Setup

1. **Start your WebSocket server** (e.g., the Swift BlenderSyncServer)
2. **Open Blender** and go to the 3D Viewport
3. **Find the Camera Sync panel** in the sidebar (press `N` to show sidebar)
4. **Configure connection settings**:
   - Host: Server hostname (default: localhost)
   - Port: Server port (default: 8765)

### Connecting

1. **Test Connection**: Click "Test Connection" to verify server is reachable
2. **Connect**: Click "Connect" to establish WebSocket connection
3. **Status**: Monitor connection status in the panel

### Sync Settings

- **Auto Sync**: Automatically sync camera changes (recommended)
- **Sync Rate**: How often to sync per second (1-120 FPS)
- **Sync Keyframes**: Include animation keyframes in sync data
- **Auto Reconnect**: Automatically reconnect when connection is lost

### Manual Sync

When Auto Sync is disabled, use the "Send Camera Data" button to manually sync.

## Message Format

The addon sends camera data in this format:

```json
{
  "type": "cameraUpdate",
  "payload": {
    "name": "Camera.001",
    "location": [0.0, 0.0, 5.0],
    "rotation": [0.0, 0.0, 0.0],
    "scale": [1.0, 1.0, 1.0],
    "focal_length": 50.0,
    "sensor_width": 36.0,
    "clip_start": 0.1,
    "clip_end": 1000.0,
    "frame": 1,
    "keyframes": [...]
  },
  "timestamp": 1234567890.123
}
```

## Troubleshooting

### Connection Issues

1. **Check server is running**: Ensure your WebSocket server is active
2. **Verify port**: Make sure the port matches your server configuration
3. **Test connection**: Use the "Test Connection" button
4. **Check console**: Look for error messages in Blender's console

### Performance

- Lower sync rate if experiencing performance issues
- Disable keyframe sync for better performance
- Check network latency to server

### Dependencies

The addon automatically installs the `websockets` package. If installation fails:

1. Ensure Blender has internet access
2. Check Blender's Python environment
3. Manually install: `pip install websockets`

## Server Compatibility

This addon is designed to work with the Swift BlenderSyncServer but can connect to any WebSocket server that accepts JSON messages.

### Expected Server Endpoint

The addon connects to: `ws://host:port/ws`

### Message Types

The server should handle these message types:
- `cameraUpdate`: Camera position and property changes
- `sceneUpdate`: Scene-level updates

## Development

### File Structure

- `__init__.py`: Main addon code
- `utils.py`: Utility functions for package management
- `blender_manifest.toml`: Addon metadata and permissions
- `README.md`: This documentation

### Extending

To add new message types or features:

1. Update `get_camera_data()` to include new data
2. Modify `send_camera_data()` to format messages
3. Add new operators for custom functionality
4. Update the UI panel as needed

## License

GPL-2.0-or-later

## Support

For issues and questions, check the console output for error messages and ensure your WebSocket server is compatible with the expected message format.