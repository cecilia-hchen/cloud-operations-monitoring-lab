-- PHASE 2 - Run in Synapse Studio: Develop > + > SQL script, "Connect to: Built-in" (serverless).
-- Replace stcloudopstgrm4 with: terraform output -raw storage_account_name
-- Serverless SQL reads the files in place in the data lake - nothing is loaded or copied.

-- =============================================================================
-- A. Sample IT ticket data (uploaded by Terraform to data/tickets/)
-- =============================================================================

-- A1. Preview
SELECT TOP 10 *
FROM OPENROWSET(
    BULK 'https://stcloudopstgrm4.dfs.core.windows.net/data/tickets/it_tickets.csv',
    FORMAT = 'CSV', PARSER_VERSION = '2.0', HEADER_ROW = TRUE
) AS tickets;

-- A2. Ticket volume, open tickets and average resolution time by category
SELECT
    category,
    COUNT(*)                                         AS ticket_count,
    SUM(CASE WHEN status = 'Open' THEN 1 ELSE 0 END) AS open_tickets,
    AVG(TRY_CAST(resolution_hours AS FLOAT))         AS avg_resolution_hours
FROM OPENROWSET(
    BULK 'https://stcloudopstgrm4.dfs.core.windows.net/data/tickets/it_tickets.csv',
    FORMAT = 'CSV', PARSER_VERSION = '2.0', HEADER_ROW = TRUE
) AS tickets
GROUP BY category
ORDER BY ticket_count DESC;

-- A3. Workload by assignment group and priority
SELECT assignment_group, priority, COUNT(*) AS ticket_count
FROM OPENROWSET(
    BULK 'https://stcloudopstgrm4.dfs.core.windows.net/data/tickets/it_tickets.csv',
    FORMAT = 'CSV', PARSER_VERSION = '2.0', HEADER_ROW = TRUE
) AS tickets
GROUP BY assignment_group, priority
ORDER BY assignment_group, priority;

-- =============================================================================
-- B. PowerShell health-check reports
--    (run Get-CloudOpsReport.ps1 -UploadToDataLake a few times first,
--     including once during the drift test, so there is history to analyze)
-- =============================================================================

-- B1. Resource inventory by type, per health-check run
SELECT
    inv.filepath() AS report_file,
    Type,
    COUNT(*)       AS resource_count
FROM OPENROWSET(
    BULK 'https://stcloudopstgrm4.dfs.core.windows.net/data/inventory/*.csv',
    FORMAT = 'CSV', PARSER_VERSION = '2.0', HEADER_ROW = TRUE
) AS inv
GROUP BY inv.filepath(), Type
ORDER BY report_file DESC, resource_count DESC;

-- B2. Compliance trend: PASS/FAIL count per health-check run
SELECT
    checks.filepath()                                AS report_file,
    SUM(CASE WHEN Status = 'PASS' THEN 1 ELSE 0 END) AS passed,
    SUM(CASE WHEN Status = 'FAIL' THEN 1 ELSE 0 END) AS failed
FROM OPENROWSET(
    BULK 'https://stcloudopstgrm4.dfs.core.windows.net/data/checks/*.csv',
    FORMAT = 'CSV', PARSER_VERSION = '2.0', HEADER_ROW = TRUE
) AS checks
GROUP BY checks.filepath()
ORDER BY report_file;

-- B3. Which checks have failed, across all runs (shows the drift test)
SELECT Category, [Check], Target, COUNT(*) AS times_failed
FROM OPENROWSET(
    BULK 'https://stcloudopstgrm4.dfs.core.windows.net/data/checks/*.csv',
    FORMAT = 'CSV', PARSER_VERSION = '2.0', HEADER_ROW = TRUE
) AS checks
WHERE Status = 'FAIL'
GROUP BY Category, [Check], Target
ORDER BY times_failed DESC;
