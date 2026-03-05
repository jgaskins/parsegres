require "./spec_helper"

private def it_round_trips(description : String, sql : String, *, file = __FILE__, line = __LINE__)
  it "round-trips #{description}", file: file, line: line do
    Parsegres.parse(sql).to_s.should eq sql
  end
end

describe Parsegres::Printer do
  describe "SELECT" do
    it_round_trips "simple wildcard", "SELECT * FROM users"

    it_round_trips "column list with aliases",
      "SELECT id AS user_id, name AS full_name FROM users"

    it_round_trips "WHERE clause",
      "SELECT id FROM users WHERE active = TRUE"

    it_round_trips "param refs",
      "SELECT * FROM users WHERE id = $1"

    it_round_trips "LIMIT and OFFSET",
      "SELECT id FROM users OFFSET 20 LIMIT 10"

    it_round_trips "ORDER BY ASC and DESC",
      "SELECT id FROM t ORDER BY name ASC, age DESC NULLS LAST"

    it_round_trips "GROUP BY and HAVING",
      "SELECT dept, count(*) FROM employees GROUP BY dept HAVING count(*) > 5"

    it_round_trips "DISTINCT",
      "SELECT DISTINCT status FROM orders"

    it_round_trips "DISTINCT ON",
      "SELECT DISTINCT ON (dept) id, dept FROM employees"

    it_round_trips "qualified table name",
      "SELECT id FROM public.users"

    it_round_trips "table alias",
      "SELECT u.id FROM users AS u"

    it_round_trips "subquery in FROM",
      "SELECT id FROM (SELECT id FROM users) AS sub"

    it_round_trips "INNER JOIN with ON",
      "SELECT u.id, o.total FROM users AS u JOIN orders AS o ON u.id = o.user_id"

    it_round_trips "LEFT JOIN",
      "SELECT u.id FROM users AS u LEFT JOIN orders AS o ON u.id = o.user_id"

    it_round_trips "JOIN USING",
      "SELECT id FROM a JOIN b USING (id, dept)"

    it_round_trips "multiple FROM tables (cross-join)",
      "SELECT a.id, b.id FROM a, b"
  end

  describe "expressions" do
    it_round_trips "integer literal",
      "SELECT 42"

    it_round_trips "float literal",
      "SELECT 3.14"

    it_round_trips "string literal",
      "SELECT 'hello'"

    it_round_trips "string literal with embedded single quote",
      "SELECT 'it''s'"

    it_round_trips "bool literals",
      "SELECT TRUE, FALSE"

    it_round_trips "NULL",
      "SELECT NULL"

    it_round_trips "unary minus",
      "SELECT -1"

    it_round_trips "unary NOT",
      "SELECT NOT TRUE"

    it_round_trips "preserving arithmetic precedence",
      # For `(a + b) * c`, the `+` has lower precedence, so the parentheses are
      # necessary.
      "SELECT (a + b) * c"

    it_round_trips "a + b * c -- no parens needed (right child has higher prec)",
      "SELECT a + b * c"

    it_round_trips "OR inside AND needs parens",
      "SELECT a AND (b OR c)"

    it_round_trips "AND inside OR is unambiguous (no parens)",
      "SELECT a OR b AND c"

    it_round_trips "IS NULL",
      "SELECT id FROM t WHERE name IS NULL"

    it_round_trips "IS NOT NULL",
      "SELECT id FROM t WHERE name IS NOT NULL"

    it_round_trips "BETWEEN",
      "SELECT id FROM t WHERE age BETWEEN 18 AND 65"

    it_round_trips "NOT BETWEEN",
      "SELECT id FROM t WHERE age NOT BETWEEN 18 AND 65"

    it_round_trips "IN list",
      "SELECT id FROM t WHERE status IN ('active', 'pending')"

    it_round_trips "NOT IN list",
      "SELECT id FROM t WHERE status NOT IN ('deleted')"

    it_round_trips "IN subquery",
      "SELECT id FROM t WHERE id IN (SELECT id FROM deleted)"

    it_round_trips "LIKE",
      "SELECT id FROM t WHERE name LIKE '%foo%'"

    it_round_trips "ILIKE",
      "SELECT id FROM t WHERE name ILIKE '%foo%'"

    it_round_trips "NOT LIKE",
      "SELECT id FROM t WHERE name NOT LIKE '%foo%'"

    it_round_trips "function call",
      "SELECT count(*) FROM t"

    it_round_trips "function call with DISTINCT",
      "SELECT count(DISTINCT id) FROM t"

    it_round_trips "cast with ::",
      "SELECT id::text FROM t"

    it_round_trips "subscript",
      "SELECT tags[1] FROM t"

    it_round_trips "CASE expression",
      "SELECT CASE WHEN x > 0 THEN 'pos' ELSE 'neg' END FROM t"

    it_round_trips "CASE expression with subject",
      "SELECT CASE status WHEN 'a' THEN 1 WHEN 'b' THEN 2 END FROM t"

    it_round_trips "EXISTS",
      "SELECT id FROM t WHERE EXISTS (SELECT 1 FROM other WHERE other.id = t.id)"

    it_round_trips "scalar subquery",
      "SELECT (SELECT max(id) FROM t) AS mx"

    it_round_trips "window function",
      "SELECT row_number() OVER (PARTITION BY dept ORDER BY salary DESC) FROM employees"

    it_round_trips "typed string literal (interval)",
      "SELECT '1 day'::interval"
  end

  describe "WITH (CTE)" do
    it_round_trips "simple CTE",
      "WITH cte AS (SELECT 1) SELECT * FROM cte"

    it_round_trips "RECURSIVE CTE",
      "WITH RECURSIVE n AS (SELECT 1 UNION ALL SELECT n + 1 FROM n WHERE n < 10) SELECT * FROM n"

    it_round_trips "MATERIALIZED CTE",
      "WITH cte AS MATERIALIZED (SELECT 1) SELECT * FROM cte"

    it_round_trips "NOT MATERIALIZED CTE",
      "WITH cte AS NOT MATERIALIZED (SELECT 1) SELECT * FROM cte"
  end

  describe "set operations" do
    it_round_trips "UNION",
      "SELECT 1 UNION SELECT 2"

    it_round_trips "UNION ALL",
      "SELECT 1 UNION ALL SELECT 2"

    it_round_trips "INTERSECT",
      "SELECT 1 INTERSECT SELECT 2"

    it_round_trips "EXCEPT",
      "SELECT 1 EXCEPT SELECT 2"
  end

  describe "INSERT" do
    it_round_trips "INSERT VALUES",
      "INSERT INTO users (name, email) VALUES ('Alice', 'alice@example.com')"

    it_round_trips "INSERT DEFAULT VALUES",
      "INSERT INTO logs DEFAULT VALUES"

    it_round_trips "INSERT SELECT",
      "INSERT INTO archive SELECT * FROM users WHERE deleted = TRUE"

    it_round_trips "INSERT RETURNING",
      "INSERT INTO users (name) VALUES ('Bob') RETURNING id"

    it_round_trips "INSERT multiple rows",
      "INSERT INTO t (a, b) VALUES (1, 2), (3, 4)"
  end

  describe "UPDATE" do
    it_round_trips "simple UPDATE",
      "UPDATE users SET name = 'Alice' WHERE id = $1"

    it_round_trips "UPDATE multiple columns",
      "UPDATE users SET name = $1, email = $2 WHERE id = $3"

    it_round_trips "UPDATE RETURNING",
      "UPDATE users SET active = FALSE WHERE id = $1 RETURNING id, name"

    it_round_trips "UPDATE table AS alias",
      %{UPDATE users AS "naming aliases like this should be a war crime" SET active = FALSE WHERE id = $1}
  end

  describe "DELETE" do
    it_round_trips "simple DELETE",
      "DELETE FROM users WHERE id = $1"

    it_round_trips "DELETE RETURNING",
      "DELETE FROM users WHERE id = $1 RETURNING id"
  end

  # TODO: Expand on these cases to ensure we're emitting all parts of the AST
  describe "DDL statements" do

    it_round_trips "CREATE TABLE",
      # This is an unfortunately long line because it has to be what will be
      # emitted when we transform the parsed query back into a string.
      "CREATE TABLE users (id uuid PRIMARY KEY DEFAULT uuidv7(), email citext NOT NULL, name text NOT NULL, created_at timestamp with time zone NOT NULL DEFAULT now())"

    it_round_trips "DROP TABLE",
      "DROP TABLE users" # little Bobby Tables

    it_round_trips "ALTER TABLE",
      "ALTER TABLE users ALTER COLUMN email SET NOT NULL"

    # Right about here is where I started getting bored with writing test
    # cases. Can ya tell?

    it_round_trips "CREATE INDEX",
      "CREATE INDEX CONCURRENTLY my_index ON users USING GIN (data)"

    it_round_trips "DROP INDEX",
      "DROP INDEX CONCURRENTLY my_index"

    it_round_trips "CREATE VIEW",
      "CREATE VIEW my_view AS SELECT 42"

    it_round_trips "DROP VIEW",
      %{DROP VIEW "my-schema"."my-view"}

    it_round_trips "TRUNCATE",
      "TRUNCATE users"

    it_round_trips "CREATE SEQUENCE",
      "CREATE SEQUENCE my_sequence AS int4 INCREMENT BY 3 NO MINVALUE MAXVALUE 1234 CYCLE START WITH 2 CACHE 5 OWNED BY my_column"

    it_round_trips "ALTER SEQUENCE",
      "ALTER SEQUENCE my_sequence AS int8"

    it_round_trips "DROP SEQUENCE",
      %{DROP SEQUENCE IF EXISTS "my-schema"."my-sequence"}

    it_round_trips "CREATE SCHEMA",
      "CREATE SCHEMA IF NOT EXISTS my_schema AUTHORIZATION picard_4_7_alpha_tango"

    it_round_trips "DROP SCHEMA",
      "DROP SCHEMA IF EXISTS my_schema"

    it_round_trips "CREATE EXTENSION",
      %{CREATE EXTENSION IF NOT EXISTS "uuid-ossp"}

    it_round_trips "DROP EXTENSION",
      %{DROP EXTENSION IF EXISTS "uuid-ossp"}

    it_round_trips "CREATE TYPE AS RANGE",
      "CREATE TYPE timerange AS RANGE (SUBTYPE = time)"

    it_round_trips "DROP TYPE",
      "DROP TYPE IF EXISTS timerange"
  end

  describe "TCL statements" do
    it_round_trips "BEGIN",
      "BEGIN"

    it_round_trips "COMMIT",
      "COMMIT"

    it_round_trips "ROLLBACK",
      "ROLLBACK"

    it_round_trips "SAVEPOINT",
      "SAVEPOINT my_savepoint"

    it_round_trips "RELEASE SAVEPOINT",
      "RELEASE SAVEPOINT my_savepoint"

    it_round_trips "ROLLBACK TO SAVEPOINT",
      "ROLLBACK TO SAVEPOINT my_savepoint"
  end

  describe "to_s convenience method" do
    it "is available on all node types" do
      ast = Parsegres.parse("SELECT id FROM users WHERE id = 42")
      ast.should be_a Parsegres::AST::Statement
      ast.to_s.should contain("SELECT")
    end

    it "enables fingerprinting by replacing literals" do
      ast = Parsegres.parse("SELECT * FROM orders WHERE status = 'active' AND amount > 100")
        .as Parsegres::AST::SelectStatement

      # Replace the WHERE clause literals with $N params
      index = 0
      replace_literals = ->(expr : Parsegres::AST::Expr) do
        Parsegres::AST::ParamRef.new(index += 1)
      end

      # if where = ast.where.as?(Parsegres::AST::BinaryExpr)
      #   # Replace 'active' in status = 'active'
      #   if left = where.left.as?(Parsegres::AST::BinaryExpr)
      #     left.right = replace_literals.call(left.right)
      #   end
      #   # Replace 100 in amount > 100
      #   if right = where.right.as?(Parsegres::AST::BinaryExpr)
      #     right.right = replace_literals.call(right.right)
      #   end
      # end
      QueryFingerprinter.new.call ast

      ast.to_s.should eq "SELECT * FROM orders WHERE status = $1 AND amount > $2"
    end
  end
end

# Example use case for this shard is "fingerprinting" queries by removing
# literals interpolated into them for the purpose of aggregating on the query.
class QueryFingerprinter
  include Parsegres::AST

  @index = 0

  # Replace `Literal`s with `ParamRef`s
  def call(expr : BinaryExpr)
    swap expr.left do
      expr.left = ParamRef.new(@index += 1)
    end
    swap expr.right do
      expr.right = ParamRef.new(@index += 1)
    end
  end

  # Traverse the statement from the top level
  def call(statement : SelectStatement | DeleteStatement | UpdateStatement)
    statement.ctes.each do |cte|
      call cte
    end
    if where = statement.where
      call where
    end
  end

  def call(statement : Statement)
    # Traverse other types of statements
  end

  def call(cte : CTEDefinition)
    call cte.query
  end

  def call(expr : Expr)
    # Traverse other types of expressions
  end

  private def swap(expr : Literal, &)
    yield
  end

  private def swap(expr : Expr, &)
    call expr
  end
end
