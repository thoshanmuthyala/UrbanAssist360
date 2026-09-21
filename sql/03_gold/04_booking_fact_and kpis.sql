/*
===============================================================================
UrbanAssist 360 | Gold 04 - Booking fact and daily KPI Dynamic Tables
Run as: URBANASSIST_ENGINEER

FACT_BOOKING resolves each booking to the provider version effective when the
booking was created. Half-open SCD2 intervals prevent boundary double matches.
===============================================================================
*/

-- Use the project role that owns the Silver inputs and Gold dimensions.
USE ROLE URBANASSIST_ENGINEER;

-- Supply compute for initial and incremental Dynamic Table refreshes.
USE WAREHOUSE URBANASSIST_WH;

-- Select the project database.
USE DATABASE URBANASSIST_DB;

-- Create the fact and aggregate in the Gold schema.
USE SCHEMA GOLD;

-- Build one fact row per latest logical booking. Natural source IDs are resolved
-- to dimension surrogate keys; provider_key is selected by the provider version
-- interval effective at booking creation time.
CREATE OR REPLACE DYNAMIC TABLE FACT_BOOKING
  TARGET_LAG = '5 MINUTES'
  WAREHOUSE = URBANASSIST_WH
  REFRESH_MODE = AUTO
  COMMENT = 'Fact grain: one row per booking using the latest booking state'
AS
SELECT
  booking.booking_id,
  TO_NUMBER(TO_CHAR(booking.booking_created_at::DATE, 'YYYYMMDD')) AS booking_date_key,
  customer.customer_key,
  provider.provider_key,
  service.service_key,
  booking.booking_city,
  booking.booking_status,
  booking.payment_method,
  booking.booking_created_at,
  booking.scheduled_at,
  booking.service_started_at,
  booking.service_completed_at,
  booking.gross_amount,
  booking.discount_amount,
  booking.tax_amount,
  booking.final_amount,
  CASE
    WHEN booking.service_started_at IS NOT NULL
     AND booking.service_completed_at IS NOT NULL
    THEN DATEDIFF('MINUTE', booking.service_started_at, booking.service_completed_at)
  END AS service_duration_minutes,
  booking.rating,
  IFF(booking.booking_status = 'COMPLETED', 1, 0) AS completed_booking_count,
  IFF(booking.booking_status = 'CANCELLED', 1, 0) AS cancelled_booking_count,
  booking.record_updated_at,
  booking.source_filename
FROM SILVER.DT_BOOKINGS_CLEAN booking
LEFT JOIN DIM_CUSTOMER customer
  ON customer.customer_id = booking.customer_id
LEFT JOIN DIM_SERVICE service
  ON service.service_id = booking.service_id
LEFT JOIN DIM_PROVIDER_SCD2 provider
  ON provider.provider_id = booking.provider_id
 AND booking.booking_created_at >= provider.effective_start_at
 AND booking.booking_created_at < provider.effective_end_at;

-- Build a reusable operational aggregate at date x city x service-category
-- grain, including booking, revenue, rating, and AI-review measures.
CREATE OR REPLACE DYNAMIC TABLE DT_DAILY_SERVICE_KPI
  TARGET_LAG = '10 MINUTES'
  WAREHOUSE = URBANASSIST_WH
  REFRESH_MODE = AUTO
  COMMENT = 'Daily operational KPIs by city and service category'
AS
SELECT
  booking.booking_date_key,
  date_dim.full_date AS booking_date,
  booking.booking_city,
  service.service_category,
  COUNT(*) AS total_bookings,
  SUM(booking.completed_booking_count) AS completed_bookings,
  SUM(booking.cancelled_booking_count) AS cancelled_bookings,
  ROUND(SUM(booking.completed_booking_count) / NULLIF(COUNT(*), 0), 4) AS completion_rate,
  ROUND(SUM(booking.cancelled_booking_count) / NULLIF(COUNT(*), 0), 4) AS cancellation_rate,
  ROUND(SUM(booking.final_amount), 2) AS total_revenue,
  ROUND(AVG(booking.rating), 2) AS average_rating,
  COUNT(review.booking_id) AS enriched_review_count,
  COUNT_IF(review.sentiment_label = 'negative') AS negative_review_count
FROM FACT_BOOKING booking
JOIN DIM_DATE date_dim
  ON date_dim.date_key = booking.booking_date_key
JOIN DIM_SERVICE service
  ON service.service_key = booking.service_key
LEFT JOIN FACT_REVIEW_INSIGHT review
  ON review.booking_id = booking.booking_id
GROUP BY ALL;

-- Manual refreshes make development and demonstrations deterministic. Scheduled
-- refreshes continue automatically afterward according to each target lag.
ALTER DYNAMIC TABLE FACT_BOOKING REFRESH;

-- Refresh the dependent daily aggregate after its booking fact is current.
ALTER DYNAMIC TABLE DT_DAILY_SERVICE_KPI REFRESH;

-- Confirm the fact contains the expected number of logical bookings.
SELECT COUNT(*) AS fact_booking_rows FROM FACT_BOOKING;

-- Preview the most recent daily KPI rows for a quick business-level smoke test.
SELECT * FROM DT_DAILY_SERVICE_KPI ORDER BY booking_date DESC, total_revenue DESC LIMIT 20;
