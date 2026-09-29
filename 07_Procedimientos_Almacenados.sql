-- =====================================================================
-- 07_Procedimientos_Almacenados.sql
-- 20 procedimientos almacenados (operaciones complejas y transaccionales)
-- =====================================================================
USE ecommerce_db;

DROP PROCEDURE IF EXISTS sp_RealizarNuevaVenta;
DROP PROCEDURE IF EXISTS sp_AgregarNuevoProducto;
DROP PROCEDURE IF EXISTS sp_ActualizarDireccionCliente;
DROP PROCEDURE IF EXISTS sp_ProcesarDevolucion;
DROP PROCEDURE IF EXISTS sp_ObtenerHistorialComprasCliente;
DROP PROCEDURE IF EXISTS sp_AjustarNivelStock;
DROP PROCEDURE IF EXISTS sp_EliminarClienteDeFormaSegura;
DROP PROCEDURE IF EXISTS sp_AplicarDescuentoPorCategoria;
DROP PROCEDURE IF EXISTS sp_GenerarReporteMensualVentas;
DROP PROCEDURE IF EXISTS sp_CambiarEstadoPedido;
DROP PROCEDURE IF EXISTS sp_RegistrarNuevoCliente;
DROP PROCEDURE IF EXISTS sp_ObtenerDetallesProductoCompleto;
DROP PROCEDURE IF EXISTS sp_FusionarCuentasCliente;
DROP PROCEDURE IF EXISTS sp_AsignarProductoAProveedor;
DROP PROCEDURE IF EXISTS sp_BuscarProductos;
DROP PROCEDURE IF EXISTS sp_ObtenerDashboardAdmin;
DROP PROCEDURE IF EXISTS sp_ProcesarPago;
DROP PROCEDURE IF EXISTS `sp_AñadirReseñaProducto`;
DROP PROCEDURE IF EXISTS sp_ObtenerProductosRelacionados;
DROP PROCEDURE IF EXISTS sp_MoverProductosEntreCategorias;

DELIMITER $$

-- 1. sp_RealizarNuevaVenta: procesa una venta completa en UNA transacción.
--    p_items es un JSON: '[{"id_producto":1,"cantidad":2},{"id_producto":6,"cantidad":1}]'
--    Los triggers validan stock, congelan el precio, descuentan inventario y calculan el total.
--    Si cualquier línea falla, se deshace toda la venta (ROLLBACK).
CREATE PROCEDURE sp_RealizarNuevaVenta(
    IN  p_id_cliente  INT,
    IN  p_id_sucursal INT,
    IN  p_items       JSON,
    OUT p_id_venta    INT)
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_id_venta = NULL;
        RESIGNAL;
    END;

    IF NOT EXISTS (SELECT 1 FROM clientes WHERE id_cliente = p_id_cliente AND activo = TRUE AND eliminado_en IS NULL) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cliente inexistente o inactivo';
    END IF;
    IF p_items IS NULL OR JSON_LENGTH(p_items) = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La venta debe tener al menos un producto';
    END IF;
    IF EXISTS (SELECT 1 FROM JSON_TABLE(p_items, '$[*]' COLUMNS (
                   id_producto INT PATH '$.id_producto',
                   cantidad INT PATH '$.cantidad')) j
               WHERE j.id_producto IS NULL OR j.cantidad IS NULL OR j.cantidad <= 0) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cada producto debe tener un ID y una cantidad mayor que cero';
    END IF;

    START TRANSACTION;
        -- (se lee la dirección en una variable: un INSERT...SELECT sobre clientes chocaría
        --  con el trigger que actualiza clientes.fecha_ultimo_pedido)
        SELECT direccion_envio INTO @dir FROM clientes WHERE id_cliente = p_id_cliente;
        INSERT INTO ventas (id_cliente, id_sucursal, estado, direccion_envio)
        VALUES (p_id_cliente, COALESCE(p_id_sucursal, 3), 'Pendiente de Pago', @dir);
        SET p_id_venta = LAST_INSERT_ID();

        -- Bloqueo de las filas de producto involucradas (evita sobreventa concurrente)
        SELECT COUNT(*) INTO @bloqueados FROM productos
        WHERE id_producto IN (SELECT j.id_producto FROM JSON_TABLE(p_items, '$[*]'
                              COLUMNS (id_producto INT PATH '$.id_producto')) j)
        FOR UPDATE;

        -- precio 0 => el trigger trg_check_stock_before_insert_venta congela el precio actual.
        -- (No se hace JOIN con productos: el trigger de stock actualiza esa tabla y MySQL
        --  no permite modificar una tabla leída por la misma sentencia.)
        -- Si un producto no existe o no hay stock, el trigger lanza el error y todo se revierte.
        INSERT INTO detalle_ventas (id_venta, id_producto, cantidad, precio_unitario_congelado)
        SELECT p_id_venta, j.id_producto, SUM(j.cantidad), 0
        FROM JSON_TABLE(p_items, '$[*]' COLUMNS (
                 id_producto INT PATH '$.id_producto',
                 cantidad    INT PATH '$.cantidad')) j
        GROUP BY j.id_producto;
    COMMIT;

    SELECT v.id_venta, v.fecha_venta, v.estado, v.total,
           fn_CalcularIVA(v.id_venta)        AS iva_19,
           fn_CalcularCostoEnvio(v.id_venta) AS costo_envio,
           fn_EstimarFechaEntrega(v.id_venta) AS entrega_estimada
    FROM ventas v WHERE v.id_venta = p_id_venta;
END$$

