-- =====================================================================
-- 01_Esquema_y_Datos.sql
-- Proyecto de Base de Datos para un E-commerce
-- Motor objetivo: MySQL 8.0+
-- Contenido: creación de la base de datos, todas las tablas (CREATE TABLE)
--            y los datos de ejemplo (INSERT INTO).
-- =====================================================================

DROP DATABASE IF EXISTS ecommerce_db;
CREATE DATABASE ecommerce_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE ecommerce_db;

-- ---------------------------------------------------------------------
-- TABLAS PRINCIPALES
-- ---------------------------------------------------------------------

-- Sucursales (requerida por el requisito de seguridad #19: cada usuario
-- solo ve las ventas de su sucursal)
CREATE TABLE sucursales (
    id_sucursal   INT AUTO_INCREMENT PRIMARY KEY,
    nombre        VARCHAR(100) NOT NULL UNIQUE,
    ciudad        VARCHAR(80)  NOT NULL,
    usuario_db    VARCHAR(80)  NULL COMMENT 'Compatibilidad con instalaciones anteriores'
);

CREATE TABLE usuarios_sucursales (
    usuario_db  VARCHAR(80) NOT NULL PRIMARY KEY,
    id_sucursal INT NOT NULL,
    CONSTRAINT fk_usuario_sucursal FOREIGN KEY (id_sucursal)
        REFERENCES sucursales(id_sucursal) ON UPDATE CASCADE ON DELETE RESTRICT
);

-- Categorías: clasificación de productos
CREATE TABLE categorias (
    id_categoria     INT AUTO_INCREMENT PRIMARY KEY,
    id_categoria_padre INT NULL,
    nombre           VARCHAR(100) NOT NULL UNIQUE,
    descripcion      TEXT NULL,
    total_productos  INT NOT NULL DEFAULT 0 COMMENT 'Contador mantenido por trigger',
    CONSTRAINT fk_categoria_padre FOREIGN KEY (id_categoria_padre)
        REFERENCES categorias(id_categoria) ON UPDATE CASCADE ON DELETE SET NULL
);

-- Proveedores: quienes suministran los productos
CREATE TABLE proveedores (
    id_proveedor       INT AUTO_INCREMENT PRIMARY KEY,
    nombre             VARCHAR(150) NOT NULL,
    email_contacto     VARCHAR(150) UNIQUE,
    telefono_contacto  VARCHAR(30)
);

-- Productos: catálogo e inventario
CREATE TABLE productos (
    id_producto         INT AUTO_INCREMENT PRIMARY KEY,
    nombre              VARCHAR(150) NOT NULL UNIQUE,
    descripcion         TEXT NULL,
    precio              DECIMAL(12,2) NOT NULL,
    costo               DECIMAL(12,2) NOT NULL,
    stock               INT NOT NULL DEFAULT 0,
    stock_minimo        INT NOT NULL DEFAULT 5  COMMENT 'Umbral de reabastecimiento',
    sku                 VARCHAR(50)  NOT NULL UNIQUE,
    peso_kg             DECIMAL(8,3) NOT NULL DEFAULT 0.500,
    ubicacion           VARCHAR(50)  NULL COMMENT 'Ubicación física en bodega',
    fecha_creacion      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_modificacion  DATETIME NULL,
    activo              BOOLEAN NOT NULL DEFAULT TRUE,
    id_categoria        INT NULL,
    id_proveedor        INT NOT NULL,
    CONSTRAINT chk_producto_precio CHECK (precio > 0),
    CONSTRAINT chk_producto_costo  CHECK (costo >= 0),
    CONSTRAINT chk_producto_stock  CHECK (stock >= 0),
    CONSTRAINT fk_producto_categoria FOREIGN KEY (id_categoria)
        REFERENCES categorias(id_categoria) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_producto_proveedor FOREIGN KEY (id_proveedor)
        REFERENCES proveedores(id_proveedor) ON UPDATE CASCADE ON DELETE RESTRICT
);

-- Clientes: usuarios registrados
CREATE TABLE clientes (
    id_cliente           INT AUTO_INCREMENT PRIMARY KEY,
    nombre               VARCHAR(80)  NOT NULL,
    apellido             VARCHAR(80)  NOT NULL,
    email                VARCHAR(150) NOT NULL UNIQUE,
    contrasena           VARCHAR(255) NOT NULL COMMENT 'Hash PBKDF2 generado y verificado por la aplicación',
    direccion_envio      VARCHAR(255) NULL,
    ciudad               VARCHAR(80)  NULL,
    region               VARCHAR(80)  NULL,
    fecha_nacimiento     DATE NULL,
    fecha_registro       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    total_gastado        DECIMAL(14,2) NOT NULL DEFAULT 0,
    fecha_ultimo_pedido  DATETIME NULL,
    nivel_lealtad        ENUM('Bronce','Plata','Oro') NOT NULL DEFAULT 'Bronce',
    id_referido_por      INT NULL COMMENT 'Programa de referidos',
    activo               BOOLEAN NOT NULL DEFAULT TRUE,
    eliminado_en         DATETIME NULL COMMENT 'Borrado lógico (soft delete)',
    CONSTRAINT fk_cliente_referido FOREIGN KEY (id_referido_por)
        REFERENCES clientes(id_cliente) ON DELETE SET NULL
);

