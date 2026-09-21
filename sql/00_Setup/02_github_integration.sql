/*
===============================================================================
UrbanAssist 360 | Setup 03 - GitHub integration for a Snowflake Workspace
Run as: ACCOUNTADMIN

Purpose
-------
Create the account-level API integration that lets a developer connect a
Snowflake Workspace to a repository hosted on github.com. This configuration
uses the Snowflake GitHub App OAuth flow, which is the preferred option for
interactive pull, commit, and push operations from Workspaces.

Before running
--------------
1. Run 01_account_and_roles.sql so URBANASSIST_ENGINEER exists.
2. Replace <GITHUB_OWNER> and <GITHUB_REPOSITORY>.
3. The GitHub repository must already contain at least one branch and commit.
4. Keep the HTTPS repository URL; SSH URLs are not supported here.

After running
-------------
Create the Git-connected Workspace through Projects -> Workspaces -> From Git
repository. The README contains the exact UI sequence because CREATE WORKSPACE
is not a SQL command.
===============================================================================
*/

-- Use ACCOUNTADMIN because creating an API integration is normally controlled
-- by an account administrator. A delegated role can be used instead when it
-- has the CREATE INTEGRATION account privilege.
USE ROLE ACCOUNTADMIN;

-- Create an HTTPS Git API integration restricted to this GitHub repository.
-- SNOWFLAKE_GITHUB_APP starts an interactive OAuth authorization when the
-- developer connects the repository in a Snowflake Workspace; no PAT is stored.
CREATE OR REPLACE API INTEGRATION URBANASSIST_GITHUB_API_INT
  API_PROVIDER = GIT_HTTPS_API
  API_ALLOWED_PREFIXES = (
    'https://github.com/thoshanmuthyala/UrbanAssist360'
  )
  API_USER_AUTHENTICATION = (
    TYPE = SNOWFLAKE_GITHUB_APP
  )
  ENABLED = TRUE
  COMMENT = 'OAuth connection from Snowflake Workspaces to the UrbanAssist GitHub repository';

-- Allow the project role to select this integration while creating or opening
-- the Git-connected Workspace. This grant does not grant access to GitHub;
-- each developer still authorizes the Snowflake GitHub App interactively.
GRANT USAGE
  ON INTEGRATION URBANASSIST_GITHUB_API_INT
  TO ROLE URBANASSIST_ENGINEER;

-- Display the integration properties so the administrator can confirm that it
-- is enabled, limited to the intended GitHub URL, and configured for OAuth.
DESCRIBE INTEGRATION URBANASSIST_GITHUB_API_INT;

-- Verify the project role received the integration privilege required by the
-- Workspace creation dialog.
SHOW GRANTS ON INTEGRATION URBANASSIST_GITHUB_API_INT;


