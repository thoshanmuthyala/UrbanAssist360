/*
===============================================================================
UrbanAssist 360 | Gold 03 - Historical and event-driven review AI enrichment
Run as: URBANASSIST_ENGINEER

AI functions consume credits. The historical backfill is deliberately capped at
1,000 reviews. Increase AI_BACKFILL_LIMIT only after reviewing account cost and
regional availability. The live task processes only reviews arriving later.
===============================================================================
*/

-- Use the role granted SNOWFLAKE.CORTEX_USER during account setup.
USE ROLE URBANASSIST_ENGINEER;

-- Supply compute for candidate selection, AI function calls, and Task runs.
USE WAREHOUSE URBANASSIST_WH;

-- Select the project database.
USE DATABASE URBANASSIST_DB;

-- Keep processing objects in OPS; the persisted AI result is fully qualified
-- into the Gold schema.
USE SCHEMA OPS;

-- Create one reusable enrichment row per reviewed booking. Raw function result
-- objects are retained beside normalized labels for traceability.
CREATE TABLE IF NOT EXISTS GOLD.FACT_REVIEW_INSIGHT (
  booking_id             VARCHAR NOT NULL,
  review_hash            VARCHAR NOT NULL,
  sentiment_label        VARCHAR,
  complaint_category     VARCHAR,
  review_summary         VARCHAR,
  sentiment_result       VARIANT,
  classification_result  VARIANT,
  model_source           VARCHAR NOT NULL,
  processed_at           TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT pk_fact_review_insight PRIMARY KEY (booking_id)
)
COMMENT = 'One AI-enrichment result per latest reviewed booking';

-- Cap the initial historical AI sample to control Cortex credit consumption.
-- Increase this value deliberately only after reviewing expected cost.
SET AI_BACKFILL_LIMIT = 1000;

-- Bring the latest booking snapshots current before choosing the backfill set.
ALTER DYNAMIC TABLE SILVER.DT_BOOKINGS_CLEAN REFRESH;

-- Backfill the latest 1,000 completed reviews. The review hash makes reruns
-- idempotent: unchanged text is not rescored or rewritten.
MERGE INTO GOLD.FACT_REVIEW_INSIGHT target
USING (
  WITH candidates AS (
    SELECT
      booking_id,
      review_text,
      SHA2(review_text, 256) AS review_hash
    FROM SILVER.DT_BOOKINGS_CLEAN
    WHERE review_text IS NOT NULL
      AND booking_status = 'COMPLETED'
    QUALIFY ROW_NUMBER() OVER (ORDER BY booking_created_at DESC, booking_id) <= $AI_BACKFILL_LIMIT
  ), scored AS (
    SELECT
      booking_id,
      review_hash,
      AI_SENTIMENT(review_text) AS sentiment_result,
      AI_CLASSIFY(
        review_text,
        ['Punctuality', 'Service Quality', 'Professionalism', 'Pricing',
         'Communication', 'No Complaint', 'Other'],
        {'task_description': 'Classify the main operational theme in a home-service customer review.'}
      ) AS classification_result
    FROM candidates
  )
  SELECT
    booking_id,
    review_hash,
    sentiment_result:categories[0]:sentiment::VARCHAR AS sentiment_label,
    classification_result:labels[0]::VARCHAR AS complaint_category,
    sentiment_result,
    classification_result
  FROM scored
) source
ON target.booking_id = source.booking_id
WHEN MATCHED AND target.review_hash <> source.review_hash THEN UPDATE SET
  review_hash = source.review_hash,
  sentiment_label = source.sentiment_label,
  complaint_category = source.complaint_category,
  sentiment_result = source.sentiment_result,
  classification_result = source.classification_result,
  model_source = 'SNOWFLAKE_AI_FUNCTIONS',
  processed_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
  booking_id, review_hash, sentiment_label, complaint_category,
  sentiment_result, classification_result, model_source
) VALUES (
  source.booking_id, source.review_hash, source.sentiment_label,
  source.complaint_category, source.sentiment_result,
  source.classification_result, 'SNOWFLAKE_AI_FUNCTIONS'
);

-- Create the stream after the historical backfill. IF NOT EXISTS preserves the
-- current offset if the setup file is reopened later.
CREATE STREAM IF NOT EXISTS BOOKING_REVIEW_STREAM
  ON TABLE BRONZE.RAW_BOOKING_EVENTS
  APPEND_ONLY = TRUE
  SHOW_INITIAL_ROWS = FALSE
  COMMENT = 'Booking changes that arrive after historical AI initialization';