-- 2. sp_AgregarNuevoProducto: inserta un producto con SKU autogenerado y valida sus datos.
CREATE PROCEDURE sp_AgregarNuevoProducto(
    IN  p_nombre        VARCHAR(150),
    IN  p_descripcion   TEXT,
    IN  p_precio        DECIMAL(12,2),
    IN  p_costo         DECIMAL(12,2),
    IN  p_stock         INT,
    IN  p_stock_minimo  INT,
    IN  p_peso_kg       DECIMAL(8,3),
    IN  p_id_categoria  INT,
    IN  p_id_proveedor  INT,
    OUT p_id_producto   INT)
BEGIN
    IF EXISTS (SELECT 1 FROM productos WHERE nombre = p_nombre) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ya existe un producto con ese nombre';
    END IF;
    IF p_precio <= 0 OR p_costo < 0 OR COALESCE(p_stock,0) < 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Precio debe ser > 0, costo y stock >= 0';
    END IF;
    IF p_precio < p_costo THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El precio de venta no puede ser menor que el costo';
    END IF;
    IF p_id_proveedor IS NULL OR NOT EXISTS (SELECT 1 FROM proveedores WHERE id_proveedor = p_id_proveedor) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Debe indicar un proveedor existente';
    END IF;

    -- El SKU se calcula antes del INSERT (la función lee categorias, que el trigger de contador modifica)
    SET @sku = fn_GenerarSKU(p_nombre, COALESCE(p_id_categoria,
                            (SELECT id_categoria FROM categorias WHERE nombre = 'General')));
    INSERT INTO productos (nombre, descripcion, precio, costo, stock, stock_minimo, sku, peso_kg,
                           id_categoria, id_proveedor)
    VALUES (p_nombre, p_descripcion, p_precio, p_costo, COALESCE(p_stock,0), COALESCE(p_stock_minimo,5),
            @sku, COALESCE(p_peso_kg,0.5), p_id_categoria, p_id_proveedor);   -- NULL -> trigger asigna "General"
    SET p_id_producto = LAST_INSERT_ID();

    SELECT * FROM productos WHERE id_producto = p_id_producto;
END$$

-- 3. sp_ActualizarDireccionCliente: actualiza la dirección del cliente y la de sus pedidos
--    que aún no se han despachado (Pendiente de Pago, Pagado, Procesando).
CREATE PROCEDURE sp_ActualizarDireccionCliente(
    IN p_id_cliente INT,
    IN p_direccion  VARCHAR(255),
    IN p_ciudad     VARCHAR(80),
    IN p_region     VARCHAR(80))
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

    IF NOT EXISTS (SELECT 1 FROM clientes WHERE id_cliente = p_id_cliente) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cliente no encontrado';
    END IF;

    START TRANSACTION;
        UPDATE clientes
        SET direccion_envio = p_direccion,
            ciudad = COALESCE(p_ciudad, ciudad),
            region = COALESCE(p_region, region)
        WHERE id_cliente = p_id_cliente;

        UPDATE ventas SET direccion_envio = p_direccion
        WHERE id_cliente = p_id_cliente
          AND estado IN ('Pendiente de Pago','Pagado','Procesando');
        SET @pedidos_actualizados = ROW_COUNT();

        INSERT INTO auditoria_clientes (id_cliente, email, accion, usuario)
        SELECT id_cliente, email, 'CAMBIO_DIRECCION', USER() FROM clientes WHERE id_cliente = p_id_cliente;
    COMMIT;

    SELECT p_id_cliente AS id_cliente, p_direccion AS nueva_direccion,
           @pedidos_actualizados AS pedidos_abiertos_actualizados;
END$$

-- 4. sp_ProcesarDevolucion: devuelve unidades de un producto de una venta, repone stock
--    y genera un crédito a favor del cliente por el precio congelado.
CREATE PROCEDURE sp_ProcesarDevolucion(
    IN p_id_venta    INT,
    IN p_id_producto INT,
    IN p_cantidad    INT,
    IN p_motivo      VARCHAR(255))
BEGIN
    DECLARE v_comprado   INT;
    DECLARE v_devuelto   INT;
    DECLARE v_precio     DECIMAL(12,2);
    DECLARE v_estado     VARCHAR(30);
    DECLARE v_id_cliente INT;
    DECLARE v_credito    DECIMAL(12,2);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

    START TRANSACTION;
    SELECT estado, id_cliente INTO v_estado, v_id_cliente
    FROM ventas WHERE id_venta = p_id_venta FOR UPDATE;
    IF v_estado IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La venta no existe';
    ELSEIF v_estado NOT IN ('Entregado','Enviado') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Solo se aceptan devoluciones de pedidos enviados o entregados';
    END IF;

    SELECT SUM(cantidad), MAX(precio_unitario_congelado) INTO v_comprado, v_precio
    FROM detalle_ventas WHERE id_venta = p_id_venta AND id_producto = p_id_producto;
    -- unidades ya devueltas antes para esta venta/producto
    SELECT COALESCE(SUM(ROUND(monto / v_precio)),0) INTO v_devuelto
    FROM creditos_cliente WHERE id_venta = p_id_venta AND motivo LIKE CONCAT('DEV#', p_id_producto, '#%');

    IF v_comprado IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El producto no pertenece a esa venta';
    ELSEIF p_cantidad <= 0 OR p_cantidad > v_comprado - v_devuelto THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cantidad a devolver inválida';
    END IF;

    SET v_credito = p_cantidad * v_precio;

    UPDATE productos SET stock = stock + p_cantidad WHERE id_producto = p_id_producto;
    INSERT INTO creditos_cliente (id_cliente, id_venta, monto, motivo)
    VALUES (v_id_cliente, p_id_venta, v_credito, CONCAT('DEV#', p_id_producto, '# ', COALESCE(p_motivo,'')));
    -- si se devolvió todo el pedido, la venta pasa a 'Devuelto'
    IF (SELECT SUM(cantidad) FROM detalle_ventas WHERE id_venta = p_id_venta) =
       (SELECT COALESCE(SUM(ROUND(c.monto / d.precio_unitario_congelado)),0)
          FROM creditos_cliente c
          JOIN detalle_ventas d ON d.id_venta = c.id_venta
               AND c.motivo LIKE CONCAT('DEV#', d.id_producto, '#%')
         WHERE c.id_venta = p_id_venta) THEN
        UPDATE ventas SET estado = 'Devuelto' WHERE id_venta = p_id_venta;
    END IF;
    COMMIT;

    SELECT p_id_venta AS id_venta, p_id_producto AS id_producto, p_cantidad AS unidades_devueltas,
           v_credito AS credito_generado,
           (SELECT SUM(monto) FROM creditos_cliente WHERE id_cliente = v_id_cliente) AS saldo_credito_cliente;
