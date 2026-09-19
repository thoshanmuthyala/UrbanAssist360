/*
===============================================================================
UrbanAssist 360 | Setup 01 - Account, role, warehouse, database, and schemas
Run as: ACCOUNTADMIN, followed by URBANASSIST_ENGINEER where indicated.

This script creates a self-contained development role. In a production account,
split ownership, engineering, task-owner, and consumer duties into separate roles.
===============================================================================
*/

-- Switch to the account administrator so the script can create a role and
-- delegate account-level privileges. This is the only privileged setup block.
USE ROLE ACCOUNTADMIN;

-- Create one project role that owns and operates the development objects. The
-- IF NOT EXISTS clause makes repeated setup runs safe.
CREATE ROLE IF NOT EXISTS URBANASSIST_ENGINEER
  COMMENT = 'Owns and operates UrbanAssist development objects';

-- Replace the following user name before running. This is deliberately explicit
-- because role assignment is an account-security decision.
GRANT ROLE URBANASSIST_ENGINEER TO USER SNOWPROTHOSHAN;

-- Add the project role below SYSADMIN so an administrator can inherit and
-- manage its privileges without using ACCOUNTADMIN for normal project work.
GRANT ROLE URBANASSIST_ENGINEER TO ROLE SYSADMIN;

-- The project role creates and owns its isolated development resources.
-- Allow the role to create the single project database.
GRANT CREATE DATABASE ON ACCOUNT TO ROLE URBANASSIST_ENGINEER;

-- Allow the role to create the X-Small project warehouse.
GRANT CREATE WAREHOUSE ON ACCOUNT TO ROLE URBANASSIST_ENGINEER;

-- Allow the role to create the S3 storage integration used by the stage.
GRANT CREATE INTEGRATION ON ACCOUNT TO ROLE URBANASSIST_ENGINEER;

-- Allow serverless task scheduling/execution under the project task owner.
GRANT EXECUTE TASK ON ACCOUNT TO ROLE URBANASSIST_ENGINEER;

-- AI functions and Cortex Agents are database roles in the shared SNOWFLAKE DB.
-- CORTEX_USER authorizes calls to functions such as AI_SENTIMENT and
-- AI_CLASSIFY from the review-enrichment procedure.
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE URBANASSIST_ENGINEER;

-- CORTEX_AGENT_USER authorizes the role to create and use Cortex Agents.
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_AGENT_USER TO ROLE URBANASSIST_ENGINEER;

-- Drop elevated administration privileges before creating project resources.
USE ROLE URBANASSIST_ENGINEER;

-- Create low-cost compute for ingestion checks, Dynamic Table refreshes,
-- procedures, Tasks, and analytical queries. Auto-suspend limits idle cost.
CREATE WAREHOUSE IF NOT EXISTS URBANASSIST_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Compute for UrbanAssist ingestion, transformation, and analytics';

-- Create the isolated project database with one day of Time Travel retention.
CREATE DATABASE IF NOT EXISTS URBANASSIST_DB
  DATA_RETENTION_TIME_IN_DAYS = 1
  COMMENT = 'Event-driven home-services analytics project';

-- Bronze owns append-only source landing tables.
CREATE SCHEMA IF NOT EXISTS URBANASSIST_DB.BRONZE
  COMMENT = 'Immutable raw landing objects';

-- Silver owns typed and cleaned Dynamic Tables.
CREATE SCHEMA IF NOT EXISTS URBANASSIST_DB.SILVER
  COMMENT = 'Validated, standardized, and enriched data';

-- Gold owns facts, dimensions, AI results, and business aggregates.
CREATE SCHEMA IF NOT EXISTS URBANASSIST_DB.GOLD
  COMMENT = 'Dimensional model and business aggregates';

-- OPS owns the operational objects that move and process data between layers.
CREATE SCHEMA IF NOT EXISTS URBANASSIST_DB.OPS
  COMMENT = 'Stages, pipes, streams, tasks, procedures, and monitoring';

-- INTELLIGENCE owns the semantic view and Cortex Agent exposed to consumers.
CREATE SCHEMA IF NOT EXISTS URBANASSIST_DB.INTELLIGENCE
  COMMENT = 'Semantic views and Cortex Agents';

-- Set the default compute and object namespace for the remaining setup checks.
USE WAREHOUSE URBANASSIST_WH;

-- Make the project database current so later unqualified object names resolve
-- inside URBANASSIST_DB.
USE DATABASE URBANASSIST_DB;

-- Use OPS as the default schema for ingestion and orchestration objects.
USE SCHEMA OPS;

-- Confirm that the session is using the intended role, warehouse, and database
-- before continuing to integrations or data objects.
SELECT CURRENT_ROLE() AS active_role,
       CURRENT_WAREHOUSE() AS active_warehouse,
       CURRENT_DATABASE() AS active_database;
