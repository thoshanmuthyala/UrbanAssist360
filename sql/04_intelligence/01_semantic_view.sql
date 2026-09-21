/*
===============================================================================
UrbanAssist 360 | Intelligence 01 - Semantic View for Cortex Analyst
Run as: URBANASSIST_ENGINEER

REFERENCE/FALLBACK: The primary project path creates this object through the
Snowsight UI. Follow sections 17-19 of docs/RUNBOOK.md. Run this file only when
you deliberately choose SQL-based creation or need to compare UI output.

The semantic graph mirrors the physical star schema. Metrics stay attached to
their natural fact table to avoid fanout and ambiguous aggregation.
===============================================================================
*/

-- Use the project role that owns the Gold model and Intelligence schema.
USE ROLE URBANASSIST_ENGINEER;

-- Select compute that Cortex Analyst-generated SQL is allowed to use.
USE WAREHOUSE URBANASSIST_WH;

-- Select the project database.
USE DATABASE URBANASSIST_DB;

-- Create the governed analytical object in the Intelligence schema.
USE SCHEMA INTELLIGENCE;

-- Define the business vocabulary exposed to Cortex Analyst. This single command
-- maps physical Gold tables to logical entities, joins, facts, dimensions,
-- metrics, instructions, and steward-approved example questions.
CREATE OR REPLACE SEMANTIC VIEW URBANASSIST_OPERATIONS_SV
  -- Register each Gold table and its business key in the semantic graph.
  TABLES (
    bookings AS URBANASSIST_DB.GOLD.FACT_BOOKING
      PRIMARY KEY (booking_id)
      WITH SYNONYMS ('bookings', 'appointments', 'jobs', 'orders')
      COMMENT = 'One row per latest booking state',
    dates AS URBANASSIST_DB.GOLD.DIM_DATE
      PRIMARY KEY (date_key)
      COMMENT = 'Calendar attributes for the booking creation date',
    customers AS URBANASSIST_DB.GOLD.DIM_CUSTOMER
      PRIMARY KEY (customer_key)
      COMMENT = 'Customer profile at its current Type 1 state',
    providers AS URBANASSIST_DB.GOLD.DIM_PROVIDER_SCD2
      PRIMARY KEY (provider_key)
      COMMENT = 'Historical provider version effective for each booking',
    services AS URBANASSIST_DB.GOLD.DIM_SERVICE
      PRIMARY KEY (service_key)
      WITH SYNONYMS ('services', 'offerings')
      COMMENT = 'Home-service catalog',
    reviews AS URBANASSIST_DB.GOLD.FACT_REVIEW_INSIGHT
      PRIMARY KEY (booking_id)
      COMMENT = 'AI-derived insight for reviewed bookings'
  )

  -- Declare valid join paths so generated SQL cannot invent relationships.
  RELATIONSHIPS (
    bookings_to_dates AS bookings(booking_date_key) REFERENCES dates,
    bookings_to_customers AS bookings(customer_key) REFERENCES customers,
    bookings_to_providers AS bookings(provider_key) REFERENCES providers,
    bookings_to_services AS bookings(service_key) REFERENCES services,
    reviews_to_bookings AS reviews(booking_id) REFERENCES bookings
  )

  -- Expose row-level numeric inputs from which governed metrics are calculated.
  FACTS (
    bookings.gross_amount AS gross_amount,
    bookings.discount_amount AS discount_amount,
    bookings.final_amount AS final_amount,
    bookings.rating AS rating,
    bookings.service_duration_minutes AS service_duration_minutes,
    bookings.completed_flag AS completed_booking_count,
    bookings.cancelled_flag AS cancelled_booking_count
  )

  -- Expose descriptive fields used for filtering, grouping, and user language.
  DIMENSIONS (
    bookings.booking_id AS booking_id COMMENT = 'Unique booking identifier',
    bookings.booking_city AS booking_city
      WITH SYNONYMS = ('city', 'market')
      COMMENT = 'City where the service was requested',
    bookings.booking_status AS booking_status
      WITH SYNONYMS = ('status', 'job status'),
    bookings.payment_method AS payment_method,
    dates.booking_date AS full_date
      WITH SYNONYMS = ('date', 'booking date'),
    dates.day_name AS day_name,
    dates.month_name AS month_name,
    dates.quarter AS quarter,
    dates.year AS year,
    dates.is_weekend AS is_weekend,
    customers.customer_segment AS customer_segment
      WITH SYNONYMS = ('segment', 'customer type'),
    customers.customer_home_city AS home_city,
    providers.provider_id AS provider_id,
    providers.provider_name AS provider_name
      WITH SYNONYMS = ('professional', 'partner'),
    providers.provider_city AS primary_city,
    providers.operating_zone AS operating_zone,
    providers.provider_tier AS provider_tier
      WITH SYNONYMS = ('tier', 'provider level'),
    providers.experience_level AS experience_level,
    providers.active_status AS active_status,
    services.service_name AS service_name,
    services.service_category AS service_category
      WITH SYNONYMS = ('category', 'service type'),
    services.skill_level_required AS skill_level_required,
    reviews.sentiment AS sentiment_label
      WITH SYNONYMS = ('sentiment', 'customer mood'),
    reviews.complaint_theme AS complaint_category
      WITH SYNONYMS = ('complaint', 'issue', 'review category')
  )

  -- Centralize aggregation formulas so Analyst answers use consistent business
  -- definitions for bookings, rates, revenue, ratings, and AI review counts.
  METRICS (
    bookings.total_bookings AS COUNT(booking_id)
      COMMENT = 'Number of distinct bookings',
    bookings.completed_bookings AS SUM(bookings.completed_flag)
      COMMENT = 'Number of bookings whose latest status is completed',
    bookings.cancelled_bookings AS SUM(bookings.cancelled_flag)
      COMMENT = 'Number of bookings whose latest status is cancelled',
    bookings.completion_rate AS SUM(bookings.completed_flag) / NULLIF(COUNT(booking_id), 0)
      COMMENT = 'Completed bookings divided by all bookings',
    bookings.cancellation_rate AS SUM(bookings.cancelled_flag) / NULLIF(COUNT(booking_id), 0)
      COMMENT = 'Cancelled bookings divided by all bookings',
    bookings.gross_revenue AS SUM(bookings.gross_amount)
      WITH SYNONYMS = ('gross sales', 'GMV'),
    bookings.net_revenue AS SUM(bookings.final_amount)
      WITH SYNONYMS = ('revenue', 'sales', 'earnings'),
    bookings.average_booking_value AS AVG(bookings.final_amount)
      WITH SYNONYMS = ('ABV', 'average order value'),
    bookings.average_rating AS AVG(bookings.rating),
    bookings.average_service_duration AS AVG(bookings.service_duration_minutes),
    reviews.enriched_review_count AS COUNT(booking_id)
      COMMENT = 'Number of reviews processed by Snowflake AI Functions',
    reviews.negative_review_count AS COUNT_IF(sentiment_label = 'negative')
      COMMENT = 'Number of AI-enriched reviews with negative overall sentiment'
  )

  -- Store a human-readable object description for catalogue discovery.
  COMMENT = 'Governed operational analytics for the UrbanAssist home-services marketplace'

  -- Guide formatting and time-column selection in generated SQL.
  AI_SQL_GENERATION 'Round rates to four decimals and currency metrics to two decimals. Use booking creation date unless the user explicitly requests another timestamp.'

  -- Define the scope boundary and clarification behavior for user questions.
  AI_QUESTION_CATEGORIZATION 'This model covers bookings, customers, services, provider history, revenue, ratings, cancellations, service duration, and enriched review sentiment. Ask for clarification when a time period or comparison group is ambiguous.'

  -- Provide steward-reviewed question-to-SQL pairs that improve reliability for
  -- two representative marketplace questions.
  AI_VERIFIED_QUERIES (
    cancellation_rate_by_city AS (
      QUESTION 'What is the cancellation rate by city?'
      VERIFIED_AT 1789142400
      ONBOARDING_QUESTION TRUE
      VERIFIED_BY '(STEWARD = urbanassist_data_team)'
      SQL 'SELECT booking_city, SUM(cancelled_booking_count) / NULLIF(COUNT(*), 0) AS cancellation_rate FROM URBANASSIST_DB.GOLD.FACT_BOOKING GROUP BY booking_city ORDER BY cancellation_rate DESC'
    ),
    revenue_by_service_category AS (
      QUESTION 'Which service category generated the most revenue?'
      VERIFIED_AT 1789142400
      ONBOARDING_QUESTION TRUE
      VERIFIED_BY '(STEWARD = urbanassist_data_team)'
      SQL 'SELECT s.service_category, SUM(b.final_amount) AS net_revenue FROM URBANASSIST_DB.GOLD.FACT_BOOKING b JOIN URBANASSIST_DB.GOLD.DIM_SERVICE s ON b.service_key = s.service_key GROUP BY s.service_category ORDER BY net_revenue DESC'
    )
  );

-- A direct semantic query must succeed before the view is attached to an agent.
-- It validates the city dimension and the governed booking/rate metrics together.
SELECT *
FROM SEMANTIC_VIEW(
  URBANASSIST_OPERATIONS_SV
  DIMENSIONS bookings.booking_city
  METRICS bookings.total_bookings, bookings.cancellation_rate
)
ORDER BY cancellation_rate DESC;

-- Confirm object creation and inspect its owner and metadata.
SHOW SEMANTIC VIEWS IN SCHEMA URBANASSIST_DB.INTELLIGENCE;
