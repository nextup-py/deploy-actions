# scripts/

Scripts de infraestructura para instalaciones de Nominapp (y potencialmente otros proyectos Laravel de NextUp) sobre VPS con CloudPanel.

## install-nominapp-client.sh

Wizard interactivo que automatiza la instalación de una instancia nueva de Nominapp para un cliente (o instancia interna, como el demo) en un VPS con CloudPanel: sitio, SSH deploy key, clonado del repo, base de datos, `.env`, `composer`/`npm`/migraciones/seeders, permisos y worker de Supervisor.

**Uso:**

```bash
sudo bash install-nominapp-client.sh
```

Corre directamente en el VPS destino, con sudo. Es idempotente — el progreso se guarda en `/root/.nominapp-installs/<cliente>.state`; si se corta a mitad de camino, correrlo de nuevo con el mismo slug retoma desde donde quedó.

Pasos que requieren consola web externa (DNS, Resend, Google Maps, Document Root en CloudPanel, secrets de GitHub Actions) quedan como pausas manuales explícitas — el script no los automatiza.

**Documentación completa** (historial de bugs corregidos, decisiones de arquitectura, automatizaciones pendientes): ver `nominapp-script-instalador-automatizado.md` en el Drive de NextUp, carpeta `05-Infraestructura`.

## uninstall-nominapp-client.sh

Da de baja por completo una instancia instalada con `install-nominapp-client.sh`: sitio en CloudPanel, base de datos y usuario MySQL, worker de Supervisor y SSH deploy key. Hace **backup automático** (`mysqldump` + `.env`) antes de borrar nada, en `/root/backups/<cliente>-<timestamp>/`.

**Uso:**

```bash
sudo bash uninstall-nominapp-client.sh
```

Operación destructiva e irreversible (fuera del backup) — pide confirmar el slug del cliente **dos veces** antes de tocar nada. Lee el `state.file` del instalador si existe, para no tener que repetir datos.

**No automatiza** (imprime instrucciones al final): eliminar la Deploy Key y los repository secrets en GitHub, el job correspondiente en `deploy.yml`, el registro DNS, y las credenciales en Bitwarden.
