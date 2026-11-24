CREATE TABLE students (
    student_id     SERIAL       PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id     SERIAL        PRIMARY KEY,
    student_id         INT           NOT NULL REFERENCES students(student_id),
    age_at_application INT           NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5,2)  NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on       DATE          NOT NULL DEFAULT CURRENT_DATE,
    status             VARCHAR(10)   NOT NULL DEFAULT 'PENDING',
    CONSTRAINT ck_application_status CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL      PRIMARY KEY,
    application_id INT         NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(10) NOT NULL,
    new_status     VARCHAR(10) NOT NULL,
    changed_at     TIMESTAMP   NOT NULL DEFAULT now()
);

INSERT INTO students (student_number, full_name) VALUES
    ('SC001', 'Namukolo Chisenga'),
    ('SC002', 'Bornwell Mutale'),
    ('SC003', 'Taonga Ngoma');


CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age    INT,
    p_income NUMERIC,
    p_mark   NUMERIC)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark must not be NULL';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive (got %)', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income must not be negative (got %)', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100 (got %)', p_mark;
    END IF;

    RETURN p_age BETWEEN 18 AND 25
       AND p_income <= 3000
       AND p_mark >= 70;
END;
$$;


CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_status VARCHAR(10);
    v_age    INT;
    v_income NUMERIC;
    v_mark   NUMERIC;
BEGIN
    SELECT status, age_at_application, monthly_income, average_mark
      INTO v_status, v_age, v_income, v_mark
      FROM applications
     WHERE application_id = p_application_id
       FOR UPDATE;                     -- stops two sessions assessing the same row

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application_id: %', p_application_id;
    END IF;
    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % was already assessed (status: %)',
                        p_application_id, v_status;
    END IF;

    UPDATE applications
       SET status = CASE WHEN fn_scholarship_eligible(v_age, v_income, v_mark)
                         THEN 'APPROVED' ELSE 'REJECTED' END
     WHERE application_id = p_application_id;
END;
$$;


CREATE OR REPLACE FUNCTION trg_applications_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
    VALUES (OLD.application_id, OLD.status, NEW.status, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_applications_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_applications_audit();


INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
    (1, 20, 2000.00, 80.00, CURRENT_DATE - 12, 'PENDING'),  -- 1 qualifies
    (1, 18, 3000.00, 70.00, CURRENT_DATE - 10, 'PENDING'),  -- 2 lower boundary: age 18, income 3000, mark 70 -> qualifies
    (2, 25, 2999.99, 70.00, CURRENT_DATE -  8, 'PENDING'),  -- 3 upper age boundary 25 -> qualifies
    (2, 17, 1000.00, 90.00, CURRENT_DATE -  6, 'PENDING'),  -- 4 too young -> rejected
    (3, 22, 3000.01, 85.00, CURRENT_DATE -  4, 'PENDING'),  -- 5 income just above limit -> rejected
    (3, 21, 1500.00, 69.99, CURRENT_DATE -  2, 'PENDING');  -- 6 mark just below limit -> rejected


CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number,
       s.full_name,
       a.average_mark,
       a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';


CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);

ANALYZE applications;
SET enable_seqscan = off;
EXPLAIN
SELECT application_id, student_id, submitted_on
FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;


CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'
        ORDER BY application_id
    LOOP
        CALL pr_assess_application(r.application_id);
    END LOOP;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;


SELECT cron.schedule('scholarship_assess_pending', '0 8 * * 1',
                     $$CALL pr_assess_pending()$$);

SELECT jobid, jobname, schedule, command, active FROM cron.job;
SELECT jobid, status, return_message, start_time, end_time
FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;


SELECT fn_scholarship_eligible(18, 3000, 70)  AS lower_boundary,    
       fn_scholarship_eligible(25, 3000, 70)  AS upper_age,         
       fn_scholarship_eligible(26, 1000, 90)  AS too_old,           
       fn_scholarship_eligible(20, 3000.01, 90) AS income_over,     
       fn_scholarship_eligible(20, 1000, 69.99) AS mark_below;      

DO $$ BEGIN PERFORM fn_scholarship_eligible(NULL, 1000, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, -1, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(0, 1000, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, 1000, 101);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;


CALL pr_assess_application(1);
DO $$ BEGIN CALL pr_assess_application(1);       
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_assess_application(999);     
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;

CALL pr_assess_pending();
CALL pr_assess_pending();      


UPDATE applications SET submitted_on = submitted_on WHERE application_id = 2;

SELECT application_id, age_at_application, monthly_income, average_mark, status
FROM applications ORDER BY application_id;       
SELECT * FROM decision_audit ORDER BY audit_id;  
SELECT * FROM v_approved_applicants ORDER BY student_number;