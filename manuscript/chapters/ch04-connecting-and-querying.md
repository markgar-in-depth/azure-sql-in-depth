# Chapter 4: Connecting and Querying

Your database is provisioned, your tier is chosen, and now you need to actually talk to it. Connecting to Azure SQL sounds simple — it's just a connection string, right? — but the path between your application and the database engine involves gateways, connection policies, TLS negotiation, and retry logic that you'll want to understand before your first production incident teaches you the hard way.

This chapter covers how connections work across all three deployment models, which tools to use for interactive queries, and how to connect from application code with resilience built in.

## Connection Architecture
<!-- Source: azure-sql-database-sql-db/concepts/connectivity/connectivity-architecture.md -->

Every connection to Azure SQL Database passes through a regional **gateway** — a fleet of stateless proxy nodes that sit between your client and the database cluster. The gateway listens on port 1433, performs initial authentication, and then routes traffic based on the server's **connection policy**.

### Gateway Routing: Redirect vs. Proxy

The connection policy determines what happens *after* the gateway completes the initial handshake. There are three settings, but really two behaviors:

**Redirect** routes the client directly to the database node after the initial gateway handshake. The gateway hands the client a redirect token containing the node's IP and a port in the 11000–11999 range. All subsequent packets bypass the gateway entirely, flowing straight to the compute node. This gives you lower latency and higher throughput.

**Proxy** keeps every packet flowing through the gateway for the lifetime of the connection. The gateway acts as a middleman for every query and every result set. This adds latency and reduces throughput, but it simplifies firewall rules — you only need to allow outbound traffic to the gateway IP on port 1433.

**Default** is what you get if you don't change anything. It applies Redirect for connections originating inside Azure (like from a VM or App Service) and Proxy for connections coming from outside Azure (your laptop, an on-premises server). For most production workloads running inside Azure, the Default policy already gives you the Redirect benefit.

| Policy | Ports Required | Latency | When Applied by Default |
|---|---|---|---|
| Redirect | 1433 + 11000–11999 | Lower | Connections from Azure |
| Proxy | 1433 only | Higher | Connections from outside |
| Default | Depends on origin | Depends | New servers |

> **Tip:** If your application runs inside Azure, explicitly set the connection policy to Redirect. The Default policy already does this, but being explicit protects you if the behavior ever changes. You'll need outbound rules allowing the 11000–11999 port range across your region's SQL service tag.

### Regional Gateway IPs and Port Requirements

Each Azure region has a set of gateway IP address ranges. When using the Proxy policy, clients must be able to reach all the gateway IPs for the server's region on port 1433. With Redirect, clients additionally need outbound access on ports 11000–11999 to the broader set of IPs covered by the `Sql.<region>` service tag.
<!-- Source: azure-sql-database-sql-db/concepts/connectivity/connectivity-architecture.md -->

If you're using **Private Link**, your client connects through a private endpoint in your VNet and doesn't need connectivity to any of the public gateway IP ranges.

> **Gotcha:** The Dedicated Administrator Connection (DAC) uses TCP ports 1434 and 14000–14999. If you need DAC access for emergency troubleshooting, make sure those ports are open too.

### How Connections Differ Across Deployment Models

The gateway architecture described above applies to **Azure SQL Database**. Managed Instance and SQL Server on VMs each have distinct connectivity paths.

**SQL Database** connections always go through the regional gateway. You connect to `<server>.database.windows.net` on port 1433, and the gateway routes you based on the connection policy.

**Managed Instance** lives inside your VNet. Its VNet-local endpoint resolves to a private IP on an internal load balancer within the instance's subnet. The load balancer routes to the gateway inside the virtual cluster, which directs traffic to the correct SQL engine node. Connections from within the same VNet or peered VNets hit this endpoint directly — no public gateway involved.

**SQL Server on Azure VMs** is just SQL Server. You connect to the VM's IP address (public or private) on whatever port SQL Server is configured to listen on — typically 1433. There's no Azure-managed gateway layer. Connectivity depends entirely on your VM's network security group rules, the Windows firewall on the VM, and whether TCP/IP is enabled in SQL Server Configuration Manager.

## Connectivity Settings
<!-- Source: azure-sql-database-sql-db/concepts/connectivity/connectivity-settings.md -->

Beyond the connection policy, several server-level settings control who and what can connect.

