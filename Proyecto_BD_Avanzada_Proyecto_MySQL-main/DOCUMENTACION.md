# Documentación técnica

## Modelo

La base `ecommerce_db` organiza el catálogo en categorías jerárquicas y proveedores; cada producto pertenece a una categoría y a un proveedor. Las ventas pertenecen a clientes y sucursales, y sus líneas se almacenan en `detalle_ventas`. `precio_unitario_congelado` conserva el precio histórico sin depender del precio actual del catálogo.

Las tablas auxiliares cubren visitas, carritos, promociones, reseñas, pagos, créditos, notificaciones, ajustes de inventario y auditoría. El stock de ejemplo se carga después de los detalles históricos: se descuentan las unidades de ventas que no estén canceladas o devueltas.

## Acceso por sucursal

`usuarios_sucursales` asigna cuentas MySQL a sucursales. Las cuentas operativas leen ventas, detalles, pagos, créditos y notificaciones por vistas filtradas; los procedimientos de reportes y cambio de estado verifican la misma asignación. `root` y `admin_user` conservan acceso global como administradores.

MySQL Community no ofrece políticas generales de seguridad por fila. Por ello, las cuentas operativas no reciben `SELECT` directo sobre las tablas de ventas; cualquier nuevo procedimiento o vista que exponga esos datos debe aplicar el filtro de sucursal antes de conceder `EXECUTE` o `SELECT`.

## Contraseñas de clientes

La tabla almacena hashes con el formato:

```text
pbkdf2_sha256$600000$<salt-base64>$<derived-key-base64>
```

La aplicación genera un salt criptográficamente aleatorio de 16 bytes y deriva 32 bytes con PBKDF2-HMAC-SHA256 y 600 000 iteraciones. La verificación vuelve a derivar el hash y compara los bytes en tiempo constante. Nunca debe guardarse ni enviarse la contraseña en texto plano a `sp_RegistrarNuevoCliente`; ese procedimiento recibe `p_hash_contrasena`.

Ejemplo de generación en Node.js:

```js
const { randomBytes, pbkdf2Sync } = require('node:crypto');

function hashPassword(password) {
  const salt = randomBytes(16);
  const derived = pbkdf2Sync(password, salt, 600000, 32, 'sha256');
  return `pbkdf2_sha256$600000$${salt.toString('base64')}$${derived.toString('base64')}`;
}
```

La complejidad de la contraseña en texto plano también debe validarse en la aplicación. La función SQL de complejidad es una validación auxiliar, no un mecanismo de almacenamiento ni de autenticación.

## Requisitos operativos y límites

- Instala MySQL 8.0.30 o superior. Ejecuta los scripts como administrador y en el orden indicado en `README.md`.
- `01_Esquema_y_Datos.sql` elimina y recrea `ecommerce_db`; es un reinicio destructivo.
- `03_Funciones.sql` cambia `log_bin_trust_function_creators` globalmente para poder crear funciones con binlog habilitado.
- `04_Seguridad.sql` crea cuentas locales, configura `validate_password`, persiste variables y elimina cuentas `root` con host no local. Revisa primero las cuentas existentes y conserva únicamente los accesos administrativos locales que realmente necesites.
- Limita también el acceso remoto con `bind-address` y reglas de firewall. El script SQL no reemplaza esos controles de infraestructura.
- Habilita `event_scheduler` en la configuración del servidor para que permanezca activo tras reiniciar MySQL.
- El evento de respaldo mantiene copias dentro de la misma base; no sustituye un respaldo externo, restaurable y probado.
- `performance_schema.host_cache` presenta contadores por host y el log de errores registra rechazos de autenticación, pero no es un registro SQL persistente de cada intento fallido. Para auditoría individual persistente se requiere MySQL Enterprise Audit u otra solución de auditoría/centralización configurada en el servidor.
- No se puede comprobar desde los scripts si el repositorio de GitHub es privado ni si el trainer fue invitado. Eso debe confirmarse en GitHub antes de la entrega.
