/*
===============================================================================
UrbanAssist 360 | Intelligence 03 - Snowflake CoWork account-level visibility
Run as: ACCOUNTADMIN

REFERENCE/FALLBACK: The primary project path configures CoWork in Snowsight.
Follow section 19 of docs/RUNBOOK.md. Use these statements only when the account
does not expose the required access control in the UI.

IMPORTANT: An account can have only one Snowflake CoWork object. First run SHOW.
Run CREATE only when no object exists. If it already exists, skip CREATE and add
the project Agent to the existing SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT object.
===============================================================================
*/

-- Use ACCOUNTADMIN because the Snowflake Intelligence object is account-level.
USE ROLE ACCOUNTADMIN;

-- Check whether the account-wide CoWork object already exists before attempting
-- the conditional CREATE statement below.
SHOW SNOWFLAKE INTELLIGENCES;

-- CONDITIONAL: execute only if SHOW returned no rows.
-- Create the single account-wide Snowflake Intelligence object used by CoWork.
CREATE SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT;

-- Allow the project role to open and use the CoWork intelligence object.
GRANT USAGE
  ON SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT
  TO ROLE URBANASSIST_ENGINEER;

-- Allow the project role to manage which project Agents are attached to CoWork.
GRANT MODIFY
  ON SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT
  TO ROLE URBANASSIST_ENGINEER;

-- Register the UrbanAssist Agent so it becomes selectable in Snowflake CoWork.
ALTER SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT
  ADD AGENT URBANASSIST_DB.INTELLIGENCE.URBANASSIST_OPERATIONS_AGENT;

-- The CoWork/Agent session uses the user's default role and default warehouse.
-- Replace the user placeholder, then run these only if the defaults are absent.
-- These defaults ensure interactive CoWork requests inherit access to both the
-- Agent and its query warehouse without requiring a manual role switch.
ALTER USER SNOWPROTHOSHAN SET
  DEFAULT_ROLE = URBANASSIST_ENGINEER,
  DEFAULT_WAREHOUSE = URBANASSIST_WH;