-- Ventas: encabezado de la orden
CREATE TABLE ventas (
    id_venta     INT AUTO_INCREMENT PRIMARY KEY,
    id_cliente   INT NOT NULL,
    id_sucursal  INT NOT NULL DEFAULT 1,
    fecha_venta  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    estado       ENUM('Pendiente de Pago','Pagado','Procesando','Enviado','Entregado','Cancelado','Devolución Parcial','Devuelto Totalmente')
                 NOT NULL DEFAULT 'Pendiente de Pago',
    total        DECIMAL(14,2) NOT NULL DEFAULT 0,
    direccion_envio VARCHAR(255) NULL COMMENT 'Dirección de despacho de este pedido',
    CONSTRAINT fk_venta_cliente  FOREIGN KEY (id_cliente)  REFERENCES clientes(id_cliente),
    CONSTRAINT fk_venta_sucursal FOREIGN KEY (id_sucursal) REFERENCES sucursales(id_sucursal)
);

-- Detalle de ventas: tabla puente N:M entre ventas y productos
CREATE TABLE detalle_ventas (
    id_detalle                 INT AUTO_INCREMENT PRIMARY KEY,
    id_venta                   INT NOT NULL,
    id_producto                INT NOT NULL,
    cantidad                   INT NOT NULL,
    precio_unitario_congelado  DECIMAL(12,2) NOT NULL COMMENT 'Precio histórico al momento de la compra',
    CONSTRAINT chk_detalle_cantidad CHECK (cantidad > 0),
    CONSTRAINT uq_detalle_venta_producto UNIQUE (id_venta, id_producto),
    CONSTRAINT fk_detalle_venta    FOREIGN KEY (id_venta)    REFERENCES ventas(id_venta) ON DELETE CASCADE,
    CONSTRAINT fk_detalle_producto FOREIGN KEY (id_producto) REFERENCES productos(id_producto)
);

-- ---------------------------------------------------------------------
-- TABLAS DE APOYO (necesarias para consultas, funciones y procedimientos)
-- ---------------------------------------------------------------------

-- Visitas a productos (consulta 18: más vistos vs. más comprados)
CREATE TABLE visitas_producto (
    id_visita    INT AUTO_INCREMENT PRIMARY KEY,
    id_producto  INT NOT NULL,
    id_cliente   INT NULL,
    fecha_visita DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (id_producto) REFERENCES productos(id_producto),
    FOREIGN KEY (id_cliente)  REFERENCES clientes(id_cliente)
);

-- Carritos de compra (consulta 10 y evento de carritos abandonados)
CREATE TABLE carritos (
    id_carrito      INT AUTO_INCREMENT PRIMARY KEY,
    id_cliente      INT NOT NULL,
    id_producto     INT NOT NULL,
    cantidad        INT NOT NULL DEFAULT 1,
    fecha_agregado  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (id_cliente)  REFERENCES clientes(id_cliente),
    FOREIGN KEY (id_producto) REFERENCES productos(id_producto)
);

-- Promociones / códigos de descuento (consulta 14 y evento de expiración)
CREATE TABLE promociones (
    id_promocion   INT AUTO_INCREMENT PRIMARY KEY,
    codigo         VARCHAR(30) NOT NULL UNIQUE,
    id_producto    INT NULL,
    porcentaje     DECIMAL(5,2) NOT NULL,
    fecha_inicio   DATETIME NOT NULL,
    fecha_fin      DATETIME NOT NULL,
    activa         BOOLEAN NOT NULL DEFAULT TRUE,
    FOREIGN KEY (id_producto) REFERENCES productos(id_producto)
);

-- Reseñas de productos (sp_AñadirReseñaProducto)
CREATE TABLE resenas (
    id_resena     INT AUTO_INCREMENT PRIMARY KEY,
    id_producto   INT NOT NULL,
    id_cliente    INT NOT NULL,
    calificacion  TINYINT NOT NULL,
    comentario    TEXT NULL,
    fecha         DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_resena_calificacion CHECK (calificacion BETWEEN 1 AND 5),
    UNIQUE KEY uq_resena (id_producto, id_cliente),
    FOREIGN KEY (id_producto) REFERENCES productos(id_producto),
    FOREIGN KEY (id_cliente)  REFERENCES clientes(id_cliente)
);

