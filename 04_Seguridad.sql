-- =====================================================================
-- 04_Seguridad.sql
-- Roles, usuarios y permisos (20 requerimientos de seguridad)
-- Debe ejecutarse con un usuario administrador (root) en MySQL 8.0.30+
-- =====================================================================
USE ecommerce_db;

-- (El requisito 15 – política de contraseñas – está al FINAL de este archivo.)

-- Limpieza para permitir re-ejecución del script
DROP USER IF EXISTS 'admin_user'@'localhost', 'marketing_user'@'localhost', 'inventory_user'@'localhost',
                    'support_user'@'localhost', 'analyst_user'@'localhost', 'auditor_user'@'localhost',
                    'visitor_user'@'localhost';
DROP ROLE IF EXISTS 'Administrador_Sistema', 'Gerente_Marketing', 'Analista_Datos', 'Empleado_Inventario',
                    'Atencion_Cliente', 'Auditor_Financiero', 'Visitante';

-- ---------------------------------------------------------------------
-- 1. Rol Administrador_Sistema con todos los privilegios sobre la base de datos
-- ---------------------------------------------------------------------
CREATE ROLE 'Administrador_Sistema';
GRANT ALL PRIVILEGES ON ecommerce_db.* TO 'Administrador_Sistema' WITH GRANT OPTION;

-- ---------------------------------------------------------------------
-- 2. Rol Gerente_Marketing: solo lectura sobre ventas y clientes
-- ---------------------------------------------------------------------
CREATE ROLE 'Gerente_Marketing';

-- ---------------------------------------------------------------------
-- 3. Rol Analista_Datos: solo lectura sobre todas las tablas de negocio,
--    EXCEPTO las de auditoría (log_*, auditoria_*), a las que no se les concede nada.
-- ---------------------------------------------------------------------
CREATE ROLE 'Analista_Datos';
GRANT SELECT ON ecommerce_db.sucursales       TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.categorias       TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.proveedores      TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.productos        TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.clientes         TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.visitas_producto TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.carritos         TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.promociones      TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.resenas          TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.ajustes_inventario TO 'Analista_Datos';

-- ---------------------------------------------------------------------
-- 4. Rol Empleado_Inventario: solo puede modificar productos (columnas stock y ubicacion)
-- ---------------------------------------------------------------------
CREATE ROLE 'Empleado_Inventario';
GRANT SELECT                    ON ecommerce_db.productos TO 'Empleado_Inventario';
GRANT UPDATE (stock, ubicacion) ON ecommerce_db.productos TO 'Empleado_Inventario';

-- ---------------------------------------------------------------------
-- 5. Rol Atencion_Cliente: ve clientes y ventas, puede actualizar datos de contacto
--    y el estado de un pedido, pero NO puede modificar precios (sin UPDATE en productos
--    ni en detalle_ventas).
-- ---------------------------------------------------------------------
CREATE ROLE 'Atencion_Cliente';
GRANT SELECT (id_cliente, nombre, apellido, direccion_envio, ciudad, region, fecha_registro, nivel_lealtad)
             ON ecommerce_db.clientes       TO 'Atencion_Cliente';
GRANT UPDATE (direccion_envio, ciudad, region) ON ecommerce_db.clientes TO 'Atencion_Cliente';

-- ---------------------------------------------------------------------
-- 6. Rol Auditor_Financiero: solo lectura sobre ventas, productos y logs de precios.
--    La tabla log_cambios_precio se crea en 05_Triggers.sql y MySQL no permite
--    conceder permisos sobre una tabla que aún no existe, por eso el GRANT sobre
--    ella está al final de 05_Triggers.sql ("Complemento de seguridad – requisito 6").
-- ---------------------------------------------------------------------
CREATE ROLE 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.productos          TO 'Auditor_Financiero';

-- ---------------------------------------------------------------------
-- 17. Rol Visitante: solo puede ver la tabla productos
-- ---------------------------------------------------------------------
CREATE ROLE 'Visitante';
GRANT SELECT ON ecommerce_db.productos TO 'Visitante';

-- ---------------------------------------------------------------------
-- 7-10. Usuarios y asignación de roles
--       Todas las cuentas: solo conexión local, contraseña fuerte, caducidad y
--       bloqueo automático tras 3 intentos fallidos (parte del req. 15 y 20).
-- ---------------------------------------------------------------------
-- 7. admin_user -> Administrador_Sistema
CREATE USER 'admin_user'@'localhost' IDENTIFIED BY 'Adm1n#Ecommerce2026'
    PASSWORD EXPIRE INTERVAL 90 DAY FAILED_LOGIN_ATTEMPTS 3 PASSWORD_LOCK_TIME 1;
