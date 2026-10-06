-- =====================================================================
-- 03_Funciones.sql
-- 20 funciones definidas por el usuario (UDF)
-- =====================================================================
USE ecommerce_db;

-- Permite crear funciones cuando el binlog está activo (MySQL 8 lo activa por defecto)
SET GLOBAL log_bin_trust_function_creators = 1;

DROP FUNCTION IF EXISTS fn_CalcularTotalVenta;
DROP FUNCTION IF EXISTS fn_VerificarDisponibilidadStock;
DROP FUNCTION IF EXISTS fn_ObtenerPrecioProducto;
DROP FUNCTION IF EXISTS fn_CalcularEdadCliente;
DROP FUNCTION IF EXISTS fn_FormatearNombreCompleto;
DROP FUNCTION IF EXISTS fn_EsClienteNuevo;
DROP FUNCTION IF EXISTS fn_CalcularCostoEnvio;
DROP FUNCTION IF EXISTS fn_AplicarDescuento;
DROP FUNCTION IF EXISTS fn_ObtenerUltimaFechaCompra;
DROP FUNCTION IF EXISTS fn_ValidarFormatoEmail;
DROP FUNCTION IF EXISTS fn_ObtenerNombreCategoria;
DROP FUNCTION IF EXISTS fn_ContarVentasCliente;
DROP FUNCTION IF EXISTS fn_CalcularDiasDesdeUltimaCompra;
DROP FUNCTION IF EXISTS fn_DeterminarEstadoLealtad;
DROP FUNCTION IF EXISTS fn_GenerarSKU;
DROP FUNCTION IF EXISTS fn_CalcularIVA;
DROP FUNCTION IF EXISTS fn_ObtenerStockTotalPorCategoria;
DROP FUNCTION IF EXISTS fn_EstimarFechaEntrega;
DROP FUNCTION IF EXISTS fn_ConvertirMoneda;
DROP FUNCTION IF EXISTS `fn_ValidarComplejidadContraseña`;

DELIMITER $$

-- 1. fn_CalcularTotalVenta: suma de subtotales (cantidad * precio congelado) de una venta.
CREATE FUNCTION fn_CalcularTotalVenta(p_id_venta INT)
RETURNS DECIMAL(14,2)
READS SQL DATA
BEGIN
    DECLARE v_total DECIMAL(14,2);
    SELECT COALESCE(SUM(cantidad * precio_unitario_congelado),0) INTO v_total
    FROM detalle_ventas WHERE id_venta = p_id_venta;
    RETURN v_total;
END$$

-- 2. fn_VerificarDisponibilidadStock: TRUE si hay stock suficiente para la cantidad pedida.
CREATE FUNCTION fn_VerificarDisponibilidadStock(p_id_producto INT, p_cantidad INT)
RETURNS BOOLEAN
READS SQL DATA
BEGIN
    DECLARE v_stock INT DEFAULT 0;
    SELECT stock INTO v_stock FROM productos WHERE id_producto = p_id_producto AND activo = TRUE;
    RETURN COALESCE(v_stock,0) >= p_cantidad;
END$$

-- 3. fn_ObtenerPrecioProducto: precio actual de un producto (NULL si no existe).
CREATE FUNCTION fn_ObtenerPrecioProducto(p_id_producto INT)
RETURNS DECIMAL(12,2)
READS SQL DATA
BEGIN
    DECLARE v_precio DECIMAL(12,2);
    SELECT precio INTO v_precio FROM productos WHERE id_producto = p_id_producto;
    RETURN v_precio;
END$$

-- 4. fn_CalcularEdadCliente: edad en años a partir de la fecha de nacimiento.
CREATE FUNCTION fn_CalcularEdadCliente(p_id_cliente INT)
RETURNS INT
READS SQL DATA
BEGIN
    DECLARE v_nac DATE;
    SELECT fecha_nacimiento INTO v_nac FROM clientes WHERE id_cliente = p_id_cliente;
    RETURN IF(v_nac IS NULL, NULL, TIMESTAMPDIFF(YEAR, v_nac, CURDATE()));
