# Diagramas de Arquitectura y Secuencia

## Diagrama de Componentes

```
+---------------------+         +---------------------------+
|                     |         |     Cluster MicroShift    |
|   Cliente Web       |         |                           |
|   (Navegador)       |  HTTP   |  +---------------------+ |
|   +-----------+     | <~~~~~~> |  | Service             | |
|   | index.html|     | WebSock |  | LoadBalancer:80      | |
|   | socket.io |     |         |  | chat-distribuido-svc | |
|   +-----------+     |         |  +----------+----------+ |
|         ^           |         |             |             |
|         |           |         |    selector |             |
|         |           |         |    app: chat-distribuido  |
+---------+-----------+         |             |             |
                                |  +----------+----------+ |
                                |  | Deployment          | |
                                |  | replicas: 2         | |
                                |  |                     | |
                                |  | +-------+ +-------+ | |
                                |  | | Pod 1 | | Pod 2 | | |
                                |  | |:3000  | |:3000  | | |
                                |  | +-------+ +-------+ | |
                                |  +---------------------+ |
                                |                           |
                                |  +---------------------+ |
                                |  | HealthProbe: /health| |
                                |  +---------------------+ |
                                +---------------------------+
```

**Nodos del sistema (arquitectura de 3 nodos):**

| Nodo | Componente | Tecnología | Función |
|------|-----------|------------|---------|
| 1 | Cliente Terminal | HTML5 / JS / Socket.io | Interfaz gráfica del chat |
| 2 | Servidor Réplica Principal | Node.js + Express + Socket.io (Pod 1) | Instancia primaria del backend |
| 3 | Servidor Redundancia | Node.js + Express + Socket.io (Pod 2) | Réplica para alta disponibilidad |

---

## Diagrama de Secuencia (Flujo de Mensajes)

```
Cliente A                Service               Pod 1 (Primario)         Pod 2 (Réplica)
    |                       |                         |                       |
    |---[HTTP] Cargar página-->|                       |                       |
    |                       |----forward----->[Pod 1] |                       |
    |<--[Socket.io connect]--|                         |                       |
    |                       |                         |                       |
    |---[emit 'registrar']-->|                       |                       |
    |                       |----broadcast---->|                       |       |
    |                       |                         |---[emit 'usuarios']-->|
    |                       |                         |                       |
    |---[emit 'mensaje']---->|                       |                       |
    |                       |----broadcast---->|                       |       |
    |                       |                         |                       |
    |<--[emit 'mensaje']-----|<----[emit 'mensaje']---|                       |
    |                       |                         |                       |
    |---[GET /health]------->|                       |                       |
    |<--[JSON {pod,status}]--|<----[responde Pod X]----|                       |
    |                       |                         |                       |
    ~                                                 ~                       ~
    ~     (FALLO: oc delete pod Pod 1)               X                       ~
    ~                                                 ~                       ~
    |                       |                         |                       |
    |---[emit 'mensaje']---->|                       |                       |
    |                       |                                             |       |
    |                       |----forward-------------------------------->|       |
    |<--[emit 'mensaje']-----|<------------------------------------------|       |
    |                       |                         |                       |
    ~                                                 ~                       ~
    ~     (MicroShift crea nuevo Pod 1 automáticamente)                     ~
    ~                                                 ~                       ~
```

---

## Flujo de Datos

1. El cliente carga `index.html` desde el Service de MicroShift
2. El cliente establece conexión WebSocket (Socket.io) con el Service
3. El Service balancea la conexión hacia uno de los Pods (Round Robin)
4. Cuando un Pod falla, las conexiones existentes se reconectan al Pod activo
5. MicroShift detecta la falla via livenessProbe y recrea el Pod automáticamente