-- Créditos a favor del cliente (los genera sp_ProcesarDevolucion, ver 08_Devoluciones.sql)
CREATE TABLE creditos_cliente (
    id_credito  INT AUTO_INCREMENT PRIMARY KEY,
    id_cliente  INT NOT NULL,
    id_venta    INT NULL,
    monto       DECIMAL(12,2) NOT NULL,
    motivo      VARCHAR(255),
    fecha       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (id_cliente) REFERENCES clientes(id_cliente)
);

-- Pagos registrados (sp_ProcesarPago)
CREATE TABLE pagos (
    id_pago     INT AUTO_INCREMENT PRIMARY KEY,
    id_venta    INT NOT NULL,
    monto       DECIMAL(14,2) NOT NULL,
    metodo      ENUM('Tarjeta','PSE','Efectivo','Transferencia') NOT NULL,
    referencia  VARCHAR(60) NOT NULL UNIQUE,
    fecha       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (id_venta) REFERENCES ventas(id_venta) ON DELETE CASCADE
);

-- Ajustes manuales de inventario con su motivo (sp_AjustarNivelStock)
CREATE TABLE ajustes_inventario (
    id_ajuste       INT AUTO_INCREMENT PRIMARY KEY,
    id_producto     INT NOT NULL,
    stock_anterior  INT NOT NULL,
    stock_nuevo     INT NOT NULL,
    motivo          VARCHAR(255) NOT NULL,
    usuario         VARCHAR(100) NOT NULL,
    fecha           DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (id_producto) REFERENCES productos(id_producto)
);

