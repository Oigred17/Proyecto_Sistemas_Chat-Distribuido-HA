const express = require('express');
const http = require('http');
const path = require('path');
const { Server } = require('socket.io');

const app = express();
const server = http.createServer(app);
const io = new Server(server, {
  transports: ['websocket'],
  pingTimeout: 30000,
  pingInterval: 10000
});

const PORT = process.env.PORT || 3000;
const HOST = process.env.HOST || '0.0.0.0';
const POD_NAME = process.env.HOSTNAME || 'localhost';
const POD_UID = process.env.POD_UID || 'unknown';
const POD_ID = (POD_UID && POD_UID !== 'unknown') ? POD_UID.substring(0, 8) : POD_NAME.split('-').pop();
const REDIS_URL = process.env.REDIS_URL;

const NOMBRES_NODOS = {
  'chat-distribuido-0': 'Nodo 2 (Réplica Principal)',
  'chat-distribuido-1': 'Nodo 3 (Redundancia)',
};
const NODO_ROL = NOMBRES_NODOS[POD_NAME] || POD_NAME;

// ── Redis adapter (comparte estado entre pods) ──────────────
const { Redis } = require('ioredis');
const { createAdapter } = require('@socket.io/redis-adapter');
const USERS_KEY = 'chat:users';
let pubClient, subClient, redisState;

if (REDIS_URL) {
  pubClient = new Redis(REDIS_URL);
  subClient = new Redis(REDIS_URL);
  redisState = new Redis(REDIS_URL);
  io.adapter(createAdapter(pubClient, subClient));
  pubClient.on('connect', () => console.log(`[Redis] Conectado a ${REDIS_URL}`));
  pubClient.on('error', (err) => console.error(`[Redis] Error: ${err.message}`));
}

// Estado local (fallback sin Redis / caché local con Redis)
const usuarios = new Map();

async function uniqueUsers(vals) {
  return [...new Set(vals)];
}

async function getGlobalUsers() {
  if (!redisState) return Array.from(usuarios.values());
  return uniqueUsers(await redisState.hvals(USERS_KEY));
}

async function addGlobalUser(socketId, username) {
  usuarios.set(socketId, username);
  if (!redisState) return Array.from(usuarios.values());
  await redisState.hset(USERS_KEY, socketId, username);
  return uniqueUsers(await redisState.hvals(USERS_KEY));
}

async function removeGlobalUser(socketId) {
  const nombre = usuarios.get(socketId);
  usuarios.delete(socketId);
  if (!redisState) return [Array.from(usuarios.values()), nombre];
  await redisState.hdel(USERS_KEY, socketId);
  return [uniqueUsers(await redisState.hvals(USERS_KEY)), nombre];
}

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
    id: POD_ID,
    uid: POD_UID,
    nodo: NODO_ROL,
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
  socket.on('registrar', async (nombre) => {
    if (typeof nombre !== 'string' || !nombre.trim()) return;
    const nombreSanitizado = nombre.trim().slice(0, 20);

    const oldLocal = usuarios.get(socket.id);
    const allUsers = await addGlobalUser(socket.id, nombreSanitizado);

    if (!oldLocal) {
      socket.broadcast.emit('mensaje-sistema', `${nombreSanitizado} se ha conectado`);
    } else {
      console.log(`[*] ${socket.id} re-registrado como ${nombreSanitizado}`);
    }

    io.emit('usuarios-activos', allUsers);
    console.log(`[*] Usuario registrado: ${nombreSanitizado} | Total: ${allUsers.length}`);
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
  socket.on('disconnect', async (reason) => {
    const nombre = usuarios.get(socket.id);
    if (nombre) {
      const [allUsers] = await removeGlobalUser(socket.id);
      socket.broadcast.emit('mensaje-sistema', `${nombre} se ha desconectado`);
      io.emit('usuarios-activos', allUsers);
      console.log(`[-] ${nombre} desconectado (${reason}) | Quedan: ${allUsers.length}`);
    }
  });
});

// ── Iniciar servidor ──────────────────────────────────────────
server.listen(PORT, HOST, () => {
  console.log(`╔════════════════════════════════════════╗`);
  console.log(`║  Chat Distribuido HA — Servidor        ║`);
  console.log(`╠════════════════════════════════════════╣`);
  console.log(`║  Escuchando en: ${HOST}:${PORT}         `);
  console.log(`║  Pod: ${POD_NAME}                        `);
  console.log(`║  ID:  ${POD_ID}                         `);
  console.log(`║  Rol: ${NODO_ROL}                        `);
  console.log(`║  Directorio cliente: ${clientDir}      `);
  console.log(`╚════════════════════════════════════════╝`);
});
