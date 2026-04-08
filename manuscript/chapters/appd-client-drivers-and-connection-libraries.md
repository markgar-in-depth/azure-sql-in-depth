# Appendix D: Client Drivers and Connection Libraries

Every connection to Azure SQL speaks the **Tabular Data Stream (TDS)** protocol — the same wire protocol SQL Server has used since the 1990s. Any driver that implements TDS can connect. But "can connect" and "should use in production" aren't the same thing.

Drivers differ in their support for Microsoft Entra authentication, Always Encrypted, connection resiliency, and redirect-mode connectivity. Use this appendix to pick the right driver for your language and verify feature support. Chapter 4 covers connection strings, pooling, and retry logic.

## The Driver Landscape
<!-- Source: shared-sql-db-sql-mi-docs/shared-how-tos/connect-and-query-from-apps/connect-query-content-reference-guide.md -->

Microsoft maintains first-party drivers for C#/.NET, Java, Python, Node.js, Go, PHP, Ruby, and C/C++. All run on Windows, Linux, and macOS. Some are thin wrappers over the ODBC driver; others implement TDS natively.

| Language | Driver | Package Source | TDS Implementation |
|---|---|---|---|
| C# / .NET | Microsoft.Data.SqlClient | NuGet | Native (managed) |
| Java | Microsoft JDBC Driver | Maven Central | Native (Java) |
| Python | mssql-python | PyPI | Native (via TDS) |
| Python | pyodbc | PyPI | ODBC wrapper |
| Node.js | tedious / mssql | npm | Native (JavaScript) |
| Go | go-mssqldb | Go modules | Native (Go) |
| PHP | SQLSRV / PDO_SQLSRV | PECL | ODBC wrapper |
| Ruby | tiny_tds | RubyGems | FreeTDS wrapper |
| C / C++ | Microsoft ODBC Driver | Microsoft Download | Native (C) |

> **Tip:** Drivers that implement TDS natively (Microsoft.Data.SqlClient, JDBC, tedious, go-mssqldb, mssql-python) don't require a separate ODBC driver install. Drivers that wrap ODBC (pyodbc, SQLSRV, PDO_SQLSRV) require the Microsoft ODBC Driver for SQL Server installed on the machine.

## Feature Matrix

Not every driver supports every Azure SQL feature. The tables below cover the capabilities that matter most in production.

**Security and encryption:**

| Feature | .NET | JDBC | ODBC 18 |
|---|---|---|---|
| Entra auth | ✓ | ✓ | ✓ |
| Always Encrypted | ✓ | ✓ | ✓ |
| TDS 8.0 (Strict) | ✓ | ✓ | ✓ |
| Encrypt default | ✓ | ✓ | ✓ |

| Feature | tedious | go-mssqldb | mssql-python |
|---|---|---|---|
| Entra auth | ✓ | ✓ | ✓ |
| Always Encrypted | ✗ | ✗ | ✗ |
| TDS 8.0 (Strict) | ✗ | ✗ | ✗ |
| Encrypt default | ✓ | ✓ | ✓ |

**Connectivity and resilience:**

| Feature | .NET | JDBC | ODBC 18 |
|---|---|---|---|
| Redirect mode | ✓ | ✓ | ✓ |
| Connection resiliency | ✓ | ✓ | ✓ |
| Configurable retry | ✓ | ✓ | ✗ |

| Feature | tedious | go-mssqldb | mssql-python |
|---|---|---|---|
| Redirect mode | ✓ | ✓ | ✓ |
| Connection resiliency | ✗ | ✗ | ✗ |
| Configurable retry | ✗ | ✗ | ✗ |

> **Note:** "Entra auth" means the driver supports at least one Microsoft Entra authentication flow (interactive, managed identity, service principal, or `DefaultAzureCredential`-style). Specific flows vary — check your driver's documentation for the exact methods supported.

> **Important:** If you need Always Encrypted client-side encryption, your choices are .NET, Java, or ODBC. The Node.js, Go, Python, PHP, and Ruby drivers don't support client-side column encryption.