GRANT 'Administrador_Sistema' TO 'admin_user'@'localhost';
SET DEFAULT ROLE 'Administrador_Sistema' TO 'admin_user'@'localhost';

-- 8. marketing_user -> Gerente_Marketing
CREATE USER 'marketing_user'@'localhost' IDENTIFIED BY 'Mkt#Ventas2026!'
    PASSWORD EXPIRE INTERVAL 90 DAY FAILED_LOGIN_ATTEMPTS 3 PASSWORD_LOCK_TIME 1;
GRANT 'Gerente_Marketing' TO 'marketing_user'@'localhost';
SET DEFAULT ROLE 'Gerente_Marketing' TO 'marketing_user'@'localhost';

-- 9. inventory_user -> Empleado_Inventario
CREATE USER 'inventory_user'@'localhost' IDENTIFIED BY 'Inv#Bodega2026!'
    PASSWORD EXPIRE INTERVAL 90 DAY FAILED_LOGIN_ATTEMPTS 3 PASSWORD_LOCK_TIME 1;
GRANT 'Empleado_Inventario' TO 'inventory_user'@'localhost';
SET DEFAULT ROLE 'Empleado_Inventario' TO 'inventory_user'@'localhost';

-- 10. support_user -> Atencion_Cliente
CREATE USER 'support_user'@'localhost' IDENTIFIED BY 'Sop#Clientes2026!'
    PASSWORD EXPIRE INTERVAL 90 DAY FAILED_LOGIN_ATTEMPTS 3 PASSWORD_LOCK_TIME 1;
GRANT 'Atencion_Cliente' TO 'support_user'@'localhost';
SET DEFAULT ROLE 'Atencion_Cliente' TO 'support_user'@'localhost';

-- Usuarios adicionales para los roles restantes
CREATE USER 'auditor_user'@'localhost' IDENTIFIED BY 'Aud#Finanzas2026!'
    PASSWORD EXPIRE INTERVAL 90 DAY FAILED_LOGIN_ATTEMPTS 3 PASSWORD_LOCK_TIME 1;
GRANT 'Auditor_Financiero' TO 'auditor_user'@'localhost';
SET DEFAULT ROLE 'Auditor_Financiero' TO 'auditor_user'@'localhost';

CREATE USER 'visitor_user'@'localhost' IDENTIFIED BY 'Vis#Catalogo2026!'
    FAILED_LOGIN_ATTEMPTS 3 PASSWORD_LOCK_TIME 1;
GRANT 'Visitante' TO 'visitor_user'@'localhost';
SET DEFAULT ROLE 'Visitante' TO 'visitor_user'@'localhost';

-- ---------------------------------------------------------------------
-- 18. Limitar el número de consultas por hora del Analista_Datos.
--     En MySQL los límites de recursos se aplican a CUENTAS, no a roles, por eso
--     se aplican al usuario que recibe el rol Analista_Datos.
-- ---------------------------------------------------------------------
CREATE USER 'analyst_user'@'localhost' IDENTIFIED BY 'Ana#Datos2026!'
    WITH MAX_QUERIES_PER_HOUR 500        -- máximo 500 consultas por hora
         MAX_CONNECTIONS_PER_HOUR 50
         MAX_USER_CONNECTIONS 3
    PASSWORD EXPIRE INTERVAL 90 DAY FAILED_LOGIN_ATTEMPTS 3 PASSWORD_LOCK_TIME 1;
GRANT 'Analista_Datos' TO 'analyst_user'@'localhost';
SET DEFAULT ROLE 'Analista_Datos' TO 'analyst_user'@'localhost';

-- Cada cuenta operativa pertenece a una sola sucursal; el administrador conserva acceso global.
INSERT INTO usuarios_sucursales (usuario_db, id_sucursal) VALUES
('marketing_user', 2), ('inventory_user', 1), ('support_user', 1),
('analyst_user', 2), ('auditor_user', 3), ('visitor_user', 3)
ON DUPLICATE KEY UPDATE id_sucursal = VALUES(id_sucursal);

-- ---------------------------------------------------------------------
-- 11. Impedir que Analista_Datos ejecute DELETE o TRUNCATE.
--     TRUNCATE requiere el privilegio DROP. Se revocan de forma explícita
--     (IF EXISTS evita error si nunca se concedieron) y el rol solo conserva SELECT.
-- ---------------------------------------------------------------------
REVOKE IF EXISTS DELETE, DROP ON ecommerce_db.* FROM 'Analista_Datos';

