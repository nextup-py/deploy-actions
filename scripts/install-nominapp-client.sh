#!/bin/bash
#
# install-nominapp-client.sh
# Wizard de instalación de una nueva instancia de Nominapp para un cliente en el VPS de TechForge.
#
# Uso: sudo bash install-nominapp-client.sh
#
# Este script automatiza todo lo que se puede hacer por SSH/CLI. Para los pasos que
# requieren una consola web externa (GitHub, Resend, Google Cloud, DNS), el script
# se detiene, te muestra exactamente qué hacer, y espera que confirmes con ENTER.
#
# IDEMPOTENCIA: el progreso se guarda en /root/.nominapp-installs/<cliente>.state.
# Si el script se corta a mitad de camino (ej: composer install se queda sin
# memoria), volvé a correrlo con el mismo slug de cliente — va a detectar el
# estado guardado y preguntarte si querés retomar desde donde quedó, sin repetir
# pasos ya hechos ni regenerar passwords que ya se usaron en la DB o el .env.

set -uo pipefail

# ── Colores para legibilidad ──────────────────────────────────────────────
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
    echo -e "${YELLOW}Presioná ENTER cuando hayas completado el paso de arriba...${NC}"
    read -r
}

# ── Manejo de errores: reporta claramente en qué paso falló ────────────────
CURRENT_STEP="inicio"
on_error() {
    local exit_code=$?
    error "Falló en el paso: ${CURRENT_STEP} (código de salida ${exit_code})"
    if [[ -n "${STATE_FILE:-}" ]]; then
        error "El progreso quedó guardado en ${STATE_FILE}."
        error "Corregí el problema y volvé a correr el script con el mismo slug ('${CLIENT:-?}') para retomar desde acá."
    fi
    exit "${exit_code}"
}
trap on_error ERR

# ── Reintentos para pasos que pueden fallar por red transitoria ────────────
retry() {
    local max_attempts=3
    local attempt=1
    local delay=5
    until "$@"; do
        if (( attempt >= max_attempts )); then
            error "Falló después de ${max_attempts} intentos: $*"
            return 1
        fi
        warn "Intento ${attempt}/${max_attempts} falló, reintentando en ${delay}s..."
        sleep "${delay}"
        ((attempt++))
    done
}

# ── Estado persistente (idempotencia) ──────────────────────────────────────
STATE_DIR="/root/.nominapp-installs"
mkdir -p "${STATE_DIR}"

step_done() {
    [[ -f "${STATE_FILE}" ]] && grep -q "^STEP_${1}=done$" "${STATE_FILE}"
}

mark_step_done() {
    echo "STEP_${1}=done" >> "${STATE_FILE}"
}

save_var() {
    # Guarda una variable en el state file (para que un resume la recupere
    # tal cual, sin regenerar passwords ya usadas en la DB o el .env)
    sed -i "/^$1=/d" "${STATE_FILE}" 2>/dev/null || true
    echo "$1=${!1}" >> "${STATE_FILE}"
}

# ── Verificar que corremos como root/sudo ─────────────────────────────────
if [[ $EUID -ne 0 ]]; then
   error "Este script necesita correr con sudo."
   exit 1
fi

echo "============================================================"
echo "   Wizard de instalación — Nominapp para nuevo cliente"
echo "============================================================"
echo ""

# ── Paso 0: Datos del cliente (con validación) ─────────────────────────────
CURRENT_STEP="captura de datos"

while true; do
    read -rp "Slug del cliente (minúsculas, sin espacios, ej: santalucia): " CLIENT
    if [[ "${CLIENT}" =~ ^[a-z][a-z0-9]{1,30}$ ]]; then
        break
    fi
    error "Slug inválido. Usá solo minúsculas y números, empezando con una letra (ej: santalucia, mbaretecars)."
done

STATE_FILE="${STATE_DIR}/${CLIENT}.state"