END$$

-- 5. sp_ObtenerHistorialComprasCliente: resumen + detalle de todas las compras de un cliente.
CREATE PROCEDURE sp_ObtenerHistorialComprasCliente(IN p_id_cliente INT)
BEGIN
    SELECT c.id_cliente, fn_FormatearNombreCompleto(c.id_cliente) AS cliente, c.email,
           fn_ContarVentasCliente(c.id_cliente)          AS compras,
           c.total_gastado, c.nivel_lealtad,
           fn_ObtenerUltimaFechaCompra(c.id_cliente)     AS ultima_compra,
           fn_CalcularDiasDesdeUltimaCompra(c.id_cliente) AS dias_desde_ultima_compra
    FROM clientes c WHERE c.id_cliente = p_id_cliente;

    SELECT v.id_venta, v.fecha_venta, v.estado, p.nombre AS producto, d.cantidad,
           d.precio_unitario_congelado, d.cantidad * d.precio_unitario_congelado AS subtotal, v.total AS total_venta
    FROM ventas v
    JOIN detalle_ventas d ON d.id_venta = v.id_venta
    JOIN productos p      ON p.id_producto = d.id_producto
    WHERE v.id_cliente = p_id_cliente
    ORDER BY v.fecha_venta DESC, d.id_detalle;
END$$

-- 6. sp_AjustarNivelStock: ajuste manual de inventario (conteo físico, merma, etc.) con motivo.
CREATE PROCEDURE sp_AjustarNivelStock(
    IN p_id_producto INT,
    IN p_nuevo_stock INT,
    IN p_motivo      VARCHAR(255))
BEGIN
    DECLARE v_anterior INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

    IF p_motivo IS NULL OR TRIM(p_motivo) = '' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Debe indicar el motivo del ajuste';
    END IF;

    START TRANSACTION;
        SELECT stock INTO v_anterior FROM productos WHERE id_producto = p_id_producto FOR UPDATE;
        IF v_anterior IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Producto no encontrado';
        END IF;
        UPDATE productos SET stock = p_nuevo_stock WHERE id_producto = p_id_producto; -- trigger impide negativos
        INSERT INTO ajustes_inventario (id_producto, stock_anterior, stock_nuevo, motivo, usuario)
        VALUES (p_id_producto, v_anterior, p_nuevo_stock, p_motivo, USER());
    COMMIT;

    SELECT p_id_producto AS id_producto, v_anterior AS stock_anterior, p_nuevo_stock AS stock_nuevo,
           p_nuevo_stock - v_anterior AS diferencia, p_motivo AS motivo;
END$$

-- 7. sp_EliminarClienteDeFormaSegura: anonimiza (derecho al olvido) sin romper las ventas históricas.
CREATE PROCEDURE sp_EliminarClienteDeFormaSegura(IN p_id_cliente INT)
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

    IF NOT EXISTS (SELECT 1 FROM clientes WHERE id_cliente = p_id_cliente AND eliminado_en IS NULL) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cliente no encontrado o ya eliminado';
    END IF;

    START TRANSACTION;
        UPDATE clientes
        SET nombre           = 'Anónimo',
            apellido         = CONCAT('Cliente ', id_cliente),
            email            = CONCAT('anonimo_', id_cliente, '@eliminado.invalid'),
            contrasena       = SHA2(CONCAT(UUID(), RAND()), 256),
            direccion_envio  = NULL,
            fecha_nacimiento = NULL,
            activo           = FALSE,
            eliminado_en     = NOW()
        WHERE id_cliente = p_id_cliente;
        UPDATE ventas SET direccion_envio = NULL WHERE id_cliente = p_id_cliente;
        DELETE FROM carritos WHERE id_cliente = p_id_cliente;
        INSERT INTO auditoria_clientes (id_cliente, email, accion, usuario)
        VALUES (p_id_cliente, CONCAT('anonimo_', p_id_cliente, '@eliminado.invalid'), 'ANONIMIZADO', USER());
    COMMIT;

    SELECT id_cliente, nombre, apellido, email, activo, eliminado_en,
           (SELECT COUNT(*) FROM ventas WHERE id_cliente = p_id_cliente) AS ventas_conservadas
    FROM clientes WHERE id_cliente = p_id_cliente;
END$$

