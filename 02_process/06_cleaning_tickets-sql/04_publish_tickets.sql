-- =====================================================================
-- M6 · 04  Publish the final tickets table  (work.support_tickets -> clean.tickets)
-- Only the clean columns, plus:
--   needs_review  true when at least one flag needs a person's decision
--   dq_flags      every flag reason for the ticket (empty = none)
-- The audit columns (raw values) stay in work.support_tickets.
-- =====================================================================

DROP TABLE IF EXISTS clean.tickets;

CREATE TABLE clean.tickets AS
SELECT
    t.ticket_id,
    t.customer_id,
    t.issue_type,
    t.ticket_created,
    t.ticket_resolved,
    t.resolution_time_hours,
    t.sentiment,
    t.support_agent,
    t.created_is_derived,
    t.resolved_is_derived,
    COALESCE(f.needs_review, FALSE) AS needs_review,
    f.reasons                       AS dq_flags
FROM work.support_tickets t
LEFT JOIN (
    SELECT ticket_id,
           BOOL_OR(flag_type = 'needs review')          AS needs_review,
           STRING_AGG(reason, '; ' ORDER BY reason)     AS reasons
    FROM clean.ticket_flags
    GROUP BY ticket_id
) f USING (ticket_id);

ALTER TABLE clean.tickets ADD PRIMARY KEY (ticket_id);
