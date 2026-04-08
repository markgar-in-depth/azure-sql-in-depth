# Chapter 20: Building Applications on Azure SQL

You've got your databases designed, secured, tuned, and scaled. Now it's time to build real applications on top of them. This chapter covers the full application lifecycle: connecting reliably, deploying schema changes through CI/CD pipelines, designing for disaster recovery, ingesting real-time data, automating recurring work, and integrating AI directly into your data tier. These are the patterns that separate a database-backed demo from a production system.

## Application Connectivity Fundamentals

Chapter 4 walked through connection setup basics. Here we'll go deeper into how connections actually work under the hood and how to authenticate applications without storing passwords.

### Connection Routing Architecture

Chapter 4 covered gateway routing and connection policies in detail. The key point for application design is: connections from inside Azure use **Redirect** by default (lower latency, direct-to-node after the gateway handshake), while connections from outside Azure use **Proxy** (every packet through the gateway). If your application runs inside a VNet with locked-down NSGs, ensure outbound rules allow both port 1433 and ports 11000–11999 for Redirect traffic.

> **Tip:** If you're connecting from outside Azure and can open the 11000–11999 port range, explicitly setting the connection policy to `Redirect` gives you the same latency benefit.

### Service Principal Authentication

Hardcoding passwords in connection strings is a well-known anti-pattern, but the alternative isn't always obvious. For application-to-database access, **managed identities** and **service principals** authenticated through Microsoft Entra ID are the right approach.

A **system-assigned managed identity** is tied to a specific Azure resource — your App Service, VM, or AKS pod. Azure manages the credential lifecycle automatically. You create a contained database user mapped to that identity:

```sql
CREATE USER [my-app-service] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [my-app-service];
ALTER ROLE db_datawriter ADD MEMBER [my-app-service];
```

In your application code, you acquire a token from the Azure Instance Metadata Service (IMDS) and pass it to the connection. With `Microsoft.Data.SqlClient` in .NET, it's automatic — set `Authentication=Active Directory Managed Identity` in the connection string and the SDK handles token acquisition and renewal.

A **user-assigned managed identity** works the same way but isn't tied to a single resource. You create it once and assign it to multiple services. This is useful when several applications need the same database permissions, or when you want identity to survive resource redeployment.

For scenarios outside Azure (local development, third-party services), register a **service principal** in Microsoft Entra ID and create a contained user mapped to it. The only difference from managed identity is how you acquire the token — using a client ID and secret (or, better, a certificate) instead of IMDS.

> **Gotcha:** Don't create SQL logins for applications. Microsoft Entra authentication gives you centralized credential management, token expiration, conditional access policies, and audit trails. SQL authentication gives you a password to rotate manually.

## Kubernetes Application Development

Containerized applications on Azure Kubernetes Service connect to Azure SQL Database the same way any application does — TDS over port 1433. But the orchestration layer adds considerations around identity, networking, and configuration management.

### Python/Flask with AKS and Azure SQL Database

Here's the pattern for a Python/Flask API running in AKS that connects to Azure SQL Database using a managed identity. The key pieces:

**1. Workload Identity Federation.** AKS supports workload identity, which maps a Kubernetes service account to a user-assigned managed identity. Your pod gets a federated token that it exchanges for a Microsoft Entra token — no secrets in your deployment YAML.

**2. The connection string.** Use `pyodbc` with the ODBC Driver 18 for SQL Server. The token is acquired via the `azure-identity` library:

```python
from azure.identity import DefaultAzureCredential
import pyodbc
import struct

credential = DefaultAzureCredential()
token = credential.get_token("https://database.windows.net/.default")
token_bytes = token.token.encode("utf-16-le")
token_struct = struct.pack(f"<I{len(token_bytes)}s", len(token_bytes), token_bytes)

conn = pyodbc.connect(
    "Driver={ODBC Driver 18 for SQL Server};"
    "Server=myserver.database.windows.net;"
    "Database=mydb;",
    attrs_before={1256: token_struct}
)
```

**3. The Docker image.** Include the ODBC driver in your Dockerfile. The Microsoft package repository provides pre-built packages for Debian and Ubuntu base images.