-- 8. sp_AplicarDescuentoPorCategoria: rebaja el precio de todos los productos activos
--    de una categoría (cada cambio queda en log_cambios_precio vía trigger).
--    Protección: el precio nunca queda por debajo del costo.
CREATE PROCEDURE sp_AplicarDescuentoPorCategoria(IN p_id_categoria INT, IN p_porcentaje DECIMAL(5,2))
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

    IF p_porcentaje <= 0 OR p_porcentaje >= 100 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El porcentaje debe estar entre 0 y 100 (exclusivo)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM categorias WHERE id_categoria = p_id_categoria) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Categoría no encontrada';
    END IF;

    START TRANSACTION;
        UPDATE productos
        SET precio = GREATEST(fn_AplicarDescuento(precio, p_porcentaje), costo)
        WHERE id_categoria = p_id_categoria AND activo = TRUE;
        SET @afectados = ROW_COUNT();
    COMMIT;

    SELECT @afectados AS productos_actualizados;
    SELECT id_producto, nombre, costo, precio AS precio_nuevo FROM productos WHERE id_categoria = p_id_categoria;
END$$

-- 9. sp_GenerarReporteMensualVentas: reporte completo de un mes (4 conjuntos de resultados).
CREATE PROCEDURE sp_GenerarReporteMensualVentas(IN p_anio INT, IN p_mes INT)
BEGIN
    DECLARE v_ini DATE DEFAULT MAKEDATE(p_anio, 1) + INTERVAL (p_mes - 1) MONTH;
    DECLARE v_fin DATE DEFAULT LAST_DAY(MAKEDATE(p_anio, 1) + INTERVAL (p_mes - 1) MONTH);
    DECLARE v_sucursal INT DEFAULT NULL;

    IF SUBSTRING_INDEX(USER(), '@', 1) NOT IN ('root','admin_user') THEN
        SELECT id_sucursal INTO v_sucursal FROM usuarios_sucursales
        WHERE usuario_db = SUBSTRING_INDEX(USER(), '@', 1);
        IF v_sucursal IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El usuario no tiene una sucursal asignada';
        END IF;
    END IF;

    -- a) Resumen general
    SELECT DATE_FORMAT(v_ini,'%Y-%m')                                           AS periodo,
           SUM(estado NOT IN ('Cancelado','Devuelto'))                          AS ventas_validas,
           SUM(estado = 'Cancelado')                                            AS ventas_canceladas,
           COALESCE(SUM(CASE WHEN estado NOT IN ('Cancelado','Devuelto') THEN total END),0) AS ingresos,
           COALESCE(ROUND(AVG(CASE WHEN estado NOT IN ('Cancelado','Devuelto') THEN total END),2),0) AS ticket_promedio,
           COUNT(DISTINCT id_cliente)                                           AS clientes_compradores
        FROM ventas
        WHERE DATE(fecha_venta) BETWEEN v_ini AND v_fin
            AND (v_sucursal IS NULL OR id_sucursal = v_sucursal);

    -- b) Ventas por categoría
    SELECT c.nombre AS categoria, SUM(d.cantidad) AS unidades,
           SUM(d.cantidad * d.precio_unitario_congelado) AS ingresos,
           SUM(d.cantidad * (d.precio_unitario_congelado - p.costo)) AS margen
    FROM ventas v JOIN detalle_ventas d ON d.id_venta = v.id_venta
    JOIN productos p ON p.id_producto = d.id_producto
    JOIN categorias c ON c.id_categoria = p.id_categoria
        WHERE DATE(v.fecha_venta) BETWEEN v_ini AND v_fin AND v.estado NOT IN ('Cancelado','Devuelto')
            AND (v_sucursal IS NULL OR v.id_sucursal = v_sucursal)
    GROUP BY c.nombre ORDER BY ingresos DESC;

    -- c) Top 5 productos del mes
    SELECT p.nombre, SUM(d.cantidad) AS unidades, SUM(d.cantidad * d.precio_unitario_congelado) AS ingresos
    FROM ventas v JOIN detalle_ventas d ON d.id_venta = v.id_venta
    JOIN productos p ON p.id_producto = d.id_producto
        WHERE DATE(v.fecha_venta) BETWEEN v_ini AND v_fin AND v.estado NOT IN ('Cancelado','Devuelto')
            AND (v_sucursal IS NULL OR v.id_sucursal = v_sucursal)
    GROUP BY p.nombre ORDER BY ingresos DESC LIMIT 5;

    -- d) Ventas por sucursal
    SELECT s.nombre AS sucursal, COUNT(v.id_venta) AS ventas, COALESCE(SUM(v.total),0) AS ingresos
    FROM sucursales s LEFT JOIN ventas v ON v.id_sucursal = s.id_sucursal
            AND DATE(v.fecha_venta) BETWEEN v_ini AND v_fin AND v.estado NOT IN ('Cancelado','Devuelto')
            AND (v_sucursal IS NULL OR v.id_sucursal = v_sucursal)
        WHERE v_sucursal IS NULL OR s.id_sucursal = v_sucursal
    GROUP BY s.nombre ORDER BY ingresos DESC;
END$$

