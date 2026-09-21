/*
===============================================================================
UrbanAssist 360 | Operations 02 - Event-driven live change walkthrough
Run as: URBANASSIST_ENGINEER

Execute the BEFORE section, upload the two live files to S3, then execute each
AFTER section in order. No external orchestrator or CI/CD pipeline is required.
===============================================================================
*/

-- Use the project role that can inspect every layer and execute development
-- refreshes.
USE ROLE URBANASSIST_ENGINEER;

-- Resume compute for the demonstration queries when needed.
USE WAREHOUSE URBANASSIST_WH;

-- Select the project database.
USE DATABASE URBANASSIST_DB;

-- Use OPS so stage, pipe, Stream, and Task names are easy to inspect.
USE SCHEMA OPS;

-- ---------- BEFORE: capture the current state ----------
-- Record the logical booking count in Bronze before the live file is uploaded.
SELECT COUNT(DISTINCT payload:booking_id::VARCHAR) AS bronze_unique_bookings
FROM BRONZE.RAW_BOOKING_EVENTS; --50000

-- Record baseline Gold volume, revenue, and cancellation rate for comparison.
SELECT COUNT(*) AS gold_bookings,
       ROUND(SUM(final_amount), 2) AS net_revenue,
       ROUND(SUM(cancelled_booking_count) / NULLIF(COUNT(*), 0), 4) AS cancellation_rate
FROM GOLD.FACT_BOOKING;

-- Record version history for a small known provider sample before SCD2 changes.
SELECT provider_id, provider_tier, primary_city, operating_zone,
       effective_start_at, effective_end_at, is_current
FROM GOLD.DIM_PROVIDER_SCD2
WHERE provider_id IN ('P00001', 'P00002', 'P00016', 'P00023', 'P00028')
ORDER BY provider_id, effective_start_at;

/*
Upload these files now, preserving the exact object keys:

  data/generated/bookings/booking_live_batch.json.gz
    -> s3://<bucket>/urbanassist/bookings/booking_live_batch.json.gz

  data/generated/providers/provider_changes_live.json.gz
    -> s3://<bucket>/urbanassist/providers/provider_changes_live.json.gz
*/

-- ---------- AFTER 1: confirm S3 visibility and Snowpipe state ----------
-- Confirm the held-back booking object is visible through the external stage.
LIST @URBANASSIST_S3_STAGE/bookings/ PATTERN = '.*booking_live_batch[.]json[.]gz';

-- Confirm the held-back provider-change object is visible through the stage.
LIST @URBANASSIST_S3_STAGE/providers/ PATTERN = '.*provider_changes_live[.]json[.]gz';

-- Check that the booking pipe received and processed its S3 notification.
SELECT SYSTEM$PIPE_STATUS('URBANASSIST_DB.OPS.BOOKING_EVENTS_PIPE') AS booking_pipe_status;

-- Check the provider pipe separately for its notification and load outcome.
SELECT SYSTEM$PIPE_STATUS('URBANASSIST_DB.OPS.PROVIDER_EVENTS_PIPE') AS provider_pipe_status;

-- Recount distinct Bronze bookings; after ingestion it should increase by 1,000.
SELECT COUNT(DISTINCT payload:booking_id::VARCHAR) AS bronze_unique_bookings
FROM BRONZE.RAW_BOOKING_EVENTS;

-- If an event notification was missed, queue the recent files once.
-- Do not repeatedly REFRESH a healthy pipe during normal operation.
-- ALTER PIPE BOOKING_EVENTS_PIPE REFRESH;
-- ALTER PIPE PROVIDER_EVENTS_PIPE REFRESH;

-- ---------- AFTER 2: inspect stream readiness and task state ----------
-- TRUE means provider rows are waiting to be consumed by the SCD2 procedure.
SELECT SYSTEM$STREAM_HAS_DATA('URBANASSIST_DB.OPS.PROVIDER_EVENTS_STREAM') AS provider_change_ready;

-- TRUE means new booking snapshots are waiting for review enrichment evaluation.
SELECT SYSTEM$STREAM_HAS_DATA('URBANASSIST_DB.OPS.BOOKING_REVIEW_STREAM') AS review_change_ready;

-- Inspect both Tasks and confirm they are STARTED rather than SUSPENDED.
SHOW TASKS IN SCHEMA URBANASSIST_DB.OPS;

-- Tasks run on their one-minute schedules. The following commands are optional
-- development shortcuts if an immediate run is preferred.
-- EXECUTE TASK TASK_PROCESS_PROVIDER_SCD2;
-- EXECUTE TASK TASK_ENRICH_NEW_REVIEWS;

-- ---------- AFTER 3: refresh declarative layers for deterministic inspection ----------
-- Refresh latest booking state immediately instead of waiting for target lag.
ALTER DYNAMIC TABLE SILVER.DT_BOOKINGS_CLEAN REFRESH;

-- Refresh clean provider events for transparent inspection of the live rows.
ALTER DYNAMIC TABLE SILVER.DT_PROVIDER_CHANGES_CLEAN REFRESH;

-- Rebuild the booking fact after Silver and SCD2 processing are current.
ALTER DYNAMIC TABLE GOLD.FACT_BOOKING REFRESH;

-- Rebuild the dependent daily KPI aggregate from current Gold results.
ALTER DYNAMIC TABLE GOLD.DT_DAILY_SERVICE_KPI REFRESH;

-- ---------- AFTER 4: validate the end state ----------
-- Confirm Silver now represents 51,000 latest logical bookings.
SELECT COUNT(*) AS silver_unique_bookings FROM SILVER.DT_BOOKINGS_CLEAN;

-- Confirm the Gold fact has the same one-row-per-booking grain.
SELECT COUNT(*) AS gold_unique_bookings FROM GOLD.FACT_BOOKING;

-- Confirm new reviewed bookings have been appended to stored AI results.
SELECT COUNT(*) AS ai_enriched_reviews FROM GOLD.FACT_REVIEW_INSIGHT;

-- Show old and new versions for the known provider sample after the Task runs.
SELECT provider_id, provider_tier, primary_city, operating_zone, active_status,
       effective_start_at, effective_end_at, is_current
FROM GOLD.DIM_PROVIDER_SCD2
WHERE provider_id IN ('P00001', 'P00002', 'P00016', 'P00023', 'P00028')
ORDER BY provider_id, effective_start_at;

-- Display the resulting September daily KPIs for business interpretation.
SELECT booking_date, booking_city, service_category, total_bookings,
       cancellation_rate, total_revenue, average_rating,
       enriched_review_count, negative_review_count
FROM GOLD.DT_DAILY_SERVICE_KPI
WHERE booking_date >= '2026-09-01'
ORDER BY booking_date DESC, total_revenue DESC;

-- Continue in the Agent playground or Snowflake CoWork with:
-- "What changed after September 1, 2026, and which city and service category
--  now need the most attention? Support the answer with governed metrics."