### Public vs. Private Network Access

The **Public network access** setting on a logical server controls whether the public endpoint accepts connections at all. When set to **Disable**, only private endpoint connections are allowed. Any attempt to connect via the public endpoint returns error 47073.

When set to **Selected networks**, you can layer IP firewall rules and VNet rules on top. Network security is covered in depth in Chapter 6 — for now, know that this toggle exists and that disabling public access is the strongest posture for production databases that only need to be reached from within Azure.

### Minimum TLS Version

Azure SQL Database enforces a minimum TLS version at the server level. The current baseline is TLS 1.2 — TLS 1.0 and 1.1 are retired and no longer available. You can also enforce TLS 1.3 if your drivers and operating systems support it.
<!-- Source: azure-sql-database-sql-db/concepts/connectivity/connectivity-settings.md -->

> **Warning:** Enforcing TLS 1.3 can break connectivity for clients using older drivers that don't support it. Not all driver/OS combinations have TLS 1.3 support yet. Test thoroughly before raising the minimum.

If a client attempts to connect with a TLS version below the minimum, the connection fails with error 47072: `Login failed with invalid TLS version`.

You can identify clients still using older TLS versions through the Azure portal's **Metrics** blade (filter by *Successful connections* and *TLS versions*) or by querying `sys.fn_get_audit_file` for the `client_tls_version_name` field.

### TLS Root Certificate Rotation

Azure periodically rotates the root Certificate Authority (CA) for TLS connections. This happens because industry compliance requirements — set by the CA/Browser Forum — sometimes flag existing root CAs as noncompliant, forcing Azure to switch to certificates signed by compliant authorities. When a rotation happens, clients that pin to a specific root CA certificate may lose connectivity. The safest approach is to trust the Microsoft RSA Root Certificate Authority 2017 and not pin to intermediate certificates. Most modern drivers and operating systems handle this automatically, but if you've hardcoded certificate thumbprints, you'll need to update them before the rotation deadline.
<!-- Source: resources/service-updates/ssl-root-certificate-expiring.md -->

> **Tip:** Set `TrustServerCertificate=false` and `Encrypt=true` in your connection strings. This ensures encrypted connections while still validating the server certificate against your OS trust store — which will pick up new root CAs automatically.

### Connection Types for Managed Instance
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/configure-networking/connection-types-overview.md -->

Managed Instance supports the same Redirect and Proxy concepts, but the mechanics differ. The VNet-local endpoint uses **Redirect** by default (as of October 2025). After the initial handshake through the internal gateway, clients connect directly to the database node within the subnet. For the Redirect *performance benefits*, your client needs a driver that supports TDS 7.4 or later (SQL Server 2012+ drivers) and must be able to reach the entire subnet IP range on port 1433. Older clients still connect — the gateway silently routes them through the less performant Proxy path instead.

The **public endpoint** (port 3342) and **private endpoints** (port 1433) always use the Proxy connection type, regardless of the instance-level setting.

| MI Endpoint | Port | Connection Type | Notes |
|---|---|---|---|
| VNet-local | 1433 | Redirect (default) | Best performance |
| Public | 3342 | Proxy (always) | Internet-reachable |
| Private endpoint | 1433 | Proxy (always) | Fixed IP in another VNet |

> **Gotcha:** The silent fallback means you'll get Proxy-level latency and throughput without any error — a nasty surprise if you're expecting Redirect performance. Check your driver version against the recommended drivers list to confirm you're getting the direct path.

## Tools for Interactive Queries

Before writing application code, you'll want a way to run ad-hoc queries. Here are the main options, roughly ordered from "no install required" to "most powerful."

### Azure Portal Query Editor

The Azure portal includes a built-in query editor for SQL Database. Navigate to your database, select **Query editor** from the resource menu, and authenticate with SQL or Microsoft Entra credentials. It's convenient for quick checks — verifying a table exists, running a simple SELECT, checking row counts.
<!-- Source: azure-sql-database-sql-db/how-to/connect-and-query/connect-and-run-ad-hoc-queries/query-editor.md -->

Limitations to know: queries time out after 5 minutes, it can't connect to the logical server's `master` database, it has IntelliSense for table and view names but not columns, and it doesn't support `ApplicationIntent=ReadOnly` for read replicas. For anything beyond quick checks, use a desktop tool.

