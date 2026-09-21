/*
===============================================================================
UrbanAssist 360 | Bronze 02 - Snowpipe auto-ingestion
Run as: URBANASSIST_ENGINEER

After creating the pipes, copy each NOTIFICATION_CHANNEL ARN from SHOW PIPES to
the corresponding S3 ObjectCreated event notification. See docs/RUNBOOK.md.
===============================================================================
*/

-- Use the role that owns the stage, raw tables, and pipes.
USE ROLE URBANASSIST_ENGINEER;

-- Select the project database so fully qualified monitoring calls are stable.
USE DATABASE URBANASSIST_DB;

-- Create both Snowpipes in the operational schema.
USE SCHEMA OPS;

-- Create the booking Snowpipe. S3 ObjectCreated notifications place messages on
-- this pipe's queue, and Snowpipe copies only matching JSON gzip objects from
-- the bookings prefix into the Bronze booking table.
CREATE PIPE IF NOT EXISTS BOOKING_EVENTS_PIPE
  AUTO_INGEST = TRUE
  COMMENT = 'Automatically loads JSON Lines booking snapshots from S3'
AS
COPY INTO BRONZE.RAW_BOOKING_EVENTS
  (payload, source_filename, source_row_number)
FROM (
  SELECT $1, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER
  FROM @URBANASSIST_S3_STAGE/bookings/
)
PATTERN = '.*[.]json[.]gz'
ON_ERROR = 'CONTINUE';

-- Create the provider Snowpipe with a separate prefix and notification channel
-- so provider changes can be observed independently of booking traffic.
CREATE PIPE IF NOT EXISTS PROVIDER_EVENTS_PIPE
  AUTO_INGEST = TRUE
  COMMENT = 'Automatically loads provider snapshots and changes from S3'
AS
COPY INTO BRONZE.RAW_PROVIDER_EVENTS
  (payload, source_filename, source_row_number)
FROM (
  SELECT $1, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER
  FROM @URBANASSIST_S3_STAGE/providers/
)
PATTERN = '.*[.]json[.]gz'
ON_ERROR = 'CONTINUE';

-- Display the two notification-channel ARNs. Copy each ARN into the matching S3
-- event notification configuration described in the runbook.
SHOW PIPES IN SCHEMA URBANASSIST_DB.OPS;

-- Use these functions after an upload to inspect queue and load status.
-- Check whether the booking pipe is running and whether it reports load errors.
SELECT SYSTEM$PIPE_STATUS('URBANASSIST_DB.OPS.BOOKING_EVENTS_PIPE') AS booking_pipe_status;

-- Check provider-pipe health independently from booking ingestion.
SELECT SYSTEM$PIPE_STATUS('URBANASSIST_DB.OPS.PROVIDER_EVENTS_PIPE') AS provider_pipe_status;
