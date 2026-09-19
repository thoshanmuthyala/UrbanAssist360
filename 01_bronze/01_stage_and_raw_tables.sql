/*
===============================================================================
UrbanAssist 360 | Bronze 01 - JSON format, external stage, and raw tables
Run as: URBANASSIST_ENGINEER
===============================================================================
*/

-- Use the project role that owns the database and integration.
USE ROLE URBANASSIST_ENGINEER;

-- Select the project warehouse for LIST and later data-loading operations.
USE WAREHOUSE URBANASSIST_WH;

-- Select the project database containing all medallion schemas.
USE DATABASE URBANASSIST_DB;

-- Create stage-related objects in the operational schema.
USE SCHEMA OPS;

-- Define how Snowflake parses each gzip-compressed JSON Lines source file. Each
-- physical line becomes one VARIANT value in the first staged column ($1).
CREATE FILE FORMAT IF NOT EXISTS JSON_GZIP_FF
  TYPE = JSON
  COMPRESSION = AUTO
  STRIP_OUTER_ARRAY = FALSE
  COMMENT = 'JSON Lines input; gzip is detected automatically';

-- Create a named external stage pointing to the project root in S3. The stage
-- reuses both the IAM trust object and the JSON parsing rules defined above.
CREATE stage IF NOT EXISTS URBANASSIST_S3_STAGE
  URL = 's3://snowpro-bucket-8572/urbanassist/'
  STORAGE_INTEGRATION = URBANASSIST_S3_INT
  FILE_FORMAT = JSON_GZIP_FF
  COMMENT = 'External stage rooted at the UrbanAssist project prefix';

-- LIST is the fastest end-to-end check of the IAM trust and bucket policy.
-- A successful result proves Snowflake can see objects under the S3 prefix.
LIST @URBANASSIST_S3_STAGE;


-- Create the append-only booking landing table. The raw VARIANT preserves every
-- source attribute and the metadata columns identify the exact source record.
CREATE TABLE IF NOT EXISTS BRONZE.RAW_BOOKING_EVENTS (
  payload             VARIANT       NOT NULL,
  source_filename     VARCHAR       NOT NULL,
  source_row_number   NUMBER        NOT NULL,
  ingested_at         TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT uq_raw_booking_source UNIQUE (source_filename, source_row_number)
)
COMMENT = 'Append-only booking snapshots exactly as received from S3';

-- Create the append-only provider landing table. Multiple snapshots for one
-- provider are expected because Gold preserves attribute history with SCD2.
CREATE TABLE IF NOT EXISTS BRONZE.RAW_PROVIDER_EVENTS (
  payload             VARIANT       NOT NULL,
  source_filename     VARCHAR       NOT NULL,
  source_row_number   NUMBER        NOT NULL,
  ingested_at         TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT uq_raw_provider_source UNIQUE (source_filename, source_row_number)
)
COMMENT = 'Append-only provider snapshots used to build the SCD2 dimension';

-- Create the customer reference landing table used to build DIM_CUSTOMER.
CREATE TABLE IF NOT EXISTS BRONZE.RAW_CUSTOMERS (
  payload             VARIANT       NOT NULL,
  source_filename     VARCHAR       NOT NULL,
  source_row_number   NUMBER        NOT NULL,
  ingested_at         TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'One-time customer reference landing table';

-- Create the service-catalogue landing table used to build DIM_SERVICE.
CREATE TABLE IF NOT EXISTS BRONZE.RAW_SERVICES (
  payload             VARIANT       NOT NULL,
  source_filename     VARCHAR       NOT NULL,
  source_row_number   NUMBER        NOT NULL,
  ingested_at         TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'One-time service reference landing table';