END$$

-- 5. fn_FormatearNombreCompleto: "Apellido, Nombre" con mayúscula inicial.
CREATE FUNCTION fn_FormatearNombreCompleto(p_id_cliente INT)
RETURNS VARCHAR(170)
READS SQL DATA
BEGIN
    DECLARE v_nombre VARCHAR(80);
    DECLARE v_apellido VARCHAR(80);
    SELECT TRIM(nombre), TRIM(apellido) INTO v_nombre, v_apellido
    FROM clientes WHERE id_cliente = p_id_cliente;
    IF v_nombre IS NULL THEN RETURN NULL; END IF;
    RETURN CONCAT(UPPER(LEFT(v_apellido,1)), LOWER(SUBSTRING(v_apellido,2)), ', ',
                  UPPER(LEFT(v_nombre,1)),   LOWER(SUBSTRING(v_nombre,2)));
END$$

-- 6. fn_EsClienteNuevo: TRUE si la PRIMERA compra del cliente fue en los últimos 30 días.
CREATE FUNCTION fn_EsClienteNuevo(p_id_cliente INT)
RETURNS BOOLEAN
READS SQL DATA
BEGIN
    DECLARE v_primera DATETIME;
    SELECT MIN(fecha_venta) INTO v_primera FROM ventas
    WHERE id_cliente = p_id_cliente AND estado NOT IN ('Cancelado','Devuelto Totalmente');
    RETURN v_primera IS NOT NULL AND v_primera >= NOW() - INTERVAL 30 DAY;
END$$

-- 7. fn_CalcularCostoEnvio: tarifa base $8.000 + $2.500 por kg (redondeado hacia arriba), con tope de $60.000.
CREATE FUNCTION fn_CalcularCostoEnvio(p_id_venta INT)
RETURNS DECIMAL(12,2)
READS SQL DATA
BEGIN
    DECLARE v_peso DECIMAL(10,3);
    SELECT COALESCE(SUM(d.cantidad * p.peso_kg),0) INTO v_peso
    FROM detalle_ventas d JOIN productos p ON p.id_producto = d.id_producto
    WHERE d.id_venta = p_id_venta;
    IF v_peso = 0 THEN RETURN 0; END IF;
    RETURN LEAST(8000 + CEIL(v_peso) * 2500, 60000);
END$$

-- 8. fn_AplicarDescuento: aplica un porcentaje (0-100) a un monto.
CREATE FUNCTION fn_AplicarDescuento(p_monto DECIMAL(14,2), p_porcentaje DECIMAL(5,2))
RETURNS DECIMAL(14,2)
DETERMINISTIC
BEGIN
    IF p_porcentaje < 0 OR p_porcentaje > 100 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El porcentaje de descuento debe estar entre 0 y 100';
    END IF;
    RETURN ROUND(p_monto * (1 - p_porcentaje / 100), 2);
END$$

-- 9. fn_ObtenerUltimaFechaCompra: fecha de la última compra válida de un cliente.
CREATE FUNCTION fn_ObtenerUltimaFechaCompra(p_id_cliente INT)
RETURNS DATETIME
READS SQL DATA
BEGIN
    DECLARE v_fecha DATETIME;
    SELECT MAX(fecha_venta) INTO v_fecha FROM ventas
    WHERE id_cliente = p_id_cliente AND estado NOT IN ('Cancelado','Devuelto Totalmente');
    RETURN v_fecha;
END$$

-- 10. fn_ValidarFormatoEmail: valida con expresión regular usuario@dominio.ext
CREATE FUNCTION fn_ValidarFormatoEmail(p_email VARCHAR(255))
RETURNS BOOLEAN
DETERMINISTIC
BEGIN
    RETURN p_email IS NOT NULL
       AND p_email REGEXP '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$';
END$$

