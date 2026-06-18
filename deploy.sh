#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  deploy.sh — Script de despliegue automatizado
#  Chat Distribuido HA — Sistemas Distribuidos
# ═══════════════════════════════════════════════════════════
set -e

IMAGE_NAME="chat-distribuido"
IMAGE_TAG="latest"
NAMESPACE="chat-ha"
K8S_DIR="k8s"

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  Chat Distribuido HA — Despliegue Automático ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── 1. Verificar dependencias ────────────────────────────────
info "Verificando dependencias..."
command -v podman  >/dev/null 2>&1 || error "Podman no encontrado. Instalar: sudo apt install podman"
command -v oc      >/dev/null 2>&1 || warn  "oc (OpenShift CLI) no encontrado. Despliegue K8s no disponible."
ok "Dependencias verificadas"

# ── 2. Construir imagen ──────────────────────────────────────
info "Construyendo imagen Docker: ${IMAGE_NAME}:${IMAGE_TAG}"
info "Contexto de build: $(pwd)"

# El contexto de build es la RAÍZ del proyecto
podman build \
  -t "${IMAGE_NAME}:${IMAGE_TAG}" \
  -f server/Dockerfile \
  . \
  || error "Error al construir la imagen"

ok "Imagen construida: ${IMAGE_NAME}:${IMAGE_TAG}"
podman images | grep "${IMAGE_NAME}" || true

# ── 3. Probar localmente (opcional) ─────────────────────────
echo ""
echo "¿Deseas probar el servidor localmente antes de desplegar? (s/N)"
read -r respuesta
if [[ "$respuesta" =~ ^[Ss]$ ]]; then
  info "Iniciando contenedor de prueba en http://localhost:8080 ..."
  podman run -d --name chat-test -p 8080:3000 "${IMAGE_NAME}:${IMAGE_TAG}"
  sleep 2
  info "Health check:"
  curl -s http://localhost:8080/health | python3 -m json.tool 2>/dev/null || \
    curl -s http://localhost:8080/health
  echo ""
  echo "Abre http://localhost:8080 en el navegador para verificar."
  echo "Presiona ENTER para detener el contenedor de prueba y continuar..."
  read -r
  podman stop chat-test && podman rm chat-test
  ok "Contenedor de prueba detenido"
fi

# ── 4. Despliegue en MicroShift ──────────────────────────────
if command -v oc >/dev/null 2>&1; then
  echo ""
  echo "¿Deseas desplegar en MicroShift? (s/N)"
  read -r respuesta_k8s
  if [[ "$respuesta_k8s" =~ ^[Ss]$ ]]; then

    info "Verificando conexión al clúster..."
    oc cluster-info >/dev/null 2>&1 || error "No hay conexión al clúster MicroShift"

    info "Creando namespace '${NAMESPACE}' (si no existe)..."
    oc apply -f "${K8S_DIR}/deployment.yaml" || error "Error al aplicar manifiestos"
    ok "Manifiestos aplicados"

    info "Esperando que los pods estén listos..."
    oc rollout status deployment/chat-distribuido -n "${NAMESPACE}" --timeout=120s \
      || warn "Timeout esperando rollout. Verifica manualmente."

    echo ""
    info "Estado del despliegue:"
    oc get pods -n "${NAMESPACE}" -l app=chat-distribuido
    echo ""
    oc get svc -n "${NAMESPACE}"

    # Obtener URL de acceso
    NODE_IP=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")
    if [ -n "$NODE_IP" ]; then
      ok "Accede a la aplicación en: http://${NODE_IP}:30080"
    fi

    # Si existe Route
    ROUTE_URL=$(oc get route chat-distribuido-route -n "${NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ -n "$ROUTE_URL" ]; then
      ok "Route disponible en: http://${ROUTE_URL}"
    fi

  fi
fi

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  ✓ Proceso completado                    ║"
echo "╚══════════════════════════════════════════╝"
echo ""
