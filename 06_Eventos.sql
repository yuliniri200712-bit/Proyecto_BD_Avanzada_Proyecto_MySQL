-- =====================================================================
-- 06_Eventos.sql
-- Tablas de reportes/soporte + 20 eventos programados + activación del event_scheduler
-- =====================================================================
USE ecommerce_db;

-- Activar el programador de eventos (sin esto los eventos existen pero no se ejecutan)
SET GLOBAL event_scheduler = ON;
SET PERSIST event_scheduler = ON;

-- ---------------------------------------------------------------------
-- TABLAS DE REPORTES Y SOPORTE
-- ---------------------------------------------------------------------

-- Reporte de ventas semanales (tabla principal pedida por el taller)
CREATE TABLE IF NOT EXISTS reporte_ventas_semanales (
    id_reporte        INT AUTO_INCREMENT PRIMARY KEY,
    semana_inicio     DATE NOT NULL,
    semana_fin        DATE NOT NULL,
    num_ventas        INT NOT NULL,
    unidades_vendidas INT NOT NULL,
    total_ventas      DECIMAL(16,2) NOT NULL,
    ticket_promedio   DECIMAL(14,2) NOT NULL,
    fecha_generacion  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_semana (semana_inicio)
);

-- Históricos para el archivado de logs (misma estructura, sin llaves foráneas)
CREATE TABLE IF NOT EXISTS log_cambios_precio_historico LIKE log_cambios_precio;
CREATE TABLE IF NOT EXISTS log_estado_pedidos_historico LIKE log_estado_pedidos;
CREATE TABLE IF NOT EXISTS auditoria_clientes_historico LIKE auditoria_clientes;

CREATE TABLE IF NOT EXISTS lista_reabastecimiento (
    id               INT AUTO_INCREMENT PRIMARY KEY,
    fecha            DATE NOT NULL,
    id_producto      INT NOT NULL,
    nombre           VARCHAR(150) NOT NULL,
    id_proveedor     INT NULL,
    stock_actual     INT NOT NULL,
    stock_minimo     INT NOT NULL,
    cantidad_sugerida INT NOT NULL,
    UNIQUE KEY uq_fecha_prod (fecha, id_producto)
);

CREATE TABLE IF NOT EXISTS resumen_ventas_diarias (
    fecha        DATE PRIMARY KEY,
    num_ventas   INT NOT NULL,
    unidades     INT NOT NULL,
    total        DECIMAL(16,2) NOT NULL,
    clientes_unicos INT NOT NULL
);

