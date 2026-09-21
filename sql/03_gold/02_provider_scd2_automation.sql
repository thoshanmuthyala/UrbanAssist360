/*
===============================================================================
UrbanAssist 360 | Gold 02 - Provider SCD Type 2 stream, procedure, and Task
Run as: URBANASSIST_ENGINEER

Run this file only after provider_initial.json.gz has been loaded and Gold 01 has
seeded DIM_PROVIDER_SCD2. The stream starts at the current table offset, so only
later provider files are treated as changes.
===============================================================================
*/

-- Use the project role that owns the source table and target dimension.
USE ROLE URBANASSIST_ENGINEER;

-- Supply compute for the Task-owned procedure and its transactional DML.
USE WAREHOUSE URBANASSIST_WH;

-- Select the project database.
USE DATABASE URBANASSIST_DB;

-- Store the Stream, procedure, and Task in the operational schema even though
-- their persisted business result is written to Gold.
USE SCHEMA OPS;

-- Start an append-only change cursor at the current end of the Bronze provider
-- table. SHOW_INITIAL_ROWS = FALSE prevents the seeded baseline from replaying.
CREATE STREAM IF NOT EXISTS PROVIDER_EVENTS_STREAM
  ON TABLE BRONZE.RAW_PROVIDER_EVENTS
  APPEND_ONLY = TRUE
  SHOW_INITIAL_ROWS = FALSE
  COMMENT = 'New provider snapshots after the initial dimension seed';

-- Create the owner-rights procedure that applies each new provider snapshot as
-- an atomic SCD2 close-and-insert operation.
CREATE OR REPLACE PROCEDURE SP_APPLY_PROVIDER_SCD2()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
  -- Create a session-scoped staging table so the Stream is consumed once and
  -- the exact same change set feeds both the UPDATE and INSERT steps.
  CREATE OR REPLACE TEMPORARY TABLE PROVIDER_DELTA_TMP (
    provider_id VARCHAR,
    provider_name VARCHAR,
    primary_city VARCHAR,
    operating_zone VARCHAR,
    provider_tier VARCHAR,
    experience_level VARCHAR,
    active_status VARCHAR,
    primary_service_category VARCHAR,
    effective_at TIMESTAMP_TZ,
    attribute_hash VARCHAR
  );

  -- Begin one transaction so the old version cannot be closed unless its new
  -- version is also inserted successfully.
  BEGIN TRANSACTION;

  -- Materializing the stream once keeps the UPDATE and INSERT consistent and
  -- advances the stream offset only if the transaction commits successfully.
  INSERT INTO PROVIDER_DELTA_TMP
  SELECT
    payload:provider_id::VARCHAR,
    payload:provider_name::VARCHAR,
    INITCAP(TRIM(payload:primary_city::VARCHAR)),
    INITCAP(TRIM(payload:operating_zone::VARCHAR)),
    UPPER(TRIM(payload:provider_tier::VARCHAR)),
    UPPER(TRIM(payload:experience_level::VARCHAR)),
    UPPER(TRIM(payload:active_status::VARCHAR)),
    payload:primary_service_category::VARCHAR,
    TRY_TO_TIMESTAMP_TZ(payload:effective_at::VARCHAR),
    SHA2(CONCAT_WS('|',
      INITCAP(TRIM(payload:primary_city::VARCHAR)),
      INITCAP(TRIM(payload:operating_zone::VARCHAR)),
      UPPER(TRIM(payload:provider_tier::VARCHAR)),
      UPPER(TRIM(payload:experience_level::VARCHAR)),
      UPPER(TRIM(payload:active_status::VARCHAR)),
      payload:primary_service_category::VARCHAR
    ), 256)
  FROM PROVIDER_EVENTS_STREAM
  WHERE METADATA$ACTION = 'INSERT'
    AND payload:provider_id IS NOT NULL
    AND TRY_TO_TIMESTAMP_TZ(payload:effective_at::VARCHAR) IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY payload:provider_id::VARCHAR
    ORDER BY TRY_TO_TIMESTAMP_TZ(payload:record_updated_at::VARCHAR) DESC
  ) = 1;

  -- Close the current version at the exact start of the new half-open interval.
  UPDATE GOLD.DIM_PROVIDER_SCD2 current_row
  SET effective_end_at = incoming.effective_at,
      is_current = FALSE,
      updated_at = CURRENT_TIMESTAMP()
  FROM PROVIDER_DELTA_TMP incoming
  WHERE current_row.provider_id = incoming.provider_id
    AND current_row.is_current = TRUE
    AND current_row.attribute_hash <> incoming.attribute_hash
    AND incoming.effective_at > current_row.effective_start_at;

  -- Insert either a brand-new provider or the new version just created above.
  INSERT INTO GOLD.DIM_PROVIDER_SCD2 (
    provider_id, provider_name, primary_city, operating_zone, provider_tier,
    experience_level, active_status, primary_service_category,
    effective_start_at, effective_end_at, is_current, attribute_hash
  )
  SELECT
    incoming.provider_id,
    incoming.provider_name,
    incoming.primary_city,
    incoming.operating_zone,
    incoming.provider_tier,
    incoming.experience_level,
    incoming.active_status,
    incoming.primary_service_category,
    incoming.effective_at,
    '9999-12-31 00:00:00 +00:00'::TIMESTAMP_TZ,
    TRUE,
    incoming.attribute_hash
  FROM PROVIDER_DELTA_TMP incoming
  WHERE NOT EXISTS (
    SELECT 1
    FROM GOLD.DIM_PROVIDER_SCD2 current_row
    WHERE current_row.provider_id = incoming.provider_id
      AND current_row.is_current = TRUE
      AND current_row.attribute_hash = incoming.attribute_hash
  )
  AND NOT EXISTS (
    SELECT 1
    FROM GOLD.DIM_PROVIDER_SCD2 current_row
    WHERE current_row.provider_id = incoming.provider_id
      AND current_row.is_current = TRUE
      AND incoming.effective_at <= current_row.effective_start_at
  );

  -- Commit the SCD2 changes and advance the Stream offset only after both DML
  -- operations complete successfully.
  COMMIT;

  -- Return a human-readable outcome to Task history and manual callers.
  RETURN 'Provider SCD2 processing completed';
END;
$$;

-- Create a one-minute scheduled Task that calls the procedure only when the
-- provider Stream reports unconsumed rows; idle schedules do no DML work.
CREATE OR REPLACE TASK TASK_PROCESS_PROVIDER_SCD2
  WAREHOUSE = URBANASSIST_WH
  SCHEDULE = '1 MINUTE'
  COMMENT = 'Applies new provider snapshots to the SCD2 dimension'
  WHEN SYSTEM$STREAM_HAS_DATA('URBANASSIST_DB.OPS.PROVIDER_EVENTS_STREAM')
AS
  CALL SP_APPLY_PROVIDER_SCD2();

-- Resume the newly created Task. Snowflake creates Tasks suspended by default.
ALTER TASK TASK_PROCESS_PROVIDER_SCD2 RESUME;

-- Verify the Task is started and inspect its schedule, condition, owner, and
-- warehouse configuration.
SHOW TASKS LIKE 'TASK_PROCESS_PROVIDER_SCD2' IN SCHEMA URBANASSIST_DB.OPS;

-- Check run history of tasks
SELECT *
  FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    TASK_NAME => 'TASK_PROCESS_PROVIDER_SCD2',
    SCHEDULED_TIME_RANGE_START => DATEADD('HOUR', -1, CURRENT_TIMESTAMP())
  ))
  ORDER BY SCHEDULED_TIME DESC;