**4. Network path.** If your database has public access disabled, your AKS cluster needs a private endpoint or VNet integration to reach it. The redirect port range (11000–11999) applies here too.

> **Tip:** Store the server name and database name in a Kubernetes ConfigMap. Store nothing secret — the managed identity handles authentication without credentials.

## CI/CD Integration

Schema changes are code. They should be versioned, reviewed, tested, and deployed through the same pipeline as your application. Azure SQL Database works with dacpac-based deployments, migration-based frameworks (EF Core Migrations, Flyway, Liquibase), or plain SQL scripts. We'll focus on the dacpac approach with GitHub Actions because it's the most common pattern for teams already using SQL Server Data Tools (SSDT).

### GitHub Actions for Dacpac Deployment

A dacpac (Data-tier Application Package) captures your database schema as a model. When deployed, SqlPackage compares the model against the target database and generates an incremental ALTER script. No manual diffing, no missed columns.

Here's a minimal GitHub Actions workflow:

```yaml
name: Deploy Database Schema
on:
  push:
    branches: [main]
    paths: ['database/**']

permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build dacpac
        run: dotnet build database/MyDatabase.sqlproj -o ./output

      - name: Azure Login (OIDC)
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Deploy to Azure SQL
        uses: azure/sql-action@v2
        with:
          connection-string: 'Server=myserver.database.windows.net;Database=mydb;Authentication=Active Directory Default;'
          dacpac-package: ./output/MyDatabase.dacpac
```

### OIDC Authentication

The workflow above uses **OpenID Connect (OIDC) federation** end to end. The `azure/login` step establishes a trust relationship between your GitHub repository and a Microsoft Entra application registration — GitHub's OIDC provider issues a short-lived token for each workflow run, and Azure accepts it as proof of identity. The `azure/sql-action` step then uses `Authentication=Active Directory Default` in the connection string, which picks up the OIDC-authenticated session from `azure/login`. No client secrets anywhere in the pipeline.

Set this up by creating a federated credential on your app registration, specifying the GitHub organization, repository, and branch.

> **Important:** Scope your service principal to the minimum permissions needed. For dacpac deployment, it needs `db_ddladmin` on the target database — not server-level admin.

### Deployment Safety

SqlPackage can generate a drift report before applying changes, and it respects `/p:BlockOnPossibleDataLoss=true` by default. For production deployments, add a step that generates the deployment script (`/Action:Script`) and posts it as a pull request comment for human review before applying it.

## DR-Aware Application Design

Your database is geo-replicated and failover groups are configured. But the database's HA doesn't mean your application is resilient — you have to design the application to follow the database when it moves. This section covers multi-region patterns that keep your application available when a region goes down.
<!-- Source: azure-sql-database-sql-db/how-to/design-data-applications/designing-cloud-solutions-for-disaster-recovery.md -->

### Connection Management During Failover

The most common DR mistake isn't missing a replica — it's hardcoding server names. Always connect through the failover group listener endpoint (`<group-name>.database.windows.net` for read-write, `<group-name>.secondary.database.windows.net` for read-only). These DNS names follow the database when it moves. Store them in configuration, not in code.
<!-- Source: azure-sql-database-sql-db/concepts/business-continuity/high-availability-disaster-recovery-checklist.md -->

When a failover happens, existing connections break. Your application sees `SqlException` errors — typically error 40613 (database unavailable) or socket-level connection resets. The listener DNS updates within seconds, but TCP connections to the old IP hang until they time out. Two things make this survivable:

1. **Retry logic with backoff.** Every database call should retry on transient errors. Use exponential backoff starting at 1 second, capping at 30 seconds. Most client libraries have built-in support — `Microsoft.Data.SqlClient` has `ConnectRetryCount` and `ConnectRetryInterval` in the connection string; EF Core has `EnableRetryOnFailure()`. For pyodbc and JDBC, implement retry in your middleware or use a library like `tenacity` (Python) or `resilience4j` (Java).

2. **Short connection timeouts.** Set `Connection Timeout=30` (not the default 15 seconds, which is too aggressive during failover, but not so long that users stare at a spinner). Combine with `ConnectRetryCount=3` and `ConnectRetryInterval=10` so the client attempts reconnection across the DNS propagation window.

