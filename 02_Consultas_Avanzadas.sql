-- =====================================================================
-- 02_Consultas_Avanzadas.sql
-- 20 consultas de análisis y reporteo (MySQL 8.0+: CTE y funciones de ventana)
-- Convención: se consideran "ventas válidas" las que NO están Canceladas ni Devueltas.
-- =====================================================================
USE ecommerce_db;

-- 1. Top 10 Productos Más Vendidos: ranking de los 10 productos que más ingresos han generado.
SELECT p.id_producto,
       p.nombre,
       SUM(d.cantidad)                               AS unidades_vendidas,
       SUM(d.cantidad * d.precio_unitario_congelado) AS ingresos,
       RANK() OVER (ORDER BY SUM(d.cantidad * d.precio_unitario_congelado) DESC) AS posicion
FROM detalle_ventas d
JOIN ventas v    ON v.id_venta = d.id_venta
JOIN productos p ON p.id_producto = d.id_producto
WHERE v.estado NOT IN ('Cancelado','Devuelto')
GROUP BY p.id_producto, p.nombre
ORDER BY ingresos DESC
LIMIT 10;

-- 2. Productos con Bajas Ventas: productos en el 10% inferior de ingresos (incluye los que nunca se vendieron).
WITH ventas_producto AS (
    SELECT p.id_producto, p.nombre,
           COALESCE(SUM(CASE WHEN v.estado NOT IN ('Cancelado','Devuelto')
                             THEN d.cantidad * d.precio_unitario_congelado END),0) AS ingresos
    FROM productos p
    LEFT JOIN detalle_ventas d ON d.id_producto = p.id_producto
    LEFT JOIN ventas v         ON v.id_venta = d.id_venta
    GROUP BY p.id_producto, p.nombre
), ranking AS (
    SELECT vp.*, PERCENT_RANK() OVER (ORDER BY ingresos ASC) AS percentil
    FROM ventas_producto vp
)
SELECT id_producto, nombre, ingresos, ROUND(percentil*100,2) AS percentil_pct
FROM ranking
WHERE percentil <= 0.10
ORDER BY ingresos;

-- 3. Clientes VIP: los 5 clientes con mayor valor de vida (LTV = gasto total histórico).
SELECT c.id_cliente,
       CONCAT(c.nombre,' ',c.apellido) AS cliente,
       COUNT(v.id_venta)               AS num_compras,
       SUM(v.total)                    AS ltv
FROM clientes c
JOIN ventas v ON v.id_cliente = c.id_cliente
WHERE v.estado NOT IN ('Cancelado','Devuelto')
GROUP BY c.id_cliente, cliente
ORDER BY ltv DESC
LIMIT 5;

-- 4. Análisis de Ventas Mensuales: ventas totales agrupadas por año y mes.
SELECT YEAR(fecha_venta)  AS anio,
       MONTH(fecha_venta) AS mes,
       COUNT(*)           AS num_ventas,
       SUM(total)         AS total_ventas
FROM ventas
WHERE estado NOT IN ('Cancelado','Devuelto')
GROUP BY anio, mes
ORDER BY anio, mes;

-- 5. Crecimiento de Clientes: nuevos clientes registrados por trimestre (y acumulado).
SELECT YEAR(fecha_registro)    AS anio,
       QUARTER(fecha_registro) AS trimestre,
       COUNT(*)                AS nuevos_clientes,
       SUM(COUNT(*)) OVER (ORDER BY YEAR(fecha_registro), QUARTER(fecha_registro)) AS acumulado
FROM clientes
GROUP BY anio, trimestre
ORDER BY anio, trimestre;

-- 6. Tasa de Compra Repetida: porcentaje de clientes compradores con más de una compra.
SELECT COUNT(*)                                        AS clientes_con_compras,
       SUM(num_compras > 1)                            AS clientes_recurrentes,
       ROUND(100 * SUM(num_compras > 1) / COUNT(*), 2) AS tasa_compra_repetida_pct
FROM (SELECT id_cliente, COUNT(*) AS num_compras
      FROM ventas
      WHERE estado NOT IN ('Cancelado','Devuelto')
      GROUP BY id_cliente) t;

-- 7. Productos Comprados Juntos Frecuentemente: pares de productos presentes en la misma venta.
SELECT d1.id_producto AS producto_a, pa.nombre AS nombre_a,
       d2.id_producto AS producto_b, pb.nombre AS nombre_b,
       COUNT(DISTINCT d1.id_venta) AS veces_juntos
FROM detalle_ventas d1
JOIN detalle_ventas d2 ON d1.id_venta = d2.id_venta AND d1.id_producto < d2.id_producto
JOIN productos pa ON pa.id_producto = d1.id_producto
JOIN productos pb ON pb.id_producto = d2.id_producto
GROUP BY producto_a, nombre_a, producto_b, nombre_b
HAVING veces_juntos >= 2
ORDER BY veces_juntos DESC;