CREATE TABLE IF NOT EXISTS inconsistencias_datos (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    tipo        VARCHAR(80) NOT NULL,
    referencia  VARCHAR(80) NOT NULL,
    detalle     VARCHAR(255) NOT NULL,
    fecha       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS cupones_cumpleanos (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    id_cliente  INT NOT NULL,
    email       VARCHAR(150) NOT NULL,
    codigo      VARCHAR(40) NOT NULL UNIQUE,
    fecha       DATE NOT NULL,
    UNIQUE KEY uq_cliente_fecha (id_cliente, fecha)
);

CREATE TABLE IF NOT EXISTS ranking_productos (
    posicion       INT NOT NULL,
    id_producto    INT PRIMARY KEY,
    nombre         VARCHAR(150) NOT NULL,
    unidades_30d   INT NOT NULL,
    ingresos_30d   DECIMAL(16,2) NOT NULL,
    actualizado    DATETIME NOT NULL
);

-- Copias de seguridad lógicas de las tablas críticas
CREATE TABLE IF NOT EXISTS bk_productos      LIKE productos;
CREATE TABLE IF NOT EXISTS bk_clientes       LIKE clientes;
CREATE TABLE IF NOT EXISTS bk_ventas         LIKE ventas;
CREATE TABLE IF NOT EXISTS bk_detalle_ventas LIKE detalle_ventas;
CREATE TABLE IF NOT EXISTS log_backups (
    id INT AUTO_INCREMENT PRIMARY KEY, tabla VARCHAR(64) NOT NULL, filas INT NOT NULL,
    fecha DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS kpis_mensuales (
    periodo           CHAR(7) PRIMARY KEY,          -- 'YYYY-MM'
    ventas_totales    DECIMAL(16,2) NOT NULL,
    num_ventas        INT NOT NULL,
    ticket_promedio   DECIMAL(14,2) NOT NULL,
    clientes_nuevos   INT NOT NULL,
    clientes_activos  INT NOT NULL,
    margen_bruto      DECIMAL(16,2) NOT NULL,
    tasa_cancelacion  DECIMAL(5,2) NOT NULL,
    calculado_en      DATETIME NOT NULL
);

-- "Vista materializada" (MySQL no las tiene: se simula con una tabla que se refresca)
CREATE TABLE IF NOT EXISTS mv_ventas_categoria_mes (
    periodo     CHAR(7) NOT NULL,
    categoria   VARCHAR(100) NOT NULL,
    unidades    INT NOT NULL,
    ingresos    DECIMAL(16,2) NOT NULL,
    PRIMARY KEY (periodo, categoria)
);

CREATE TABLE IF NOT EXISTS log_tamano_bd (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    fecha       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    datos_mb    DECIMAL(12,2) NOT NULL,
    indices_mb  DECIMAL(12,2) NOT NULL,
    total_mb    DECIMAL(12,2) NOT NULL,
    num_tablas  INT NOT NULL
);

CREATE TABLE IF NOT EXISTS alertas_fraude (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    id_cliente  INT NOT NULL,
    tipo        VARCHAR(80) NOT NULL,
    detalle     VARCHAR(255) NOT NULL,
    fecha       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS reporte_proveedores_mensual (
    periodo        CHAR(7) NOT NULL,
    id_proveedor   INT NOT NULL,
    proveedor      VARCHAR(150) NOT NULL,
    productos_vendidos INT NOT NULL,
    unidades       INT NOT NULL,
    ingresos       DECIMAL(16,2) NOT NULL,
    margen         DECIMAL(16,2) NOT NULL,
    ranking        INT NOT NULL,
    PRIMARY KEY (periodo, id_proveedor)
);

-- ---------------------------------------------------------------------
-- EVENTOS
-- ---------------------------------------------------------------------
DROP EVENT IF EXISTS evt_generate_weekly_sales_report;
DROP EVENT IF EXISTS evt_cleanup_temp_tables_daily;
DROP EVENT IF EXISTS evt_archive_old_logs_monthly;
DROP EVENT IF EXISTS evt_deactivate_expired_promotions_hourly;
DROP EVENT IF EXISTS evt_recalculate_customer_loyalty_tiers_nightly;
DROP EVENT IF EXISTS evt_generate_reorder_list_daily;
DROP EVENT IF EXISTS evt_rebuild_indexes_weekly;
DROP EVENT IF EXISTS evt_suspend_inactive_accounts_quarterly;
DROP EVENT IF EXISTS evt_aggregate_daily_sales_data;
DROP EVENT IF EXISTS evt_check_data_consistency_nightly;
DROP EVENT IF EXISTS evt_send_birthday_greetings_daily;
DROP EVENT IF EXISTS evt_update_product_rankings_hourly;
DROP EVENT IF EXISTS evt_backup_critical_tables_daily;
DROP EVENT IF EXISTS evt_clear_abandoned_carts_daily;
DROP EVENT IF EXISTS evt_calculate_monthly_kpis;
DROP EVENT IF EXISTS evt_refresh_materialized_views_nightly;
DROP EVENT IF EXISTS evt_log_database_size_weekly;
DROP EVENT IF EXISTS evt_detect_fraudulent_activity_hourly;
DROP EVENT IF EXISTS evt_generate_supplier_performance_report_monthly;
DROP EVENT IF EXISTS evt_purge_soft_deleted_records_weekly;

DELIMITER $$

-- 1. evt_generate_weekly_sales_report: cada lunes 01:00 resume la semana anterior (lun-dom).
CREATE EVENT evt_generate_weekly_sales_report
ON SCHEDULE EVERY 1 WEEK
STARTS (CURDATE() + INTERVAL (7 - WEEKDAY(CURDATE())) DAY + INTERVAL 1 HOUR)
DO
BEGIN
    DECLARE v_ini DATE DEFAULT CURDATE() - INTERVAL (WEEKDAY(CURDATE()) + 7) DAY;
    DECLARE v_fin DATE DEFAULT v_ini + INTERVAL 6 DAY;
    INSERT INTO reporte_ventas_semanales
        (semana_inicio, semana_fin, num_ventas, unidades_vendidas, total_ventas, ticket_promedio)
    SELECT v_ini, v_fin,
           COUNT(DISTINCT v.id_venta),
           COALESCE(SUM(d.cantidad),0),
           COALESCE((SELECT SUM(total) FROM ventas
                     WHERE DATE(fecha_venta) BETWEEN v_ini AND v_fin
                       AND estado NOT IN ('Cancelado','Devuelto')),0),
           COALESCE((SELECT AVG(total) FROM ventas
                     WHERE DATE(fecha_venta) BETWEEN v_ini AND v_fin
                       AND estado NOT IN ('Cancelado','Devuelto')),0)
    FROM ventas v
    LEFT JOIN detalle_ventas d ON d.id_venta = v.id_venta
    WHERE DATE(v.fecha_venta) BETWEEN v_ini AND v_fin
      AND v.estado NOT IN ('Cancelado','Devuelto')
    ON DUPLICATE KEY UPDATE num_ventas = VALUES(num_ventas),
                            unidades_vendidas = VALUES(unidades_vendidas),
                            total_ventas = VALUES(total_ventas),
                            ticket_promedio = VALUES(ticket_promedio),
                            fecha_generacion = NOW();
END$$

-- 2. evt_cleanup_temp_tables_daily: borra a diario las tablas de trabajo con prefijo tmp_
CREATE EVENT evt_cleanup_temp_tables_daily
ON SCHEDULE EVERY 1 DAY STARTS (CURDATE() + INTERVAL 1 DAY + INTERVAL 2 HOUR)
DO
BEGIN
    DECLARE v_fin BOOLEAN DEFAULT FALSE;
    DECLARE v_tabla VARCHAR(64);
    DECLARE cur CURSOR FOR
        SELECT table_name FROM information_schema.tables
        WHERE table_schema = 'ecommerce_db' AND table_name LIKE 'tmp\\_%';
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_fin = TRUE;
    OPEN cur;
    bucle: LOOP
        FETCH cur INTO v_tabla;
        IF v_fin THEN LEAVE bucle; END IF;
        SET @sql = CONCAT('DROP TABLE IF EXISTS `ecommerce_db`.`', v_tabla, '`');
        PREPARE s FROM @sql; EXECUTE s; DEALLOCATE PREPARE s;
    END LOOP;
    CLOSE cur;
END$$

-- 3. evt_archive_old_logs_monthly: mueve logs de más de 6 meses a tablas históricas.
CREATE EVENT evt_archive_old_logs_monthly
ON SCHEDULE EVERY 1 MONTH STARTS (LAST_DAY(CURDATE()) + INTERVAL 1 DAY + INTERVAL 3 HOUR)
DO
BEGIN
    DECLARE v_limite DATETIME DEFAULT NOW() - INTERVAL 6 MONTH;
    START TRANSACTION;
    INSERT INTO log_cambios_precio_historico SELECT * FROM log_cambios_precio WHERE fecha_cambio < v_limite;
    DELETE FROM log_cambios_precio WHERE fecha_cambio < v_limite;
    INSERT INTO log_estado_pedidos_historico SELECT * FROM log_estado_pedidos WHERE fecha_cambio < v_limite;
    DELETE FROM log_estado_pedidos WHERE fecha_cambio < v_limite;
    INSERT INTO auditoria_clientes_historico SELECT * FROM auditoria_clientes WHERE fecha < v_limite;
    DELETE FROM auditoria_clientes WHERE fecha < v_limite;
    COMMIT;
END$$

-- 4. evt_deactivate_expired_promotions_hourly: desactiva códigos de descuento vencidos.
CREATE EVENT evt_deactivate_expired_promotions_hourly
ON SCHEDULE EVERY 1 HOUR STARTS CURRENT_TIMESTAMP
DO
    UPDATE promociones SET activa = FALSE WHERE activa = TRUE AND fecha_fin < NOW()$$

-- 5. evt_recalculate_customer_loyalty_tiers_nightly: recalcula Bronce/Plata/Oro cada noche.
CREATE EVENT evt_recalculate_customer_loyalty_tiers_nightly
ON SCHEDULE EVERY 1 DAY STARTS (CURDATE() + INTERVAL 1 DAY + INTERVAL 1 HOUR)
DO
    UPDATE clientes SET nivel_lealtad = fn_DeterminarEstadoLealtad(id_cliente)
    WHERE eliminado_en IS NULL$$

-- 6. evt_generate_reorder_list_daily: lista diaria de productos por reabastecer.
CREATE EVENT evt_generate_reorder_list_daily
ON SCHEDULE EVERY 1 DAY STARTS (CURDATE() + INTERVAL 1 DAY + INTERVAL 6 HOUR)
DO
    INSERT INTO lista_reabastecimiento
        (fecha, id_producto, nombre, id_proveedor, stock_actual, stock_minimo, cantidad_sugerida)
    SELECT CURDATE(), id_producto, nombre, id_proveedor, stock, stock_minimo, stock_minimo * 2 - stock
    FROM productos
    WHERE activo = TRUE AND stock < stock_minimo
    ON DUPLICATE KEY UPDATE stock_actual = VALUES(stock_actual),
                            cantidad_sugerida = VALUES(cantidad_sugerida)$$

-- 7. evt_rebuild_indexes_weekly: reconstruye (ALTER ... FORCE) y re-analiza las tablas más usadas.
CREATE EVENT evt_rebuild_indexes_weekly
ON SCHEDULE EVERY 1 WEEK STARTS (CURDATE() + INTERVAL (6 - WEEKDAY(CURDATE())) DAY + INTERVAL 4 HOUR)
DO
BEGIN
    ALTER TABLE ventas FORCE;
    ALTER TABLE detalle_ventas FORCE;
    ALTER TABLE productos FORCE;
    ALTER TABLE clientes FORCE;
    ANALYZE TABLE ventas, detalle_ventas, productos, clientes;
END$$

-- 8. evt_suspend_inactive_accounts_quarterly: desactiva clientes sin actividad en más de un año.
CREATE EVENT evt_suspend_inactive_accounts_quarterly
ON SCHEDULE EVERY 1 QUARTER STARTS (CURDATE() + INTERVAL 1 DAY + INTERVAL 5 HOUR)
DO
    UPDATE clientes c
    SET c.activo = FALSE
    WHERE c.activo = TRUE
      AND c.fecha_registro < NOW() - INTERVAL 1 YEAR
      AND COALESCE(c.fecha_ultimo_pedido, c.fecha_registro) < NOW() - INTERVAL 1 YEAR$$

-- 9. evt_aggregate_daily_sales_data: resume las ventas del día anterior (se ejecuta a las 00:10).
CREATE EVENT evt_aggregate_daily_sales_data
ON SCHEDULE EVERY 1 DAY STARTS (CURDATE() + INTERVAL 1 DAY + INTERVAL 10 MINUTE)
DO
    INSERT INTO resumen_ventas_diarias (fecha, num_ventas, unidades, total, clientes_unicos)
    SELECT CURDATE() - INTERVAL 1 DAY,
           COUNT(DISTINCT v.id_venta),
           COALESCE(SUM(d.cantidad),0),
           COALESCE(SUM(d.cantidad * d.precio_unitario_congelado),0),
           COUNT(DISTINCT v.id_cliente)
    FROM ventas v LEFT JOIN detalle_ventas d ON d.id_venta = v.id_venta
    WHERE DATE(v.fecha_venta) = CURDATE() - INTERVAL 1 DAY
      AND v.estado NOT IN ('Cancelado','Devuelto')
    ON DUPLICATE KEY UPDATE num_ventas = VALUES(num_ventas), unidades = VALUES(unidades),
                            total = VALUES(total), clientes_unicos = VALUES(clientes_unicos)$$

-- 10. evt_check_data_consistency_nightly: busca inconsistencias en los datos.
CREATE EVENT evt_check_data_consistency_nightly
ON SCHEDULE EVERY 1 DAY STARTS (CURDATE() + INTERVAL 1 DAY + INTERVAL 2 HOUR + INTERVAL 30 MINUTE)
DO
BEGIN
    -- a) ventas sin detalle
    INSERT INTO inconsistencias_datos (tipo, referencia, detalle)
    SELECT 'VENTA_SIN_DETALLE', CONCAT('venta ', v.id_venta), 'La venta no tiene líneas de detalle'
    FROM ventas v WHERE NOT EXISTS (SELECT 1 FROM detalle_ventas d WHERE d.id_venta = v.id_venta);
    -- b) total de la venta distinto a la suma de su detalle
    INSERT INTO inconsistencias_datos (tipo, referencia, detalle)
    SELECT 'TOTAL_DESCUADRADO', CONCAT('venta ', v.id_venta),
           CONCAT('total=', v.total, ' vs detalle=', fn_CalcularTotalVenta(v.id_venta))
    FROM ventas v WHERE v.total <> fn_CalcularTotalVenta(v.id_venta);
    -- c) productos con precio menor que el costo
    INSERT INTO inconsistencias_datos (tipo, referencia, detalle)
    SELECT 'PRECIO_BAJO_COSTO', CONCAT('producto ', id_producto),
           CONCAT('precio=', precio, ' costo=', costo)
    FROM productos WHERE precio < costo;
    -- d) contador de productos por categoría desactualizado
    INSERT INTO inconsistencias_datos (tipo, referencia, detalle)
    SELECT 'CONTADOR_CATEGORIA', CONCAT('categoria ', c.id_categoria),
           CONCAT('contador=', c.total_productos, ' real=', COUNT(p.id_producto))
    FROM categorias c LEFT JOIN productos p ON p.id_categoria = c.id_categoria
    GROUP BY c.id_categoria, c.total_productos
    HAVING c.total_productos <> COUNT(p.id_producto);