-- 10. sp_CambiarEstadoPedido: cambia el estado respetando el flujo permitido y deja una
--     notificación en la bandeja de salida para otros sistemas (logística, email, ERP).
CREATE PROCEDURE sp_CambiarEstadoPedido(IN p_id_venta INT, IN p_nuevo_estado VARCHAR(30))
BEGIN
    DECLARE v_actual VARCHAR(30);
    DECLARE v_permitido BOOLEAN DEFAULT FALSE;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

    SELECT estado INTO v_actual FROM ventas WHERE id_venta = p_id_venta;
    IF v_actual IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Pedido no encontrado';
    END IF;

    IF SUBSTRING_INDEX(USER(), '@', 1) NOT IN ('root','admin_user')
       AND NOT EXISTS (
           SELECT 1 FROM ventas v
           JOIN usuarios_sucursales us ON us.id_sucursal = v.id_sucursal
           WHERE v.id_venta = p_id_venta
             AND us.usuario_db = SUBSTRING_INDEX(USER(), '@', 1)
       ) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El pedido no pertenece a la sucursal del usuario';
    END IF;

    -- Máquina de estados del pedido
    SET v_permitido = CASE
        WHEN v_actual = 'Pendiente de Pago' AND p_nuevo_estado IN ('Pagado','Cancelado')      THEN TRUE
        WHEN v_actual = 'Pagado'            AND p_nuevo_estado IN ('Procesando','Cancelado')   THEN TRUE
        WHEN v_actual = 'Procesando'        AND p_nuevo_estado IN ('Enviado','Cancelado')      THEN TRUE
        WHEN v_actual = 'Enviado'           AND p_nuevo_estado IN ('Entregado','Devuelto')     THEN TRUE
        WHEN v_actual = 'Entregado'         AND p_nuevo_estado = 'Devuelto'                    THEN TRUE
        ELSE FALSE END;
    IF NOT v_permitido THEN
        SET @msg = CONCAT('Transición no permitida: ', v_actual, ' -> ', p_nuevo_estado);
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = @msg;
    END IF;

    START TRANSACTION;
        UPDATE ventas SET estado = p_nuevo_estado WHERE id_venta = p_id_venta;   -- trigger audita el cambio
        INSERT INTO notificaciones (sistema_destino, tipo, payload)
        VALUES (CASE WHEN p_nuevo_estado IN ('Enviado','Entregado') THEN 'LOGISTICA' ELSE 'EMAIL' END,
                'CAMBIO_ESTADO_PEDIDO',
                JSON_OBJECT('id_venta', p_id_venta, 'anterior', v_actual, 'nuevo', p_nuevo_estado,
                            'fecha', NOW()));
    COMMIT;

    SELECT p_id_venta AS id_venta, v_actual AS estado_anterior, p_nuevo_estado AS estado_nuevo;
END$$

-- 11. sp_RegistrarNuevoCliente: valida email único y con formato, contraseña compleja y guarda el hash.
CREATE PROCEDURE sp_RegistrarNuevoCliente(
    IN  p_nombre      VARCHAR(80),
    IN  p_apellido    VARCHAR(80),
    IN  p_email       VARCHAR(150),
    IN  p_hash_contrasena VARCHAR(255),
    IN  p_direccion   VARCHAR(255),
    IN  p_ciudad      VARCHAR(80),
    IN  p_region      VARCHAR(80),
    IN  p_fecha_nac   DATE,
    OUT p_id_cliente  INT)
BEGIN
    SET p_email = LOWER(TRIM(p_email));
    IF NOT fn_ValidarFormatoEmail(p_email) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Formato de email inválido';
    END IF;
    IF EXISTS (SELECT 1 FROM clientes WHERE email = p_email) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El email ya está registrado';
    END IF;
    IF p_hash_contrasena IS NULL
       OR NOT REGEXP_LIKE(p_hash_contrasena,
          '^pbkdf2_sha256\\$600000\\$[A-Za-z0-9+/]{22}==\\$[A-Za-z0-9+/]{43}=$') THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Se requiere un hash PBKDF2-SHA256 válido generado por la aplicación';
    END IF;

    INSERT INTO clientes (nombre, apellido, email, contrasena, direccion_envio, ciudad, region, fecha_nacimiento)
    VALUES (p_nombre, p_apellido, p_email, p_hash_contrasena, p_direccion, p_ciudad, p_region, p_fecha_nac);
    SET p_id_cliente = LAST_INSERT_ID();

    SELECT id_cliente, nombre, apellido, email, fecha_registro FROM clientes WHERE id_cliente = p_id_cliente;
END$$

-- 12. sp_ObtenerDetallesProductoCompleto: ficha completa (producto + categoría + proveedor + métricas).
CREATE PROCEDURE sp_ObtenerDetallesProductoCompleto(IN p_id_producto INT)
BEGIN
    SELECT p.id_producto, p.sku, p.nombre, p.descripcion, p.precio, p.costo,
           ROUND(100*(p.precio - p.costo)/p.precio, 2) AS margen_pct,
           p.stock, p.stock_minimo, p.ubicacion, p.peso_kg, p.activo, p.fecha_creacion, p.fecha_modificacion,
           c.id_categoria, c.nombre AS categoria,
           pr.id_proveedor, pr.nombre AS proveedor, pr.email_contacto, pr.telefono_contacto,
           (SELECT COALESCE(SUM(d.cantidad),0) FROM detalle_ventas d JOIN ventas v ON v.id_venta = d.id_venta
             WHERE d.id_producto = p.id_producto AND v.estado NOT IN ('Cancelado','Devuelto')) AS unidades_vendidas,
           (SELECT ROUND(AVG(calificacion),1) FROM resenas r WHERE r.id_producto = p.id_producto) AS calificacion_promedio,
           (SELECT COUNT(*) FROM resenas r WHERE r.id_producto = p.id_producto) AS num_resenas,
           (SELECT COUNT(*) FROM visitas_producto vp WHERE vp.id_producto = p.id_producto) AS visitas
    FROM productos p
    LEFT JOIN categorias  c  ON c.id_categoria = p.id_categoria
    LEFT JOIN proveedores pr ON pr.id_proveedor = p.id_proveedor
    WHERE p.id_producto = p_id_producto;
