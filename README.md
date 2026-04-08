# Azure SQL In Depth

A comprehensive developer's guide organized for learning, not reference. Covers Azure SQL Database, Hyperscale, Managed Instance, and SQL Server on Azure VMs — every major feature, pattern, and operational concern — in the order you need them.

## Download

The epub is always available here for free and updated regularly:

**[Download the latest epub](https://github.com/markgar-in-depth/azure-sql-in-depth/releases/latest)**

If you find value in this book, consider supporting the author by purchasing it on [Kindle](https://www.amazon.com/dp/PLACEHOLDER).

## What's Inside

- **Part I: The Azure SQL Landscape** — What Azure SQL is, why it exists, and how to choose the right deployment option.
- **Part II: Getting Started** — Hands-on setup. Create your first resources, connect, and run queries.
- **Part III: Security** — Defense in depth: network, identity, encryption, auditing, and threat detection.
- **Part IV: Hyperscale, HA, DR, and Backups** — The Hyperscale deep dive, then keeping your data alive, recoverable, and resilient.
- **Part V: Performance and Monitoring** — Understanding, measuring, and improving the performance of your workloads.
- **Part VI: Data Management and Application Patterns** — Moving data, building applications, and designing for real-world patterns.
- **Part VII: Migration** — Moving workloads to Azure SQL, from planning to post-migration optimization.
- **Part VIII: Operations and Administration** — Day-to-day management, cost optimization, and advanced operational patterns.

28 chapters and 7 appendices. See the full [outline](manuscript/outline/outline.md) for details.

## Who This Book Is For

Professional developers and DBAs building production applications on Azure SQL. Assumes comfort with cloud services, relational databases, T-SQL, and at least one application language.

## Building from Source

Requires [Pandoc](https://pandoc.org/installing.html) and PowerShell.

```bash
pwsh build.ps1
```

Output: `build/Azure-SQL-In-Depth.epub`

## License

[Creative Commons Attribution-NonCommercial-NoDerivatives 4.0 International](LICENSE).

This book is not affiliated with or endorsed by Microsoft.
