# Proceso de Devolución Completo — `sp_ProcesarDevolucion`

Documentación de la actividad **"Procedimiento Almacenado – Proceso de Devolución Completo"**, implementada en [`08_Devoluciones.sql`](08_Devoluciones.sql).

## 1. Objetivo

El equipo de atención al cliente necesita procesar devoluciones de forma **automatizada y segura**. Con una sola llamada:

```sql
CALL sp_ProcesarDevolucion(id_venta, id_producto, cantidad_devuelta);
```

el sistema:

1. Valida que la cantidad a devolver **no supere la cantidad comprada** en esa venta.
2. **Incrementa el stock** del producto devuelto en `productos`.
3. Actualiza el **estado de la venta** a `'Devolución Parcial'` o `'Devuelto Totalmente'`.
4. **Inserta un registro** en la nueva tabla `devoluciones` para auditorías futuras.
5. Ejecuta todo **dentro de una transacción**: o se completa todo, o no se modifica nada.

## 2. Contenido del script `08_Devoluciones.sql`

| Sección | Qué hace |
|---|---|
| 1. Estados de devolución | Ajusta el `ENUM` de `ventas.estado` para incluir `'Devolución Parcial'` y `'Devuelto Totalmente'`. Si la base tenía el estado antiguo `'Devuelto'`, lo convierte a `'Devuelto Totalmente'` sin perder datos. |
| 2. `CREATE TABLE devoluciones` | Tabla de auditoría con una fila por cada devolución. |
| 3. `CREATE PROCEDURE sp_ProcesarDevolucion` | El procedimiento transaccional. |
| 4. Permisos | `EXECUTE` para el rol `Atencion_Cliente` y `SELECT` sobre `devoluciones` para `Auditor_Financiero`. |

El script es **idempotente**: se puede ejecutar varias veces sin errores.

## 3. Tabla `devoluciones`

Guarda una "foto" completa de cada operación, de modo que una auditoría puede reconstruir lo ocurrido sin depender de los valores actuales de otras tablas.

| Columna | Descripción |
|---|---|
| `id_devolucion` | Identificador (PK, autoincremental). |
| `id_venta` | Venta afectada (FK → `ventas`). |
| `id_detalle` | Línea de la venta devuelta (FK → `detalle_ventas`). |
| `id_producto` | Producto devuelto (FK → `productos`). |
| `id_cliente` | Cliente de la venta (FK → `clientes`). |
| `cantidad_comprada` | Unidades compradas en esa línea. |
| `cantidad_devuelta` | Unidades devueltas **en esta operación**. |
| `precio_unitario` | Precio congelado de la venta (no el precio actual del catálogo). |
| `monto_reembolso` | `cantidad_devuelta × precio_unitario`. |
| `stock_anterior` / `stock_nuevo` | Inventario del producto antes y después. |
| `estado_venta_anterior` / `estado_venta_nuevo` | Estado de la venta antes y después. |
| `usuario` | Usuario MySQL que ejecutó la devolución (`USER()`). |
| `fecha_devolucion` | Fecha y hora de la operación. |

**Restricciones:**

- `CHECK (cantidad_devuelta > 0)`, `CHECK (cantidad_devuelta <= cantidad_comprada)` y `CHECK (monto_reembolso >= 0)`.
- Llaves foráneas con `ON DELETE RESTRICT` hacia `ventas` y `detalle_ventas`: **una venta con devoluciones no se puede borrar**. Así el registro de auditoría nunca queda huérfano y el stock no se repone dos veces, ya que los triggers de borrado también lo reponen.
- Índices por `(id_venta, id_producto)` y por `fecha_devolucion` para que las validaciones y los reportes sean rápidos.

## 4. Funcionamiento del procedimiento, paso a paso