## C# / .NET: Microsoft.Data.SqlClient
<!-- Source: shared-sql-db-sql-mi-docs/shared-how-tos/connect-and-query-from-apps/connect-query-dotnet-core.md -->

**Microsoft.Data.SqlClient** is the actively developed ADO.NET provider for SQL Server and Azure SQL. It's the replacement for `System.Data.SqlClient`, which is in maintenance mode and no longer receives new features.

**Install:**

```bash
dotnet add package Microsoft.Data.SqlClient
```

**Key capabilities:**

- **Microsoft Entra authentication** via `Authentication=Active Directory Default`, `Active Directory Interactive`, `Active Directory Managed Identity`, and `Active Directory Service Principal`.
- **Configurable retry logic** built into the provider — you can define retry count, interval, and transient error numbers without writing your own retry loop.
- **Always Encrypted** with automatic encryption/decryption of parameterized queries.
- **Connection resiliency** that transparently reconnects idle connections broken by Azure gateway failovers.

**Minimal connection example:**

```csharp
using Microsoft.Data.SqlClient;

var builder = new SqlConnectionStringBuilder
{
    DataSource = "myserver.database.windows.net",
    InitialCatalog = "mydb",
    Authentication = SqlAuthenticationMethod.ActiveDirectoryDefault,
    Encrypt = SqlConnectionEncryptOption.Mandatory
};

await using var conn = new SqlConnection(builder.ConnectionString);
await conn.OpenAsync();

await using var cmd = new SqlCommand("SELECT name FROM sys.databases", conn);
await using var reader = await cmd.ExecuteReaderAsync();
while (await reader.ReadAsync())
{
    Console.WriteLine(reader.GetString(0));
}
```

> **Gotcha:** Don't use `System.Data.SqlClient` for new projects. It doesn't support configurable retry logic, some newer Entra auth flows, or recent Always Encrypted improvements. If you're migrating from `System.Data.SqlClient`, the namespace change is the biggest hurdle — the API surface is nearly identical.

## Java: Microsoft JDBC Driver for SQL Server
<!-- Source: shared-sql-db-sql-mi-docs/shared-how-tos/develop-data-applications/java/connect-query-java.md -->

The **Microsoft JDBC Driver for SQL Server** is a Type 4 JDBC driver — pure Java, no native dependencies. The Maven artifact is `com.microsoft.sqlserver:mssql-jdbc`.

**Install (Maven):**

```xml
<dependency>
    <groupId>com.microsoft.sqlserver</groupId>
    <artifactId>mssql-jdbc</artifactId>
    <version>12.4.2.jre11</version> <!-- Check Maven Central for the latest version -->
</dependency>
```

**Key capabilities:**

- **Microsoft Entra authentication** including interactive, managed identity, service principal, and `DefaultAzureCredential`-style flows via the `msal4j` library.
- **Always Encrypted** with Java KeyStore or Azure Key Vault for column master key storage.
- **Configurable connection retry** via `connectRetryCount` and `connectRetryInterval` connection properties.
- **Redirect-mode** connectivity for lower-latency Azure-internal connections.

**Minimal connection example:**

```java
import java.sql.*;
import java.util.Properties;

Properties props = new Properties();
props.setProperty("url",
    "jdbc:sqlserver://myserver.database.windows.net:1433;"
    + "database=mydb;encrypt=true;trustServerCertificate=false;"
    + "authentication=ActiveDirectoryDefault;");

try (Connection conn = DriverManager.getConnection(
        props.getProperty("url"), props);
     Statement stmt = conn.createStatement();
     ResultSet rs = stmt.executeQuery(
        "SELECT name FROM sys.databases")) {
    while (rs.next()) {
        System.out.println(rs.getString("name"));
    }
}
```

> **Tip:** Pick the JAR that matches your JRE version. The driver ships separate artifacts for JRE 8, 11, and 17+. Using the wrong one gives you a `ClassNotFoundException` at runtime, not a compile error.

