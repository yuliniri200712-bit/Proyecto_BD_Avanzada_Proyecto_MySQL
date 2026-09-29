# Proyecto de Base de Datos para un E-commerce

## Descripción breve

Este proyecto implementa el núcleo de la base de datos de una tienda en línea sobre **MySQL 8.0**. Gestiona el catálogo de productos, las categorías, los proveedores, los clientes y todo el ciclo de vida de las ventas (orden → pago → despacho → entrega → devolución), garantizando la integridad de los datos con llaves foráneas, restricciones `CHECK`, triggers y transacciones. Sobre ese núcleo se construyen 20 consultas analíticas, 20 funciones, un esquema de seguridad con roles y usuarios, los 20 requisitos de triggers (cubiertos por triggers principales y auxiliares), 20 eventos programados y 20 procedimientos almacenados. El precio de cada producto vendido queda **congelado** en `detalle_ventas.precio_unitario_congelado`, de modo que el historial de ventas no cambia aunque el precio del catálogo cambie.

## Integrantes

**Equipo:** Proyecto MySQL

- Andrés Julian Rolon Ibero

## Requisitos

- MySQL Server **8.0.30 o superior** (se usan CTE, funciones de ventana, `JSON_TABLE`, roles y `REVOKE IF EXISTS`).
- Ejecutar los scripts con un usuario administrador (por ejemplo `root`), porque se crean roles, usuarios y eventos.
- Cliente configurado en `utf8mb4` (los datos tienen tildes y eñes).
- La aplicación debe generar y verificar contraseñas de clientes con PBKDF2-HMAC-SHA256, 600 000 iteraciones y salt aleatorio; MySQL solo almacena el hash.
- `04_Seguridad.sql` requiere permisos para crear usuarios/roles, instalar `validate_password` y usar `SET PERSIST`. Revisa las cuentas `root` antes de ejecutarlo.

## Instrucciones de ejecución

Ejecute los archivos **en este orden**, desde la raíz del repositorio:

| # | Archivo | Qué hace |
|---|---------|----------|
| 1 | `01_Esquema_y_Datos.sql` | Crea la base `ecommerce_db`, todas las tablas y carga los datos de ejemplo (8 categorías, 6 proveedores, 25 productos, 20 clientes, 40 ventas). |
| 2 | `02_Consultas_Avanzadas.sql` | Ejecuta las 20 consultas de análisis y reporteo. |
| 3 | `03_Funciones.sql` | Crea las 20 funciones (UDF) y muestra una prueba rápida. |
| 4 | `04_Seguridad.sql` | Crea roles, usuarios, vistas seguras y permisos. |
| 5 | `05_Triggers.sql` | Crea las tablas de auditoría (`log_cambios_precio`, etc.) y los triggers requeridos y auxiliares. |
| 6 | `06_Eventos.sql` | Crea las tablas de reportes (`reporte_ventas_semanales`, etc.), los 20 eventos y activa el `event_scheduler`. |
| 7 | `07_Procedimientos_Almacenados.sql` | Crea los 20 procedimientos almacenados. |

Desde la terminal:

```bash
mysql -u root -p --default-character-set=utf8mb4 < 01_Esquema_y_Datos.sql
mysql -u root -p --default-character-set=utf8mb4 < 02_Consultas_Avanzadas.sql
mysql -u root -p --default-character-set=utf8mb4 < 03_Funciones.sql
mysql -u root -p --default-character-set=utf8mb4 < 04_Seguridad.sql
mysql -u root -p --default-character-set=utf8mb4 < 05_Triggers.sql
mysql -u root -p --default-character-set=utf8mb4 < 06_Eventos.sql
mysql -u root -p --default-character-set=utf8mb4 < 07_Procedimientos_Almacenados.sql
```

O, dentro del cliente `mysql`: `SOURCE 01_Esquema_y_Datos.sql;` y así sucesivamente.

En resumen:

1. Ejecutar `01_Esquema_y_Datos.sql` para crear la estructura y cargar los datos iniciales.
2. Ejecutar los scripts del `02` al `07` en orden para implementar toda la lógica avanzada.

> **Importante:** `01_Esquema_y_Datos.sql` ejecuta `DROP DATABASE IF EXISTS ecommerce_db`; destruye y recrea la base. No lo ejecutes sobre datos que quieras conservar. Los demás scripts eliminan y recrean algunos objetos, y `04_Seguridad.sql` solo instala `validate_password` si aún no está instalado.

> **Dependencias entre archivos:** algunos permisos se conceden donde nace el objeto: el `SELECT` de `Auditor_Financiero` sobre `log_cambios_precio` (final de `05`) y los permisos `EXECUTE` sobre reportes y cambio de estado (final de `07`). Las lecturas de ventas se canalizan por vistas y procedimientos filtrados por sucursal.

El programador de eventos requiere que `event_scheduler` permanezca habilitado después de reiniciar MySQL. Configúralo también en el archivo de configuración del servidor (`event_scheduler=ON`) si el servicio no permite persistir variables desde SQL.

## Pruebas rápidas

```sql
USE ecommerce_db;

-- Venta transaccional (valida stock, congela precio, descuenta inventario y calcula total)
CALL sp_RealizarNuevaVenta(5, 3, '[{"id_producto":2,"cantidad":1},{"id_producto":6,"cantidad":2}]', @venta);
CALL sp_ProcesarPago(@venta, 2100000, 'PSE');
CALL sp_CambiarEstadoPedido(@venta, 'Procesando');
SELECT * FROM log_estado_pedidos;

-- Trigger de precios
UPDATE productos SET precio = 4300000 WHERE id_producto = 1;
SELECT * FROM log_cambios_precio;

-- Seguridad: este usuario NO puede cambiar precios
-- mysql -u inventory_user -p'Inv#Bodega2026!' ecommerce_db
-- UPDATE productos SET precio = 1 WHERE id_producto = 1;   -- ERROR 1143
```

## Usuarios creados

| Usuario | Contraseña | Rol |
|---------|-----------|-----|
| `admin_user` | `Adm1n#Ecommerce2026` | Administrador_Sistema |
| `marketing_user` | `Mkt#Ventas2026!` | Gerente_Marketing |
| `inventory_user` | `Inv#Bodega2026!` | Empleado_Inventario |
| `support_user` | `Sop#Clientes2026!` | Atencion_Cliente |
| `analyst_user` | `Ana#Datos2026!` | Analista_Datos (máx. 500 consultas/hora) |
| `auditor_user` | `Aud#Finanzas2026!` | Auditor_Financiero |
| `visitor_user` | `Vis#Catalogo2026!` | Visitante |

Todas las contraseñas son de ejemplo para el entorno académico; cámbielas en un entorno real.

## Documentación

La explicación del modelo, seguridad, hashing de contraseñas y límites del entorno está en [`DOCUMENTACION.md`](DOCUMENTACION.md).

## Entrega

Repositorio: `Proyecto_BD_Avanzada_Proyecto_MySQL`. Antes de entregar, crea el repositorio privado con el nombre solicitado e invita al trainer como colaborador. La configuración del repositorio y la invitación deben comprobarse en GitHub; no se realizan desde estos scripts.
