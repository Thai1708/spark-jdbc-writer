# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Spark JDBC Writer is a high-performance Spark extension for writing DataFrames to relational databases (Oracle and PostgreSQL). It provides two implementations:

- **Scala JAR (v1.0.7)**: Traditional Spark extension loaded via `--jars` (legacy, still in use)
- **Pure Python (v2.1.0)**: No JAR dependency for PostgreSQL; uses JVM JDBC (ojdbc8.jar) for Oracle (preferred for new work)

Both support: MERGE/UPSERT, partition overwrite, error logging, retry logic, and pre/post SQL execution.

## Build Commands

### Scala JAR
```bash
sbt assembly                    # Build fat JAR
sbt test                        # Run unit tests
sbt "testOnly *OracleDialectTest"  # Run specific test
make build                      # Clean + assembly (recommended)
```

### Python Package
```bash
cd python
pip install -e .                          # Install for development
pytest tests/ -v                          # Run all tests
pytest tests/test_executor.py -v          # Run single test file
pytest tests/test_executor.py::TestWriteOptions -v  # Run single test class
```

From repo root:
```bash
make wheel                      # Build wheel (python/dist/*.whl)
```

### Deployment

The Makefile deploys to `s3://aws-sg-nedp-{env}-mwaa/` for MWAA integration. For Glue jobs, manually deploy to `s3://aws-sg-nedp-{env}-emr-artifacts/`:

```bash
# Via Makefile (deploys to mwaa bucket)
make deploy-all-uat             # Build JAR + wheel + template → UAT S3
make deploy-all-prod            # Build JAR + wheel + template → PROD S3 (with confirmation)
make sync-uat                   # Upload existing artifacts to UAT (no rebuild)

# Direct to Glue artifacts bucket (preferred for Glue jobs)
aws s3 cp glue_artifact/jdbc_writer_template_v2.py s3://aws-sg-nedp-dev-emr-artifacts/scripts/
aws s3 cp python/dist/spark_jdbcwriter-2.1.0-py3-none-any.whl s3://aws-sg-nedp-dev-emr-artifacts/whl/
```

### Versioning

Versions are managed separately:
- **Scala JAR**: `build.sbt` → `version := "1.0.7"`
- **Python wheel**: `python/setup.py` → `version="2.1.0"` (also update `python/jdbcwriter/__init__.py` → `__version__`)

Bump both files when releasing coordinated changes. **NOTE**: `__init__.py` currently reads `2.0.0` — it should match `setup.py` at `2.1.0`.

## Architecture

### Python Implementation (v2.1.0) — Active Development

The Python package (`python/jdbcwriter/`) is the actively developed implementation:

| Module | Replaces (Scala) | Purpose |
|--------|-------------------|---------|
| `_writer.py` | `JdbcWriter.scala` | Main orchestration — routes to write mode, handles pre/post/onFail SQL, step timing |
| `_executor.py` | `JdbcMergeExecutor.scala` + `JdbcPartitionOverwriteExecutor.scala` | Batch execution, `WriteOptions` dataclass, `foreachPartition` logic |
| `_dialects.py` | `dialect/*.scala` | SQL generation — `OracleDialect` (MERGE INTO DUAL), `PostgresDialect` (ON CONFLICT) |
| `_utils.py` | `util/*.scala` | Connection factory (JVM JDBC / psycopg2), retry with backoff, password masking |
| `config_parser.py` | — | YAML config parsing/validation for Glue batch operations (multi-table migrations) |

**Key execution model**: For `merge_into` and `overwrite_partition` modes, `_writer.py` serializes the schema + options into dicts, then passes them to `_executor.py` functions via `df.foreachPartition()`. Each Spark executor creates its own DB connection (connections are not serializable across Spark workers).

### Oracle Connection: JVM JDBC (no Oracle Instant Client)

The Python package uses **JVM JDBC** via Spark's JVM for Oracle connections (`_utils.py:JvmJdbcConnection`). This wraps Java's `DriverManager.getConnection()` through `spark.sparkContext._jvm`, using the ojdbc8.jar already loaded via `--jars`. No Oracle Instant Client or `cx_Oracle` package is needed.

Key classes in `_utils.py`:
- `JvmJdbcConnection` — DB-API 2.0 compatible wrapper around Java JDBC Connection
- `JvmJdbcCursor` — Wraps Java PreparedStatement, converts `:1, :2` Oracle bind vars to `?` JDBC placeholders
- `_set_parameter()` — Maps Python types to Java JDBC types (None→setNull, int→setLong, datetime→setTimestamp, date→setDate, Decimal→setBigDecimal, str→setString with date detection)

For PostgreSQL, it prefers JVM JDBC if SparkSession available, falls back to psycopg2.

### AWS Glue Integration

`glue_artifact/jdbc_writer_template_v2.py` is the Glue job entry point:
```
MWAA (Airflow) → GlueJobOperator → jdbc_writer_template_v2.py
                                            │
                                   Parse JSON config (TABLES_JSON arg)
                                            │
                              Read Iceberg → JdbcWriter.write() → Oracle/PostgreSQL
```

The template handles: Secrets Manager credential resolution, Spark catalog configuration, macro rendering (`${ ds_dt }`, `${ table_name }`, etc.), and per-table error handling with `on_fail_sql`.

### SQL Execution Flow (Critical)