> **Note:** The portal query editor communicates over TCP port 443. If you see connection errors in the query editor but your client tools work fine, your browser's network may be blocking outbound traffic on that port.

### SQL Server Management Studio (SSMS)

SSMS is the full-featured GUI for SQL Server and Azure SQL. It provides object explorer, query execution plans, IntelliSense, schema comparison, and almost everything else you'd want for database administration. It runs on Windows only. Use version 18.0 or later for the best Azure SQL compatibility, though the latest release is always recommended.

### VS Code with the mssql Extension

If you prefer a lightweight, cross-platform editor, the **mssql extension for Visual Studio Code** provides IntelliSense, query execution, and result grid export. It runs on Windows, macOS, and Linux. It won't replace SSMS for heavy administration tasks, but for writing and testing queries during development, it's excellent.

### sqlcmd and bcp

**sqlcmd** is the command-line query tool for SQL Server. It's invaluable for scripting — CI/CD pipelines, deployment scripts, health checks. The modern Go-based `sqlcmd` (available via `winget`, `brew`, or direct download) supports Microsoft Entra authentication natively.

**bcp** (bulk copy program) is the command-line tool for bulk data import and export. It's the fastest way to move flat files in and out of SQL Server. We'll use it in Chapter 5 when we cover loading data.

## Connecting from Application Code
<!-- Source: shared-sql-db-sql-mi-docs/shared-how-tos/develop-data-applications/develop-overview.md -->

This is where most developers spend their time: building and maintaining the code that connects your application to Azure SQL.

### Connection Libraries Overview

Azure SQL Database and Managed Instance support the TDS (Tabular Data Stream) protocol, the same wire protocol that SQL Server has used for decades. Any driver that speaks TDS can connect. Here are the primary options by language:

| Language | Driver / Library | Package |
|---|---|---|
| C# / .NET | Microsoft.Data.SqlClient | NuGet |
| Java | Microsoft JDBC Driver | Maven Central |
| Python | pyodbc (via ODBC Driver) | PyPI |
| Node.js | tedious / mssql | npm |
| Go | go-mssqldb | Go modules |
| PHP | SQLSRV / PDO_SQLSRV | PECL |
| Ruby | tiny_tds | RubyGems |
| C/C++ | ODBC Driver for SQL Server | Microsoft Download |

> **Important:** For .NET applications, use `Microsoft.Data.SqlClient`, not the older `System.Data.SqlClient`. The new library gets active feature development — configurable retry logic, Microsoft Entra token support, and improved Always Encrypted support. `System.Data.SqlClient` is in maintenance mode.

### Building a Connection String

A connection string for Azure SQL Database looks like this:

```
Server=tcp:myserver.database.windows.net,1433;Initial Catalog=mydb;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;Authentication=Active Directory Default;
```

The key parts:

- **Server**: The fully qualified domain name of your logical server, suffixed with `.database.windows.net`. Always include the `tcp:` prefix and port `,1433` explicitly — it prevents ambiguity.
- **Initial Catalog**: Your database name. Don't omit this; without it, you connect to `master`, which isn't what you want from application code.
- **Encrypt=True**: Non-negotiable. Azure SQL Database requires encrypted connections. Most modern drivers default to this, but be explicit.
- **TrustServerCertificate=False**: Validates the server's TLS certificate. Set this to `False` in production. Setting it to `True` skips validation and opens the door to man-in-the-middle attacks.
- **Connection Timeout**: How long the driver waits for the initial connection. The default of 15 seconds is too short for cloud connections — use at least 30 seconds.
- **Authentication**: `Active Directory Default` uses `DefaultAzureCredential`, which automatically picks up your identity from the environment — managed identity in Azure, Azure CLI credentials locally.

> **Gotcha:** Don't embed passwords in connection strings stored in source control. Use Microsoft Entra (passwordless) authentication with managed identities for deployed applications, and Azure CLI or Visual Studio credentials for local development. If you must use SQL authentication, store the password in Azure Key Vault or environment variables.

For Managed Instance, the server name follows the pattern `<instance>.dns-zone.database.windows.net`. For SQL Server on VMs, it's the VM's IP or DNS name, optionally with a custom port: `Server=sqlvm.eastus.cloudapp.azure.com,1433`.

### Connection Pooling Fundamentals

