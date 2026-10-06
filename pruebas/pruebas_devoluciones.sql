-- =====================================================================
-- pruebas/pruebas_devoluciones.sql
-- Pruebas automáticas de 08_Devoluciones.sql (tabla devoluciones y
-- procedimiento sp_ProcesarDevolucion).
--
-- ¡ATENCIÓN! Estas pruebas MODIFICAN datos (procesan devoluciones reales sobre
-- las ventas 3, 4, 8, 20 y 37). Ejecútelas sobre una base recién creada con 01..08:
--   mysql -u root -p --default-character-set=utf8mb4 < pruebas/pruebas_devoluciones.sql
-- Al final se muestra una tabla con cada prueba y su resultado (PASA / FALLA).
-- =====================================================================
USE ecommerce_db;

DROP TABLE IF EXISTS _resultados_pruebas;
CREATE TABLE _resultados_pruebas (
    n         INT AUTO_INCREMENT PRIMARY KEY,
    prueba    VARCHAR(200) NOT NULL,
    resultado VARCHAR(5)   NOT NULL,
    detalle   VARCHAR(500) NULL
);

DROP PROCEDURE IF EXISTS _verificar;
DROP PROCEDURE IF EXISTS _esperar_error;

DELIMITER $$
-- Registra si una condición se cumple.
CREATE PROCEDURE _verificar(IN p_prueba VARCHAR(200), IN p_ok BOOLEAN, IN p_detalle VARCHAR(500))
BEGIN
    INSERT INTO _resultados_pruebas (prueba, resultado, detalle)
    VALUES (p_prueba, IF(COALESCE(p_ok, FALSE), 'PASA', 'FALLA'), p_detalle);
END$$

-- Ejecuta una sentencia que DEBE fallar y comprueba el texto del error.
CREATE PROCEDURE _esperar_error(IN p_prueba VARCHAR(200), IN p_sentencia TEXT, IN p_fragmento VARCHAR(200))
BEGIN
    DECLARE v_msg TEXT DEFAULT NULL;
    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        GET DIAGNOSTICS CONDITION 1 v_msg = MESSAGE_TEXT;
    SET @_sql = p_sentencia;
    PREPARE _st FROM @_sql;
    EXECUTE _st;
    DEALLOCATE PREPARE _st;
    CALL _verificar(p_prueba, v_msg LIKE CONCAT('%', p_fragmento, '%'), COALESCE(v_msg, '(no hubo error)'));
END$$
DELIMITER ;

-- ---------------------------------------------------------------------
-- Estado inicial. Venta 3 (cliente 1, 'Entregado'): 3 x producto 7 y 1 x producto 8.
-- ---------------------------------------------------------------------
SELECT stock INTO @stock7_ini FROM productos WHERE id_producto = 7;
SELECT stock INTO @stock8_ini FROM productos WHERE id_producto = 8;
SELECT total_gastado INTO @gastado1_ini FROM clientes WHERE id_cliente = 1;
SELECT COUNT(*) INTO @creditos_ini FROM creditos_cliente;

-- P1. Devolución parcial: 2 de 3 camisetas.
CALL sp_ProcesarDevolucion(3, 7, 2);
CALL _verificar('P1 stock del producto 7 aumenta en 2',
    (SELECT stock FROM productos WHERE id_producto = 7) = @stock7_ini + 2, NULL);
CALL _verificar('P1 venta 3 queda en Devolución Parcial',
    (SELECT estado FROM ventas WHERE id_venta = 3) = 'Devolución Parcial', NULL);
CALL _verificar('P1 se inserta 1 registro en devoluciones con monto 2 x 45000',
    (SELECT COUNT(*) = 1 AND SUM(monto_reembolso) = 90000 AND MAX(estado_venta_anterior) = 'Entregado'
       FROM devoluciones WHERE id_venta = 3), NULL);
CALL _verificar('P1 el cambio de estado queda en log_estado_pedidos (trigger)',
    EXISTS (SELECT 1 FROM log_estado_pedidos WHERE id_venta = 3 AND estado_nuevo = 'Devolución Parcial'), NULL);