- **pre_sql / post_sql**: Handled by `JdbcWriter` inside `_writer.py` — executed via `execute_sql_statements()` in `_executor.py`
- **on_fail_sql**: Handled at **two levels**:
  1. By the **Glue template** — extracted from options *before* calling JdbcWriter (via `opts.pop()`), rendered with error macros (`${ error_message }`), executed independently on failure
  2. By `_writer.py` internally if configured in options (the template pops `onFailSql` keys before calling JdbcWriter to avoid double execution)
- All SQL execution uses `_utils.get_connection()` which creates JVM JDBC connections for Oracle

## Key Patterns

### Write Modes
- `append`: Delegates to native Spark JDBC writer
- `overwrite`: DELETE/TRUNCATE + INSERT (3 strategies: `deleteBeforeInsert` > `truncateTable` > default DROP+CREATE)
- `overwrite_partition`: **Non-atomic** DELETE WHERE partition_col IN (...) + native Spark JDBC INSERT
- `merge_into`: Database-specific UPSERT via `foreachPartition` with batching

### Database Dialects
- **Oracle**: `MERGE INTO ... USING (SELECT :1 FROM DUAL)`, bind variables `:1, :2, ...` (converted to `?` by JvmJdbcCursor), UPPERCASE identifiers
- **PostgreSQL**: `INSERT ... ON CONFLICT DO UPDATE`, `%s` placeholders, lowercase identifiers

### Column Case Handling
Auto-detected from JDBC URL: Oracle defaults `uppercaseColumns=true`, PostgreSQL defaults `false`.

### Partition Values Optimization
The `partitionValues` option accepts explicit partition values (comma-separated or JSON array), avoiding an expensive `df.select().distinct().collect()` scan. Always prefer providing `partitionValues` in configs when possible.

### WriteOptions Defaults
- `batchSize`: 2000 for Oracle, 1000 for PostgreSQL (auto-detected from URL)
- `commitInterval`: 2 (batches between commits)
- `uppercaseColumns`: auto (true for Oracle, false for PostgreSQL)

### Glue Template Macros
Available in YAML configs: `${ ds_dt }`, `${ ds_dt_nodash }`, `${ ds_dt_minus_1 }`, `${ ds_dt_plus_1 }`, `${ ds_dt_year }`, `${ ds_dt_month }`, `${ ds_dt_day }`, `${ job_name }`, `${ job_run_id }`, `${ table_name }`, `${ start_time }`, `${ row_count }`, `${ error_message }`, `${ workers }`, `${ worker_type }`, `${ dpu }`, `${ glue_version }`

## Critical Operational Knowledge

### JVM JDBC Type Mapping Gotcha (NULL handling)

`JvmJdbcCursor._set_parameter()` maps `None` to `setNull(index, Types.VARCHAR)`. This means all NULLs are sent as VARCHAR type. For Oracle columns with non-VARCHAR types (DATE, NUMBER, TIMESTAMP), this **may** cause implicit type conversion. If Oracle rejects the NULL, the `setNull` call may need the correct SQL type instead.

### Glue 5.0 + Wheel Extraction for C Extensions

Glue 5.0 uses **Python 3.11**. Wheels with C extensions (`.so` files) cannot be imported from `.whl` archives directly — Python's `zipimport` doesn't support it. The Glue template has `extract_wheel_files()` at the top that extracts wheels with C extensions to a temp directory before any imports.

### S3 Deployment Paths

The Makefile deploys to `s3://aws-sg-nedp-{env}-mwaa/` but the actual Glue job artifacts referenced by DAGs live at:
- **Template**: `s3://aws-sg-nedp-{env}-emr-artifacts/scripts/jdbc_writer_template_v2.py`
- **Wheel**: `s3://aws-sg-nedp-{env}-emr-artifacts/whl/spark_jdbcwriter-2.1.0-py3-none-any.whl`

Ensure you deploy to the correct bucket depending on whether the consumer is MWAA or Glue.

### Related Codebases

YAML configs defining which wheel/jar versions DAGs use are in the sibling `nedp-etl` project:
- `glue_entries/*_v2.yml` — Glue job configurations
- `.artifacts/dag_generator/generate_glue_transport_dags_v2.py` — DAG generator (must be re-run after YAML changes)

## Testing

### Unit Tests (No database required)
```bash
sbt test                                # Scala tests (H2 in-memory)
cd python && pytest tests/ -v           # Python tests (mocked)
cd python && pytest tests/test_executor.py::TestWriteOptions -v  # Single test class
```

### Integration Tests (Docker databases)
```bash
docker-compose up -d postgres oracle
docker-compose exec pyspark python tests/test_integration.py

# Glue 5.0 local testing
docker-compose -f docker-compose.glue5.yml up -d
docker-compose -f docker-compose.glue5.yml exec glue bash
pip install /app/python/ && python /app/tests/test_glue_local.py
```

Integration test files are in the repo root `tests/` directory (separate from Python unit tests in `python/tests/`).

## Dependencies

### Scala
- Scala 2.12.18, Spark 3.5.5 (provided), PostgreSQL driver 42.7.3 (bundled), Oracle JDBC 23.3 (optional)

### Python
- Python 3.8+, PySpark >= 3.5.0, cx_Oracle >= 8.0.0 (listed in setup.py but JVM JDBC is used at runtime for Oracle), psycopg2-binary >= 2.9.0, pyyaml >= 5.0