## Python: mssql-python and pyodbc

Python has two paths to Azure SQL: the newer **mssql-python** driver and the established **pyodbc** library.

### mssql-python (Recommended for New Projects)
<!-- Source: shared-sql-db-sql-mi-docs/shared-how-tos/connect-and-query-from-apps/connect-query-python.md -->

**mssql-python** is Microsoft's native Python driver for SQL Server. It uses the TDS protocol directly — no ODBC driver dependency required.

**Install:**

```bash
pip install mssql-python
```

**Key capabilities:**

- **Microsoft Entra authentication** with `ActiveDirectoryDefault`, `ActiveDirectoryInteractive`, `ActiveDirectoryMSI`, and `ActiveDirectoryServicePrincipal`.
- Built-in TDS implementation — no separate ODBC driver install on Windows. Linux requires `libltdl7`; macOS requires `openssl`.
- Works on Windows, Linux, and macOS.

**Minimal connection example:**

```python
from mssql_python import connect

conn_str = (
    "Server=myserver.database.windows.net;"
    "Database=mydb;"
    "Authentication=ActiveDirectoryDefault;"
    "Encrypt=yes;TrustServerCertificate=no"
)

with connect(conn_str) as conn:
    with conn.cursor() as cursor:
        cursor.execute("SELECT name FROM sys.databases")
        for row in cursor.fetchall():
            print(row.name)
```

### pyodbc

**pyodbc** is a mature, widely-used library that wraps the Microsoft ODBC Driver for SQL Server. It requires the ODBC driver to be installed separately.

**Install:**

```bash
pip install pyodbc
```

You also need the **Microsoft ODBC Driver 18 for SQL Server** installed on the machine.

**Minimal connection example:**

```python
import pyodbc

conn = pyodbc.connect(
    "Driver={ODBC Driver 18 for SQL Server};"
    "Server=myserver.database.windows.net;"
    "Database=mydb;"
    "Authentication=ActiveDirectoryDefault;"
    "Encrypt=yes;TrustServerCertificate=no"
)

cursor = conn.cursor()
cursor.execute("SELECT name FROM sys.databases")
for row in cursor.fetchall():
    print(row.name)
```

> **Gotcha:** On Linux, installing the ODBC driver requires adding Microsoft's apt or yum repository and installing `msodbcsql18`. It's straightforward but catches people who expect `pip install` to handle everything.

## Node.js: tedious and mssql
<!-- Source: shared-sql-db-sql-mi-docs/shared-how-tos/connect-and-query-from-apps/connect-query-nodejs.md -->

**tedious** is the low-level TDS implementation for Node.js. Most developers use it through the **mssql** wrapper package, which provides a cleaner API with connection pooling.

**Install:**

```bash
npm install mssql
```

**Key capabilities:**

- **Microsoft Entra authentication** including managed identity types (`azure-active-directory-msi-vm`, `azure-active-directory-msi-app-service`) and default credential flows.
- Built-in connection pooling.
- Redirect-mode support.

**Minimal connection example:**

```javascript
const sql = require('mssql');

const config = {
    server: 'myserver.database.windows.net',
    database: 'mydb',
    port: 1433,
    authentication: {
        type: 'azure-active-directory-default'
    },
    options: {
        encrypt: true,
        trustServerCertificate: false
    }
};

async function main() {
    const pool = await sql.connect(config);
    const result = await pool.request()
        .query('SELECT name FROM sys.databases');
    console.log(result.recordset);
    pool.close();
}

main();
```

> **Note:** The `mssql` package wraps tedious and adds connection pooling, transaction helpers, and a promise-based API. For most applications, use `mssql` rather than tedious directly.

## Go: go-mssqldb
<!-- Source: shared-sql-db-sql-mi-docs/shared-how-tos/connect-and-query-from-apps/connect-query-go.md -->

**go-mssqldb** is Microsoft's Go driver for SQL Server and Azure SQL. It implements `database/sql` interfaces, so it works with Go's standard database tooling.