-- 8. Rotación de Inventario por categoría: costo de lo vendido / valor del inventario actual a costo.
SELECT c.nombre AS categoria,
       COALESCE(SUM(vendido.costo_vendido),0)             AS costo_mercancia_vendida,
       SUM(p.stock * p.costo)                              AS valor_inventario_actual,
       ROUND(COALESCE(SUM(vendido.costo_vendido),0) / NULLIF(SUM(p.stock * p.costo),0), 2) AS indice_rotacion
FROM categorias c
JOIN productos p ON p.id_categoria = c.id_categoria
LEFT JOIN (SELECT d.id_producto, SUM(d.cantidad * pr.costo) AS costo_vendido
           FROM detalle_ventas d
           JOIN ventas v     ON v.id_venta = d.id_venta
           JOIN productos pr ON pr.id_producto = d.id_producto
           WHERE v.estado NOT IN ('Cancelado','Devuelto')
           GROUP BY d.id_producto) vendido ON vendido.id_producto = p.id_producto
GROUP BY c.id_categoria, c.nombre
ORDER BY indice_rotacion DESC;

-- 9. Productos que Necesitan Reabastecimiento: stock actual por debajo del umbral mínimo.
SELECT id_producto, nombre, sku, stock, stock_minimo,
       (stock_minimo * 2 - stock) AS cantidad_sugerida_pedido
FROM productos
WHERE activo = TRUE AND stock < stock_minimo
ORDER BY (stock - stock_minimo);

-- 10. Análisis de Carrito Abandonado (Simulado): clientes con productos en el carrito
--     que no han completado una venta en los últimos 30 días.
SELECT c.id_cliente, CONCAT(c.nombre,' ',c.apellido) AS cliente, c.email,
       COUNT(ca.id_carrito)                 AS productos_en_carrito,
       SUM(ca.cantidad * p.precio)          AS valor_carrito,
       MAX(ca.fecha_agregado)               AS ultimo_agregado
FROM carritos ca
JOIN clientes  c ON c.id_cliente = ca.id_cliente
JOIN productos p ON p.id_producto = ca.id_producto
WHERE NOT EXISTS (SELECT 1 FROM ventas v
                  WHERE v.id_cliente = ca.id_cliente
                    AND v.estado NOT IN ('Cancelado','Devuelto')
                    AND v.fecha_venta >= ca.fecha_agregado - INTERVAL 30 DAY)
GROUP BY c.id_cliente, cliente, c.email
ORDER BY valor_carrito DESC;

-- 11. Rendimiento de Proveedores: clasificación según el volumen de ventas de sus productos.
SELECT pr.id_proveedor, pr.nombre AS proveedor,
       COALESCE(SUM(d.cantidad),0)                              AS unidades_vendidas,
       COALESCE(SUM(d.cantidad * d.precio_unitario_congelado),0) AS ingresos,
       DENSE_RANK() OVER (ORDER BY COALESCE(SUM(d.cantidad * d.precio_unitario_congelado),0) DESC) AS ranking
FROM proveedores pr
LEFT JOIN productos p      ON p.id_proveedor = pr.id_proveedor
LEFT JOIN detalle_ventas d ON d.id_producto = p.id_producto
       AND d.id_venta IN (SELECT id_venta FROM ventas WHERE estado NOT IN ('Cancelado','Devuelto'))
GROUP BY pr.id_proveedor, pr.nombre
ORDER BY ranking;

-- 12. Análisis Geográfico de Ventas: ventas agrupadas por región y ciudad del cliente.
SELECT c.region, c.ciudad,
       COUNT(v.id_venta)          AS num_ventas,
       COUNT(DISTINCT c.id_cliente) AS clientes,
       SUM(v.total)               AS total_ventas
FROM ventas v
JOIN clientes c ON c.id_cliente = v.id_cliente
WHERE v.estado NOT IN ('Cancelado','Devuelto')
GROUP BY c.region, c.ciudad WITH ROLLUP;

-- 13. Ventas por Hora del Día: horas pico de compras.
SELECT HOUR(fecha_venta) AS hora,
       COUNT(*)          AS num_ventas,
       SUM(total)        AS total_ventas,
       RANK() OVER (ORDER BY COUNT(*) DESC) AS ranking_hora
FROM ventas
WHERE estado NOT IN ('Cancelado','Devuelto')
GROUP BY hora
ORDER BY num_ventas DESC, hora;