END$$

-- 13. sp_FusionarCuentasCliente: pasa todo lo del cliente duplicado al principal y anonimiza el duplicado.
CREATE PROCEDURE sp_FusionarCuentasCliente(IN p_id_principal INT, IN p_id_duplicado INT)
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

    IF p_id_principal = p_id_duplicado THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Las cuentas a fusionar deben ser distintas';
    END IF;
    IF (SELECT COUNT(*) FROM clientes WHERE id_cliente IN (p_id_principal, p_id_duplicado)
                                        AND eliminado_en IS NULL) <> 2 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Alguna de las cuentas no existe o está eliminada';
    END IF;

    START TRANSACTION;
        UPDATE ventas           SET id_cliente = p_id_principal WHERE id_cliente = p_id_duplicado;
        UPDATE carritos         SET id_cliente = p_id_principal WHERE id_cliente = p_id_duplicado;
        UPDATE visitas_producto SET id_cliente = p_id_principal WHERE id_cliente = p_id_duplicado;
        UPDATE creditos_cliente SET id_cliente = p_id_principal WHERE id_cliente = p_id_duplicado;
        -- reseñas: si ambos reseñaron el mismo producto se conserva la del principal
        DELETE r FROM resenas r
        JOIN resenas rp ON rp.id_producto = r.id_producto AND rp.id_cliente = p_id_principal
        WHERE r.id_cliente = p_id_duplicado;
        UPDATE resenas          SET id_cliente = p_id_principal WHERE id_cliente = p_id_duplicado;
        UPDATE clientes SET id_referido_por = p_id_principal
        WHERE id_referido_por = p_id_duplicado AND id_cliente <> p_id_principal;

        -- recalcular métricas del principal
        UPDATE clientes
        SET total_gastado = (SELECT COALESCE(SUM(total),0) FROM ventas
                             WHERE id_cliente = p_id_principal AND estado NOT IN ('Cancelado','Devuelto')),
            fecha_ultimo_pedido = (SELECT MAX(fecha_venta) FROM ventas WHERE id_cliente = p_id_principal),
            nivel_lealtad = fn_DeterminarEstadoLealtad(p_id_principal)
        WHERE id_cliente = p_id_principal;

        -- el duplicado queda anonimizado y marcado como eliminado
        UPDATE clientes
        SET email = CONCAT('fusionado_', id_cliente, '@eliminado.invalid'),
            contrasena = SHA2(UUID(), 256), direccion_envio = NULL, fecha_nacimiento = NULL,
            total_gastado = 0, activo = FALSE, eliminado_en = NOW(), id_referido_por = NULL
        WHERE id_cliente = p_id_duplicado;

        INSERT INTO auditoria_clientes (id_cliente, email, accion, usuario)
        VALUES (p_id_duplicado, CONCAT('fusionado_en_', p_id_principal), 'FUSION_CUENTA', USER());
    COMMIT;

    CALL sp_ObtenerHistorialComprasCliente(p_id_principal);
END$$

-- 14. sp_AsignarProductoAProveedor: asigna o cambia el proveedor de un producto.
CREATE PROCEDURE sp_AsignarProductoAProveedor(IN p_id_producto INT, IN p_id_proveedor INT)
BEGIN
    DECLARE v_anterior INT;
    IF NOT EXISTS (SELECT 1 FROM productos WHERE id_producto = p_id_producto) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Producto no encontrado';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM proveedores WHERE id_proveedor = p_id_proveedor) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Proveedor no encontrado';
    END IF;
    SELECT id_proveedor INTO v_anterior FROM productos WHERE id_producto = p_id_producto;
    UPDATE productos SET id_proveedor = p_id_proveedor WHERE id_producto = p_id_producto;

    SELECT p.id_producto, p.nombre, v_anterior AS proveedor_anterior,
           p.id_proveedor AS proveedor_nuevo, pr.nombre AS nombre_proveedor
    FROM productos p JOIN proveedores pr ON pr.id_proveedor = p.id_proveedor
    WHERE p.id_producto = p_id_producto;
END$$

-- 15. sp_BuscarProductos: búsqueda avanzada. Cualquier filtro en NULL se ignora.
--     p_orden: 'precio_asc' | 'precio_desc' | 'nombre' | 'mas_vendidos' (por defecto)
CREATE PROCEDURE sp_BuscarProductos(
    IN p_texto          VARCHAR(100),
    IN p_id_categoria   INT,
    IN p_precio_min     DECIMAL(12,2),
    IN p_precio_max     DECIMAL(12,2),
    IN p_solo_con_stock BOOLEAN,
    IN p_orden          VARCHAR(20))
