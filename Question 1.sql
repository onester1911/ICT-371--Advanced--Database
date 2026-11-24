CREATE TABLE medicines (
    medicine_id SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100) NOT NULL,
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty INTEGER NOT NULL CHECK (stock_qty >= 0)
);
CREATE TABLE sales (
    sale_id SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on TIMESTAMP NOT NULL
);
CREATE TABLE stock_audit (
    audit_id SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    old_qty INTEGER NOT NULL,
    new_qty INTEGER NOT NULL,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE daily_sales (
    sales_date DATE PRIMARY KEY,
    total_qty INTEGER NOT NULL DEFAULT 0,
    total_amount NUMERIC(12,2) NOT NULL DEFAULT 0
);
INSERT INTO medicines (
    medicine_name,
    unit_price,
    stock_qty
)
VALUES
('Paracetamol', 15.00, 50),
('Amoxicillin', 35.00, 40),
('Ibuprofen', 20.00, 30);
CALL pr_record_sale(1, 2, CURRENT_TIMESTAMP - INTERVAL '5 days');

CALL pr_record_sale(2, 3, CURRENT_TIMESTAMP - INTERVAL '5 days');

CALL pr_record_sale(3, 4, CURRENT_TIMESTAMP - INTERVAL '4 days');

CALL pr_record_sale(1, 5, CURRENT_TIMESTAMP - INTERVAL '3 days');

CALL pr_record_sale(2, 2, CURRENT_TIMESTAMP - INTERVAL '2 days');

CALL pr_record_sale(3, 3, CURRENT_TIMESTAMP - INTERVAL '1 day');

CREATE OR REPLACE FUNCTION fn_sale_value(
    p_medicine_id INTEGER,
    p_quantity INTEGER
)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION
        'Quantity must be greater than zero';
    END IF;

    SELECT unit_price
    INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
        'Medicine ID % does not exist', p_medicine_id;
    END IF;

    RETURN v_price * p_quantity;
END;
$$;
SELECT fn_sale_value(1, 3);
SELECT fn_sale_value(1, 0);

CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INTEGER,
    p_quantity INTEGER,
    p_sold_on TIMESTAMP
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
    v_stock INTEGER;
BEGIN

    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION
        'Quantity must be greater than zero';
    END IF;

    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION
        'Sale date cannot be NULL';
    END IF;

    SELECT unit_price, stock_qty
    INTO v_price, v_stock
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
        'Medicine ID % does not exist', p_medicine_id;
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION
        'Insufficient stock. Available: %, Requested: %',
        v_stock, p_quantity;
    END IF;

    INSERT INTO sales (
        medicine_id,
        quantity,
        unit_price,
        sold_on
    )
    VALUES (
        p_medicine_id,
        p_quantity,
        v_price,
        p_sold_on
    );

    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;

END;
$$;
CALL pr_record_sale(1, 2, CURRENT_TIMESTAMP);
SELECT * FROM medicines;
SELECT * FROM sales;

CREATE OR REPLACE FUNCTION fn_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN

    IF OLD.stock_qty IS DISTINCT FROM NEW.stock_qty THEN

        INSERT INTO stock_audit (
            medicine_id,
            old_qty,
            new_qty,
            changed_at
        )
        VALUES (
            NEW.medicine_id,
            OLD.stock_qty,
            NEW.stock_qty,
            CURRENT_TIMESTAMP
        );

    END IF;

    RETURN NEW;

END;
$$;
CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
EXECUTE FUNCTION fn_stock_audit();
UPDATE medicines
SET stock_qty = stock_qty - 1
WHERE medicine_id = 1;
SELECT * FROM stock_audit;

CREATE OR REPLACE VIEW v_low_stock AS
SELECT
    medicine_name,
    unit_price,
    stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;
SELECT * FROM v_low_stock;
CALL pr_record_sale(2, 3, CURRENT_TIMESTAMP);
SELECT * FROM v_low_stock;

CREATE INDEX idx_sales_medicine_date
ON sales (medicine_id, sold_on);
SELECT *
FROM sales
WHERE medicine_id = 1
AND sold_on BETWEEN
    '2026-11-01 00:00:00'
    AND '2026-11-30 23:59:59';
	EXPLAIN
SELECT *
FROM sales
WHERE medicine_id = 1
AND sold_on BETWEEN
    '2026-11-01 00:00:00'
    AND '2026-11-30 23:59:59';

CREATE OR REPLACE PROCEDURE pr_refresh_sales(
    p_day DATE
)
LANGUAGE plpgsql
AS $$
BEGIN

    IF p_day IS NULL THEN
        RAISE EXCEPTION
        'Sales date cannot be NULL';
    END IF;

    INSERT INTO daily_sales (
        sales_date,
        total_qty,
        total_amount
    )
    SELECT
        p_day,
        COALESCE(SUM(quantity), 0)::INTEGER,
        COALESCE(SUM(quantity * unit_price), 0)::NUMERIC(12,2)
    FROM sales
    WHERE sold_on >= p_day
      AND sold_on < p_day + 1

    ON CONFLICT (sales_date)
    DO UPDATE SET
        total_qty = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;

END;
$$;	
CALL pr_refresh_sales(CURRENT_DATE);
SELECT * FROM daily_sales;
CALL pr_refresh_sales(CURRENT_DATE);
SELECT * FROM daily_sales;
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'daily-pharmacy-sales-refresh',
    '15 0 * * *',
    'CALL pr_refresh_sales(CURRENT_DATE - 1);'
);
SELECT *
FROM cron.job;