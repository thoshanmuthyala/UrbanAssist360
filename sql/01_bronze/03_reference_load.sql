/*
===============================================================================
UrbanAssist 360 | Bronze 03 - Initial reference loads and Snowpipe recovery
Run as: URBANASSIST_ENGINEER

Upload customers.json.gz and services.json.gz before running this file.
Snowpipe handles bookings and providers. ALTER PIPE REFRESH queues recent files
that existed before event notifications were configured.
===============================================================================
*/

-- Use the role that owns the stage, pipes, and raw tables.
USE ROLE URBANASSIST_ENGINEER;

-- Resume the project warehouse if needed for the explicit COPY statements.
USE WAREHOUSE URBANASSIST_WH;

-- Select the project database that contains Bronze and OPS.
USE DATABASE URBANASSIST_DB;

-- Use OPS so stage and pipe names can remain unqualified.
USE SCHEMA OPS;

-- Load the customer reference file once. ABORT_STATEMENT prevents a partially
-- accepted customer master when any row in the file cannot be loaded.
COPY INTO BRONZE.RAW_CUSTOMERS
  (payload, source_filename, source_row_number)
FROM (
  SELECT $1, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER
  FROM @URBANASSIST_S3_STAGE/reference/customers/
)
PATTERN = '.*customers[.]json[.]gz'
ON_ERROR = 'ABORT_STATEMENT';

-- Load the service catalogue with the same all-or-nothing error policy.
COPY INTO BRONZE.RAW_SERVICES
  (payload, source_filename, source_row_number)
FROM (
  SELECT $1, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER
  FROM @URBANASSIST_S3_STAGE/reference/services/
)
PATTERN = '.*services[.]json[.]gz'
ON_ERROR = 'ABORT_STATEMENT';

-- Safe recovery for files uploaded shortly before the notification was active.
-- ALTER PIPE REFRESH considers only recent staged files; it is not a backfill
-- mechanism for arbitrarily old objects.
ALTER PIPE BOOKING_EVENTS_PIPE REFRESH;

-- Queue recently staged provider objects that predate the S3 event setup.
ALTER PIPE PROVIDER_EVENTS_PIPE REFRESH;

-- Reconcile the four Bronze tables after initial loading. Booking and provider
-- counts are physical snapshots, while customer and service counts are masters.
SELECT 'RAW_CUSTOMERS' AS object_name, COUNT(*) AS row_count FROM BRONZE.RAW_CUSTOMERS
UNION ALL
SELECT 'RAW_SERVICES', COUNT(*) FROM BRONZE.RAW_SERVICES
UNION ALL
SELECT 'RAW_BOOKING_EVENTS', COUNT(*) FROM BRONZE.RAW_BOOKING_EVENTS
UNION ALL
SELECT 'RAW_PROVIDER_EVENTS', COUNT(*) FROM BRONZE.RAW_PROVIDER_EVENTS
ORDER BY object_name;

-- Show rejected rows, if any, from the last 24 hours.
-- COPY_HISTORY exposes status and error details for recent booking loads.
SELECT *
FROM TABLE(
  INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'URBANASSIST_DB.BRONZE.RAW_BOOKING_EVENTS',
    START_TIME => DATEADD('HOUR', -24, CURRENT_TIMESTAMP())
  )
)
ORDER BY LAST_LOAD_TIME DESC;