-- ---------------------------------------------------------------------
-- 12. Permiso de Gerente_Marketing para ejecutar los procedimientos de reportes
--     de marketing. Como un GRANT EXECUTE ON PROCEDURE exige que el procedimiento
--     ya exista, este GRANT está al FINAL de 07_Procedimientos_Almacenados.sql
--     (sección "Complemento de seguridad – requisito 12").
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- 13. Vista v_info_clientes_basica que oculta datos sensibles
--     (sin contraseña, sin fecha de nacimiento, email enmascarado, sin gasto total)
-- ---------------------------------------------------------------------
CREATE OR REPLACE SQL SECURITY DEFINER VIEW v_info_clientes_basica AS
SELECT id_cliente,
       nombre,
       apellido,
       CONCAT(LEFT(email, 2), '****', SUBSTRING(email, LOCATE('@', email))) AS email_enmascarado,
       ciudad,
       region,
       nivel_lealtad,
       fecha_registro
FROM clientes
WHERE eliminado_en IS NULL;

GRANT SELECT ON ecommerce_db.v_info_clientes_basica TO 'Atencion_Cliente';
GRANT SELECT ON ecommerce_db.v_info_clientes_basica TO 'Gerente_Marketing';

-- ---------------------------------------------------------------------
-- 14. Revocar UPDATE sobre la columna precio de productos a Empleado_Inventario.
--     Garantiza que, aunque alguien se lo hubiera concedido, el rol no pueda cambiar precios.
-- ---------------------------------------------------------------------
REVOKE IF EXISTS UPDATE (precio) ON ecommerce_db.productos FROM 'Empleado_Inventario';

-- ---------------------------------------------------------------------
-- 16. El usuario root no puede usarse desde conexiones remotas:
--     elimina cualquier cuenta root cuyo host no sea de loopback.
--     El firewall/bind-address también debe limitar conexiones al servidor.
-- ---------------------------------------------------------------------
SET SESSION group_concat_max_len = 65535;
SELECT GROUP_CONCAT(CONCAT(QUOTE(user), '@', QUOTE(host)) SEPARATOR ', ')
INTO @cuentas_root_remotas
FROM mysql.user
WHERE user = 'root' AND host NOT IN ('localhost','127.0.0.1','::1');
SET @sql_eliminar_root_remoto = IF(@cuentas_root_remotas IS NULL, 'SELECT 1',
    CONCAT('DROP USER IF EXISTS ', @cuentas_root_remotas));
PREPARE stmt_root_remoto FROM @sql_eliminar_root_remoto;
EXECUTE stmt_root_remoto;
DEALLOCATE PREPARE stmt_root_remoto;
-- Verificación: solo deben quedar localhost / 127.0.0.1 / ::1
SELECT user, host FROM mysql.user WHERE user = 'root';

-- ---------------------------------------------------------------------
-- 19. Cada usuario solo ve las ventas de su sucursal.
--     ventas.id_sucursal y sucursales.usuario_db se crearon en 01_Esquema_y_Datos.sql.
--     La vista filtra por el usuario conectado (USER()), y a los roles operativos
--     se les da acceso a la vista en lugar de a la tabla completa.
-- ---------------------------------------------------------------------
CREATE OR REPLACE SQL SECURITY DEFINER VIEW v_ventas_mi_sucursal AS
SELECT v.*
FROM ventas v
WHERE EXISTS (
        SELECT 1 FROM usuarios_sucursales us
        WHERE us.usuario_db = SUBSTRING_INDEX(USER(), '@', 1)
            AND us.id_sucursal = v.id_sucursal
);

CREATE OR REPLACE SQL SECURITY DEFINER VIEW v_detalle_ventas_mi_sucursal AS
SELECT d.*
FROM detalle_ventas d
JOIN ventas v ON v.id_venta = d.id_venta
WHERE EXISTS (
        SELECT 1 FROM usuarios_sucursales us
        WHERE us.usuario_db = SUBSTRING_INDEX(USER(), '@', 1)
            AND us.id_sucursal = v.id_sucursal
);

CREATE OR REPLACE SQL SECURITY DEFINER VIEW v_pagos_mi_sucursal AS
SELECT p.*
FROM pagos p
JOIN ventas v ON v.id_venta = p.id_venta
WHERE EXISTS (
        SELECT 1 FROM usuarios_sucursales us
        WHERE us.usuario_db = SUBSTRING_INDEX(USER(), '@', 1)
            AND us.id_sucursal = v.id_sucursal
);

