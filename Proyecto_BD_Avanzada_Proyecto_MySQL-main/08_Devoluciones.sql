-- =====================================================================
-- 08_Devoluciones.sql
-- Actividad: Procedimiento Almacenado - Proceso de Devolución Completo
-- Motor objetivo: MySQL 8.0+
--
-- Contenido:
--   1. Ajuste del ENUM ventas.estado con los estados 'Devolución Parcial'
--      y 'Devuelto Totalmente'.
--   2. CREATE TABLE devoluciones: registro de cada devolución para auditoría.
--   3. CREATE PROCEDURE sp_ProcesarDevolucion(id_venta, id_producto, cantidad_devuelta):
--        a) valida que la cantidad no supere lo comprado (descontando lo ya devuelto),
--        b) incrementa el stock del producto,
--        c) cambia el estado de la venta a 'Devolución Parcial' o 'Devuelto Totalmente',
--        d) inserta el registro en devoluciones,
--        e) todo dentro de UNA transacción (o se completa todo, o no cambia nada).
--
-- Requiere: haber ejecutado antes 01 a 07 (tablas, triggers, roles y usuarios).
-- Este script se puede ejecutar varias veces sin error (es idempotente).
-- =====================================================================
USE ecommerce_db;

-- ---------------------------------------------------------------------
-- 1. ESTADOS DE DEVOLUCIÓN EN LA TABLA ventas
-- ---------------------------------------------------------------------
-- Si la base se creó con una versión anterior de 01_Esquema_y_Datos.sql, el ENUM
-- tiene el estado 'Devuelto'. Se hace en tres pasos para no perder datos:
--   1) se amplía el ENUM con los estados viejo y nuevos,
--   2) las ventas en 'Devuelto' pasan a 'Devuelto Totalmente',
--   3) se deja el ENUM definitivo (sin 'Devuelto').
-- Si la base ya tiene el ENUM nuevo, los tres pasos no alteran ningún dato.
ALTER TABLE ventas MODIFY estado
    ENUM('Pendiente de Pago','Pagado','Procesando','Enviado','Entregado','Cancelado',
         'Devuelto','Devolución Parcial','Devuelto Totalmente')
    NOT NULL DEFAULT 'Pendiente de Pago';

UPDATE ventas SET estado = 'Devuelto Totalmente' WHERE estado = 'Devuelto';

ALTER TABLE ventas MODIFY estado
    ENUM('Pendiente de Pago','Pagado','Procesando','Enviado','Entregado','Cancelado',
         'Devolución Parcial','Devuelto Totalmente')
    NOT NULL DEFAULT 'Pendiente de Pago';