-- 14. Impacto de Promociones: ventas de un producto antes, durante y después de su campaña
--     (se usa una ventana de 30 días antes y 30 días después de la promoción).
SELECT pm.codigo, p.nombre AS producto,
       CASE WHEN v.fecha_venta <  pm.fecha_inicio THEN '1. Antes'
            WHEN v.fecha_venta <= pm.fecha_fin    THEN '2. Durante'
            ELSE '3. Después' END                  AS periodo,
       COUNT(DISTINCT v.id_venta)                  AS num_ventas,
       COALESCE(SUM(d.cantidad),0)                 AS unidades,
       COALESCE(SUM(d.cantidad * d.precio_unitario_congelado),0) AS ingresos
FROM promociones pm
JOIN productos p      ON p.id_producto = pm.id_producto
JOIN detalle_ventas d ON d.id_producto = pm.id_producto
JOIN ventas v         ON v.id_venta = d.id_venta
WHERE v.estado NOT IN ('Cancelado','Devuelto')
  AND v.fecha_venta BETWEEN pm.fecha_inicio - INTERVAL 30 DAY AND pm.fecha_fin + INTERVAL 30 DAY
GROUP BY pm.codigo, p.nombre, periodo
ORDER BY pm.codigo, periodo;

-- 15. Análisis de Cohort: retención mes a mes desde la primera compra de cada cliente.
WITH primera AS (
    SELECT id_cliente, DATE_FORMAT(MIN(fecha_venta),'%Y-%m-01') AS cohorte
    FROM ventas WHERE estado NOT IN ('Cancelado','Devuelto')
    GROUP BY id_cliente
), actividad AS (
    SELECT DISTINCT v.id_cliente, p.cohorte,
           TIMESTAMPDIFF(MONTH, p.cohorte, DATE_FORMAT(v.fecha_venta,'%Y-%m-01')) AS mes_desde_inicio
    FROM ventas v JOIN primera p ON p.id_cliente = v.id_cliente
    WHERE v.estado NOT IN ('Cancelado','Devuelto')
), tamanio AS (
    SELECT cohorte, COUNT(*) AS clientes_cohorte FROM primera GROUP BY cohorte
)
SELECT a.cohorte, t.clientes_cohorte, a.mes_desde_inicio,
       COUNT(DISTINCT a.id_cliente) AS clientes_activos,
       ROUND(100 * COUNT(DISTINCT a.id_cliente) / t.clientes_cohorte, 2) AS retencion_pct
FROM actividad a JOIN tamanio t ON t.cohorte = a.cohorte
GROUP BY a.cohorte, t.clientes_cohorte, a.mes_desde_inicio
ORDER BY a.cohorte, a.mes_desde_inicio;

-- 16. Margen de Beneficio por Producto (usa el campo costo de productos).
SELECT p.id_producto, p.nombre, p.precio, p.costo,
       (p.precio - p.costo)                            AS margen_unitario,
       ROUND(100 * (p.precio - p.costo) / p.precio, 2) AS margen_pct,
       COALESCE(SUM(d.cantidad * (d.precio_unitario_congelado - p.costo)),0) AS utilidad_realizada
FROM productos p
LEFT JOIN detalle_ventas d ON d.id_producto = p.id_producto
       AND d.id_venta IN (SELECT id_venta FROM ventas WHERE estado NOT IN ('Cancelado','Devuelto'))
GROUP BY p.id_producto, p.nombre, p.precio, p.costo
ORDER BY margen_pct DESC;

-- 17. Tiempo Promedio Entre Compras: días medios que tarda un cliente en volver a comprar.
WITH compras AS (
    SELECT id_cliente, fecha_venta,
           LAG(fecha_venta) OVER (PARTITION BY id_cliente ORDER BY fecha_venta) AS compra_anterior
    FROM ventas WHERE estado NOT IN ('Cancelado','Devuelto')
)
SELECT c.id_cliente, CONCAT(cl.nombre,' ',cl.apellido) AS cliente,
       COUNT(*) + 1                                              AS num_compras,
       ROUND(AVG(DATEDIFF(c.fecha_venta, c.compra_anterior)),1) AS dias_promedio_entre_compras
FROM compras c JOIN clientes cl ON cl.id_cliente = c.id_cliente
WHERE c.compra_anterior IS NOT NULL
GROUP BY c.id_cliente, cliente
UNION ALL
SELECT NULL, '== PROMEDIO GENERAL ==', NULL,
       ROUND(AVG(DATEDIFF(fecha_venta, compra_anterior)),1)
FROM compras WHERE compra_anterior IS NOT NULL;

