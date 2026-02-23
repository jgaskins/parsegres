# `Parsegres`

Parsegres provides a Postgre-compatible SQL parser.

## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     parsegres:
       github: jgaskins/parsegres
   ```

2. Run `shards install`

## Usage

The main use case is to parse a SQL query using the `Parsegres.parse` method:

```crystal
require "parsegres"

query = Parsegres.parse(<<-SQL)
  SELECT *
  FROM users
  WHERE status = $1
  AND group_id = $2
  LIMIT 25
SQL
```

## Supported statements

| Statement | Notes |
|---|---|
| `SELECT` | Including CTEs, set operations, subqueries, JOINs, aggregates |
| `INSERT` | `VALUES`, `DEFAULT VALUES`, `INSERT … SELECT`, `RETURNING` |
| `UPDATE` | `FROM`, `RETURNING` |
| `DELETE` | `USING`, `RETURNING` |
| `CREATE TABLE` | Column/table constraints, `TEMP`, `IF NOT EXISTS`, schema-qualified |
| `ALTER TABLE` | Add/drop/alter columns, rename, add/drop constraints |
| `DROP TABLE` | Multiple targets, `IF EXISTS`, `CASCADE`/`RESTRICT` |
| `CREATE INDEX` | `UNIQUE`, `CONCURRENTLY`, `USING`, partial indexes, `IF NOT EXISTS` |
| `DROP INDEX` | Multiple targets, `CONCURRENTLY`, `IF EXISTS` |
| `CREATE VIEW` | `OR REPLACE`, `TEMP`, `IF NOT EXISTS`, explicit column list |
| `DROP VIEW` | Multiple targets, `IF EXISTS`, `CASCADE`/`RESTRICT` |
| `TRUNCATE` | Multiple targets, `ONLY`, `RESTART`/`CONTINUE IDENTITY`, `CASCADE`/`RESTRICT` |
| `CREATE SEQUENCE` | All standard options (`INCREMENT BY`, `MINVALUE`/`MAXVALUE`, `START`, `CACHE`, `CYCLE`, `OWNED BY`) |
| `ALTER SEQUENCE` | Same options as `CREATE SEQUENCE`, plus `RESTART` |
| `DROP SEQUENCE` | Multiple targets, `IF EXISTS`, `CASCADE`/`RESTRICT` |
| `CREATE SCHEMA` | `IF NOT EXISTS`, `AUTHORIZATION` |
| `DROP SCHEMA` | Multiple targets, `IF EXISTS`, `CASCADE`/`RESTRICT` |
| `BEGIN` | Optional `WORK`/`TRANSACTION` |
| `COMMIT` | Optional `WORK`/`TRANSACTION` |
| `ROLLBACK` | Optional `WORK`/`TRANSACTION` |

## Not yet implemented

The following statement types are not currently supported. PRs welcome!

- **`CREATE TYPE` / `DROP TYPE`** — composite types, enums, domains, range types
- **`CREATE EXTENSION` / `DROP EXTENSION`** — extension management
- **`GRANT` / `REVOKE`** — privilege management
- **`CREATE FUNCTION` / `DROP FUNCTION`** — user-defined functions
- **`CREATE TRIGGER` / `DROP TRIGGER`** — trigger management
- **`CREATE MATERIALIZED VIEW` / `REFRESH MATERIALIZED VIEW` / `DROP MATERIALIZED VIEW`**
- **`ALTER VIEW`** — modifying existing views
- **`ALTER SEQUENCE`** advanced options — `OWNED BY` reassignment, `AS type`
- **`SAVEPOINT` / `RELEASE SAVEPOINT` / `ROLLBACK TO SAVEPOINT`**
- **`LOCK TABLE`**
- **`VACUUM` / `ANALYZE`**
- **`COPY`**
- **`EXPLAIN`**

## Contributing

1. Fork it (<https://github.com/jgaskins/parsegres/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Jamie Gaskins](https://github.com/jgaskins) - creator and maintainer