END$$

-- 11. evt_send_birthday_greetings_daily: genera cupones para los cumpleañeros del día.
CREATE EVENT evt_send_birthday_greetings_daily
ON SCHEDULE EVERY 1 DAY STARTS (CURDATE() + INTERVAL 1 DAY + INTERVAL 7 HOUR)
DO
    INSERT IGNORE INTO cupones_cumpleanos (id_cliente, email, codigo, fecha)
    SELECT id_cliente, email, CONCAT('CUMPLE-', id_cliente, '-', DATE_FORMAT(CURDATE(),'%Y%m%d')), CURDATE()
    FROM clientes
    WHERE activo = TRUE AND eliminado_en IS NULL
      AND MONTH(fecha_nacimiento) = MONTH(CURDATE())
      AND DAY(fecha_nacimiento)   = DAY(CURDATE())$$

-- 12. evt_update_product_rankings_hourly: ranking de productos más vendidos (últimos 30 días).
CREATE EVENT evt_update_product_rankings_hourly
ON SCHEDULE EVERY 1 HOUR STARTS CURRENT_TIMESTAMP
DO
BEGIN
    DELETE FROM ranking_productos;
    INSERT INTO ranking_productos (posicion, id_producto, nombre, unidades_30d, ingresos_30d, actualizado)
    SELECT ROW_NUMBER() OVER (ORDER BY SUM(d.cantidad) DESC, SUM(d.cantidad*d.precio_unitario_congelado) DESC),
           p.id_producto, p.nombre, SUM(d.cantidad), SUM(d.cantidad*d.precio_unitario_congelado), NOW()
    FROM detalle_ventas d
    JOIN ventas v    ON v.id_venta = d.id_venta
    JOIN productos p ON p.id_producto = d.id_producto
    WHERE v.fecha_venta >= NOW() - INTERVAL 30 DAY AND v.estado NOT IN ('Cancelado','Devuelto')
    GROUP BY p.id_producto, p.nombre;
