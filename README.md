# `Parsegres`

Parsegres provides a Postgres-compatible SQL parser.

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
| `SELECT` | CTEs, set operations (`UNION`, et al), subqueries, JOINs, window functions |
| `INSERT` | `VALUES`, `DEFAULT VALUES`, `INSERT … SELECT`, `RETURNING` |
| `UPDATE` | `FROM`, `RETURNING` |
| `DELETE` | `USING`, `RETURNING` |
| `CREATE TABLE` | Column/table constraints, `TEMP`, `IF NOT EXISTS`, schema-qualified |
| `ALTER TABLE` | `{ADD,DROP,ALTER,RENAME} COLUMN`, `ADD`/`DROP CONSTRAINT` |
| `DROP TABLE` | `IF EXISTS`, `CASCADE`/`RESTRICT`, multiple tables |
| `CREATE INDEX` | `UNIQUE`, `CONCURRENTLY`, `USING`, partial indexes, `IF NOT EXISTS` |
| `DROP INDEX` | `CONCURRENTLY`, `IF EXISTS`, multiple indexes |
| `CREATE VIEW` | `OR REPLACE`, `TEMP`, `IF NOT EXISTS`, explicit column list |
| `DROP VIEW` | `IF EXISTS`, `CASCADE`/`RESTRICT`, multiple views |
| `TRUNCATE` | Multiple targets, `ONLY`, `RESTART`/`CONTINUE IDENTITY`, `CASCADE`/`RESTRICT` |
| `CREATE SEQUENCE` | All standard options (`INCREMENT BY`, `MINVALUE`/`MAXVALUE`, `START`, `CACHE`, `CYCLE`, `OWNED BY`) |
| `ALTER SEQUENCE` | Same options as `CREATE SEQUENCE`, plus `RESTART` |
| `DROP SEQUENCE` | `IF EXISTS`, `CASCADE`/`RESTRICT`, multiple sequences |
| `CREATE SCHEMA` | `IF NOT EXISTS`, `AUTHORIZATION` |
| `DROP SCHEMA` | `IF EXISTS`, `CASCADE`/`RESTRICT`, multiple schemas |
| `CREATE EXTENSION` | `IF NOT EXISTS` |
| `DROP EXTENSION` | `IF EXISTS`, `CASCADE`/`RESTRICT`, multiple extensions |
| `CREATE TYPE` | Range types (`AS RANGE`) |
| `CREATE RULE` | `OR REPLACE`, event routing, `DO ALSO`/`DO INSTEAD` |
| `DO` | Anonymous code blocks, optional `LANGUAGE` |
| `BEGIN` | Optional `WORK`/`TRANSACTION` |
| `COMMIT` | Optional `WORK`/`TRANSACTION` |
| `ROLLBACK` | Optional `WORK`/`TRANSACTION` |

## Not yet implemented

The following statement types are not currently supported. PRs welcome!

- **`CREATE TYPE`** — composite types, enums, domains (range types are supported)
- **`DROP TYPE`** — dropping types
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
