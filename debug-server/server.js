const express = require('express');
const { createServer } = require('http');
const { Server } = require('socket.io');

const app = express();
const httpServer = createServer(app);
const io = new Server(httpServer, {
  cors: {
    origin: "*",
    methods: ["GET", "POST"]
  }
});

const PORT = process.env.PORT || 8765;

// Store connected clients
const clients = new Map();

// Serve a simple test page
app.get('/', (req, res) => {
  res.send(`
    <!DOCTYPE html>
    <html>
    <head>
        <title>WebSocket Debug Server</title>
        <style>
            body { font-family: Arial, sans-serif; margin: 40px; }
            .container { max-width: 800px; }
            .log { background: #f5f5f5; padding: 10px; border-radius: 5px; height: 300px; overflow-y: scroll; margin: 10px 0; }
            .controls { margin: 10px 0; }
            input, button { margin: 5px; padding: 8px; }
            .stats { background: #e3f2fd; padding: 10px; border-radius: 5px; margin: 10px 0; }
        </style>
        <script src="/socket.io/socket.io.js"></script>
    </head>
    <body>
        <div class="container">
            <h1>WebSocket Debug Server</h1>
            <div class="stats">
                <strong>Status:</strong> <span id="status">Disconnected</span><br>
                <strong>Connected Clients:</strong> <span id="clientCount">0</span><br>
                <strong>Server:</strong> ws://localhost:${PORT}
            </div>
            
            <div class="controls">
                <button onclick="connect()">Connect</button>
                <button onclick="disconnect()">Disconnect</button>
                <button onclick="clearLog()">Clear Log</button>
            </div>
            
            <div class="controls">
                <input type="text" id="messageInput" placeholder="Enter message to send" style="width: 300px;">
                <button onclick="sendMessage()">Send Message</button>
            </div>
            
            <div id="log" class="log"></div>
        </div>

        <script>
            let socket = null;
            
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
                if (socket) return;
                
                socket = io();
                
                socket.on('connect', () => {
                    log('Connected to server', 'info');
                    updateStatus('Connected');
                });
                
                socket.on('disconnect', () => {
                    log('Disconnected from server', 'error');
                    updateStatus('Disconnected');
                    socket = null;
                });
                
                socket.on('message', (data) => {
                    log(\`Received: \${JSON.stringify(data)}\`, 'received');
                });
                
                socket.on('clientCount', (count) => {
                    document.getElementById('clientCount').textContent = count;
                });
                
                socket.on('broadcast', (data) => {
                    log(\`Broadcast: \${JSON.stringify(data)}\`, 'received');
                });
            }
            
            function disconnect() {
                if (socket) {
                    socket.disconnect();
                    socket = null;
                }
            }
            
            function sendMessage() {
                if (!socket) {
                    log('Not connected!', 'error');
                    return;
                }
                
                const input = document.getElementById('messageInput');
                const message = input.value.trim();
                
                if (!message) return;
                
                try {
                    // Try to parse as JSON, fallback to plain text
                    const data = message.startsWith('{') ? JSON.parse(message) : { text: message };
                    socket.emit('message', data);
                    log(\`Sent: \${JSON.stringify(data)}\`, 'sent');
                    input.value = '';
                } catch (e) {
                    log(\`Error sending message: \${e.message}\`, 'error');
                }
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

// Socket.IO connection handling
io.on('connection', (socket) => {
  const clientInfo = {
    id: socket.id,
    connectedAt: new Date(),
    messageCount: 0
  };
  
  clients.set(socket.id, clientInfo);
  
  console.log(`🔗 Client connected: ${socket.id} (Total: ${clients.size})`);
  
  // Broadcast client count to all clients
  io.emit('clientCount', clients.size);

  // Handle incoming messages
  socket.on('message', (data) => {
    clientInfo.messageCount++;
    
    console.log(`📨 Message from ${socket.id}:`, data);
    
    // Echo the message back to sender
    socket.emit('message', {
      type: 'echo',
      originalMessage: data,
      timestamp: new Date().toISOString(),
      clientId: socket.id
    });
    
    // Broadcast to all other clients
    socket.broadcast.emit('broadcast', {
      type: 'broadcast',
      message: data,
      from: socket.id,
      timestamp: new Date().toISOString()
    });
  });

  // Handle camera updates specifically (for Blender addon)
  socket.on('camera_update', (data) => {
    console.log(`🎥 Camera update from ${socket.id}:`, data);
    
    // Broadcast camera update to all other clients
    socket.broadcast.emit('camera_update', {
      ...data,
      from: socket.id,
      receivedAt: new Date().toISOString()
    });
  });

  // Handle custom events
  socket.on('custom_event', (eventName, data) => {
    console.log(`🎯 Custom event '${eventName}' from ${socket.id}:`, data);
    
    // Broadcast custom event
    socket.broadcast.emit('custom_event', eventName, {
      ...data,
      from: socket.id
    });
  });

  // Handle disconnection
  socket.on('disconnect', (reason) => {
    const client = clients.get(socket.id);
    if (client) {
      console.log(`❌ Client disconnected: ${socket.id} (Reason: ${reason}, Messages sent: ${client.messageCount})`);
      clients.delete(socket.id);
      
      // Update client count
      io.emit('clientCount', clients.size);
    }
  });

  // Handle errors
  socket.on('error', (error) => {
    console.error(`💥 Socket error from ${socket.id}:`, error);
  });
});

// Server info endpoint
app.get('/info', (req, res) => {
  res.json({
    server: 'Debug WebSocket Server',
    port: PORT,
    connectedClients: clients.size,
    clients: Array.from(clients.entries()).map(([id, info]) => ({
      id,
      connectedAt: info.connectedAt,
      messageCount: info.messageCount
    })),
    uptime: process.uptime()
  });
});

// Health check
app.get('/health', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

// Start server
httpServer.listen(PORT, () => {
  console.log(`🚀 Debug WebSocket Server running on http://localhost:${PORT}`);
  console.log(`📊 Server info: http://localhost:${PORT}/info`);
  console.log(`🏥 Health check: http://localhost:${PORT}/health`);
  console.log('');
  console.log('📡 WebSocket Events:');
  console.log('   - message: General message handling');
  console.log('   - camera_update: Camera data from Blender');
  console.log('   - custom_event: Custom event broadcasting');
  console.log('');
  console.log('🔧 Test with:');
  console.log(`   curl http://localhost:${PORT}/info`);
  console.log(`   Open browser: http://localhost:${PORT}`);
});