END$$

-- 13. evt_backup_critical_tables_daily: copia lógica nocturna de las tablas críticas.
CREATE EVENT evt_backup_critical_tables_daily
ON SCHEDULE EVERY 1 DAY STARTS (CURDATE() + INTERVAL 1 DAY + INTERVAL 3 HOUR + INTERVAL 30 MINUTE)
DO
BEGIN
    DELETE FROM bk_detalle_ventas; INSERT INTO bk_detalle_ventas SELECT * FROM detalle_ventas;
    INSERT INTO log_backups (tabla, filas) VALUES ('detalle_ventas', ROW_COUNT());
    DELETE FROM bk_ventas;         INSERT INTO bk_ventas         SELECT * FROM ventas;
    INSERT INTO log_backups (tabla, filas) VALUES ('ventas', ROW_COUNT());
    DELETE FROM bk_clientes;       INSERT INTO bk_clientes       SELECT * FROM clientes;
    INSERT INTO log_backups (tabla, filas) VALUES ('clientes', ROW_COUNT());
    DELETE FROM bk_productos;      INSERT INTO bk_productos      SELECT * FROM productos;
    INSERT INTO log_backups (tabla, filas) VALUES ('productos', ROW_COUNT());
END$$

-- 14. evt_clear_abandoned_carts_daily: vacía carritos abandonados hace más de 72 horas.
CREATE EVENT evt_clear_abandoned_carts_daily
ON SCHEDULE EVERY 1 DAY STARTS (CURDATE() + INTERVAL 1 DAY + INTERVAL 4 HOUR + INTERVAL 30 MINUTE)
DO
    DELETE FROM carritos WHERE fecha_agregado < NOW() - INTERVAL 72 HOUR$$

