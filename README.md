# deploy-actions

Workflow reusable de GitHub Actions para desplegar proyectos Laravel de NextUp por SSH directo, más los scripts de infraestructura para instalar/desinstalar instancias de Nominapp en un VPS con CloudPanel.

Este repo es público (requisito de GitHub para que un workflow reusable pueda ser consumido por otros repos de la organización sin restricciones de plan). No contiene secretos de ningún proyecto — cada consumidor pasa los suyos propios al invocarlo.

## Qué resuelve

Antes, el deploy de cada proyecto corría vía webhook → `public/deploy.php` en el propio servidor. Ese mecanismo nunca ejecutaba `storage:link` (causaba 404 en archivos servidos desde `storage/`) y estaba duplicado por proyecto. Este repo centraliza esa lógica en un único workflow reusable: GitHub Actions se conecta por SSH directo al servidor y ejecuta el deploy él mismo.

## `laravel-deploy.yml` — workflow reusable

### Cómo se usa

Cada proyecto tiene su propio `.github/workflows/deploy.yml`, un caller mínimo con un job por instancia/cliente, condicionado por el input `environment` elegido al correr el workflow manualmente:

```yaml
name: Deploy
on:
  workflow_dispatch:
    inputs:
      environment:
        type: choice
        options: [mi-instancia]
        required: true

jobs:
  deploy-mi-instancia:
    if: ${{ inputs.environment == 'mi-instancia' }}
    permissions:
      contents: write
    uses: nextup-py/deploy-actions/.github/workflows/laravel-deploy.yml@<SHA fijo>
    with:
      environment_name: mi-instancia
      run_tests: true
      run_migrations: true
    secrets:
      SSH_HOST: ${{ secrets.MI_INSTANCIA_SSH_HOST }}
      SSH_PORT: ${{ secrets.MI_INSTANCIA_SSH_PORT }}
      SSH_USER: ${{ secrets.MI_INSTANCIA_SSH_USER }}
      SSH_PRIVATE_KEY: ${{ secrets.MI_INSTANCIA_SSH_PRIVATE_KEY }}
      DEPLOY_PATH: ${{ secrets.MI_INSTANCIA_DEPLOY_PATH }}
      APP_URL: ${{ secrets.MI_INSTANCIA_APP_URL }}
      SMTP_HOST: ${{ secrets.SMTP_HOST }}
      SMTP_PORT: ${{ secrets.SMTP_PORT }}
      SMTP_USER: ${{ secrets.SMTP_USER }}
      SMTP_PASS: ${{ secrets.SMTP_PASS }}
      NOTIFY_EMAIL: ${{ secrets.NOTIFY_EMAIL }}
```

⚠️ **Siempre referenciar por SHA fijo** (`@<commit sha>`), nunca por `@main` — así un cambio en este repo no rompe deploys de otros proyectos sin que sea intencional. Actualizar la versión es cambiar el SHA a propósito en el caller.

Los secrets con prefijo por instancia (`MI_INSTANCIA_*`) son **repository secrets** del repo consumidor (no GitHub Environments nativos) — cada cliente/instancia tiene los suyos, prefijados en mayúsculas.

### Inputs

| Input | Tipo | Default | Descripción |
|---|---|---|---|
| `environment_name` | string | *(requerido)* | Nombre del environment de GitHub Actions asociado a este deploy (controla protection rules, historial de deploys) |
| `run_tests` | boolean | `true` | Si corre el job `test` (Pest + MySQL de servicio) antes de deployar |
| `run_migrations` | boolean | `true` | Si corre `migrate --force` (con backup de DB previo) durante el deploy |
| `php_version` | string | `8.3` | Versión de PHP para el job de tests |
| `node_version` | string | `22` | Versión de Node para el build de assets |

### Secrets

