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

  echo "ACCEDER AL CHAT:"
  echo ""
  if [ -n "$ROUTE_URL" ]; then
    echo "  Metodo 1 - Route (RECOMENDADO - no requiere port-forward):"
    echo "    ${ROUTE_URL}"
    echo "    (Nota: si nip.io resuelve a 127.0.0.1, usa el metodo 2)"
    echo ""
    echo "  Metodo 2 - Port-forward (acceso red local):"
  else
    echo "  Metodo 1 - Port-forward (RECOMENDADO - acceso red local):"
  fi
  echo "    oc port-forward -n chat-ha svc/chat-distribuido-svc --address 0.0.0.0 8080:80"
  echo "    http://${IP}:8080"
  echo ""
  echo "  Alternativa - NodePort (solo si la red del contenedor lo permite):"
  echo "    http://${IP}:30080"
  echo ""
  echo "PRUEBA DE TOLERANCIA A FALLOS:"
  echo "  (abre el chat primero, luego en otra terminal ejecuta:)"
  echo ""
  echo "  # 1 - Ver pods activos (Nodo 2 Principal, Nodo 3 Redundancia):"
  echo "    oc get pods -n chat-ha -l app=chat-distribuido -o wide"
  echo ""
  echo "  # 2 - Eliminar UN pod mientras envias mensajes:"
  echo "    oc delete pod -n chat-ha chat-distribuido-0"
  echo ""
  echo "  # 3 - Ver como MicroShift lo recrea automaticamente:"
  echo "    oc get pods -n chat-ha -l app=chat-distribuido -w"
  echo ""
  echo "  # 4 - Verificar que el chat se reconecta solo:"
  echo "    El navegador mostrara 'Reconectando...' por ~1s y volvera solo"
  echo ""
  echo "PRUEBA DE BALANCEO DE CARGA:"
  echo "  (verifica que el trafico se distribuye entre los 2 nodos)"
  echo ""
  echo "  while true; do"
  echo "    curl -s http://localhost:8080/health | python3 -c \"import sys,json; print(json.load(sys.stdin)['nodo'])\""
  echo "    sleep 1"
  echo "  done"
  echo "============================================="

  PF_SCRIPT="/tmp/chat-pf-loop.sh"
  cat > "$PF_SCRIPT" << 'PFEOF'
#!/usr/bin/env bash
trap "exit 0" SIGTERM SIGINT
NAMESPACE="$1"
while true; do
  oc port-forward -n "${NAMESPACE}" svc/chat-distribuido-svc --address 0.0.0.0 8080:80
  sleep 2
done
PFEOF
  chmod +x "$PF_SCRIPT"

  echo ""
  echo "Iniciar port-forward? (F)oreground | (B)ackground | (R)oute | (N)o"
  read -r pf
  case "$pf" in
    [Ff]*)
      ;&
    [Bb]*)
      # Liberar puerto 8080 si otro proceso lo esta usando
      PF_PID_OLD=$(cat /tmp/chat-pf.pid 2>/dev/null || echo "")
      if [ -n "$PF_PID_OLD" ] && kill -0 "$PF_PID_OLD" 2>/dev/null; then
        info "Cerrando port-forward anterior (PID $PF_PID_OLD)..."
        kill -9 "$PF_PID_OLD" 2>/dev/null
        sleep 1
      fi
      ;;
  esac

  case "$pf" in
    [Ff]*)
      info "Port-forward activo en http://${IP}:8080 (Ctrl+C para detener)..."
      info "  (se auto-reinicia si el pod se elimina, aprox 2s de reconexion)"
      "${PF_SCRIPT}" "${NAMESPACE}" "${IP}"
      ;;
    [Bb]*)
      info "Port-forward en background (PID guardado en /tmp/chat-pf.pid)..."
      nohup "${PF_SCRIPT}" "${NAMESPACE}" "${IP}" >/tmp/chat-pf.log 2>&1 &
      PF_PID=$!
      echo $PF_PID > /tmp/chat-pf.pid
      ok "Port-forward corriendo en PID $PF_PID (se auto-reinicia si el pod falla)"
      echo "  http://${IP}:8080"
      echo "  Accesible desde cualquier PC en la red"
      echo ""
      echo "Probar tolerancia a fallos:"
      echo "  1. Abre http://${IP}:8080 en el navegador"
      echo "  2. Envia mensajes de chat"
      echo "  3. En OTRA terminal: oc delete pod -n chat-ha chat-distribuido-0"
      echo "  4. El port-forward se reinicia solo (~2s) y el chat se reconecta"
      echo "  5. Ver el health check: curl -s http://${IP}:8080/health | python3 -m json.tool"
      echo ""
      echo "Para detenerlo:"
      echo "  kill \$(cat /tmp/chat-pf.pid)"
      ;;
    [Rr]*)
      if [ -n "$ROUTE_URL" ]; then
        ok "Usando route: ${ROUTE_URL}"
        echo "  (minc expone rutas HTTP en el puerto 9080)"
      else
        warn "No hay Route definida. Verifica con: oc get route -n ${NAMESPACE}"
      fi
      ;;
    *)
      info "Omitido. Usa el comando manualmente:"
      info "  oc port-forward -n chat-ha svc/chat-distribuido-svc --address 0.0.0.0 8080:80"
      ;;
  esac
fi

echo ""; echo "            Proceso completado               "; echo ""
