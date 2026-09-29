#!/bin/bash
#
# uninstall-nominapp-client.sh
# Da de baja por completo una instancia de Nominapp instalada con install-nominapp-client.sh:
# sitio CloudPanel, base de datos, usuario MySQL, worker de Supervisor y SSH deploy key.
#
# Uso: sudo bash uninstall-nominapp-client.sh
#
# SIEMPRE hace un backup (mysqldump + .env) antes de borrar nada, en /root/backups/.
# Es una operación DESTRUCTIVA E IRREVERSIBLE (fuera del backup) — pide confirmación
# escribiendo el slug del cliente dos veces.
#
# Lo que NO borra (requiere pasos manuales en consolas web, se imprimen al final):
#   - Deploy Key en GitHub (Settings → Deploy keys)
#   - Repository secrets en GitHub Actions (prefijo <CLIENTE>_*)
#   - El job correspondiente en .github/workflows/deploy.yml
#   - El registro DNS

set -uo pipefail

# ── Colores ──────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[ACCIÓN MANUAL]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

pause() {
    echo -e "${YELLOW}Presioná ENTER para continuar...${NC}"
    read -r
}

CURRENT_STEP="inicio"
on_error() {
    local exit_code=$?
    error "Falló en el paso: ${CURRENT_STEP} (código de salida ${exit_code})"
    error "Revisá el error de arriba antes de reintentar. El backup (si ya se hizo) quedó en ${BACKUP_DIR:-/root/backups}."
    exit "${exit_code}"
}
trap on_error ERR

if [[ $EUID -ne 0 ]]; then
   error "Este script necesita correr con sudo."
   exit 1
fi

echo "============================================================"
echo "   Desinstalador — Nominapp (baja completa de una instancia)"
echo "============================================================"
echo ""

# ── Paso 0: Identificar al cliente ─────────────────────────────────────────
CURRENT_STEP="captura de datos"
read -rp "Slug del cliente a dar de baja (ej: santalucia): " CLIENT

STATE_DIR="/root/.nominapp-installs"
STATE_FILE="${STATE_DIR}/${CLIENT}.state"

if [[ -f "${STATE_FILE}" ]]; then
    ok "Encontrado state file de la instalación (${STATE_FILE}), usando esos datos."
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
else
    warn "No hay state file para '${CLIENT}' (¿se instaló sin el script, o con otro slug?)."
    read -rp "Dominio completo (ej: santalucia.techforge.com.py): " DOMAIN
    DB_NAME="nominapp-${CLIENT}"
    BASE="/home/${CLIENT}/htdocs/${DOMAIN}"
fi

if [[ ! -d "/home/${CLIENT}" ]]; then
    error "No existe /home/${CLIENT} — no parece haber un sitio activo para este cliente. Abortando."
    exit 1
fi

echo ""
log "Se va a dar de baja COMPLETAMENTE:"
echo "  Cliente:        ${CLIENT}"
echo "  Dominio:        ${DOMAIN}"
echo "  Base de datos:  ${DB_NAME}"
echo "  Directorio:     ${BASE}"
echo ""
warn "Esto es IRREVERSIBLE (fuera del backup automático). Se va a borrar:"
echo "  - El sitio completo en CloudPanel (archivos, incluyendo storage/)"
echo "  - La base de datos y el usuario MySQL"
echo "  - El worker de Supervisor"
echo "  - La SSH deploy key del site-user"
echo ""

# ── Confirmación estricta: escribir el slug dos veces ──────────────────────
CURRENT_STEP="confirmación"
read -rp "Escribí el slug del cliente para confirmar ('${CLIENT}'): " CONFIRM1
if [[ "${CONFIRM1}" != "${CLIENT}" ]]; then
    error "No coincide. Abortando sin tocar nada."
    exit 1
fi
read -rp "Escribilo de nuevo para confirmar de verdad: " CONFIRM2
if [[ "${CONFIRM2}" != "${CLIENT}" ]]; then
    error "No coincide. Abortando sin tocar nada."
    exit 1
fi
ok "Confirmado. Procediendo."

# ── Paso 1: Backup (DB + .env) ──────────────────────────────────────────────
CURRENT_STEP="backup"
BACKUP_DIR="/root/backups/${CLIENT}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${BACKUP_DIR}"

log "Obteniendo credenciales master de MySQL..."
MYSQL_ROOT_PASS=$(clpctl db:show:master-credentials | grep -i "| Password" | awk -F '|' '{print $3}' | xargs)
if [[ -z "${MYSQL_ROOT_PASS}" ]]; then
    error "No se pudo extraer la password de MySQL automáticamente."
    read -rp "Pegala manualmente (sudo clpctl db:show:master-credentials para verla): " MYSQL_ROOT_PASS
fi

