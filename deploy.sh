#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="chat-distribuido"
IMAGE_TAG="latest"
NAMESPACE="chat-ha"
K8S_DIR="k8s"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
title() { echo -e "\n${YELLOW}=== $1 ===${NC}"; }

echo ""
echo "      Chat Distribuido HA - Despliegue y Verificacion      "
echo ""

# ─────────────────────────────────────────────────────────────
# Verificar que NO se ejecute como root
# ─────────────────────────────────────────────────────────────
if [ "$EUID" -eq 0 ]; then
  echo "[ERROR] No ejecutes este script con sudo."
  echo "        Ejecutalo como usuario normal: ./deploy.sh"
  echo "        El script pedira sudo solo cuando sea necesario."
  exit 1
fi

# ─────────────────────────────────────────────────────────────
# FASE 1: VERIFICACION DEL ENTORNO
# ─────────────────────────────────────────────────────────────
title "1/6 - Verificando herramientas"

command -v podman >/dev/null 2>&1 && ok "Podman: $(podman --version)" || error "Podman no encontrado"
command -v oc     >/dev/null 2>&1 && ok "oc: $(oc version --client 2>/dev/null | head -1)" || error "oc no encontrado"
command -v minc   >/dev/null 2>&1 && ok "minc instalado" || warn "minc no instalado"
command -v curl   >/dev/null 2>&1 && ok "curl instalado" || error "curl no encontrado"

# ─────────────────────────────────────────────────────────────
# FASE 2: VERIFICACION MICROSHIFT
# ─────────────────────────────────────────────────────────────
title "2/6 - Verificando MicroShift"

if ! oc cluster-info >/dev/null 2>&1; then
  warn "Sin conexion. Intentando iniciar MicroShift..."
  if command -v minc >/dev/null 2>&1; then
    STATUS=$(minc status 2>/dev/null | grep '"container"' | cut -d: -f2 | tr -d ' ",')
    if [ "$STATUS" = "stopped" ] || [ -z "$STATUS" ]; then
      info "MicroShift detenido. Creando/iniciando con minc..."
      echo "  (se pedira sudo para ejecutar minc create)"
      sudo minc create 2>&1 || error "Error al crear MicroShift con minc"
      ok "MicroShift creado/iniciado"
    fi
    info "Esperando que el API server responda..."
    for i in $(seq 1 60); do
      if oc cluster-info >/dev/null 2>&1; then
        ok "API Server responde"
        break
      fi
      if [ $((i % 6)) -eq 0 ]; then
        info "  Esperando... ($((i * 5))s)"
      fi
      sleep 5
    done
    oc cluster-info >/dev/null 2>&1 || error "MicroShift no responde tras 5 minutos"
    mkdir -p ~/.kube
    info "Generando kubeconfig..."
    if minc generate-kubeconfig > ~/.kube/config 2>/dev/null; then
      ok "kubeconfig generado con minc"
    else
      info "Buscando kubeconfig alternativo..."
      KUBEADMIN=$(sudo find /var/lib/containers/storage -path "*/kubeadmin/*/kubeconfig" 2>/dev/null | head -1)
      if [ -n "$KUBEADMIN" ]; then
        sudo cat "$KUBEADMIN" > ~/.kube/config
        ok "kubeconfig copiado desde $KUBEADMIN"
      else
        error "No se pudo generar kubeconfig"
      fi
    fi
    chmod 600 ~/.kube/config
  else
    error "MINC no instalado"
  fi
fi

oc cluster-info >/dev/null 2>&1 || error "MicroShift no responde"
ok "API Server conectado"

NODOS=$(oc get nodes --no-headers 2>/dev/null | wc -l)
ok "Nodos disponibles: ${NODOS}"
oc get nodes

# ─────────────────────────────────────────────────────────────
# FASE 3: CONSTRUIR IMAGEN
# ─────────────────────────────────────────────────────────────
title "3/6 - Construyendo imagen"

podman build -t "${IMAGE_NAME}:${IMAGE_TAG}" -f server/Dockerfile . || error "Error al construir"
ok "Imagen construida: ${IMAGE_NAME}:${IMAGE_TAG}"

# ─────────────────────────────────────────────────────────────
# FASE 4: CARGAR IMAGEN EN MICROSHIFT
# ─────────────────────────────────────────────────────────────
title "4/6 - Cargando imagen en MicroShift"

podman save "${IMAGE_NAME}:${IMAGE_TAG}" | sudo ctr images import - || error "Error al cargar"
ok "Imagen cargada en el daemon de MicroShift"

# ─────────────────────────────────────────────────────────────
# FASE 5: PRUEBA LOCAL (OPCIONAL)
# ─────────────────────────────────────────────────────────────
title "5/6 - Prueba local (opcional)"

echo "Probar servidor localmente antes de desplegar? (s/N)"
read -r respuesta
if [[ "$respuesta" =~ ^[Ss]$ ]]; then
  info "Iniciando contenedor de prueba..."
  podman run -d --name chat-test -p 8080:3000 "${IMAGE_NAME}:${IMAGE_TAG}"
  sleep 2

  echo ""
  echo "--- Health Check ---"
  curl -s http://localhost:8080/health | python3 -m json.tool 2>/dev/null || curl -s http://localhost:8080/health
  echo ""
  echo "--- Endpoint raiz ---"
  curl -sI http://localhost:8080/ | head -5
  echo ""
  echo "Abre http://localhost:8080 en el navegador para probar."
  echo "Presiona ENTER para detener y continuar..."
  read -r
  podman stop chat-test && podman rm chat-test
  ok "Prueba local finalizada"
