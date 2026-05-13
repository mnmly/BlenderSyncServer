const WebSocket = require('ws');
const express = require('express');
const { createServer } = require('http');

const app = express();
const server = createServer(app);
const PORT = process.env.PORT || 8765;

// Create WebSocket server
const wss = new WebSocket.Server({ 
  server,
  path: '/ws' // Match the path your Blender addon expects
});

// Store connected clients
const clients = new Set();

// Serve a simple test page
app.get('/', (req, res) => {
  res.send(`
    <!DOCTYPE html>
    <html>
    <head>
        <title>Raw WebSocket Debug Server</title>
        <style>
            body { font-family: Arial, sans-serif; margin: 40px; }
            .container { max-width: 800px; }
            .log { background: #f5f5f5; padding: 10px; border-radius: 5px; height: 300px; overflow-y: scroll; margin: 10px 0; }
            .controls { margin: 10px 0; }
            input, button { margin: 5px; padding: 8px; }
            .stats { background: #e3f2fd; padding: 10px; border-radius: 5px; margin: 10px 0; }
        </style>
    </head>
    <body>
        <div class="container">
            <h1>Raw WebSocket Debug Server</h1>
            <div class="stats">
                <strong>Status:</strong> <span id="status">Disconnected</span><br>
                <strong>Connected Clients:</strong> <span id="clientCount">${clients.size}</span><br>
                <strong>WebSocket URL:</strong> ws://localhost:${PORT}/ws
            </div>
            
            <div class="controls">
                <button onclick="connect()">Connect</button>
                <button onclick="disconnect()">Disconnect</button>
                <button onclick="clearLog()">Clear Log</button>
            </div>
            
            <div class="controls">
                <input type="text" id="messageInput" placeholder="Enter JSON message" style="width: 400px;">
                <button onclick="sendMessage()">Send Message</button>
            </div>
            
            <div class="controls">
                <button onclick="sendCameraUpdate()">Send Test Camera Update</button>
                <button onclick="sendPing()">Send Ping</button>
            </div>
            
            <div id="log" class="log"></div>
        </div>

        <script>
            let ws = null;
            
            function log(message, type = 'info') {
                const logDiv = document.getElementById('log');
                const timestamp = new Date().toLocaleTimeString();
                const color = type === 'error' ? 'red' : type === 'sent' ? 'blue' : type === 'received' ? 'green' : 'black';
                logDiv.innerHTML += \`<div style="color: \${color}">[\${timestamp}] \${message}</div>\`;
                logDiv.scrollTop = logDiv.scrollHeight;
            }
            
            function updateStatus(status) {
                document.getElementById('status').textContent = status;
                document.getElementById('status').style.color = status === 'Connected' ? 'green' : 'red';
            }
            
            function connect() {
                if (ws) return;
                
                ws = new WebSocket('ws://localhost:${PORT}/ws');
                
                ws.onopen = () => {
                    log('✅ Connected to WebSocket server', 'info');
                    updateStatus('Connected');
                };
                
                ws.onclose = () => {
                    log('❌ Disconnected from WebSocket server', 'error');
                    updateStatus('Disconnected');
                    ws = null;
                };
                
                ws.onmessage = (event) => {
                    try {
                        const data = JSON.parse(event.data);
                        log(\`📨 Received: \${JSON.stringify(data, null, 2)}\`, 'received');
                    } catch (e) {
                        log(\`📨 Received (text): \${event.data}\`, 'received');
                    }
                };
                
                ws.onerror = (error) => {
                    log(\`💥 WebSocket error: \${error}\`, 'error');
                };
            }
            
            function disconnect() {
                if (ws) {
                    ws.close();
                    ws = null;
                }
            }
            
            function sendMessage() {
                if (!ws || ws.readyState !== WebSocket.OPEN) {
                    log('❌ Not connected!', 'error');
                    return;
                }
                
                const input = document.getElementById('messageInput');
                const message = input.value.trim();
                
                if (!message) return;
                
                try {
                    // Try to parse as JSON to validate
                    const data = JSON.parse(message);
                    ws.send(message);
                    log(\`📤 Sent: \${message}\`, 'sent');
                    input.value = '';
                } catch (e) {
                    log(\`❌ Invalid JSON: \${e.message}\`, 'error');
                }
            }
            
            function sendCameraUpdate() {
                if (!ws || ws.readyState !== WebSocket.OPEN) {
                    log('❌ Not connected!', 'error');
                    return;
                }
                
                const cameraData = {
                    name: "Camera.001",
                    location: [Math.random() * 10 - 5, Math.random() * 10 - 5, Math.random() * 10 + 2],
                    rotation: [Math.random(), Math.random(), Math.random()],
                    scale: [1, 1, 1],
                    focal_length: 50.0,
                    sensor_width: 36.0,
                    clip_start: 0.1,
                    clip_end: 1000.0,
                    frame: Math.floor(Math.random() * 250) + 1
                };
                
                const message = {
                    type: "camera_update",
                    payload: btoa(JSON.stringify(cameraData)), // base64 encode like Blender
                    timestamp: Date.now() / 1000
                };
                
                ws.send(JSON.stringify(message));
                log(\`📤 Sent camera update: \${JSON.stringify(message, null, 2)}\`, 'sent');
            }
            
            function sendPing() {
                if (!ws || ws.readyState !== WebSocket.OPEN) {
                    log('❌ Not connected!', 'error');
                    return;
                }
                
                const ping = { type: "ping", timestamp: Date.now() / 1000 };
                ws.send(JSON.stringify(ping));
                log(\`📤 Sent ping\`, 'sent');
            }
            
            function clearLog() {
                document.getElementById('log').innerHTML = '';
            }
            
            // Allow Enter key to send message
            document.getElementById('messageInput').addEventListener('keypress', (e) => {
                if (e.key === 'Enter') sendMessage();
            });
        </script>
    </body>
    </html>
  `);
});

