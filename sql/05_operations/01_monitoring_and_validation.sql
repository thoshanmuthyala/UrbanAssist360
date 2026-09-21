/*
===============================================================================
UrbanAssist 360 | Operations 01 - Monitoring and data-quality validation
Run as: URBANASSIST_ENGINEER

Every result should be reviewed. Queries named *_violations should return zero.
Account Usage can lag; Information Schema functions are used for recent history.
===============================================================================
*/

-- Use the role with access to every project layer and operational object.
USE ROLE URBANASSIST_ENGINEER;

-- Resume compute for validation queries if the warehouse is suspended.
USE WAREHOUSE URBANASSIST_WH;

-- Select the project database.
USE DATABASE URBANASSIST_DB;

-- Use OPS as the default namespace for pipeline history functions.
USE SCHEMA OPS;

-- ---------- Ingestion health ----------
-- Inspect booking Snowpipe queue state and its most recent ingestion outcome.
SELECT SYSTEM$PIPE_STATUS('URBANASSIST_DB.OPS.BOOKING_EVENTS_PIPE') AS booking_pipe_status;

-- Inspect provider Snowpipe independently so one source cannot hide the other.
SELECT SYSTEM$PIPE_STATUS('URBANASSIST_DB.OPS.PROVIDER_EVENTS_PIPE') AS provider_pipe_status;

-- Review recent booking COPY attempts, loaded files, errors, and row counts.
SELECT *
FROM TABLE(
  INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'URBANASSIST_DB.BRONZE.RAW_BOOKING_EVENTS',
    START_TIME => DATEADD('DAY', -1, CURRENT_TIMESTAMP())
  )
)
ORDER BY LAST_LOAD_TIME DESC;

-- ---------- Layer reconciliation ----------
-- Compare physical Bronze rows, distinct source bookings, deduplicated Silver
-- bookings, Gold facts, and persisted AI results in one result set.
SELECT 'BRONZE_PHYSICAL_BOOKING_ROWS' AS measure, COUNT(*) AS value
FROM BRONZE.RAW_BOOKING_EVENTS
UNION ALL
SELECT 'BRONZE_DISTINCT_BOOKINGS', COUNT(DISTINCT payload:booking_id::VARCHAR)
FROM BRONZE.RAW_BOOKING_EVENTS
UNION ALL
SELECT 'SILVER_LATEST_BOOKINGS', COUNT(*)
FROM SILVER.DT_BOOKINGS_CLEAN
UNION ALL
SELECT 'GOLD_FACT_BOOKINGS', COUNT(*)
FROM GOLD.FACT_BOOKING
UNION ALL
SELECT 'AI_ENRICHED_REVIEWS', COUNT(*)
FROM GOLD.FACT_REVIEW_INSIGHT;

-- The latest-state tables must contain one row per booking.
-- Any returned row indicates Silver deduplication did not enforce its grain.
SELECT booking_id, COUNT(*) AS duplicate_count
FROM SILVER.DT_BOOKINGS_CLEAN
GROUP BY booking_id
HAVING COUNT(*) > 1;

-- Any returned row indicates the Gold booking fact violated its declared grain.
SELECT booking_id, COUNT(*) AS duplicate_count
FROM GOLD.FACT_BOOKING
GROUP BY booking_id
HAVING COUNT(*) > 1;

-- ---------- Referential integrity ----------
-- All four dimension keys must resolve before a booking is analytically usable.
SELECT COUNT(*) AS missing_dimension_key_violations
FROM GOLD.FACT_BOOKING
WHERE booking_date_key IS NULL
   OR customer_key IS NULL
   OR provider_key IS NULL
   OR service_key IS NULL;

-- Verify every populated booking date key has a matching calendar row.
SELECT COUNT(*) AS invalid_date_key_violations
FROM GOLD.FACT_BOOKING fact
LEFT JOIN GOLD.DIM_DATE dimension
  ON dimension.date_key = fact.booking_date_key
WHERE dimension.date_key IS NULL;

-- ---------- SCD2 invariants ----------
-- Every natural provider ID must have exactly one open/current version.
SELECT provider_id, COUNT_IF(is_current) AS current_version_count
FROM GOLD.DIM_PROVIDER_SCD2
GROUP BY provider_id
HAVING COUNT_IF(is_current) <> 1;

