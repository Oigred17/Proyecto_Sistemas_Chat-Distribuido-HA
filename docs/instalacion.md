# Guía de Instalación Completa para Linux Mint

## Requisitos del Sistema

- Linux Mint 21.x o superior (basado en Ubuntu 22.04+)
- Mínimo 4 GB de RAM (recomendado 8 GB)
- 20 GB de espacio libre en disco
- Procesador de 64 bits (x86_64)

---

## 1. Instalación de Podman

```bash
# Actualizar paquetes
sudo apt update && sudo apt upgrade -y

# Instalar Podman
sudo apt install -y podman podman-docker curl wget

# Verificar instalación
podman --version
```

---

## 2. Instalación de MicroShift (vía MINC)

MicroShift oficialmente solo funciona en RHEL. Para Linux Mint usamos **MINC (MicroShift in Container)**, un proyecto de la comunidad que ejecuta MicroShift como un contenedor de Podman.

### 2.1 Descargar MINC

```bash
# Descargar el binario de MINC (última versión)
curl -LsSf -o minc https://github.com/minc-org/minc/releases/latest/download/minc_linux_amd64
chmod +x minc
sudo mv minc /usr/local/bin/
```

### 2.2 Iniciar MicroShift con MINC

```bash
# Iniciar el clúster (requiere sudo por ahora)
sudo minc start

# La primera vez descarga las imágenes y configura todo (~5-10 min)
```

### 2.3 Verificar que MicroShift está corriendo

```bash
# MINC configura automáticamente el kubeconfig
sudo minc status
```

---

## 3. Instalación de OpenShift CLI (oc) y kubectl

```bash
# Descargar el cliente oc
curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/oc/latest/linux/oc.tar.gz

# Extraer
tar xzf oc.tar.gz

# Mover a /usr/local/bin
sudo mv oc /usr/local/bin/
sudo mv kubectl /usr/local/bin/

# Verificar
oc version
```

---

## 4. Configurar acceso a MicroShift

MINC genera automáticamente el kubeconfig. Para usarlo:

```bash
# MINC ya configura el contexto, verificar con:
oc whoami 2>/dev/null || export KUBECONFIG=$(sudo find /var/lib -name kubeconfig 2>/dev/null | head -1)

# Si lo anterior no funciona, pedir el kubeconfig a MINC:
sudo minc kubeconfig > ~/.kube/config
chmod 600 ~/.kube/config
```

---

## 5. Verificar el clúster

```bash
# Ver nodos
oc get nodes

# Ver pods del sistema (debe mostrar varios en Running)
oc get pods -A
```

---

## 6. Construir y desplegar la aplicación del chat

```bash
# Construir la imagen con Podman
cd ~/Documentos/Proyecto_Sistemas
podman build -t chat-distribuido:latest server/

# Aplicar el manifiesto
oc apply -f k8s/deployment.yaml

# Ver los pods
oc get pods -l app=chat-distribuido

# Exponer el servicio para acceder desde el navegador
oc port-forward svc/chat-distribuido-svc 8080:80
```

Abrir en el navegador: `http://localhost:8080`

---

## 7. Resumen de Comandos Útiles

```bash
minc start          # Iniciar MicroShift
minc stop           # Detener MicroShift
minc status         # Ver estado
minc kubeconfig     # Obtener kubeconfig
minc delete         # Eliminar el clúster

oc get nodes        # Ver nodos
oc get pods -A      # Ver todos los pods
oc get svc          # Ver servicios
oc logs -l app=chat-distribuido  # Ver logs
```

---

## Referencias

- MINC (MicroShift in Container): https://github.com/minc-org/minc
- MicroShift: https://github.com/openshift/microshift
- OpenShift CLI: https://mirror.openshift.com/pub/openshift-v4/clients/oc/latest/
- Podman: https://podman.io/
