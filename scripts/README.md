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
