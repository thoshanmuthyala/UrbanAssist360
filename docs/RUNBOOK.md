# UrbanAssist 360 implementation runbook

This runbook builds the project directly in Snowflake and uses a Git-connected
Snowflake Workspace for development. Execute the stages in order. Each checkpoint
must pass before continuing because later objects depend on earlier state.

## 1. Prerequisites

### Snowflake

- An account on AWS or a Snowflake region allowed to read the selected S3 bucket
- `ACCOUNTADMIN` access for initial grants and Snowflake CoWork configuration
- Permission to create a storage integration
- Cortex AI Functions available locally, or an approved cross-region inference
  policy
- Cortex Agents and Snowflake CoWork enabled for the account
- A user with a default role and default warehouse

### AWS

- An S3 bucket in an approved region
- Permission to create or modify an IAM policy and role
- Permission to create S3 event notifications
- No existing event notification with an overlapping `urbanassist/bookings/` or
  `urbanassist/providers/` prefix

### GitHub

- A non-empty repository with at least one branch
- A development branch, for example `feature/urbanassist360-snowflake-dev`
- Permission to authorize the Snowflake GitHub App for the repository
- A Snowflake Git API integration that allows the repository HTTPS URL

Never place AWS keys, Snowflake passwords, GitHub tokens, or private keys in this
repository or in SQL comments.

## 2. Prepare the Git-connected Snowflake Workspace

1. Add the `urbanassist360-snowflake-dev` folder to the GitHub repository.
2. Commit and push it to the intended development branch. Snowflake cannot create
   a Git Workspace from an empty repository.
3. From a regular Snowsight SQL worksheet, run the commands in the README's
   **Connect GitHub to a Snowflake Workspace** section. This creates
   `URBANASSIST_GITHUB_API_INT` and grants it to `URBANASSIST_ENGINEER`. If the
   role does not exist yet, copy and run `sql/00_setup/01_account_and_roles.sql`
   from the GitHub file view first.
4. In Snowsight, open **Projects → Workspaces**.
5. Choose **From Git repository**.
6. Paste the repository HTTPS URL.
7. Select `URBANASSIST_GITHUB_API_INT`.
8. Complete the Snowflake GitHub App authorization and create the Workspace.
9. Open **Changes**, fetch all branches if needed, and switch to the project
   branch.
10. Confirm that `urbanassist360-snowflake-dev/sql/00_setup/01_account_and_roles.sql` opens as
    a SQL file.

The Workspace is the development surface. Running a SQL file executes it against
the role, warehouse, database, and schema selected by the statements in that
file. Git synchronization versions the files; it does not deploy Snowflake
objects automatically.

## 3. Generate and separate the source data

The repository includes generated files. To reproduce them, run from the project
root in any standard Python 3 environment:

```bash
python3 scripts/generate_data.py
```

No third-party Python package is required. The manifest is a lightweight source
inventory containing file names, physical record counts, and file sizes; it is
not loaded by the Snowflake pipeline.

Separate the upload into two groups.

### Initial files

```text
reference/customers.json.gz
reference/services.json.gz
providers/provider_initial.json.gz
bookings/booking_batch_001.json.gz
bookings/booking_batch_002.json.gz
bookings/booking_batch_003.json.gz
bookings/booking_batch_004.json.gz
bookings/booking_batch_005.json.gz
```

### Held-back live files

```text
providers/provider_changes_live.json.gz
bookings/booking_live_batch.json.gz
```

Do not upload the held-back files until the streams and Tasks have been created.

## 4. Create the S3 prefix

Create or reuse one bucket, then create these object-key prefixes:

```text
urbanassist/bookings/
urbanassist/providers/
urbanassist/reference/customers/
urbanassist/reference/services/
```

The prefix names are part of the SQL contract. If they change, update the stage
paths in `sql/01_bronze/02_snowpipe_auto_ingest.sql`,
`sql/01_bronze/03_initial_reference_load.sql`, and
`sql/05_operations/02_live_event_demo.sql`.

Recommended bucket controls:

- Block public access.
- Enable default server-side encryption.
- Enable bucket versioning when organizational policy requires recovery.
- Add a lifecycle policy only if the source-retention requirement is known.
- Keep Snowflake access read-only for this project.

## 5. Create the AWS IAM policy and role