CALL _verificar('P1 se genera el crédito a favor del cliente',
    (SELECT COUNT(*) FROM creditos_cliente) = @creditos_ini + 1, NULL);

-- P2. Devolver más de lo que queda (queda 1 camiseta): debe fallar SIN cambiar nada.
CALL _esperar_error('P2 rechaza devolver 2 cuando solo queda 1',
    'CALL sp_ProcesarDevolucion(3, 7, 2)', 'mayor que la disponible');
CALL _verificar('P2 el stock no cambió tras el error',
    (SELECT stock FROM productos WHERE id_producto = 7) = @stock7_ini + 2, NULL);
CALL _verificar('P2 no se insertó ninguna devolución extra',
    (SELECT COUNT(*) FROM devoluciones WHERE id_venta = 3) = 1, NULL);

-- P3. Devolver la última camiseta: la venta sigue parcial (falta el jean).
CALL sp_ProcesarDevolucion(3, 7, 1);
CALL _verificar('P3 venta 3 sigue en Devolución Parcial',
    (SELECT estado FROM ventas WHERE id_venta = 3) = 'Devolución Parcial', NULL);
CALL _verificar('P3 el producto 7 ya tiene sus 3 unidades devueltas',
    (SELECT SUM(cantidad_devuelta) FROM devoluciones WHERE id_venta = 3 AND id_producto = 7) = 3, NULL);

-- P4. Devolver el jean: la venta queda Devuelto Totalmente.
CALL sp_ProcesarDevolucion(3, 8, 1);
CALL _verificar('P4 venta 3 queda en Devuelto Totalmente',
    (SELECT estado FROM ventas WHERE id_venta = 3) = 'Devuelto Totalmente', NULL);
CALL _verificar('P4 stock del producto 8 aumenta en 1',
    (SELECT stock FROM productos WHERE id_producto = 8) = @stock8_ini + 1, NULL);
CALL _verificar('P4 total_gastado del cliente 1 baja en el total de la venta 3 (274000)',
    (SELECT total_gastado FROM clientes WHERE id_cliente = 1) = @gastado1_ini - 274000, NULL);

-- P5. Una venta totalmente devuelta ya no admite devoluciones.
CALL _esperar_error('P5 rechaza devolución sobre venta Devuelto Totalmente',
    'CALL sp_ProcesarDevolucion(3, 8, 1)', 'Devuelto Totalmente');

-- P6..P9. Validaciones de entrada.
CALL _esperar_error('P6 rechaza venta en estado Procesando (venta 37)',
    'CALL sp_ProcesarDevolucion(37, 3, 1)', 'Procesando');
CALL _esperar_error('P7 rechaza venta inexistente',
    'CALL sp_ProcesarDevolucion(99999, 1, 1)', 'La venta no existe');
CALL _esperar_error('P8 rechaza producto que no está en la venta',
    'CALL sp_ProcesarDevolucion(4, 1, 1)', 'no pertenece a esa venta');
CALL _esperar_error('P9a rechaza cantidad 0',
    'CALL sp_ProcesarDevolucion(4, 11, 0)', 'mayor que cero');
CALL _esperar_error('P9b rechaza cantidad negativa',
    'CALL sp_ProcesarDevolucion(4, 11, -3)', 'mayor que cero');
CALL _esperar_error('P9c rechaza parámetros NULL',
    'CALL sp_ProcesarDevolucion(4, NULL, 1)', 'Debe indicar');

-- P10. ATOMICIDAD: se fuerza un fallo en el ÚLTIMO paso (INSERT en devoluciones),
-- cuando el stock y el estado YA se habían modificado dentro de la transacción.
-- Tras el ROLLBACK, nada debe haber cambiado.
DROP TRIGGER IF EXISTS _trg_falla_devolucion;
CREATE TRIGGER _trg_falla_devolucion BEFORE INSERT ON devoluciones FOR EACH ROW
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Fallo simulado al registrar la devolución';