-- 15. evt_calculate_monthly_kpis: el día 1 de cada mes calcula los KPIs del mes anterior.
CREATE EVENT evt_calculate_monthly_kpis
ON SCHEDULE EVERY 1 MONTH STARTS (LAST_DAY(CURDATE()) + INTERVAL 1 DAY + INTERVAL 2 HOUR)
DO
BEGIN
    DECLARE v_ini DATE DEFAULT DATE_FORMAT(CURDATE() - INTERVAL 1 MONTH, '%Y-%m-01');
    DECLARE v_fin DATE DEFAULT LAST_DAY(CURDATE() - INTERVAL 1 MONTH);
    INSERT INTO kpis_mensuales (periodo, ventas_totales, num_ventas, ticket_promedio, clientes_nuevos,
                                clientes_activos, margen_bruto, tasa_cancelacion, calculado_en)
    SELECT DATE_FORMAT(v_ini,'%Y-%m'),
           COALESCE(SUM(CASE WHEN estado NOT IN ('Cancelado','Devuelto') THEN total END),0),
           SUM(estado NOT IN ('Cancelado','Devuelto')),
           COALESCE(AVG(CASE WHEN estado NOT IN ('Cancelado','Devuelto') THEN total END),0),
           (SELECT COUNT(*) FROM clientes WHERE DATE(fecha_registro) BETWEEN v_ini AND v_fin),
           COUNT(DISTINCT id_cliente),
           (SELECT COALESCE(SUM(d.cantidad*(d.precio_unitario_congelado - p.costo)),0)
              FROM detalle_ventas d JOIN ventas v2 ON v2.id_venta = d.id_venta
              JOIN productos p ON p.id_producto = d.id_producto
             WHERE DATE(v2.fecha_venta) BETWEEN v_ini AND v_fin
               AND v2.estado NOT IN ('Cancelado','Devuelto')),
           COALESCE(ROUND(100*SUM(estado='Cancelado')/NULLIF(COUNT(*),0),2),0),
           NOW()
    FROM ventas
    WHERE DATE(fecha_venta) BETWEEN v_ini AND v_fin
    ON DUPLICATE KEY UPDATE ventas_totales = VALUES(ventas_totales), num_ventas = VALUES(num_ventas),
        ticket_promedio = VALUES(ticket_promedio), clientes_nuevos = VALUES(clientes_nuevos),
        clientes_activos = VALUES(clientes_activos), margen_bruto = VALUES(margen_bruto),
        tasa_cancelacion = VALUES(tasa_cancelacion), calculado_en = NOW();
