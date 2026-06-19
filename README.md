# Chat Distribuido HA

Sistema de chat distribuido con alta disponibilidad, desplegado en MicroShift (Kubernetes).

## Arquitectura (3 Nodos)

| Nodo | Componente | Tecnología |
|------|-----------|------------|
| 1 | Cliente Terminal | HTML5 / JS / Socket.io |
| 2 | Servidor Réplica Principal | Node.js + Express + Socket.io |
| 3 | Servidor Redundancia | Node.js + Express + Socket.io |

## Estructura del Proyecto

```
Proyecto_Sistemas/
├── client/index.html       # Cliente web
├── server/
│   ├── server.js           # Servidor backend
│   ├── package.json        # Dependencias
│   └── Dockerfile          # Imagen de contenedor
├── k8s/deployment.yaml     # Manifiestos Kubernetes
├── docs/
│   ├── instalacion.md      # Guía de instalación
│   ├── manual-despliegue.md # Manual de despliegue
│   └── diagramas.md        # Diagramas de arquitectura
├── deploy.sh               # Script de despliegue automatizado
└── README.md               # Este archivo
```

## Despliegue Rápido

```bash
./deploy.sh
```

## Prueba de Tolerancia a Fallos

```bash
oc get pods -n chat-ha -l app=chat-distribuido -o wide
oc delete pod -n chat-ha chat-distribuido-0   # mientras se envían mensajes
oc get pods -n chat-ha -l app=chat-distribuido -w  # ver recreación automática
```

## Documentación

- `docs/instalacion.md` — Instalación completa del entorno
- `docs/manual-despliegue.md` — Manual de despliegue detallado
- `docs/diagramas.md` — Diagramas de componentes y secuencia
