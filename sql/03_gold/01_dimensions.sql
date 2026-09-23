/*
===============================================================================
UrbanAssist 360 | Gold 01 - Dimensions and initial provider state
Run as: URBANASSIST_ENGINEER

Only DIM_PROVIDER_SCD2 is Type 2. Customer and service attributes are maintained
as simple Type 1 dimensions so the project keeps one focused history pattern.
===============================================================================
*/

-- Use the project role that owns the Bronze, Silver, and Gold objects.
USE ROLE URBANASSIST_ENGINEER;

-- Supply compute for calendar generation, MERGE statements, and the initial
-- provider-dimension seed.
USE WAREHOUSE URBANASSIST_WH;

-- Select the shared project database.
USE DATABASE URBANASSIST_DB;

-- Create unqualified dimension names in the Gold schema.
USE SCHEMA GOLD;

-- Create the conformed calendar dimension. The numeric YYYYMMDD key is stable
-- and lets facts group consistently by business date attributes.
CREATE TABLE IF NOT EXISTS DIM_DATE (
  date_key       NUMBER       NOT NULL,
  full_date      DATE         NOT NULL,
  day_name       VARCHAR      NOT NULL,
  day_of_week    NUMBER       NOT NULL,
  week_number    NUMBER       NOT NULL,
  month_number   NUMBER       NOT NULL,
  month_name     VARCHAR      NOT NULL,
  quarter        NUMBER       NOT NULL,
  year           NUMBER       NOT NULL,
  is_weekend     BOOLEAN      NOT NULL,
  CONSTRAINT pk_dim_date PRIMARY KEY (date_key)
)
COMMENT = 'Calendar dimension covering 2025 through 2027';

-- Generate every date from 2025-01-01 through 2027-12-31 and insert dates that
-- are not already present. MERGE makes the population step safe to rerun.
MERGE INTO DIM_DATE target
USING (
  WITH generated_dates AS (
    SELECT DATEADD('DAY', ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2025-01-01'::DATE) AS full_date
    FROM TABLE(GENERATOR(ROWCOUNT => 1096))
  )
  SELECT
    TO_NUMBER(TO_CHAR(full_date, 'YYYYMMDD')) AS date_key,
    full_date,
    DAYNAME(full_date) AS day_name,
    DAYOFWEEKISO(full_date) AS day_of_week,
    WEEKISO(full_date) AS week_number,
    MONTH(full_date) AS month_number,
    MONTHNAME(full_date) AS month_name,
    QUARTER(full_date) AS quarter,
    YEAR(full_date) AS year,
    DAYOFWEEKISO(full_date) IN (6, 7) AS is_weekend
  FROM generated_dates
) source
ON target.date_key = source.date_key
WHEN NOT MATCHED THEN INSERT (
  date_key, full_date, day_name, day_of_week, week_number, month_number,
  month_name, quarter, year, is_weekend
) VALUES (
  source.date_key, source.full_date, source.day_name, source.day_of_week,
  source.week_number, source.month_number, source.month_name, source.quarter,
  source.year, source.is_weekend
);

-- Create the Type 1 customer dimension. customer_key is the warehouse surrogate
-- key; customer_id remains the stable identifier supplied by the business.
CREATE TABLE IF NOT EXISTS DIM_CUSTOMER (
  customer_key      NUMBER AUTOINCREMENT START 1 INCREMENT 1,
  customer_id       VARCHAR NOT NULL,
  customer_name     VARCHAR NOT NULL,
  customer_segment  VARCHAR NOT NULL,
  home_city         VARCHAR NOT NULL,
  signup_date       DATE,
  is_active         BOOLEAN NOT NULL,
  created_at        TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  updated_at        TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT pk_dim_customer PRIMARY KEY (customer_key),
  CONSTRAINT uq_dim_customer UNIQUE (customer_id)
)
COMMENT = 'Type 1 customer dimension';

-- Parse the most recently ingested record for each customer. Update an existing
-- row in place or insert a new row because customer history is out of scope.
MERGE INTO DIM_CUSTOMER target
USING (
  SELECT
    payload:customer_id::VARCHAR AS customer_id,
    payload:customer_name::VARCHAR AS customer_name,
    UPPER(payload:customer_segment::VARCHAR) AS customer_segment,
    INITCAP(payload:home_city::VARCHAR) AS home_city,
    TRY_TO_DATE(payload:signup_date::VARCHAR) AS signup_date,
    COALESCE(payload:is_active::BOOLEAN, TRUE) AS is_active
  FROM BRONZE.RAW_CUSTOMERS
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY payload:customer_id::VARCHAR
    ORDER BY ingested_at DESC, source_row_number DESC
  ) = 1
) source
ON target.customer_id = source.customer_id
WHEN MATCHED THEN UPDATE SET
  customer_name = source.customer_name,
  customer_segment = source.customer_segment,
  home_city = source.home_city,
  signup_date = source.signup_date,
  is_active = source.is_active,
  updated_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT
  (customer_id, customer_name, customer_segment, home_city, signup_date, is_active)
VALUES
  (source.customer_id, source.customer_name, source.customer_segment,
   source.home_city, source.signup_date, source.is_active);