Attach a least-privilege policy like the following to a dedicated IAM role.
Replace `<bucket>` with the exact bucket name.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListUrbanAssistPrefix",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::<bucket>",
      "Condition": {
        "StringLike": {
          "s3:prefix": ["urbanassist/*"]
        }
      }
    },
    {
      "Sid": "ReadUrbanAssistObjects",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:GetObjectVersion"],
      "Resource": "arn:aws:s3:::<bucket>/urbanassist/*"
    }
  ]
}
```

Create the role with a temporary trusted principal permitted by your AWS
administration process. Copy the role ARN. The final trust relationship cannot
be completed until Snowflake returns its IAM user ARN and external ID.

## 6. Create Snowflake account objects

Open `sql/00_setup/01_account_and_roles.sql`. If it was already run to prepare
the Git-connected Workspace, rerun it to confirm the idempotent setup and final
session-context check.

1. Replace `<YOUR_SNOWFLAKE_USER>` with the exact Snowflake user identifier.
2. Run the account-admin section.
3. Continue through the project-role section.
4. Confirm the final query reports:
   - `URBANASSIST_ENGINEER`
   - `URBANASSIST_WH`
   - `URBANASSIST_DB`

The script grants the project role to `SYSADMIN` so account administrators can
manage objects through the normal custom-role hierarchy.

## 7. Complete the Snowflake–AWS trust relationship

Open `sql/00_setup/02_s3_storage_integration.sql`.

1. Replace `<AWS_ROLE_ARN>` with the dedicated role ARN.
2. Replace `<S3_BUCKET_NAME>` with the exact bucket.
3. Run the script.
4. From `DESC INTEGRATION`, copy:
   - `STORAGE_AWS_IAM_USER_ARN`
   - `STORAGE_AWS_EXTERNAL_ID`
5. Replace the IAM role's temporary trust policy with:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "<STORAGE_AWS_IAM_USER_ARN>"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "<STORAGE_AWS_EXTERNAL_ID>"
        }
      }
    }
  ]
}
```

Do not omit the external-ID condition. It binds role assumption to the intended
Snowflake integration.

## 8. Create and verify the stage

Open `sql/01_bronze/01_stage_and_raw_tables.sql`.

1. Replace `<S3_BUCKET_NAME>`.
2. Run the file.
3. `LIST @URBANASSIST_S3_STAGE` may be empty before upload, but it must not return
   an authorization error.
4. Confirm all four Bronze tables exist.

The script uses `IF NOT EXISTS` for persistent landing objects to protect data
if the file is reopened. To intentionally change a stage or file-format property,
use an explicit `ALTER` or reviewed replacement statement.

## 9. Create Snowpipes and S3 event notifications

Open `sql/01_bronze/02_snowpipe_auto_ingest.sql` and run it.

`SHOW PIPES` returns a `notification_channel` ARN. Snowflake commonly shares a
managed SQS queue among pipes in the same account and AWS region, so the two ARNs
may be identical.

In the S3 bucket, create ObjectCreated notifications:

### Booking notification

- Event: all object-create events
- Prefix: `urbanassist/bookings/`
- Suffix: `.json.gz`
- Destination: SQS queue
- Queue ARN: booking pipe `notification_channel`

### Provider notification

- Event: all object-create events
- Prefix: `urbanassist/providers/`
- Suffix: `.json.gz`
- Destination: SQS queue
- Queue ARN: provider pipe `notification_channel`

AWS rejects overlapping notification filters. Resolve any pre-existing filter
before proceeding; do not broaden these two prefixes to `urbanassist/`.

Check both `SYSTEM$PIPE_STATUS` results. `executionState` should be running and
the notification channel should not report a configuration error.

## 10. Upload the initial files

Upload the initial files to these exact keys:

| Local file | S3 object key |
|---|---|
| `reference/customers.json.gz` | `urbanassist/reference/customers/customers.json.gz` |
| `reference/services.json.gz` | `urbanassist/reference/services/services.json.gz` |
| `providers/provider_initial.json.gz` | `urbanassist/providers/provider_initial.json.gz` |
| `bookings/booking_batch_*.json.gz` | `urbanassist/bookings/booking_batch_*.json.gz` |

Reference files are loaded by `COPY INTO`; booking and provider files are loaded
by Snowpipe. If files were placed before notifications became active,
`sql/01_bronze/03_initial_reference_load.sql` issues a one-time
`ALTER PIPE … REFRESH` recovery.

Snowpipe deduplicates by staged filename and load metadata. Uploading the same
content under a different name creates additional Bronze rows. Silver still
deduplicates bookings by `booking_id`, but renamed duplicates should be removed
from the source process rather than treated as normal.

## 11. Load reference data and verify Bronze

Run `sql/01_bronze/03_initial_reference_load.sql`.

Expected logical inputs:

- `RAW_CUSTOMERS`: 5,000
- `RAW_SERVICES`: 20
- `RAW_PROVIDER_EVENTS`: 250 before the live file
- `RAW_BOOKING_EVENTS`: more than 50,000 physical rows because controlled booking
  updates add later snapshots
- Distinct Bronze booking IDs: 50,000

