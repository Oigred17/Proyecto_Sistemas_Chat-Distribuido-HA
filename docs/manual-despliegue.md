# Manual de Despliegue — Chat Distribuido HA

## Estructura del Proyecto

```
Proyecto_Sistemas/
├── client/
│   └── index.html          # Cliente web (HTML + Socket.io)
├── server/
│   ├── server.js           # Servidor Node.js (Express + Socket.io)
│   ├── package.json        # Dependencias npm
│   └── Dockerfile          # Imagen de contenedor
├── k8s/
│   └── deployment.yaml     # Namespace + Deployment + Service + Route
├── docs/
│   ├── instalacion.md      # Guía de instalación del entorno
│   ├── manual-despliegue.md # Este archivo
│   └── diagramas.md        # Diagramas de arquitectura
└── deploy.sh               # Script de despliegue automatizado
```

---

## Requisitos Previos

| Herramienta | Versión mínima | Instalación |
|-------------|---------------|-------------|
| Node.js     | 18.x          | `sudo apt install nodejs` |
| Podman      | 4.x           | `sudo apt install podman` |
| oc (OpenShift CLI) | 4.x  | Ver `docs/instalacion.md` |
| MicroShift (vía MINC) | — | Ver `docs/instalacion.md` |

---

## Opción A: Ejecución Local (Desarrollo)

```bash
# 1. Instalar dependencias del servidor
cd server/
npm install

# 2. Iniciar el servidor
cd ..                    # Volver a la raíz del proyecto
node server/server.js

# 3. Abrir en el navegador
xdg-open http://localhost:3000
```

El servidor detecta automáticamente la ruta del cliente:
- **Desarrollo:** busca `../client/` relativo a `server.js`
- **Producción (Docker):** usa `CLIENT_DIR=/app/client`

---

## Opción B: Despliegue Automatizado

```bash
# Script interactivo: construye imagen, prueba local, y despliega en MicroShift
./deploy.sh
```

---

## Opción C: Despliegue Manual con Podman + MicroShift

### Paso 1 — Construir la imagen del contenedor

```bash
# ⚠️ El contexto de build debe ser la RAÍZ del proyecto (no server/)
# porque el Dockerfile necesita acceder a client/ y server/
cd ~/Documentos/Proyecto_Sistemas

podman build \
  -t chat-distribuido:latest \
  -f server/Dockerfile \
  .
```

### Paso 2 — Verificar la imagen

```bash
podman images | grep chat-distribuido

# Probar localmente antes de desplegar
podman run --rm -p 8080:3000 chat-distribuido:latest

# Health check de prueba
curl http://localhost:8080/health
```

### Paso 3 — Iniciar MicroShift

```bash
sudo minc start
sudo minc status

# Exportar kubeconfig
sudo minc kubeconfig > ~/.kube/config
chmod 600 ~/.kube/config

oc get nodes   # Debe mostrar el nodo en Ready
```

### Paso 4 — Cargar la imagen en MicroShift

MicroShift usa su propio daemon de contenedores. Hay dos formas de pasar la imagen:

**Opción 4a — Exportar e importar (recomendado en entorno local):**
```bash
# Exportar imagen desde Podman
podman save chat-distribuido:latest | sudo ctr images import -
```

**Opción 4b — Usar imagen desde Podman socket compartido:**
```bash
# Configurar en deployment.yaml:
#   image: localhost/chat-distribuido:latest
#   imagePullPolicy: IfNotPresent
```

### Paso 5 — Aplicar manifiestos

```bash
oc apply -f k8s/deployment.yaml

# Verificar que los recursos se crearon
oc get all -n chat-ha
```

### Paso 6 — Verificar el despliegue

```bash
# Ver pods (deben estar en Running)
oc get pods -n chat-ha -l app=chat-distribuido

# Ver logs en tiempo real
oc logs -n chat-ha -l app=chat-distribuido -f

# Ver el Service y su puerto
oc get svc -n chat-ha

# Ver la Route (URL de acceso)
oc get route -n chat-ha
```

### Paso 7 — Acceder a la aplicación

```bash
# Obtener IP del nodo
NODE_IP=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "Accede en: http://$NODE_IP:30080"

# O usar port-forward
oc port-forward -n chat-ha svc/chat-distribuido-svc 8080:80
# Luego abrir: http://localhost:8080
```

---

## Explicación de los Manifiestos YAML

### Namespace `chat-ha`
Aísla todos los recursos del proyecto en su propio espacio de nombres.

### StatefulSet
| Campo | Valor | Propósito |
|-------|-------|-----------|
| `replicas: 2` | 2 | Alta disponibilidad: siempre hay al menos 1 pod activo |
| `strategy: RollingUpdate` | maxUnavailable=0 | Actualizar sin downtime |
| `podAntiAffinity` | preferredDuringScheduling | Distribuir pods en nodos distintos |
| `livenessProbe` | `/health` cada 15s | Reiniciar pod si no responde |
| `readinessProbe` | `/health` cada 5s | Solo recibir tráfico si está listo |
| `startupProbe` | `/health` | Dar tiempo extra en el arranque |
| `resources.limits` | 128Mi / 200m | Evitar consumo excesivo |

### Service (NodePort)
Expone la aplicación en el **puerto 30080** de todos los nodos del clúster.

### Route (OpenShift)
Proporciona una URL HTTP amigable gestionada por el router de MicroShift.

---

## Prueba de Tolerancia a Fallos

```bash
# 1. Abrir el chat en el navegador y enviar mensajes

# 2. Ver los pods activos
oc get pods -n chat-ha -l app=chat-distribuido

# 3. Eliminar un pod manualmente (simular fallo)
oc delete pod <nombre-del-pod> -n chat-ha

# 4. Observar cómo MicroShift recrea el pod automáticamente
oc get pods -n chat-ha -l app=chat-distribuido -w

# 5. El chat debe reconectarse automáticamente sin perder mensajes previos
```

**Resultado esperado:** El indicador de estado en el cliente mostrará "Reconectando..." por 1-2 segundos y luego "Conectado" de nuevo.

---

## Comandos Útiles

```bash
# MicroShift
sudo minc start / stop / status / delete

# Pods
oc get pods -n chat-ha
oc describe pod <nombre> -n chat-ha
oc logs <nombre> -n chat-ha
oc delete pod <nombre> -n chat-ha

# Escalar réplicas
oc scale statefulset/chat-distribuido --replicas=3 -n chat-ha

# Reiniciar todos los pods
oc delete pods -n chat-ha -l app=chat-distribuido

# Eliminar todo el despliegue
oc delete namespace chat-ha
```