-- Create the Type 1 service dimension used to describe each booked service and
-- provide catalogue benchmarks such as standard price and expected duration.
CREATE TABLE IF NOT EXISTS DIM_SERVICE (
  service_key                NUMBER AUTOINCREMENT START 1 INCREMENT 1,
  service_id                 VARCHAR NOT NULL,
  service_name               VARCHAR NOT NULL,
  service_category           VARCHAR NOT NULL,
  standard_price             NUMBER(12,2) NOT NULL,
  expected_duration_minutes  NUMBER NOT NULL,
  skill_level_required       VARCHAR NOT NULL,
  is_active                  BOOLEAN NOT NULL,
  created_at                 TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  updated_at                 TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT pk_dim_service PRIMARY KEY (service_key),
  CONSTRAINT uq_dim_service UNIQUE (service_id)
)
COMMENT = 'Type 1 service catalog dimension';

-- Parse the latest source row for each service, updating current catalogue
-- attributes in place and inserting previously unseen service IDs.
MERGE INTO DIM_SERVICE target
USING (
  SELECT
    payload:service_id::VARCHAR AS service_id,
    payload:service_name::VARCHAR AS service_name,
    payload:service_category::VARCHAR AS service_category,
    TRY_TO_DECIMAL(payload:standard_price::VARCHAR, 12, 2) AS standard_price,
    TRY_TO_NUMBER(payload:expected_duration_minutes::VARCHAR) AS expected_duration_minutes,
    UPPER(payload:skill_level_required::VARCHAR) AS skill_level_required,
    COALESCE(payload:is_active::BOOLEAN, TRUE) AS is_active
  FROM BRONZE.RAW_SERVICES
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY payload:service_id::VARCHAR
    ORDER BY ingested_at DESC, source_row_number DESC
  ) = 1
) source
ON target.service_id = source.service_id
WHEN MATCHED THEN UPDATE SET
  service_name = source.service_name,
  service_category = source.service_category,
  standard_price = source.standard_price,
  expected_duration_minutes = source.expected_duration_minutes,
  skill_level_required = source.skill_level_required,
  is_active = source.is_active,
  updated_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT
  (service_id, service_name, service_category, standard_price,
   expected_duration_minutes, skill_level_required, is_active)
VALUES
  (source.service_id, source.service_name, source.service_category,
   source.standard_price, source.expected_duration_minutes,
   source.skill_level_required, source.is_active);

-- Create the Type 2 provider dimension. provider_key identifies one historical
-- version; provider_id identifies the professional across all versions.
CREATE TABLE IF NOT EXISTS DIM_PROVIDER_SCD2 (
  provider_key              NUMBER AUTOINCREMENT START 1 INCREMENT 1,
  provider_id               VARCHAR NOT NULL,
  provider_name             VARCHAR NOT NULL,
  primary_city              VARCHAR NOT NULL,
  operating_zone            VARCHAR NOT NULL,
  provider_tier             VARCHAR NOT NULL,
  experience_level          VARCHAR NOT NULL,
  active_status             VARCHAR NOT NULL,
  primary_service_category  VARCHAR NOT NULL,
  effective_start_at        TIMESTAMP_TZ NOT NULL,
  effective_end_at          TIMESTAMP_TZ NOT NULL,
  is_current                BOOLEAN NOT NULL,
  attribute_hash            VARCHAR NOT NULL,
  created_at                TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  updated_at                TIMESTAMP_LTZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
  CONSTRAINT pk_dim_provider PRIMARY KEY (provider_key)
)
COMMENT = 'Provider dimension preserving changes to operational attributes';

-- Ensure the Silver provider table has materialized before the initial seed.
-- The live provider Stream is created later, after this historical baseline.
ALTER DYNAMIC TABLE SILVER.DT_PROVIDER_CHANGES_CLEAN REFRESH;

-- Seed one earliest valid state for every provider. Each baseline row is marked
-- current and stays open until a later provider event closes it.
INSERT INTO DIM_PROVIDER_SCD2 (
  provider_id, provider_name, primary_city, operating_zone, provider_tier,
  experience_level, active_status, primary_service_category,
  effective_start_at, effective_end_at, is_current, attribute_hash
)
SELECT
  source.provider_id,
  source.provider_name,
  source.primary_city,
  source.operating_zone,
  source.provider_tier,
  source.experience_level,
  source.active_status,
  source.primary_service_category,
  source.effective_at,
  '9999-12-31 00:00:00 +00:00'::TIMESTAMP_TZ,
  TRUE,
  source.attribute_hash
FROM (
  SELECT *
  FROM SILVER.DT_PROVIDER_CHANGES_CLEAN
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY provider_id
    ORDER BY effective_at, record_updated_at
  ) = 1
) source
WHERE NOT EXISTS (
  SELECT 1 FROM DIM_PROVIDER_SCD2 target
  WHERE target.provider_id = source.provider_id
);

-- Reconcile initial row counts across all four dimensions before enabling
-- incremental provider SCD2 processing.
SELECT 'DIM_DATE' AS object_name, COUNT(*) AS row_count FROM DIM_DATE
UNION ALL SELECT 'DIM_CUSTOMER', COUNT(*) FROM DIM_CUSTOMER
UNION ALL SELECT 'DIM_SERVICE', COUNT(*) FROM DIM_SERVICE
UNION ALL SELECT 'DIM_PROVIDER_SCD2', COUNT(*) FROM DIM_PROVIDER_SCD2
ORDER BY object_name;