**Install:**

```bash
go get github.com/microsoft/go-mssqldb
```

**Key capabilities:**

- **Microsoft Entra authentication** via the `azuread` sub-package — supports `ActiveDirectoryDefault`, managed identity, and service principal.
- Redirect-mode support.
- Named parameters via `sql.Named()`.

**Minimal connection example:**

```go
package main

import (
    "context"
    "database/sql"
    "fmt"
    "log"

    "github.com/microsoft/go-mssqldb/azuread"
)

func main() {
    connStr := "server=myserver.database.windows.net;" +
        "port=1433;database=mydb;" +
        "fedauth=ActiveDirectoryDefault;"

    db, err := sql.Open(azuread.DriverName, connStr)
    if err != nil {
        log.Fatal(err)
    }
    defer db.Close()

    rows, err := db.QueryContext(context.Background(),
        "SELECT name FROM sys.databases")
    if err != nil {
        log.Fatal(err)
    }
    defer rows.Close()

    for rows.Next() {
        var name string
        rows.Scan(&name)
        fmt.Println(name)
    }
}
```

> **Tip:** Import `github.com/microsoft/go-mssqldb/azuread` instead of the base package when you need Entra authentication. The `azuread` sub-package registers a driver that includes the MSAL token acquisition logic.

## PHP: SQLSRV and PDO_SQLSRV
<!-- Source: shared-sql-db-sql-mi-docs/shared-how-tos/connect-and-query-from-apps/connect-query-php.md -->

Microsoft provides two PHP extensions: **SQLSRV** (procedural API) and **PDO_SQLSRV** (PDO interface). Both are wrappers around the Microsoft ODBC Driver.

**Prerequisites:** Install PHP and the Microsoft ODBC Driver for SQL Server, then install the PHP extensions via PECL or your platform's package manager.

**Key capabilities:**

- Microsoft Entra authentication (via ODBC driver).
- Always Encrypted support (via ODBC driver).
- Works with Laravel (Eloquent) and other PHP frameworks through PDO_SQLSRV.

**Minimal connection example (SQLSRV):**

```php
<?php
$serverName = "myserver.database.windows.net";
$connectionOptions = array(
    "Database" => "mydb",
    "Authentication" => "ActiveDirectoryMsi"
);

$conn = sqlsrv_connect($serverName, $connectionOptions);

$tsql = "SELECT name FROM sys.databases";
$result = sqlsrv_query($conn, $tsql);

while ($row = sqlsrv_fetch_array($result, SQLSRV_FETCH_ASSOC)) {
    echo $row['name'] . PHP_EOL;
}
?>
```

> **Gotcha:** The PHP extensions depend on the ODBC driver for all their Azure-specific capabilities. If you upgrade the PHP extensions but leave an old ODBC driver installed, you'll miss features like TDS 8.0 support and newer Entra auth modes.

## Ruby: tiny_tds
<!-- Source: shared-sql-db-sql-mi-docs/shared-how-tos/connect-and-query-from-apps/connect-query-ruby.md -->

**tiny_tds** is a Ruby binding for FreeTDS, providing TDS protocol access to SQL Server and Azure SQL.

**Install:**

```bash
gem install tiny_tds
```

**Key capabilities:**

- Connects to Azure SQL Database, Managed Instance, and SQL Server on Azure VMs.
- The `azure: true` option in the connection configuration enables Azure-specific connection handling.

**Minimal connection example:**

```ruby
require 'tiny_tds'

client = TinyTds::Client.new(
  host: 'myserver.database.windows.net',
  database: 'mydb',
  username: 'myuser',
  password: 'mypassword',
  port: 1433,
  azure: true
)

result = client.execute("SELECT name FROM sys.databases")
result.each do |row|
  puts row['name']
end
```

> **Note:** Ruby's tiny_tds has the narrowest Azure feature support of all the listed drivers. It doesn't support Microsoft Entra authentication natively — you'd need to acquire a token separately and pass it as an access token. For Ruby applications that need Entra auth, consider using ODBC through a Ruby ODBC binding instead.

