/*
===============================================================================
UrbanAssist 360 | Intelligence 02 - Cortex Agent backed by Cortex Analyst
Run as: URBANASSIST_ENGINEER

REFERENCE/FALLBACK: The primary project path creates and configures the Agent
through the Snowsight UI. Follow sections 17-19 of docs/RUNBOOK.md. Run this file
only when deliberately using SQL or comparing the stored specification.
===============================================================================
*/

-- Use the role granted both Cortex Agent and Semantic View privileges.
USE ROLE URBANASSIST_ENGINEER;

-- Select the warehouse the Analyst tool will use for generated SQL.
USE WAREHOUSE URBANASSIST_WH;

-- Select the project database.
USE DATABASE URBANASSIST_DB;

-- Create the Agent in the Intelligence schema beside its Semantic View.
USE SCHEMA INTELLIGENCE;

-- Create the governed operations Agent. The specification limits its analytical
-- tool to the project Semantic View, sets time/token budgets, and instructs it
-- to distinguish measured facts from recommendations.
CREATE OR REPLACE AGENT URBANASSIST_OPERATIONS_AGENT
  COMMENT = 'Operations agent for governed UrbanAssist booking and review analytics'
  PROFILE = '{"display_name":"UrbanAssist Operations Agent","color":"blue"}'
  FROM SPECIFICATION
  $$
  models:
    orchestration: auto

  orchestration:
    budget:
      seconds: 30
      tokens: 16000

  instructions:
    response: "Lead with the operational conclusion. Cite the metrics used, format rates as percentages and currency as INR, and keep recommendations separate from facts."
    orchestration: "Use URBANASSIST_OPERATIONS_SV for every question about bookings, customers, providers, services, revenue, cancellations, ratings, service duration, sentiment, or complaint categories. Never invent business values."
    system: "You are an operations analyst for a home-services marketplace. Identify material issues, explain evidence, and recommend practical actions."
    sample_questions:
      - question: "Which city and service category need the most attention?"
      - question: "Compare performance for Standard and Premium providers."
      - question: "What are the most common themes in negative reviews?"

  tools:
    - tool_spec:
        type: "cortex_analyst_text_to_sql"
        name: "URBANASSIST_OPERATIONS_SV"
        description: "Queries the governed UrbanAssist semantic view for booking, revenue, provider, service, customer, and AI-enriched review metrics."

  tool_resources:
    URBANASSIST_OPERATIONS_SV:
      semantic_view: "URBANASSIST_DB.INTELLIGENCE.URBANASSIST_OPERATIONS_SV"
      execution_environment:
        type: "warehouse"
        warehouse: "URBANASSIST_WH"
        query_timeout: 60
  $$;

-- Allow the project role to resolve the Semantic View relationships and query
-- its governed metrics when the Agent invokes Cortex Analyst.
GRANT REFERENCES, SELECT
  ON SEMANTIC VIEW URBANASSIST_OPERATIONS_SV
  TO ROLE URBANASSIST_ENGINEER;
-- Allow developers using the project role to open and invoke the Agent.
GRANT USAGE
  ON AGENT URBANASSIST_OPERATIONS_AGENT
  TO ROLE URBANASSIST_ENGINEER;

-- Inspect the stored specification and confirm the Agent was created as expected.
DESCRIBE AGENT URBANASSIST_OPERATIONS_AGENT;