END$$

-- 16. evt_refresh_materialized_views_nightly: refresca la "vista materializada" de ventas por categoría/mes.
CREATE EVENT evt_refresh_materialized_views_nightly
ON SCHEDULE EVERY 1 DAY STARTS (CURDATE() + INTERVAL 1 DAY + INTERVAL 1 HOUR + INTERVAL 30 MINUTE)
DO
BEGIN
    DELETE FROM mv_ventas_categoria_mes;
    INSERT INTO mv_ventas_categoria_mes (periodo, categoria, unidades, ingresos)
    SELECT DATE_FORMAT(v.fecha_venta,'%Y-%m'), c.nombre, SUM(d.cantidad),
           SUM(d.cantidad * d.precio_unitario_congelado)
    FROM ventas v
    JOIN detalle_ventas d ON d.id_venta = v.id_venta
    JOIN productos p      ON p.id_producto = d.id_producto
    JOIN categorias c     ON c.id_categoria = p.id_categoria
    WHERE v.estado NOT IN ('Cancelado','Devuelto')
    GROUP BY DATE_FORMAT(v.fecha_venta,'%Y-%m'), c.nombre;
END$$

-- 17. evt_log_database_size_weekly: registra el tamaño de la base de datos.
CREATE EVENT evt_log_database_size_weekly
ON SCHEDULE EVERY 1 WEEK STARTS (CURDATE() + INTERVAL 1 DAY + INTERVAL 5 HOUR)
DO
    INSERT INTO log_tamano_bd (datos_mb, indices_mb, total_mb, num_tablas)
    SELECT ROUND(SUM(data_length)/1048576,2), ROUND(SUM(index_length)/1048576,2),
           ROUND(SUM(data_length+index_length)/1048576,2), COUNT(*)
    FROM information_schema.tables WHERE table_schema = 'ecommerce_db'$$

