-- =====================================================================
-- M6 · 02  Clean support tickets  (raw.support_tickets -> work.support_tickets)
--
-- One CTE per cleaning step, so each rule can be read and tested on its own.
-- Values are never guessed: what cannot be proven becomes NULL and gets a flag.
-- The data was exported on 2025-12-02, so any timestamp after that day is impossible.
-- =====================================================================

DROP TABLE IF EXISTS work.support_tickets;

CREATE TABLE work.support_tickets AS
WITH
-- Step 1: trim every column; keep only one row per ticket_id (ROW_NUMBER guards against duplicates)
trimmed AS (
    SELECT
        TRIM(ticket_id)                    AS ticket_id,
        TRIM(customer_id)                  AS customer_id,
        TRIM(issue_type)                   AS issue_type_raw,
        NULLIF(TRIM(ticket_created), '')   AS created_raw,
        NULLIF(TRIM(ticket_resolved), '')  AS resolved_raw,
        TRIM(resolution_time_hours)        AS hours_raw,
        TRIM(sentiment)                    AS sentiment_raw,
        TRIM(support_agent)                AS agent_raw,
        ROW_NUMBER() OVER (PARTITION BY TRIM(ticket_id) ORDER BY ticket_created) AS rn
    FROM raw.support_tickets
),
dedup AS (
    SELECT * FROM trimmed WHERE rn = 1
),

-- Step 2: categorical keys. lower case, '3' -> 'e' (leetspeak), trailing 'x' / '_' removed
keys AS (
    SELECT
        d.*,
        REGEXP_REPLACE(REPLACE(LOWER(issue_type_raw), '3', 'e'), '[x_]+$', '') AS issue_key,
        REPLACE(LOWER(sentiment_raw), '3', 'e')                               AS sentiment_key
    FROM dedup d
),
issue_types(value) AS (VALUES ('delay'), ('payment'), ('product'), ('refund')),
sentiments(value)  AS (VALUES ('negative'), ('neutral'), ('positive')),

-- Step 3: map keys to standard values
--   exact match, reversed text ('tnemyap' -> 'payment'), or a unique prefix ('pay' -> 'payment')
mapped AS (
    SELECT
        k.*,
        COALESCE(
            (SELECT value FROM issue_types WHERE value = k.issue_key),
            (SELECT value FROM issue_types WHERE value = REVERSE(k.issue_key)),
            (SELECT MIN(value) FROM issue_types WHERE value LIKE k.issue_key || '%'
               HAVING COUNT(*) = 1)
        ) AS issue_type,
        COALESCE(
            (SELECT value FROM sentiments WHERE value = k.sentiment_key),
            (SELECT MIN(value) FROM sentiments WHERE value LIKE k.sentiment_key || '%'
               HAVING COUNT(*) = 1)
        ) AS sentiment
    FROM keys k
),

-- Step 4: timestamps. Accept only ISO 8601 text that PostgreSQL can really parse
--   ('2025-12-12T28:77:10' has the right shape but hour 28 does not exist)
parsed AS (
    SELECT
        m.*,
        CASE WHEN created_raw  ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?$'
              AND pg_input_is_valid(created_raw, 'timestamp')
             THEN CAST(created_raw AS timestamp) END  AS created_parsed,
        CASE WHEN resolved_raw ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?$'
              AND pg_input_is_valid(resolved_raw, 'timestamp')
             THEN CAST(resolved_raw AS timestamp) END AS resolved_parsed,
        CAST(NULLIF(hours_raw, '') AS numeric)        AS resolution_time_hours
    FROM mapped m
),
-- impossible future timestamps (after the export day) -> NULL
dated AS (
    SELECT
        p.*,
        CASE WHEN created_parsed  < TIMESTAMP '2025-12-03' THEN created_parsed  END AS created_valid,
        CASE WHEN resolved_parsed < TIMESTAMP '2025-12-03' THEN resolved_parsed END AS resolved_valid
    FROM parsed p
),

-- Step 5: rebuild a missing timestamp from the other one and resolution_time_hours,
--   but only if the rule holds for EVERY ticket where both timestamps are valid
consistency AS (
    SELECT BOOL_AND(ABS(EXTRACT(EPOCH FROM resolved_valid - created_valid) / 3600 - resolution_time_hours) < 0.01)
           AS hours_always_match
    FROM dated
    WHERE created_valid IS NOT NULL AND resolved_valid IS NOT NULL
),
derived AS (
    SELECT
        d.*,
        (d.created_valid IS NULL AND d.resolved_valid IS NOT NULL AND c.hours_always_match) AS created_is_derived,
        -- a rebuilt resolve time after the export day means the ticket was still open: do not rebuild
        (d.resolved_valid IS NULL AND d.created_valid IS NOT NULL AND c.hours_always_match
         AND d.created_valid + d.resolution_time_hours * INTERVAL '1 hour' < TIMESTAMP '2025-12-03') AS resolved_is_derived
    FROM dated d CROSS JOIN consistency c
),

-- Step 6: agent names. remove symbols ('--', '@@'), collapse spaces,
--   fix all-lower / all-upper names with INITCAP
agents AS (
    SELECT
        dv.*,
        CASE WHEN a1 = LOWER(a1) OR a1 = UPPER(a1) THEN INITCAP(a1) ELSE a1 END AS agent_step1
    FROM derived dv,
    LATERAL (
        SELECT REGEXP_REPLACE(
                   TRIM(BOTH '-' FROM REGEXP_REPLACE(dv.agent_raw, '[^A-Za-z .''-]+', '', 'g')),
                   '\s+', ' ', 'g') AS a1
    ) x
),
-- every spelling of an agent name that occurs in the data; used as the reference
known_agents AS (
    SELECT DISTINCT ON (LOWER(agent_step1)) LOWER(agent_step1) AS agent_key, agent_step1 AS agent_name
    FROM agents
    ORDER BY LOWER(agent_step1), agent_step1
),
-- 'aa' typo (lower-case 'aa' inside a word): replace 'aa' with 'a' ONLY when that spelling
--   exists as another agent name ('Kaathy Berry' -> 'Kathy Berry').
--   'Isaac Grant' stays, because 'Isac Grant' never occurs; 'Aaron' is not touched (capital A).
agents_fixed AS (
    SELECT
        a.*,
        COALESCE(k.agent_name, a.agent_step1) AS support_agent,
        (k.agent_name IS NOT NULL)            AS agent_typo_fixed
    FROM agents a
    LEFT JOIN known_agents k
           ON a.agent_step1 ~ 'aa'
          AND k.agent_key = REPLACE(LOWER(a.agent_step1), 'aa', 'a')
)

SELECT
    ticket_id,
    customer_id,
    issue_type,
    COALESCE(created_valid,
             CASE WHEN created_is_derived  THEN resolved_valid - resolution_time_hours * INTERVAL '1 hour' END) AS ticket_created,
    COALESCE(resolved_valid,
             CASE WHEN resolved_is_derived THEN created_valid  + resolution_time_hours * INTERVAL '1 hour' END) AS ticket_resolved,
    resolution_time_hours,
    sentiment,
    support_agent,
    created_is_derived,
    resolved_is_derived,
    -- kept for the flag table and the audit
    issue_type_raw, created_raw, resolved_raw, sentiment_raw, agent_raw,
    created_parsed, resolved_parsed, agent_typo_fixed
FROM agents_fixed;

ALTER TABLE work.support_tickets ADD PRIMARY KEY (ticket_id);
