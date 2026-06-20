#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="chat-ha"
SERVICE="svc/chat-distribuido-svc"
LOCAL_PORT="8080"
REMOTE_PORT="80"
LOG_FILE="/tmp/chat-pf-loop.log"

echo "[$(date +%H:%M:%S)] Iniciando port-forward loop hacia $SERVICE"
echo "  Accede en: http://localhost:$LOCAL_PORT (local)"
echo "  (Log: $LOG_FILE)"
echo ""

while true; do
  echo "[$(date +%H:%M:%S)] Conectando port-forward..."
  oc port-forward -n "$NAMESPACE" "$SERVICE" "$LOCAL_PORT:$REMOTE_PORT" --address 0.0.0.0 > "$LOG_FILE" 2>&1
  echo "[$(date +%H:%M:%S)] Port-forward caído. Reintentando en 2s..."
  sleep 2
done
