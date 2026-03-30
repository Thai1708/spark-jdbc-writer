# Spark JDBC Writer

A high-performance Spark JDBC writer extension supporting multiple write modes, stored procedure execution, and advanced features for Oracle and PostgreSQL databases.

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [Write Modes](#write-modes)
- [Calling SQL Stored Procedures](#calling-sql-stored-procedures)
- [Pre/Post SQL Statements](#prepost-sql-statements)
- [Configuration Options](#configuration-options)
- [Security](#security)
- [Error Handling](#error-handling)

## Installation

Add the JAR to your Spark application:

```bash
spark-submit --jars jdbcwriter.jar your_app.jar
```

## Quick Start

```scala
import com.example.spark.jdbc.JdbcWriter

// Simple append
JdbcWriter.write(df, Map(
  "url" -> "jdbc:postgresql://localhost:5432/mydb",
  "dbtable" -> "schema.users",
  "user" -> "dbuser",
  "password" -> "dbpass",
  "writeMode" -> "append"
))

// Merge/Upsert with stored procedure call
JdbcWriter.write(df, Map(
  "url" -> "jdbc:oracle:thin:@localhost:1521:xe",
  "dbtable" -> "users",
  "user" -> "dbuser",
  "password" -> "dbpass",
  "writeMode" -> "merge_into",
  "mergeKeys" -> "id",
  "postSql" -> "CALL refresh_user_stats()"
))
```

## Write Modes

### 1. Append Mode

Inserts new rows using Spark's native JDBC writer with PreparedStatement batching.

```scala
JdbcWriter.write(df, Map(
  "url" -> "jdbc:postgresql://localhost/mydb",
  "dbtable" -> "users",
  "writeMode" -> "append"
))
```

| Database   | SQL Pattern | Batch Size | Performance |
|------------|-------------|------------|-------------|
| Oracle     | `INSERT INTO ... VALUES (?, ?)` | 1000 | ~25K rows/sec |
| PostgreSQL | `INSERT INTO ... VALUES (?, ?)` | 1000 | ~312K rows/sec |

**Use case:** Pure inserts, no duplicates
**Limitation:** Fails on duplicate keys

### 2. Overwrite Mode

Replaces entire table with three different strategies.

```scala
// Option 1: DELETE + INSERT (transactional, can rollback)
JdbcWriter.write(df, Map(
  "url" -> "jdbc:postgresql://localhost/mydb",
  "dbtable" -> "users",
  "writeMode" -> "overwrite",
  "deleteBeforeInsert" -> "true"  // DML, preserves structure
))

// Option 2: TRUNCATE + INSERT (fastest, non-transactional)
JdbcWriter.write(df, Map(
  "url" -> "jdbc:postgresql://localhost/mydb",
  "dbtable" -> "users",
  "writeMode" -> "overwrite",
  "truncateTable" -> "true"  // DDL, preserves structure
))

// Option 3: DROP + CREATE + INSERT (default, recreates schema)
JdbcWriter.write(df, Map(
  "url" -> "jdbc:postgresql://localhost/mydb",
  "dbtable" -> "users",
  "writeMode" -> "overwrite"
))
```

| Strategy | Method | Preserves Structure | Transactional | Rollback | Speed |
|----------|--------|---------------------|---------------|----------|-------|
| `deleteBeforeInsert=true` | DELETE + INSERT | ✓ | ✓ (DML) | ✓ | Slowest |
| `truncateTable=true` | TRUNCATE + INSERT | ✓ | ✗ (DDL) | ✗ | Fastest |
| Default | DROP + CREATE + INSERT | ✗ | ✗ (DDL) | ✗ | Medium |

**Priority:** `deleteBeforeInsert` > `truncateTable` > default

**Use case:** Full table refresh
**Limitation:** Deletes all existing data

### 3. Overwrite Partition Mode

Deletes specific partitions then inserts new data.

```scala
JdbcWriter.write(df, Map(
  "url" -> "jdbc:postgresql://localhost/mydb",
  "dbtable" -> "sales",
  "writeMode" -> "overwrite_partition",
  "partitionColumns" -> "year,month"
))
```

| Database   | Phase 1 | Phase 2 | Performance |
|------------|---------|---------|-------------|
| Oracle     | `DELETE WHERE partition_col IN (...)` | INSERT | ~17K rows/sec |
| PostgreSQL | `DELETE WHERE partition_col IN (...)` | INSERT | ~167K rows/sec |

**WARNING:** Non-atomic operation. If Phase 2 fails after Phase 1 commits, partition data is lost.

**Use case:** Incremental partition loads (daily/monthly)

### 4. Merge Mode (UPSERT)

Inserts new rows and updates existing rows based on merge keys.

```scala
JdbcWriter.write(df, Map(
  "url" -> "jdbc:postgresql://localhost/mydb",
  "dbtable" -> "users",
  "writeMode" -> "merge_into",
  "mergeKeys" -> "id",
  "mergeDeleteUnmatched" -> "true"  // Optional: delete rows not in source
))
```

**Oracle Implementation:**
```sql
MERGE INTO table T
USING (SELECT ? AS col1, ? AS col2 FROM DUAL UNION ALL ...) S
ON (T.key = S.key)
WHEN MATCHED THEN UPDATE SET T.col1 = S.col1
WHEN NOT MATCHED THEN INSERT (key, col1) VALUES (S.key, S.col1)
```

**PostgreSQL Implementation:**
```sql
INSERT INTO table (key, col1, col2) VALUES (?, ?, ?)
ON CONFLICT (key) DO UPDATE SET col1 = EXCLUDED.col1, col2 = EXCLUDED.col2
```

| Database   | Insert Path | Update Path |
|------------|-------------|-------------|
| Oracle     | ~11K rows/sec | ~6K rows/sec |
| PostgreSQL | ~275K rows/sec | ~283K rows/sec |

**Use case:** Incremental loads with duplicates, CDC processing

---

## Calling SQL Stored Procedures

Use `preSql` and `postSql` options to execute stored procedures before or after data operations.

### Oracle Stored Procedures

**Call procedure without parameters:**
```scala
JdbcWriter.write(df, Map(
  "url" -> "jdbc:oracle:thin:@localhost:1521:xe",
  "dbtable" -> "users",
  "writeMode" -> "merge_into",
  "mergeKeys" -> "id",
  "postSql" -> "CALL update_statistics()"
))
```

**Call procedure with parameters:**
```scala
JdbcWriter.write(df, Map(
  "url" -> "jdbc:oracle:thin:@localhost:1521:xe",
  "dbtable" -> "sales",
  "writeMode" -> "append",
  "postSql" -> "CALL calculate_totals('2024', 'Q1')"
))
```

**Execute PL/SQL block:**
```scala
JdbcWriter.write(df, Map(
  "url" -> "jdbc:oracle:thin:@localhost:1521:xe",
  "dbtable" -> "orders",
  "writeMode" -> "merge_into",
  "mergeKeys" -> "order_id",
  "postSql" -> """BEGIN
    pkg_order.refresh_order_cache;
    pkg_reporting.update_daily_summary(SYSDATE);
  END;"""
))
```

**Call package procedure:**
```scala
JdbcWriter.write(df, Map(
  "url" -> "jdbc:oracle:thin:@localhost:1521:xe",
  "dbtable" -> "inventory",
  "writeMode" -> "overwrite_partition",
  "partitionColumns" -> "warehouse_id",
  "preSql" -> "CALL pkg_inventory.disable_triggers()",
  "postSql" -> "CALL pkg_inventory.enable_triggers(); CALL pkg_inventory.recalculate_stock()"
))
```

### PostgreSQL Stored Procedures/Functions

**Call procedure (PostgreSQL 11+):**
```scala
JdbcWriter.write(df, Map(
  "url" -> "jdbc:postgresql://localhost/mydb",
  "dbtable" -> "users",
  "writeMode" -> "merge_into",
  "mergeKeys" -> "id",
  "postSql" -> "CALL refresh_materialized_views()"
))
```

**Call function:**
```scala
JdbcWriter.write(df, Map(
  "url" -> "jdbc:postgresql://localhost/mydb",
  "dbtable" -> "transactions",
  "writeMode" -> "append",
  "postSql" -> "SELECT process_new_transactions()"
))
```

**Execute function with parameters:**
```scala
JdbcWriter.write(df, Map(
  "url" -> "jdbc:postgresql://localhost/mydb",
  "dbtable" -> "audit_log",
  "writeMode" -> "append",
  "postSql" -> "SELECT archive_old_records('2024-01-01'::date, 1000)"
))
```

**Multiple procedure calls:**
```scala
JdbcWriter.write(df, Map(
  "url" -> "jdbc:postgresql://localhost/mydb",
  "dbtable" -> "sales",
  "writeMode" -> "overwrite_partition",
  "partitionColumns" -> "sale_date",
  "preSql" -> "SELECT disable_sale_triggers()",
  "postSql" -> "SELECT enable_sale_triggers(); CALL update_sales_aggregates(); VACUUM ANALYZE sales"
))
```

### Common Procedure Patterns

**Data validation before write:**
```scala
JdbcWriter.write(df, Map(
  "url" -> "jdbc:postgresql://localhost/mydb",
  "dbtable" -> "financial_data",
  "writeMode" -> "append",
  "preSql" -> "SELECT validate_batch_window()",  // Throws exception if validation fails
  "postSql" -> "CALL close_batch_window()"
))
```

**Refresh materialized views after load:**
```scala
JdbcWriter.write(df, Map(
  "url" -> "jdbc:postgresql://localhost/mydb",
  "dbtable" -> "raw_events",
  "writeMode" -> "append",
  "postSql" -> "REFRESH MATERIALIZED VIEW CONCURRENTLY event_summary"
))
```

**Update statistics and indexes:**
```scala
// Oracle
JdbcWriter.write(df, Map(
  "url" -> "jdbc:oracle:thin:@localhost:1521:xe",
  "dbtable" -> "large_table",
  "writeMode" -> "append",
  "postSql" -> "BEGIN DBMS_STATS.GATHER_TABLE_STATS('SCHEMA', 'LARGE_TABLE'); END;"
))

// PostgreSQL
JdbcWriter.write(df, Map(
  "url" -> "jdbc:postgresql://localhost/mydb",
  "dbtable" -> "large_table",
  "writeMode" -> "append",
  "postSql" -> "ANALYZE large_table; REINDEX TABLE large_table"
))
```

**ETL workflow with logging:**
```scala
JdbcWriter.write(df, Map(
  "url" -> "jdbc:postgresql://localhost/mydb",
  "dbtable" -> "fact_sales",
  "writeMode" -> "merge_into",
  "mergeKeys" -> "sale_id",
  "preSql" -> "SELECT etl_log_start('fact_sales_load')",
  "postSql" -> "SELECT etl_log_end('fact_sales_load'); CALL update_dimension_keys()"
))
```

---

## Pre/Post SQL Statements

Execute custom SQL statements before and after write operations.

### Usage

**Single statement:**
```scala
JdbcWriter.write(df, Map(
  "preSql" -> "SET work_mem = '256MB'",
  "postSql" -> "VACUUM ANALYZE users"
))
```

**Multiple statements (semicolon-delimited):**
```scala
JdbcWriter.write(df, Map(
  "preSql" -> "SET work_mem = '256MB'; SET enable_seqscan = off",
  "postSql" -> "VACUUM ANALYZE users; REINDEX TABLE users"
))
```

**Indexed statements:**
```scala
JdbcWriter.write(df, Map(
  "preSql.0" -> "SET work_mem = '256MB'",
  "preSql.1" -> "SET maintenance_work_mem = '1GB'",
  "postSql.0" -> "VACUUM ANALYZE users",
  "postSql.1" -> "REINDEX TABLE users"
))
```

### Transaction Semantics

| Phase | Transaction | On Failure |
|-------|-------------|------------|
| Pre-SQL | Separate transaction | Data write aborted |
| Data Write | Mode-specific transaction | Post-SQL skipped |
| Post-SQL | Separate transaction | Data already committed |

---

## Configuration Options

| Option | Required | Default | Description |
|--------|----------|---------|-------------|
| `url` | Yes* | - | JDBC connection URL |
| `dbtable` | Yes* | - | Target table (schema.table) |
| `catalogTable` | Yes* | - | Alternative: catalog.schema.table |
| `user` | No | - | Database username |
| `password` | No | - | Database password |
| `driver` | No | Auto-detect | JDBC driver class |
| `writeMode` | No | append | append, overwrite, overwrite_partition, merge_into |
| `uppercaseColumns` | No | Auto-detect | Uppercase all column names (true for Oracle, false for others) |
| `partitionColumns` | Mode | - | Columns for partition overwrite |
| `mergeKeys` | Mode | - | Columns for merge matching |
| `mergeUpdateColumns` | No | All non-key | Columns to update on match |
| `mergeInsertColumns` | No | All | Columns to insert on no match |
| `mergeDeleteUnmatched` | No | false | Delete target rows not in source |
| `batchSize` | No | 1000/2000 | Rows per batch (2000 for Oracle) |
| `commitInterval` | No | 10 | Batches per commit |
| `truncateTable` | No | false | Use TRUNCATE for overwrite (DDL) |
| `deleteBeforeInsert` | No | false | Use DELETE for overwrite (DML, takes precedence over truncateTable) |
| `preSql` | No | - | SQL to execute before write |
| `postSql` | No | - | SQL to execute after write |
| `onFailSql` | No | - | SQL to execute on operation failure |

*Either `catalogTable` OR (`url` + `dbtable`) required

### Table and Column Name Handling

The library automatically handles database-specific identifier conventions:

| Database | Unquoted Identifiers | Library Behavior | Example |
|----------|---------------------|------------------|---------|
| **Oracle** | Stored as UPPERCASE | Converts to uppercase, no quotes | `users` → `USERS` |
| **PostgreSQL** | Stored as lowercase | Converts to lowercase, no quotes | `Users` → `users` |

This ensures identifiers match the database's default behavior. For case-sensitive identifiers (created with quotes), pass the exact name matching the database schema.

---

## Security

### SQL Injection Prevention

**Protected:**
- String values in partition conditions (properly escaped)
- Merge/Upsert operations (parameterized PreparedStatements)
- Table names in TRUNCATE (dialect-specific quoting)
- NULL values (uses `IS NULL` syntax)

**User Responsibility:**
- Pre/Post SQL statements execute as-is - use trusted SQL only
- Validate table names from user input
- Manage credentials securely

### Password Masking

Error messages and logs automatically mask:
- Passwords in JDBC URLs: `jdbc://user:****@host`
- Password parameters: `password=****`
- JSON password fields: `"password": "****"`

---

## Error Handling

### Automatic Retry

Transient failures are retried with exponential backoff:

**Retried (Transient):**
- Connection timeouts/resets
- Deadlocks (SQL State 40001, 40P01)
- Too many connections
- Network errors
- Oracle: ORA-00060, ORA-03135, ORA-12170, ORA-12541
- SQL Server: Error 1205, 1222

**Not Retried (Permanent):**
- Constraint violations (23xxx)
- Syntax errors (42xxx)
- Permission denied
- Data type errors

### Retry Configuration

| Setting | Default |
|---------|---------|
| Max retries | 3 |
| Initial delay | 100ms |
| Max delay | 5000ms |
| Backoff multiplier | 2.0 |

---

## Database Compatibility

| Feature | PostgreSQL | Oracle |
|---------|------------|--------|
| Append | Yes | Yes |
| Overwrite | Yes | Yes |
| Overwrite Partition | Yes | Yes |
| Merge/Upsert | Yes | Yes |
| Delete Unmatched | Yes | Yes |
| Pre/Post SQL | Yes | Yes |
| Stored Procedures | Yes | Yes |

## License

Apache 2.0