-- Reject provider versions whose effective range is empty or negative.
SELECT COUNT(*) AS invalid_scd2_interval_violations
FROM GOLD.DIM_PROVIDER_SCD2
WHERE effective_start_at >= effective_end_at;

-- Verify that no two historical versions for the same provider overlap.
SELECT COUNT(*) AS overlapping_scd2_interval_violations
FROM GOLD.DIM_PROVIDER_SCD2 left_version
JOIN GOLD.DIM_PROVIDER_SCD2 right_version
  ON left_version.provider_id = right_version.provider_id
 AND left_version.provider_key < right_version.provider_key
 AND left_version.effective_start_at < right_version.effective_end_at
 AND right_version.effective_start_at < left_version.effective_end_at;

-- ---------- Business-rule checks ----------
-- Detect impossible financial, rating, or service-duration measures.
SELECT COUNT(*) AS invalid_measure_violations
FROM GOLD.FACT_BOOKING
WHERE final_amount < 0
   OR discount_amount < 0
   OR rating NOT BETWEEN 1 AND 5
   OR service_duration_minutes < 0;

-- Produce the primary marketplace health metrics from the booking fact.
SELECT
  COUNT(*) AS total_fact_rows,
  SUM(completed_booking_count) AS completed_bookings,
  SUM(cancelled_booking_count) AS cancelled_bookings,
  ROUND(SUM(completed_booking_count) / NULLIF(COUNT(*), 0), 4) AS completion_rate,
  ROUND(SUM(cancelled_booking_count) / NULLIF(COUNT(*), 0), 4) AS cancellation_rate,
  ROUND(SUM(final_amount), 2) AS net_revenue,
  ROUND(AVG(rating), 2) AS average_rating
FROM GOLD.FACT_BOOKING;

-- Measure what percentage of latest nonblank reviews have persisted AI results.
SELECT
  COUNT_IF(review_text IS NOT NULL) AS review_candidates,
  COUNT(review.booking_id) AS enriched_reviews,
  ROUND(COUNT(review.booking_id) / NULLIF(COUNT_IF(review_text IS NOT NULL), 0), 4) AS enrichment_coverage
FROM SILVER.DT_BOOKINGS_CLEAN booking
LEFT JOIN GOLD.FACT_REVIEW_INSIGHT review
  ON review.booking_id = booking.booking_id;

-- ---------- Task and Dynamic Table history ----------
-- Review Task executions from the last day, including failures and messages.
SELECT name, state, scheduled_time, completed_time, error_code, error_message
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
  SCHEDULED_TIME_RANGE_START => DATEADD('DAY', -1, CURRENT_TIMESTAMP()),
  RESULT_LIMIT => 100
))
WHERE database_name = 'URBANASSIST_DB'
ORDER BY scheduled_time DESC;

-- Review recent Dynamic Table refreshes and diagnose stale or failed objects.
SELECT name, state, refresh_action, refresh_start_time, refresh_end_time,
       refresh_trigger, state_code, state_message
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
  DATA_TIMESTAMP_START => DATEADD('DAY', -1, CURRENT_TIMESTAMP()),
  RESULT_LIMIT => 100
))
WHERE database_name = 'URBANASSIST_DB'
ORDER BY refresh_start_time DESC;

-- ---------- Expected synthetic patterns ----------
-- Compare city cancellation rates; the generated data intentionally gives Pune
-- a visibly higher cancellation rate for a meaningful demonstration.
SELECT booking_city,
       ROUND(SUM(cancelled_booking_count) / NULLIF(COUNT(*), 0), 4) AS cancellation_rate,
       COUNT(*) AS total_bookings
FROM GOLD.FACT_BOOKING
GROUP BY booking_city
ORDER BY cancellation_rate DESC;

-- Compare category revenue and ratings; generated patterns make the output easy
-- to discuss and validate during development.
SELECT service.service_category,
       ROUND(SUM(booking.final_amount), 2) AS net_revenue,
       ROUND(AVG(booking.rating), 2) AS average_rating
FROM GOLD.FACT_BOOKING booking
JOIN GOLD.DIM_SERVICE service ON service.service_key = booking.service_key
GROUP BY service.service_category
ORDER BY net_revenue DESC;
