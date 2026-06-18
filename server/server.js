const express = require('express');
const http = require('http');
const path = require('path');
const { Server } = require('socket.io');

const app = express();
const server = http.createServer(app);
const io = new Server(server, {
  // Permite reconexiones correctamente
  pingTimeout: 30000,
  pingInterval: 10000
});

const PORT = process.env.PORT || 3000;
const HOST = process.env.HOST || '0.0.0.0';
const POD_NAME = process.env.HOSTNAME || 'localhost';

// Estado: mapa socketId -> nombre
const usuarios = new Map();

// ── Servir cliente estático ──────────────────────────────────
// En Docker, el cliente estará en /app/client/
// En desarrollo local, estará en ../client/ relativo a server/
const clientDir = process.env.CLIENT_DIR ||
  (process.env.NODE_ENV === 'production'
    ? path.join(__dirname, 'client')
    : path.join(__dirname, '..', 'client'));

app.use(express.static(clientDir));

// ── Health check (para liveness/readiness probes) ────────────
app.get('/health', (_req, res) => {
  res.json({
    status: 'ok',
    timestamp: new Date().toISOString(),
    pod: POD_NAME,
    usuarios: usuarios.size,
    uptime: Math.floor(process.uptime())
  });
});

// ── Ruta raíz (por si acaso) ──────────────────────────────────
app.get('/', (_req, res) => {
  res.sendFile(path.join(clientDir, 'index.html'));
});

// ── WebSocket: lógica del chat ────────────────────────────────
io.on('connection', (socket) => {
  console.log(`[+] Cliente conectado: ${socket.id}`);

  // Registrar usuario con nombre
  socket.on('registrar', (nombre) => {
    if (typeof nombre !== 'string' || !nombre.trim()) return;
    const nombreSanitizado = nombre.trim().slice(0, 20);

    // Si ya estaba registrado (reconexión), actualizar nombre
    const nombreAnterior = usuarios.get(socket.id);
    usuarios.set(socket.id, nombreSanitizado);

    if (!nombreAnterior) {
      // Primera conexión: anunciar al resto
      socket.broadcast.emit('mensaje-sistema', `${nombreSanitizado} se ha conectado`);
    } else {
      console.log(`[*] ${socket.id} re-registrado como ${nombreSanitizado}`);
    }

    // Enviar lista actualizada a todos
    io.emit('usuarios-activos', Array.from(usuarios.values()));
    console.log(`[*] Usuario registrado: ${nombreSanitizado} | Total: ${usuarios.size}`);
  });

  // Reenviar mensaje a todos (broadcast)
  socket.on('mensaje', (texto) => {
    if (typeof texto !== 'string' || !texto.trim()) return;
    const nombre = usuarios.get(socket.id) || 'Anónimo';
    const msg = {
      nombre,
      texto: texto.trim().slice(0, 500), // limitar longitud
      hora: new Date().toLocaleTimeString('es-MX', { hour: '2-digit', minute: '2-digit' })
    };
    io.emit('mensaje', msg);
    console.log(`[MSG] ${nombre}: ${msg.texto.substring(0, 60)}`);
  });

  // Desconexión
  socket.on('disconnect', (reason) => {
    const nombre = usuarios.get(socket.id);
    if (nombre) {
      usuarios.delete(socket.id);
      socket.broadcast.emit('mensaje-sistema', `${nombre} se ha desconectado`);
      io.emit('usuarios-activos', Array.from(usuarios.values()));
      console.log(`[-] ${nombre} desconectado (${reason}) | Quedan: ${usuarios.size}`);
    }
  });
});

// ── Iniciar servidor ──────────────────────────────────────────
server.listen(PORT, HOST, () => {
  console.log(`╔════════════════════════════════════════╗`);
  console.log(`║  Chat Distribuido HA — Servidor        ║`);
  console.log(`╠════════════════════════════════════════╣`);
  console.log(`║  Escuchando en: ${HOST}:${PORT}         `);
  console.log(`║  Pod / Hostname: ${POD_NAME}           `);
  console.log(`║  Directorio cliente: ${clientDir}      `);
  console.log(`╚════════════════════════════════════════╝`);
});