Opening a TCP connection, performing a TLS handshake, and authenticating takes time — often 50–200ms or more. Connection pooling keeps a cache of open, authenticated connections that your application can reuse.
<!-- TODO: source needed for "50–200ms" connection establishment latency -->

In ADO.NET, pooling is enabled by default. When you call `SqlConnection.Open()`, the runtime checks the pool for an existing connection with matching connection string parameters. If one is available, you get it immediately. When you call `Close()` or `Dispose()`, the connection returns to the pool rather than being destroyed.

Most other drivers handle pooling similarly. The `mssql` package for Node.js manages its own pool. JDBC has pooling via connection pool managers like HikariCP.

Key pooling rules:

- **Close connections promptly.** Don't hold a connection while doing non-database work. The pool can't reuse what you're holding.
- **Keep connection strings identical.** A single character difference in the connection string creates a separate pool. Centralize your connection string construction.
- **Size the pool for your workload.** ADO.NET defaults to a maximum of 100 connections per pool. If you hit the ceiling, new requests block until a connection is returned.
<!-- TODO: source needed for "100 connections per pool" ADO.NET default -->
- **Avoid long-running transactions.** They hold connections for extended periods, starving other requests. If possible, break large operations into smaller batches.

### Retry Logic for Transient Faults
<!-- Source: resources/troubleshoot/troubleshoot-common-connectivity-issues.md, resources/troubleshoot/troubleshoot-common-errors-issues.md -->

Azure SQL Database is a cloud service running on shared infrastructure. Hardware failures, load balancing events, software upgrades, and planned maintenance can all cause brief connection interruptions. These are **transient faults** — they resolve themselves within seconds.

Your application must handle them. The database will come back; the question is whether your application waits gracefully or crashes.

#### What Transient Faults Look Like

You'll see specific error codes. The most common:

| Error Code | Meaning |
|---|---|
| 40197 | Service error during processing — retry |
| 40501 | Service is busy — retry after 10 seconds |
| 40613 | Database not currently available |
| 49918 | Not enough resources — retry later |
| 10053/10054 | Transport-level connection broken |
| 4060 | Cannot open database (often during failover) |

These errors are *expected* in cloud environments. If your application doesn't retry, you'll see intermittent failures that correlate with maintenance windows or load spikes.

#### Retry Strategy

The pattern is straightforward: catch the error, wait, reconnect, try again. But the details matter.

1. **Wait at least 5 seconds before the first retry.** Retrying immediately can overwhelm the service while it's recovering.
2. **Use exponential backoff.** Double the delay on each subsequent attempt, up to a maximum of 60 seconds.
3. **Set a maximum retry count.** Three to five retries covers most transient events. If the database hasn't recovered after that, something bigger is wrong.
4. **Don't retry the same command on a broken connection.** Establish a fresh connection first, then re-execute the query. Retrying a `SELECT` on a dead connection just produces the same error.
5. **Be careful with writes.** If an `UPDATE` or `INSERT` failed mid-execution, the transaction may or may not have committed. Use idempotent operations or check state before retrying.

#### Retry in Practice: .NET

`Microsoft.Data.SqlClient` has built-in connection retry via the `ConnectRetryCount` and `ConnectRetryInterval` connection string parameters:

```csharp
var connectionString = new SqlConnectionStringBuilder
{
    DataSource = "tcp:myserver.database.windows.net,1433",
    InitialCatalog = "mydb",
    Authentication = SqlAuthenticationMethod.ActiveDirectoryDefault,
    Encrypt = SqlConnectionEncryptOption.Mandatory,
    ConnectRetryCount = 3,
    ConnectRetryInterval = 10,
    ConnectTimeout = 30
}.ConnectionString;
```

This retries the initial connection up to 3 times with 10-second intervals. For *command* retries (a query failing on an already-open connection), use the configurable retry logic feature:

```csharp
var retryLogic = SqlConfigurableRetryFactory.CreateExponentialRetryProvider(
    new SqlRetryLogicOption
    {
        NumberOfTries = 5,
        DeltaTime = TimeSpan.FromSeconds(1),
        MaxTimeInterval = TimeSpan.FromSeconds(60),
        TransientErrors = new[] { 40613, 40197, 40501, 49918, 4060 }
    });

using var connection = new SqlConnection(connectionString);
connection.RetryLogicProvider = retryLogic;

using var command = connection.CreateCommand();
command.RetryLogicProvider = retryLogic;
command.CommandText = "SELECT TOP 10 OrderId, CustomerId FROM Orders";

connection.Open();
using var reader = command.ExecuteReader();
```

