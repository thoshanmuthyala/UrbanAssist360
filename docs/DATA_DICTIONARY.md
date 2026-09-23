# Data dictionary and lineage

## Source record conventions

All source files are gzip-compressed JSON Lines. Every line is a complete JSON
object. Timestamps use UTC ISO-8601 strings, identifiers are stable strings, and
money values are expressed in INR.

`expected_sentiment` and `expected_complaint_category` in generated booking JSON
exist only to validate the deterministic data patterns. The Snowflake pipeline
does not select them into Silver or Gold and does not use them to generate AI
results.

## Bronze

All Bronze tables share four fields:

| Column | Type | Meaning |
|---|---|---|
| `payload` | `VARIANT` | Original source record |
| `source_filename` | `VARCHAR` | S3 object path reported by COPY metadata |
| `source_row_number` | `NUMBER` | Line number within the file |
| `ingested_at` | `TIMESTAMP_LTZ` | Snowflake landing time |

`RAW_BOOKING_EVENTS` is append-only and can contain several snapshots for one
`booking_id`. `RAW_PROVIDER_EVENTS` contains the initial provider state and later
changes. Customer and service raw tables are reference landings.

## Silver

### `DT_BOOKINGS_CLEAN`

Grain: one latest valid snapshot per `booking_id`.

The table parses JSON, normalizes text, validates required identifiers, converts
timestamps and amounts, rejects unsupported statuses, and chooses the greatest
`record_updated_at`. Ties are broken by ingestion time and source row number.

### `DT_PROVIDER_CHANGES_CLEAN`

Grain: one row per valid provider source event.

`attribute_hash` is SHA-256 over the six Type 2 tracked attributes: city, zone,
tier, experience level, active status, and primary service category.

## Gold dimensions

### `DIM_DATE`

Key: `date_key` in `YYYYMMDD` numeric form. Contains calendar attributes from
2025-01-01 through 2027-12-31.

### `DIM_CUSTOMER`

Key: generated `customer_key`. Natural key: `customer_id`. Type 1 attributes are
customer name, segment, home city, signup date, and active flag.

### `DIM_SERVICE`

Key: generated `service_key`. Natural key: `service_id`. Contains service name,
category, list price, expected duration, required skill level, and active flag.

### `DIM_PROVIDER_SCD2`

Key: generated `provider_key`. Natural key: `provider_id`.

The validity interval is half-open:

```text
effective_start_at <= booking_created_at < effective_end_at
```

The current version ends at `9999-12-31` and has `is_current = TRUE`. Exactly one
current version must exist for every provider.

## Gold facts

### `FACT_BOOKING`

Grain: one row per booking using the latest state.

| Column group | Columns |
|---|---|
| Keys | `booking_id`, `booking_date_key`, `customer_key`, `provider_key`, `service_key` |
| Status | `booking_status`, `payment_method` |
| Timestamps | created, scheduled, started, completed, updated |
| Money | `gross_amount`, `discount_amount`, `tax_amount`, `final_amount` |
| Measures | duration minutes, rating, completed count, cancelled count |
| Audit | `source_filename` |

### `FACT_REVIEW_INSIGHT`

Grain: one row per latest reviewed booking processed by Snowflake AI Functions.
The table keeps normalized labels and the complete function-result objects for
traceability. `review_hash` prevents unchanged reviews from being reprocessed.

### `DT_DAILY_SERVICE_KPI`

Grain: booking date × booking city × service category.

It materializes total, completed, and cancelled bookings; completion and
cancellation rates; revenue; rating; AI enrichment coverage; and negative-review
count.

## Lineage summary

```text
S3 bookings
  -> RAW_BOOKING_EVENTS
  -> DT_BOOKINGS_CLEAN
  -> FACT_BOOKING
  -> DT_DAILY_SERVICE_KPI

S3 provider events
  -> RAW_PROVIDER_EVENTS
  -> provider stream
  -> SP_APPLY_PROVIDER_SCD2
  -> DIM_PROVIDER_SCD2
  -> FACT_BOOKING

New booking reviews
  -> booking stream
  -> SP_ENRICH_NEW_REVIEWS
  -> FACT_REVIEW_INSIGHT
  -> DT_DAILY_SERVICE_KPI

Gold facts and dimensions
  -> URBANASSIST_OPERATIONS_SV
  -> UrbanAssist_Analyst tool
  -> URBANASSIST_OPERATIONS_AGENT
  -> Snowflake CoWork
```