-- ---------------------------------------------------------------------
-- 2. TABLA devoluciones
-- ---------------------------------------------------------------------
-- Una fila por cada devolución procesada. Guarda una "foto" completa de la
-- operación (cantidades, precio, stock antes/después, estados antes/después,
-- usuario y fecha) para que auditoría pueda reconstruir lo ocurrido sin
-- depender de los valores actuales de otras tablas.
CREATE TABLE IF NOT EXISTS devoluciones (
    id_devolucion          INT AUTO_INCREMENT PRIMARY KEY,
    id_venta               INT NOT NULL,
    id_detalle             INT NOT NULL COMMENT 'Línea de detalle_ventas devuelta',
    id_producto            INT NOT NULL,
    id_cliente             INT NOT NULL,
    cantidad_comprada      INT NOT NULL COMMENT 'Unidades de la línea en la venta original',
    cantidad_devuelta      INT NOT NULL COMMENT 'Unidades devueltas en ESTA operación',
    precio_unitario        DECIMAL(12,2) NOT NULL COMMENT 'Precio congelado de la venta',
    monto_reembolso        DECIMAL(14,2) NOT NULL COMMENT 'cantidad_devuelta * precio_unitario',
    stock_anterior         INT NOT NULL,
    stock_nuevo            INT NOT NULL,
    estado_venta_anterior  VARCHAR(30) NOT NULL,
    estado_venta_nuevo     VARCHAR(30) NOT NULL,
    usuario                VARCHAR(100) NOT NULL COMMENT 'Usuario MySQL que ejecutó la devolución',
    fecha_devolucion       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_devolucion_cantidad CHECK (cantidad_devuelta > 0),
    CONSTRAINT chk_devolucion_tope     CHECK (cantidad_devuelta <= cantidad_comprada),
    CONSTRAINT chk_devolucion_monto    CHECK (monto_reembolso >= 0),
    -- ON DELETE RESTRICT: una venta (o una línea) con devoluciones registradas no se
    -- puede borrar; así el registro de auditoría nunca queda huérfano y el stock
    -- no se repone dos veces (los triggers de borrado también reponen stock).
    CONSTRAINT fk_devolucion_venta    FOREIGN KEY (id_venta)    REFERENCES ventas(id_venta)            ON DELETE RESTRICT,
    CONSTRAINT fk_devolucion_detalle  FOREIGN KEY (id_detalle)  REFERENCES detalle_ventas(id_detalle)  ON DELETE RESTRICT,
    CONSTRAINT fk_devolucion_producto FOREIGN KEY (id_producto) REFERENCES productos(id_producto),
    CONSTRAINT fk_devolucion_cliente  FOREIGN KEY (id_cliente)  REFERENCES clientes(id_cliente),
    INDEX idx_devolucion_venta_producto (id_venta, id_producto),
    INDEX idx_devolucion_fecha (fecha_devolucion)
);

-- ---------------------------------------------------------------------
-- 3. PROCEDIMIENTO sp_ProcesarDevolucion
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_ProcesarDevolucion;

DELIMITER $$

CREATE PROCEDURE sp_ProcesarDevolucion(
    IN p_id_venta          INT,
    IN p_id_producto       INT,
    IN p_cantidad_devuelta INT)