## Microsoft ODBC Driver for SQL Server
<!-- Source: shared-sql-db-sql-mi-docs/shared-how-tos/connect-and-query-from-apps/connect-query-content-reference-guide.md -->

The **Microsoft ODBC Driver for SQL Server** is the foundation driver. PHP, pyodbc, and several other language bindings depend on it. Even if you're not writing C/C++, you'll likely install it.

**Current version:** ODBC Driver 18 for SQL Server.

If you're using a language that wraps ODBC (pyodbc, PHP), the features available to your application depend on which ODBC driver version is installed — not just which language driver version you're running.

| Version | Key Additions |
|---|---|
| ODBC 11 | Connection resiliency, driver-aware pooling |
| ODBC 13.1 | Always Encrypted, Entra auth |
| ODBC 17 | Always Encrypted for BCP API |
| ODBC 18 | TDS 8.0, encrypt-by-default, `LongAsMax` |

> **Important:** ODBC Driver 18 changed the default for `Encrypt` to `Yes`. Applications upgrading from ODBC 17 that relied on the old default (`No`) will fail to connect if `TrustServerCertificate` isn't set correctly. For Azure SQL this is a non-issue — you always want encryption — but on-premises SQL Server instances without proper certificates will break. Plan for this during upgrades.

**Install on Linux (Ubuntu/Debian):**

```bash
curl https://packages.microsoft.com/keys/microsoft.asc | \
    sudo tee /etc/apt/trusted.gpg.d/microsoft.asc
sudo add-apt-repository \
    "$(curl https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/prod.list)"
sudo apt-get update
sudo apt-get install -y msodbcsql18
```

**Install on macOS:**

```bash
brew tap microsoft/mssql-release https://github.com/Microsoft/homebrew-mssql-release
brew update
brew install msodbcsql18
```

## ORM and Framework Support

Most teams don't use raw drivers — they use an ORM or data-access framework on top. Here's how the major frameworks map to the underlying drivers.
<!-- Source: shared-sql-db-sql-mi-docs/shared-how-tos/connect-and-query-from-apps/connect-query-content-reference-guide.md -->

| Language | Framework | Underlying Driver |
|---|---|---|
| C# / .NET | Entity Framework Core | Microsoft.Data.SqlClient |
| Java | Hibernate, Spring Data JPA | JDBC Driver |
| Python | Django, SQLAlchemy | pyodbc or mssql-python |
| Node.js | Sequelize, TypeORM, Prisma | tedious |
| Go | GORM | go-mssqldb |
| PHP | Laravel (Eloquent) | PDO_SQLSRV |
| Ruby | Ruby on Rails | tiny_tds |

> **Tip:** When troubleshooting ORM connectivity issues, check the underlying driver version first. ORMs abstract the connection, but they can't work around bugs or missing features in the driver layer underneath. Running `SELECT @@VERSION` through your ORM is a quick sanity check that the full stack is working.

## Choosing the Right Driver

If you're starting fresh, the decision tree is short:

- **.NET?** Microsoft.Data.SqlClient — it's the actively maintained first-party provider.
- **Java?** Microsoft JDBC Driver — it's the only first-party option.
- **Python?** mssql-python for the simplest setup (no separate ODBC driver). pyodbc if you need Always Encrypted or have existing pyodbc code.
- **Node.js?** The mssql package (which wraps tedious). It gives you pooling and a clean async API.
- **Go?** go-mssqldb with the azuread sub-package for Entra auth.
- **PHP?** PDO_SQLSRV for PDO compatibility, SQLSRV for procedural code. Both need the ODBC driver.
- **Ruby?** tiny_tds, but be aware of its limited Azure feature support.
- **C/C++?** Microsoft ODBC Driver directly.

For a deeper walkthrough of connection strings, pooling, retry logic, and common connectivity errors, see Chapter 4.