> **Gotcha:** DNS caching can delay failover from the application's perspective. .NET's `ServicePointManager` caches DNS for 2 minutes by default. Set `ServicePointManager.DnsRefreshTimeout` to 30 seconds in DR-critical applications. On Linux containers, check `/etc/resolv.conf` for stale resolver settings.

### Application-Level Health Checks

Don't rely solely on Traffic Manager or your load balancer to detect a database failover. Add an explicit health endpoint in your application that tests the database connection:

```csharp
app.MapGet("/health/db", async (SqlConnection conn) =>
{
    try
    {
        await conn.OpenAsync();
        await using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT 1";
        cmd.CommandTimeout = 5;
        await cmd.ExecuteScalarAsync();
        return Results.Ok();
    }
    catch
    {
        return Results.StatusCode(503);
    }
});
```

This endpoint should use the same failover group listener as production traffic. When it returns 503, your load balancer routes users to the secondary region's application instance — which connects to the same listener and reaches the new primary. Test this regularly by triggering a manual failover.

### Multi-Region Patterns with Failover Groups and Traffic Manager

The simplest DR topology uses a failover group with Azure Traffic Manager. Your application deploys to two regions. Traffic Manager routes users to the primary region. The failover group provides a read-write listener endpoint (`<group-name>.database.windows.net`) that always points to the current primary.

When a regional outage occurs:

1. The failover group detects the outage and promotes the secondary database (after the configured grace period).
2. Traffic Manager detects the application endpoint failure in the primary region and redirects traffic to the secondary region.
3. The application in the secondary region connects to the same failover group listener — which now resolves to the new primary.

> **Gotcha:** Traffic Manager failover and database failover are independent. Traffic Manager might redirect users before the database failover completes. Your application must handle transient connection failures gracefully with retry logic during this window.

For applications that can tolerate read-only access during an outage, use both the read-write and read-only listener endpoints. When the primary region fails, the application detects write failures and switches to read-only mode using the read-only endpoint, which resolves to the secondary. This keeps users productive while the failover completes.
<!-- Source: azure-sql-database-sql-db/how-to/design-data-applications/designing-cloud-solutions-for-disaster-recovery.md -->

| Pattern | RPO | Recovery time |
|---|---|---|
| Active-passive with co-located DB | < 5 sec (writes) | DNS TTL + detection |
| Active-passive, data preservation | 0 (read-only mode) | Read-only: immediate |
| Active-active load balanced | < 5 sec (writes) | DNS TTL + detection |

### Rolling Upgrades via Geo-Replication

Database upgrades are disruptive. If your schema change fails, you need a rollback path that doesn't involve restoring from backup. Active geo-replication gives you one.
<!-- Source: azure-sql-database-sql-db/how-to/design-data-applications/manage-application-rolling-upgrade.md -->

The pattern:

1. Create a geo-secondary of your production database.
2. Set the primary to read-only mode.
3. Disconnect the secondary (breaking the replication link) — you now have two independent copies.
4. Run your upgrade script against the disconnected copy.
5. If the upgrade succeeds, swap the application's staging and production environments.
6. If it fails, discard the upgraded copy and revert the primary to read-write.

This approach gives you a fully synchronized rollback target at every step. The downside: the application is in read-only mode for the duration of the upgrade script.

For applications that are already geo-redundant, extend this pattern by creating staging environments in both regions with chained geo-replication. The upgrade runs in parallel across both regions, and you swap both staging environments simultaneously. More complex, but your DR posture is never compromised during the upgrade.

### Elastic Pool DR Strategies for SaaS Applications

SaaS applications with per-tenant databases face a unique DR challenge: you might have hundreds of tenant databases in elastic pools, each needing recovery. The strategies scale differently depending on cost tolerance.
<!-- Source: azure-sql-database-sql-db/how-to/design-data-applications/disaster-recovery-strategies-for-applications-with-elastic-pool.md -->