DB_EXISTS=$(mysql -h127.0.0.1 -uroot -p"${MYSQL_ROOT_PASS}" -N -e "SHOW DATABASES LIKE '${DB_NAME}';" 2>/dev/null)
if [[ -n "${DB_EXISTS}" ]]; then
    log "Haciendo backup de la base de datos '${DB_NAME}'..."
    mysqldump -h127.0.0.1 -uroot -p"${MYSQL_ROOT_PASS}" "${DB_NAME}" | gzip > "${BACKUP_DIR}/${DB_NAME}.sql.gz"
    ok "Backup de DB guardado en ${BACKUP_DIR}/${DB_NAME}.sql.gz"
else
    warn "La base de datos '${DB_NAME}' no existe, se salta el backup de DB."
fi

if [[ -f "${BASE}/.env" ]]; then
    cp "${BASE}/.env" "${BACKUP_DIR}/.env.backup"
    ok ".env respaldado en ${BACKUP_DIR}/.env.backup"
fi

if [[ -f "${STATE_FILE}" ]]; then
    cp "${STATE_FILE}" "${BACKUP_DIR}/state.backup"
    ok "State file respaldado en ${BACKUP_DIR}/state.backup"
fi

echo ""
warn "Backup completo en ${BACKUP_DIR}. Revisalo si querés antes de seguir."
pause

# ── Paso 2: Detener y eliminar el worker de Supervisor ──────────────────────
CURRENT_STEP="baja del worker de Supervisor"
if [[ -f "/etc/supervisor/conf.d/${CLIENT}-worker.conf" ]]; then
    log "Deteniendo y eliminando worker de Supervisor..."
    supervisorctl stop "${CLIENT}-worker:*" || true
    rm -f "/etc/supervisor/conf.d/${CLIENT}-worker.conf"
    supervisorctl reread
    supervisorctl update
    ok "Worker de Supervisor eliminado."
else
    warn "No había worker de Supervisor configurado para '${CLIENT}', se salta."
fi

# ── Paso 3: Eliminar el sitio en CloudPanel ──────────────────────────────────
CURRENT_STEP="eliminación del sitio en CloudPanel"
log "Eliminando el sitio en CloudPanel (esto borra /home/${CLIENT} completo)..."
clpctl site:delete --domainName="${DOMAIN}" --force || {
    warn "clpctl site:delete falló o pidió confirmación interactiva — si te pidió confirmar, hacelo manualmente y volvé a correr el script (va a saltear este paso si /home/${CLIENT} ya no existe)."
}

if [[ -d "/home/${CLIENT}" ]]; then
    warn "El directorio /home/${CLIENT} todavía existe. Puede que site:delete haya fallado — revisá manualmente."
else
    ok "Sitio y archivos eliminados."
fi

# ── Paso 4: Eliminar base de datos y usuario MySQL ──────────────────────────
CURRENT_STEP="eliminación de base de datos"
log "Eliminando base de datos y usuario MySQL..."
mysql -h127.0.0.1 -uroot -p"${MYSQL_ROOT_PASS}" -e "
DROP DATABASE IF EXISTS \`${DB_NAME}\`;
DROP USER IF EXISTS '${CLIENT}'@'127.0.0.1';
DROP USER IF EXISTS '${CLIENT}'@'localhost';
FLUSH PRIVILEGES;
"
ok "Base de datos '${DB_NAME}' y usuario '${CLIENT}' eliminados."

# ── Paso 5: Archivar el state file ──────────────────────────────────────────
CURRENT_STEP="archivado del state file"
if [[ -f "${STATE_FILE}" ]]; then
    mv "${STATE_FILE}" "${STATE_FILE}.uninstalled-$(date +%Y%m%d-%H%M%S)"
    ok "State file archivado (para que un futuro install-nominapp-client.sh con el mismo slug no lo confunda con una instalación en curso)."
fi

# ── Resumen final ────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
ok "Baja completa para ${CLIENT}"
echo "============================================================"
echo "  Backup:  ${BACKUP_DIR}"
echo ""
warn "Pendiente MANUAL (no automatizado por este script):"
echo "  1. GitHub → ${GH_REPO:-<org/repo>} → Settings → Deploy keys"
echo "     → Eliminar la key '${CLIENT}-vps'"
echo "  2. GitHub → ${GH_REPO:-<org/repo>} → Settings → Secrets and variables → Actions"
echo "     → Eliminar los secrets con prefijo '${CLIENT^^}_*'"
echo "  3. Si el cliente tenía su propio job en .github/workflows/deploy.yml,"
echo "     eliminarlo (o el 'environment' correspondiente en el choice de workflow_dispatch)"
echo "  4. Eliminar el registro DNS de '${DOMAIN}' si ya no se va a usar"
echo "  5. Eliminar las credenciales de este cliente en Bitwarden"
echo "     (o marcarlas claramente como dadas de baja, con fecha)"
echo "============================================================"