-- 18. evt_detect_fraudulent_activity_hourly: patrones sospechosos en la última hora / día.
CREATE EVENT evt_detect_fraudulent_activity_hourly
ON SCHEDULE EVERY 1 HOUR STARTS CURRENT_TIMESTAMP
DO
BEGIN
    -- 3 o más pedidos cancelados / fallidos en 24 horas
    INSERT INTO alertas_fraude (id_cliente, tipo, detalle)
    SELECT id_cliente, 'PEDIDOS_FALLIDOS', CONCAT(COUNT(*), ' pedidos cancelados en 24 h')
    FROM ventas
    WHERE estado = 'Cancelado' AND fecha_venta >= NOW() - INTERVAL 24 HOUR
    GROUP BY id_cliente HAVING COUNT(*) >= 3;
    -- 5 o más pedidos en la última hora
    INSERT INTO alertas_fraude (id_cliente, tipo, detalle)
    SELECT id_cliente, 'RAFAGA_PEDIDOS', CONCAT(COUNT(*), ' pedidos en 1 h')
    FROM ventas
    WHERE fecha_venta >= NOW() - INTERVAL 1 HOUR
    GROUP BY id_cliente HAVING COUNT(*) >= 5;
    -- pedido individual > 5 veces el ticket promedio histórico del cliente
    INSERT INTO alertas_fraude (id_cliente, tipo, detalle)
    SELECT v.id_cliente, 'MONTO_ATIPICO', CONCAT('venta ', v.id_venta, ' por ', v.total)
    FROM ventas v
    WHERE v.fecha_venta >= NOW() - INTERVAL 1 HOUR
      AND v.total > 5 * (SELECT AVG(v2.total) FROM ventas v2
                         WHERE v2.id_cliente = v.id_cliente AND v2.id_venta <> v.id_venta);
END$$

