CREATE TABLE vehicles (
    vehicle_id             SERIAL      PRIMARY KEY,
    registration           VARCHAR(15) NOT NULL UNIQUE,
    current_odometer       INT         NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer  INT         NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT ck_service_not_ahead CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INT    NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE   NOT NULL,
    start_odometer INT    NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INT    NOT NULL CHECK (end_odometer >= 0),
    CONSTRAINT ck_trip_distance CHECK (end_odometer > start_odometer)
);

CREATE TABLE service_alerts (
    vehicle_id       INT  PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service INT  NOT NULL,
    flagged_on       DATE NOT NULL DEFAULT CURRENT_DATE
);


INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('ABC 1001', 12000, 10000),   -- 2,000 km since service
    ('ABD 2002', 30000, 24000),   -- 6,000 km since service (already due)
    ('ABE 3003',  7000,  3000);   -- 4,000 km since service (crosses 5,000 exactly via trips)


CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_current INT;
    v_last    INT;
BEGIN
    SELECT current_odometer, last_service_odometer
      INTO v_current, v_last
      FROM vehicles
     WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    RETURN (v_current - v_last) >= 5000;
END;
$$;


CREATE OR REPLACE FUNCTION trg_trips_odometer()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_current INT;
BEGIN
    
    SELECT current_odometer INTO v_current
      FROM vehicles
     WHERE vehicle_id = NEW.vehicle_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;
    IF NEW.start_odometer IS NULL OR NEW.end_odometer IS NULL THEN
        RAISE EXCEPTION 'Odometer readings must not be NULL';
    END IF;
    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: end (%) must be greater than start (%)',
                        NEW.end_odometer, NEW.start_odometer;
    END IF;
    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Start odometer % does not match vehicle''s current odometer %',
                        NEW.start_odometer, v_current;
    END IF;

    UPDATE vehicles
       SET current_odometer = NEW.end_odometer
     WHERE vehicle_id = NEW.vehicle_id;       

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trips_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_trips_odometer();


CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INT,
    p_trip_on    DATE,
    p_start      INT,
    p_end        INT)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_vehicle_id IS NULL OR p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'No argument may be NULL';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;
    IF p_end <= p_start THEN
        RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;


CALL pr_record_trip(1, CURRENT_DATE - 10, 12000, 12400);
CALL pr_record_trip(1, CURRENT_DATE -  8, 12400, 13000);   -- V1: 3,000 km since service
CALL pr_record_trip(2, CURRENT_DATE -  9, 30000, 30600);
CALL pr_record_trip(2, CURRENT_DATE -  6, 30600, 31100);   -- V2: 7,100 km since service
CALL pr_record_trip(3, CURRENT_DATE -  7,  7000,  7600);
CALL pr_record_trip(3, CURRENT_DATE -  5,  7600,  8000);   -- V3: exactly 5,000 km -> due


CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;


CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);

ANALYZE trips;
SET enable_seqscan = off;
EXPLAIN
SELECT trip_id, trip_on, start_odometer, end_odometer
FROM trips
WHERE vehicle_id = 2
  AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;


CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN
    
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id,
           current_odometer - last_service_odometer,
           CURRENT_DATE
    FROM vehicles
    WHERE current_odometer - last_service_odometer >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
        SET km_since_service = EXCLUDED.km_since_service;   

     WHERE NOT EXISTS (
        SELECT 1 FROM vehicles v
        WHERE v.vehicle_id = sa.vehicle_id
          AND v.current_odometer - v.last_service_odometer >= 5000);
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;


SELECT cron.schedule('fleet_refresh_service_alerts', '0 6 * * 1',
                     $$CALL pr_refresh_service_alerts()$$);

SELECT jobid, jobname, schedule, command, active FROM cron.job;
SELECT jobid, status, return_message, start_time, end_time
FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;


SELECT vehicle_id, registration, current_odometer, last_service_odometer,
       fn_service_due(vehicle_id) AS service_due
FROM vehicles ORDER BY vehicle_id;       

DO $$ BEGIN PERFORM fn_service_due(999);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 13000, 12900);   -- end <= start
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(999, CURRENT_DATE, 0, 10);       -- unknown vehicle
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 12000, 12100);  -- wrong start odometer
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;

SELECT * FROM vehicles ORDER BY vehicle_id;   
SELECT * FROM trips ORDER BY trip_id;
SELECT * FROM v_service_due;

CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;      


UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 2;
CALL pr_refresh_service_alerts(); 
CALL pr_refresh_service_alerts();                      
SELECT * FROM service_alerts ORDER BY vehicle_id;       