Review COPY history. Any `LOAD_FAILED` or non-zero error count must be resolved
before creating downstream objects.

## 12. Create Silver Dynamic Tables

Run `sql/02_silver/01_clean_dynamic_tables.sql`.

Check `SHOW DYNAMIC TABLES`:

- Both scheduling states should be active.
- `DT_BOOKINGS_CLEAN` should contain 50,000 rows.
- `DT_PROVIDER_CHANGES_CLEAN` should contain 250 initial provider rows.
- `refresh_mode` may resolve to incremental or full under `AUTO`; both are valid
  for this small implementation. Review `refresh_mode_reason` when learning why.

The five-minute target lag is a maximum staleness objective. Snowflake chooses
refresh timing; it is not equivalent to a five-minute cron expression.

## 13. Build dimensions and initialize provider history

Run `sql/03_gold/01_dimensions.sql` only after Silver data is present.

Expected state:

- `DIM_DATE`: 1,096 calendar rows
- `DIM_CUSTOMER`: 5,000
- `DIM_SERVICE`: 20
- `DIM_PROVIDER_SCD2`: 250
- Every provider has one current version
- Every current provider ends at `9999-12-31`

The initial provider seed selects the earliest valid provider event. Later files
must go through the SCD2 procedure, not the seed statement.

## 14. Establish the provider-change boundary

Run `sql/03_gold/02_provider_scd2_automation.sql`.

This moment is important: the provider stream starts after the initial 250 rows.
Do not upload `provider_changes_live.json.gz` before this point.

The Task is created suspended by Snowflake and explicitly resumed by the script.
Confirm the final `SHOW TASKS` result reports `started`.

The SCD2 procedure performs one transaction:

1. Materialize the append-only stream delta.
2. Compare the incoming attribute hash with the current provider version.
3. Close a changed current version at the incoming effective timestamp.
4. Insert the new current version.
5. Commit and advance the stream offset together.

The sample change file has at most one change per provider. If a production feed
can deliver several ordered changes for one provider in one micro-batch, extend
the procedure to process all effective timestamps rather than keeping only the
latest event.

## 15. Initialize AI enrichment and its event boundary

Run `sql/03_gold/03_review_ai_enrichment.sql`.

Before running:

- Confirm the project role has `SNOWFLAKE.CORTEX_USER`.
- Confirm the account region supports `AI_SENTIMENT` and `AI_CLASSIFY` or that an
  approved cross-region inference setting exists.
- Review `AI_BACKFILL_LIMIT`. The default is 1,000.

The script enriches the newest historical reviews, then creates the booking
stream at the current Bronze offset. Do not upload `booking_live_batch.json.gz`
before this point.

The complete function objects are stored in VARIANT fields. Normalized labels
are extracted into relational columns for the fact and semantic layer. Null
function results remain visible for operational review rather than aborting the
entire multi-row run.

## 16. Build facts and KPIs

Run `sql/03_gold/04_booking_fact_and_kpis.sql`.

Expected state before live ingestion:

- `FACT_BOOKING`: 50,000 rows
- No duplicate `booking_id`
- No missing dimension keys
- `DT_DAILY_SERVICE_KPI` contains January–August 2026 dates

The booking fact and KPI objects are Dynamic Tables. The manual refreshes at the
end of the file make the initial result deterministic; normal refresh management
continues afterward.

## 17. Build the Semantic View from the Snowsight UI

The primary implementation path for the entire `04_intelligence` phase is the
Snowsight UI. The three SQL files in `sql/04_intelligence` remain as readable,
version-controlled reference definitions and troubleshooting fallbacks; do not
run them when following this UI path.

### 17.1 Select the correct Snowflake context

1. Sign in to Snowsight.
2. Use the role selector to switch to `URBANASSIST_ENGINEER`.
3. Select `URBANASSIST_WH` as the warehouse.
4. Confirm that all six Gold tables listed below are already populated. The
   Semantic View stores metadata; it does not create or load the Gold tables.

### 17.2 Start the Semantic View wizard

1. Open **AI & ML → Cortex Analyst**.
2. Select **Create new → Create new Semantic View**. In Workspace-based Semantic
   Studio this can instead appear as **Add new → Semantic View**.
3. Set the location to database `URBANASSIST_DB`, schema `INTELLIGENCE`.
4. Enter object name `URBANASSIST_OPERATIONS_SV`.
5. Enter this description:

   > Governed operational analytics for UrbanAssist bookings, customers,
   > providers, services, revenue, cancellations, ratings, service duration,
   > and AI-enriched customer reviews.

6. Select **Next**.
7. Choose the option to start from Snowflake tables. If the wizard first offers
   optional SQL, BI-file, or YAML context, select **Skip**.
