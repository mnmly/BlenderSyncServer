# Debug WebSocket Server

A simple Socket.IO server for debugging WebSocket connections and testing real-time communication.

## Features

- 🔗 **Real-time connections** with Socket.IO
- 📨 **Message echoing** and broadcasting
- 🎥 **Camera update handling** (for Blender addon testing)
- 🎯 **Custom event support**
- 📊 **Client connection tracking**
- 🌐 **Built-in web interface** for testing
- 📡 **REST API endpoints** for server info

## Quick Start

```bash
# Install dependencies
npm install

# Start server
npm start

# Or start with auto-reload (development)
npm run dev
```

## Usage

### Web Interface
Open http://localhost:8765 in your browser for a built-in testing interface.

### REST Endpoints
- `GET /` - Web testing interface
- `GET /info` - Server and client information
- `GET /health` - Health check

### WebSocket Events

#### General Events
- `message` - Send/receive general messages
- `custom_event` - Send custom events with any name

#### Blender-Specific Events
- `camera_update` - Send camera data from Blender addon

## Testing with Blender

1. **Start the debug server**: `npm start`
2. **Update Blender addon** to connect to `localhost:8765`
3. **Monitor connections** in the web interface or server logs

## Example Messages

### General Message
```javascript
socket.emit('message', {
  type: 'test',
  data: 'Hello World',
  timestamp: Date.now()
});
```

### Camera Update (Blender)
```javascript
socket.emit('camera_update', {
  name: 'Camera.001',
  location: [0, 0, 5],
  rotation: [0, 0, 0],
  focal_length: 50
});
```

### Custom Event
```javascript
socket.emit('custom_event', 'scene_change', {
  scene: 'Scene.001',
  frame: 120
});
```

## Server Logs

The server logs all connections and messages:

```
🔗 Client connected: abc123 (Total: 1)
📨 Message from abc123: { type: 'test', data: 'hello' }
🎥 Camera update from abc123: { name: 'Camera', location: [0,0,5] }
❌ Client disconnected: abc123 (Reason: client disconnect, Messages sent: 5)
```

## Configuration

Set environment variables:
- `PORT` - Server port (default: 8765)

## API Reference

### Client Events (Incoming)
- `connect` - Client connected
- `disconnect` - Client disconnected  
- `message` - General message
- `camera_update` - Camera data
- `custom_event` - Custom event

### Server Events (Outgoing)
- `message` - Echo message back to sender
- `broadcast` - Broadcast message to other clients
- `camera_update` - Broadcast camera update
- `clientCount` - Current number of connected clients

## Development

```bash
# Install with dev dependencies
npm install

# Start with nodemon for auto-reload
npm run dev

# Check server info
curl http://localhost:8765/info
```

This debug server helps you test WebSocket connections, debug message formats, and validate real-time communication before integrating with production servers.