CREATE OR REPLACE SQL SECURITY DEFINER VIEW v_creditos_mi_sucursal AS
SELECT cc.*
FROM creditos_cliente cc
JOIN ventas v ON v.id_venta = cc.id_venta
WHERE EXISTS (
        SELECT 1 FROM usuarios_sucursales us
        WHERE us.usuario_db = SUBSTRING_INDEX(USER(), '@', 1)
            AND us.id_sucursal = v.id_sucursal
);

CREATE OR REPLACE SQL SECURITY DEFINER VIEW v_notificaciones_mi_sucursal AS
SELECT n.*
FROM notificaciones n
JOIN ventas v ON v.id_venta = CAST(JSON_UNQUOTE(JSON_EXTRACT(n.payload, '$.id_venta')) AS UNSIGNED)
WHERE EXISTS (
        SELECT 1 FROM usuarios_sucursales us
        WHERE us.usuario_db = SUBSTRING_INDEX(USER(), '@', 1)
            AND us.id_sucursal = v.id_sucursal
);

GRANT SELECT ON ecommerce_db.v_ventas_mi_sucursal TO 'Atencion_Cliente';
GRANT SELECT ON ecommerce_db.v_ventas_mi_sucursal TO 'Gerente_Marketing';
GRANT SELECT ON ecommerce_db.v_ventas_mi_sucursal TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.v_ventas_mi_sucursal TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.v_detalle_ventas_mi_sucursal TO 'Atencion_Cliente';
GRANT SELECT ON ecommerce_db.v_detalle_ventas_mi_sucursal TO 'Gerente_Marketing';
GRANT SELECT ON ecommerce_db.v_detalle_ventas_mi_sucursal TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.v_detalle_ventas_mi_sucursal TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.v_pagos_mi_sucursal TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.v_creditos_mi_sucursal TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.v_notificaciones_mi_sucursal TO 'Analista_Datos';

-- ---------------------------------------------------------------------
-- 20. Auditar los intentos de inicio de sesión fallidos.
--     a) log_error_verbosity = 3 hace que MySQL escriba cada "Access denied for user"
--        en el log de errores (MySQL Community no incluye el plugin Enterprise Audit).
--     b) performance_schema.host_cache cuenta los errores de autenticación por host.
--     c) FAILED_LOGIN_ATTEMPTS (arriba) bloquea la cuenta tras 3 fallos.
--     d) La vista v_intentos_login_fallidos permite consultarlos desde SQL.
-- ---------------------------------------------------------------------
SET PERSIST log_error_verbosity = 3;

CREATE OR REPLACE VIEW v_intentos_login_fallidos AS
SELECT ip, host, count_authentication_errors, count_handshake_errors,
       first_seen, last_seen, first_error_seen, last_error_seen
FROM performance_schema.host_cache
WHERE count_authentication_errors > 0 OR count_handshake_errors > 0;

GRANT SELECT ON ecommerce_db.v_intentos_login_fallidos TO 'Administrador_Sistema';

FLUSH PRIVILEGES;

-- ---------------------------------------------------------------------
-- 15. Política de contraseñas seguras para TODOS los usuarios
--     INSTALL COMPONENT no admite "IF NOT EXISTS", así que solo se instala si el
--     componente aún no está registrado en mysql.component (evita el error 3529).
--     Todas las contraseñas de este script ya cumplen la política STRONG.
-- ---------------------------------------------------------------------
SET @sql_validate_password = IF(
    (SELECT COUNT(*) FROM mysql.component
      WHERE component_urn = 'file://component_validate_password') = 0,
    'INSTALL COMPONENT ''file://component_validate_password''',
    'SELECT ''validate_password ya estaba instalado'' AS aviso');
PREPARE stmt_validate_password FROM @sql_validate_password;
EXECUTE stmt_validate_password;
DEALLOCATE PREPARE stmt_validate_password;
SET PERSIST validate_password.policy               = 'STRONG';  -- mayús., minús., número, símbolo y diccionario
SET PERSIST validate_password.length               = 10;
SET PERSIST validate_password.mixed_case_count     = 1;
SET PERSIST validate_password.number_count         = 1;
SET PERSIST validate_password.special_char_count   = 1;
SET PERSIST default_password_lifetime              = 90;        -- las contraseñas caducan cada 90 días
SET PERSIST password_history                       = 5;         -- no reutilizar las últimas 5
SET PERSIST password_reuse_interval                = 365;

-- Verificación de roles y privilegios
SHOW GRANTS FOR 'Analista_Datos';
SHOW GRANTS FOR 'Empleado_Inventario';
SHOW GRANTS FOR 'support_user'@'localhost' USING 'Atencion_Cliente';