8. Select schema `URBANASSIST_DB.GOLD` and add these physical tables:

| Logical table name | Physical Snowflake table | Primary key in Semantic Studio | Business grain |
|---|---|---|---|
| `bookings` | `FACT_BOOKING` | `BOOKING_ID` | One row per latest logical booking |
| `dates` | `DIM_DATE` | `DATE_KEY` | One row per calendar date |
| `customers` | `DIM_CUSTOMER` | `CUSTOMER_KEY` | One row per customer |
| `providers` | `DIM_PROVIDER_SCD2` | `PROVIDER_KEY` | One row per historical provider version |
| `services` | `DIM_SERVICE` | `SERVICE_KEY` | One row per service |
| `reviews` | `FACT_REVIEW_INSIGHT` | `BOOKING_ID` | One AI result per reviewed booking |

`PROVIDER_KEY`, not `PROVIDER_ID`, is the provider primary key because one
provider can have several SCD2 versions.

### 17.3 Select only the required physical columns

Selecting a focused column set makes the generated model easier to understand.

| Physical table | Columns to select |
|---|---|
| `FACT_BOOKING` | `BOOKING_ID`, `BOOKING_DATE_KEY`, `CUSTOMER_KEY`, `PROVIDER_KEY`, `SERVICE_KEY`, `BOOKING_CITY`, `BOOKING_STATUS`, `PAYMENT_METHOD`, `BOOKING_CREATED_AT`, `SCHEDULED_AT`, `SERVICE_STARTED_AT`, `SERVICE_COMPLETED_AT`, `GROSS_AMOUNT`, `DISCOUNT_AMOUNT`, `FINAL_AMOUNT`, `RATING`, `SERVICE_DURATION_MINUTES`, `COMPLETED_BOOKING_COUNT`, `CANCELLED_BOOKING_COUNT` |
| `DIM_DATE` | `DATE_KEY`, `FULL_DATE`, `DAY_NAME`, `MONTH_NAME`, `QUARTER`, `YEAR`, `IS_WEEKEND` |
| `DIM_CUSTOMER` | `CUSTOMER_KEY`, `CUSTOMER_SEGMENT`, `HOME_CITY` |
| `DIM_PROVIDER_SCD2` | `PROVIDER_KEY`, `PROVIDER_ID`, `PROVIDER_NAME`, `PRIMARY_CITY`, `OPERATING_ZONE`, `PROVIDER_TIER`, `EXPERIENCE_LEVEL`, `ACTIVE_STATUS` |
| `DIM_SERVICE` | `SERVICE_KEY`, `SERVICE_NAME`, `SERVICE_CATEGORY`, `SKILL_LEVEL_REQUIRED` |
| `FACT_REVIEW_INSIGHT` | `BOOKING_ID`, `SENTIMENT_LABEL`, `COMPLAINT_CATEGORY` |

Select **Generate** or **Next**, review the suggestions, and open the generated
view in Semantic Studio. Do not assume every AI suggestion is correct; reconcile
it with the mappings below.

### 17.4 Set logical names and relationships

Edit each logical table and set the logical name and primary key exactly as in
section 17.2. Then select **+ Relationship** and add these five relationships:

| Relationship name | Foreign-key side | Referenced side | Business meaning |
|---|---|---|---|
| `bookings_to_dates` | `bookings.BOOKING_DATE_KEY` | `dates.DATE_KEY` | Date when the booking was created |
| `bookings_to_customers` | `bookings.CUSTOMER_KEY` | `customers.CUSTOMER_KEY` | Customer who placed the booking |
| `bookings_to_providers` | `bookings.PROVIDER_KEY` | `providers.PROVIDER_KEY` | Provider version valid for the booking |
| `bookings_to_services` | `bookings.SERVICE_KEY` | `services.SERVICE_KEY` | Service requested |
| `reviews_to_bookings` | `reviews.BOOKING_ID` | `bookings.BOOKING_ID` | Optional AI review insight for a booking |

The booking or review table is always the foreign-key side. Semantic Views
infer the join and relationship type from keys, so there is no need to force a
left or inner join in this screen.

### 17.5 Define dimensions

In each logical table, open **Dimensions** and retain or add the following
business fields. Use the semantic name in the first column and map it to the
physical column in the second column.

