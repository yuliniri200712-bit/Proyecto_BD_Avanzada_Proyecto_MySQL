-- =====================================================================
-- 05_Triggers.sql
-- Tablas de auditoría/soporte + 20 triggers (disparadores)
-- =====================================================================
USE ecommerce_db;

-- ---------------------------------------------------------------------
-- TABLAS DE AUDITORÍA Y SOPORTE
-- ---------------------------------------------------------------------

-- Log de cambios de precio (tabla de auditoría principal pedida por el taller)
CREATE TABLE IF NOT EXISTS log_cambios_precio (
    id_log           INT AUTO_INCREMENT PRIMARY KEY,
    id_producto      INT NOT NULL,
    precio_anterior  DECIMAL(12,2) NOT NULL,
    precio_nuevo     DECIMAL(12,2) NOT NULL,
    usuario          VARCHAR(100) NOT NULL,
    fecha_cambio     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (id_producto) REFERENCES productos(id_producto)
);

-- Auditoría de altas de clientes
CREATE TABLE IF NOT EXISTS auditoria_clientes (
    id_auditoria  INT AUTO_INCREMENT PRIMARY KEY,
    id_cliente    INT NOT NULL,
    email         VARCHAR(150) NOT NULL,
    accion        VARCHAR(30)  NOT NULL,
    usuario       VARCHAR(100) NOT NULL,
    fecha         DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Historial de cambios de estado de pedidos
CREATE TABLE IF NOT EXISTS log_estado_pedidos (
    id_log           INT AUTO_INCREMENT PRIMARY KEY,
    id_venta         INT NOT NULL,
    estado_anterior  VARCHAR(30) NOT NULL,
    estado_nuevo     VARCHAR(30) NOT NULL,
    usuario          VARCHAR(100) NOT NULL,
    fecha_cambio     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Alertas de stock bajo
CREATE TABLE IF NOT EXISTS alertas_stock (
    id_alerta     INT AUTO_INCREMENT PRIMARY KEY,
    id_producto   INT NOT NULL,
    stock_actual  INT NOT NULL,
    stock_minimo  INT NOT NULL,
    mensaje       VARCHAR(255) NOT NULL,
    atendida      BOOLEAN NOT NULL DEFAULT FALSE,
    fecha         DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Archivo de ventas eliminadas (encabezado y detalle)
CREATE TABLE IF NOT EXISTS ventas_archivo (
    id_venta        INT PRIMARY KEY,
    id_cliente      INT NOT NULL,
    id_sucursal     INT NOT NULL,
    fecha_venta     DATETIME NOT NULL,
    estado          VARCHAR(30) NOT NULL,
    total           DECIMAL(14,2) NOT NULL,
    fecha_archivo   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    archivado_por   VARCHAR(100) NOT NULL
);
CREATE TABLE IF NOT EXISTS detalle_ventas_archivo (
    id_detalle                 INT PRIMARY KEY,
    id_venta                   INT NOT NULL,
    id_producto                INT NOT NULL,
    cantidad                   INT NOT NULL,
    precio_unitario_congelado  DECIMAL(12,2) NOT NULL
);

-- Permisos a nivel de aplicación y su auditoría.
-- MySQL NO permite crear triggers sobre las tablas del sistema (mysql.user, mysql.db...),
-- por eso los permisos que gestiona la aplicación se registran en esta tabla y
-- el trigger audita cualquier cambio sobre ella.
CREATE TABLE IF NOT EXISTS permisos_usuarios (
    id_permiso  INT AUTO_INCREMENT PRIMARY KEY,
    usuario     VARCHAR(80) NOT NULL,
    rol         VARCHAR(80) NOT NULL,
    activo      BOOLEAN NOT NULL DEFAULT TRUE,
    UNIQUE KEY uq_usuario_rol (usuario, rol)
);
CREATE TABLE IF NOT EXISTS log_cambios_permisos (
    id_log         INT AUTO_INCREMENT PRIMARY KEY,
    id_permiso     INT NOT NULL,
    usuario_afectado VARCHAR(80) NOT NULL,
    rol_anterior   VARCHAR(80),
    rol_nuevo      VARCHAR(80),
    activo_anterior BOOLEAN,
    activo_nuevo   BOOLEAN,
    modificado_por VARCHAR(100) NOT NULL,
    fecha          DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT IGNORE INTO permisos_usuarios (usuario, rol) VALUES
('admin_user','Administrador_Sistema'), ('marketing_user','Gerente_Marketing'),
('inventory_user','Empleado_Inventario'), ('support_user','Atencion_Cliente'),
('analyst_user','Analista_Datos'), ('auditor_user','Auditor_Financiero');

-- ---------------------------------------------------------------------
-- TRIGGERS
-- ---------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_audit_precio_producto_after_update;
DROP TRIGGER IF EXISTS trg_check_stock_before_insert_venta;
DROP TRIGGER IF EXISTS trg_update_stock_after_insert_venta;
DROP TRIGGER IF EXISTS trg_prevent_delete_categoria_with_products;
DROP TRIGGER IF EXISTS trg_log_new_customer_after_insert;
DROP TRIGGER IF EXISTS trg_update_total_gastado_cliente;
DROP TRIGGER IF EXISTS trg_restore_stock_after_cancel;
DROP TRIGGER IF EXISTS trg_set_fecha_modificacion_producto;
DROP TRIGGER IF EXISTS trg_prevent_negative_stock;
DROP TRIGGER IF EXISTS trg_capitalize_nombre_cliente;
DROP TRIGGER IF EXISTS trg_recalculate_total_venta_on_detalle_change;
DROP TRIGGER IF EXISTS trg_validate_stock_before_detail_update;
DROP TRIGGER IF EXISTS trg_recalculate_total_after_detail_delete;
DROP TRIGGER IF EXISTS trg_update_customer_spend_after_sale_insert;
DROP TRIGGER IF EXISTS trg_update_customer_spend_after_sale_delete;
DROP TRIGGER IF EXISTS trg_log_order_status_change;
DROP TRIGGER IF EXISTS trg_prevent_price_zero_or_less;
DROP TRIGGER IF EXISTS trg_send_stock_alert_on_low_stock;
DROP TRIGGER IF EXISTS trg_archive_deleted_venta;
DROP TRIGGER IF EXISTS trg_validate_email_format_on_customer;
DROP TRIGGER IF EXISTS trg_validate_email_format_on_customer_upd;
DROP TRIGGER IF EXISTS trg_update_last_order_date_customer;
DROP TRIGGER IF EXISTS trg_prevent_self_referral;
DROP TRIGGER IF EXISTS trg_log_permission_changes;
DROP TRIGGER IF EXISTS trg_assign_default_category_on_null;
DROP TRIGGER IF EXISTS trg_update_producto_count_in_categoria;
DROP TRIGGER IF EXISTS trg_update_producto_count_in_categoria_upd;
DROP TRIGGER IF EXISTS trg_update_producto_count_in_categoria_del;

DELIMITER $$

-- 1. trg_audit_precio_producto_after_update: guarda un log de cada cambio de precio.
CREATE TRIGGER trg_audit_precio_producto_after_update
AFTER UPDATE ON productos
FOR EACH ROW
BEGIN
    IF NEW.precio <> OLD.precio THEN
        INSERT INTO log_cambios_precio (id_producto, precio_anterior, precio_nuevo, usuario)
        VALUES (NEW.id_producto, OLD.precio, NEW.precio, USER());
    END IF;
END$$

-- 2. trg_check_stock_before_insert_venta: antes de registrar una línea de venta verifica
--    que haya stock y congela el precio si no se envió.
CREATE TRIGGER trg_check_stock_before_insert_venta
BEFORE INSERT ON detalle_ventas
FOR EACH ROW
BEGIN
    DECLARE v_stock INT;
    DECLARE v_activo BOOLEAN;
    DECLARE v_estado VARCHAR(30);
    SELECT estado INTO v_estado FROM ventas WHERE id_venta = NEW.id_venta;
    IF v_estado IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La venta no existe';
    ELSEIF v_estado IN ('Cancelado','Devolución Parcial','Devuelto Totalmente') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No se pueden agregar productos a una venta cerrada o en devolución';
    END IF;
    SELECT stock, activo INTO v_stock, v_activo FROM productos WHERE id_producto = NEW.id_producto;
    IF v_stock IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El producto no existe';
    ELSEIF v_activo = FALSE THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El producto está descontinuado';
    ELSEIF v_stock < NEW.cantidad THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Stock insuficiente para registrar la venta';
    END IF;
    IF NEW.precio_unitario_congelado IS NULL OR NEW.precio_unitario_congelado = 0 THEN
        SET NEW.precio_unitario_congelado = (SELECT precio FROM productos WHERE id_producto = NEW.id_producto);
    END IF;
END$$

-- 3. trg_update_stock_after_insert_venta: descuenta el stock vendido y actualiza el total de la venta.
CREATE TRIGGER trg_update_stock_after_insert_venta
AFTER INSERT ON detalle_ventas
FOR EACH ROW
BEGIN
    UPDATE productos SET stock = stock - NEW.cantidad WHERE id_producto = NEW.id_producto;
    UPDATE ventas SET total = fn_CalcularTotalVenta(NEW.id_venta) WHERE id_venta = NEW.id_venta;
END$$

-- 4. trg_prevent_delete_categoria_with_products: no permite borrar categorías con productos.
CREATE TRIGGER trg_prevent_delete_categoria_with_products
BEFORE DELETE ON categorias
FOR EACH ROW
BEGIN
    IF EXISTS (SELECT 1 FROM productos WHERE id_categoria = OLD.id_categoria) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'No se puede eliminar la categoría: tiene productos asociados';
    END IF;
END$$

-- 5. trg_log_new_customer_after_insert: registra en auditoría cada cliente nuevo.
CREATE TRIGGER trg_log_new_customer_after_insert
AFTER INSERT ON clientes
FOR EACH ROW
BEGIN
    IF NEW.id_referido_por IS NOT NULL AND NEW.id_referido_por = NEW.id_cliente THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Un cliente no puede referirse a sí mismo';
    END IF;
    INSERT INTO auditoria_clientes (id_cliente, email, accion, usuario)
    VALUES (NEW.id_cliente, NEW.email, 'ALTA_CLIENTE', USER());
END$$

-- 6. trg_update_total_gastado_cliente: recalcula clientes.total_gastado cuando cambia
--    el total o el estado de una venta (cubre compras nuevas, cancelaciones y devoluciones).
CREATE TRIGGER trg_update_total_gastado_cliente
AFTER UPDATE ON ventas
FOR EACH ROW
BEGIN
    IF NEW.total <> OLD.total OR NEW.estado <> OLD.estado THEN
        UPDATE clientes
        SET total_gastado = (SELECT COALESCE(SUM(total),0) FROM ventas
                             WHERE id_cliente = NEW.id_cliente
                               AND estado NOT IN ('Cancelado','Devuelto Totalmente'))
        WHERE id_cliente = NEW.id_cliente;
    END IF;
END$$

CREATE TRIGGER trg_restore_stock_after_cancel
AFTER UPDATE ON ventas
FOR EACH ROW
BEGIN
    IF NEW.estado = 'Cancelado' AND OLD.estado <> 'Cancelado' THEN
        UPDATE productos p
        JOIN (SELECT id_producto, SUM(cantidad) AS unidades
              FROM detalle_ventas WHERE id_venta = NEW.id_venta GROUP BY id_producto) d
          ON d.id_producto = p.id_producto
        SET p.stock = p.stock + d.unidades;
    END IF;
END$$

CREATE TRIGGER trg_update_customer_spend_after_sale_insert
AFTER INSERT ON ventas
FOR EACH ROW
BEGIN
    UPDATE clientes
    SET total_gastado = (SELECT COALESCE(SUM(total),0) FROM ventas
                         WHERE id_cliente = NEW.id_cliente
                           AND estado NOT IN ('Cancelado','Devuelto Totalmente'))
    WHERE id_cliente = NEW.id_cliente;
END$$

CREATE TRIGGER trg_update_customer_spend_after_sale_delete
AFTER DELETE ON ventas
FOR EACH ROW
BEGIN
    UPDATE clientes
    SET total_gastado = (SELECT COALESCE(SUM(total),0) FROM ventas
                         WHERE id_cliente = OLD.id_cliente
                           AND estado NOT IN ('Cancelado','Devuelto Totalmente'))
    WHERE id_cliente = OLD.id_cliente;
END$$

-- 7. trg_set_fecha_modificacion_producto: marca la fecha de última modificación.
CREATE TRIGGER trg_set_fecha_modificacion_producto
BEFORE UPDATE ON productos
FOR EACH ROW
BEGIN
    SET NEW.fecha_modificacion = NOW();
END$$

-- 8. trg_prevent_negative_stock: impide dejar stock negativo (mensaje claro antes del CHECK).
CREATE TRIGGER trg_prevent_negative_stock
BEFORE UPDATE ON productos
FOR EACH ROW
BEGIN
    IF NEW.stock < 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Operación rechazada: el stock no puede ser negativo';
    END IF;
END$$

-- 9. trg_capitalize_nombre_cliente: primera letra en mayúscula de nombre y apellido.
CREATE TRIGGER trg_capitalize_nombre_cliente
BEFORE INSERT ON clientes
FOR EACH ROW
BEGIN
    SET NEW.nombre   = CONCAT(UPPER(LEFT(TRIM(NEW.nombre),1)),   LOWER(SUBSTRING(TRIM(NEW.nombre),2)));
    SET NEW.apellido = CONCAT(UPPER(LEFT(TRIM(NEW.apellido),1)), LOWER(SUBSTRING(TRIM(NEW.apellido),2)));
END$$

-- 10. trg_recalculate_total_venta_on_detalle_change: si se modifica una línea de venta,
--     recalcula el total y ajusta el stock por la diferencia de unidades.
CREATE TRIGGER trg_recalculate_total_venta_on_detalle_change
AFTER UPDATE ON detalle_ventas
FOR EACH ROW
BEGIN
    IF NEW.id_producto = OLD.id_producto THEN
        UPDATE productos SET stock = stock - (NEW.cantidad - OLD.cantidad)
        WHERE id_producto = NEW.id_producto;
    ELSE
        UPDATE productos SET stock = stock + OLD.cantidad WHERE id_producto = OLD.id_producto;
        UPDATE productos SET stock = stock - NEW.cantidad WHERE id_producto = NEW.id_producto;
    END IF;
    UPDATE ventas SET total = fn_CalcularTotalVenta(NEW.id_venta) WHERE id_venta = NEW.id_venta;
    IF OLD.id_venta <> NEW.id_venta THEN
        UPDATE ventas SET total = fn_CalcularTotalVenta(OLD.id_venta) WHERE id_venta = OLD.id_venta;
    END IF;
END$$

CREATE TRIGGER trg_validate_stock_before_detail_update
BEFORE UPDATE ON detalle_ventas
FOR EACH ROW
BEGIN
    DECLARE v_stock INT;
    DECLARE v_activo BOOLEAN;
    DECLARE v_requerido INT;
    DECLARE v_estado_anterior VARCHAR(30);
    DECLARE v_estado_nuevo VARCHAR(30);

    SELECT estado INTO v_estado_anterior FROM ventas WHERE id_venta = OLD.id_venta;
    SELECT estado INTO v_estado_nuevo FROM ventas WHERE id_venta = NEW.id_venta;
    IF v_estado_anterior IN ('Cancelado','Devolución Parcial','Devuelto Totalmente')
       OR v_estado_nuevo IN ('Cancelado','Devolución Parcial','Devuelto Totalmente') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No se pueden modificar detalles de ventas cerradas o en devolución';
    END IF;

    IF NEW.id_producto <> OLD.id_producto OR NEW.cantidad > OLD.cantidad THEN
        SELECT stock, activo INTO v_stock, v_activo
        FROM productos WHERE id_producto = NEW.id_producto;
        IF v_stock IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El producto no existe';
        ELSEIF v_activo = FALSE THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El producto está descontinuado';
        END IF;
        SET v_requerido = NEW.cantidad - IF(NEW.id_producto = OLD.id_producto, OLD.cantidad, 0);
        IF v_stock < v_requerido THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Stock insuficiente para modificar el detalle';
        END IF;
    END IF;
END$$

CREATE TRIGGER trg_recalculate_total_after_detail_delete
AFTER DELETE ON detalle_ventas
FOR EACH ROW
BEGIN
    DECLARE v_estado VARCHAR(30);
    SELECT estado INTO v_estado FROM ventas WHERE id_venta = OLD.id_venta;
    IF v_estado IS NOT NULL AND v_estado NOT IN ('Cancelado','Devuelto Totalmente') THEN
        UPDATE productos SET stock = stock + OLD.cantidad WHERE id_producto = OLD.id_producto;
        UPDATE ventas SET total = fn_CalcularTotalVenta(OLD.id_venta) WHERE id_venta = OLD.id_venta;
    END IF;
END$$

-- 11. trg_log_order_status_change: audita cada cambio de estado de un pedido.
CREATE TRIGGER trg_log_order_status_change
AFTER UPDATE ON ventas
FOR EACH ROW
BEGIN
    IF NEW.estado <> OLD.estado THEN
        INSERT INTO log_estado_pedidos (id_venta, estado_anterior, estado_nuevo, usuario)
        VALUES (NEW.id_venta, OLD.estado, NEW.estado, USER());
    END IF;
END$$

-- 12. trg_prevent_price_zero_or_less: el precio nunca puede ser <= 0
--     (en INSERT lo garantiza además el CHECK chk_producto_precio).
CREATE TRIGGER trg_prevent_price_zero_or_less
BEFORE UPDATE ON productos
FOR EACH ROW
BEGIN
    IF NEW.precio <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El precio del producto debe ser mayor que cero';
    END IF;
END$$

-- 13. trg_send_stock_alert_on_low_stock: crea una alerta cuando el stock cruza el umbral mínimo.
CREATE TRIGGER trg_send_stock_alert_on_low_stock
AFTER UPDATE ON productos
FOR EACH ROW
BEGIN
    IF NEW.stock < NEW.stock_minimo AND OLD.stock >= OLD.stock_minimo THEN
        INSERT INTO alertas_stock (id_producto, stock_actual, stock_minimo, mensaje)
        VALUES (NEW.id_producto, NEW.stock, NEW.stock_minimo,
                CONCAT('Stock bajo en "', NEW.nombre, '" (SKU ', NEW.sku, '): quedan ', NEW.stock, ' unidades'));
    END IF;
END$$

-- 14. trg_archive_deleted_venta: antes de borrar una venta, copia encabezado y detalle al archivo.
--     (MySQL no tiene triggers INSTEAD OF: la venta sale de la tabla operativa pero
--      queda preservada íntegramente en ventas_archivo / detalle_ventas_archivo.)
CREATE TRIGGER trg_archive_deleted_venta
BEFORE DELETE ON ventas
FOR EACH ROW
BEGIN
    IF OLD.estado NOT IN ('Cancelado','Devuelto Totalmente') THEN
        UPDATE productos p
        JOIN (SELECT id_producto, SUM(cantidad) AS unidades
              FROM detalle_ventas WHERE id_venta = OLD.id_venta GROUP BY id_producto) d
          ON d.id_producto = p.id_producto
        SET p.stock = p.stock + d.unidades;
    END IF;
    INSERT INTO ventas_archivo (id_venta, id_cliente, id_sucursal, fecha_venta, estado, total, archivado_por)
    VALUES (OLD.id_venta, OLD.id_cliente, OLD.id_sucursal, OLD.fecha_venta, OLD.estado, OLD.total, USER());
    INSERT INTO detalle_ventas_archivo (id_detalle, id_venta, id_producto, cantidad, precio_unitario_congelado)
    SELECT id_detalle, id_venta, id_producto, cantidad, precio_unitario_congelado
    FROM detalle_ventas WHERE id_venta = OLD.id_venta;
END$$

-- 15. trg_validate_email_format_on_customer: valida el email al INSERTAR un cliente...
CREATE TRIGGER trg_validate_email_format_on_customer
BEFORE INSERT ON clientes
FOR EACH ROW
BEGIN
    IF NOT fn_ValidarFormatoEmail(NEW.email) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Formato de email inválido';
    END IF;
END$$

-- 15b. ...y al ACTUALIZARLO (MySQL exige un trigger por evento).
CREATE TRIGGER trg_validate_email_format_on_customer_upd
BEFORE UPDATE ON clientes
FOR EACH ROW
BEGIN
    IF NEW.email <> OLD.email AND NOT fn_ValidarFormatoEmail(NEW.email) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Formato de email inválido';
    END IF;
END$$

-- 16. trg_update_last_order_date_customer: guarda la fecha del último pedido del cliente.
CREATE TRIGGER trg_update_last_order_date_customer
AFTER INSERT ON ventas
FOR EACH ROW
BEGIN
    UPDATE clientes
    SET fecha_ultimo_pedido = GREATEST(COALESCE(fecha_ultimo_pedido, NEW.fecha_venta), NEW.fecha_venta)
    WHERE id_cliente = NEW.id_cliente;
END$$

-- 17. trg_prevent_self_referral: un cliente no puede referirse a sí mismo.
CREATE TRIGGER trg_prevent_self_referral
BEFORE UPDATE ON clientes
FOR EACH ROW
BEGIN
    IF NEW.id_referido_por IS NOT NULL AND NEW.id_referido_por = NEW.id_cliente THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Un cliente no puede referirse a sí mismo';
    END IF;
END$$

-- 18. trg_log_permission_changes: audita los cambios de permisos de los usuarios.
CREATE TRIGGER trg_log_permission_changes
AFTER UPDATE ON permisos_usuarios
FOR EACH ROW
BEGIN
    INSERT INTO log_cambios_permisos (id_permiso, usuario_afectado, rol_anterior, rol_nuevo,
                                      activo_anterior, activo_nuevo, modificado_por)
    VALUES (NEW.id_permiso, NEW.usuario, OLD.rol, NEW.rol, OLD.activo, NEW.activo, USER());
END$$

-- 19. trg_assign_default_category_on_null: categoría "General" si llega sin categoría.
CREATE TRIGGER trg_assign_default_category_on_null
BEFORE INSERT ON productos
FOR EACH ROW
BEGIN
    IF NEW.id_categoria IS NULL THEN
        SET NEW.id_categoria = (SELECT id_categoria FROM categorias WHERE nombre = 'General');
    END IF;
END$$

-- 20. trg_update_producto_count_in_categoria: mantiene el contador de productos por categoría (altas)...
CREATE TRIGGER trg_update_producto_count_in_categoria
AFTER INSERT ON productos
FOR EACH ROW
BEGIN
    UPDATE categorias SET total_productos = total_productos + 1 WHERE id_categoria = NEW.id_categoria;
END$$

-- 20b. ...y cuando un producto cambia de categoría.
CREATE TRIGGER trg_update_producto_count_in_categoria_upd
AFTER UPDATE ON productos
FOR EACH ROW
BEGIN
    IF NOT (NEW.id_categoria <=> OLD.id_categoria) THEN
        UPDATE categorias SET total_productos = total_productos - 1 WHERE id_categoria = OLD.id_categoria;
        UPDATE categorias SET total_productos = total_productos + 1 WHERE id_categoria = NEW.id_categoria;
    END IF;
END$$

CREATE TRIGGER trg_update_producto_count_in_categoria_del
AFTER DELETE ON productos
FOR EACH ROW
BEGIN
    IF OLD.id_categoria IS NOT NULL THEN
        UPDATE categorias SET total_productos = total_productos - 1
        WHERE id_categoria = OLD.id_categoria;
    END IF;
END$$

DELIMITER ;

-- ---------------------------------------------------------------------
-- Complemento de seguridad – requisito 6 de 04_Seguridad.sql
-- Auditor_Financiero puede leer el log de precios (la tabla ya existe en este punto).
-- ---------------------------------------------------------------------
GRANT SELECT ON ecommerce_db.log_cambios_precio TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.alertas_stock TO 'Analista_Datos';

-- Verificación
SHOW TRIGGERS FROM ecommerce_db;