```
CALL sp_ProcesarDevolucion(p_id_venta, p_id_producto, p_cantidad_devuelta)
│
├─ Validar parámetros: ninguno NULL y cantidad > 0
│
├─ START TRANSACTION
│   ├─ Paso 0  Bloquear la venta (SELECT ... FOR UPDATE) y validar:
│   │          · que exista
│   │          · que pertenezca a la sucursal del usuario (salvo root/admin_user)
│   │          · que esté en 'Enviado', 'Entregado' o 'Devolución Parcial'
│   ├─ Paso 1  Validar la cantidad:
│   │          disponible = comprada − ya devuelta (suma en devoluciones)
│   │          si cantidad_devuelta > disponible → error
│   ├─ Paso 2  UPDATE productos SET stock = stock + cantidad_devuelta
│   ├─ Paso 3  Estado de la venta:
│   │          total devuelto (todas las líneas) ≥ total comprado → 'Devuelto Totalmente'
│   │          en otro caso                                    → 'Devolución Parcial'
│   ├─ Paso 4  INSERT INTO devoluciones (...)   ← registro de auditoría
│   │          INSERT INTO creditos_cliente (...) ← saldo a favor del cliente
├─ COMMIT
│
└─ Devuelve un resumen (id_devolucion, unidades, reembolso, stock y estados)

Si ocurre CUALQUIER error en medio → EXIT HANDLER → ROLLBACK + RESIGNAL
```

### 4.1 Validación de la cantidad (requisito 1)

No basta con comparar contra lo comprado: un cliente podría devolver 2 unidades hoy y 2 mañana de una compra de 3. Por eso se calcula:

```
disponible = cantidad comprada − SUM(cantidad_devuelta en devoluciones anteriores)
```

Si `cantidad_devuelta > disponible`, se lanza un error explicativo, por ejemplo:

```
Cantidad a devolver (2) mayor que la disponible para devolución (1): comprado 3, ya devuelto 2
```

### 4.2 Reposición de inventario (requisito 2)

`UPDATE productos SET stock = stock + cantidad_devuelta`. Se guardan el stock anterior y el nuevo en `devoluciones`. Los triggers existentes de `productos` actualizan `fecha_modificacion` automáticamente.

### 4.3 Estado de la venta (requisito 3)

Se compara el total de unidades de la venta (todas sus líneas) con el total devuelto, incluida la devolución actual:

| Situación | Estado resultante |
|---|---|
| Se devolvió una parte de las unidades | `Devolución Parcial` |
| Se devolvieron todas las unidades de todos los productos | `Devuelto Totalmente` |

Al cambiar el estado, los triggers de `05_Triggers.sql` hacen dos cosas más:

- Registran el cambio en `log_estado_pedidos`.
- Recalculan `clientes.total_gastado`. Una venta `Devuelto Totalmente` deja de contar como gasto, igual que una cancelada.

### 4.4 Registro para auditoría (requisito 4)

Cada llamada exitosa inserta exactamente una fila en `devoluciones`. Además, el reembolso se registra como saldo a favor en `creditos_cliente`, con el motivo `Devolución #<id>`.

### 4.5 Transacción y atomicidad (requisito 5)

```sql
DECLARE EXIT HANDLER FOR SQLEXCEPTION
BEGIN
    ROLLBACK;   -- deshace stock, estado, log y registros
    RESIGNAL;   -- re-lanza el error original a quien llamó
END;
```

- Todas las modificaciones ocurren entre `START TRANSACTION` y `COMMIT`.
- Si falla cualquier paso (una validación, una llave foránea, un `CHECK` o un trigger), el manejador hace `ROLLBACK` y **nada queda modificado**.
- **Concurrencia:** `SELECT ... FOR UPDATE` bloquea la fila de la venta, el detalle y el producto. Si dos empleados devuelven la misma venta a la vez, el segundo espera al primero y ve las unidades ya devueltas, así que es imposible devolver más de lo comprado.

## 5. Reglas de negocio y seguridad

| Regla | Detalle |
|---|---|
| Estados que admiten devolución | `Enviado`, `Entregado` y `Devolución Parcial`. Se rechazan `Pendiente de Pago`, `Pagado`, `Procesando`, `Cancelado` y `Devuelto Totalmente`. |
| Seguridad por sucursal | `root` y `admin_user` pueden devolver cualquier venta. Los demás usuarios solo las de su sucursal (`usuarios_sucursales`), con el mismo criterio que `sp_CambiarEstadoPedido`. |
| Permisos | `Atencion_Cliente` tiene `EXECUTE` sobre el procedimiento, pero **no** puede modificar `productos` ni `ventas` directamente. El procedimiento corre con `SQL SECURITY DEFINER`. |
| Precio del reembolso | Siempre el `precio_unitario_congelado` de la venta, no el precio actual del catálogo. |
| Ventas en devolución | Los triggers impiden agregar o modificar líneas de una venta en `Devolución Parcial` o `Devuelto Totalmente`. |
| Único camino para devolver | `sp_CambiarEstadoPedido` ya no permite pasar una venta a un estado de devolución. Así se evita marcar una devolución sin reponer stock ni dejar registro. |