-- 19. evt_generate_supplier_performance_report_monthly: rendimiento mensual de proveedores.
CREATE EVENT evt_generate_supplier_performance_report_monthly
ON SCHEDULE EVERY 1 MONTH STARTS (LAST_DAY(CURDATE()) + INTERVAL 1 DAY + INTERVAL 2 HOUR + INTERVAL 30 MINUTE)
DO
BEGIN
    DECLARE v_ini DATE DEFAULT DATE_FORMAT(CURDATE() - INTERVAL 1 MONTH, '%Y-%m-01');
    DECLARE v_fin DATE DEFAULT LAST_DAY(CURDATE() - INTERVAL 1 MONTH);
    INSERT INTO reporte_proveedores_mensual
        (periodo, id_proveedor, proveedor, productos_vendidos, unidades, ingresos, margen, ranking)
    SELECT DATE_FORMAT(v_ini,'%Y-%m'), pr.id_proveedor, pr.nombre,
           COUNT(DISTINCT d.id_producto), COALESCE(SUM(d.cantidad),0),
           COALESCE(SUM(d.cantidad*d.precio_unitario_congelado),0),
           COALESCE(SUM(d.cantidad*(d.precio_unitario_congelado - p.costo)),0),
           RANK() OVER (ORDER BY COALESCE(SUM(d.cantidad*d.precio_unitario_congelado),0) DESC)
    FROM proveedores pr
    LEFT JOIN productos p ON p.id_proveedor = pr.id_proveedor
    LEFT JOIN detalle_ventas d ON d.id_producto = p.id_producto
         AND d.id_venta IN (SELECT id_venta FROM ventas
                            WHERE DATE(fecha_venta) BETWEEN v_ini AND v_fin
                              AND estado NOT IN ('Cancelado','Devuelto'))
    GROUP BY pr.id_proveedor, pr.nombre
    ON DUPLICATE KEY UPDATE productos_vendidos = VALUES(productos_vendidos), unidades = VALUES(unidades),
        ingresos = VALUES(ingresos), margen = VALUES(margen), ranking = VALUES(ranking);
END$$

-- 20. evt_purge_soft_deleted_records_weekly: elimina definitivamente clientes marcados como
--     borrados hace más de 30 días que no tienen ventas (los que tienen ventas se conservan
--     anonimizados para no romper la integridad referencial).
CREATE EVENT evt_purge_soft_deleted_records_weekly
ON SCHEDULE EVERY 1 WEEK STARTS (CURDATE() + INTERVAL 1 DAY + INTERVAL 5 HOUR + INTERVAL 30 MINUTE)
DO
BEGIN
    CREATE TEMPORARY TABLE IF NOT EXISTS tmp_purga (id_cliente INT PRIMARY KEY);
    DELETE FROM tmp_purga;
    INSERT INTO tmp_purga
    SELECT c.id_cliente FROM clientes c
    WHERE c.eliminado_en IS NOT NULL AND c.eliminado_en < NOW() - INTERVAL 30 DAY
      AND NOT EXISTS (SELECT 1 FROM ventas v WHERE v.id_cliente = c.id_cliente);
    DELETE FROM carritos         WHERE id_cliente IN (SELECT id_cliente FROM tmp_purga);
    DELETE FROM visitas_producto WHERE id_cliente IN (SELECT id_cliente FROM tmp_purga);
    DELETE FROM resenas          WHERE id_cliente IN (SELECT id_cliente FROM tmp_purga);
    DELETE FROM creditos_cliente WHERE id_cliente IN (SELECT id_cliente FROM tmp_purga);
    UPDATE clientes SET id_referido_por = NULL WHERE id_referido_por IN (SELECT id_cliente FROM tmp_purga);
    DELETE FROM clientes         WHERE id_cliente IN (SELECT id_cliente FROM tmp_purga);
    DROP TEMPORARY TABLE IF EXISTS tmp_purga;
END$$

DELIMITER ;

-- Verificación
SHOW VARIABLES LIKE 'event_scheduler';
SELECT event_name, interval_value, interval_field, starts, status
FROM information_schema.events WHERE event_schema = 'ecommerce_db' ORDER BY event_name;
