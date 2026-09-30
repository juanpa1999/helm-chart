-- Seed de datos de prueba para el backend (PostgreSQL).
-- Requiere que el esquema ya exista (alembic upgrade head -> migrations/versions/9870790feabf_gen_db.py).
-- Idempotente: se puede correr varias veces sin duplicar usuario ni sensores.
--
-- Uso (Kubernetes, desde la raíz del repo; lo corre up.sh):
--   kubectl exec -i deploy/db-deployment -- psql -U postgres -d postgres -v ON_ERROR_STOP=1 < sql/seed_pablodevops.sql

BEGIN;

-- 1) Usuario pablodevops
-- La app valida con passlib/bcrypt (managers/auth.py), así que se guarda el hash bcrypt,
-- no la contraseña en texto plano.
INSERT INTO users (username, password, status, user_role, creation_date)
VALUES (
    'pablodevops',
    '$2b$12$I43SRqmyOtN0j2ENWFUcYu.oLKmNckSXzF2HlcrA9D1YdO29PEgRm',
    'active',
    'master',
    CURRENT_DATE
)
ON CONFLICT (username) DO UPDATE
    SET password  = EXCLUDED.password,
        status    = EXCLUDED.status,
        user_role = EXCLUDED.user_role;

-- 2) Sensores
-- Las lecturas referencian sensors.sensor_number (no sensors.id), y los managers
-- solo aceptan lecturas de sensores con status = 'active'.
INSERT INTO sensors (sensor_number, sensor_location, status, creation_date)
VALUES
    (101, 'Bodega A - Temperatura', 'active',   CURRENT_DATE),
    (102, 'Bodega A - Humedad',     'active',   CURRENT_DATE),
    (103, 'Bodega A - Bascula',     'active',   CURRENT_DATE),
    (201, 'Bodega B - Multisensor', 'active',   CURRENT_DATE),
    (301, 'Laboratorio - Reserva',  'inactive', CURRENT_DATE)
ON CONFLICT (sensor_number) DO NOTHING;

-- 3) Lecturas: una cada hora durante las últimas 24 h, en hora de Bogotá
-- (igual que los managers, que usan America/Bogota).
-- Se eliminan antes las lecturas de estos sensores para que el seed sea repetible.
DELETE FROM temperature_sensors WHERE sensor_id IN (101, 201);
DELETE FROM humidity_sensors    WHERE sensor_id IN (102, 201);
DELETE FROM weight_sensors      WHERE sensor_id IN (103, 201);

INSERT INTO temperature_sensors (temperature, creation_date, sensor_id)
SELECT (18 + floor(random() * 10))::int,
       (now() AT TIME ZONE 'America/Bogota' - make_interval(hours => h)) AT TIME ZONE 'America/Bogota',
       s
FROM generate_series(0, 23) AS h
CROSS JOIN (VALUES (101), (201)) AS t(s);

INSERT INTO humidity_sensors (humidity, creation_date, sensor_id)
SELECT (40 + floor(random() * 40))::int,
       (now() AT TIME ZONE 'America/Bogota' - make_interval(hours => h)) AT TIME ZONE 'America/Bogota',
       s
FROM generate_series(0, 23) AS h
CROSS JOIN (VALUES (102), (201)) AS t(s);

INSERT INTO weight_sensors (weight, creation_date, sensor_id)
SELECT (500 + floor(random() * 500))::int,
       (now() AT TIME ZONE 'America/Bogota' - make_interval(hours => h)) AT TIME ZONE 'America/Bogota',
       s
FROM generate_series(0, 23) AS h
CROSS JOIN (VALUES (103), (201)) AS t(s);

COMMIT;

-- Verificación rápida
SELECT id, username, status, user_role, creation_date FROM users WHERE username = 'pablodevops';
SELECT sensor_number, sensor_location, status FROM sensors ORDER BY sensor_number;
SELECT 'temperature' AS tipo, count(*) FROM temperature_sensors
UNION ALL SELECT 'humidity', count(*) FROM humidity_sensors
UNION ALL SELECT 'weight',   count(*) FROM weight_sensors;