| Logical table | Semantic dimension | Physical column | Useful synonyms |
|---|---|---|---|
| `bookings` | `booking_id` | `BOOKING_ID` | — |
| `bookings` | `booking_city` | `BOOKING_CITY` | city, market |
| `bookings` | `booking_status` | `BOOKING_STATUS` | status, job status |
| `bookings` | `payment_method` | `PAYMENT_METHOD` | payment type |
| `dates` | `booking_date` | `FULL_DATE` | date, booking date |
| `dates` | `day_name` | `DAY_NAME` | weekday |
| `dates` | `month_name` | `MONTH_NAME` | month |
| `dates` | `quarter` | `QUARTER` | — |
| `dates` | `year` | `YEAR` | — |
| `dates` | `is_weekend` | `IS_WEEKEND` | weekend |
| `customers` | `customer_segment` | `CUSTOMER_SEGMENT` | segment, customer type |
| `customers` | `customer_home_city` | `HOME_CITY` | home city |
| `providers` | `provider_id` | `PROVIDER_ID` | professional ID, partner ID |
| `providers` | `provider_name` | `PROVIDER_NAME` | professional, partner |
| `providers` | `provider_city` | `PRIMARY_CITY` | primary city |
| `providers` | `operating_zone` | `OPERATING_ZONE` | zone |
| `providers` | `provider_tier` | `PROVIDER_TIER` | tier, provider level |
| `providers` | `experience_level` | `EXPERIENCE_LEVEL` | experience |
| `providers` | `active_status` | `ACTIVE_STATUS` | provider status |
| `services` | `service_name` | `SERVICE_NAME` | service |
| `services` | `service_category` | `SERVICE_CATEGORY` | category, service type |
| `services` | `skill_level_required` | `SKILL_LEVEL_REQUIRED` | skill level |
| `reviews` | `sentiment` | `SENTIMENT_LABEL` | sentiment, customer mood |
| `reviews` | `complaint_theme` | `COMPLAINT_CATEGORY` | complaint, issue, review category |

Add the listed synonyms manually. Domain synonyms improve question matching;
irrelevant generated synonyms can reduce accuracy.

### 17.6 Define row-level facts and governed metrics

Under the `bookings` logical table, add these **Facts**:

| Semantic fact | Expression/physical column | Meaning |
|---|---|---|
| `gross_amount` | `GROSS_AMOUNT` | Price before discount |
| `discount_amount` | `DISCOUNT_AMOUNT` | Discount granted |
| `final_amount` | `FINAL_AMOUNT` | Final customer charge/revenue |
| `rating` | `RATING` | Customer rating |
| `service_duration_minutes` | `SERVICE_DURATION_MINUTES` | Actual service duration |
| `completed_flag` | `COMPLETED_BOOKING_COUNT` | 1 for a completed booking, otherwise 0 |
| `cancelled_flag` | `CANCELLED_BOOKING_COUNT` | 1 for a cancelled booking, otherwise 0 |

Under `bookings`, add these **Metrics**. Enter the expression using the logical
fields shown by Semantic Studio; its autocomplete should resolve them.

| Metric name | Metric expression | Format/meaning |
|---|---|---|
| `total_bookings` | `COUNT(booking_id)` | Number of bookings |
| `completed_bookings` | `SUM(completed_flag)` | Completed bookings |
| `cancelled_bookings` | `SUM(cancelled_flag)` | Cancelled bookings |
| `completion_rate` | `SUM(completed_flag) / NULLIF(COUNT(booking_id), 0)` | Display as percentage |
| `cancellation_rate` | `SUM(cancelled_flag) / NULLIF(COUNT(booking_id), 0)` | Display as percentage |
| `gross_revenue` | `SUM(gross_amount)` | INR currency; synonyms: gross sales, GMV |
| `net_revenue` | `SUM(final_amount)` | INR currency; synonyms: revenue, sales, earnings |
| `average_booking_value` | `AVG(final_amount)` | INR currency; synonyms: ABV, average order value |
| `average_rating` | `AVG(rating)` | Average customer rating |
| `average_service_duration` | `AVG(service_duration_minutes)` | Average minutes |

Under `reviews`, add:

| Metric name | Metric expression | Meaning |
|---|---|---|
| `enriched_review_count` | `COUNT(booking_id)` | Reviews processed by AI Functions |
| `negative_review_count` | `COUNT_IF(SENTIMENT_LABEL = 'negative')` | Enriched reviews classified as negative |

For metric expressions, select fields from Semantic Studio autocomplete. This
avoids quoting or case mistakes and makes it clear whether the editor is using a
semantic fact name or its underlying physical-column expression.

### 17.7 Add Cortex Analyst instructions

Open the custom-instructions area and add:

- **SQL generation:** `Round rates to four decimals and currency metrics to two decimals. Display currency as INR. Use booking creation date unless the user explicitly requests another timestamp.`
- **Question categorization:** `This model covers bookings, customers, services, provider history, revenue, ratings, cancellations, service duration, and enriched review sentiment. Ask for clarification when a time period or comparison group is ambiguous.`

### 17.8 Save and verify the Semantic View

Because this runbook starts from **AI & ML → Cortex Analyst → Create new Semantic
View**, **Save** is the final creation action. There is no separate Deploy button
in this wizard.