SELECT stock INTO @stock13_ini FROM productos WHERE id_producto = 13;
SELECT estado INTO @estado8_ini FROM ventas WHERE id_venta = 8;   -- venta 8: 1 x producto 13
SELECT COUNT(*) INTO @logs_ini FROM log_estado_pedidos;
SELECT COUNT(*) INTO @creditos_ini FROM creditos_cliente;

CALL _esperar_error('P10 el fallo simulado se propaga a quien llama',
    'CALL sp_ProcesarDevolucion(8, 13, 1)', 'Fallo simulado');
CALL _verificar('P10 ROLLBACK: el stock del producto 13 no cambió',
    (SELECT stock FROM productos WHERE id_producto = 13) = @stock13_ini, NULL);
CALL _verificar('P10 ROLLBACK: el estado de la venta 8 no cambió',
    (SELECT estado FROM ventas WHERE id_venta = 8) = @estado8_ini, NULL);
CALL _verificar('P10 ROLLBACK: no quedó log de estado ni crédito',
    (SELECT COUNT(*) FROM log_estado_pedidos) = @logs_ini
    AND (SELECT COUNT(*) FROM creditos_cliente) = @creditos_ini, NULL);
DROP TRIGGER _trg_falla_devolucion;

-- Sin el fallo simulado, la misma devolución funciona.
CALL sp_ProcesarDevolucion(8, 13, 1);
CALL _verificar('P10 sin el fallo, la venta 8 queda Devuelto Totalmente',
    (SELECT estado FROM ventas WHERE id_venta = 8) = 'Devuelto Totalmente', NULL);

-- P11. Coherencia con el resto del sistema.
CALL sp_ProcesarDevolucion(20, 13, 1);   -- venta 20: producto 13 y 11 -> parcial
CALL _esperar_error('P11a no se pueden agregar productos a una venta en devolución',
    'INSERT INTO detalle_ventas (id_venta, id_producto, cantidad, precio_unitario_congelado) VALUES (20, 1, 1, 0)',
    'en devolución');
CALL _esperar_error('P11b sp_CambiarEstadoPedido ya no marca devoluciones sin pasar por el procedimiento',
    'CALL sp_CambiarEstadoPedido(4, ''Devuelto Totalmente'')', 'Transición no permitida');
SELECT stock INTO @stock13_ini FROM productos WHERE id_producto = 13;
CALL _esperar_error('P11c no se puede borrar una venta con devoluciones registradas',
    'DELETE FROM ventas WHERE id_venta = 20', 'foreign key');
CALL _verificar('P11c el intento de borrado no alteró el stock',
    (SELECT stock FROM productos WHERE id_producto = 13) = @stock13_ini, NULL);

-- P12. Devolución sobre una venta 'Enviado' (venta 35: producto 11 y 13).
CALL sp_ProcesarDevolucion(35, 11, 1);
CALL _verificar('P12 venta Enviado admite devolución y queda parcial',
    (SELECT estado FROM ventas WHERE id_venta = 35) = 'Devolución Parcial', NULL);

-- P13. Integridad global: stock_nuevo - stock_anterior = cantidad en cada registro.
CALL _verificar('P13 cada registro de auditoría es consistente',
    NOT EXISTS (SELECT 1 FROM devoluciones
                 WHERE stock_nuevo - stock_anterior <> cantidad_devuelta
                    OR monto_reembolso <> cantidad_devuelta * precio_unitario), NULL);

-- ---------------------------------------------------------------------
-- RESULTADOS
-- ---------------------------------------------------------------------
SELECT n, prueba, resultado, detalle FROM _resultados_pruebas ORDER BY n;
SELECT SUM(resultado = 'PASA') AS pasan, SUM(resultado = 'FALLA') AS fallan, COUNT(*) AS total
FROM _resultados_pruebas;

SELECT * FROM devoluciones ORDER BY id_devolucion;

-- Limpieza de los objetos auxiliares de prueba (los datos de las devoluciones se conservan).
DROP PROCEDURE _verificar;
DROP PROCEDURE _esperar_error;
DROP TABLE _resultados_pruebas;