BEGIN
    DECLARE v_estado_actual   VARCHAR(30);
    DECLARE v_estado_nuevo    VARCHAR(30);
    DECLARE v_id_cliente      INT;
    DECLARE v_id_sucursal     INT;
    DECLARE v_id_detalle      INT;
    DECLARE v_cant_comprada   INT;
    DECLARE v_precio          DECIMAL(12,2);
    DECLARE v_ya_devuelto     INT;
    DECLARE v_disponible      INT;
    DECLARE v_stock_anterior  INT;
    DECLARE v_unid_venta      INT;
    DECLARE v_unid_devueltas  INT;
    DECLARE v_monto           DECIMAL(14,2);
    DECLARE v_id_devolucion   INT;
    DECLARE v_usuario         VARCHAR(80) DEFAULT SUBSTRING_INDEX(USER(), '@', 1);
    DECLARE v_msg             VARCHAR(255);

    -- Manejador de errores: ante CUALQUIER error (validación con SIGNAL, violación de
    -- una llave foránea, un CHECK, un trigger, etc.) se deshace toda la transacción
    -- con ROLLBACK y el error se re-lanza (RESIGNAL) para que quien llamó lo vea.
    -- Así se cumple la atomicidad: o se aplican los 4 cambios, o ninguno.
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    -- ---- Validación de parámetros (no requiere leer tablas) ----
    IF p_id_venta IS NULL OR p_id_producto IS NULL OR p_cantidad_devuelta IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Debe indicar id_venta, id_producto y cantidad_devuelta';
    END IF;
    IF p_cantidad_devuelta <= 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'La cantidad a devolver debe ser mayor que cero';
    END IF;

    START TRANSACTION;

        -- ---- Paso 0: bloquear y validar la venta ----
        -- FOR UPDATE bloquea la fila de la venta hasta el COMMIT/ROLLBACK. Si dos
        -- empleados procesan devoluciones de la misma venta al mismo tiempo, la
        -- segunda espera a la primera y luego ve las unidades ya devueltas, por lo
        -- que nunca se puede devolver más de lo comprado.
        SELECT estado, id_cliente, id_sucursal
          INTO v_estado_actual, v_id_cliente, v_id_sucursal
          FROM ventas
         WHERE id_venta = p_id_venta
         FOR UPDATE;

        IF v_estado_actual IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La venta no existe';
        END IF;

        -- Seguridad por sucursal (mismo criterio que sp_CambiarEstadoPedido):
        -- root y admin_user operan en todas; el resto solo en su sucursal.
        IF v_usuario NOT IN ('root','admin_user')
           AND NOT EXISTS (SELECT 1 FROM usuarios_sucursales
                            WHERE usuario_db = v_usuario AND id_sucursal = v_id_sucursal) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La venta no pertenece a la sucursal del usuario';
        END IF;

        -- Solo se devuelve lo que ya salió de bodega. Una venta con devolución
        -- parcial puede recibir más devoluciones; una devuelta totalmente, no.
        IF v_estado_actual NOT IN ('Enviado','Entregado','Devolución Parcial') THEN
            -- (MySQL limita MESSAGE_TEXT a 128 caracteres; por eso LEFT(..., 128))
            SET v_msg = CONCAT('Venta en estado "', v_estado_actual,
                               '": solo se devuelven ventas Enviadas, Entregadas o con Devolución Parcial');
            SET v_msg = LEFT(v_msg, 128);
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
        END IF;

        -- ---- Paso 1: validar la cantidad contra lo comprado ----
        -- detalle_ventas tiene UNIQUE (id_venta, id_producto): hay como máximo una línea.
        SELECT id_detalle, cantidad, precio_unitario_congelado
          INTO v_id_detalle, v_cant_comprada, v_precio
          FROM detalle_ventas
         WHERE id_venta = p_id_venta AND id_producto = p_id_producto
         FOR UPDATE;

        IF v_id_detalle IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El producto no pertenece a esa venta';
        END IF;

        -- Unidades de este producto ya devueltas en operaciones anteriores.
        SELECT COALESCE(SUM(cantidad_devuelta), 0)
          INTO v_ya_devuelto
          FROM devoluciones
         WHERE id_venta = p_id_venta AND id_producto = p_id_producto;

        SET v_disponible = v_cant_comprada - v_ya_devuelto;

        IF p_cantidad_devuelta > v_disponible THEN
            SET v_msg = CONCAT('Cantidad a devolver (', p_cantidad_devuelta,
                               ') mayor que la disponible para devolución (', v_disponible,
                               '): comprado ', v_cant_comprada, ', ya devuelto ', v_ya_devuelto);
            SET v_msg = LEFT(v_msg, 128);
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
        END IF;

        -- ---- Paso 2: reponer el inventario ----
        SELECT stock INTO v_stock_anterior
          FROM productos WHERE id_producto = p_id_producto
         FOR UPDATE;

        UPDATE productos
           SET stock = stock + p_cantidad_devuelta
         WHERE id_producto = p_id_producto;
        -- (los triggers de productos actualizan fecha_modificacion automáticamente)

        -- ---- Paso 3: calcular y actualizar el estado de la venta ----
        -- Se compara el total de unidades de la venta con el total devuelto
        -- (devoluciones anteriores + la actual) sumando TODOS sus productos.
        SELECT SUM(cantidad) INTO v_unid_venta
          FROM detalle_ventas WHERE id_venta = p_id_venta;

        SELECT COALESCE(SUM(cantidad_devuelta), 0) + p_cantidad_devuelta
          INTO v_unid_devueltas
          FROM devoluciones WHERE id_venta = p_id_venta;

        SET v_estado_nuevo = IF(v_unid_devueltas >= v_unid_venta,
                                'Devuelto Totalmente', 'Devolución Parcial');

        IF v_estado_nuevo <> v_estado_actual THEN
            -- Los triggers de ventas registran el cambio en log_estado_pedidos y
            -- recalculan clientes.total_gastado (que excluye 'Devuelto Totalmente').
            UPDATE ventas SET estado = v_estado_nuevo WHERE id_venta = p_id_venta;
        END IF;

        -- ---- Paso 4: registrar la devolución (auditoría) ----
        SET v_monto = p_cantidad_devuelta * v_precio;

        INSERT INTO devoluciones (id_venta, id_detalle, id_producto, id_cliente,
                                  cantidad_comprada, cantidad_devuelta, precio_unitario,
                                  monto_reembolso, stock_anterior, stock_nuevo,
                                  estado_venta_anterior, estado_venta_nuevo, usuario)
        VALUES (p_id_venta, v_id_detalle, p_id_producto, v_id_cliente,
                v_cant_comprada, p_cantidad_devuelta, v_precio,
                v_monto, v_stock_anterior, v_stock_anterior + p_cantidad_devuelta,
                v_estado_actual, v_estado_nuevo, USER());
        SET v_id_devolucion = LAST_INSERT_ID();

        -- El reembolso queda como saldo a favor del cliente (tabla ya existente
        -- creditos_cliente), enlazado con el número de devolución.
        INSERT INTO creditos_cliente (id_cliente, id_venta, monto, motivo)
        VALUES (v_id_cliente, p_id_venta, v_monto,
                CONCAT('Devolución #', v_id_devolucion, ': ', p_cantidad_devuelta,
                       ' unidad(es) del producto ', p_id_producto));

    COMMIT;

    -- Resumen de la operación para quien ejecutó el procedimiento.
    SELECT v_id_devolucion                                   AS id_devolucion,
           p_id_venta                                        AS id_venta,
           p_id_producto                                     AS id_producto,
           p_cantidad_devuelta                               AS unidades_devueltas,
           v_disponible - p_cantidad_devuelta                AS unidades_aun_devolvibles,
           v_monto                                           AS monto_reembolso,
           v_stock_anterior                                  AS stock_anterior,
           v_stock_anterior + p_cantidad_devuelta            AS stock_nuevo,
           v_estado_actual                                   AS estado_anterior,
           v_estado_nuevo                                    AS estado_nuevo;
