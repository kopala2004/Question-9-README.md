-- ============================================================
-- QUESTION 9 - FARMER COOPERATIVE MAIZE DELIVERIES
-- POSTGRESQL / pgAdmin 4 VERSION
-- ============================================================

-- (a) TABLES
DROP TABLE IF EXISTS daily_purchases CASCADE;
DROP TABLE IF EXISTS deliveries CASCADE;
DROP TABLE IF EXISTS farmers CASCADE;

CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id   SERIAL PRIMARY KEY,
    farmer_id     INT NOT NULL REFERENCES farmers(farmer_id),
    grade         VARCHAR(5) NOT NULL CHECK (UPPER(grade) IN ('A','B','C')),
    weight_kg     NUMERIC(10, 2) NOT NULL CHECK (weight_kg > 0),
    unit_rate     NUMERIC(10, 2) NOT NULL DEFAULT 0,
    total_value   NUMERIC(12, 2) NOT NULL DEFAULT 0,
    delivered_on  DATE NOT NULL,
    is_paid       BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(12, 2) NOT NULL DEFAULT 0,
    total_value   NUMERIC(12, 2) NOT NULL DEFAULT 0
);

INSERT INTO farmers (farmer_number, full_name) VALUES
    ('F001', 'Chanda Mwila'),
    ('F002', 'Grace Banda'),
    ('F003', 'Kelvin Phiri');

-- (b) FUNCTION
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade VARCHAR)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_grade IS NULL OR UPPER(p_grade) NOT IN ('A','B','C') THEN
        RAISE EXCEPTION 'Unsupported grade';
    END IF;
    RETURN CASE UPPER(p_grade)
        WHEN 'A' THEN 5.00
        WHEN 'B' THEN 4.00
        ELSE 3.00
    END;
END;
$$;

-- (c) PROCEDURE
CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INT,
    p_grade     VARCHAR,
    p_weight    NUMERIC,
    p_date      DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rate NUMERIC;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Unknown farmer';
    END IF;
    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Invalid weight';
    END IF;
    v_rate := fn_maize_rate(p_grade);
    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, UPPER(p_grade), p_weight, p_date, FALSE);
END;
$$;

-- (d) TRIGGER FUNCTION + TRIGGERS
CREATE OR REPLACE FUNCTION trg_deliveries_pricing()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Invalid weight';
    END IF;
    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := NEW.weight_kg * NEW.unit_rate;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_deliveries_before_insert ON deliveries;
CREATE TRIGGER trg_deliveries_before_insert
BEFORE INSERT ON deliveries
FOR EACH ROW EXECUTE FUNCTION trg_deliveries_pricing();

DROP TRIGGER IF EXISTS trg_deliveries_before_update ON deliveries;
CREATE TRIGGER trg_deliveries_before_update
BEFORE UPDATE ON deliveries
FOR EACH ROW EXECUTE FUNCTION trg_deliveries_pricing();

-- (a) SEED - AFTER trigger
CALL pr_receive_delivery(1, 'A', 100, '2026-11-24');
CALL pr_receive_delivery(1, 'B',  50, '2026-11-24');
CALL pr_receive_delivery(2, 'C',  80, '2026-11-24');
CALL pr_receive_delivery(2, 'A',  60, '2026-11-25');
CALL pr_receive_delivery(3, 'B',  70, '2026-11-25');
CALL pr_receive_delivery(3, 'C',  40, '2026-11-25');

UPDATE deliveries SET is_paid = TRUE WHERE delivery_id IN (1, 3, 5);

-- (e) VIEW
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT
    f.farmer_number,
    f.full_name,
    COALESCE(SUM(CASE WHEN d.is_paid = FALSE THEN d.total_value ELSE 0 END), 0) AS total_unpaid
FROM farmers AS f
LEFT JOIN deliveries AS d ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

SELECT * FROM v_farmer_amount_due;

-- (f) INDEX
CREATE INDEX IF NOT EXISTS idx_deliveries_farmer_date
    ON deliveries (farmer_id, delivered_on);

EXPLAIN
SELECT * FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN '2026-11-24' AND '2026-11-25';

-- (g) SCHEDULED JOB PROCEDURE
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_w NUMERIC;
    v_v NUMERIC;
BEGIN
    SELECT COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
    INTO v_w, v_v
    FROM deliveries
    WHERE delivered_on = p_day;

    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    VALUES (p_day, v_w, v_v)
    ON CONFLICT (purchase_date)
    DO UPDATE SET total_weight = EXCLUDED.total_weight,
                  total_value  = EXCLUDED.total_value;
END;
$$;

-- Test it
CALL pr_refresh_purchases('2026-11-24');
SELECT * FROM daily_purchases;