| Secret | Para qué |
|---|---|
| `SSH_HOST`, `SSH_PORT`, `SSH_USER`, `SSH_PRIVATE_KEY` | Conexión SSH del runner al servidor de destino. `SSH_USER` es un usuario **dedicado al deploy**, distinto del site-user y de la Deploy Key de `git pull` — ver nota de seguridad abajo |
| `DEPLOY_PATH` | Ruta absoluta del proyecto en el servidor (ej. `/home/cliente/htdocs/dominio/proyecto`) |
| `APP_URL` | URL pública, usada para el health check post-deploy |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`, `NOTIFY_EMAIL` | Notificación por email si el deploy falla (compartidos a nivel repo consumidor, no por instancia) |

**Nota de seguridad — dos pares de SSH keys con direcciones de confianza opuestas, nunca reutilizar uno para el otro:**
- La **Deploy Key** de GitHub (Settings → Deploy keys del repo del proyecto) es para que el **servidor** haga `git clone`/`pull` **desde** GitHub — de solo lectura.
- La **`SSH_PRIVATE_KEY`** de este workflow es para que el **runner de Actions** se conecte **al servidor** y ejecute el deploy — necesita permisos de escritura sobre el proyecto, pero no debería ser el site-user completo si se puede evitar.

### Qué hace el job `deploy`

Por SSH (`appleboy/ssh-action`), con rollback automático (`trap ERR` → `git reset --hard` al SHA anterior + `artisan up`) si cualquier paso falla:

1. `artisan down` (modo mantenimiento)
2. `git pull origin main`
3. `composer install --no-dev --optimize-autoloader`
4. `artisan storage:link`
5. `npm ci` + build de Vite
6. Si `run_migrations=true`: backup de la DB (`mysqldump` comprimido, rota y conserva los últimos 7) → `artisan migrate --force`
7. `artisan livewire:publish --assets`, `filament:assets`, `optimize:clear`, `optimize`, `filament:optimize`
8. `artisan queue:restart`
9. `artisan up`

Todo el log de cada paso queda en `storage/logs/deploy.log` **en el servidor** (no en el runner) — es el primer lugar para diagnosticar un deploy fallido.

Después del deploy: un **health check** HTTP contra `APP_URL` (falla el job si devuelve 5xx), **notificación por email** si algo falló, y si todo salió bien, el job `tag` crea y pushea un tag `prod-<fecha>-<hora>` usando `GITHUB_TOKEN` (no SSH — el tagging no toca el servidor).

### Concurrencia

Cada `environment_name` tiene su propio grupo de concurrencia (`deploy-<environment_name>`) — dos deploys a la misma instancia no pueden correr en simultáneo, pero deploys a instancias distintas sí.

### Versionado

Con tags (`v1.0.0`, `v1.1.0`, `v1.2.0`, ...) además del SHA fijo que usa cada caller. Ver el doc `nominapp-pipeline-deploy-ssh-reusable-workflow.md` en el Drive de NextUp (carpeta `05-Infraestructura`) para el historial completo de versiones y qué cambió en cada una.

### Consumidores actuales

`nextup-py/nominapp` (instancias `bar777`, `arca`, `nextup-demo`), `nextup-py/itassets`, `nextup-py/nextup-landing-base`.

## `scripts/` — instalación de instancias de Nominapp

Scripts para instalar y desinstalar instancias de Nominapp en un VPS con CloudPanel (site, DB, `.env`, worker de Supervisor, etc.) — complementan el workflow de arriba pero no dependen de él. Ver `scripts/README.md` para el detalle de cada uno.

## Documentación relacionada (Drive de NextUp, carpeta `05-Infraestructura`)

- `nominapp-pipeline-deploy-ssh-reusable-workflow.md` — arquitectura completa de este pipeline, historial de versiones, gotchas de configuración
- `techforge-checklist-deploy-nominapp.md` — checklist manual paso a paso para instalar una instancia nueva
- `nominapp-script-instalador-automatizado.md` — documentación de `scripts/install-nominapp-client.sh`