-- 11. fn_ObtenerNombreCategoria: nombre de la categoría de un producto.
CREATE FUNCTION fn_ObtenerNombreCategoria(p_id_producto INT)
RETURNS VARCHAR(100)
READS SQL DATA
BEGIN
    DECLARE v_nombre VARCHAR(100);
    SELECT c.nombre INTO v_nombre
    FROM productos p JOIN categorias c ON c.id_categoria = p.id_categoria
    WHERE p.id_producto = p_id_producto;
    RETURN v_nombre;
END$$

-- 12. fn_ContarVentasCliente: número de compras válidas de un cliente.
CREATE FUNCTION fn_ContarVentasCliente(p_id_cliente INT)
RETURNS INT
READS SQL DATA
BEGIN
    DECLARE v_n INT;
    SELECT COUNT(*) INTO v_n FROM ventas
    WHERE id_cliente = p_id_cliente AND estado NOT IN ('Cancelado','Devuelto Totalmente');
    RETURN v_n;
END$$

-- 13. fn_CalcularDiasDesdeUltimaCompra: días transcurridos desde la última compra (NULL si nunca compró).
CREATE FUNCTION fn_CalcularDiasDesdeUltimaCompra(p_id_cliente INT)
RETURNS INT
READS SQL DATA
BEGIN
    DECLARE v_fecha DATETIME;
    SET v_fecha = fn_ObtenerUltimaFechaCompra(p_id_cliente);
    RETURN IF(v_fecha IS NULL, NULL, DATEDIFF(CURDATE(), v_fecha));
END$$

-- 14. fn_DeterminarEstadoLealtad: Bronce < $3.000.000 <= Plata < $8.000.000 <= Oro
CREATE FUNCTION fn_DeterminarEstadoLealtad(p_id_cliente INT)
RETURNS VARCHAR(10)
READS SQL DATA
BEGIN
    DECLARE v_gasto DECIMAL(14,2);
    SELECT COALESCE(SUM(total),0) INTO v_gasto FROM ventas
    WHERE id_cliente = p_id_cliente AND estado NOT IN ('Cancelado','Devuelto Totalmente');
    RETURN CASE WHEN v_gasto >= 8000000 THEN 'Oro'
                WHEN v_gasto >= 3000000 THEN 'Plata'
                ELSE 'Bronce' END;
END$$

-- 15. fn_GenerarSKU: CAT-NOM-#### (3 letras categoría, 3 letras nombre, consecutivo).
CREATE FUNCTION fn_GenerarSKU(p_nombre VARCHAR(150), p_id_categoria INT)
RETURNS VARCHAR(50)
READS SQL DATA
BEGIN
    DECLARE v_cat VARCHAR(100);
    DECLARE v_sig INT;
    SELECT nombre INTO v_cat FROM categorias WHERE id_categoria = p_id_categoria;
    SELECT COALESCE(MAX(id_producto),0) + 1 INTO v_sig FROM productos;
    RETURN UPPER(CONCAT(
        LEFT(REGEXP_REPLACE(CONVERT(COALESCE(v_cat,'GEN') USING ascii), '[^A-Za-z]', ''), 3), '-',
        LEFT(REGEXP_REPLACE(CONVERT(p_nombre USING ascii), '[^A-Za-z]', ''), 3), '-',
        LPAD(v_sig, 4, '0')));
END$$

-- 16. fn_CalcularIVA: IVA (19% en Colombia) sobre el total de una venta.
CREATE FUNCTION fn_CalcularIVA(p_id_venta INT)
RETURNS DECIMAL(14,2)
READS SQL DATA
BEGIN
    RETURN ROUND(fn_CalcularTotalVenta(p_id_venta) * 0.19, 2);
END$$