**Cost-sensitive approach:** Don't geo-replicate tenant databases. Instead, geo-replicate only the management databases (user profiles, billing) using failover groups. If the primary region goes down, create a new elastic pool in the DR region and restore tenant databases using geo-restore. Recovery time depends on the number of databases and their sizes — it can be slow, but the ongoing cost is minimal.

**Tiered-SLA approach:** Separate tenants by tier. Paying customers get geo-replicated databases in a secondary pool — failover is fast (metadata-level swap). Free-tier tenants use geo-restore — slower, but the cost of geo-replication is only borne by revenue-generating tenants.

**Geographically distributed approach:** Split paying tenants 50/50 across two regions, each with active databases. A regional outage impacts only half the paid tenants. The other half continues uninterrupted. This is the most resilient but also the most expensive and operationally complex.

> **Tip:** Batch failover operations. The failover API processes individual databases, and initiating hundreds of failovers sequentially is slow. Batch them in groups of at least 20 for reasonable recovery times.

## Azure Stream Analytics Integration

Sometimes you need data flowing *into* your database in real time rather than batch-loading it. Azure Stream Analytics provides a managed service that can ingest events from Event Hubs or IoT Hub, transform them with a SQL-like query language, and write the results directly to Azure SQL Database.
<!-- Source: azure-sql-database-sql-db/how-to/performance/stream-data-stream-analytics-integration.md -->

The integration is available directly from the Azure portal: navigate to your database, select **Stream analytics (preview)** under Integrations, and configure an input source, a transformation query, and an output table. The portal pre-fills your database context, so setup is straightforward.

The Stream Analytics Query Language (SAQL) supports windowing functions (tumbling, hopping, sliding, session windows), temporal joins, and pattern matching. A typical use case: aggregate IoT sensor readings into 5-minute averages and insert them into a summary table.

```sql
-- Stream Analytics query: 5-minute average temperature by device
SELECT
    deviceId,
    AVG(temperature) AS avg_temp,
    System.Timestamp() AS window_end
INTO [sql-output]
FROM [eventhub-input]
GROUP BY deviceId, TumblingWindow(minute, 5)
```

> **Note:** This integration is in preview. Stream Analytics can also output to Azure SQL Managed Instance and Azure Synapse Analytics, but the portal-integrated setup experience is specific to Azure SQL Database.

Key configuration decisions:

- **Streaming units** control throughput and cost. Start small (1–3 SUs) and scale based on observed lag.
- **Undersizing symptoms:** If SUs can't keep up with the incoming event rate, events queue in the input source (Event Hub or IoT Hub) and the **input backlog** metric climbs. The job won't drop events (unless you configured the Drop error policy), but latency degrades until you add SUs or the input rate drops.
- **Error handling:** Choose between *Retry* (blocks on errors, guarantees delivery order) and *Drop* (skips bad records, maintains throughput). For most analytical workloads, Drop with dead-letter logging is the right choice.
- **Partitioning:** If your query supports it, enable parallel writes to the output table. This requires the Stream Analytics query's partition key to align with the target table's structure.

## Automation and Job Scheduling

Databases don't just serve queries — they need ongoing maintenance, data movement, and operational tasks. Azure SQL provides several automation mechanisms, each suited to different scenarios.
<!-- Source: azure-sql-database-sql-db/how-to/elastic-jobs/elastic-jobs-overview.md, azure-sql-database-sql-db/how-to/elastic-jobs/job-automation-overview.md -->

### Elastic Jobs: Cross-Database T-SQL Execution at Scale

**Elastic jobs** are the native job scheduling service for Azure SQL Database. They run T-SQL scripts across one or many databases — on a schedule or on demand. If you've used SQL Server Agent, elastic jobs serve a similar purpose, but they're designed for the multi-database, multi-server reality of cloud architectures.

#### Architecture

An elastic job system has four components:

- **Job agent:** The Azure resource that orchestrates job execution. You create it in the portal, PowerShell, or via REST API.
- **Job database:** An Azure SQL Database that stores job definitions, execution history, and metadata. This must be an existing database — the agent configures it during creation.
- **Target group:** Defines where a job runs. A target group can include individual databases, all databases on a server, all databases in an elastic pool, or any combination. Targets are resolved dynamically at runtime — if you add a database to a targeted server after creating the job, the new database is included automatically.
- **Job steps:** The T-SQL scripts that execute against each target. Each step has its own timeout, retry policy, and optional output capture.

