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
  warn "Sin conexion. Configurando kubeconfig..."
  if command -v minc >/dev/null 2>&1; then
    mkdir -p ~/.kube
    KUBEADMIN=$(sudo find /var/lib/containers/storage -path "*/kubeadmin/*/kubeconfig" 2>/dev/null | head -1)
    if [ -n "$KUBEADMIN" ]; then
      sudo cat "$KUBEADMIN" > ~/.kube/config
      chmod 600 ~/.kube/config
      ok "kubeconfig configurado"
    else
      error "kubeconfig no encontrado. Ejecuta: sudo minc create"
    fi
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

  oc apply -f "${K8S_DIR}/deployment.yaml" || error "Error al aplicar manifiestos"
  ok "Manifiestos aplicados"

  info "Esperando pods listos..."
  oc rollout status deployment/chat-distribuido -n "${NAMESPACE}" --timeout=120s || warn "Timeout"

  echo ""
  echo "--- PODS ---"
  oc get pods -n "${NAMESPACE}" -l app=chat-distribuido -o wide

  echo ""
  echo "--- HEALTH CHECK DESDE CADA POD ---"
  for pod in $(oc get pods -n "${NAMESPACE}" -l app=chat-distribuido -o name | cut -d/ -f2); do
    RESP=$(oc exec -n "${NAMESPACE}" "$pod" -- curl -s http://localhost:3000/health 2>/dev/null || echo "{\"error\":\"no response\"}")
    echo "  ${pod}: ${RESP}"
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
  echo "ACCEDER AL CHAT:"
  echo ""
  echo "  Metodo 1 - Port-forward (RECOMENDADO):"
  echo "    oc port-forward -n chat-ha svc/chat-distribuido-svc 8080:80"
  echo "    http://localhost:8080"
  echo ""
  echo "  Metodo 2 - NodePort (acceso desde la red local):"
  IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | grep -v 127.0.0.1 | head -1)
  echo "    http://${IP}:30080"
  echo ""
  echo "PRUEBA DE TOLERANCIA A FALLOS:"
  echo "  (abre el chat primero, luego en otra terminal ejecuta:)"
  echo ""
  echo "  # 1 - Ver pods activos:"
  echo "    oc get pods -n chat-ha -l app=chat-distribuido"
  echo ""
  echo "  # 2 - Eliminar UN pod mientras envias mensajes:"
  POD_NAME=$(oc get pods -n "${NAMESPACE}" -l app=chat-distribuido -o name | head -1 | cut -d/ -f2)
  echo "    oc delete pod -n chat-ha ${POD_NAME}"
  echo ""
  echo "  # 3 - Ver como MicroShift lo recrea automaticamente:"
  echo "    oc get pods -n chat-ha -l app=chat-distribuido -w"
  echo ""
  echo "  # 4 - Verificar que el chat se reconecta solo:"
  echo "    El navegador mostrara 'Reconectando...' por ~1s y volvera solo"
  echo ""
  echo "PRUEBA DE BALANCEO DE CARGA:"
  echo "  (verifica que el trafico se distribuye entre los 2 pods)"
  echo ""
  echo "  while true; do"
  echo "    curl -s http://localhost:8080/health | python3 -c \"import sys,json; print(json.load(sys.stdin)['pod'])\""
  echo "    sleep 1"
  echo "  done"
  echo "============================================="

  echo ""
  echo "Iniciar port-forward ahora? (s/N)"
  read -r pf
  if [[ "$pf" =~ ^[Ss]$ ]]; then
    info "Port-forward activo en http://localhost:8080 (Ctrl+C para detener)..."
    oc port-forward -n "${NAMESPACE}" svc/chat-distribuido-svc 8080:80
  fi
fi

echo ""; echo "            Proceso completado               "; echo ""
