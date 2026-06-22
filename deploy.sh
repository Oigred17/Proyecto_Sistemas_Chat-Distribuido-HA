#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

IMAGE_NAME="chat-distribuido"
IMAGE_TAG="latest"
FULL_IMAGE="localhost/${IMAGE_NAME}:${IMAGE_TAG}"
NAMESPACE="chat-ha"
K8S_DIR="${SCRIPT_DIR}/k8s"
MANIFEST="${K8S_DIR}/deployment.yaml"

# ── Colores ──────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
title() { echo -e "\n${YELLOW}=== $1 ===${NC}"; }

echo ""
echo "      Chat Distribuido HA - Despliegue y Verificacion      "
echo ""

# ── No ejecutar como root ─────────────────────────────────
if [ "$EUID" -eq 0 ]; then
  echo "[ERROR] No ejecutes este script con sudo."
  echo "        Ejecutalo como usuario normal: ./deploy.sh"
  exit 1
fi

# ── Validar sudo al inicio ────────────────────────────────
title "Validando acceso sudo"
sudo -v 2>/dev/null || { echo "  Se necesita sudo para continuar."; sudo -v; }
ok "Acceso sudo confirmado"

# ── Detectar herramientas ─────────────────────────────────
title "1/6 - Verificando herramientas"

PODMAN=""; DOCKER=""; RUNTIME=""
command -v podman >/dev/null 2>&1 && PODMAN=$(command -v podman) && RUNTIME="$PODMAN"
if [ -z "$RUNTIME" ]; then
  command -v docker >/dev/null 2>&1 && DOCKER=$(command -v docker) && RUNTIME="$DOCKER"
fi
if [ -n "$RUNTIME" ]; then
  ok "$(basename "$RUNTIME"): $($RUNTIME --version 2>/dev/null | head -1)"
else
  error "No se encontro podman ni docker"
fi

command -v oc >/dev/null 2>&1 && ok "oc: $(oc version --client 2>/dev/null | head -1)" || error "oc no encontrado"

# Buscar minc en varios lugares
MINC=""
for candidate in "$SCRIPT_DIR/minc" "./minc" "/usr/local/bin/minc" "/usr/bin/minc" "minc"; do
  if command -v "$candidate" >/dev/null 2>&1; then
    MINC=$(command -v "$candidate")
    break
  elif [ -f "$candidate" ] && [ -x "$candidate" ]; then
    MINC="$candidate"
    break
  fi
done

if [ -n "$MINC" ]; then
  ok "minc: $($MINC version 2>/dev/null || echo disponible)"
else
  warn "minc no instalado — la creacion de MicroShift debe hacerse manualmente"
  MINC=""
fi

command -v curl >/dev/null 2>&1 && ok "curl instalado" || warn "curl no instalado (prueba local no disponible)"

# ── Verificar / iniciar MicroShift ────────────────────────
title "2/6 - Verificando MicroShift"

if oc cluster-info >/dev/null 2>&1; then
  ok "API Server conectado"
else
  warn "MicroShift no responde"
  if [ -z "$MINC" ]; then
    error "No hay MINC disponible para iniciar MicroShift"
  fi

  MICROSHIFT_CONTAINER=$(sudo "${RUNTIME}" ps -a --filter name=microshift --format '{{.Names}} {{.Status}}' 2>/dev/null || echo "")

  if echo "$MICROSHIFT_CONTAINER" | grep -qi "microshift.*Up"; then
    info "MicroShift container: RUNNING (solo falta kubeconfig)"
  elif echo "$MICROSHIFT_CONTAINER" | grep -qi "microshift.*Exited"; then
    echo ""
    info "MicroShift container: DETENIDO"
    printf "  Iniciarlo con ${RUNTIME}? (s/N): "
    read -r
    if [[ "$REPLY" =~ ^[Ss]$ ]]; then
      sudo "${RUNTIME}" start microshift || error "Error al iniciar contenedor microshift"
      ok "MicroShift iniciado"
    fi
  else
    echo ""
    echo "  Se ejecutara: sudo ${MINC} create"
    echo "  (descarga ~1-2 GB, puede tardar 5-10 min la primera vez)"
    echo ""
    printf "  Presiona ENTER para continuar o Ctrl+C para cancelar... "
    read -r
    echo ""
    info "Ejecutando: sudo ${MINC} create"
    sudo "$MINC" create || error "Error al crear MicroShift con minc"
    ok "MicroShift creado"
  fi

  info "Esperando API server (hasta 5 min)..."
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

  # ── Configurar kubeconfig ────────────────────────────────
  mkdir -p ~/.kube
  info "Configurando kubeconfig..."

  if [ -n "$MINC" ]; then
    sudo "$MINC" generate-kubeconfig 2>/dev/null || true
  fi

  KUBECONFIG_COPIADA=""
  for src in \
    "/root/.kube/config" \
    "/var/lib/microshift/resources/kubeadmin/kubeconfig" \
    "/var/lib/containers/storage/volumes/*/kubeconfig"; do
    if sudo test -f "$src" 2>/dev/null; then
      sudo cat "$src" > ~/.kube/config 2>/dev/null && KUBECONFIG_COPIADA="$src" && break
    fi
  done

  if [ -z "$KUBECONFIG_COPIADA" ]; then
    warn "No se encontro kubeconfig. Buscando con find..."
    FOUND=$(sudo find /var/lib /root -name kubeconfig -not -path "*/proc/*" 2>/dev/null | head -1)
    if [ -n "$FOUND" ]; then
      sudo cat "$FOUND" > ~/.kube/config && KUBECONFIG_COPIADA="$FOUND"
    fi
  fi

  if [ -n "$KUBECONFIG_COPIADA" ]; then
    ok "kubeconfig copiado desde ${KUBECONFIG_COPIADA}"
  else
    error "No se pudo obtener el kubeconfig"
  fi
  chmod 600 ~/.kube/config