1. Select **Save**.
2. Wait until Snowflake confirms that the Semantic View was created.
3. Return to **AI & ML → Cortex Analyst** and confirm that
   `URBANASSIST_OPERATIONS_SV` appears in the list.
4. Open it and verify that its location is
   `URBANASSIST_DB.INTELLIGENCE` and that it contains six logical tables and five
   relationships.
5. If the page provides a preview or chat panel, select `URBANASSIST_WH` and ask
   these questions one at a time:

   - `What is the cancellation rate by city?`
   - `Which service category generated the most net revenue?`
   - `Compare completion rate for Standard and Premium providers.`
   - `What are the most common complaint themes among negative reviews?`

6. For each answer, inspect the generated SQL, result columns, and join path.
   Confirm that rates use the governed flags and provider questions join through
   `PROVIDER_KEY`, not `PROVIDER_ID`.
7. Save the first two tested questions as verified queries only after their SQL
   and results are correct. Mark them as onboarding questions if the UI offers
   that option.

If this Cortex Analyst page does not provide a chat panel, that is not an error.
Continue to section 18, attach the Semantic View to the Agent, and perform the
same tests from the Agent playground.

The **Deploy** button belongs to the other authoring route: Semantic Studio
inside a Snowflake Workspace, where the view is maintained as a local
`.sv.yaml` file and then deployed to a live object. Only that Workspace route
creates the auto-managed `cortex-project.yaml` file. These steps are not needed
for the wizard route used by this runbook.

`Cortex Analyst` is not a separate schema object that must be created after the
Semantic View. It is Snowflake's natural-language-to-SQL capability. The
saved Semantic View supplies its business vocabulary, joins, and metrics;
the next section attaches that capability to an Agent as a tool.

## 18. Create the Cortex Agent and add Analyst from the UI

### 18.1 Create the Agent object

1. Keep role `URBANASSIST_ENGINEER` and warehouse `URBANASSIST_WH` selected.
2. Open **AI & ML → Agents**.
3. Select **Create agent**.
4. Set database `URBANASSIST_DB` and schema `INTELLIGENCE`.
5. Set **Agent object name** to `URBANASSIST_OPERATIONS_AGENT`.
6. Set **Display name** to `UrbanAssist Operations Agent`.
7. Set the description to:

   > Answers governed operational questions about UrbanAssist bookings,
   > customers, provider history, services, revenue, cancellations, ratings,
   > service duration, sentiment, and complaint themes.

8. Choose the blue profile color if the field is available and select **Create
   agent**.

At this point the Agent has general model knowledge but no project-data access.
The next step gives it Cortex Analyst as its one governed data tool.

### 18.2 Attach the Cortex Analyst tool

1. On the Agent page select **Edit**, then open **Tools**.
2. Find **Cortex Analyst** and select **+ Add**.
3. Choose **Semantic view**.
4. Select database `URBANASSIST_DB`, schema `INTELLIGENCE`, and semantic view
   `URBANASSIST_OPERATIONS_SV`.
5. Use tool name `URBANASSIST_OPERATIONS_SV`. For semantic-view tools, current
   Snowsight uses the Semantic View name as the tool name.
6. Enter this tool description:

   > Generates governed SQL for UrbanAssist booking, revenue, provider,
   > service, customer, rating, duration, and AI-enriched review analysis.

7. For warehouse choose **Custom → URBANASSIST_WH**.
8. Set query timeout to `60` seconds.
9. Select **Add**.

### 18.3 Configure orchestration and sample questions

1. Open **Orchestration**.
2. Leave the orchestration model on **Auto**, unless the account requires an
   approved specific model.
3. Enter this **Planning instruction**:

   > Use URBANASSIST_OPERATIONS_SV for every question about bookings,
   > customers, providers, services, revenue, cancellations, ratings, service
   > duration, sentiment, or complaint themes. Never invent business values.
   > Ask for clarification when the requested date range or comparison group is
   > ambiguous.

4. Enter this **Response instruction**:

   > Lead with the operational conclusion. State the metrics used, format rates
   > as percentages and currency as INR, and clearly separate measured facts
   > from recommendations.

5. If budget configuration is displayed, set the response time limit to `30`
   seconds and the orchestration token limit to `16000`.
6. Add these sample questions:

   - `Which city and service category need the most attention?`
   - `Compare performance for Standard and Premium providers.`
   - `What are the most common themes in negative reviews?`

7. Select **Save**.

### 18.4 Test in the Agent playground

1. Enter `What is the cancellation rate by city?`.
2. Expand the response details and confirm that the Agent called
   `URBANASSIST_OPERATIONS_SV` as a Cortex Analyst tool.