BEGIN
    DECLARE v_sucursal INT DEFAULT NULL;
    IF SUBSTRING_INDEX(USER(), '@', 1) NOT IN ('root','admin_user') THEN
        SELECT id_sucursal INTO v_sucursal FROM usuarios_sucursales
        WHERE usuario_db = SUBSTRING_INDEX(USER(), '@', 1);
        IF v_sucursal IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El usuario no tiene una sucursal asignada';
        END IF;
    END IF;

    SELECT p.id_producto, p.sku, p.nombre, c.nombre AS categoria, p.precio, p.stock,
           COALESCE(ventas.unidades,0) AS unidades_vendidas,
           (SELECT ROUND(AVG(calificacion),1) FROM resenas r WHERE r.id_producto = p.id_producto) AS calificacion
    FROM productos p
    LEFT JOIN categorias c ON c.id_categoria = p.id_categoria
    LEFT JOIN (SELECT d.id_producto, SUM(d.cantidad) AS unidades
               FROM detalle_ventas d JOIN ventas v ON v.id_venta = d.id_venta
                             WHERE v.estado NOT IN ('Cancelado','Devuelto')
                                 AND (v_sucursal IS NULL OR v.id_sucursal = v_sucursal)
                             GROUP BY d.id_producto) ventas
           ON ventas.id_producto = p.id_producto
    WHERE p.activo = TRUE
      AND (p_texto IS NULL OR p.nombre LIKE CONCAT('%', p_texto, '%') OR p.descripcion LIKE CONCAT('%', p_texto, '%'))
      AND (p_id_categoria IS NULL OR p.id_categoria = p_id_categoria)
      AND (p_precio_min IS NULL OR p.precio >= p_precio_min)
      AND (p_precio_max IS NULL OR p.precio <= p_precio_max)
      AND (COALESCE(p_solo_con_stock, FALSE) = FALSE OR p.stock > 0)
    ORDER BY
      CASE WHEN p_orden = 'precio_asc'  THEN p.precio END ASC,
      CASE WHEN p_orden = 'precio_desc' THEN p.precio END DESC,
      CASE WHEN p_orden = 'nombre'      THEN p.nombre END ASC,
      unidades_vendidas DESC;
END$$

-- 16. sp_ObtenerDashboardAdmin: KPIs para el panel de administración.
CREATE PROCEDURE sp_ObtenerDashboardAdmin()
BEGIN
    SELECT
      (SELECT COALESCE(SUM(total),0) FROM ventas WHERE DATE(fecha_venta) = CURDATE()
          AND estado NOT IN ('Cancelado','Devuelto'))                                   AS ventas_hoy,
      (SELECT COUNT(*) FROM ventas WHERE DATE(fecha_venta) = CURDATE())                 AS pedidos_hoy,
      (SELECT COALESCE(SUM(total),0) FROM ventas WHERE fecha_venta >= DATE_FORMAT(CURDATE(),'%Y-%m-01')
          AND estado NOT IN ('Cancelado','Devuelto'))                                   AS ventas_mes,
      (SELECT COUNT(*) FROM clientes WHERE DATE(fecha_registro) = CURDATE())            AS clientes_nuevos_hoy,
      (SELECT COUNT(*) FROM clientes WHERE fecha_registro >= NOW() - INTERVAL 30 DAY)   AS clientes_nuevos_30d,
      (SELECT COUNT(*) FROM ventas WHERE estado = 'Pendiente de Pago')                  AS pedidos_pendientes_pago,
      (SELECT COUNT(*) FROM ventas WHERE estado IN ('Pagado','Procesando'))             AS pedidos_por_despachar,
      (SELECT COUNT(*) FROM productos WHERE activo = TRUE AND stock < stock_minimo)     AS productos_bajo_stock,
      (SELECT ROUND(AVG(total),2) FROM ventas WHERE estado NOT IN ('Cancelado','Devuelto')) AS ticket_promedio_historico,
      (SELECT COUNT(*) FROM carritos)                                                   AS productos_en_carritos;

    -- Últimos 5 pedidos
    SELECT v.id_venta, v.fecha_venta, fn_FormatearNombreCompleto(v.id_cliente) AS cliente, v.estado, v.total
    FROM ventas v ORDER BY v.fecha_venta DESC LIMIT 5;
END$$

-- 17. sp_ProcesarPago: simula el cobro de una venta y la pasa a 'Pagado'.
CREATE PROCEDURE sp_ProcesarPago(
    IN p_id_venta INT,
    IN p_monto    DECIMAL(14,2),
    IN p_metodo   VARCHAR(20))
BEGIN
    DECLARE v_total  DECIMAL(14,2);
    DECLARE v_estado VARCHAR(30);
    DECLARE v_ref    VARCHAR(60);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

    START TRANSACTION;
        SELECT total, estado INTO v_total, v_estado FROM ventas WHERE id_venta = p_id_venta FOR UPDATE;
        IF v_estado IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Venta no encontrada';
        ELSEIF v_estado <> 'Pendiente de Pago' THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La venta no está pendiente de pago';
        ELSEIF p_monto < v_total THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Pago rechazado: monto insuficiente';
        END IF;

        SET v_ref = CONCAT('PAY-', p_id_venta, '-', UPPER(LEFT(REPLACE(UUID(),'-',''), 12)));
        INSERT INTO pagos (id_venta, monto, metodo, referencia) VALUES (p_id_venta, p_monto, p_metodo, v_ref);
        UPDATE ventas SET estado = 'Pagado' WHERE id_venta = p_id_venta;
    COMMIT;

    SELECT p_id_venta AS id_venta, v_total AS total, p_monto AS monto_pagado,
           p_monto - v_total AS cambio, v_ref AS referencia_pago, 'Pagado' AS estado;
END$$

-- 18. sp_AñadirReseñaProducto: solo clientes que compraron (y no cancelaron) pueden reseñar.
CREATE PROCEDURE `sp_AñadirReseñaProducto`(
    IN p_id_cliente   INT,
    IN p_id_producto  INT,
    IN p_calificacion TINYINT,
    IN p_comentario   TEXT)
