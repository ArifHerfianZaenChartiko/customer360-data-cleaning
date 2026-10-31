-- =====================================================================
-- M6 · 01  Create schemas and tables (PostgreSQL)
-- Database: customer360
--
-- raw.*    the tickets CSV exactly as delivered (every column text)
-- work.*   intermediate tables of the ticket cleaning (kept for audit)
-- clean.*  the final clean tables of all five sources (this schema is the deliverable)
--
-- Loading: 06_cleaning_tickets.ipynb loads the data with COPY.
-- In DBeaver you can load the same CSV files from clean_data/csv with
-- right-click table > Import Data.
-- =====================================================================

DROP SCHEMA IF EXISTS raw CASCADE;
DROP SCHEMA IF EXISTS work CASCADE;
DROP SCHEMA IF EXISTS clean CASCADE;
CREATE SCHEMA raw;
CREATE SCHEMA work;
CREATE SCHEMA clean;

-- Raw tickets: all text, so nothing is converted or lost on load
CREATE TABLE raw.support_tickets (
    ticket_id             text,
    customer_id           text,
    issue_type            text,
    ticket_created        text,
    ticket_resolved       text,
    resolution_time_hours text,
    sentiment             text,
    support_agent         text
);

-- Clean tables from M2-M5 (same columns as the clean Excel/CSV files)
CREATE TABLE clean.customers (
    customer_id            text PRIMARY KEY,
    first_name             text,
    last_name              text,
    email                  text,
    email_is_shared        boolean,
    phone_e164             text,
    phone_ext              text,
    phone_raw              text,
    gender                 text,
    dob                    date,
    signup_date            date,
    address                text,
    city                   text,
    state                  text,
    country                text,
    state_country_conflict boolean,
    device_count           integer,
    source                 text,
    needs_review           boolean,
    dq_flags               text
);

CREATE TABLE clean.customer_devices (
    customer_id text REFERENCES clean.customers (customer_id),
    device_id   text,
    PRIMARY KEY (customer_id, device_id)
);

CREATE TABLE clean.products (
    product_id    text PRIMARY KEY,
    product_name  text,
    category      text,
    price         numeric(12, 2),
    price_status  text,
    flag_type     text,
    review_reason text
);

CREATE TABLE clean.orders (
    order_id          text PRIMARY KEY,
    customer_id       text,
    product_id        text,
    order_date        date,
    order_amount      numeric(12, 2),
    is_amount_outlier boolean,
    quantity          integer,
    payment_method    text,
    status            text,
    needs_review      boolean,
    dq_flags          text
);

CREATE TABLE clean.clickstream (
    event_id             text PRIMARY KEY,
    session_id           text,
    customer_id          text,
    is_anonymous         boolean,
    event_type           text,
    page_url             text,
    product_id           text,
    device_id            text,
    timestamp_utc        timestamp,
    timestamp_tz_assumed boolean,
    ingest_run_id        text
);