3. Inspect the generated SQL and confirm that it queried project data rather
   than answering from general knowledge.
4. Ask `Which service category generated the most net revenue?` and confirm that
   the tool joins bookings to services through `SERVICE_KEY`.
5. Ask a follow-up, `Show only completed bookings`, to demonstrate that the
   conversation retains context.

Do not proceed to CoWork if the Agent does not make a tool call. Reopen **Edit →
Tools** and verify the Semantic View, warehouse, and tool name.

## 19. Configure and test Snowflake CoWork from the UI

### 19.1 Understand the account-level boundary

Snowflake CoWork is the conversational application in which users choose and
interact with Agents. A Snowflake account can have only one account-level CoWork
object. Do not delete or replace an existing object just for this project.

### 19.2 Create or open CoWork settings

1. In Snowsight switch to `ACCOUNTADMIN` for the one-time account configuration.
2. Open **AI & ML → Agents**.
3. Open the **Snowflake CoWork** tab and select **Open settings**. The first saved
   UI configuration automatically creates the account object named
   `SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT` if it does not already exist.
4. If an organization-wide CoWork configuration already exists, preserve its
   branding and existing Agent list.
5. For a new development configuration, use:

   - Display name: `UrbanAssist Data CoWork`
   - Welcome message: `Ask governed questions about bookings, revenue, service performance, providers, ratings, cancellations, and customer reviews.`
   - Color theme: choose a simple blue theme

6. In the Agent visibility/list area, select **Add agent** (or enable the Agent
   in the available-Agent list), choose
   `URBANASSIST_DB.INTELLIGENCE.URBANASSIST_OPERATIONS_AGENT`, and save.

Adding the Agent controls whether it appears in the curated CoWork list; it does
not bypass Snowflake role permissions.

### 19.3 Verify user access and defaults in Snowsight

For the developer who will test CoWork:

1. Open **Admin → Users & Roles → Users** and select the user.
2. Select **Edit** and verify:
   - Default role: `URBANASSIST_ENGINEER`
   - Default warehouse: `URBANASSIST_WH`
3. Open the `URBANASSIST_ENGINEER` role and verify it has access to:
   - database `URBANASSIST_DB` and schema `INTELLIGENCE`;
   - Agent `URBANASSIST_OPERATIONS_AGENT`;
   - Semantic View `URBANASSIST_OPERATIONS_SV` and its Gold source tables;
   - warehouse `URBANASSIST_WH`;
   - Snowflake database role `SNOWFLAKE.CORTEX_AGENT_USER`.
4. In the CoWork settings access/privileges area, grant or verify `USAGE` for
   `URBANASSIST_ENGINEER` on the CoWork object. Keep `MODIFY` restricted to the
   administrator unless developers genuinely need to curate the global Agent
   list.

The project setup script already grants the Cortex database roles and makes the
project role the owner of its database objects. Some Snowflake releases expose
all CoWork grants in the settings UI; if the account does not show a CoWork
privilege editor, use only the grant statements in
`sql/04_intelligence/03_cowork_access.sql` as the administrative fallback.

CoWork initializes a new session using the user's **default** role and default
warehouse. Changing the active role in an unrelated worksheet does not change
those login defaults.

### 19.4 Open CoWork and perform acceptance tests