-- 18. Productos Más Vistos vs. Comprados: tasa de conversión visita -> unidad vendida.
SELECT p.id_producto, p.nombre,
       COALESCE(vis.visitas,0)  AS visitas,
       COALESCE(ven.unidades,0) AS unidades_compradas,
       ROUND(100 * COALESCE(ven.unidades,0) / NULLIF(vis.visitas,0), 2) AS conversion_pct
FROM productos p
LEFT JOIN (SELECT id_producto, COUNT(*) AS visitas FROM visitas_producto GROUP BY id_producto) vis
       ON vis.id_producto = p.id_producto
LEFT JOIN (SELECT d.id_producto, SUM(d.cantidad) AS unidades
           FROM detalle_ventas d JOIN ventas v ON v.id_venta = d.id_venta
           WHERE v.estado NOT IN ('Cancelado','Devuelto')
           GROUP BY d.id_producto) ven ON ven.id_producto = p.id_producto
WHERE vis.visitas IS NOT NULL OR ven.unidades IS NOT NULL
ORDER BY visitas DESC, unidades_compradas DESC;

-- 19. Segmentación de Clientes (RFM): puntuación 1-5 en Recencia, Frecuencia y Monetario.
WITH base AS (
    SELECT c.id_cliente, CONCAT(c.nombre,' ',c.apellido) AS cliente,
           DATEDIFF(CURDATE(), MAX(v.fecha_venta)) AS recencia_dias,
           COUNT(v.id_venta)                       AS frecuencia,
           SUM(v.total)                            AS monetario
    FROM clientes c JOIN ventas v ON v.id_cliente = c.id_cliente
    WHERE v.estado NOT IN ('Cancelado','Devuelto')
    GROUP BY c.id_cliente, cliente
), puntajes AS (
    SELECT b.*,
           NTILE(5) OVER (ORDER BY recencia_dias DESC) AS r,
           NTILE(5) OVER (ORDER BY frecuencia ASC)     AS f,
           NTILE(5) OVER (ORDER BY monetario ASC)      AS m
    FROM base b
)
SELECT id_cliente, cliente, recencia_dias, frecuencia, monetario, r, f, m,
       CONCAT(r,f,m) AS rfm,
       CASE WHEN r >= 4 AND f >= 4 AND m >= 4 THEN 'Campeones'
            WHEN f >= 4                      THEN 'Leales'
            WHEN r >= 4                      THEN 'Recientes / Prometedores'
            WHEN r <= 2 AND m >= 4           THEN 'En riesgo (alto valor)'
            WHEN r <= 2                      THEN 'Hibernando'
            ELSE 'Necesitan atención' END AS segmento
FROM puntajes
ORDER BY monetario DESC;

-- 20. Predicción de Demanda Simple: proyección del próximo mes para una categoría
--     (media móvil de los últimos 3 meses con venta + tendencia lineal). Categoría ejemplo: Electrónica.
SET @categoria := 'Electrónica';
WITH mensual AS (
    SELECT DATE_FORMAT(v.fecha_venta,'%Y-%m') AS periodo,
           SUM(d.cantidad)                    AS unidades,
           SUM(d.cantidad * d.precio_unitario_congelado) AS ingresos
    FROM ventas v
    JOIN detalle_ventas d ON d.id_venta = v.id_venta
    JOIN productos p      ON p.id_producto = d.id_producto
    JOIN categorias c     ON c.id_categoria = p.id_categoria
    WHERE c.nombre = @categoria COLLATE utf8mb4_unicode_ci AND v.estado NOT IN ('Cancelado','Devuelto')
    GROUP BY periodo
), numerado AS (
    SELECT periodo, unidades, ingresos, ROW_NUMBER() OVER (ORDER BY periodo) AS x FROM mensual
), regresion AS (
    SELECT (COUNT(*)*SUM(x*unidades) - SUM(x)*SUM(unidades)) /
           NULLIF(COUNT(*)*SUM(x*x) - SUM(x)*SUM(x),0) AS pendiente,
           MAX(x) AS ultimo_x
    FROM numerado
), ultimos3 AS (
    SELECT AVG(unidades) AS media_unidades, AVG(ingresos) AS media_ingresos
    FROM (SELECT unidades, ingresos FROM numerado ORDER BY x DESC LIMIT 3) t
)
SELECT @categoria                                         AS categoria,
       DATE_FORMAT(CURDATE() + INTERVAL 1 MONTH,'%Y-%m')  AS mes_proyectado,
       ROUND(u.media_unidades, 1)                         AS media_movil_unidades,
       ROUND(r.pendiente, 3)                              AS tendencia_por_mes,
       GREATEST(ROUND(u.media_unidades + COALESCE(r.pendiente,0)),0) AS unidades_proyectadas,
       ROUND(u.media_ingresos, 0)                         AS ingresos_proyectados
FROM ultimos3 u CROSS JOIN regresion r;
