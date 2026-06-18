# Proyecto Ordinario — Sistemas Distribuidos y Alta Disponibilidad

## Resumen del Proyecto

**Sistema:** Chat distribuido en tiempo real con tolerancia a fallos  
**Tecnologías:** Node.js · Express · Socket.io · Podman · Kubernetes (MicroShift)  
**Arquitectura:** Cliente-Servidor distribuido con múltiples réplicas

---

## Estado del Proyecto

| Componente | Archivo |
|-----------|---------|--------|
| Cliente Web | `client/index.html` |
| Servidor Node.js | `server/server.js` |
| Dockerfile | `server/Dockerfile` |
| Manifiestos K8s | `k8s/deployment.yaml` |
| Script despliegue | `deploy.sh` |
| Manual despliegue | `docs/manual-despliegue.md` |
| Guía instalación | `docs/instalacion.md` |
| Diagramas | `docs/diagramas.md` |

---

## Cómo Ejecutar

### Desarrollo Local (más rápido para demostrar)
```bash
cd ~/Documentos/Proyecto_Sistemas
node server/server.js
# Abrir: http://localhost:3000
```

### Con Podman (contenedor)
```bash
cd ~/Documentos/Proyecto_Sistemas
podman build -t chat-distribuido:latest -f server/Dockerfile .
podman run -p 3000:3000 chat-distribuido:latest
```

### Con MicroShift (Kubernetes)
```bash
./deploy.sh
# O manualmente:
oc apply -f k8s/deployment.yaml
oc port-forward -n chat-ha svc/chat-distribuido-svc 8080:80
```

---

## Características Implementadas

### Funcionales
- [x] Chat en tiempo real con WebSockets (Socket.io)
- [x] Múltiples usuarios simultáneos
- [x] Lista de usuarios en línea en tiempo real
- [x] Notificaciones de conexión/desconexión
- [x] **Reconexión automática** del cliente (tolera caídas del pod)
- [x] Endpoint `/health` para health checks de Kubernetes

### Alta Disponibilidad
- [x] 2 réplicas en Kubernetes (siempre hay 1 disponible)
- [x] `livenessProbe`: reinicia pods que no responden
- [x] `readinessProbe`: solo recibe tráfico cuando está listo
- [x] `startupProbe`: da tiempo extra al arranque inicial
- [x] `RollingUpdate` con `maxUnavailable=0` (sin downtime en updates)
- [x] `podAntiAffinity`: distribuir pods en nodos distintos

### Operacionales
- [x] Namespace dedicado (`chat-ha`) para aislamiento
- [x] Route de OpenShift para acceso HTTP
- [x] Límites de recursos (CPU/RAM)
- [x] Script automatizado `deploy.sh`

---

## Arquitectura

```
Internet / LAN
     │
     ▼
┌─────────────────────────────────────────────┐
│          MicroShift Cluster                 │
│                                             │
│  ┌──────────────────────────────────────┐   │
│  │  Namespace: chat-ha                  │   │
│  │                                      │   │
│  │  Route ──► Service (NodePort:30080)  │   │
│  │              │                       │   │
│  │      ┌───────┴───────┐               │   │
│  │      ▼               ▼               │   │
│  │  ┌────────┐     ┌────────┐           │   │
│  │  │ Pod 1  │     │ Pod 2  │           │   │
│  │  │ :3000  │     │ :3000  │           │   │
│  │  │Node.js │     │Node.js │           │   │
│  │  └────────┘     └────────┘           │   │
│  │                                      │   │
│  └──────────────────────────────────────┘   │
└─────────────────────────────────────────────┘
     ▲
     │ WebSocket (Socket.io)
     │
┌────────────────┐
│ Cliente Web    │
│ (Navegador)    │
│ index.html     │
└────────────────┘
```
