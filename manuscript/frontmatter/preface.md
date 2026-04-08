## Preface

### Who This Book Is For

This book is for professional developers and DBAs building production
applications on Azure SQL. You're comfortable with cloud services, relational
databases, and T-SQL. You've probably worked with at least one application
language — C#, Java, Python, or JavaScript/TypeScript — and you're ready to go
beyond getting-started tutorials.

Maybe you're migrating an on-premises SQL Server workload to Azure. Maybe
you're building something new and trying to decide between Azure SQL Database,
Managed Instance, and SQL Server on a VM. Maybe you've been running Azure SQL
for a while and want to understand the parts you've been avoiding. This book
is for all of those situations.

What this book is *not*: a SQL primer. I assume you can write a query, design
a schema, and troubleshoot a deadlock. We're here to learn the platform, not
the language.

### How This Book Is Organized

The book is organized for progressive learning, not as a reference manual.
Each part builds on the ones before it.

**Part I: The Azure SQL Landscape** introduces the three deployment options —
Azure SQL Database, Managed Instance, and SQL Server on Azure VMs — and gives
you a decision framework for choosing the right one. No code, no setup — just
mental models.

**Part II: Getting Started** is hands-on. You'll create your first resources,
connect to them, design a schema, and run queries across all three deployment
options.

**Part III: Security** covers defense in depth: network security, authentication
and identity, encryption, auditing, and threat detection. It's placed early
because security decisions constrain everything that follows — network topology,
connection patterns, and operational workflows all depend on choices you make
here.

**Part IV: Hyperscale, HA, DR, and Backups** starts with a deep dive into the
Hyperscale service tier's distributed architecture, then covers backup and
restore, high availability, and disaster recovery across all deployment options.
Hyperscale comes first because the HA and backup chapters reference its
architecture.

**Part V: Performance and Monitoring** covers observability (Azure Monitor,
database watcher, DMVs, Extended Events), performance tuning (blocking,
deadlocks, automatic tuning), and in-memory technologies (OLTP, columnstore).

**Part VI: Data Management and Application Patterns** gets into data modeling,
multi-tenant SaaS patterns, data movement, elastic database tools, and
building production applications on Azure SQL.

**Part VII: Migration** walks through migration planning, assessment, and
execution for each deployment option — SQL Database, Managed Instance, and
SQL Server on Azure VMs.

**Part VIII: Operations and Administration** covers day-to-day management,
cost optimization, and advanced topics for Managed Instance and SQL Server
on Azure VMs.

You can read straight through, but you don't have to. After Parts I–III,
you'll have enough to build and secure a working application. Jump to
whichever part addresses your immediate need from there.

### Conventions Used in This Book

Throughout this book, you'll see several types of callouts:

> **Tip** — A helpful suggestion or best practice that can save you time.

> **Note** — Additional context or clarification that's worth knowing.

> **Important** — Something you need to understand before proceeding.

> **Warning** — A potential pitfall or behavior that could cause data loss
> or downtime if ignored.

> **Gotcha** — A subtle behavior or default that catches people off guard.
> These are things the docs mention but don't emphasize.

> **Prerequisite** — Something you need to have in place before the next
> section will work.

Cross-references to other chapters use the format "→ see Chapter N." Source
references to Microsoft Learn documentation appear in comments within code
blocks and in callouts.