-- Create an owner-rights procedure for reviews that arrive after the backfill.
-- It consumes the Stream transactionally and persists only changed review text.
CREATE OR REPLACE PROCEDURE SP_ENRICH_NEW_REVIEWS()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
  -- Create a session-scoped staging table for the latest review text observed
  -- for each booking in the current Stream batch.
  CREATE OR REPLACE TEMPORARY TABLE REVIEW_DELTA_TMP (
    booking_id VARCHAR,
    review_text VARCHAR,
    review_hash VARCHAR
  );

  -- Keep Stream consumption and Gold upsert atomic. A failure rolls back the DML
  -- and leaves the Stream rows available for the next Task attempt.
  BEGIN TRANSACTION;

  -- Materialize only inserted rows with nonblank review text. When several
  -- snapshots for one booking arrive together, retain the latest source update.
  INSERT INTO REVIEW_DELTA_TMP
  SELECT
    payload:booking_id::VARCHAR,
    NULLIF(TRIM(payload:review_text::VARCHAR), ''),
    SHA2(NULLIF(TRIM(payload:review_text::VARCHAR), ''), 256)
  FROM BOOKING_REVIEW_STREAM
  WHERE METADATA$ACTION = 'INSERT'
    AND NULLIF(TRIM(payload:review_text::VARCHAR), '') IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY payload:booking_id::VARCHAR
    ORDER BY TRY_TO_TIMESTAMP_TZ(payload:record_updated_at::VARCHAR) DESC
  ) = 1;

  -- Exclude review hashes already stored, call AI_SENTIMENT and AI_CLASSIFY for
  -- new text, then update or insert the one Gold result for each booking.
  MERGE INTO GOLD.FACT_REVIEW_INSIGHT target
  USING (
    WITH changed_reviews AS (
      SELECT delta.*
      FROM REVIEW_DELTA_TMP delta
      LEFT JOIN GOLD.FACT_REVIEW_INSIGHT existing
        ON existing.booking_id = delta.booking_id
       AND existing.review_hash = delta.review_hash
      WHERE existing.booking_id IS NULL
    ), scored AS (
      SELECT
        booking_id,
        review_hash,
        AI_SENTIMENT(review_text) AS sentiment_result,
        AI_CLASSIFY(
          review_text,
          ['Punctuality', 'Service Quality', 'Professionalism', 'Pricing',
           'Communication', 'No Complaint', 'Other'],
          {'task_description': 'Classify the main operational theme in a home-service customer review.'}
        ) AS classification_result
      FROM changed_reviews
    )
    SELECT
      booking_id,
      review_hash,
      sentiment_result:categories[0]:sentiment::VARCHAR AS sentiment_label,
      classification_result:labels[0]::VARCHAR AS complaint_category,
      sentiment_result,
      classification_result
    FROM scored
  ) source
  ON target.booking_id = source.booking_id
  WHEN MATCHED THEN UPDATE SET
    review_hash = source.review_hash,
    sentiment_label = source.sentiment_label,
    complaint_category = source.complaint_category,
    sentiment_result = source.sentiment_result,
    classification_result = source.classification_result,
    model_source = 'SNOWFLAKE_AI_FUNCTIONS',
    processed_at = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT (
    booking_id, review_hash, sentiment_label, complaint_category,
    sentiment_result, classification_result, model_source
  ) VALUES (
    source.booking_id, source.review_hash, source.sentiment_label,
    source.complaint_category, source.sentiment_result,
    source.classification_result, 'SNOWFLAKE_AI_FUNCTIONS'
  );

  -- Commit the AI results and advance the Stream offset together.
  COMMIT;

  -- Return a readable procedure outcome for manual calls and Task history.
  RETURN 'New review enrichment completed';
END;
$$;

-- Create a one-minute Task that runs only while the review Stream has data.
CREATE OR REPLACE TASK TASK_ENRICH_NEW_REVIEWS
  WAREHOUSE = URBANASSIST_WH
  SCHEDULE = '1 MINUTE'
  COMMENT = 'Uses Snowflake AI functions for newly arrived customer reviews'
  WHEN SYSTEM$STREAM_HAS_DATA('URBANASSIST_DB.OPS.BOOKING_REVIEW_STREAM')
AS
  CALL SP_ENRICH_NEW_REVIEWS();

-- Start the Task; newly created Snowflake Tasks are suspended by default.
ALTER TASK TASK_ENRICH_NEW_REVIEWS RESUME;

-- Summarize the stored sentiment and complaint labels to confirm that the
-- historical backfill produced analytically usable results.
SELECT sentiment_label, complaint_category, COUNT(*) AS review_count
FROM GOLD.FACT_REVIEW_INSIGHT
GROUP BY ALL
ORDER BY review_count DESC;
