-- Run once in the Azure portal: SQL database > Query editor (log in with Entra ID).
-- 1. The table for the measurements (same columns as in CS1, plus host)
CREATE TABLE measurements (
    id          INT IDENTITY(1,1) PRIMARY KEY,
    [timestamp] NVARCHAR(19)  NOT NULL,
    host        NVARCHAR(100) NOT NULL,
    metric      NVARCHAR(50)  NOT NULL,
    value       FLOAT         NOT NULL
);

-- 2. A database user for the API's managed identity (no password)
CREATE USER [app-kh-monitoring-yailin01] FROM EXTERNAL PROVIDER;

-- 3. Least privilege: the API may only read and write data
ALTER ROLE db_datareader ADD MEMBER [app-kh-monitoring-yailin01];
ALTER ROLE db_datawriter ADD MEMBER [app-kh-monitoring-yailin01];