## 6. Mensajes de error

| Caso | Mensaje |
|---|---|
| Parámetro NULL | `Debe indicar id_venta, id_producto y cantidad_devuelta` |
| Cantidad ≤ 0 | `La cantidad a devolver debe ser mayor que cero` |
| Venta inexistente | `La venta no existe` |
| Venta de otra sucursal | `La venta no pertenece a la sucursal del usuario` |
| Estado no válido | `Venta en estado "<estado>": solo se devuelven ventas Enviadas, Entregadas o con Devolución Parcial` |
| Producto ajeno a la venta | `El producto no pertenece a esa venta` |
| Cantidad excesiva | `Cantidad a devolver (X) mayor que la disponible para devolución (Y): comprado A, ya devuelto B` |

Todos usan `SQLSTATE '45000'` (error 1644).

## 7. Ejemplo de uso

La venta 3 (cliente 1, `Entregado`) tiene 3 camisetas (producto 7, $45.000 c/u) y 1 jean (producto 8, $139.000).

```sql
CALL sp_ProcesarDevolucion(3, 7, 2);  -- 2 camisetas → 'Devolución Parcial', reembolso 90.000
CALL sp_ProcesarDevolucion(3, 7, 2);  -- ERROR: solo queda 1 camiseta por devolver (no cambia nada)
CALL sp_ProcesarDevolucion(3, 7, 1);  -- última camiseta → sigue 'Devolución Parcial'
CALL sp_ProcesarDevolucion(3, 8, 1);  -- el jean → 'Devuelto Totalmente'

SELECT * FROM devoluciones WHERE id_venta = 3;
SELECT * FROM log_estado_pedidos WHERE id_venta = 3;
```

Resultado de la primera llamada:

| id_devolucion | id_venta | id_producto | unidades_devueltas | unidades_aun_devolvibles | monto_reembolso | stock_anterior | stock_nuevo | estado_anterior | estado_nuevo |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 3 | 7 | 2 | 1 | 90000.00 | 111 | 113 | Entregado | Devolución Parcial |

## 8. Cambios en los demás archivos

| Archivo | Cambio |
|---|---|
| `01_Esquema_y_Datos.sql` | El `ENUM` de `ventas.estado` cambia `'Devuelto'` por `'Devolución Parcial'` y `'Devuelto Totalmente'`. |
| `02`, `03`, `06`, `07` | Las consultas, funciones, eventos y reportes que excluían `'Devuelto'` ahora excluyen `'Devuelto Totalmente'`. |
| `05_Triggers.sql` | Lo mismo, y además los triggers de `detalle_ventas` bloquean cambios en ventas con `'Devolución Parcial'`. |
| `07_Procedimientos_Almacenados.sql` | Se retiró la versión antigua de `sp_ProcesarDevolucion` (4 parámetros, sin tabla propia) y `sp_CambiarEstadoPedido` ya no asigna estados de devolución. |

> Una venta en `Devolución Parcial` sigue contando en los reportes de ingresos por su total original. El dinero devuelto queda en `devoluciones.monto_reembolso` y en `creditos_cliente`.

## 9. Pruebas

El archivo [`pruebas/pruebas_devoluciones.sql`](pruebas/pruebas_devoluciones.sql) contiene 31 verificaciones automáticas. Muestran `PASA` o `FALLA` y **modifican datos**, así que deben ejecutarse sobre una base recién creada.

```bash
mysql -u root -p --default-character-set=utf8mb4 < pruebas/pruebas_devoluciones.sql
```

Qué cubren:

- Devolución parcial, devoluciones sucesivas y devolución total.
- Rechazo por cantidad excesiva, cero, negativa o NULL, por venta inexistente, por producto ajeno y por estado no permitido.
- **Atomicidad:** se fuerza un fallo en el último paso con un trigger temporal y se comprueba que stock, estado, log y créditos quedan intactos.
- Integración con triggers: log de estado, `total_gastado`, bloqueo de nuevas líneas y bloqueo de borrado de ventas con devoluciones.

Resultado en MySQL 8.0.46: **31/31 PASA**. Además, se verificó manualmente:

- `support_user` puede devolver ventas de su sucursal y recibe un error con las de otra sucursal.
- `support_user` no puede hacer `UPDATE` directo sobre `productos`.
- `auditor_user` puede consultar `devoluciones`.
- `08_Devoluciones.sql` migra correctamente una base creada con el esquema anterior (estado `'Devuelto'`).