# ── Retomar instalación previa si existe estado guardado ───────────────────
if [[ -f "${STATE_FILE}" ]]; then
    warn "Ya existe una instalación en curso o completa para '${CLIENT}' (${STATE_FILE})."
    echo "Contenido guardado:"
    cat "${STATE_FILE}"
    echo ""
    read -rp "¿Retomar desde donde quedó? (yes/no — 'no' cancela sin borrar nada): " RESUME
    if [[ "${RESUME}" != "yes" ]]; then
        error "Cancelado. Si querés empezar de cero, borrá primero ${STATE_FILE} y los recursos del cliente."
        exit 1
    fi
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
    ok "Estado cargado. Retomando instalación de '${CLIENT}'."
else
    while true; do
        read -rp "Dominio completo (ej: santalucia.techforge.com.py): " DOMAIN
        if [[ "${DOMAIN}" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
            break
        fi
        error "Dominio inválido. Formato esperado: subdominio.dominio.tld"
    done

    read -rp "Nombre visible de la app (ej: Nominapp): " APP_NAME

    while true; do
        read -rp "Repo de GitHub (formato org/repo, ej: nextup-py/nominapp): " GH_REPO
        [[ "${GH_REPO}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && break
        error "Formato inválido. Tiene que ser org/repo."
    done

    read -rp "Versión de PHP (default 8.3): " PHP_VERSION
    PHP_VERSION=${PHP_VERSION:-8.3}

    DB_NAME="nominapp-${CLIENT}"
    SITE_PASSWORD=$(openssl rand -base64 18 | tr -d '=+/' | cut -c1-16)
    DB_PASSWORD=$(openssl rand -base64 18 | tr -d '=+/' | cut -c1-16)
    ADMIN_PASSWORD=$(openssl rand -base64 18 | tr -d '=+/' | cut -c1-16)
    ADMIN_EMAIL="admin@${DOMAIN}"
    BASE="/home/${CLIENT}/htdocs/${DOMAIN}"

    echo ""
    log "Resumen de la instalación:"
    echo "  Cliente:        ${CLIENT}"
    echo "  Dominio:        ${DOMAIN}"
    echo "  App name:       ${APP_NAME}"
    echo "  Repo:           ${GH_REPO}"
    echo "  PHP:            ${PHP_VERSION}"
    echo "  Base de datos:  ${DB_NAME}"
    echo "  Directorio:     ${BASE}"
    echo ""
    read -rp "¿Confirmás estos datos? (yes/no): " CONFIRM
    [[ "${CONFIRM}" == "yes" ]] || { error "Cancelado."; exit 1; }

    # Guardamos todo ANTES de tocar nada, así un corte a mitad de camino
    # siempre tiene de dónde retomar.
    : > "${STATE_FILE}"
    for var in CLIENT DOMAIN APP_NAME GH_REPO PHP_VERSION DB_NAME BASE \
               SITE_PASSWORD DB_PASSWORD ADMIN_PASSWORD ADMIN_EMAIL; do
        save_var "${var}"
    done
fi

# ── Paso 1: DNS ────────────────────────────────────────────────────────────
CURRENT_STEP="DNS"
if ! step_done DNS_CONFIRMED; then
    SERVER_IP=$(curl -4 -s ifconfig.me || hostname -I | awk '{print $1}')
    save_var SERVER_IP
    warn "Pedile a quien administra el DNS que agregue este registro A:"
    echo "    ${DOMAIN}  →  ${SERVER_IP}"
    warn "No hace falta esperar la propagación para seguir — solo la vas a necesitar para el SSL más adelante."
    pause
    mark_step_done DNS_CONFIRMED
fi

# ── Paso 2: Crear el sitio en CloudPanel ──────────────────────────────────
CURRENT_STEP="creación del sitio en CloudPanel"
if ! step_done SITE_CREATED; then
    if [[ -d "/home/${CLIENT}" ]]; then
        warn "El directorio /home/${CLIENT} ya existe (¿sitio creado fuera de este script?). Salteando creación."
    else
        log "Creando sitio en CloudPanel..."
        clpctl site:add:php \
          --domainName="${DOMAIN}" \
          --phpVersion="${PHP_VERSION}" \
          --vhostTemplate='Generic' \
          --siteUser="${CLIENT}" \
          --siteUserPassword="${SITE_PASSWORD}"
        ok "Sitio creado."
    fi
    mark_step_done SITE_CREATED
fi

# ── Paso 3: SSH key de deploy ──────────────────────────────────────────────
CURRENT_STEP="generación de SSH key de deploy"
if ! step_done DEPLOY_KEY_READY; then
    if [[ -f "/home/${CLIENT}/.ssh/id_ed25519.pub" ]]; then
        warn "Ya existe una SSH key para ${CLIENT}, no se regenera."
    else
        log "Generando SSH key para deploy..."
        sudo -u "${CLIENT}" ssh-keygen -t ed25519 -C "${CLIENT}-deploy" -f "/home/${CLIENT}/.ssh/id_ed25519" -N ""
    fi
    DEPLOY_PUBKEY=$(cat "/home/${CLIENT}/.ssh/id_ed25519.pub")

    echo ""
    warn "Agregá esta Deploy Key en GitHub → ${GH_REPO} → Settings → Deploy keys → Add deploy key"
    echo "  Nombre sugerido: ${CLIENT}-vps"
    echo "  Key:"
    echo "  ${DEPLOY_PUBKEY}"
    echo ""
    pause

    log "Verificando autenticación con GitHub (vas a tener que aceptar el host, escribí 'yes' cuando te lo pida)..."
    sudo -u "${CLIENT}" ssh -o StrictHostKeyChecking=accept-new -T git@github.com || true
    mark_step_done DEPLOY_KEY_READY
fi

# ── Paso 4: Clonar el repo ─────────────────────────────────────────────────
CURRENT_STEP="clonado del repo"
if ! step_done REPO_CLONED; then
    log "Clonando el repo..."
    sudo -u "${CLIENT}" bash -c "cd ${BASE} && rm -rf ./* && git clone git@github.com:${GH_REPO}.git ."
    ok "Repo clonado."
    mark_step_done REPO_CLONED
fi

# ── Paso 5: Base de datos ─────────────────────────────────────────────────
CURRENT_STEP="creación de base de datos"
if ! step_done DB_CREATED; then
    log "Obteniendo credenciales master de MySQL..."
    # La salida de clpctl es una tabla con bordes "|" — extraemos la fila de Password
    # y tomamos su segunda columna, ya limpia de espacios y bordes.
    MYSQL_ROOT_PASS=$(clpctl db:show:master-credentials | grep -i "| Password" | awk -F '|' '{print $3}' | xargs)

    if [[ -z "${MYSQL_ROOT_PASS}" ]]; then
        error "No se pudo extraer la password de MySQL automáticamente."
        read -rp "Pegala manualmente (sudo clpctl db:show:master-credentials para verla): " MYSQL_ROOT_PASS
    fi

    DB_EXISTS=$(mysql -h127.0.0.1 -uroot -p"${MYSQL_ROOT_PASS}" -N -e "SHOW DATABASES LIKE '${DB_NAME}';" 2>/dev/null)
    if [[ -n "${DB_EXISTS}" ]]; then
        warn "La base de datos '${DB_NAME}' ya existe, no se recrea."
    else
        log "Creando base de datos y usuario (localhost + 127.0.0.1)..."
        mysql -h127.0.0.1 -uroot -p"${MYSQL_ROOT_PASS}" -e "
CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${CLIENT}'@'127.0.0.1' IDENTIFIED BY '${DB_PASSWORD}';
CREATE USER IF NOT EXISTS '${CLIENT}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${CLIENT}'@'127.0.0.1';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${CLIENT}'@'localhost';
FLUSH PRIVILEGES;
"
        ok "Base de datos '${DB_NAME}' y usuario '${CLIENT}' creados (con acceso desde localhost y 127.0.0.1 — Laravel usa DB_HOST=localhost por defecto, que en MySQL es una autenticación distinta a 127.0.0.1)."
    fi
    mark_step_done DB_CREATED
fi

# ── Paso 6: API keys externas ──────────────────────────────────────────────
# NOTA PARA AUTOMATIZAR A FUTURO:
#   - Resend: POST https://api.resend.com/api-keys con Authorization: Bearer <MASTER_KEY>
#     de tu cuenta (una key con permiso para crear otras keys). Guardar esa
#     master key fuera del repo (ej: /root/.nominapp-secrets.env, chmod 600) y
#     sourcearla al inicio del script.
#   - Google Maps: requiere gcloud CLI autenticado con una service account del
#     proyecto nextup-nominapp-maps (`gcloud services api-keys create ...`).
#     Instalar gcloud en el VPS o correr ese paso desde tu máquina y pasar la
#     key resultante como variable de entorno al script.
CURRENT_STEP="API keys externas (Resend / Google Maps)"
if ! step_done EXTERNAL_KEYS_READY; then
    echo ""
    warn "Creá una nueva API key de Resend llamada 'nominapp-${CLIENT}' en resend.com/api-keys"
    read -rp "Pegá acá el RESEND_KEY (re_...): " RESEND_KEY

    warn "Creá una nueva API key de Google Maps en el proyecto nextup-nominapp-maps,"
    warn "restringida a HTTP referrer '${DOMAIN}/*' y a la API 'Maps JavaScript API' únicamente."
    read -rp "Pegá acá el GOOGLE_MAPS_API_KEY (AIza...): " MAPS_KEY

    save_var RESEND_KEY
    save_var MAPS_KEY
    mark_step_done EXTERNAL_KEYS_READY
fi

# ── Paso 7: .env ────────────────────────────────────────────────────────────
CURRENT_STEP="configuración del .env"
if ! step_done ENV_CONFIGURED; then
    log "Armando el .env..."
    sudo -u "${CLIENT}" cp "${BASE}/.env.example" "${BASE}/.env"

    sudo -u "${CLIENT}" sed -i \
      -e "s|^APP_NAME=.*|APP_NAME=\"${APP_NAME}\"|" \
      -e "s|^APP_URL=.*|APP_URL=https://${DOMAIN}|" \
      -e "s|^DB_DATABASE=.*|DB_DATABASE=${DB_NAME}|" \
      -e "s|^DB_USERNAME=.*|DB_USERNAME=${CLIENT}|" \
      -e "s|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASSWORD}|" \
      -e "s|^MAIL_MAILER=.*|MAIL_MAILER=resend|" \
      -e "s|^GOOGLE_MAPS_API_KEY=.*|GOOGLE_MAPS_API_KEY=${MAPS_KEY}|" \
      "${BASE}/.env"

    # ADMIN_EMAIL, ADMIN_PASSWORD y RESEND_KEY pueden no existir en todos los
    # .env.example — los agregamos si faltan, así el ProductionSeeder no crea
    # el admin con el email/password default.
    for pair in "ADMIN_EMAIL=${ADMIN_EMAIL}" "ADMIN_PASSWORD=${ADMIN_PASSWORD}" "RESEND_KEY=${RESEND_KEY}"; do
        key="${pair%%=*}"
        if sudo -u "${CLIENT}" grep -q "^${key}=" "${BASE}/.env"; then
            sudo -u "${CLIENT}" sed -i "s|^${key}=.*|${pair}|" "${BASE}/.env"
        else
            echo "${pair}" | sudo -u "${CLIENT}" tee -a "${BASE}/.env" > /dev/null
        fi
    done
    ok ".env configurado."
    mark_step_done ENV_CONFIGURED
fi

# ── Paso 8: Instalación de Laravel ────────────────────────────────────────
CURRENT_STEP="composer install"
if ! step_done COMPOSER_INSTALLED; then
    log "Composer install (con reintentos si falla por red)..."
    retry sudo -u "${CLIENT}" bash -c "cd ${BASE} && COMPOSER_MEMORY_LIMIT=-1 composer install --no-dev --optimize-autoloader"
    mark_step_done COMPOSER_INSTALLED
fi

CURRENT_STEP="generación de APP_KEY"
if ! step_done APP_KEY_SET; then
    log "Generando APP_KEY..."
    sudo -u "${CLIENT}" php "${BASE}/artisan" key:generate
    mark_step_done APP_KEY_SET
fi

CURRENT_STEP="migraciones"
if ! step_done MIGRATED; then
    log "Corriendo migraciones (instalación nueva)..."
    sudo -u "${CLIENT}" php "${BASE}/artisan" migrate:fresh --force
    mark_step_done MIGRATED
fi

CURRENT_STEP="build de frontend"
if ! step_done FRONTEND_BUILT; then
    log "Instalando dependencias de frontend y compilando assets (con reintentos si falla por red)..."
    retry sudo -u "${CLIENT}" bash -c "cd ${BASE} && npm install"
    sudo -u "${CLIENT}" bash -c "cd ${BASE} && npm run build"
    mark_step_done FRONTEND_BUILT
fi

CURRENT_STEP="publicación de assets Livewire/Filament"
if ! step_done ASSETS_PUBLISHED; then
    log "Publicando assets de Livewire/Filament..."
    sudo -u "${CLIENT}" php "${BASE}/artisan" livewire:publish --assets
    sudo -u "${CLIENT}" php "${BASE}/artisan" filament:upgrade
    mark_step_done ASSETS_PUBLISHED
fi

CURRENT_STEP="seeder de producción"
if ! step_done SEEDED; then
    log "Optimizando antes del seeder..."
    sudo -u "${CLIENT}" php "${BASE}/artisan" config:clear
    sudo -u "${CLIENT}" php "${BASE}/artisan" optimize
    sudo -u "${CLIENT}" php "${BASE}/artisan" filament:optimize

    log "La password del admin ya está definida (${ADMIN_PASSWORD}) — se va a usar automáticamente."
    # IMPORTANTE: config:clear antes del seeder es obligatorio, no opcional.
    # El "optimize" de arriba cachea la config, y una vez cacheada, Laravel deja
    # de leer el .env en cada request — por eso env('ADMIN_EMAIL') dentro del
    # seeder devolvería el default admin@example.com si no limpiamos el cache
    # justo antes de sembrar.
    sudo -u "${CLIENT}" php "${BASE}/artisan" config:clear
    sudo -u "${CLIENT}" php "${BASE}/artisan" db:seed --force --class=ProductionSeeder
    sudo -u "${CLIENT}" php "${BASE}/artisan" optimize
    sudo -u "${CLIENT}" php "${BASE}/artisan" filament:optimize
    ok "Seeder corrido."
    mark_step_done SEEDED
fi

# ── Paso 9: Permisos ───────────────────────────────────────────────────────
CURRENT_STEP="ajuste de permisos"
if ! step_done PERMISSIONS_SET; then
    log "Ajustando permisos de storage y bootstrap/cache..."
    chmod -R 775 "${BASE}/storage" "${BASE}/bootstrap/cache"
    chown -R "${CLIENT}:${CLIENT}" "${BASE}/storage" "${BASE}/bootstrap/cache"
    ok "Permisos aplicados."
    mark_step_done PERMISSIONS_SET
fi

# ── Paso 10: Queue worker con Supervisor ──────────────────────────────────
CURRENT_STEP="configuración del worker"
if ! step_done WORKER_CONFIGURED; then
    log "Configurando worker de Supervisor..."
    tee "/etc/supervisor/conf.d/${CLIENT}-worker.conf" > /dev/null <<EOF
[program:${CLIENT}-worker]
process_name=%(program_name)s_%(process_num)02d
command=php ${BASE}/artisan queue:work --sleep=3 --tries=3 --max-time=3600
numprocs=1
autostart=true
autorestart=true
stopwaitsecs=3600
user=${CLIENT}
redirect_stderr=true
stdout_logfile=${BASE}/storage/logs/worker.log
EOF
    supervisorctl reread
    supervisorctl update
    ok "Worker configurado. Estado:"
    supervisorctl status | grep "${CLIENT}" || true
    mark_step_done WORKER_CONFIGURED
fi

# ── Paso 11: Document Root ──────────────────────────────────────────────────
# CloudPanel crea el sitio con el Document Root apuntando a la raíz del proyecto,
# pero Laravel necesita servir desde /public — sin esto el sitio da 403 Forbidden.
CURRENT_STEP="configuración de Document Root"
if ! step_done DOCUMENT_ROOT_SET; then
    warn "Configurá el Document Root en CloudPanel (queda más prolijo hacerlo desde la UI):"
    echo "  CloudPanel → Sites → ${DOMAIN} → Settings → Root Directory"
    echo "  Cambiar de:  ${DOMAIN}"
    echo "  a:           ${DOMAIN}/public"
    echo "  y guardar."
    pause
    mark_step_done DOCUMENT_ROOT_SET
fi

# ── Paso 12: SSL ────────────────────────────────────────────────────────────
CURRENT_STEP="instalación de SSL"
if ! step_done SSL_INSTALLED; then
    echo ""
    warn "Verificá que el DNS ya haya propagado antes de continuar:"
    echo "    dig +short ${DOMAIN}"
    echo "Debería devolver: ${SERVER_IP}"
    pause

    log "Instalando certificado SSL..."
    if clpctl lets-encrypt:install:certificate --domainName="${DOMAIN}"; then
        mark_step_done SSL_INSTALLED
    else
        warn "El SSL falló — probablemente el DNS todavía no propagó."
        warn "Reintentá manualmente después con: clpctl lets-encrypt:install:certificate --domainName=${DOMAIN}"
        warn "Volvé a correr este script cuando el DNS esté OK para que retome desde acá."
    fi
fi

# ── Paso 13: GitHub Actions ────────────────────────────────────────────────
# NOTA PARA AUTOMATIZAR A FUTURO: con un GitHub PAT (scope repo, permisos de
# administración) se puede crear el environment y sus secrets vía API
# (POST /repos/{owner}/{repo}/environments/{name}, y para cada secret hay que
# encriptarlo con la public key del repo — libsodium/nacl — antes de subirlo).
CURRENT_STEP="configuración de GitHub Actions"
if ! step_done GH_ACTIONS_READY; then
    echo ""
    warn "Pendiente manual: creá el environment '${CLIENT}' en GitHub Actions"
    echo "  (repo ${GH_REPO} → Settings → Environments → New environment)"
    echo "  con los secrets necesarios para el deploy automático (revisá el environment de un cliente anterior como plantilla)."
    pause
    mark_step_done GH_ACTIONS_READY
fi

# ── Resumen final ───────────────────────────────────────────────────────────
echo ""
echo "============================================================"
ok "Instalación completa para ${CLIENT}"
echo "============================================================"
echo "  URL:              https://${DOMAIN}"
echo "  Site user:        ${CLIENT}"
echo "  Site password:    ${SITE_PASSWORD}"
echo "  DB:               ${DB_NAME}"
echo "  DB user:          ${CLIENT}"
echo "  DB password:      ${DB_PASSWORD}"
echo ""
echo "  Admin email:      ${ADMIN_EMAIL}"
echo "  Admin password:   ${ADMIN_PASSWORD}"
echo ""
warn "Guardá TODO lo de arriba en Bitwarden"
warn "bajo '[TechForge Nominapp - ${CLIENT}]' ANTES de cerrar la terminal."
echo "============================================================"
echo ""
log "Estado guardado en ${STATE_FILE} (contiene passwords — no lo borres hasta confirmar que guardaste todo en Bitwarden)."