-- Bandeja de salida de notificaciones para otros sistemas (sp_CambiarEstadoPedido)
CREATE TABLE notificaciones (
    id_notificacion INT AUTO_INCREMENT PRIMARY KEY,
    sistema_destino VARCHAR(50) NOT NULL,
    tipo            VARCHAR(50) NOT NULL,
    payload         JSON NOT NULL,
    enviada         BOOLEAN NOT NULL DEFAULT FALSE,
    fecha           DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Índices de apoyo para reportes
CREATE INDEX idx_ventas_fecha   ON ventas(fecha_venta);
CREATE INDEX idx_ventas_estado  ON ventas(estado);
CREATE INDEX idx_detalle_prod   ON detalle_ventas(id_producto);

-- =====================================================================
-- DATOS DE EJEMPLO
-- =====================================================================

INSERT INTO sucursales (nombre, ciudad, usuario_db) VALUES
('Sucursal Centro',  'Cúcuta',       'support_user'),
('Sucursal Norte',   'Bucaramanga',  'marketing_user'),
('Sucursal Online',  'Bogotá',       'admin_user');

INSERT INTO categorias (nombre, descripcion) VALUES
('General',      'Categoría por defecto para productos sin clasificar'),
('Electrónica',  'Computadores, celulares, audio y accesorios'),
('Ropa',         'Prendas de vestir para hombre y mujer'),
('Hogar',        'Artículos para cocina, decoración y limpieza'),
('Deportes',     'Implementos deportivos y ropa deportiva'),
('Libros',       'Libros físicos de distintos géneros'),
('Juguetes',     'Juguetes y juegos de mesa'),
('Belleza',      'Cuidado personal y cosméticos');

INSERT INTO proveedores (nombre, email_contacto, telefono_contacto) VALUES
('TecnoAndina S.A.S.',     'ventas@tecnoandina.co',    '+57 607 5710001'),
('Textiles del Norte',     'pedidos@textilesnorte.co', '+57 607 5720002'),
('Casa & Estilo Ltda.',    'contacto@casaestilo.co',   '+57 601 7430003'),
('Deportes Extremos S.A.', 'info@deportesx.co',        '+57 604 4440004'),
('Editorial Horizonte',    'libros@horizonte.co',      '+57 601 3450005'),
('Distribuidora Mágica',   'ventas@magica.co',         '+57 602 5550006');

INSERT INTO productos (nombre, descripcion, precio, costo, stock, stock_minimo, sku, peso_kg, ubicacion, fecha_creacion, id_categoria, id_proveedor) VALUES
('Laptop Pro 14',            'Portátil 14" 16GB RAM 512GB SSD',     4200000, 3300000, 15, 5,  'ELE-LAP-0001', 1.600, 'A-01', '2025-01-10 09:00:00', 2, 1),
('Smartphone X12',           'Celular 6.5" 128GB',                  1850000, 1350000, 30, 10, 'ELE-SMA-0002', 0.200, 'A-02', '2025-01-10 09:05:00', 2, 1),
('Audífonos Bluetooth BT5',  'Audífonos inalámbricos con ANC',       320000,  180000, 60, 15, 'ELE-AUD-0003', 0.250, 'A-03', '2025-01-12 10:00:00', 2, 1),
('Monitor 27 4K',            'Monitor IPS 27 pulgadas 4K',          1450000, 1050000,  4, 5,  'ELE-MON-0004', 5.500, 'A-04', '2025-02-01 11:00:00', 2, 1),
('Teclado Mecánico RGB',     'Switches rojos, retroiluminado',       280000,  160000, 45, 10, 'ELE-TEC-0005', 0.900, 'A-05', '2025-02-01 11:10:00', 2, 1),
('Mouse Inalámbrico',        'Mouse ergonómico 2.4GHz',               85000,   40000, 80, 20, 'ELE-MOU-0006', 0.120, 'A-06', '2025-02-01 11:20:00', 2, 1),
('Camiseta Algodón Básica',  'Camiseta 100% algodón',                 45000,   18000,120, 30, 'ROP-CAM-0007', 0.200, 'B-01', '2025-01-15 08:00:00', 3, 2),
('Jean Clásico',             'Jean azul corte recto',                139000,   65000, 70, 20, 'ROP-JEA-0008', 0.700, 'B-02', '2025-01-15 08:10:00', 3, 2),
('Chaqueta Impermeable',     'Chaqueta para lluvia',                 259000,  130000,  3, 8,  'ROP-CHA-0009', 0.900, 'B-03', '2025-03-01 08:00:00', 3, 2),
('Vestido de Verano',        'Vestido fresco estampado',             119000,   52000, 25, 10, 'ROP-VES-0010', 0.350, 'B-04', '2025-03-05 08:00:00', 3, 2),
('Sartén Antiadherente 28',  'Sartén de aluminio con teflón',         98000,   45000, 40, 10, 'HOG-SAR-0011', 1.100, 'C-01', '2025-01-20 09:00:00', 4, 3),
('Juego de Sábanas Doble',   'Sábanas 200 hilos',                    149000,   70000, 35, 10, 'HOG-SAB-0012', 1.300, 'C-02', '2025-01-20 09:10:00', 4, 3),
('Cafetera Espresso',        'Cafetera de 15 bares',                 689000,  420000,  6, 5,  'HOG-CAF-0013', 4.200, 'C-03', '2025-02-10 09:00:00', 4, 3),
('Lámpara de Escritorio LED','Lámpara regulable',                     79000,   33000, 50, 10, 'HOG-LAM-0014', 0.800, 'C-04', '2025-02-10 09:10:00', 4, 3),
('Balón de Fútbol Pro',      'Balón talla 5 profesional',            129000,   60000, 55, 15, 'DEP-BAL-0015', 0.450, 'D-01', '2025-01-25 10:00:00', 5, 4),
('Tapete de Yoga',           'Tapete antideslizante 6mm',             89000,   38000, 40, 10, 'DEP-TAP-0016', 1.000, 'D-02', '2025-01-25 10:10:00', 5, 4),
('Mancuernas 10kg (par)',    'Par de mancuernas hexagonales',        210000,  120000,  2, 5,  'DEP-MAN-0017',20.000, 'D-03', '2025-02-15 10:00:00', 5, 4),
('Bicicleta Urbana',         'Bicicleta rin 26 7 velocidades',      1290000,  850000,  8, 3,  'DEP-BIC-0018',14.000, 'D-04', '2025-03-10 10:00:00', 5, 4),
('Novela: Cien Años',        'Novela clásica latinoamericana',        59000,   25000, 90, 20, 'LIB-NOV-0019', 0.500, 'E-01', '2025-01-05 12:00:00', 6, 5),
('Libro: SQL Avanzado',      'Guía práctica de bases de datos',       99000,   45000, 30, 10, 'LIB-SQL-0020', 0.700, 'E-02', '2025-01-05 12:10:00', 6, 5),
('Libro: Cocina Colombiana', 'Recetario tradicional',                 75000,   32000, 20, 5,  'LIB-COC-0021', 0.900, 'E-03', '2025-04-01 12:00:00', 6, 5),
('Rompecabezas 1000 piezas', 'Paisaje andino',                        65000,   28000, 35, 10, 'JUG-ROM-0022', 0.600, 'F-01', '2025-02-20 13:00:00', 7, 6),
('Juego de Mesa Estrategia', 'Juego para 2-6 jugadores',             149000,   75000, 22, 8,  'JUG-JUE-0023', 1.200, 'F-02', '2025-02-20 13:10:00', 7, 6),
('Crema Hidratante Facial',  'Crema con ácido hialurónico',           69000,   27000, 60, 15, 'BEL-CRE-0024', 0.150, 'G-01', '2025-03-15 14:00:00', 8, 6),
('Perfume Floral 100ml',     'Eau de parfum',                        259000,  120000, 12, 5,  'BEL-PER-0025', 0.400, 'G-02', '2025-03-15 14:10:00', 8, 6);

-- Contador inicial de productos por categoría
UPDATE categorias c
SET total_productos = (SELECT COUNT(*) FROM productos p WHERE p.id_categoria = c.id_categoria);

-- Contraseñas almacenadas como hash SHA-256 (nunca en texto plano)
INSERT INTO clientes (nombre, apellido, email, contrasena, direccion_envio, ciudad, region, fecha_nacimiento, fecha_registro, id_referido_por) VALUES
('Laura',    'Gómez',     'laura.gomez@mail.com',     'pbkdf2_sha256$600000$4ZBpv5Gf+BeFaNznDs2+sw==$ojAd9N/7jossjRsvg+4wXdDBYLCwZbuQv35g7jfQoL8=', 'Cra 5 # 10-20',       'Cúcuta',       'Norte de Santander', '1992-05-14', '2025-01-05 10:00:00', NULL),
('Andrés',   'Pérez',     'andres.perez@mail.com',    'pbkdf2_sha256$600000$mzwc88HJN70wHxh1hlYHxg==$R52R/84ZU/U3NlzPOhK/982w9ZkQDfGzQ5cmzS/Ltwo=', 'Cl 12 # 3-45',        'Bogotá',       'Cundinamarca',       '1988-09-23', '2025-01-18 15:30:00', 1),
('María',    'Rodríguez', 'maria.rod@mail.com',       'pbkdf2_sha256$600000$cUulLoOEeWLl4/YdE8GsCQ==$1RJjMF8ni3wbddtlrgLaDwJyGgOxDZDgIb6oIU/3Nuk=', 'Av 0 # 15-80',        'Cúcuta',       'Norte de Santander', '1995-11-02', '2025-02-02 09:15:00', 1),
('Carlos',   'Martínez',  'carlos.mtz@mail.com',      'pbkdf2_sha256$600000$Lnzuevj9sQBqC2GIsy2L+w==$lPANBL3YD8ZA0qzZ/l/hFJv0K8kgGJWPQasqpBvdrd4=', 'Cl 45 # 27-10',       'Bucaramanga',  'Santander',          '1985-03-30', '2025-02-20 18:45:00', NULL),
('Valentina','López',     'vale.lopez@mail.com',      'pbkdf2_sha256$600000$uT8bSLL3bnyEF5ft3Y2sbg==$H6SkKPjKAHVFeVYSBg3GgKwQZelMTpX4d6xP1aqm5gk=', 'Cra 70 # 44-12',      'Medellín',     'Antioquia',          '1999-07-19', '2025-03-11 11:20:00', 2),
('Santiago', 'Hernández', 'santi.hdz@mail.com',       'pbkdf2_sha256$600000$G9kCfG9VoTK4KLc0mlvP3w==$pQJEtIJZjsYwORz78JW5sWjhMoGJGCf9pYL2YxsyXoI=', 'Cl 5 # 38-25',        'Cali',         'Valle del Cauca',    '1990-12-08', '2025-04-03 14:00:00', NULL),
('Camila',   'Díaz',      'camila.diaz@mail.com',     'pbkdf2_sha256$600000$7jaAkmGMZr1I0hkByCnmNQ==$NILyxgxc1OJA1PBl7pGOrPJr00KLeWBKMARDqLVhG80=', 'Cra 27 # 36-14',      'Bucaramanga',  'Santander',          '1997-02-27', '2025-04-22 16:10:00', 4),
('Julián',   'Torres',    'julian.torres@mail.com',   'pbkdf2_sha256$600000$Ad1TjbrDEbi8HZtSHuS6dg==$sp+u2Fgs2IXo/2c58nFXsR81aKeT2h8n0doyo35Hv2g=', 'Cl 10 # 4-50',        'Cúcuta',       'Norte de Santander', '2000-06-11', '2025-05-09 08:30:00', 3),
('Daniela',  'Ramírez',   'dani.ramirez@mail.com',    'pbkdf2_sha256$600000$nnCZ7VybsFqVM8G86LNQXQ==$XRaEOIy3XDscqz6fCFyPXCoI1o6NidB73VknYJfklXI=', 'Cra 15 # 93-60',      'Bogotá',       'Cundinamarca',       '1993-10-05', '2025-06-14 19:00:00', NULL),
('Felipe',   'Castro',    'felipe.castro@mail.com',   'pbkdf2_sha256$600000$F948AIkzXfDgTXXAueKi5Q==$DXUHbq5RMNsoOY7NAeWKMZa9JiRotpRjJIJvqCuwWXI=', 'Cl 30 # 65-20',       'Medellín',     'Antioquia',          '1987-01-17', '2025-07-01 10:40:00', 5),
('Sofía',    'Vargas',    'sofia.vargas@mail.com',    'pbkdf2_sha256$600000$p44x14Nb74t01LAZCG8Bxw==$O5y3c1ZyHJoB0SBcKWSj0yyB65Y+JXD3lSoFp4uDkGY=', 'Av 6 # 25N-30',       'Cali',         'Valle del Cauca',    '1996-08-29', '2025-08-19 13:25:00', NULL),
('Mateo',    'Rojas',     'mateo.rojas@mail.com',     'pbkdf2_sha256$600000$ZpJ5bvnyyD7oxaz9KPbfsg==$cJbVqe0ixOFz4Rf6IndG4R5HQWRatppj43AboFXdPVY=', 'Cl 72 # 54-10',       'Barranquilla', 'Atlántico',          '1991-04-09', '2025-09-07 17:50:00', NULL),
('Isabella', 'Moreno',    'isa.moreno@mail.com',      'pbkdf2_sha256$600000$igfEsb8qyBrEpvCzUlj4KQ==$zUkXAbvkaJBR9neMBqWe3pazaDayvT2c8VS1bAslguQ=', 'Cra 43 # 80-15',      'Barranquilla', 'Atlántico',          '2001-09-24', '2025-10-12 12:00:00', 12),
('Sebastián','Jiménez',   'sebas.jimenez@mail.com',   'pbkdf2_sha256$600000$LorF62uNxBm19gn9qbAGRw==$xiCpJ5Azh4fpHfoupedkqTZBfrJ2dvTAOT51utw7IxU=', 'Cl 19 # 8-40',        'Cúcuta',       'Norte de Santander', '1994-12-31', '2025-11-28 09:45:00', 8),
('Paula',    'Suárez',    'paula.suarez@mail.com',    'pbkdf2_sha256$600000$rmKzeqTJsFRSZ3JQKahpAg==$TjIdSynWFni6khG0Hw5iNonQ9hN7q6SybR61aL4EhnQ=', 'Cra 33 # 48-22',      'Bucaramanga',  'Santander',          '1998-03-03', '2026-01-15 15:15:00', NULL),
('Diego',    'Ortiz',     'diego.ortiz@mail.com',     'pbkdf2_sha256$600000$9ifL2Fx8zshXnkmPYR61fA==$1Aq+uEDpT4a5QDht/PRgjOVOoLMkTcRustN6z92LgOw=', 'Cl 100 # 19-61',      'Bogotá',       'Cundinamarca',       '1986-07-07', '2026-02-10 10:05:00', 9),
('Natalia',  'Silva',     'nata.silva@mail.com',      'pbkdf2_sha256$600000$3vOlhG+/fy25vtZRIN10dA==$q11sQo1e3fReH+6dVLZhhLlpbUgqg3nHzbUxRtnKxf8=', 'Cra 80 # 33-18',      'Medellín',     'Antioquia',          '1993-05-21', '2026-03-22 20:30:00', NULL),
('Tomás',    'Mendoza',   'tomas.mendoza@mail.com',   'pbkdf2_sha256$600000$ZIE3Lr+R7aSRyqYQCJowtQ==$gMAIBWe+bjJt0nDA5m6f7H7Er06bn9FP3LD46twTd+U=', 'Cl 9 # 2-15',         'Cúcuta',       'Norte de Santander', '2002-11-13', '2026-05-30 11:00:00', 14),
('Gabriela', 'Reyes',     'gabi.reyes@mail.com',      'pbkdf2_sha256$600000$bPrPqM77HkDK00h4zJdhWA==$LhBRE6qxbchq0bHz1gQ7Ttd6Nk8R17XXm9vkBx7/SB8=', 'Cra 1 # 60-40',       'Cali',         'Valle del Cauca',    '1995-02-14', '2026-07-18 16:40:00', NULL),
('Nicolás',  'Guerrero',  'nico.guerrero@mail.com',   'pbkdf2_sha256$600000$9hEXuIVdk/0EB4fq++7ntA==$JLj2D3w6uDvdc+3s6rAMLKklREHL0A2Sahyuyz/4vtc=', 'Cl 53 # 46-30',       'Barranquilla', 'Atlántico',          '1989-09-01', '2026-09-01 09:00:00', NULL);

-- Ventas (encabezados). El total se calcula al final a partir de los detalles.
INSERT INTO ventas (id_cliente, id_sucursal, fecha_venta, estado) VALUES
(1, 1, '2025-01-20 10:15:00', 'Entregado'),   -- 1
(2, 3, '2025-02-03 19:40:00', 'Entregado'),   -- 2
(1, 1, '2025-02-25 12:05:00', 'Entregado'),   -- 3
(3, 1, '2025-03-08 20:30:00', 'Entregado'),   -- 4
(4, 2, '2025-03-19 09:50:00', 'Entregado'),   -- 5
(5, 3, '2025-04-02 14:22:00', 'Entregado'),   -- 6
(2, 3, '2025-04-15 21:10:00', 'Entregado'),   -- 7
(6, 3, '2025-05-06 11:35:00', 'Entregado'),   -- 8
(7, 2, '2025-05-21 18:00:00', 'Entregado'),   -- 9
(1, 1, '2025-06-10 19:55:00', 'Entregado'),   -- 10
(8, 1, '2025-06-28 13:45:00', 'Entregado'),   -- 11
(3, 1, '2025-07-12 20:20:00', 'Entregado'),   -- 12
(9, 3, '2025-07-30 10:10:00', 'Entregado'),   -- 13
(4, 2, '2025-08-14 16:30:00', 'Entregado'),   -- 14
(10,3, '2025-08-29 21:45:00', 'Entregado'),   -- 15
(5, 3, '2025-09-10 12:15:00', 'Entregado'),   -- 16
(11,3, '2025-09-25 19:05:00', 'Entregado'),   -- 17
(2, 3, '2025-10-08 20:40:00', 'Entregado'),   -- 18
(12,3, '2025-10-22 11:00:00', 'Entregado'),   -- 19
(1, 1, '2025-11-05 18:25:00', 'Entregado'),   -- 20
(13,3, '2025-11-20 20:50:00', 'Entregado'),   -- 21
(7, 2, '2025-12-03 15:15:00', 'Entregado'),   -- 22
(14,1, '2025-12-15 19:30:00', 'Entregado'),   -- 23
(3, 1, '2025-12-22 21:05:00', 'Entregado'),   -- 24
(6, 3, '2026-01-09 10:45:00', 'Entregado'),   -- 25
(15,2, '2026-01-28 20:10:00', 'Entregado'),   -- 26
(8, 1, '2026-02-14 19:20:00', 'Entregado'),   -- 27
(16,3, '2026-03-03 12:35:00', 'Entregado'),   -- 28
(2, 3, '2026-03-18 20:55:00', 'Entregado'),   -- 29
(9, 3, '2026-04-06 18:40:00', 'Entregado'),   -- 30
(17,3, '2026-04-25 21:15:00', 'Entregado'),   -- 31
(1, 1, '2026-05-12 19:45:00', 'Entregado'),   -- 32
(4, 2, '2026-06-02 14:05:00', 'Entregado'),   -- 33
(18,1, '2026-06-20 20:25:00', 'Entregado'),   -- 34
(5, 3, '2026-07-08 11:50:00', 'Enviado'),     -- 35
(19,3, '2026-07-26 19:35:00', 'Enviado'),     -- 36
(3, 1, '2026-08-11 20:15:00', 'Procesando'),  -- 37
(10,3, '2026-08-30 18:05:00', 'Procesando'),  -- 38
(7, 2, '2026-09-10 21:30:00', 'Pendiente de Pago'), -- 39
(20,3, '2026-09-15 10:20:00', 'Cancelado');   -- 40

INSERT INTO detalle_ventas (id_venta, id_producto, cantidad, precio_unitario_congelado) VALUES
(1, 1, 1, 4100000), (1, 6, 1, 85000),
(2, 2, 1, 1800000), (2, 3, 1, 320000),
(3, 7, 3, 45000),   (3, 8, 1, 139000),
(4, 11,1, 98000),   (4, 12,1, 149000), (4, 14,1, 79000),
(5, 15,2, 129000),  (5, 16,1, 89000),
(6, 19,1, 59000),   (6, 20,1, 99000),
(7, 5, 1, 280000),  (7, 6, 1, 85000),  (7, 3, 1, 320000),
(8, 13,1, 689000),
(9, 10,2, 119000),  (9, 24,1, 69000),
(10,4, 1, 1450000), (10,5, 1, 280000), (10,6, 1, 85000),
(11,22,1, 65000),   (11,23,1, 149000),
(12,25,1, 259000),  (12,24,2, 69000),
(13,1, 1, 4200000), (13,3, 1, 320000),
(14,18,1, 1290000), (14,15,1, 129000),
(15,2, 1, 1850000), (15,6, 1, 85000),
(16,7, 2, 45000),   (16,9, 1, 259000),
(17,20,2, 99000),   (17,19,1, 59000),
(18,1, 1, 4200000), (18,5, 1, 280000), (18,6, 1, 85000),
(19,15,1, 129000),  (19,16,2, 89000),
(20,13,1, 689000),  (20,11,1, 98000),
(21,24,1, 69000),   (21,25,1, 259000),
(22,8, 2, 139000),  (22,7, 2, 45000),
(23,23,1, 149000),  (23,22,1, 65000),
(24,3, 1, 320000),  (24,6, 1, 85000),
(25,17,1, 210000),  (25,16,1, 89000),
(26,12,1, 149000),  (26,14,2, 79000),
(27,2, 1, 1850000), (27,3, 1, 320000),
(28,20,1, 99000),   (28,21,1, 75000),
(29,4, 1, 1450000), (29,5, 1, 280000),
(30,10,1, 119000),  (30,7, 2, 45000),
(31,15,1, 129000),  (31,17,1, 210000),
(32,1, 1, 4200000), (32,6, 1, 85000),
(33,18,1, 1290000),
(34,19,2, 59000),   (34,22,1, 65000),
(35,11,1, 98000),   (35,13,1, 689000),
(36,24,2, 69000),   (36,25,1, 259000),
(37,3, 2, 320000),  (37,6, 1, 85000),
(38,5, 1, 280000),  (38,6, 1, 85000),
(39,8, 1, 139000),
(40,2, 1, 1850000);

-- El inventario de partida debe reflejar las ventas históricas válidas.
UPDATE productos p
JOIN (
    SELECT d.id_producto, SUM(d.cantidad) AS unidades_vendidas
    FROM detalle_ventas d
    JOIN ventas v ON v.id_venta = d.id_venta
    WHERE v.estado NOT IN ('Cancelado','Devuelto Totalmente')
    GROUP BY d.id_producto
) vendidas ON vendidas.id_producto = p.id_producto
SET p.stock = p.stock - vendidas.unidades_vendidas;

-- Total de cada venta = suma de subtotales (cantidad * precio congelado)
UPDATE ventas v
SET total = (SELECT COALESCE(SUM(d.cantidad * d.precio_unitario_congelado),0)
             FROM detalle_ventas d WHERE d.id_venta = v.id_venta);

-- La dirección del pedido se toma de la dirección del cliente
UPDATE ventas v JOIN clientes c ON c.id_cliente = v.id_cliente SET v.direccion_envio = c.direccion_envio;

-- Totales acumulados por cliente (sólo ventas no canceladas)
UPDATE clientes c
SET total_gastado = (SELECT COALESCE(SUM(v.total),0) FROM ventas v
                     WHERE v.id_cliente = c.id_cliente AND v.estado NOT IN ('Cancelado','Devuelto Totalmente')),
    fecha_ultimo_pedido = (SELECT MAX(v.fecha_venta) FROM ventas v WHERE v.id_cliente = c.id_cliente);

INSERT INTO visitas_producto (id_producto, id_cliente, fecha_visita) VALUES
(1,1,'2026-08-01 10:00:00'),(1,2,'2026-08-01 11:00:00'),(1,3,'2026-08-02 12:00:00'),(1,4,'2026-08-03 13:00:00'),
(1,5,'2026-08-04 14:00:00'),(1,6,'2026-08-05 15:00:00'),(2,1,'2026-08-01 10:30:00'),(2,7,'2026-08-02 10:30:00'),
(2,8,'2026-08-03 10:30:00'),(4,9,'2026-08-04 10:30:00'),(4,10,'2026-08-05 10:30:00'),(4,11,'2026-08-06 10:30:00'),
(4,12,'2026-08-07 10:30:00'),(4,13,'2026-08-08 10:30:00'),(4,14,'2026-08-09 10:30:00'),(4,15,'2026-08-10 10:30:00'),
(18,1,'2026-08-11 09:00:00'),(18,2,'2026-08-12 09:00:00'),(18,3,'2026-08-13 09:00:00'),(18,4,'2026-08-14 09:00:00'),
(18,5,'2026-08-15 09:00:00'),(6,1,'2026-08-16 09:00:00'),(6,2,'2026-08-17 09:00:00'),(25,3,'2026-08-18 09:00:00'),
(25,4,'2026-08-19 09:00:00'),(25,5,'2026-08-20 09:00:00'),(9,6,'2026-08-21 09:00:00'),(13,7,'2026-08-22 09:00:00'),
(13,8,'2026-08-23 09:00:00'),(3,9,'2026-08-24 09:00:00');

INSERT INTO carritos (id_cliente, id_producto, cantidad, fecha_agregado) VALUES
(11, 4, 1, '2026-09-01 20:00:00'),
(12, 18,1, '2026-09-05 21:00:00'),
(15, 9, 1, '2026-09-12 19:00:00'),
(20, 1, 1, '2026-09-20 18:00:00'),
(6,  25,1, '2026-09-22 12:00:00');

INSERT INTO promociones (codigo, id_producto, porcentaje, fecha_inicio, fecha_fin, activa) VALUES
('BLACKFRIDAY25', 1, 10.00, '2025-11-01 00:00:00', '2025-11-30 23:59:59', TRUE),
('VERANO26',      7, 15.00, '2026-06-01 00:00:00', '2026-06-30 23:59:59', TRUE),
('DEPORTE26',    15, 20.00, '2026-09-01 00:00:00', '2026-12-31 23:59:59', TRUE);