#### Authentication

Elastic jobs support two authentication methods for connecting to target databases:

| Method | Recommendation |
|---|---|
| Microsoft Entra (UMI) | **Recommended.** User-assigned managed identity. No passwords to manage. |
| Database-scoped credentials | Legacy approach. Requires matching logins on every target. |

With UMI authentication, you create a user-assigned managed identity, assign it to the job agent, and create contained database users mapped to that identity on each target:

```sql
-- On each target database
CREATE USER [job-agent-UMI] FROM EXTERNAL PROVIDER;
GRANT ALTER ON SCHEMA::dbo TO [job-agent-UMI];
GRANT CREATE TABLE TO [job-agent-UMI];
```
<!-- Source: azure-sql-database-sql-db/how-to/elastic-jobs/elastic-jobs-tsql-create-manage.md -->

#### Creating and Running Jobs

Define a target group, create a job, add steps, and execute:

```sql
-- Create a target group
EXEC jobs.sp_add_target_group 'AllProductionDatabases';

EXEC jobs.sp_add_target_group_member
    @target_group_name = 'AllProductionDatabases',
    @target_type = 'SqlServer',
    @server_name = 'prod-server.database.windows.net';

-- Create a job
EXEC jobs.sp_add_job @job_name = 'UpdateStatistics';

-- Add a step
EXEC jobs.sp_add_jobstep
    @job_name = 'UpdateStatistics',
    @step_name = 'RunUpdateStats',
    @command = N'EXEC sp_updatestats;',
    @target_group_name = 'AllProductionDatabases',
    @max_parallelism = 10;

-- Schedule it
EXEC jobs.sp_update_job
    @job_name = 'UpdateStatistics',
    @enabled = 1,
    @schedule_interval_type = 'Days',
    @schedule_interval_count = 1,
    @schedule_start_time = '2025-01-01T02:00:00';
```

The `@max_parallelism` parameter controls how many target databases execute concurrently. The job agent has tiered capacity:

| Agent tier | Max concurrent jobs |
|---|---|
| JA100 (default) | 100 |
| JA200 | 200 |
| JA400 | 400 |
| JA800 | 800 |
<!-- Source: azure-sql-database-sql-db/how-to/elastic-jobs/elastic-jobs-overview.md -->

> **Important:** Elastic job scripts must be **idempotent**. Transient failures trigger automatic retries, so your script must produce the same result whether it runs once or multiple times.

#### Managed Private Endpoints

If your target databases have public access disabled, the job agent can't reach them over the internet. Elastic job private endpoints solve this: you create a service-managed private endpoint from the job agent to each target server. This establishes a private link so the agent can execute jobs even when **Deny Public Access** is enabled.

The private endpoint is per-server (not per-database), and you must approve it on the target server's Networking pane before the agent can use it. The job agent's connection to its own job database does *not* use private endpoints — it uses internal certificate-based authentication.
<!-- Source: azure-sql-database-sql-db/how-to/elastic-jobs/elastic-jobs-overview.md -->

### SQL Agent on Managed Instance

Azure SQL Managed Instance includes a full SQL Server Agent — the same agent you know from on-premises SQL Server. It runs T-SQL job steps, SSIS packages, replication steps, and OS command/PowerShell steps. For teams migrating from SQL Server, this is often the path of least resistance.
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/automation/job-automation-managed-instance.md -->

Key features:

- **Multi-step workflows:** Chain steps with success/failure branching. Each step can have its own retry policy.
- **Schedules:** One-time, recurring, or triggered on instance restart (useful for post-failover tasks).
- **Database Mail notifications:** Configure an email profile (which *must* be named `AzureManagedInstance_dbmail_profile`) to notify operators on job success, failure, or completion.

```sql
-- Configure Database Mail
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;
EXEC sp_configure 'Database Mail XPs', 1;
RECONFIGURE;

-- Create a mail profile (name is mandatory)
EXEC msdb.dbo.sysmail_add_profile_sp
    @profile_name = 'AzureManagedInstance_dbmail_profile',
    @description = 'Managed Instance SQL Agent mail.';
```
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/automation/job-automation-managed-instance.md -->