// WebSocket connection handling
wss.on('connection', (ws, request) => {
  const clientId = Math.random().toString(36).substr(2, 9);
  let messageCount = 0;
  
  clients.add(ws);
  
  console.log(`🔗 WebSocket client connected: ${clientId} (Total: ${clients.size})`);
  console.log(`   User-Agent: ${request.headers['user-agent'] || 'Unknown'}`);
  console.log(`   Origin: ${request.headers.origin || 'Unknown'}`);

  // Send welcome message
  ws.send(JSON.stringify({
    type: 'welcome',
    message: 'Connected to debug WebSocket server',
    clientId: clientId,
    timestamp: Date.now() / 1000
  }));

  // Handle incoming messages
  ws.on('message', (data) => {
    messageCount++;
    
    try {
      const message = JSON.parse(data.toString());
      console.log(`📨 Message from ${clientId}:`, message);
      
      // Handle different message types
      switch (message.type) {
        case 'camera_update':
          console.log(`🎥 Camera update from ${clientId}`);
          if (message.payload) {
            console.log(`   Payload: ${message.payload.length}`);
            try {
              // Decode base64 payload
              const decoded = Buffer.from(message.payload, 'base64').toString('utf-8');
              const cameraData = JSON.parse(decoded);
              console.log(`   Camera: ${cameraData.name}, Location: [${cameraData.location?.join(', ')}]`);
              console.log(`   Camera: ${cameraData.name}, Location: [${cameraData.baked_keyframes?.join(', ')}]`);
            } catch (e) {
              console.log(`   Could not decode payload: ${e.message}`);
            }
          }
          break;
          
        case 'ping':
          console.log(`🏓 Ping from ${clientId}`);
          ws.send(JSON.stringify({
            type: 'pong',
            timestamp: Date.now() / 1000
          }));
          break;
          
        default:
          console.log(`📨 Generic message from ${clientId}: ${message.type || 'no type'}`);
      }
      
      // Echo message back to sender
      ws.send(JSON.stringify({
        type: 'echo',
        originalMessage: message,
        clientId: clientId,
        timestamp: Date.now() / 1000
      }));
      
      // Broadcast to all other clients
      const broadcast = {
        type: 'broadcast',
        message: message,
        from: clientId,
        timestamp: Date.now() / 1000
      };
      
      clients.forEach(client => {
        if (client !== ws && client.readyState === WebSocket.OPEN) {
          client.send(JSON.stringify(broadcast));
        }
      });
      
    } catch (error) {
      console.log(`📨 Non-JSON message from ${clientId}: ${data.toString().substring(0, 100)}...`);
      
      // Send error response
      ws.send(JSON.stringify({
        type: 'error',
        message: 'Invalid JSON format',
        received: data.toString().substring(0, 100),
        timestamp: Date.now() / 1000
      }));
    }
  });

  // Handle close
  ws.on('close', (code, reason) => {
    clients.delete(ws);
    console.log(`❌ WebSocket client disconnected: ${clientId} (Code: ${code}, Reason: ${reason.toString()}, Messages: ${messageCount})`);
    console.log(`   Remaining clients: ${clients.size}`);
  });

  // Handle errors
  ws.on('error', (error) => {
    console.error(`💥 WebSocket error from ${clientId}:`, error);
  });
});

// Server info endpoint
app.get('/info', (req, res) => {
  res.json({
    server: 'Raw WebSocket Debug Server',
    port: PORT,
    websocketPath: '/ws',
    connectedClients: clients.size,
    protocol: 'ws',
    uptime: process.uptime()
  });
});

// Health check
app.get('/health', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

// Start server
server.listen(PORT, () => {
  console.log(`🚀 Raw WebSocket Debug Server running on http://localhost:${PORT}`);
  console.log(`🔌 WebSocket endpoint: ws://localhost:${PORT}/ws`);
  console.log(`📊 Server info: http://localhost:${PORT}/info`);
  console.log(`🏥 Health check: http://localhost:${PORT}/health`);
  console.log('');
  console.log('🔧 Test WebSocket connection:');
  console.log(`   Browser: http://localhost:${PORT}`);
  console.log(`   Command line: wscat -c ws://localhost:${PORT}/ws`);
  console.log('');
  console.log('📡 Supported message types:');
  console.log('   - camera_update: Blender camera data');
  console.log('   - ping: Connection test');
  console.log('   - Any JSON: General messages');
});