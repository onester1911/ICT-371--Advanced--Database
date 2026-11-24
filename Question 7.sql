CREATE TABLE customers (
    customer_id SERIAL       PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id       SERIAL        PRIMARY KEY,
    customer_id      INT           NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE          NOT NULL,
    previous_reading NUMERIC(12,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(12,2) NOT NULL CHECK (current_reading >= 0),
    CONSTRAINT uq_reading_customer_month UNIQUE (customer_id, reading_month),
    CONSTRAINT ck_reading_month_start CHECK (EXTRACT(DAY FROM reading_month) = 1)
);

CREATE TABLE bills (
    bill_id     SERIAL        PRIMARY KEY,
    reading_id  INT           NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on      DATE          NOT NULL,
    CONSTRAINT ck_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE          PRIMARY KEY,
    total_due     NUMERIC(14,2) NOT NULL DEFAULT 0
);

INSERT INTO customers (full_name) VALUES
    ('Chipo Mwanza'), ('Lweendo Hamoonga'), ('Mulenga Katongo');


CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_units IS NULL THEN
        RAISE EXCEPTION 'Consumption must not be NULL';
    END IF;
    IF p_units < 0 THEN
        RAISE EXCEPTION 'Consumption must not be negative: %', p_units;
    END IF;

    RETURN ROUND( LEAST(p_units, 10) * 5.00
                + GREATEST(p_units - 10, 0) * 8.00, 2);
END;
$$;


CREATE OR REPLACE FUNCTION trg_readings_check()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'Current reading (%) is below previous reading (%)',
                        NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_readings_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_readings_check();


CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_prev   NUMERIC(12,2);
    v_curr   NUMERIC(12,2);
    v_charge NUMERIC(12,2);
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date must not be NULL';
    END IF;

    SELECT previous_reading, current_reading
      INTO v_prev, v_curr
      FROM readings
     WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id: %', p_reading_id;
    END IF;
    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;

    v_charge := fn_water_charge(v_curr - v_prev);

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0, p_due_on);
END;
$$;


INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, date_trunc('month', CURRENT_DATE - INTERVAL '2 months')::date, 100.0, 100.0),  -- 0 units
    (2, date_trunc('month', CURRENT_DATE - INTERVAL '2 months')::date,  50.0,  60.0),  -- exactly 10
    (3, date_trunc('month', CURRENT_DATE - INTERVAL '2 months')::date,  20.0,  35.0),  -- 15
    (1, date_trunc('month', CURRENT_DATE - INTERVAL '1 month')::date,  100.0, 125.0),  -- 25
    (2, date_trunc('month', CURRENT_DATE - INTERVAL '1 month')::date,   60.0,  67.5),  -- 7.5
    (3, date_trunc('month', CURRENT_DATE - INTERVAL '1 month')::date,   35.0,  47.0);  -- 12


CALL pr_generate_bill(1, CURRENT_DATE - 20);
CALL pr_generate_bill(2, CURRENT_DATE - 20);
CALL pr_generate_bill(3, CURRENT_DATE - 20);
CALL pr_generate_bill(4, CURRENT_DATE + 10);
CALL pr_generate_bill(5, CURRENT_DATE -  3);
CALL pr_generate_bill(6, CURRENT_DATE + 10);


UPDATE bills SET amount_paid = charge WHERE reading_id = 2;
UPDATE bills SET amount_paid = 30.00  WHERE reading_id = 3;


CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name AS customer_name,
       b.due_on,
       b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r  ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;


CREATE INDEX idx_bills_unpaid_due_on ON bills (due_on) WHERE amount_paid < charge;

ANALYZE bills;
SET enable_seqscan = off;
EXPLAIN
SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM bills
WHERE amount_paid < charge
  AND due_on < CURRENT_DATE;
RESET enable_seqscan;


CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
    FROM bills
    WHERE amount_paid < charge
    ON CONFLICT (snapshot_date) DO UPDATE
        SET total_due = EXCLUDED.total_due;      -- replace on rerun
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;


SELECT cron.schedule('water_refresh_receivables', '30 0 * * *',
                     $$CALL pr_refresh_receivables()$$);

SELECT jobid, jobname, schedule, command, active FROM cron.job;
SELECT jobid, status, return_message, start_time, end_time
FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;


SELECT u AS units, fn_water_charge(u) AS charge
FROM (VALUES (0::numeric), (5), (10), (10.5), (15), (25)) AS t(u);


DO $$ BEGIN PERFORM fn_water_charge(NULL);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_water_charge(-1);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_generate_bill(999, CURRENT_DATE);        -- unknown reading
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_generate_bill(1, CURRENT_DATE);          -- already billed
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;


DO $$ BEGIN INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
            VALUES (1, date_trunc('month', CURRENT_DATE)::date, 200, 150);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
SELECT COUNT(*) AS readings_for_current_month FROM readings
WHERE reading_month = date_trunc('month', CURRENT_DATE)::date;         

SELECT * FROM readings ORDER BY reading_id;
SELECT * FROM bills ORDER BY bill_id;
SELECT * FROM v_overdue_bills;

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();      
SELECT * FROM receivable_snapshot;