END$$

DELIMITER ;

-- ---------------------------------------------------------------------
-- 4. PERMISOS
-- ---------------------------------------------------------------------
-- El equipo de atención al cliente (rol creado en 04_Seguridad.sql) puede ejecutar
-- el procedimiento. Como es SQL SECURITY DEFINER (valor por defecto), no necesita
-- permisos directos sobre ventas, productos ni devoluciones: solo EXECUTE.
GRANT EXECUTE ON PROCEDURE ecommerce_db.sp_ProcesarDevolucion TO 'Atencion_Cliente';
-- Auditoría financiera puede consultar el historial de devoluciones.
GRANT SELECT ON ecommerce_db.devoluciones TO 'Auditor_Financiero';

-- ---------------------------------------------------------------------
-- Ejemplos de uso (comentados para no modificar datos al ejecutar el script)
-- ---------------------------------------------------------------------
-- Venta 3: 3 Camisetas (producto 7) y 1 Jean (producto 8), estado 'Entregado'.
-- CALL sp_ProcesarDevolucion(3, 7, 2);   -- devuelve 2 camisetas  -> 'Devolución Parcial'
-- CALL sp_ProcesarDevolucion(3, 7, 2);   -- ERROR: solo queda 1 camiseta por devolver
-- CALL sp_ProcesarDevolucion(3, 7, 1);   -- última camiseta       -> sigue 'Devolución Parcial'
-- CALL sp_ProcesarDevolucion(3, 8, 1);   -- el jean               -> 'Devuelto Totalmente'
-- SELECT * FROM devoluciones WHERE id_venta = 3;