fi

# ─────────────────────────────────────────────────────────────
# FASE 6: DESPLEGAR EN MICROSHIFT
# ─────────────────────────────────────────────────────────────
title "6/6 - Despliegue en MicroShift"

echo "Desplegar en MicroShift? (s/N)"
read -r respuesta_k8s
if [[ "$respuesta_k8s" =~ ^[Ss]$ ]]; then

  # Eliminar StatefulSet anterior si existe
  if oc get statefulset chat-distribuido -n "${NAMESPACE}" >/dev/null 2>&1; then
    info "StatefulSet chat-distribuido ya existe. Se actualizará con 'oc apply'."
  fi

  oc apply -f "${K8S_DIR}/deployment.yaml" || error "Error al aplicar manifiestos"
  ok "Manifiestos aplicados"

  info "Esperando pods listos..."
  oc rollout status statefulset/chat-distribuido -n "${NAMESPACE}" --timeout=120s || warn "Timeout"

  echo ""
  echo "--- PODS ---"
  oc get pods -n "${NAMESPACE}" -l app=chat-distribuido -o wide

  echo ""
  echo "--- HEALTH CHECK DESDE CADA NODO ---"
  for pod in $(oc get pods -n "${NAMESPACE}" -l app=chat-distribuido -o name | cut -d/ -f2); do
    RESP=$(oc exec -n "${NAMESPACE}" "$pod" -- wget -qO- http://127.0.0.1:3000/health 2>/dev/null || echo "{\"error\":\"no response\"}")
    NODO=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('nodo','?'))" 2>/dev/null || echo "?")
    echo "  ${pod} (${NODO}): ${RESP}"
  done

  echo ""
  echo "--- SERVICES ---"
  oc get svc -n "${NAMESPACE}"

  echo ""
  echo "--- ROUTE ---"
  oc get route -n "${NAMESPACE}" 2>/dev/null || echo "  No hay Route definida"

  echo ""
  echo "============================================="
  ok "DESPLIEGUE EXITOSO"
  echo ""

  # Detectar URL de la Route si existe
  ROUTE_URL=""
  if oc get route -n "${NAMESPACE}" chat-distribuido-route >/dev/null 2>&1; then
    ROUTE_URL=$(oc get route -n "${NAMESPACE}" chat-distribuido-route -o jsonpath='http://{.spec.host}' 2>/dev/null || echo "")
    if [ -n "$ROUTE_URL" ]; then
      # minc expone rutas HTTP en el puerto 9080 del host
      ROUTE_URL="${ROUTE_URL}:9080"
    fi
  fi

  IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | grep -v 127.0.0.1 | head -1)

  echo "ACCEDER AL CHAT (Recomendado - tolerancia a fallos nativa):"
  ROUTE_HOST=$(oc get route -n "${NAMESPACE}" chat-distribuido-route -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  if [ -n "$ROUTE_HOST" ]; then
    echo "  http://${ROUTE_HOST}:9080"
    echo ""
    echo "  (El router de MicroShift balancea entre los 2 pods automaticamente."
    echo "   Al eliminar un pod, el trafico se redirige al otro SIN INTERRUPCION.)"
  fi
  echo ""
  echo "Alternativa - Port-forward (requiere reconexion manual):"
  echo "  oc port-forward -n chat-ha svc/chat-distribuido-svc 8080:80"
  echo "  http://localhost:8080"
  echo ""
  echo "============================================="
  echo "PRUEBA DE TOLERANCIA A FALLOS (por Route):"
  echo "  1. Abre http://${ROUTE_HOST}:9080 en el navegador"
  echo "  2. Envia mensajes de chat"
  echo "  3. En OTRA terminal:"
  echo "     oc delete pod -n chat-ha chat-distribuido-0"
  echo "  4. El chat SIGUE FUNCIONANDO (el router redirige al otro pod)"
  echo "  5. MicroShift recrea el pod automaticamente:"
  echo "     oc get pods -n chat-ha -l app=chat-distribuido -w"
  echo ""
  echo "Verificar el ID unico del pod:"
  echo "  curl -s http://${ROUTE_HOST}:9080/health | python3 -m json.tool"
  echo "  (El campo 'id' cambia cuando el pod se recrea)"
  echo "============================================="

  echo ""
  echo "Iniciar port-forward auxiliar? (s/N)"
  echo "  (Recomendado: usa la Route en http://${ROUTE_HOST}:9080)"
  read -r pf
  if [[ "$pf" =~ ^[Ss]$ ]]; then
    info "Port-forward en http://localhost:8080 (Ctrl+C para detener)..."
    oc port-forward -n "${NAMESPACE}" svc/chat-distribuido-svc 8080:80
  fi
fi

echo ""; echo "            Proceso completado               "; echo ""