-- 17. fn_ObtenerStockTotalPorCategoria: suma del stock de los productos de una categoría.
CREATE FUNCTION fn_ObtenerStockTotalPorCategoria(p_id_categoria INT)
RETURNS INT
READS SQL DATA
BEGIN
    DECLARE v_total INT;
    SELECT COALESCE(SUM(stock),0) INTO v_total FROM productos WHERE id_categoria = p_id_categoria;
    RETURN v_total;
END$$

-- 18. fn_EstimarFechaEntrega: días hábiles según la ciudad del cliente (salida desde Cúcuta).
CREATE FUNCTION fn_EstimarFechaEntrega(p_id_venta INT)
RETURNS DATE
READS SQL DATA
BEGIN
    DECLARE v_ciudad VARCHAR(80);
    DECLARE v_fecha  DATETIME;
    DECLARE v_dias   INT;
    DECLARE v_res    DATE;
    SELECT c.ciudad, v.fecha_venta INTO v_ciudad, v_fecha
    FROM ventas v JOIN clientes c ON c.id_cliente = v.id_cliente
    WHERE v.id_venta = p_id_venta;
    SET v_dias = CASE
        WHEN v_ciudad = 'Cúcuta' THEN 1
        WHEN v_ciudad IN ('Bucaramanga','Bogotá') THEN 3
        WHEN v_ciudad IN ('Medellín','Cali','Barranquilla') THEN 4
        ELSE 7 END;
    SET v_res = DATE(v_fecha);
    WHILE v_dias > 0 DO                       -- se cuentan solo días hábiles (lun-vie)
        SET v_res = v_res + INTERVAL 1 DAY;
        IF DAYOFWEEK(v_res) NOT IN (1,7) THEN SET v_dias = v_dias - 1; END IF;
    END WHILE;
    RETURN v_res;
END$$

-- 19. fn_ConvertirMoneda: convierte COP a USD/EUR/MXN con tasas fijas.
CREATE FUNCTION fn_ConvertirMoneda(p_monto_cop DECIMAL(16,2), p_moneda CHAR(3))
RETURNS DECIMAL(16,2)
DETERMINISTIC
BEGIN
    DECLARE v_tasa DECIMAL(12,4);   -- pesos colombianos por 1 unidad de la moneda destino
    SET v_tasa = CASE UPPER(p_moneda)
        WHEN 'COP' THEN 1
        WHEN 'USD' THEN 4000
        WHEN 'EUR' THEN 4400
        WHEN 'MXN' THEN 220
        ELSE NULL END;
    IF v_tasa IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Moneda no soportada (use COP, USD, EUR o MXN)';
    END IF;
    RETURN ROUND(p_monto_cop / v_tasa, 2);
END$$

-- 20. fn_ValidarComplejidadContraseña: mínimo 8 caracteres, mayúscula, minúscula, número y símbolo.
CREATE FUNCTION `fn_ValidarComplejidadContraseña`(p_pass VARCHAR(255))
RETURNS BOOLEAN
DETERMINISTIC
BEGIN
    RETURN CHAR_LENGTH(p_pass) >= 8
       AND REGEXP_LIKE(p_pass, '[A-Z]', 'c')
       AND REGEXP_LIKE(p_pass, '[a-z]', 'c')
       AND REGEXP_LIKE(p_pass, '[0-9]')
       AND REGEXP_LIKE(p_pass, '[^A-Za-z0-9]');
END$$

DELIMITER ;

-- Pruebas rápidas
SELECT fn_CalcularTotalVenta(1)              AS total_venta_1,
       fn_VerificarDisponibilidadStock(4,10) AS hay_10_monitores,
       fn_FormatearNombreCompleto(8)         AS nombre_formateado,
       fn_DeterminarEstadoLealtad(1)         AS lealtad_cliente_1,
       fn_GenerarSKU('Parlante Portátil', 2) AS sku_generado,
       fn_EstimarFechaEntrega(36)            AS entrega_venta_36,
       fn_ConvertirMoneda(4000000,'USD')     AS usd,
       `fn_ValidarComplejidadContraseña`('Abc#1234') AS pass_ok;