#### Retry in Practice: Python

With `pyodbc`, you handle retries yourself. A simple implementation:

```python
import pyodbc
import re
import time

MAX_RETRIES = 5
TRANSIENT_ERRORS = {40197, 40501, 40613, 49918, 4060, 10053, 10054}

def _extract_native_error(exc):
    """Pull the native SQL Server error number from a pyodbc exception.
    ODBC messages look like: '[08S01] [Microsoft][ODBC Driver 18 ...]
    Communication link failure (10054) (SQLExecDirectW)'.
    """
    if len(exc.args) >= 2:
        match = re.search(r'\((\d+)\)\s*\(SQL', str(exc.args[1]))
        if match:
            return int(match.group(1))
    return 0

def execute_with_retry(connection_string, query):
    for attempt in range(MAX_RETRIES):
        try:
            with pyodbc.connect(connection_string) as conn:
                cursor = conn.cursor()
                cursor.execute(query)
                return cursor.fetchall()
        except pyodbc.Error as e:
            # e.args[0] is the SQLSTATE string (e.g., '08S01'), not an int.
            # The native SQL Server error number lives in e.args[1].
            error_code = _extract_native_error(e)
            if error_code in TRANSIENT_ERRORS and attempt < MAX_RETRIES - 1:
                wait = min(5 * (2 ** attempt), 60)
                time.sleep(wait)
            else:
                raise
```

#### Retry in Practice: Node.js

The `mssql` package for Node.js supports retry configuration at the pool level:

```javascript
const sql = require('mssql');

const config = {
  server: 'myserver.database.windows.net',
  database: 'mydb',
  authentication: {
    type: 'azure-active-directory-default'
  },
  options: {
    encrypt: true,
    trustServerCertificate: false,
    connectTimeout: 30000,
    requestTimeout: 30000
  },
  pool: {
    max: 10,
    min: 0,
    idleTimeoutMillis: 30000
  }
};

async function queryWithRetry(query, maxRetries = 5) {
  for (let attempt = 0; attempt < maxRetries; attempt++) {
    try {
      const pool = await sql.connect(config);
      const result = await pool.request().query(query);
      return result.recordset;
    } catch (err) {
      const transientErrors = [40197, 40501, 40613, 49918];
      if (transientErrors.includes(err.number) && attempt < maxRetries - 1) {
        const wait = Math.min(5000 * Math.pow(2, attempt), 60000);
        await new Promise(resolve => setTimeout(resolve, wait));
      } else {
        throw err;
      }
    }
  }
}
```

### Common Connectivity Errors and How to Fix Them

When a connection fails, the error message usually tells you exactly what's wrong — if you know what to look for. Here are the errors you'll hit most often:

**Error 40615: Cannot open server**
Your client IP isn't in the server's firewall rules. Add it through the portal or `az sql server firewall-rule create`.

**Error 18456: Login failed**
Wrong credentials or the user doesn't exist. Verify the login and password, and confirm a database-level user is mapped.

**Error 47073: Public network interface not accessible**
Public access is disabled on the server. Use a private endpoint, or re-enable public access under Networking settings.

**Error 47072: Login failed with invalid TLS version**
Your client is negotiating a TLS version below the server's minimum. Upgrade your driver or OS to support TLS 1.2+.

**Error 10060: Connection timed out**
Something between your client and the server is blocking the traffic. Check NSG rules, firewalls, and port requirements at every layer.

**Error 40197 / 40613: Transient fault**
The service is reconfiguring. These are the transient errors covered earlier — implement retry logic and move on.

For a comprehensive troubleshooting reference, see Appendix G.

## Connecting SQL Server on Azure VMs
<!-- Source: sql-server-on-azure-vms/windows/how-to-guides/ways-to-connect-to-sql.md -->

SQL Server on an Azure VM gives you full control — and full responsibility. The connectivity mode is set when you provision the VM, but you can change it later.

### Public, Private, and Local Access Modes

When you create a SQL Server VM through the Azure portal, you choose a **SQL connectivity** option:

