/*
===============================================================================
UrbanAssist 360 | Silver 01 - Clean and deduplicated Dynamic Tables
Run as: URBANASSIST_ENGINEER

TARGET_LAG is a freshness objective, not a fixed cron interval. AUTO lets
Snowflake choose a supported refresh mode for each query definition.
===============================================================================
*/

-- Use the project role that owns Bronze inputs and Silver outputs.
USE ROLE URBANASSIST_ENGINEER;

-- Supply compute for initial and incremental Dynamic Table refreshes.
USE WAREHOUSE URBANASSIST_WH;

-- Select the database containing both source and target medallion layers.
USE DATABASE URBANASSIST_DB;

-- Create the Dynamic Tables in the Silver schema.
USE SCHEMA SILVER;

-- Declare the desired latest-booking result. Snowflake maintains it toward a
-- five-minute freshness target; no Task or manual MERGE is required.
CREATE OR REPLACE DYNAMIC TABLE DT_BOOKINGS_CLEAN
  TARGET_LAG = '5 MINUTES'
  WAREHOUSE = URBANASSIST_WH
  REFRESH_MODE = AUTO
  COMMENT = 'Latest valid, typed snapshot for every booking'
AS
SELECT
  payload:booking_id::VARCHAR                              AS booking_id,
  payload:customer_id::VARCHAR                             AS customer_id,
  payload:provider_id::VARCHAR                             AS provider_id,
  payload:service_id::VARCHAR                              AS service_id,
  INITCAP(TRIM(payload:booking_city::VARCHAR))              AS booking_city,
  TRY_TO_TIMESTAMP_TZ(payload:booking_created_at::VARCHAR)  AS booking_created_at,
  TRY_TO_TIMESTAMP_TZ(payload:scheduled_at::VARCHAR)        AS scheduled_at,
  TRY_TO_TIMESTAMP_TZ(payload:service_started_at::VARCHAR)  AS service_started_at,
  TRY_TO_TIMESTAMP_TZ(payload:service_completed_at::VARCHAR) AS service_completed_at,
  UPPER(TRIM(payload:booking_status::VARCHAR))               AS booking_status,
  TRY_TO_DECIMAL(payload:gross_amount::VARCHAR, 12, 2)       AS gross_amount,
  TRY_TO_DECIMAL(payload:discount_amount::VARCHAR, 12, 2)    AS discount_amount,
  TRY_TO_DECIMAL(payload:tax_amount::VARCHAR, 12, 2)         AS tax_amount,
  TRY_TO_DECIMAL(payload:final_amount::VARCHAR, 12, 2)       AS final_amount,
  UPPER(TRIM(payload:payment_method::VARCHAR))                AS payment_method,
  TRY_TO_NUMBER(payload:rating::VARCHAR)                     AS rating,
  NULLIF(TRIM(payload:review_text::VARCHAR), '')              AS review_text,
  TRY_TO_TIMESTAMP_TZ(payload:record_updated_at::VARCHAR)    AS record_updated_at,
  source_filename,
  ingested_at
FROM BRONZE.RAW_BOOKING_EVENTS
WHERE payload:booking_id IS NOT NULL
  AND payload:customer_id IS NOT NULL
  AND payload:provider_id IS NOT NULL
  AND payload:service_id IS NOT NULL
  AND TRY_TO_TIMESTAMP_TZ(payload:booking_created_at::VARCHAR) IS NOT NULL
  AND UPPER(TRIM(payload:booking_status::VARCHAR)) IN
      ('BOOKED', 'ASSIGNED', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED')
  AND COALESCE(TRY_TO_DECIMAL(payload:final_amount::VARCHAR, 12, 2), -1) >= 0
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY payload:booking_id::VARCHAR
  ORDER BY TRY_TO_TIMESTAMP_TZ(payload:record_updated_at::VARCHAR) DESC,
           ingested_at DESC,
           source_row_number DESC
) = 1;

-- Declare a typed provider-event result. Unlike booking Silver, this keeps every
-- valid provider event because Gold needs the event sequence to construct SCD2.
CREATE OR REPLACE DYNAMIC TABLE DT_PROVIDER_CHANGES_CLEAN
  TARGET_LAG = '5 MINUTES'
  WAREHOUSE = URBANASSIST_WH
  REFRESH_MODE = AUTO
  COMMENT = 'Typed provider snapshots with a hash of SCD2 tracked attributes'
AS
SELECT
  payload:provider_id::VARCHAR                              AS provider_id,
  payload:provider_name::VARCHAR                            AS provider_name,
  INITCAP(TRIM(payload:primary_city::VARCHAR))               AS primary_city,
  INITCAP(TRIM(payload:operating_zone::VARCHAR))             AS operating_zone,
  UPPER(TRIM(payload:provider_tier::VARCHAR))                 AS provider_tier,
  UPPER(TRIM(payload:experience_level::VARCHAR))              AS experience_level,
  UPPER(TRIM(payload:active_status::VARCHAR))                 AS active_status,
  payload:primary_service_category::VARCHAR                  AS primary_service_category,
  TRY_TO_TIMESTAMP_TZ(payload:effective_at::VARCHAR)         AS effective_at,
  TRY_TO_TIMESTAMP_TZ(payload:record_updated_at::VARCHAR)    AS record_updated_at,
  SHA2(CONCAT_WS('|',
    INITCAP(TRIM(payload:primary_city::VARCHAR)),
    INITCAP(TRIM(payload:operating_zone::VARCHAR)),
    UPPER(TRIM(payload:provider_tier::VARCHAR)),
    UPPER(TRIM(payload:experience_level::VARCHAR)),
    UPPER(TRIM(payload:active_status::VARCHAR)),
    payload:primary_service_category::VARCHAR
  ), 256) AS attribute_hash,
  source_filename,
  ingested_at
FROM BRONZE.RAW_PROVIDER_EVENTS
WHERE payload:provider_id IS NOT NULL
  AND TRY_TO_TIMESTAMP_TZ(payload:effective_at::VARCHAR) IS NOT NULL
  AND UPPER(TRIM(payload:provider_tier::VARCHAR)) IN ('STANDARD', 'PREMIUM')
  AND UPPER(TRIM(payload:active_status::VARCHAR)) IN ('ACTIVE', 'INACTIVE');

-- Confirm both Dynamic Tables exist and inspect refresh mode, target lag, state,
-- and scheduling information before building Gold objects.
SHOW DYNAMIC TABLES IN SCHEMA URBANASSIST_DB.SILVER;

