FROM docker.io/node:18-alpine

# Metadatos
LABEL maintainer="Sistemas Distribuidos"
LABEL description="Chat Distribuido con Alta Disponibilidad vía WebSockets"

WORKDIR /app

# 1. Instalar herramientas útiles y dependencias (capa cacheada si no cambia package.json)
RUN apk add --no-cache curl
COPY server/package.json .
RUN npm install --omit=dev && npm cache clean --force

# 2. Copiar el servidor
COPY server/server.js .

# 3. Copiar el cliente estático (ruta relativa a la raíz del proyecto)
COPY client/ ./client/

# Variables de entorno por defecto
ENV PORT=3000
ENV HOST=0.0.0.0
ENV NODE_ENV=production
ENV CLIENT_DIR=/app/client

EXPOSE 3000

# Healthcheck nativo de Docker (usar 127.0.0.1, no localhost,
# porque wget en alpine puede fallar resolviendo localhost a IPv6)
HEALTHCHECK --interval=15s --timeout=5s --start-period=5s --retries=3 \
  CMD wget -qO- http://127.0.0.1:3000/health || exit 1

CMD ["node", "server.js"]
