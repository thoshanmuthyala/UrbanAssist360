/*
===============================================================================
UrbanAssist 360 | Setup 02 - AWS S3 storage integration
Run as: URBANASSIST_ENGINEER

Replace both placeholders before running. The S3 URL must end in /urbanassist/
because every later stage path is relative to that project prefix.
===============================================================================
*/

-- Use the project role that received CREATE INTEGRATION during account setup.
USE ROLE URBANASSIST_ENGINEER;

-- Set the project database as the current database for consistent name
-- resolution and integration ownership context.
USE DATABASE URBANASSIST_DB;

-- Use OPS because external connectivity objects are operational components.
USE SCHEMA OPS;
-- Create the account-level trust object Snowflake uses to assume the supplied
-- AWS IAM role. STORAGE_ALLOWED_LOCATIONS prevents access outside this project
-- prefix even if the AWS role itself has broader permissions.
CREATE OR REPLACE STORAGE INTEGRATION URBANASSIST_S3_INT
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  ENABLED = TRUE
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::446241389601:role/urban360-snowflake-role'
  STORAGE_ALLOWED_LOCATIONS = ('s3://snowpro-bucket-8572/urbanassist/')
  COMMENT = 'Read-only integration for UrbanAssist source files';

-- Copy STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID from this result
-- into the AWS IAM role trust policy. The runbook provides the exact sequence.
-- Rerun this command after editing the AWS trust policy to compare the values.
DESC INTEGRATION URBANASSIST_S3_INT;
