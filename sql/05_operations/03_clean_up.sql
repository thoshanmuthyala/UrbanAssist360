/*
===============================================================================
UrbanAssist 360 | Operations 03 - Optional teardown

All destructive statements are commented out. Review the exact object names,
confirm that URBANASSIST_DB is dedicated to this project, then uncomment only the
objects that should be removed. S3 source files are not deleted by this script.
===============================================================================
*/

-- Set a harmless project-role context. Every destructive statement below stays
-- commented until the operator explicitly reviews and enables it.
USE ROLE URBANASSIST_ENGINEER;

-- Stop recurring compute before dropping objects.
-- Suspend the review Task so it cannot start another AI-processing run.
-- ALTER TASK URBANASSIST_DB.OPS.TASK_ENRICH_NEW_REVIEWS SUSPEND;

-- Suspend the provider Task so it cannot modify SCD2 during teardown.
-- ALTER TASK URBANASSIST_DB.OPS.TASK_PROCESS_PROVIDER_SCD2 SUSPEND;

-- If the Agent was added to the account CoWork object, remove it first as
-- ACCOUNTADMIN. Keep the CoWork object if other agents use it.
-- Elevate only for the account-level Snowflake Intelligence modification.
-- USE ROLE ACCOUNTADMIN;

-- Detach this project Agent without deleting the shared CoWork object.
-- ALTER SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT
--   DROP AGENT URBANASSIST_DB.INTELLIGENCE.URBANASSIST_OPERATIONS_AGENT;

-- Remove project-owned account and database objects.
-- Return to the project owner before dropping resources it owns.
-- USE ROLE URBANASSIST_ENGINEER;

-- Drop all project schemas, tables, Tasks, Agents, and data in one database.
-- DROP DATABASE URBANASSIST_DB;

-- Drop the dedicated compute warehouse after all dependent work has stopped.
-- DROP WAREHOUSE URBANASSIST_WH;

-- Drop the Snowflake trust object; this does not modify the AWS IAM role or S3.
-- DROP STORAGE INTEGRATION URBANASSIST_S3_INT;

-- Remove the role only after revoking it from users and SYSADMIN.
-- Elevate to manage role hierarchy and user grants.
-- USE ROLE ACCOUNTADMIN;

-- Revoke the project role from the named developer account.
-- REVOKE ROLE URBANASSIST_ENGINEER FROM USER <YOUR_SNOWFLAKE_USER>;

-- Remove the project role from the SYSADMIN hierarchy.
-- REVOKE ROLE URBANASSIST_ENGINEER FROM ROLE SYSADMIN;

-- Drop the now-unassigned project role last.
-- DROP ROLE URBANASSIST_ENGINEER;