1. Return to **AI & ML → Agents** and select **UrbanAssist Operations Agent**.
2. Select **Preview in Snowflake CoWork**. Alternatively, open
   [https://ai.snowflake.com](https://ai.snowflake.com) and sign in to the same
   Snowflake account.
3. Confirm that **UrbanAssist Operations Agent** is visible and selected.
4. Ask:

   > Summarize bookings, completion rate, cancellation rate, and net revenue by
   > city. Separate facts from recommendations.

5. Confirm that the answer shows project results and traceability to the
   generated query/tool call.
6. Ask:

   > What are the most common complaint themes among negative reviews, and what
   > operational action would you recommend?

7. Confirm that the first part is supported by the Semantic View and the
   recommendation is clearly distinguished from measured facts.
8. Ask for a bar chart of cancellation rate by city to demonstrate CoWork's
   conversational visualization capability.

The Intelligence phase is complete when all four checkpoints pass:

- the Semantic View is saved and appears in the Cortex Analyst list;
- Cortex Analyst produces valid governed SQL;
- the Agent consistently invokes the Analyst tool for project-data questions;
- the Agent is visible and queryable in Snowflake CoWork.

Current Snowflake UI references:

- [Semantic Studio](https://docs.snowflake.com/en/user-guide/views-semantic/semantic-studio)
- [Create and manage Cortex Agents](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-agents-manage)
- [CoWork user access and Agent visibility](https://docs.snowflake.com/en/user-guide/snowflake-cortex/snowflake-cowork/deploy-agents)

## 20. Run the validation gates

Run `sql/05_operations/01_monitoring_and_validation.sql`.

All of these result sets must return zero rows or zero violations:

- Duplicate Silver bookings
- Duplicate Gold bookings
- Missing dimension keys
- Invalid date keys
- Providers with zero or multiple current versions
- Invalid SCD2 intervals
- Overlapping provider intervals
- Negative amounts, invalid ratings, or negative durations

Review AI enrichment coverage separately. It is expected to be less than 100%
when the historical limit is lower than the number of source reviews.

## 21. Execute the live event-driven change

Open `sql/05_operations/02_live_event_demo.sql` and execute the BEFORE queries.

Upload:

```text
data/generated/bookings/booking_live_batch.json.gz
  -> urbanassist/bookings/booking_live_batch.json.gz

data/generated/providers/provider_changes_live.json.gz
  -> urbanassist/providers/provider_changes_live.json.gz
```

Then execute the AFTER sections sequentially:

1. Confirm stage visibility and pipe health.
2. Confirm each stream reports data.
3. Allow the one-minute Tasks to run, or manually execute them once.
4. Refresh Silver and Gold Dynamic Tables for deterministic inspection.
5. Validate 51,000 Gold booking rows.
6. Inspect provider version history.
7. Inspect September KPI rows and the increased AI-enrichment count.

Finally ask the Agent:

> What changed after September 1, 2026, and which city and service category now
> need the most attention? Support the answer with governed metrics.

Useful follow-ups:

- Compare Standard and Premium provider completion rates.
- Which providers changed tier, and how does their earlier performance compare?
- What are the most frequent themes among negative enriched reviews?
- Create a concise operations summary separating facts from recommendations.

## 22. Rerun behavior

| Object group | Safe rerun behavior |
|---|---|
| Account database/schemas/warehouse | `IF NOT EXISTS`; non-destructive |
| Bronze tables, stage, pipes | `IF NOT EXISTS`; current data and offsets preserved |
| Reference dimensions | `MERGE`; Type 1 values updated |
| Silver/Gold Dynamic Tables | `CREATE OR REPLACE`; contents reinitialize |
| Provider initial seed | Inserts only missing natural keys |
| Streams | `IF NOT EXISTS`; offsets preserved |
| Procedures/Tasks | Replaced with repository definition |
| Historical AI backfill | Review hash prevents unchanged updates, but AI source query can still incur calls |
| Semantic View/Agent | Edit and deploy from the UI; review the diff because deployment replaces the live definition |
| CoWork object | Edit the existing account-level object; never recreate or delete a shared configuration for a rerun |

Do not replace a stream merely to clear it. Consume or deliberately recreate it
only after deciding how pending changes will be recovered.

## 23. Troubleshooting

| Symptom | Check | Resolution |
|---|---|---|
| `LIST` returns access denied | Integration ARN, external ID, IAM policy, bucket prefix | Correct trust and least-privilege policy, then retry `LIST` |
| File is visible but Bronze is unchanged | Pipe status and S3 notification prefix/suffix | Correct notification; use one reviewed `ALTER PIPE … REFRESH` for recent missed files |
| Pipe reports stopped | `SYSTEM$PIPE_STATUS`, COPY history | Resolve file-format or permission error, then resume/recreate only if required |
| Silver count is zero | Bronze count and standalone SELECT | Correct JSON path/casts, then replace and refresh the Dynamic Table |
| Dynamic Table uses full refresh | `SHOW DYNAMIC TABLES.refresh_mode_reason` | Accept for this data size or simplify unsupported query constructs |
| Provider stream has no data | Upload timing and exact S3 key | Ensure the live file arrived after stream creation and was loaded by the provider pipe |
| Provider has two current rows | SCD2 validation and effective timestamps | Suspend Task, correct conflicting interval in a transaction, rerun validation |
| AI labels are null | Cortex role, regional support, function result VARIANT | Review privilege/region; inspect raw result and function errors |
| AI Task repeats costs | Review hash and stream offset | Confirm existing review hash matches and stream is not being recreated |
| Agent does not call Analyst | Agent tool/resource names and semantic privileges | Make names identical; grant semantic view access and table SELECT as required |
| CoWork does not display Agent | CoWork object membership, agent USAGE, default role/warehouse | Add Agent, correct grants, and reauthenticate |
| Git branch is missing | Workspace Changes menu | Fetch All, then select the remote branch |

## 24. Cleanup

`sql/05_operations/03_cleanup.sql` contains a safe teardown order with every destructive
statement commented out. Suspend Tasks first, remove the Agent from the shared
CoWork object, then remove only project-owned database, warehouse, integration,
and role objects. The SQL does not delete S3 files.