- **Public**: Accessible over the internet. The portal configures the NSG to allow inbound TCP on port 1433, enables TCP/IP in SQL Server, and turns on SQL authentication.
- **Private**: Accessible only from within the same virtual network. Same configuration as Public, minus the NSG rule for internet traffic.
- **Local**: Accessible only from within the VM itself. Useful for development or when the application runs on the same machine.

The connection string for a public VM uses its public IP or DNS label:

```
Server=sqlvmlabel.eastus.cloudapp.azure.com;Integrated Security=false;User ID=mylogin;Password=mypassword
```

> **Tip:** Avoid using the default port 1433 for internet-facing VMs. Configure SQL Server to listen on a non-standard port (e.g., 1500) and specify it in the connection string with a comma: `Server=sqlvmlabel.eastus.cloudapp.azure.com,1500`. This won't stop a determined attacker, but it reduces noise from automated scanners.

### TCP/IP Enablement and NSG Rules

The portal configures TCP/IP automatically for most SQL Server images, but **Developer** and **Express** editions are the exception — you must enable TCP/IP manually via SQL Server Configuration Manager after the VM is created.

For network access, you need:

1. **TCP/IP enabled** in SQL Server Configuration Manager under *SQL Server Network Configuration > Protocols*.
2. **Windows Firewall rule** allowing inbound traffic on the SQL Server port.
3. **NSG rule** allowing inbound TCP traffic on the SQL Server port from the desired source (your IP, a VNet, or `Internet` for public access).

All three must be in place. Missing any one of them results in connection timeouts (error 10060) that can be maddening to diagnose because the error message doesn't tell you *which* layer blocked the traffic.

### DNS Labels for Public Connectivity

Rather than connecting to a raw IP address that can change, create a **DNS label** for your VM's public IP address. In the Azure portal, go to the VM's public IP resource, open Configuration, and set a DNS label name. You'll get a stable A record like `myvm.eastus.cloudapp.azure.com` that resolves to the current public IP.

## Managed Instance Application Connectivity
<!-- Source: azure-sql-managed-instance-sql-mi/how-to/connect-application-instance.md, azure-sql-managed-instance-sql-mi/concepts/architecture/connectivity-architecture-overview.md -->

Managed Instance's VNet-native architecture means connectivity depends on where your application lives relative to the instance's subnet.

### Same-VNet Connectivity

This is the simplest case. If your application runs in the same VNet (even a different subnet), it connects directly to the instance's VNet-local endpoint: `<instance>.<dns-zone>.database.windows.net` on port 1433. No special networking configuration is needed beyond ensuring that NSG rules on the application's subnet allow outbound traffic to the MI subnet.

### Peered-VNet Connectivity

For applications in a different VNet, you have three options:

1. **Private endpoints** — the most secure option. Creates a fixed IP in the application's VNet that tunnels traffic to the MI. Only one-way connectivity; requires just one IP address.
2. **VNet peering** — uses the Azure backbone network with negligible latency. Supports global peering across regions (for instances in subnets created after September 2020).
3. **VNet-to-VNet VPN gateway** — useful when peering isn't feasible or when you need encryption in transit beyond TLS.

### On-Premises Connectivity

From on-premises, you have two paths to the VNet-local endpoint:

- **Site-to-site VPN** — encrypted tunnel over the internet between your on-premises gateway and Azure.
- **Azure ExpressRoute** — private connection through a connectivity provider, bypassing the public internet.

If you just need data access and don't want to set up VPN/ExpressRoute, you can enable the **public endpoint** on the Managed Instance. It's accessible at `<instance>.public.<dns-zone>.database.windows.net` on port 3342. The public endpoint is disabled by default and must be explicitly enabled. It always uses Proxy, as noted in the connection types table earlier in this chapter.

### App Service Connectivity

Azure App Service can reach Managed Instance through VNet integration. When the App Service is integrated with a VNet peered to the MI's VNet, the peering must be configured with:

- **Allow Gateway Transit** on the App Service's VNet peering.
- **Use Remote Gateways** on the MI's VNet peering.
- The MI VNet must **not** have its own gateway.

> **Note:** VNet integration doesn't work through ExpressRoute gateways, even in coexistence mode. If your MI VNet has an ExpressRoute gateway, use App Service Environment instead — it runs directly inside your VNet.

The connectivity fundamentals are in place. In the next chapter, you'll put them to work: designing a schema, loading data, and discovering where Azure SQL's T-SQL dialect differs from what you're used to.