BEGIN
    IF p_calificacion NOT BETWEEN 1 AND 5 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La calificación debe estar entre 1 y 5';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM ventas v JOIN detalle_ventas d ON d.id_venta = v.id_venta
                   WHERE v.id_cliente = p_id_cliente AND d.id_producto = p_id_producto
                     AND v.estado IN ('Pagado','Procesando','Enviado','Entregado')) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Solo puede reseñar productos que haya comprado';
    END IF;

    INSERT INTO resenas (id_producto, id_cliente, calificacion, comentario)
    VALUES (p_id_producto, p_id_cliente, p_calificacion, p_comentario)
    ON DUPLICATE KEY UPDATE calificacion = VALUES(calificacion), comentario = VALUES(comentario), fecha = NOW();

    SELECT p_id_producto AS id_producto, ROUND(AVG(calificacion),2) AS calificacion_promedio, COUNT(*) AS num_resenas
    FROM resenas WHERE id_producto = p_id_producto;
END$$

-- 19. sp_ObtenerProductosRelacionados: "quienes compraron esto también compraron..."
--     Si no hay co-compras suficientes, completa con los más vendidos de la misma categoría.
CREATE PROCEDURE sp_ObtenerProductosRelacionados(IN p_id_producto INT, IN p_limite INT)
BEGIN
    DECLARE v_sucursal INT DEFAULT NULL;
    SET p_limite = COALESCE(p_limite, 5);
    IF SUBSTRING_INDEX(USER(), '@', 1) NOT IN ('root','admin_user') THEN
        SELECT id_sucursal INTO v_sucursal FROM usuarios_sucursales
        WHERE usuario_db = SUBSTRING_INDEX(USER(), '@', 1);
        IF v_sucursal IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El usuario no tiene una sucursal asignada';
        END IF;
    END IF;
    SELECT id_producto, nombre, precio, puntaje, motivo
    FROM (
        SELECT p.id_producto, p.nombre, p.precio,
               COUNT(DISTINCT v.id_cliente) * 10 AS puntaje,
               'Comprado por los mismos clientes' AS motivo
        FROM ventas v
        JOIN detalle_ventas d ON d.id_venta = v.id_venta
        JOIN productos p      ON p.id_producto = d.id_producto
        WHERE v.id_cliente IN (SELECT v2.id_cliente FROM ventas v2
                               JOIN detalle_ventas d2 ON d2.id_venta = v2.id_venta
                                                             WHERE d2.id_producto = p_id_producto AND v2.estado NOT IN ('Cancelado','Devuelto')
                                                                 AND (v_sucursal IS NULL OR v2.id_sucursal = v_sucursal))
          AND d.id_producto <> p_id_producto AND p.activo = TRUE
          AND v.estado NOT IN ('Cancelado','Devuelto')
          AND (v_sucursal IS NULL OR v.id_sucursal = v_sucursal)
        GROUP BY p.id_producto, p.nombre, p.precio
        UNION ALL
        SELECT p.id_producto, p.nombre, p.precio, 1 AS puntaje, 'Misma categoría' AS motivo
        FROM productos p
        WHERE p.id_categoria = (SELECT id_categoria FROM productos WHERE id_producto = p_id_producto)
          AND p.id_producto <> p_id_producto AND p.activo = TRUE
    ) candidatos
    GROUP BY id_producto, nombre, precio, puntaje, motivo
    ORDER BY puntaje DESC, precio DESC
    LIMIT p_limite;
END$$

-- 20. sp_MoverProductosEntreCategorias: mueve productos de forma segura (transacción).
--     p_ids_productos: JSON '[1,2,3]' o NULL para mover TODOS los de la categoría origen.
--     El contador de productos por categoría lo actualiza el trigger.
CREATE PROCEDURE sp_MoverProductosEntreCategorias(
    IN p_id_categoria_origen  INT,
    IN p_id_categoria_destino INT,
    IN p_ids_productos        JSON)
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

    IF p_id_categoria_origen = p_id_categoria_destino THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Origen y destino son la misma categoría';
    END IF;
    IF (SELECT COUNT(*) FROM categorias WHERE id_categoria IN (p_id_categoria_origen, p_id_categoria_destino)) <> 2 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Categoría de origen o destino inexistente';
    END IF;

    START TRANSACTION;
        UPDATE productos
        SET id_categoria = p_id_categoria_destino
        WHERE id_categoria = p_id_categoria_origen
          AND (p_ids_productos IS NULL
               OR id_producto IN (SELECT j.id FROM JSON_TABLE(p_ids_productos, '$[*]'
                                  COLUMNS (id INT PATH '$')) j));
        SET @movidos = ROW_COUNT();
        IF p_ids_productos IS NOT NULL AND @movidos <> JSON_LENGTH(p_ids_productos) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Algún producto no pertenece a la categoría origen: operación revertida';
        END IF;
    COMMIT;

    SELECT @movidos AS productos_movidos;
    SELECT id_categoria, nombre, total_productos FROM categorias
    WHERE id_categoria IN (p_id_categoria_origen, p_id_categoria_destino);
END$$

DELIMITER ;

-- ---------------------------------------------------------------------
-- Complemento de seguridad – requisito 12 de 04_Seguridad.sql
-- Gerente_Marketing puede ejecutar los procedimientos de reportes de marketing.
-- (Se ubica aquí porque GRANT EXECUTE exige que el procedimiento ya exista.)
-- ---------------------------------------------------------------------
GRANT EXECUTE ON PROCEDURE ecommerce_db.sp_GenerarReporteMensualVentas     TO 'Gerente_Marketing';
GRANT EXECUTE ON PROCEDURE ecommerce_db.sp_ObtenerProductosRelacionados    TO 'Gerente_Marketing';
GRANT EXECUTE ON PROCEDURE ecommerce_db.sp_BuscarProductos                 TO 'Gerente_Marketing';
GRANT EXECUTE ON PROCEDURE ecommerce_db.sp_CambiarEstadoPedido             TO 'Atencion_Cliente';
