-- =====================================================================
-- M6 · 05  Integrity checks across all clean tables
-- One row per check. failing_rows = 0 means the check passed.
-- Checks report problems; they do not change data.
-- =====================================================================

DROP TABLE IF EXISTS clean.integrity_checks;

CREATE TABLE clean.integrity_checks AS
WITH checks AS (
    -- Primary keys: one row per ID
    SELECT 1 AS check_no, 'primary key' AS check_type, 'customers.customer_id is unique' AS check_name,
           (SELECT COUNT(*) - COUNT(DISTINCT customer_id) FROM clean.customers) AS failing_rows,
           (SELECT COUNT(*) FROM clean.customers) AS total_rows
    UNION ALL
    SELECT 2, 'primary key', 'products.product_id is unique',
           (SELECT COUNT(*) - COUNT(DISTINCT product_id) FROM clean.products),
           (SELECT COUNT(*) FROM clean.products)
    UNION ALL
    SELECT 3, 'primary key', 'orders.order_id is unique',
           (SELECT COUNT(*) - COUNT(DISTINCT order_id) FROM clean.orders),
           (SELECT COUNT(*) FROM clean.orders)
    UNION ALL
    SELECT 4, 'primary key', 'tickets.ticket_id is unique',
           (SELECT COUNT(*) - COUNT(DISTINCT ticket_id) FROM clean.tickets),
           (SELECT COUNT(*) FROM clean.tickets)
    UNION ALL
    SELECT 5, 'primary key', 'clickstream.event_id is unique',
           (SELECT COUNT(*) - COUNT(DISTINCT event_id) FROM clean.clickstream),
           (SELECT COUNT(*) FROM clean.clickstream)

    -- Foreign keys: every reference points to an existing row (orphans)
    UNION ALL
    SELECT 6, 'foreign key', 'orders.customer_id exists in customers',
           (SELECT COUNT(*) FROM clean.orders o
             WHERE NOT EXISTS (SELECT 1 FROM clean.customers c WHERE c.customer_id = o.customer_id)),
           (SELECT COUNT(*) FROM clean.orders)
    UNION ALL
    SELECT 7, 'foreign key', 'orders.product_id exists in products',
           (SELECT COUNT(*) FROM clean.orders o
             WHERE NOT EXISTS (SELECT 1 FROM clean.products p WHERE p.product_id = o.product_id)),
           (SELECT COUNT(*) FROM clean.orders)
    UNION ALL
    SELECT 8, 'foreign key', 'tickets.customer_id exists in customers',
           (SELECT COUNT(*) FROM clean.tickets t
             WHERE NOT EXISTS (SELECT 1 FROM clean.customers c WHERE c.customer_id = t.customer_id)),
           (SELECT COUNT(*) FROM clean.tickets)
    UNION ALL
    SELECT 9, 'foreign key', 'clickstream.customer_id exists in customers (anonymous events excluded)',
           (SELECT COUNT(*) FROM clean.clickstream e
             WHERE e.customer_id IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM clean.customers c WHERE c.customer_id = e.customer_id)),
           (SELECT COUNT(*) FROM clean.clickstream WHERE customer_id IS NOT NULL)
    UNION ALL
    SELECT 10, 'foreign key', 'clickstream.product_id exists in products',
           (SELECT COUNT(*) FROM clean.clickstream e
             WHERE e.product_id IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM clean.products p WHERE p.product_id = e.product_id)),
           (SELECT COUNT(*) FROM clean.clickstream WHERE product_id IS NOT NULL)
    UNION ALL
    SELECT 11, 'foreign key', 'customer_devices.customer_id exists in customers',
           (SELECT COUNT(*) FROM clean.customer_devices d
             WHERE NOT EXISTS (SELECT 1 FROM clean.customers c WHERE c.customer_id = d.customer_id)),
           (SELECT COUNT(*) FROM clean.customer_devices)

    -- Business rules: values that are valid on their own but contradict another table
    UNION ALL
    SELECT 12, 'business rule', 'clickstream device belongs to the logged-in customer',
           (SELECT COUNT(*) FROM clean.clickstream e
             WHERE e.customer_id IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM clean.customer_devices d
                                WHERE d.customer_id = e.customer_id AND d.device_id = e.device_id)),
           (SELECT COUNT(*) FROM clean.clickstream WHERE customer_id IS NOT NULL)
    UNION ALL
    SELECT 13, 'business rule', 'order date is not before the customer signed up',
           (SELECT COUNT(*) FROM clean.orders o JOIN clean.customers c USING (customer_id)
             WHERE o.order_date < c.signup_date),
           (SELECT COUNT(*) FROM clean.orders WHERE order_date IS NOT NULL)
    UNION ALL
    SELECT 14, 'business rule', 'ticket is not created before the customer signed up',
           (SELECT COUNT(*) FROM clean.tickets t JOIN clean.customers c USING (customer_id)
             WHERE t.ticket_created::date < c.signup_date),
           (SELECT COUNT(*) FROM clean.tickets WHERE ticket_created IS NOT NULL)
    UNION ALL
    SELECT 15, 'business rule', 'ticket is not resolved before it was created',
           (SELECT COUNT(*) FROM clean.tickets WHERE ticket_resolved < ticket_created),
           (SELECT COUNT(*) FROM clean.tickets
             WHERE ticket_created IS NOT NULL AND ticket_resolved IS NOT NULL)
)
SELECT
    check_no,
    check_type,
    check_name,
    failing_rows,
    total_rows,
    ROUND(100.0 * failing_rows / NULLIF(total_rows, 0), 2) AS failing_pct,
    CASE WHEN failing_rows = 0 THEN 'pass' ELSE 'flag' END AS status
FROM checks
ORDER BY check_no;

SELECT * FROM clean.integrity_checks;