> **Gotcha:** SQL Agent on Managed Instance has limitations compared to on-premises: settings are read-only (`sp_set_agent_properties` isn't supported), alerts aren't supported, proxies aren't supported, and you can't run scripts from disk files. Job history retention is fixed at 1,000 total records and 100 per job.

### Azure Automation Runbooks

Azure Automation provides a third option: PowerShell and Python runbooks that run on a schedule or in response to events. Runbooks can call the Azure SQL PowerShell cmdlets to manage databases, execute queries, or orchestrate multi-step workflows across Azure services.
<!-- Source: azure-sql-database-sql-db/how-to/manage/automation-manage.md -->

Use managed identities (not the retired Run As accounts) for authentication. Runbooks are best suited for tasks that cross service boundaries — for example, scaling a database before a scheduled batch load, then scaling it back down after.

### Comparing Automation Options

Synapse pipelines target Synapse Analytics pools, not Azure SQL Database or Managed Instance, so they're omitted here. The comparison below focuses on the options that target Azure SQL workloads.
<!-- Source: azure-sql-database-sql-db/how-to/elastic-jobs/job-automation-overview.md -->

**SQL-native options:**

| | Elastic jobs | SQL Agent (MI) |
|---|---|---|
| **Platform** | SQL Database | Managed Instance |
| **Cross-DB** | Yes (many) | Single instance |
| **T-SQL** | Native | Native |
| **Non-SQL** | No | PowerShell, SSIS |
| **Private** | Private endpoints | VNet-native |

**Platform-level options:**

| | Automation | Fabric |
|---|---|---|
| **Platform** | Any Azure | Fabric SQL DB |
| **Cross-DB** | Via PowerShell | Via pipelines |
| **T-SQL** | Via cmdlets | Via activities |
| **Non-SQL** | Yes | Yes |
| **Private** | IP-based | Managed |

## AI and Copilot Integration

Azure SQL Database is increasingly a participant in AI workflows, not just a data store that AI applications query. The database engine now has native vector support, can call external REST APIs, and exposes a governed interface for AI agents.
<!-- Source: azure-sql-database-sql-db/overview/ai-artificial-intelligence-intelligent-applications.md -->

### RAG Patterns with Azure OpenAI

**Retrieval Augmented Generation (RAG)** is the dominant pattern for grounding large language models in domain-specific data. Instead of fine-tuning a model on your data (expensive, slow, stale), you retrieve relevant context at query time and include it in the prompt.

Azure SQL Database fits naturally into RAG architectures:

1. Store your domain data in tables.
2. Generate vector embeddings for searchable content using Azure OpenAI's embedding models.
3. Store those embeddings alongside the source data.
4. At query time, embed the user's question, find the nearest vectors, and pass the matching rows to the LLM as context.

You can call Azure OpenAI directly from T-SQL using `sp_invoke_external_rest_endpoint`:

```sql
DECLARE @retval INT, @response NVARCHAR(MAX);
DECLARE @payload NVARCHAR(MAX) = JSON_OBJECT('input': @text);

EXEC @retval = sp_invoke_external_rest_endpoint
    @url = 'https://myoai.openai.azure.com/openai/deployments/text-embedding-ada-002/embeddings?api-version=2023-03-15-preview',
    @payload = @payload,
    @response = @response OUTPUT;
```
<!-- Source: azure-sql-database-sql-db/overview/ai-artificial-intelligence-intelligent-applications.md -->

This keeps the embedding pipeline inside the database — no external ETL needed for vectorization.

### Vector Data Type, Vector Functions, and Embeddings

Azure SQL Database now has a native **vector** data type. Instead of storing embeddings as JSON arrays or varbinary blobs, you declare a column as `vector(N)` where N is the dimension count:

```sql
CREATE TABLE articles (
    id INT NOT NULL PRIMARY KEY,
    title NVARCHAR(200),
    content NVARCHAR(MAX),
    embedding vector(1536) NOT NULL
);
```

The `VECTOR_DISTANCE` function calculates similarity between two vectors using cosine, dot product, or Euclidean distance:

```sql
DECLARE @query_vector vector(1536) = @embedding_from_openai;

SELECT TOP 10 id, title,
    VECTOR_DISTANCE('cosine', @query_vector, embedding) AS distance
FROM articles
ORDER BY VECTOR_DISTANCE('cosine', @query_vector, embedding);
```
<!-- Source: azure-sql-database-sql-db/overview/ai-artificial-intelligence-intelligent-applications.md -->

This is exact nearest neighbor search — not approximate. For most workloads up to millions of rows, the performance is excellent because the database engine can combine vector distance calculations with traditional query optimization (index seeks on filtered columns, partition elimination).

> **Tip:** You don't need a dedicated vector database. Storing embeddings alongside relational data in Azure SQL Database eliminates synchronization headaches and lets you combine vector similarity with traditional WHERE clauses in a single query.

### SQL MCP Server

When you build an AI agent that needs database access, you have options: give it a REST API, let it generate raw SQL, or use a protocol designed for the task. REST APIs require you to anticipate every query an agent might need and build endpoints for each one. Raw SQL generation (text-to-SQL) is fragile — models hallucinate column names, ignore permissions, and produce queries that are syntactically valid but semantically wrong. You end up writing elaborate prompt engineering to compensate.

The **Model Context Protocol (MCP)** takes a different approach. The SQL MCP Server provides a governed interface between AI agents and your Azure SQL Database — a structured contract that lets agents discover what they can do without guessing at schema.
<!-- Source: azure-sql-database-sql-db/overview/ai-artificial-intelligence-intelligent-applications.md -->

Instead of giving a model raw schema access, the MCP server defines a set of tools backed by your configuration:

- **Entities** map to tables or views, with fine-grained access control.
- **Roles and constraints** are enforced consistently — the agent discovers available capabilities through the protocol, not through prompt instructions.
- **Operations** are routed through the defined toolset, not through arbitrary generated SQL.

The separation between reasoning (what the model decides to do) and execution (how queries are built and run) means fewer errors and no need for complex prompt engineering to handle schema ambiguity. The same Data API builder configuration that powers REST and GraphQL endpoints also governs MCP access, so if you've already defined your API surface, MCP adds agent access without duplicating rules.

> **Tip:** Start with MCP if you're building agent-driven applications from scratch. If you already have REST endpoints that cover your access patterns, MCP adds value when agents need to compose queries dynamically rather than calling fixed endpoints.

### Microsoft Copilot in Azure for SQL Database

Microsoft Copilot in Azure brings natural-language administration to the Azure portal. Navigate to your database in the portal, and Copilot can answer questions grounded in your specific database context — drawing from documentation, DMVs, catalog views, Query Store, and Azure diagnostics.
<!-- Source: azure-sql-database-sql-db/overview/copilot-azure-sql-overview.md -->

Practical uses:

- **Performance troubleshooting:** "Why is my database slow?" triggers analysis of wait stats, expensive queries, and resource utilization.
- **Index recommendations:** "Should I add an index on this table?" uses Query Store data to suggest missing indexes.
- **Connectivity help:** "Which connection string should I use?" generates the right connection string for your database.
- **Administrative queries:** "What are the longest running queries in the past day?" pulls from Query Store.
<!-- Source: azure-sql-database-sql-db/overview/copilot-prompts-list.md -->

Copilot respects your existing RBAC permissions — it can only access resources and perform actions that you're authorized for. Your prompts and responses aren't used to train the underlying models. The feature is available at no additional cost.

> **Note:** Copilot is AI-powered, so responses can be wrong. Always verify generated queries before running them against production databases. Treat Copilot as a fast starting point, not an oracle.

The AI integration story here isn't about replacing your application logic with LLM calls. It's about making your database a first-class participant in AI workflows — storing and searching vectors natively, calling AI services directly from T-SQL, exposing governed interfaces for agents, and using natural language to reduce the friction of database administration. The tools are production-ready. The patterns in this chapter give you the starting points to wire them into your applications.

In the next chapter, we shift from building applications to migrating existing ones — the planning, assessment, and decision framework for moving workloads to Azure SQL.
