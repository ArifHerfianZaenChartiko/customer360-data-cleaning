-- =====================================================================
-- M6 · 03  Ticket flags  (one row per problem)
-- Nothing here changes data; it lists what was found, with a flag_type:
--   needs review              a person should check or decide
--   invalid or missing value  the source value was impossible or in the future; set to null
--   auto-fixed (info)         the value was rebuilt automatically; listed for transparency
-- =====================================================================

DROP TABLE IF EXISTS clean.ticket_flags;

CREATE TABLE clean.ticket_flags AS
SELECT ticket_id, 'invalid or missing value' AS flag_type, 'ticket_created' AS column_name,
       created_raw AS raw_value, 'impossible timestamp (bad month/hour); set to null' AS reason
FROM work.support_tickets
WHERE created_raw IS NOT NULL AND created_parsed IS NULL

UNION ALL
SELECT ticket_id, 'invalid or missing value', 'ticket_resolved', resolved_raw,
       'impossible timestamp (bad month/hour); set to null'
FROM work.support_tickets
WHERE resolved_raw IS NOT NULL AND resolved_parsed IS NULL

UNION ALL
SELECT ticket_id, 'invalid or missing value', 'ticket_created', created_raw,
       'timestamp after the data export (2025-12-02); set to null'
FROM work.support_tickets
WHERE created_parsed >= TIMESTAMP '2025-12-03'

UNION ALL
SELECT ticket_id, 'invalid or missing value', 'ticket_resolved', resolved_raw,
       'timestamp after the data export (2025-12-02); set to null'
FROM work.support_tickets
WHERE resolved_parsed >= TIMESTAMP '2025-12-03'

UNION ALL
SELECT ticket_id, 'auto-fixed (info)', 'ticket_created', COALESCE(created_raw, '(blank)'),
       'rebuilt as ticket_resolved minus resolution_time_hours'
FROM work.support_tickets
WHERE created_is_derived

UNION ALL
SELECT ticket_id, 'auto-fixed (info)', 'ticket_resolved', COALESCE(resolved_raw, '(blank)'),
       'rebuilt as ticket_created plus resolution_time_hours'
FROM work.support_tickets
WHERE resolved_is_derived

UNION ALL
SELECT ticket_id, 'needs review', 'support_agent', agent_raw,
       'possible doubled-letter typo; no clean spelling of this agent exists, kept as is'
FROM work.support_tickets
WHERE support_agent ~ 'aa' AND NOT agent_typo_fixed

UNION ALL
SELECT ticket_id, 'needs review', 'issue_type', issue_type_raw, 'issue type could not be mapped'
FROM work.support_tickets
WHERE issue_type IS NULL

UNION ALL
SELECT ticket_id, 'needs review', 'sentiment', sentiment_raw, 'sentiment could not be mapped'
FROM work.support_tickets
WHERE sentiment IS NULL;
