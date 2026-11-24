/*=========================================================
ICT371 ADVANCED DATABASE
QUESTION 3: LIBRARY RETURNS AND OVERDUE FINES
=========================================================*/

CREATE SCHEMA IF NOT EXISTS q3_library;

SET search_path TO q3_library, public;

--=========================================================
-- TABLES
--=========================================================

CREATE TABLE books
(
    book_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title VARCHAR(100) NOT NULL
);

CREATE TABLE loans
(
    loan_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    book_id INTEGER NOT NULL
    REFERENCES books(book_id),

    borrower_name VARCHAR(100) NOT NULL,

    borrowed_on DATE NOT NULL,

    due_on DATE NOT NULL,

    returned_on DATE,

    fine_amount NUMERIC(10,2) DEFAULT 0,

    CHECK (due_on >= borrowed_on)
);

CREATE TABLE loan_audit
(
    audit_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    loan_id INTEGER NOT NULL
    REFERENCES loans(loan_id),

    old_returned_on DATE,

    new_returned_on DATE,

    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE overdue_summary
(
    snapshot_date DATE PRIMARY KEY,

    overdue_count INTEGER NOT NULL,

    total_fine NUMERIC(12,2) NOT NULL
);

--=========================================================
-- SEED DATA
--=========================================================

INSERT INTO books(title)
VALUES
('Database Systems'),
('Java Programming'),
('Computer Networks');

INSERT INTO loans
(
book_id,
borrower_name,
borrowed_on,
due_on,
returned_on,
fine_amount
)
VALUES

-- Open overdue loan
(
1,
'Mary Banda',
CURRENT_DATE - 20,
CURRENT_DATE - 10,
NULL,
0
),

-- Open loan not overdue
(
2,
'John Phiri',
CURRENT_DATE - 3,
CURRENT_DATE + 7,
NULL,
0
),

-- Returned on time
(
3,
'Grace Zulu',
CURRENT_DATE - 15,
CURRENT_DATE - 10,
CURRENT_DATE - 10,
0
),

(
1,
'Peter Mwale',
CURRENT_DATE - 25,
CURRENT_DATE - 18,
CURRENT_DATE - 12,
0
),

(
2,
'Paul Tembo',
CURRENT_DATE - 12,
CURRENT_DATE - 5,
NULL,
0
),

(
3,
'Esther Lungu',
CURRENT_DATE - 5,
CURRENT_DATE + 5,
NULL,
0
);

--=========================================================
-- FUNCTION
-- K2 PER DAY OVERDUE
--=========================================================

CREATE OR REPLACE FUNCTION fn_loan_fine
(
    p_loan_id INTEGER,
    p_as_of DATE
)

RETURNS NUMERIC

LANGUAGE plpgsql

AS
$$

DECLARE

    v_due DATE;

    v_returned DATE;

    v_effective DATE;

    v_days INTEGER;

BEGIN

    SELECT
        due_on,
        returned_on
    INTO
        v_due,
        v_returned
    FROM loans
    WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan';
    END IF;

    IF v_returned IS NOT NULL THEN
        v_effective :=
            LEAST(v_returned, p_as_of);
    ELSE
        v_effective :=
            p_as_of;
    END IF;

    v_days :=
        GREATEST(
            v_effective - v_due,
            0
        );

    RETURN ROUND(v_days * 2.00,2);

END;

$$;

--=========================================================
-- PROCEDURE
-- RETURN LOAN
--=========================================================

CREATE OR REPLACE PROCEDURE pr_return_loan
(
    p_loan_id INTEGER,
    p_returned_on DATE
)

LANGUAGE plpgsql

AS
$$

DECLARE

    v_borrowed DATE;

    v_returned DATE;

    v_fine NUMERIC;

BEGIN

    SELECT
        borrowed_on,
        returned_on
    INTO
        v_borrowed,
        v_returned
    FROM loans
    WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan';
    END IF;

    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan already returned';
    END IF;

    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION
        'Return date cannot be before borrowed date';
    END IF;

    v_fine :=
        fn_loan_fine
        (
            p_loan_id,
            p_returned_on
        );

    UPDATE loans
    SET
        returned_on = p_returned_on,
        fine_amount = v_fine
    WHERE loan_id = p_loan_id;

END;

$$;

--=========================================================
-- AUDIT TRIGGER FUNCTION
--=========================================================

CREATE OR REPLACE FUNCTION audit_return_changes()

RETURNS TRIGGER

LANGUAGE plpgsql

AS
$$

BEGIN

    IF OLD.returned_on IS DISTINCT FROM NEW.returned_on
    THEN

        INSERT INTO loan_audit
        (
            loan_id,
            old_returned_on,
            new_returned_on,
            changed_at
        )
        VALUES
        (
            NEW.loan_id,
            OLD.returned_on,
            NEW.returned_on,
            CURRENT_TIMESTAMP
        );

    END IF;

    RETURN NULL;

END;

$$;

--=========================================================
-- TRIGGER
--=========================================================

CREATE TRIGGER trg_return_audit

AFTER UPDATE

ON loans

FOR EACH ROW

EXECUTE FUNCTION audit_return_changes();

--=========================================================
-- VIEW
-- CURRENTLY OVERDUE LOANS
--=========================================================

CREATE OR REPLACE VIEW v_overdue_loans

AS

SELECT

    b.title,

    l.borrower_name,

    l.due_on,

    fn_loan_fine
    (
        l.loan_id,
        CURRENT_DATE
    ) AS fine_today

FROM loans l

JOIN books b
ON b.book_id = l.book_id

WHERE l.returned_on IS NULL
AND l.due_on < CURRENT_DATE;

--=========================================================
-- INDEX
-- SUPPORT BOOK SEARCHES
--=========================================================

CREATE INDEX idx_loans_book_unreturned

ON loans
(
    book_id,
    returned_on
);

-- EXPLAIN TEST

EXPLAIN

SELECT *

FROM loans

WHERE book_id = 1

AND returned_on IS NULL;

--=========================================================
-- SUMMARY PROCEDURE
--=========================================================

CREATE OR REPLACE PROCEDURE pr_refresh_overdue
(
    p_as_of DATE
)

LANGUAGE plpgsql

AS
$$

BEGIN

    INSERT INTO overdue_summary
    (
        snapshot_date,
        overdue_count,
        total_fine
    )

    SELECT

        p_as_of,

        COUNT(*),

        COALESCE
        (
            SUM
            (
                fn_loan_fine
                (
                    loan_id,
                    p_as_of
                )
            ),
            0
        )

    FROM loans

    WHERE returned_on IS NULL
    AND due_on < p_as_of

    ON CONFLICT(snapshot_date)

    DO UPDATE

    SET

        overdue_count =
        EXCLUDED.overdue_count,

        total_fine =
        EXCLUDED.total_fine;

END;

$$;

--=========================================================
-- SCHEDULED JOB EXAMPLE (PG_CRON)
--=========================================================

-- SELECT cron.schedule(
-- 'refresh-overdue-summary',
-- '10 0 * * *',
-- $$CALL q3_library.pr_refresh_overdue(CURRENT_DATE);$$
-- );

--=========================================================
-- TEST STATEMENTS
--=========================================================

SELECT fn_loan_fine(1,CURRENT_DATE);

CALL pr_return_loan
(
1,
CURRENT_DATE
);

SELECT *
FROM loan_audit;

SELECT *
FROM v_overdue_loans;

CALL pr_refresh_overdue
(
CURRENT_DATE
);

SELECT *
FROM overdue_summary;