fi

oc cluster-info >/dev/null 2>&1 || error "MicroShift no responde"
ok "API Server conectado"

NODOS=$(oc get nodes --no-headers 2>/dev/null | wc -l)
ok "Nodos: ${NODOS}"
oc get nodes

# ── Obtener IPs del host ───────────────────────────────────
HOST_IPS=()
while IFS= read -r line; do
  HOST_IPS+=("$line")
done < <(ip -4 addr show | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | grep -v 127.0.0.1 || true)

# ── Exponer MicroShift a la red ────────────────────────────
MICROSHIFT_BIND=$(sudo "${RUNTIME}" inspect microshift --format '{{.NetworkSettings.Ports}}' 2>/dev/null || echo "")

if echo "$MICROSHIFT_BIND" | grep -q "127.0.0.1" && [ ${#HOST_IPS[@]} -gt 0 ]; then
  echo ""
  warn "MicroShift solo escucha en 127.0.0.1"
  echo "  Tus IPs de red: ${HOST_IPS[*]}"
  echo "
  La Route (puerto 9080) tiene tolerancia a fallos NATIVA
  (el router de MicroShift redirige al pod vivo).
  El port-forward NO tiene tolerancia (muere si el pod cae).
  "
  echo "Opciones para exponer la Route a la red:"
  echo "  1) iptables DNAT (recomendado — tolerancia a fallos)"
  echo "  2) socat (simple, efimero)"
  echo "  3) Omitir (solo localhost)"
  echo ""
  printf "Elige (1/2/3) [3]: "
  read -r net_opt

  if [[ "$net_opt" == "1" ]]; then
    info "Configurando iptables DNAT para exponer Route en 0.0.0.0:9080..."
    sudo sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null 2>&1 || true
    sudo iptables -t nat -C PREROUTING -p tcp --dport 9080 -j DNAT --to-destination 127.0.0.1:9080 2>/dev/null ||
      sudo iptables -t nat -A PREROUTING -p tcp --dport 9080 -j DNAT --to-destination 127.0.0.1:9080 || true
    sudo iptables -t nat -C OUTPUT -p tcp --dport 9080 -j DNAT --to-destination 127.0.0.1:9080 2>/dev/null ||
      sudo iptables -t nat -A OUTPUT -p tcp --dport 9080 -j DNAT --to-destination 127.0.0.1:9080 || true
    ok "Route expuesta en http://${HOST_IPS[0]}:9080"
  elif [[ "$net_opt" == "2" ]] && command -v socat >/dev/null 2>&1; then
    PORT_9080_FREE=true
    (sudo "${RUNTIME}" port microshift 2>/dev/null | grep -q "0.0.0.0:9080") && PORT_9080_FREE=false
    if $PORT_9080_FREE; then
      info "Iniciando socat en 0.0.0.0:9080 -> 127.0.0.1:9080"
      nohup sudo socat TCP-LISTEN:9080,fork,reuseaddr TCP:127.0.0.1:9080 >/dev/null 2>&1 &
      SOCAT_PID=$!
      ok "socat (PID ${SOCAT_PID}) — http://${HOST_IPS[0]}:9080"
    else
      warn "Puerto 9080 ocupado en 0.0.0.0. Usando iptables..."
      sudo sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null 2>&1 || true
      sudo iptables -t nat -A PREROUTING -p tcp --dport 9080 -j DNAT --to-destination 127.0.0.1:9080 2>/dev/null || true
      ok "Route expuesta con iptables — http://${HOST_IPS[0]}:9080"
    fi
  elif [[ "$net_opt" == "2" ]] && ! command -v socat >/dev/null 2>&1; then
    warn "socat no instalado. Usando iptables..."
    sudo sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null 2>&1 || true
    sudo iptables -t nat -A PREROUTING -p tcp --dport 9080 -j DNAT --to-destination 127.0.0.1:9080 2>/dev/null || true
    ok "Route expuesta con iptables — http://${HOST_IPS[0]}:9080"
  else
    info "MicroShift solo accesible desde localhost"
  fi
fi

# ── Construir imagen ──────────────────────────────────────
title "3/6 - Construyendo imagen"

"${RUNTIME}" build -t "${FULL_IMAGE}" -f server/Dockerfile "${SCRIPT_DIR}" || error "Error al construir"
ok "Imagen: ${FULL_IMAGE}"

# ── Cargar imagen en MicroShift ───────────────────────────
title "4/6 - Cargando imagen en MicroShift"

TMP_IMAGE=$(mktemp /tmp/chat-distribuido-image-XXXXXX.tar)
cleanup() { rm -f "${TMP_IMAGE}"; }
trap cleanup EXIT

"${RUNTIME}" save "${FULL_IMAGE}" -o "${TMP_IMAGE}" || error "Error al exportar imagen"

if command -v ctr >/dev/null 2>&1; then
  sudo ctr -n k8s.io images import "${TMP_IMAGE}" && ok "Imagen cargada en containerd (k8s.io)" && CLEAN=1
elif command -v crictl >/dev/null 2>&1; then
  sudo crictl load "${TMP_IMAGE}" && ok "Imagen cargada via crictl" && CLEAN=1
fi

if [ "${CLEAN:-0}" -eq 0 ]; then
  warn "ctr/crictl no disponibles. Copiando imagen al storage de MicroShift..."
  sudo mkdir -p /var/lib/microshift/images 2>/dev/null || true
  sudo cp "${TMP_IMAGE}" /var/lib/microshift/images/ || error "No se pudo cargar la imagen"
  ok "Imagen copiada a /var/lib/microshift/images/"
fi

rm -f "${TMP_IMAGE}"
trap - EXIT

# ── Prueba local opcional ─────────────────────────────────
title "5/6 - Prueba local (opcional)"
echo "Probar localmente antes de desplegar? (s/N)"
read -r respuesta
if [[ "$respuesta" =~ ^[Ss]$ ]]; then
  info "Iniciando contenedor de prueba..."
  "${RUNTIME}" run -d --name chat-test -p 8080:3000 "${FULL_IMAGE}"
  sleep 2
  echo ""
  curl -s http://localhost:8080/health | python3 -m json.tool 2>/dev/null || curl -s http://localhost:8080/health
  echo ""
  echo "Presiona ENTER para detener y continuar..."
  read -r
  "${RUNTIME}" stop chat-test && "${RUNTIME}" rm chat-test
  ok "Prueba local finalizada"
fi

# ── Desplegar en MicroShift ───────────────────────────────
title "6/6 - Despliegue en MicroShift"
echo "Desplegar en MicroShift? (s/N)"
read -r respuesta_k8s
if [[ "$respuesta_k8s" =~ ^[Ss]$ ]]; then
  if [ ! -f "$MANIFEST" ]; then
    error "Manifiesto no encontrado: ${MANIFEST}"
  fi
  oc apply -f "${MANIFEST}" || error "Error al aplicar manifiestos"
  ok "Manifiestos aplicados"

  info "Esperando pods listos..."
  oc rollout status statefulset/chat-distribuido -n "${NAMESPACE}" --timeout=120s || warn "Timeout en rollout"

  echo ""
  echo "--- PODS ---"
  oc get pods -n "${NAMESPACE}" -l app=chat-distribuido -o wide

  echo ""
  echo "--- HEALTH CHECK ---"
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
  ok "DESPLIEGUE EXITOSO"
  echo ""

  ROUTE_HOST=$(oc get route -n "${NAMESPACE}" chat-distribuido-route -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

  echo "ACCEDER AL CHAT:"
  echo "  Route (local):  http://127.0.0.1:9080  (tolerancia a fallos SI)"
  if [ -n "$ROUTE_HOST" ]; then
    for ip in "${HOST_IPS[@]}"; do
      echo "  Route (red):    http://${ip}:9080"
    done
  fi
  echo "  Port-forward:   http://localhost:8080 (tolerancia a fallos NO)"
  echo ""
  echo "  PRUEBA DE TOLERANCIA A FALLOS:"
  echo "  1. Abre http://127.0.0.1:9080 en el navegador"
  echo "  2. Envia mensajes"
  echo "  3. En otra terminal: oc delete pod -n ${NAMESPACE} chat-distribuido-0"
  echo "  4. El chat se reconecta al otro pod SIN INTERRUPCION"
  echo ""

  echo "Iniciar port-forward? (s/N)"
  read -r pf
  if [[ "$pf" =~ ^[Ss]$ ]]; then
    PF_ADDR="localhost"
    echo "  Ser visible en la red? (s/N)"
    read -r pf_net
    [[ "$pf_net" =~ ^[Ss]$ ]] && PF_ADDR="0.0.0.0"

    PF_PORT=8080
    while [ "$PF_PORT" -lt 8100 ]; do
      if ! (ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null) | grep -q ":${PF_PORT} "; then
        break
      fi
      PF_PORT=$((PF_PORT + 1))
    done

    info "Port-forward en http://${PF_ADDR}:${PF_PORT} (Ctrl+C para detener)..."
    oc port-forward --address "${PF_ADDR}" -n "${NAMESPACE}" svc/chat-distribuido-svc "${PF_PORT}":80 || warn "Falló port-forward en puerto ${PF_PORT}"
  fi
fi

echo ""; echo "            Proceso completado               "; echo ""
