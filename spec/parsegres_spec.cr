require "./spec_helper"

# Convenience aliases to keep tests readable.
private alias SELECT = Parsegres::AST::SelectStatement
private alias CompoundSelect = Parsegres::AST::CompoundSelect
private alias INSERT = Parsegres::AST::InsertStatement
private alias ValuesSource = Parsegres::AST::ValuesSource
private alias DefaultValuesSource = Parsegres::AST::DefaultValuesSource
private alias SelectSource = Parsegres::AST::SelectSource
private alias UPDATE = Parsegres::AST::UpdateStatement
private alias DELETE = Parsegres::AST::DeleteStatement
private alias CREATE_TABLE = Parsegres::AST::CreateTableStatement
private alias ALTER_TABLE = Parsegres::AST::AlterTableStatement
private alias DROP_TABLE = Parsegres::AST::DropTableStatement
private alias CREATE_INDEX = Parsegres::AST::CreateIndexStatement
private alias DROP_INDEX = Parsegres::AST::DropIndexStatement
private alias CREATE_VIEW = Parsegres::AST::CreateViewStatement
private alias DROP_VIEW = Parsegres::AST::DropViewStatement
private alias TRUNCATE = Parsegres::AST::TruncateStatement
private alias CREATE_SEQUENCE = Parsegres::AST::CreateSequenceStatement
private alias ALTER_SEQUENCE = Parsegres::AST::AlterSequenceStatement
private alias DROP_SEQUENCE = Parsegres::AST::DropSequenceStatement
private alias CREATE_SCHEMA = Parsegres::AST::CreateSchemaStatement
private alias DROP_SCHEMA = Parsegres::AST::DropSchemaStatement
private alias CREATE_EXTENSION = Parsegres::AST::CreateExtensionStatement
private alias DROP_EXTENSION = Parsegres::AST::DropExtensionStatement
private alias CREATE_RANGE_TYPE = Parsegres::AST::CreateRangeTypeStatement
private alias DROP_TYPE = Parsegres::AST::DropTypeStatement
private alias DO_STMT = Parsegres::AST::DoStatement

describe Parsegres do
  describe ".parse" do
    it "returns a SELECT for a simple query" do
      Parsegres.parse("SELECT 1").should be_a(SELECT)
    end

    describe "simple SELECT query" do
      query = Parsegres.parse(<<-SQL).as(SELECT)
        SELECT *
        FROM users
        WHERE status = $1
        AND group_id = $2
        LIMIT 25
        SQL

      it "parses a wildcard column" do
        query.columns.size.should eq 1
        query.columns[0].expr.should be_a(Parsegres::AST::Wildcard)
      end

      it "parses the FROM table" do
        query.from.size.should eq 1
        table = query.from[0].as(Parsegres::AST::TableRef)
        table.name.should eq "users"
        table.schema.should be_nil
        table.alias_name.should be_nil
      end

      it "parses the WHERE clause as AND of two equality comparisons" do
        where = query.where.as(Parsegres::AST::BinaryExpr)
        where.op.should eq "AND"

        left = where.left.as(Parsegres::AST::BinaryExpr)
        left.op.should eq "="
        left.left.as(Parsegres::AST::ColumnRef).column.should eq "status"
        left.right.as(Parsegres::AST::ParamRef).index.should eq 1

        right = where.right.as(Parsegres::AST::BinaryExpr)
        right.op.should eq "="
        right.left.as(Parsegres::AST::ColumnRef).column.should eq "group_id"
        right.right.as(Parsegres::AST::ParamRef).index.should eq 2
      end

      it "parses LIMIT 25" do
        query
          .limit.as(Parsegres::AST::IntegerLiteral)
          .value
          .should eq 25
      end
    end

    describe "SELECT columns" do
      it "parses a column list" do
        q = Parsegres.parse("SELECT id, name, email FROM users").as(SELECT)
        q.columns.size.should eq 3
        q.columns
          .map(&.expr.as(Parsegres::AST::ColumnRef).column)
          .should eq %w[id name email]
      end

      it "parses aliased columns" do
        q = Parsegres.parse(<<-SQL).as(SELECT)
          SELECT
            id AS user_id,
            name AS full_name
          FROM users
        SQL
        q.columns
          .map(&.alias_name)
          .should eq %w[user_id full_name]
      end

      it "parses table-qualified columns" do
        q = Parsegres.parse("SELECT u.id, u.name FROM users u").as(SELECT)
        col = q.columns[0].expr.as(Parsegres::AST::ColumnRef)
        col.table.should eq "u"
        col.column.should eq "id"
      end

      it "parses DISTINCT" do
        q = Parsegres.parse("SELECT DISTINCT status FROM users").as(SELECT)
        q.distinct?.should be_true
      end
    end

    describe "literals" do
      it "parses an integer literal" do
        Parsegres.parse("SELECT 42").as(SELECT)
          .columns[0]
          .expr.as(Parsegres::AST::IntegerLiteral)
          .value
          .should eq 42
      end

      it "parses a float literal" do
        Parsegres.parse("SELECT 3.14").as(SELECT)
          .columns[0]
          .expr.as(Parsegres::AST::FloatLiteral)
          .value
          .should eq 3.14
      end

      it "parses a string literal" do
        Parsegres.parse("SELECT 'hello'").as(SELECT)
          .columns[0]
          .expr.as(Parsegres::AST::StringLiteral)
          .value
          .should eq "hello"
      end

      it "parses TRUE and FALSE" do
        Parsegres.parse("SELECT TRUE, FALSE").as(SELECT)
          .columns
          .map(&.expr.as(Parsegres::AST::BoolLiteral).value)
          .should eq [true, false]
      end

      it "parses NULL" do
        Parsegres.parse("SELECT NULL").as(SELECT)
          .columns[0]
          .expr
          .should be_a(Parsegres::AST::NullLiteral)
      end
    end

    describe "WHERE expressions" do
      it "parses IS NULL" do
        expr = Parsegres.parse("SELECT 1 FROM t WHERE x IS NULL").as(SELECT)
          .where.as(Parsegres::AST::IsNullExpr)

        expr.negated?.should be_false
        expr.operand.as(Parsegres::AST::ColumnRef).column.should eq "x"
      end

      it "parses IS NOT NULL" do
        Parsegres.parse("SELECT 1 FROM t WHERE x IS NOT NULL").as(SELECT)
          .where.as(Parsegres::AST::IsNullExpr)
          .negated?
          .should be_true
      end

      it "parses IN list" do
        expr = Parsegres.parse("SELECT 1 FROM t WHERE id IN (1, 2, 3)").as(SELECT)
          .where.as(Parsegres::AST::InListExpr)

        expr.negated?.should be_false
        expr.list.size.should eq 3
        expr.list.map(&.as(Parsegres::AST::IntegerLiteral).value).should eq [1, 2, 3]
      end

      it "parses NOT IN list" do
        Parsegres.parse("SELECT 1 FROM t WHERE id NOT IN (1, 2, 3)").as(SELECT)
          .where.as(Parsegres::AST::InListExpr)
          .negated?
          .should be_true
      end

      it "parses BETWEEN" do
        expr = Parsegres
          .parse("SELECT 1 FROM t WHERE age BETWEEN 18 AND 65").as(SELECT)
          .where.as(Parsegres::AST::BetweenExpr)

        expr.negated?.should be_false
        expr.low.as(Parsegres::AST::IntegerLiteral).value.should eq 18
        expr.high.as(Parsegres::AST::IntegerLiteral).value.should eq 65
      end

      it "parses LIKE" do
        expr = Parsegres.parse("SELECT 1 FROM t WHERE name LIKE 'A%'").as(SELECT)
          .where.as(Parsegres::AST::LikeExpr)

        expr.ilike?.should be_false
        expr.negated?.should be_false
        expr.pattern.as(Parsegres::AST::StringLiteral).value.should eq "A%"
      end

      it "parses ILIKE" do
        Parsegres.parse("SELECT 1 FROM t WHERE name ILIKE 'a%'").as(SELECT)
          .where.as(Parsegres::AST::LikeExpr)
          .ilike?
          .should be_true
      end
    end

    describe "JOINs" do
      it "parses INNER JOIN with ON" do
        join = Parsegres.parse(<<-SQL).as(SELECT)
          SELECT u.id, o.total
          FROM users u
          INNER JOIN orders o ON u.id = o.user_id
        SQL
          .from[0].as(Parsegres::AST::JoinExpr)

        join.kind.inner?.should be_true
        join
          .left.as(Parsegres::AST::TableRef)
          .name
          .should eq "users"
        join
          .right.as(Parsegres::AST::TableRef)
          .name
          .should eq "orders"
        join
          .on.as(Parsegres::AST::BinaryExpr)
          .op
          .should eq "="
      end

      it "parses LEFT JOIN" do
        Parsegres.parse("SELECT 1 FROM a LEFT JOIN b ON a.id = b.a_id").as(SELECT)
          .from[0].as(Parsegres::AST::JoinExpr)
          .kind
          .left?
          .should be_true
      end
    end

    describe "table functions in FROM" do
      it "parses a table function call in FROM with an alias" do
        q = Parsegres.parse("SELECT x FROM generate_series(1, 10) AS x").as(SELECT)
        ref = q.from[0].as(Parsegres::AST::TableFunctionRef)

        ref.func.name.should eq "generate_series"
        ref.func.args.size.should eq 2
        ref.alias_name.should eq "x"
      end

      it "parses a table function call in FROM without an alias" do
        Parsegres.parse("SELECT 1 FROM unnest($1)").as(SELECT)
          .from[0].as(Parsegres::AST::TableFunctionRef)
          .func.name.should eq "unnest"
      end
    end

    describe "function calls" do
      it "parses a function with arguments" do
        function = Parsegres
          .parse("SELECT coalesce(name, 'unknown') FROM users").as(SELECT)
          .columns[0]
          .expr.as(Parsegres::AST::FunctionCall)

        function.name.should eq "coalesce"
        function.args.size.should eq 2
      end

      it "parses COUNT(*)" do
        function = Parsegres.parse("SELECT count(*) FROM users").as(SELECT)
          .columns[0]
          .expr.as(Parsegres::AST::FunctionCall)

        function.name.should eq "count"
        function.star?.should be_true
      end

      it "parses COUNT(DISTINCT x)" do
        Parsegres.parse("SELECT count(DISTINCT id) FROM users").as(SELECT)
          .columns[0]
          .expr.as(Parsegres::AST::FunctionCall)
          .distinct?
          .should be_true
      end
    end

    describe "GROUP BY and ORDER BY" do
      it "parses GROUP BY with HAVING" do
        q = Parsegres.parse(<<-SQL).as(SELECT)
          SELECT status, count(*)
          FROM users
          GROUP BY status
          HAVING count(*) > 10
          SQL

        q.group_by.size.should eq 1
        q.group_by[0].as(Parsegres::AST::ColumnRef).column.should eq "status"
        q.having.should_not be_nil
      end

      it "parses ORDER BY with direction" do
        q = Parsegres.parse(<<-SQL).as(SELECT)
          SELECT id
          FROM users
          ORDER BY
            created_at DESC,
            name ASC
        SQL

        q.order_by.size.should eq 2
        q.order_by[0].direction.desc?.should be_true
        q.order_by[1].direction.asc?.should be_true
      end
    end

    describe "leading-dot float literals" do
      it "parses .5 as a float" do
        Parsegres.parse("SELECT .5 FROM t").as(SELECT)
          .columns[0].expr.as(Parsegres::AST::FloatLiteral)
          .value.should eq 0.5
      end

      it "parses a comparison against a leading-dot float" do
        expr = Parsegres.parse("SELECT * FROM t WHERE x > .04").as(SELECT)
          .where.as(Parsegres::AST::BinaryExpr)
        expr.op.should eq ">"
        expr.right.as(Parsegres::AST::FloatLiteral).value.should eq 0.04
      end
    end

    describe "dollar-quoted string literals" do
      it "parses an empty-tag dollar-quote ($$...$$)" do
        Parsegres.parse("SELECT $$hello world$$ FROM t").as(SELECT)
          .columns[0].expr.as(Parsegres::AST::StringLiteral)
          .value.should eq "hello world"
      end

      it "parses a tagged dollar-quote ($tag$...$tag$)" do
        Parsegres.parse("SELECT $msg$it's here$msg$ FROM t").as(SELECT)
          .columns[0].expr.as(Parsegres::AST::StringLiteral)
          .value.should eq "it's here"
      end

      it "preserves newlines inside a dollar-quoted string" do
        Parsegres.parse("SELECT $$line1\nline2$$ FROM t").as(SELECT)
          .columns[0].expr.as(Parsegres::AST::StringLiteral)
          .value.should eq "line1\nline2"
      end
    end

    describe "aggregate FILTER clause" do
      it "parses count(*) FILTER (WHERE condition)" do
        func = Parsegres.parse("SELECT count(*) FILTER (WHERE active) FROM t").as(SELECT)
          .columns[0].expr.as(Parsegres::AST::FunctionCall)
        func.name.should eq "count"
        func.star?.should be_true
        func.filter.not_nil!.as(Parsegres::AST::ColumnRef).column.should eq "active"
      end

      it "parses agg(expr) FILTER (WHERE condition)" do
        func = Parsegres.parse("SELECT sum(amount) FILTER (WHERE status = 'paid') FROM t").as(SELECT)
          .columns[0].expr.as(Parsegres::AST::FunctionCall)
        func.name.should eq "sum"
        func.filter.should_not be_nil
      end
    end

    describe "arithmetic and type casts" do
      it "parses arithmetic" do
        Parsegres.parse("SELECT price * quantity FROM items").as(SELECT)
          .columns[0]
          .expr.as(Parsegres::AST::BinaryExpr)
          .op
          .should eq "*"
      end

      it "parses :: type cast" do
        cast = Parsegres.parse("SELECT id::text FROM users").as(SELECT)
          .columns[0]
          .expr.as(Parsegres::AST::CastExpr)

        cast.type_name.should eq "text"
        cast.expr.as(Parsegres::AST::ColumnRef).column.should eq "id"
      end

      it "parses #>> JSON path-as-text operator" do
        expr = Parsegres.parse("SELECT data#>>'{key}' FROM t").as(SELECT)
          .columns[0].expr.as(Parsegres::AST::BinaryExpr)

        expr.op.should eq "#>>"
        expr.left.as(Parsegres::AST::ColumnRef).column.should eq "data"
        expr.right.as(Parsegres::AST::StringLiteral).value.should eq "{key}"
      end

      it "parses #> JSON path operator" do
        Parsegres.parse("SELECT data#>'{key}' FROM t").as(SELECT)
          .columns[0].expr.as(Parsegres::AST::BinaryExpr)
          .op.should eq "#>"
      end

      it "parses an array subscript on a column" do
        expr = Parsegres.parse("SELECT arr[1] FROM t").as(SELECT)
          .columns[0].expr.as(Parsegres::AST::SubscriptExpr)

        expr.index.as(Parsegres::AST::IntegerLiteral).value.should eq 1
        expr.expr.as(Parsegres::AST::ColumnRef).column.should eq "arr"
      end

      it "parses an array subscript on a subquery result" do
        Parsegres.parse("SELECT (SELECT 1)[1]").as(SELECT)
          .columns[0].expr.as(Parsegres::AST::SubscriptExpr)
          .expr.should be_a(Parsegres::AST::SubqueryExpr)
      end

      describe "JSON arrow operators" do
        it "parses -> (field by key, returns JSON)" do
          expr = Parsegres.parse("SELECT data->'key' FROM t").as(SELECT)
            .columns[0].expr.as(Parsegres::AST::BinaryExpr)
          expr.op.should eq "->"
          expr.left.as(Parsegres::AST::ColumnRef).column.should eq "data"
          expr.right.as(Parsegres::AST::StringLiteral).value.should eq "key"
        end

        it "parses ->> (field as text)" do
          Parsegres.parse("SELECT data->>'key' FROM t").as(SELECT)
            .columns[0].expr.as(Parsegres::AST::BinaryExpr)
            .op.should eq "->>"
        end

        it "chains -> and ->>" do
          expr = Parsegres.parse("SELECT data->'a'->>'b' FROM t").as(SELECT)
            .columns[0].expr.as(Parsegres::AST::BinaryExpr)
          expr.op.should eq "->>"
          expr.left.as(Parsegres::AST::BinaryExpr).op.should eq "->"
        end
      end

      describe "containment operators" do
        it "parses @> (contains)" do
          Parsegres.parse("SELECT * FROM t WHERE a @> b").as(SELECT)
            .where.as(Parsegres::AST::BinaryExpr).op.should eq "@>"
        end

        it "parses <@ (contained by)" do
          Parsegres.parse("SELECT * FROM t WHERE a <@ b").as(SELECT)
            .where.as(Parsegres::AST::BinaryExpr).op.should eq "<@"
        end
      end

      describe "full-text search operator" do
        it "parses @@ operator" do
          Parsegres.parse("SELECT * FROM t WHERE ts @@ query").as(SELECT)
            .where.as(Parsegres::AST::BinaryExpr).op.should eq "@@"
        end
      end

      describe "regex match operators" do
        it "parses ~ (case-sensitive match)" do
          Parsegres.parse("SELECT * FROM t WHERE name ~ 'pat'").as(SELECT)
            .where.as(Parsegres::AST::BinaryExpr).op.should eq "~"
        end

        it "parses ~* (case-insensitive match)" do
          Parsegres.parse("SELECT * FROM t WHERE name ~* 'pat'").as(SELECT)
            .where.as(Parsegres::AST::BinaryExpr).op.should eq "~*"
        end

        it "parses !~ (case-sensitive no match)" do
          Parsegres.parse("SELECT * FROM t WHERE name !~ 'pat'").as(SELECT)
            .where.as(Parsegres::AST::BinaryExpr).op.should eq "!~"
        end

        it "parses !~* (case-insensitive no match)" do
          Parsegres.parse("SELECT * FROM t WHERE name !~* 'pat'").as(SELECT)
            .where.as(Parsegres::AST::BinaryExpr).op.should eq "!~*"
        end
      end

      describe "exponentiation operator" do
        it "parses ^ operator" do
          Parsegres.parse("SELECT 2 ^ 10").as(SELECT)
            .columns[0].expr.as(Parsegres::AST::BinaryExpr).op.should eq "^"
        end
      end

      describe "bitwise operators" do
        it "parses & (bitwise AND)" do
          Parsegres.parse("SELECT flags & 1 FROM t").as(SELECT)
            .columns[0].expr.as(Parsegres::AST::BinaryExpr).op.should eq "&"
        end

        it "parses | (bitwise OR)" do
          Parsegres.parse("SELECT flags | 1 FROM t").as(SELECT)
            .columns[0].expr.as(Parsegres::AST::BinaryExpr).op.should eq "|"
        end

        it "parses << (shift left)" do
          Parsegres.parse("SELECT 1 << 4").as(SELECT)
            .columns[0].expr.as(Parsegres::AST::BinaryExpr).op.should eq "<<"
        end

        it "parses >> (shift right)" do
          Parsegres.parse("SELECT 256 >> 4").as(SELECT)
            .columns[0].expr.as(Parsegres::AST::BinaryExpr).op.should eq ">>"
        end
      end

      describe "unary bitwise NOT" do
        it "parses ~ as unary prefix operator" do
          expr = Parsegres.parse("SELECT ~flags FROM t").as(SELECT)
            .columns[0].expr.as(Parsegres::AST::UnaryExpr)
          expr.op.should eq "~"
          expr.operand.as(Parsegres::AST::ColumnRef).column.should eq "flags"
        end
      end
    end

    describe "CASE expressions" do
      it "parses searched CASE" do
        expr = Parsegres.parse(<<-SQL).as(SELECT)
          SELECT
            CASE
            WHEN status = 'active' THEN 1
            ELSE 0
            END
          FROM users
        SQL
          .columns[0]
          .expr.as(Parsegres::AST::CaseExpr)

        expr.subject.should be_nil
        expr.whens.size.should eq 1
        expr.else.should_not be_nil
      end

      it "parses simple CASE" do
        expr = Parsegres.parse("SELECT CASE status WHEN 'active' THEN 1 WHEN 'inactive' THEN 0 END FROM users").as(SELECT)
          .columns[0]
          .expr.as(Parsegres::AST::CaseExpr)

        expr.subject.should_not be_nil
        expr.whens.size.should eq 2
      end
    end

    describe "CTEs" do
      it "parses a basic WITH clause" do
        query = Parsegres.parse(<<-SQL).as(SELECT)
          WITH active_users AS (
            SELECT id, name
            FROM users
            WHERE status = 'active'
          )
          SELECT id, name FROM active_users
        SQL
        query.ctes.size.should eq 1
        cte = query.ctes[0]
        cte.name.should eq "active_users"
        cte.columns.should be_nil
        cte.query.as(SELECT).from[0].as(Parsegres::AST::TableRef).name.should eq "users"
        query.recursive?.should be_false
        query.from[0].as(Parsegres::AST::TableRef).name.should eq "active_users"
      end

      it "parses multiple CTEs" do
        ctes = Parsegres.parse(<<-SQL).as(SELECT).ctes
          WITH
            a AS (SELECT 1),
            b AS (SELECT 2)
          SELECT * FROM a, b
          SQL

        ctes.size.should eq 2
        ctes[0].name.should eq "a"
        ctes[1].name.should eq "b"
      end

      it "parses a RECURSIVE CTE with UNION ALL" do
        query = Parsegres.parse(<<-SQL).as(SELECT)
          WITH RECURSIVE nums (n) AS (
            SELECT 1
            UNION ALL
            SELECT n + 1 FROM nums WHERE n < 10
          )
          SELECT n FROM nums
          SQL
        query.recursive?.should be_true
        cte = query.ctes[0]
        cte.name.should eq "nums"
        cte.columns.should eq ["n"]
        body = cte.query.as(CompoundSelect)
        body.op.union_all?.should be_true
        body.left.should be_a(SELECT)
        body.right.should be_a(SELECT)
      end

      it "parses a CTE with an explicit column list" do
        cte = Parsegres.parse(<<-SQL).as(SELECT).ctes.first
          WITH totals (user_id, total) AS (
            SELECT user_id, sum(amount) FROM orders GROUP BY user_id
          )
          SELECT user_id, total FROM totals
          SQL

        cte.name.should eq "totals"
        cte.columns.should eq ["user_id", "total"]
      end

      it "parses WITH ... UPDATE" do
        stmt = Parsegres.parse(<<-SQL).as(UPDATE)
          WITH people_ids AS (
            SELECT people.id AS id, users.id AS user_id
            FROM people
            JOIN users ON users.id = people.user_id
          )
          UPDATE users
          SET person_id = (
            SELECT people_ids.id
            FROM people_ids
            WHERE user_id = users.id
          )
        SQL

        stmt.ctes.size.should eq 1
        stmt.ctes[0].name.should eq "people_ids"
        stmt.table.should eq "users"
        stmt.assignments[0].column.should eq "person_id"
        stmt.assignments[0].value.should be_a(Parsegres::AST::SubqueryExpr)
      end

      it "parses WITH ... INSERT" do
        stmt = Parsegres.parse(<<-SQL).as(INSERT)
          WITH src AS (SELECT id FROM staging)
          INSERT INTO users (id) SELECT id FROM src
        SQL

        stmt.ctes.size.should eq 1
        stmt.ctes[0].name.should eq "src"
        stmt.table.should eq "users"
      end

      it "parses WITH ... DELETE" do
        stmt = Parsegres.parse(<<-SQL).as(DELETE)
          WITH old AS (SELECT id FROM archive)
          DELETE FROM users WHERE id IN (SELECT id FROM old)
        SQL

        stmt.ctes.size.should eq 1
        stmt.ctes[0].name.should eq "old"
        stmt.table.should eq "users"
      end
    end

    describe "set operations" do
      it "parses UNION ALL" do
        stmt = Parsegres.parse(<<-SQL).as(CompoundSelect)
          SELECT id FROM users

          UNION ALL

          SELECT id FROM admins
        SQL

        stmt.op.union_all?.should be_true
        stmt.left.as(SELECT).from[0].as(Parsegres::AST::TableRef).name.should eq "users"
        stmt.right.as(SELECT).from[0].as(Parsegres::AST::TableRef).name.should eq "admins"
      end

      it "parses UNION (distinct by default)" do
        Parsegres.parse(<<-SQL).as(CompoundSelect).op.union?.should be_true
          SELECT id FROM a

          UNION

          SELECT id FROM b
        SQL
      end

      it "parses UNION DISTINCT (explicit keyword)" do
        Parsegres.parse(<<-SQL).as(CompoundSelect).op.union?.should be_true
          SELECT 1

          UNION DISTINCT

          SELECT 2
        SQL
      end

      it "parses INTERSECT" do
        Parsegres.parse(<<-SQL).as(CompoundSelect).op.intersect?.should be_true
          SELECT id FROM a

          INTERSECT

          SELECT id FROM b
        SQL
      end

      it "parses INTERSECT ALL" do
        Parsegres.parse(<<-SQL).as(CompoundSelect).op.intersect_all?.should be_true
          SELECT id FROM a

          INTERSECT ALL

          SELECT id FROM b
        SQL
      end

      it "parses EXCEPT" do
        Parsegres.parse(<<-SQL).as(CompoundSelect).op.except?.should be_true
          SELECT id FROM a

          EXCEPT

          SELECT id FROM b
        SQL
      end

      it "parses EXCEPT ALL" do
        Parsegres.parse(<<-SQL).as(CompoundSelect).op.except_all?.should be_true
          SELECT id FROM a

          EXCEPT

          ALL SELECT id FROM b
        SQL
      end

      it "UNION chains bind from left to right" do
        # SELECT 1 UNION SELECT 2 UNION SELECT 3  ==  (SELECT 1 UNION SELECT 2) UNION SELECT 3
        outer = Parsegres.parse(<<-SQL).as(CompoundSelect)
          SELECT 1

          UNION

          SELECT 2

          UNION

          SELECT 3
        SQL
        outer.op.union?.should be_true
        outer.left.should be_a(CompoundSelect)
        outer.left.as(CompoundSelect).op.union?.should be_true
        outer.right.should be_a(SELECT)
      end

      it "INTERSECT binds more tightly than UNION" do
        # SELECT 1 UNION SELECT 2 INTERSECT SELECT 3  ==  SELECT 1 UNION (SELECT 2 INTERSECT SELECT 3)
        outer = Parsegres.parse(<<-SQL).as(CompoundSelect)
          SELECT 1

          UNION

          SELECT 2

          INTERSECT

          SELECT 3
        SQL
        outer.op.union?.should be_true
        outer.left.should be_a(SELECT)
        inner = outer.right.as(CompoundSelect)
        inner.op.intersect?.should be_true
      end

      it "INTERSECT binds more tightly than EXCEPT" do
        # SELECT 1 EXCEPT SELECT 2 INTERSECT SELECT 3  ==  SELECT 1 EXCEPT (SELECT 2 INTERSECT SELECT 3)
        outer = Parsegres.parse("SELECT 1 EXCEPT SELECT 2 INTERSECT SELECT 3").as(CompoundSelect)
        outer.op.except?.should be_true
        outer.right.as(CompoundSelect).op.intersect?.should be_true
      end

      it "ORDER BY and LIMIT apply to the entire compound result" do
        stmt = Parsegres.parse(<<-SQL).as(CompoundSelect)
          SELECT id FROM a

          UNION

          SELECT id FROM b
          -- The clauses below apply to the compound query, not the second `SELECT`
          ORDER BY id DESC
          LIMIT 10
        SQL
        stmt.op.union?.should be_true
        stmt.order_by.size.should eq 1
        stmt.order_by[0].direction.desc?.should be_true
        stmt.limit.as(Parsegres::AST::IntegerLiteral).value.should eq 10
      end

      it "parses a compound query as a subquery in FROM" do
        ref = Parsegres.parse(<<-SQL).as(SELECT)
          SELECT id
          FROM (
            SELECT id
            FROM a

            UNION

            SELECT id
            FROM b
          ) combined
        SQL
          .from[0].as(Parsegres::AST::SubqueryRef)

        ref.alias_name.should eq "combined"
        ref.query.as(CompoundSelect).op.union?.should be_true
      end
    end

    describe "INSERT statements" do
      it "parses a simple INSERT with VALUES" do
        stmt = Parsegres.parse("INSERT INTO users VALUES (1, 'alice')").as(INSERT)
        stmt.table.should eq "users"
        stmt.schema.should be_nil
        stmt.columns.should be_nil
        rows = stmt.source.as(ValuesSource).rows
        rows.size.should eq 1
        row = rows.first
        row[0].as(Parsegres::AST::IntegerLiteral).value.should eq 1
        row[1].as(Parsegres::AST::StringLiteral).value.should eq "alice"
      end

      it "parses INSERT with a column list" do
        stmt = Parsegres.parse(<<-SQL).as(INSERT)
          INSERT INTO users (id, name)
          VALUES (1, 'alice')
        SQL
        stmt.columns.should eq ["id", "name"]
      end

      it "parses INSERT with multiple VALUE rows" do
        stmt = Parsegres.parse(<<-SQL).as(INSERT)
          INSERT INTO users
          VALUES
            (1, 'alice'),
            (2, 'bob')
        SQL
        stmt.source.as(ValuesSource).rows.size.should eq 2
      end

      it "parses INSERT DEFAULT VALUES" do
        stmt = Parsegres.parse("INSERT INTO users DEFAULT VALUES").as(INSERT)
        stmt.source.should be_a(DefaultValuesSource)
      end

      it "parses INSERT ... SELECT" do
        Parsegres.parse(<<-SQL).as(INSERT)
          INSERT INTO archive
          SELECT *
          FROM users
          WHERE active = false
        SQL
          .source.as(SelectSource)
          .query.as(SELECT)
          .from[0].as(Parsegres::AST::TableRef)
          .name
          .should eq "users"
      end

      it "parses INSERT with RETURNING columns" do
        stmt = Parsegres.parse(<<-SQL).as(INSERT)
          INSERT INTO users (name)
          VALUES ('alice')
          RETURNING
            id,
            created_at
        SQL

        stmt.returning.size.should eq 2
        stmt.returning[0].expr.as(Parsegres::AST::ColumnRef).column.should eq "id"
      end

      it "parses INSERT with RETURNING *" do
        Parsegres.parse("INSERT INTO users VALUES (1) RETURNING *").as(INSERT)
          .returning[0]
          .expr
          .should be_a(Parsegres::AST::Wildcard)
      end

      it "parses INSERT with a schema-qualified table" do
        stmt = Parsegres.parse("INSERT INTO public.users VALUES (1)").as(INSERT)

        stmt.schema.should eq "public"
        stmt.table.should eq "users"
      end

      it "parses INSERT with parameter placeholders" do
        stmt = Parsegres.parse("INSERT INTO users (id, name) VALUES ($1, $2)").as(INSERT)
        row = stmt.source.as(ValuesSource).rows.first
        row[0].as(Parsegres::AST::ParamRef).index.should eq 1
        row[1].as(Parsegres::AST::ParamRef).index.should eq 2
      end
    end

    describe "UPDATE statements" do
      it "parses a simple UPDATE" do
        stmt = Parsegres.parse("UPDATE users SET name = 'alice'").as(UPDATE)

        stmt.table.should eq "users"
        stmt.schema.should be_nil
        stmt.only?.should be_false
        stmt.alias_name.should be_nil
        stmt.assignments.size.should eq 1
        stmt.assignments[0].column.should eq "name"
        stmt.assignments[0].value.as(Parsegres::AST::StringLiteral).value.should eq "alice"
      end

      it "parses UPDATE with multiple assignments" do
        stmt = Parsegres.parse(<<-SQL).as(UPDATE)
          UPDATE users
          SET
            name = 'alice',
            age = 30
        SQL

        stmt.assignments.size.should eq 2
        stmt.assignments[0].column.should eq "name"
        stmt.assignments[1].column.should eq "age"
        stmt.assignments[1].value.as(Parsegres::AST::IntegerLiteral).value.should eq 30
      end

      it "parses UPDATE with WHERE" do
        stmt = Parsegres.parse(<<-SQL).as(UPDATE)
          UPDATE users
          SET active = true
          WHERE id = $1
        SQL
        where = stmt.where.as(Parsegres::AST::BinaryExpr)
        where.op.should eq "="
        where.left.as(Parsegres::AST::ColumnRef).column.should eq "id"
        where.right.as(Parsegres::AST::ParamRef).index.should eq 1
      end

      it "parses UPDATE with FROM" do
        stmt = Parsegres.parse(<<-SQL).as(UPDATE)
          UPDATE employees
          SET salary = salaries.amount
          FROM salaries
          WHERE employees.id = salaries.employee_id
        SQL

        stmt.from.size.should eq 1
        stmt.from[0].as(Parsegres::AST::TableRef).name.should eq "salaries"
        stmt.where.should_not be_nil
      end

      it "parses UPDATE with RETURNING" do
        stmt = Parsegres.parse(<<-SQL).as(UPDATE)
          UPDATE users
          SET name = 'alice'
          WHERE id = 1
          RETURNING id, name
        SQL

        stmt.returning.size.should eq 2
        stmt.returning[0].expr.as(Parsegres::AST::ColumnRef).column.should eq "id"
        stmt.returning[1].expr.as(Parsegres::AST::ColumnRef).column.should eq "name"
      end

      it "parses UPDATE with RETURNING *" do
        Parsegres.parse("UPDATE users SET active = false RETURNING *").as(UPDATE)
          .returning[0]
          .expr
          .should be_a(Parsegres::AST::Wildcard)
      end

      it "parses UPDATE with a schema-qualified table" do
        stmt = Parsegres.parse("UPDATE public.users SET active = false").as(UPDATE)
        stmt.schema.should eq "public"
        stmt.table.should eq "users"
      end

      it "parses UPDATE ONLY" do
        stmt = Parsegres.parse("UPDATE ONLY users SET active = false").as(UPDATE)
        stmt.only?.should be_true
        # Gotta make sure we didn't parse `ONLY` as the table name
        stmt.table.should eq "users"
      end

      it "parses UPDATE with a table alias" do
        Parsegres.parse(<<-SQL).as(UPDATE)
          UPDATE users AS u
          -- note: you can't use the alias in the SET clause
          SET active = false
          WHERE u.id = 1
        SQL
          .alias_name
          .should eq "u"
      end

      it "parses UPDATE SET col = DEFAULT" do
        Parsegres.parse("UPDATE users SET status = DEFAULT WHERE id = 1").as(UPDATE)
          .assignments[0]
          .value
          .should be_a(Parsegres::AST::DefaultExpr)
      end

      it "parses UPDATE with parameter placeholders" do
        stmt = Parsegres.parse(<<-SQL).as(UPDATE)
          UPDATE users
          SET
            name = $1,
            age = $2
          WHERE id = $3
        SQL

        stmt.assignments[0].value.as(Parsegres::AST::ParamRef).index.should eq 1
        stmt.assignments[1].value.as(Parsegres::AST::ParamRef).index.should eq 2
        stmt.where.as(Parsegres::AST::BinaryExpr).right.as(Parsegres::AST::ParamRef).index.should eq 3
      end
    end

    describe "CREATE TABLE statements" do
      it "parses a simple CREATE TABLE" do
        stmt = Parsegres.parse(<<-SQL).as(CREATE_TABLE)
          CREATE TABLE users (
            id integer,
            name text,
            active boolean
          )
        SQL

        stmt.name.should eq "users"
        stmt.schema.should be_nil
        stmt.temporary?.should be_false
        stmt.if_not_exists?.should be_false
        stmt.columns.size.should eq 3
        stmt.columns[0].name.should eq "id"
        stmt.columns[0].type_name.should eq "integer"
        stmt.columns[1].name.should eq "name"
        stmt.columns[1].type_name.should eq "text"
        stmt.constraints.should be_empty
      end

      it "parses CREATE TEMP TABLE" do
        Parsegres.parse("CREATE TEMP TABLE t (id integer)").as(CREATE_TABLE)
          .temporary?
          .should be_true
      end

      it "parses CREATE TEMPORARY TABLE" do
        Parsegres.parse("CREATE TEMPORARY TABLE t (id integer)").as(CREATE_TABLE)
          .temporary?
          .should be_true
      end

      it "parses CREATE TABLE IF NOT EXISTS" do
        stmt = Parsegres.parse("CREATE TABLE IF NOT EXISTS users (id integer)").as(CREATE_TABLE)

        stmt.if_not_exists?.should be_true
        # Making sure we didn't parse the `IF` as the table name
        stmt.name.should eq "users"
      end

      it "parses a schema-qualified table name" do
        stmt = Parsegres.parse("CREATE TABLE public.users (id integer)").as(CREATE_TABLE)

        stmt.schema.should eq "public"
        stmt.name.should eq "users"
      end

      describe "column types" do
        it "parses types with precision" do
          stmt = Parsegres.parse(<<-SQL).as(CREATE_TABLE)
            CREATE TABLE products (
              name varchar(255),
              price numeric(10, 2)
            )
          SQL

          stmt.columns[0].type_name.should eq "varchar(255)"
          stmt.columns[1].type_name.should eq "numeric(10, 2)"
        end

        it "parses array column types" do
          Parsegres.parse("CREATE TABLE t (tags text[])").as(CREATE_TABLE)
            .columns[0]
            .type_name
            .should eq "text[]"
        end

        describe "types with multiple name tokens" do
          it "parses double precision" do
            Parsegres.parse("CREATE TABLE t (val double precision)").as(CREATE_TABLE)
              .columns[0]
              .type_name
              .should eq "double precision"
          end

          it "parses character varying with length" do
            Parsegres.parse("CREATE TABLE t (s character varying(100))").as(CREATE_TABLE)
              .columns[0]
              .type_name
              .should eq "character varying(100)"
          end

          it "parses timestamp with time zone" do
            Parsegres.parse("CREATE TABLE t (ts timestamp with time zone)").as(CREATE_TABLE)
              .columns[0]
              .type_name
              .should eq "timestamp with time zone"
          end

          it "parses timestamp without time zone" do
            Parsegres.parse("CREATE TABLE t (ts timestamp without time zone)").as(CREATE_TABLE)
              .columns[0]
              .type_name
              .should eq "timestamp without time zone"
          end

          it "parses time with time zone" do
            Parsegres.parse("CREATE TABLE t (ts time with time zone)").as(CREATE_TABLE)
              .columns[0]
              .type_name
              .should eq "time with time zone"
          end
        end
      end

      describe "column constraints" do
        it "parses NOT NULL" do
          Parsegres.parse("CREATE TABLE t (name text NOT NULL)").as(CREATE_TABLE)
            .columns[0]
            .constraints[0]
            .should be_a(Parsegres::AST::NotNullConstraint)
        end

        it "parses explicit NULL" do
          Parsegres.parse("CREATE TABLE t (name text NULL)").as(CREATE_TABLE)
            .columns[0]
            .constraints[0]
            .should be_a(Parsegres::AST::NullConstraint)
        end

        it "parses DEFAULT with a literal" do
          Parsegres.parse("CREATE TABLE t (active boolean DEFAULT true)").as(CREATE_TABLE)
            .columns[0]
            .constraints[0].as(Parsegres::AST::DefaultConstraint)
            .expr.as(Parsegres::AST::BoolLiteral)
            .value
            .should be_true
        end

        it "parses DEFAULT with a function call" do
          Parsegres.parse("CREATE TABLE t (created_at timestamptz DEFAULT now())").as(CREATE_TABLE)
            .columns[0]
            .constraints[0].as(Parsegres::AST::DefaultConstraint)
            .expr.as(Parsegres::AST::FunctionCall)
            .name
            .should eq "now"
        end

        it "parses DEFAULT with an integer expression" do
          Parsegres.parse("CREATE TABLE t (count integer DEFAULT 42)").as(CREATE_TABLE)
            .columns[0]
            .constraints[0].as(Parsegres::AST::DefaultConstraint)
            .expr.as(Parsegres::AST::IntegerLiteral)
            .value
            .should eq 42
        end

        it "parses PRIMARY KEY" do
          Parsegres.parse("CREATE TABLE t (id integer PRIMARY KEY)").as(CREATE_TABLE)
            .columns[0]
            .constraints[0]
            .should be_a(Parsegres::AST::PrimaryKeyColumnConstraint)
        end

        it "parses UNIQUE" do
          Parsegres.parse("CREATE TABLE t (email text UNIQUE)").as(CREATE_TABLE)
            .columns[0]
            .constraints[0]
            .should be_a(Parsegres::AST::UniqueColumnConstraint)
        end

        it "parses CHECK" do
          expr = Parsegres.parse("CREATE TABLE t (age integer CHECK (age >= 0))").as(CREATE_TABLE)
            .columns[0]
            # validating here that it's a CHECK constraint
            .constraints[0].as(Parsegres::AST::CheckColumnConstraint)
            .expr.as(Parsegres::AST::BinaryExpr)

          expr.left.as(Parsegres::AST::ColumnRef).column.should eq "age"
          expr.op.should eq ">="
          expr.right.as(Parsegres::AST::IntegerLiteral).value.should eq 0
        end

        it "parses REFERENCES without a column" do
          constraint = Parsegres.parse("CREATE TABLE orders (user_id integer REFERENCES users)").as(CREATE_TABLE)
            .columns[0]
            .constraints[0].as(Parsegres::AST::ReferencesConstraint)

          constraint.ref_table.should eq "users"
          constraint.ref_column.should be_nil
        end

        it "parses REFERENCES with a column" do
          constraint = Parsegres.parse("CREATE TABLE orders (user_id integer REFERENCES users (id))").as(CREATE_TABLE)
            .columns[0]
            .constraints[0].as(Parsegres::AST::ReferencesConstraint)

          constraint.ref_table.should eq "users"
          constraint.ref_column.should eq "id"
        end

        it "parses multiple constraints on one column" do
          constraints = Parsegres.parse("CREATE TABLE t (id integer NOT NULL PRIMARY KEY)").as(CREATE_TABLE)
            .columns.first
            .constraints

          constraints.size.should eq 2
          constraints[0].should be_a Parsegres::AST::NotNullConstraint
          constraints[1].should be_a Parsegres::AST::PrimaryKeyColumnConstraint
        end

        it "parses a named CONSTRAINT on a column" do
          Parsegres.parse("CREATE TABLE t (age integer CONSTRAINT age_positive CHECK (age > 0))").as(CREATE_TABLE)
            .columns[0]
            .constraints[0].as(Parsegres::AST::CheckColumnConstraint)
            .constraint_name
            .should eq "age_positive"
        end
      end

      describe "table constraints" do
        it "parses PRIMARY KEY" do
          Parsegres.parse(<<-SQL).as(CREATE_TABLE)
            CREATE TABLE t (id integer, PRIMARY KEY (id))
          SQL
            .constraints[0].as(Parsegres::AST::PrimaryKeyTableConstraint)
            .columns
            .should eq %w[id]
        end

        it "parses composite PRIMARY KEY" do
          Parsegres.parse(<<-SQL).as(CREATE_TABLE)
            CREATE TABLE t (a integer, b integer, PRIMARY KEY (a, b))
          SQL
            .constraints[0].as(Parsegres::AST::PrimaryKeyTableConstraint)
            .columns
            .should eq %w[a b]
        end

        it "parses UNIQUE" do
          Parsegres.parse(<<-SQL).as(CREATE_TABLE)
            CREATE TABLE t (email text, UNIQUE (email))
          SQL
            .constraints[0].as(Parsegres::AST::UniqueTableConstraint)
            .columns
            .should eq %w[email]
        end

        it "parses UNIQUE with keyword column names" do
          Parsegres.parse(<<-SQL).as(CREATE_TABLE)
            CREATE TABLE git_objects (sha text, repo_id uuid, type int4, UNIQUE (sha, repo_id, type))
          SQL
            .constraints[0].as(Parsegres::AST::UniqueTableConstraint)
            .columns
            .should eq %w[sha repo_id type]
        end

        it "parses CHECK" do
          Parsegres.parse(<<-SQL).as(CREATE_TABLE)
            CREATE TABLE t (price numeric, CHECK (price > 0))
          SQL
            .constraints[0].as(Parsegres::AST::CheckTableConstraint)
            .expr.as(Parsegres::AST::BinaryExpr)
            .op
            .should eq ">"
        end

        it "parses FOREIGN KEY" do
          foreign_key = Parsegres.parse(<<-SQL).as(CREATE_TABLE)
            CREATE TABLE orders (
              user_id integer,
              FOREIGN KEY (user_id) REFERENCES users (id)
            )
          SQL
            .constraints[0].as(Parsegres::AST::ForeignKeyTableConstraint)

          foreign_key.columns.should eq ["user_id"]
          foreign_key.ref_table.should eq "users"
          foreign_key.ref_columns.should eq ["id"]
        end

        it "parses a composite FOREIGN KEY" do
          fk = Parsegres.parse(<<-SQL).as(CREATE_TABLE)
            CREATE TABLE t (
              a integer, b integer,
              FOREIGN KEY (a, b) REFERENCES other (x, y)
            )
          SQL
            .constraints[0].as(Parsegres::AST::ForeignKeyTableConstraint)

          fk.columns.should eq %w[a b]
          fk.ref_columns.should eq %w[x y]
        end

        it "parses FOREIGN KEY without reference columns" do
          fk = Parsegres.parse(<<-SQL).as(CREATE_TABLE)
            CREATE TABLE orders (user_id integer, FOREIGN KEY (user_id) REFERENCES users)
          SQL
            .constraints[0].as(Parsegres::AST::ForeignKeyTableConstraint)

          fk.ref_table.should eq "users"
          fk.ref_columns.should be_nil
        end

        it "parses a named table constraint" do
          Parsegres.parse(<<-SQL).as(CREATE_TABLE)
            CREATE TABLE t (id integer, CONSTRAINT pk_t PRIMARY KEY (id))
          SQL
            .constraints
            .first.as(Parsegres::AST::PrimaryKeyTableConstraint)
            .constraint_name
            .should eq "pk_t"
        end

        describe "EXCLUDE constraint" do
          it "parses EXCLUDE USING with a single element" do
            excl = Parsegres.parse(<<-SQL).as(CREATE_TABLE)
              CREATE TABLE t (col tsrange, EXCLUDE USING GIST (col WITH &&))
            SQL
              .constraints[0].as(Parsegres::AST::ExcludeTableConstraint)

            excl.using.should eq "GIST"
            excl.elements.size.should eq 1
            excl.elements[0].column.should eq "col"
            excl.elements[0].operator.should eq "&&"
          end

          it "parses EXCLUDE with multiple elements and mixed operators" do
            stmt = Parsegres.parse(<<-SQL).as(CREATE_TABLE)
              CREATE TABLE user_availabilities(
                id UUID PRIMARY KEY NOT NULL DEFAULT gen_random_uuid(),
                user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                day_of_week SMALLINT NOT NULL,
                time_range timerange NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                EXCLUDE USING GIST (time_range WITH &&, day_of_week WITH =, user_id WITH =)
              )
            SQL

            stmt.columns.size.should eq 6
            excl = stmt.constraints[0].as(Parsegres::AST::ExcludeTableConstraint)
            excl.using.should eq "GIST"
            excl.elements.size.should eq 3
            excl.elements[0].column.should eq "time_range"
            excl.elements[0].operator.should eq "&&"
            excl.elements[1].column.should eq "day_of_week"
            excl.elements[1].operator.should eq "="
            excl.elements[2].column.should eq "user_id"
            excl.elements[2].operator.should eq "="
          end
        end
      end

      it "parses a table with a keyword-named column" do
        stmt = Parsegres.parse(<<-SQL).as(CREATE_TABLE)
          CREATE TABLE identities(
            id TEXT PRIMARY KEY NOT NULL,
            type INTEGER NOT NULL,
            email TEXT UNIQUE NOT NULL,
            photo_url TEXT,
            refresh_token TEXT UNIQUE NOT NULL,
            user_id UUID NOT NULL REFERENCES users(id),
            created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
          )
        SQL

        stmt.name.should eq "identities"
        stmt.columns.size.should eq 8
        stmt.columns[1].name.should eq "type"
        stmt.columns[1].type_name.should eq "INTEGER"
      end

      it "parses REFERENCES with ON DELETE CASCADE" do
        stmt = Parsegres.parse(<<-SQL).as(CREATE_TABLE)
          CREATE TABLE settings(
            id UUID PRIMARY KEY NOT NULL DEFAULT gen_random_uuid(),
            user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            value TEXT NOT NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            UNIQUE (name, user_id)
          )
        SQL

        stmt.name.should eq "settings"
        stmt.columns.size.should eq 6
        stmt.constraints.size.should eq 1

        id_col = stmt.columns[0]
        id_col.type_name.should eq "UUID"
        id_col.constraints[0].should be_a(Parsegres::AST::PrimaryKeyColumnConstraint)
        id_col.constraints[1].should be_a(Parsegres::AST::NotNullConstraint)
        id_col.constraints[2].as(Parsegres::AST::DefaultConstraint)
          .expr.as(Parsegres::AST::FunctionCall)
          .name.should eq "gen_random_uuid"

        user_id_col = stmt.columns[1]
        user_id_col.constraints[0].should be_a(Parsegres::AST::NotNullConstraint)
        ref = user_id_col.constraints[1].as(Parsegres::AST::ReferencesConstraint)
        ref.ref_table.should eq "users"
        ref.ref_column.should eq "id"

        u = stmt.constraints[0].as(Parsegres::AST::UniqueTableConstraint)
        u.columns.should eq ["name", "user_id"]
      end

      it "parses a realistic table definition" do
        stmt = Parsegres.parse(<<-SQL).as(CREATE_TABLE)
          CREATE TABLE orders (
            id bigint PRIMARY KEY,
            user_id int8 NOT NULL REFERENCES users (id),
            store_id int8 NOT NULL REFERENCES stores(id), -- no space after table
            total numeric(12, 2) NOT NULL DEFAULT 0,
            status text NOT NULL DEFAULT 'pending',
            created_at timestamp with time zone NOT NULL DEFAULT now(),
            CONSTRAINT orders_uniq_user_status UNIQUE (user_id, status)
          )
          SQL
        stmt.columns.size.should eq 6
        stmt.constraints.size.should eq 1

        id_col = stmt.columns[0]
        id_col.type_name.should eq "bigint"
        id_col.constraints[0].should be_a(Parsegres::AST::PrimaryKeyColumnConstraint)

        uid_col = stmt.columns[1]
        uid_col.constraints[0].should be_a(Parsegres::AST::NotNullConstraint)
        uid_col.constraints[1].as(Parsegres::AST::ReferencesConstraint).ref_table.should eq "users"

        total_col = stmt.columns[3]
        total_col.type_name.should eq "numeric(12, 2)"
        total_col
          .constraints[1].as(Parsegres::AST::DefaultConstraint)
          .expr.as(Parsegres::AST::IntegerLiteral)
          .value.should eq 0

        created_col = stmt.columns[5]
        created_col.type_name.should eq "timestamp with time zone"

        u = stmt.constraints[0].as(Parsegres::AST::UniqueTableConstraint)
        u.constraint_name.should eq "orders_uniq_user_status"
        u.columns.should eq ["user_id", "status"]
      end
    end

    describe "DELETE statements" do
      it "parses a simple DELETE" do
        stmt = Parsegres.parse("DELETE FROM users").as(DELETE)

        stmt.table.should eq "users"
        stmt.schema.should be_nil
        stmt.only?.should be_false
        stmt.alias_name.should be_nil
        stmt.where.should be_nil
        stmt.using.should be_empty
        stmt.returning.should be_empty
      end

      it "parses DELETE with WHERE" do
        where = Parsegres.parse("DELETE FROM users WHERE id = $1").as(DELETE)
          .where.as(Parsegres::AST::BinaryExpr)

        where.left.as(Parsegres::AST::ColumnRef).column.should eq "id"
        where.op.should eq "="
        where.right.as(Parsegres::AST::ParamRef).index.should eq 1
      end

      it "parses DELETE FROM ONLY" do
        stmt = Parsegres.parse("DELETE FROM ONLY users WHERE id = 1").as(DELETE)

        stmt.only?.should be_true
        stmt.table.should eq "users"
      end

      it "parses DELETE with a table alias" do
        Parsegres.parse("DELETE FROM users AS u WHERE u.active = false").as(DELETE)
          .alias_name
          .should eq "u"
      end

      it "parses DELETE with USING" do
        stmt = Parsegres.parse(<<-SQL).as(DELETE)
          DELETE FROM orders
          USING customers
          WHERE orders.customer_id = customers.id AND customers.active = false
        SQL

        stmt.using.size.should eq 1
        stmt.using[0].as(Parsegres::AST::TableRef).name.should eq "customers"
        stmt.where.should_not be_nil
      end

      it "parses DELETE with multiple USING tables" do
        stmt = Parsegres.parse(<<-SQL).as(DELETE)
          DELETE FROM a
          USING b, c
          WHERE a.id = b.a_id
            AND b.c_id = c.id
        SQL

        stmt.using.size.should eq 2
        stmt.using[0].as(Parsegres::AST::TableRef).name.should eq "b"
        stmt.using[1].as(Parsegres::AST::TableRef).name.should eq "c"
      end

      it "parses DELETE with RETURNING" do
        stmt = Parsegres.parse("DELETE FROM users WHERE id = 1 RETURNING id, name").as(DELETE)

        stmt.returning.size.should eq 2
        stmt.returning[0]
          .expr.as(Parsegres::AST::ColumnRef)
          .column
          .should eq "id"
      end

      it "parses DELETE with RETURNING *" do
        Parsegres.parse("DELETE FROM users WHERE id = 1 RETURNING *").as(DELETE)
          .returning[0]
          .expr
          .should be_a(Parsegres::AST::Wildcard)
      end

      it "parses DELETE with a schema-qualified table" do
        stmt = Parsegres.parse("DELETE FROM public.users WHERE id = 1").as(DELETE)

        stmt.schema.should eq "public"
        stmt.table.should eq "users"
      end
    end

    describe "DO statements" do
      it "parses a DO block with a dollar-quoted body" do
        stmt = Parsegres.parse(<<-SQL).as(DO_STMT)
          DO $$
          BEGIN
            RAISE EXCEPTION 'something bad happened';
          END
          $$
        SQL

        stmt.code.should contain("RAISE EXCEPTION")
        stmt.language.should be_nil
      end

      it "parses a DO block with an explicit LANGUAGE clause" do
        stmt = Parsegres.parse("DO LANGUAGE plpgsql $$BEGIN END$$").as(DO_STMT)

        stmt.language.should eq "plpgsql"
        stmt.code.should contain("BEGIN")
      end
    end

    describe "ALTER TABLE statements" do
      it "parses ADD COLUMN" do
        stmt = Parsegres.parse("ALTER TABLE users ADD COLUMN bio text").as(ALTER_TABLE)

        stmt.name.should eq "users"
        stmt.schema.should be_nil
        stmt.if_exists?.should be_false
        stmt.only?.should be_false
        action = stmt.actions[0].as(Parsegres::AST::AddColumnAction)
        action.if_not_exists?.should be_false
        action.column.name.should eq "bio"
        action.column.type_name.should eq "text"
      end

      it "parses ADD COLUMN without the COLUMN keyword" do
        Parsegres.parse("ALTER TABLE users ADD bio text").as(ALTER_TABLE)
          .actions[0].as(Parsegres::AST::AddColumnAction)
          .column
          .name
          .should eq "bio"
      end

      it "parses ADD COLUMN IF NOT EXISTS" do
        action = Parsegres.parse("ALTER TABLE users ADD COLUMN IF NOT EXISTS score integer").as(ALTER_TABLE)
          .actions[0].as(Parsegres::AST::AddColumnAction)

        action.if_not_exists?.should be_true
        action.column.name.should eq "score"
      end

      it "parses ADD COLUMN with constraints" do
        col = Parsegres.parse("ALTER TABLE users ADD COLUMN email text NOT NULL UNIQUE").as(ALTER_TABLE)
          .actions[0].as(Parsegres::AST::AddColumnAction)
          .column

        col.constraints[0].should be_a(Parsegres::AST::NotNullConstraint)
        col.constraints[1].should be_a(Parsegres::AST::UniqueColumnConstraint)
      end

      it "parses DROP COLUMN" do
        action = Parsegres.parse("ALTER TABLE users DROP COLUMN bio").as(ALTER_TABLE)
          .actions[0].as(Parsegres::AST::DropColumnAction)

        action.column.should eq "bio"
        action.if_exists?.should be_false
        action.behavior.should be_nil
      end

      it "parses DROP COLUMN without the COLUMN keyword" do
        Parsegres.parse("ALTER TABLE users DROP bio").as(ALTER_TABLE)
          .actions[0].as(Parsegres::AST::DropColumnAction)
          .column
          .should eq "bio"
      end

      it "parses DROP COLUMN IF EXISTS" do
        Parsegres.parse("ALTER TABLE users DROP COLUMN IF EXISTS bio").as(ALTER_TABLE)
          .actions[0].as(Parsegres::AST::DropColumnAction)
          .if_exists?
          .should be_true
      end

      it "parses DROP COLUMN CASCADE" do
        Parsegres.parse("ALTER TABLE users DROP COLUMN bio CASCADE").as(ALTER_TABLE)
          .actions[0].as(Parsegres::AST::DropColumnAction)
          .behavior.not_nil!
          .cascade?
          .should be_true
      end

      it "parses DROP COLUMN RESTRICT" do
        Parsegres.parse("ALTER TABLE users DROP COLUMN bio RESTRICT").as(ALTER_TABLE)
          .actions[0].as(Parsegres::AST::DropColumnAction)
          .behavior.not_nil!
          .restrict?
          .should be_true
      end

      it "parses ALTER COLUMN SET DATA TYPE" do
        action = Parsegres.parse("ALTER TABLE users ALTER COLUMN score SET DATA TYPE numeric(10,2)").as(ALTER_TABLE)
          .actions[0].as(Parsegres::AST::AlterColumnTypeAction)

        action.column.should eq "score"
        action.type_name.should eq "numeric(10, 2)"
      end

      it "parses ALTER COLUMN TYPE (shorthand)" do
        action = Parsegres.parse("ALTER TABLE users ALTER COLUMN score TYPE bigint").as(ALTER_TABLE)
          .actions[0].as(Parsegres::AST::AlterColumnTypeAction)

        action.column.should eq "score"
        action.type_name.should eq "bigint"
      end

      it "parses ALTER COLUMN without the COLUMN keyword" do
        Parsegres.parse("ALTER TABLE users ALTER score TYPE bigint").as(ALTER_TABLE)
          .actions[0].as(Parsegres::AST::AlterColumnTypeAction)
          .column
          .should eq "score"
      end

      it "parses ALTER COLUMN SET DEFAULT" do
        action = Parsegres.parse(<<-SQL).as(ALTER_TABLE)
          ALTER TABLE users
          ALTER COLUMN active
          SET DEFAULT true
        SQL
          .actions[0].as(Parsegres::AST::AlterColumnSetDefaultAction)

        action.column.should eq "active"
        action.expr.as(Parsegres::AST::BoolLiteral).value.should be_true
      end

      it "parses ALTER COLUMN DROP DEFAULT" do
        Parsegres.parse("ALTER TABLE users ALTER COLUMN active DROP DEFAULT").as(ALTER_TABLE)
          .actions[0].as(Parsegres::AST::AlterColumnDropDefaultAction)
          .column
          .should eq "active"
      end

      it "parses ALTER COLUMN SET NOT NULL" do
        Parsegres.parse("ALTER TABLE users ALTER COLUMN name SET NOT NULL").as(ALTER_TABLE)
          .actions[0].as(Parsegres::AST::AlterColumnSetNotNullAction)
          .column
          .should eq "name"
      end

      it "parses ALTER COLUMN DROP NOT NULL" do
        Parsegres.parse("ALTER TABLE users ALTER COLUMN name DROP NOT NULL").as(ALTER_TABLE)
          .actions[0].as(Parsegres::AST::AlterColumnDropNotNullAction)
          .column
          .should eq "name"
      end

      it "parses RENAME COLUMN" do
        action = Parsegres.parse("ALTER TABLE users RENAME COLUMN username TO login").as(ALTER_TABLE)
          .actions[0].as(Parsegres::AST::RenameColumnAction)

        action.old_name.should eq "username"
        action.new_name.should eq "login"
      end

      it "parses RENAME COLUMN without the COLUMN keyword" do
        action = Parsegres.parse("ALTER TABLE users RENAME username TO login").as(ALTER_TABLE)
          .actions[0].as(Parsegres::AST::RenameColumnAction)

        action.old_name.should eq "username"
        action.new_name.should eq "login"
      end

      it "parses RENAME TO (rename table)" do
        Parsegres.parse("ALTER TABLE users RENAME TO accounts").as(ALTER_TABLE)
          .actions[0].as(Parsegres::AST::RenameTableAction)
          .new_name
          .should eq "accounts"
      end

      it "parses ADD CONSTRAINT" do
        fk = Parsegres.parse("ALTER TABLE orders ADD CONSTRAINT fk_user FOREIGN KEY (user_id) REFERENCES users (id)").as(ALTER_TABLE)
          .actions[0].as(Parsegres::AST::AddConstraintAction)
          .constraint.as(Parsegres::AST::ForeignKeyTableConstraint)

        fk.constraint_name.should eq "fk_user"
        fk.columns.should eq ["user_id"]
        fk.ref_table.should eq "users"
        fk.ref_columns.should eq ["id"]
      end

      it "parses ADD PRIMARY KEY constraint" do
        Parsegres.parse("ALTER TABLE t ADD PRIMARY KEY (id)").as(ALTER_TABLE)
          .actions[0].as(Parsegres::AST::AddConstraintAction)
          .constraint.as(Parsegres::AST::PrimaryKeyTableConstraint)
          .columns
          .should eq ["id"]
      end

      it "parses DROP CONSTRAINT" do
        action = Parsegres.parse("ALTER TABLE orders DROP CONSTRAINT fk_user").as(ALTER_TABLE)
          .actions[0].as(Parsegres::AST::DropConstraintAction)

        action.name.should eq "fk_user"
        action.if_exists?.should be_false
        action.behavior.should be_nil
      end

      it "parses DROP CONSTRAINT IF EXISTS CASCADE" do
        action = Parsegres.parse("ALTER TABLE orders DROP CONSTRAINT IF EXISTS fk_user CASCADE").as(ALTER_TABLE)
          .actions[0].as(Parsegres::AST::DropConstraintAction)

        action.if_exists?.should be_true
        action.behavior.not_nil!.cascade?.should be_true
      end

      it "parses multiple actions" do
        stmt = Parsegres.parse(<<-SQL).as(ALTER_TABLE)
          ALTER TABLE users
          ADD COLUMN score integer DEFAULT 0,
          DROP COLUMN bio,
          ALTER COLUMN name SET NOT NULL
        SQL

        stmt.actions.size.should eq 3
        stmt.actions[0].should be_a(Parsegres::AST::AddColumnAction)
        stmt.actions[1].should be_a(Parsegres::AST::DropColumnAction)
        stmt.actions[2].should be_a(Parsegres::AST::AlterColumnSetNotNullAction)
      end

      it "parses ALTER TABLE IF EXISTS" do
        stmt = Parsegres.parse("ALTER TABLE IF EXISTS users ADD COLUMN bio text").as(ALTER_TABLE)

        stmt.if_exists?.should be_true
        stmt.name.should eq "users"
      end

      it "parses ALTER TABLE ONLY" do
        Parsegres.parse("ALTER TABLE ONLY users DROP COLUMN bio").as(ALTER_TABLE)
          .only?
          .should be_true
      end

      it "parses a schema-qualified table name" do
        stmt = Parsegres.parse("ALTER TABLE public.users ADD COLUMN bio text").as(ALTER_TABLE)

        stmt.schema.should eq "public"
        stmt.name.should eq "users"
      end
    end

    describe "DROP TABLE statements" do
      it "parses a simple DROP TABLE" do
        stmt = Parsegres.parse("DROP TABLE users").as(DROP_TABLE)

        stmt.targets.size.should eq 1
        stmt.targets[0].name.should eq "users"
        stmt.targets[0].schema.should be_nil
        stmt.if_exists?.should be_false
        stmt.behavior.should be_nil
      end

      it "parses DROP TABLE IF EXISTS" do
        stmt = Parsegres.parse("DROP TABLE IF EXISTS users").as(DROP_TABLE)

        stmt.if_exists?.should be_true
        stmt.targets[0].name.should eq "users"
      end

      it "parses DROP TABLE CASCADE" do
        Parsegres.parse("DROP TABLE users CASCADE").as(DROP_TABLE)
          .behavior.not_nil!
          .cascade?
          .should be_true
      end

      it "parses DROP TABLE RESTRICT" do
        Parsegres.parse("DROP TABLE users RESTRICT").as(DROP_TABLE)
          .behavior.not_nil!
          .restrict?
          .should be_true
      end

      it "parses DROP TABLE with multiple tables" do
        stmt = Parsegres.parse("DROP TABLE users, orders, products").as(DROP_TABLE)

        stmt.targets.size.should eq 3
        stmt.targets.map(&.name).should eq %w[users orders products]
      end

      it "parses DROP TABLE with a schema-qualified name" do
        table = Parsegres.parse("DROP TABLE public.users").as(DROP_TABLE)
          .targets[0]

        table.schema.should eq "public"
        table.name.should eq "users"
      end

      it "parses DROP TABLE IF EXISTS with multiple tables and CASCADE" do
        stmt = Parsegres.parse("DROP TABLE IF EXISTS a, public.b CASCADE").as(DROP_TABLE)

        stmt.if_exists?.should be_true
        stmt.targets.size.should eq 2
        stmt.targets[0].name.should eq "a"
        stmt.targets[1].schema.should eq "public"
        stmt.targets[1].name.should eq "b"
        stmt.behavior.not_nil!.cascade?.should be_true
      end
    end

    describe "CREATE INDEX statements" do
      it "parses a simple CREATE INDEX" do
        stmt = Parsegres.parse("CREATE INDEX idx_email ON users (email)").as(CREATE_INDEX)

        stmt.index_name.should eq "idx_email"
        stmt.table_name.should eq "users"
        stmt.table_schema.should be_nil
        stmt.unique?.should be_false
        stmt.concurrently?.should be_false
        stmt.if_not_exists?.should be_false
        stmt.only?.should be_false
        stmt.using.should be_nil
        stmt.where.should be_nil
        stmt.columns.size.should eq 1
        stmt.columns[0].column.should eq "email"
        stmt.columns[0].direction.should be_nil
        stmt.columns[0].nulls_order.should be_nil
      end

      it "parses CREATE UNIQUE INDEX" do
        Parsegres.parse(<<-SQL).as(CREATE_INDEX)
          CREATE UNIQUE INDEX idx_email
          ON users (email)
        SQL
          .unique?
          .should be_true
      end

      it "parses CREATE INDEX CONCURRENTLY" do
        Parsegres.parse(<<-SQL).as(CREATE_INDEX)
          CREATE INDEX CONCURRENTLY idx_email ON users (email)
        SQL
          .concurrently?
          .should be_true
      end

      it "parses CREATE INDEX IF NOT EXISTS" do
        Parsegres.parse("CREATE INDEX IF NOT EXISTS idx_email ON users (email)").as(CREATE_INDEX)
          .if_not_exists?
          .should be_true
      end

      it "parses CREATE INDEX without a name" do
        stmt = Parsegres.parse("CREATE INDEX ON users (email)").as(CREATE_INDEX)

        stmt.index_name.should be_nil
        stmt.table_name.should eq "users"
      end

      it "parses CREATE INDEX ON ONLY" do
        Parsegres.parse("CREATE INDEX ON ONLY users (email)").as(CREATE_INDEX)
          .only?
          .should be_true
      end

      it "parses CREATE INDEX USING method" do
        Parsegres.parse("CREATE INDEX ON users USING hash (email)").as(CREATE_INDEX)
          .using
          .should eq "hash"
      end

      it "parses CREATE INDEX with a schema-qualified table" do
        stmt = Parsegres.parse("CREATE INDEX ON public.users (email)").as(CREATE_INDEX)

        stmt.table_schema.should eq "public"
        stmt.table_name.should eq "users"
      end

      it "parses CREATE INDEX with multiple columns" do
        stmt = Parsegres.parse("CREATE INDEX ON users (last_name, first_name)").as(CREATE_INDEX)

        stmt.columns.size.should eq 2
        stmt.columns[0].column.should eq "last_name"
        stmt.columns[1].column.should eq "first_name"
      end

      it "parses column direction" do
        Parsegres.parse("CREATE INDEX ON users (created_at DESC)").as(CREATE_INDEX)
          .columns[0]
          .direction.not_nil!
          .desc?
          .should be_true
      end

      it "parses column NULLS FIRST / NULLS LAST" do
        Parsegres.parse("CREATE INDEX ON users (score DESC NULLS LAST)").as(CREATE_INDEX)
          .columns[0]
          .nulls_order.not_nil!
          .last?
          .should be_true
      end

      it "parses a partial index with WHERE" do
        where = Parsegres.parse("CREATE INDEX ON users (email) WHERE active = true").as(CREATE_INDEX)
          .where.as(Parsegres::AST::BinaryExpr)

        where.left.as(Parsegres::AST::ColumnRef).column.should eq "active"
        where.op.should eq "="
        where.right.as(Parsegres::AST::BoolLiteral).value.should eq true
      end

      it "parses a realistic CREATE UNIQUE INDEX" do
        stmt = Parsegres.parse(<<-SQL).as(CREATE_INDEX)
          CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS idx_users_email
          ON public.users USING btree (email ASC NULLS LAST)
          WHERE deleted_at IS NULL
        SQL

        stmt.unique?.should be_true
        stmt.concurrently?.should be_true
        stmt.if_not_exists?.should be_true
        stmt.index_name.should eq "idx_users_email"
        stmt.table_schema.should eq "public"
        stmt.table_name.should eq "users"
        stmt.using.should eq "btree"
        stmt.columns[0].column.should eq "email"
        stmt.columns[0].direction.not_nil!.asc?.should be_true
        stmt.columns[0].nulls_order.not_nil!.last?.should be_true
        stmt.where.should be_a(Parsegres::AST::IsNullExpr)
      end

      it "parses an index whose columns share names with keywords" do
        stmt = Parsegres.parse(<<-SQL).as(CREATE_INDEX)
          CREATE UNIQUE INDEX CONCURRENTLY index_identities_unique_on_type_and_email
          ON identities (type, email)
        SQL

        stmt.unique?.should be_true
        stmt.concurrently?.should be_true
        stmt.index_name.should eq "index_identities_unique_on_type_and_email"
        stmt.table_name.should eq "identities"
        stmt.columns.size.should eq 2
        stmt.columns[0].column.should eq "type"
        stmt.columns[1].column.should eq "email"
      end

      it "parses a parenthesized expression as an index element" do
        stmt = Parsegres.parse(<<-SQL).as(CREATE_INDEX)
          CREATE INDEX ON git_objects (repo_id, (metadata_raw::jsonb->>'tree'))
          WHERE type = 0
        SQL

        stmt.columns.size.should eq 2
        stmt.columns[0].column.should eq "repo_id"
        stmt.columns[1].column.should eq ""
        stmt.columns[1].expr.should be_a(Parsegres::AST::BinaryExpr)
      end

      it "parses USING gin with a parenthesized expression element" do
        stmt = Parsegres.parse(<<-SQL).as(CREATE_INDEX)
          CREATE INDEX ON git_objects USING gin ((metadata_raw::jsonb->'entries'))
          WHERE type = 1
        SQL

        stmt.using.should eq "gin"
        stmt.columns.size.should eq 1
        stmt.columns[0].expr.should be_a(Parsegres::AST::BinaryExpr)
      end
    end

    describe "DROP INDEX statements" do
      it "parses a simple DROP INDEX" do
        stmt = Parsegres.parse("DROP INDEX idx_email").as(DROP_INDEX)

        stmt.targets.size.should eq 1
        stmt.targets[0].name.should eq "idx_email"
        stmt.targets[0].schema.should be_nil
        stmt.concurrently?.should be_false
        stmt.if_exists?.should be_false
        stmt.behavior.should be_nil
      end

      it "parses DROP INDEX CONCURRENTLY" do
        Parsegres.parse("DROP INDEX CONCURRENTLY idx_email").as(DROP_INDEX)
          .concurrently?
          .should be_true
      end

      it "parses DROP INDEX IF EXISTS" do
        Parsegres.parse("DROP INDEX IF EXISTS idx_email").as(DROP_INDEX)
          .if_exists?
          .should be_true
      end

      it "parses DROP INDEX CASCADE" do
        Parsegres.parse("DROP INDEX idx_email CASCADE").as(DROP_INDEX)
          .behavior.not_nil!
          .cascade?
          .should be_true
      end

      it "parses DROP INDEX with multiple indexes" do
        stmt = Parsegres.parse("DROP INDEX idx_a, idx_b, idx_c").as(DROP_INDEX)

        stmt.targets.size.should eq 3
        stmt.targets.map(&.name).should eq %w[idx_a idx_b idx_c]
      end

      it "parses DROP INDEX with a schema-qualified name" do
        stmt = Parsegres.parse("DROP INDEX public.idx_email").as(DROP_INDEX)

        stmt.targets[0].schema.should eq "public"
        stmt.targets[0].name.should eq "idx_email"
      end

      it "parses DROP INDEX CONCURRENTLY IF EXISTS name RESTRICT" do
        stmt = Parsegres.parse("DROP INDEX CONCURRENTLY IF EXISTS idx_email RESTRICT").as(DROP_INDEX)

        stmt.concurrently?.should be_true
        stmt.if_exists?.should be_true
        stmt.behavior.not_nil!.restrict?.should be_true
      end
    end

    describe "CREATE VIEW statements" do
      it "parses a simple CREATE VIEW" do
        stmt = Parsegres.parse("CREATE VIEW active_users AS SELECT id, name FROM users WHERE active = true").as(CREATE_VIEW)

        stmt.name.should eq "active_users"
        stmt.schema.should be_nil
        stmt.or_replace?.should be_false
        stmt.temporary?.should be_false
        stmt.if_not_exists?.should be_false
        stmt.columns.should be_nil
        stmt.query.as(SELECT).from[0].as(Parsegres::AST::TableRef).name.should eq "users"
      end

      it "parses CREATE OR REPLACE VIEW" do
        stmt = Parsegres.parse("CREATE OR REPLACE VIEW v AS SELECT 1").as(CREATE_VIEW)

        stmt.or_replace?.should be_true
        stmt.name.should eq "v"
      end

      it "parses CREATE TEMP VIEW" do
        Parsegres.parse("CREATE TEMP VIEW v AS SELECT 1").as(CREATE_VIEW)
          .temporary?
          .should be_true
      end

      it "parses CREATE TEMPORARY VIEW" do
        Parsegres.parse("CREATE TEMPORARY VIEW v AS SELECT 1").as(CREATE_VIEW)
          .temporary?
          .should be_true
      end

      it "parses CREATE OR REPLACE TEMP VIEW" do
        stmt = Parsegres.parse("CREATE OR REPLACE TEMP VIEW v AS SELECT 1").as(CREATE_VIEW)

        stmt.or_replace?.should be_true
        stmt.temporary?.should be_true
      end

      it "parses CREATE VIEW IF NOT EXISTS" do
        Parsegres.parse("CREATE VIEW IF NOT EXISTS v AS SELECT 1").as(CREATE_VIEW)
          .if_not_exists?
          .should be_true
      end

      it "parses CREATE VIEW with an explicit column list" do
        Parsegres.parse("CREATE VIEW v (id, name) AS SELECT id, name FROM users").as(CREATE_VIEW)
          .columns
          .should eq %w[id name]
      end

      it "parses CREATE VIEW with a schema-qualified name" do
        stmt = Parsegres.parse("CREATE VIEW public.active_users AS SELECT 1").as(CREATE_VIEW)

        stmt.schema.should eq "public"
        stmt.name.should eq "active_users"
      end

      it "parses CREATE VIEW with a compound SELECT query" do
        Parsegres.parse(<<-SQL).as(CREATE_VIEW)
          CREATE VIEW v AS

          SELECT id FROM a

          UNION

          SELECT id FROM b
        SQL
          .query
          .should be_a(CompoundSelect)
      end
    end

    describe "DROP VIEW statements" do
      it "parses a simple DROP VIEW" do
        stmt = Parsegres.parse("DROP VIEW active_users").as(DROP_VIEW)

        stmt.targets.size.should eq 1
        stmt.targets[0].name.should eq "active_users"
        stmt.targets[0].schema.should be_nil
        stmt.if_exists?.should be_false
        stmt.behavior.should be_nil
      end

      it "parses DROP VIEW IF EXISTS" do
        stmt = Parsegres.parse("DROP VIEW IF EXISTS active_users").as(DROP_VIEW)

        stmt.if_exists?.should be_true
        stmt.targets[0].name.should eq "active_users"
      end

      it "parses DROP VIEW CASCADE" do
        Parsegres.parse("DROP VIEW active_users CASCADE").as(DROP_VIEW)
          .behavior.not_nil!
          .cascade?
          .should be_true
      end

      it "parses DROP VIEW RESTRICT" do
        Parsegres.parse("DROP VIEW active_users RESTRICT").as(DROP_VIEW)
          .behavior.not_nil!
          .restrict?
          .should be_true
      end

      it "parses DROP VIEW with multiple views" do
        stmt = Parsegres.parse("DROP VIEW v1, v2, v3").as(DROP_VIEW)

        stmt.targets.size.should eq 3
        stmt.targets.map(&.name).should eq %w[v1 v2 v3]
      end

      it "parses DROP VIEW with a schema-qualified name" do
        stmt = Parsegres.parse("DROP VIEW public.active_users").as(DROP_VIEW)

        stmt.targets[0].schema.should eq "public"
        stmt.targets[0].name.should eq "active_users"
      end
    end

    describe "TRUNCATE statements" do
      it "parses a simple TRUNCATE" do
        stmt = Parsegres.parse("TRUNCATE users").as(TRUNCATE)

        stmt.targets.size.should eq 1
        stmt.targets[0].name.should eq "users"
        stmt.targets[0].schema.should be_nil
        stmt.targets[0].only.should be_false
        stmt.identity.should be_nil
        stmt.behavior.should be_nil
      end

      it "parses TRUNCATE TABLE (optional TABLE keyword)" do
        Parsegres.parse("TRUNCATE TABLE users").as(TRUNCATE)
          .targets[0]
          .name
          .should eq "users"
      end

      it "parses TRUNCATE ONLY" do
        stmt = Parsegres.parse("TRUNCATE ONLY users").as(TRUNCATE)

        stmt.targets[0].only.should be_true
        stmt.targets[0].name.should eq "users"
      end

      it "parses TRUNCATE with multiple tables" do
        stmt = Parsegres.parse("TRUNCATE users, orders, products").as(TRUNCATE)

        stmt.targets.size.should eq 3
        stmt.targets.map(&.name).should eq %w[users orders products]
      end

      it "parses TRUNCATE RESTART IDENTITY" do
        Parsegres.parse("TRUNCATE users RESTART IDENTITY").as(TRUNCATE)
          .identity.not_nil!
          .restart?
          .should be_true
      end

      it "parses TRUNCATE CONTINUE IDENTITY" do
        Parsegres.parse("TRUNCATE users CONTINUE IDENTITY").as(TRUNCATE)
          .identity.not_nil!
          .continue?
          .should be_true
      end

      it "parses TRUNCATE CASCADE" do
        Parsegres.parse("TRUNCATE users CASCADE").as(TRUNCATE)
          .behavior.not_nil!
          .cascade?
          .should be_true
      end

      it "parses TRUNCATE RESTART IDENTITY CASCADE" do
        stmt = Parsegres.parse("TRUNCATE users RESTART IDENTITY CASCADE").as(TRUNCATE)

        stmt.identity.not_nil!.restart?.should be_true
        stmt.behavior.not_nil!.cascade?.should be_true
      end

      it "parses TRUNCATE with a schema-qualified table" do
        stmt = Parsegres.parse("TRUNCATE public.users").as(TRUNCATE)

        stmt.targets[0].schema.should eq "public"
        stmt.targets[0].name.should eq "users"
      end
    end

    describe "CREATE SEQUENCE statements" do
      it "parses a simple CREATE SEQUENCE" do
        stmt = Parsegres.parse("CREATE SEQUENCE seq").as(CREATE_SEQUENCE)

        stmt.name.should eq "seq"
        stmt.schema.should be_nil
        stmt.temporary?.should be_false
        stmt.if_not_exists?.should be_false
        stmt.options.increment.should be_nil
        stmt.options.cycle.should be_nil
      end

      it "parses CREATE SEQUENCE IF NOT EXISTS" do
        stmt = Parsegres.parse("CREATE SEQUENCE IF NOT EXISTS seq").as(CREATE_SEQUENCE)

        stmt.if_not_exists?.should be_true
        stmt.name.should eq "seq"
      end

      it "parses CREATE TEMPORARY SEQUENCE" do
        Parsegres.parse("CREATE TEMPORARY SEQUENCE seq").as(CREATE_SEQUENCE)
          .temporary?
          .should be_true
      end

      it "parses CREATE SEQUENCE AS TYPE" do
        options = Parsegres.parse("CREATE SEQUENCE seq AS int8 INCREMENT BY 1").as(CREATE_SEQUENCE)
          .options

        options.type.should eq "int8"
        options.increment.should eq 1
      end

      it "parses CREATE SEQUENCE with INCREMENT BY" do
        Parsegres.parse("CREATE SEQUENCE seq INCREMENT BY 5").as(CREATE_SEQUENCE)
          .options
          .increment
          .should eq 5
      end

      it "parses CREATE SEQUENCE with INCREMENT (no BY)" do
        Parsegres.parse("CREATE SEQUENCE seq INCREMENT 2").as(CREATE_SEQUENCE)
          .options
          .increment
          .should eq 2
      end

      it "parses CREATE SEQUENCE with MINVALUE and MAXVALUE" do
        stmt = Parsegres.parse("CREATE SEQUENCE seq MINVALUE 1 MAXVALUE 1000").as(CREATE_SEQUENCE)

        stmt.options.min_value.should eq 1
        stmt.options.max_value.should eq 1000
      end

      it "parses CREATE SEQUENCE with NO MINVALUE and NO MAXVALUE" do
        stmt = Parsegres.parse("CREATE SEQUENCE seq NO MINVALUE NO MAXVALUE").as(CREATE_SEQUENCE)

        stmt.options.no_min_value?.should be_true
        stmt.options.no_max_value?.should be_true
      end

      it "parses CREATE SEQUENCE with START WITH" do
        Parsegres.parse("CREATE SEQUENCE seq START WITH 100").as(CREATE_SEQUENCE)
          .options
          .start
          .should eq 100
      end

      it "parses CREATE SEQUENCE with CACHE" do
        Parsegres.parse("CREATE SEQUENCE seq CACHE 20").as(CREATE_SEQUENCE)
          .options
          .cache
          .should eq 20
      end

      it "parses CREATE SEQUENCE with CYCLE" do
        Parsegres.parse("CREATE SEQUENCE seq CYCLE").as(CREATE_SEQUENCE)
          .options
          .cycle
          .should be_true
      end

      it "parses CREATE SEQUENCE with NO CYCLE" do
        Parsegres.parse("CREATE SEQUENCE seq NO CYCLE").as(CREATE_SEQUENCE)
          .options
          .cycle
          .should be_false
      end

      it "parses CREATE SEQUENCE with OWNED BY" do
        Parsegres.parse("CREATE SEQUENCE seq OWNED BY users.id").as(CREATE_SEQUENCE)
          .options
          .owned_by
          .should eq "users.id"
      end

      it "parses CREATE SEQUENCE with OWNED BY NONE" do
        Parsegres.parse("CREATE SEQUENCE seq OWNED BY NONE").as(CREATE_SEQUENCE)
          .options
          .owned_by
          .should eq "NONE"
      end

      it "parses CREATE SEQUENCE with multiple options" do
        opts = Parsegres.parse(<<-SQL).as(CREATE_SEQUENCE).options
          CREATE SEQUENCE order_id_seq
            INCREMENT BY 1
            MINVALUE 1
            MAXVALUE 9223372036854775807
            START WITH 1
            CACHE 1
            NO CYCLE
        SQL

        opts.increment.should eq 1
        opts.min_value.should eq 1
        opts.start.should eq 1
        opts.cache.should eq 1
        opts.cycle.should be_false
      end

      it "parses CREATE SEQUENCE with a schema-qualified name" do
        stmt = Parsegres.parse("CREATE SEQUENCE public.seq").as(CREATE_SEQUENCE)

        stmt.schema.should eq "public"
        stmt.name.should eq "seq"
      end
    end

    describe "ALTER SEQUENCE statements" do
      it "parses ALTER SEQUENCE with INCREMENT BY" do
        stmt = Parsegres.parse("ALTER SEQUENCE seq INCREMENT BY 2").as(ALTER_SEQUENCE)

        stmt.name.should eq "seq"
        stmt.if_exists?.should be_false
        stmt.options.increment.should eq 2
      end

      it "parses ALTER SEQUENCE IF EXISTS" do
        stmt = Parsegres.parse("ALTER SEQUENCE IF EXISTS seq CYCLE").as(ALTER_SEQUENCE)

        stmt.if_exists?.should be_true
        stmt.options.cycle.should be_true
      end

      it "parses ALTER SEQUENCE RESTART WITH" do
        stmt = Parsegres.parse("ALTER SEQUENCE seq RESTART WITH 1").as(ALTER_SEQUENCE)

        stmt.options.restart.should eq 1
        stmt.options.restart_default?.should be_false
      end

      it "parses ALTER SEQUENCE RESTART (no value)" do
        stmt = Parsegres.parse("ALTER SEQUENCE seq RESTART").as(ALTER_SEQUENCE)

        stmt.options.restart_default?.should be_true
        stmt.options.restart.should be_nil
      end

      it "parses ALTER SEQUENCE NO CYCLE" do
        Parsegres.parse("ALTER SEQUENCE seq NO CYCLE").as(ALTER_SEQUENCE)
          .options
          .cycle
          .should be_false
      end

      it "parses ALTER SEQUENCE with a schema-qualified name" do
        stmt = Parsegres.parse("ALTER SEQUENCE public.seq INCREMENT BY 1").as(ALTER_SEQUENCE)

        stmt.schema.should eq "public"
        stmt.name.should eq "seq"
      end
    end

    describe "DROP SEQUENCE statements" do
      it "parses a simple DROP SEQUENCE" do
        stmt = Parsegres.parse("DROP SEQUENCE seq").as(DROP_SEQUENCE)

        stmt.targets.size.should eq 1
        stmt.targets[0].name.should eq "seq"
        stmt.targets[0].schema.should be_nil
        stmt.if_exists?.should be_false
        stmt.behavior.should be_nil
      end

      it "parses DROP SEQUENCE IF EXISTS" do
        Parsegres.parse("DROP SEQUENCE IF EXISTS seq").as(DROP_SEQUENCE)
          .if_exists?
          .should be_true
      end

      it "parses DROP SEQUENCE CASCADE" do
        Parsegres.parse("DROP SEQUENCE seq CASCADE").as(DROP_SEQUENCE)
          .behavior.not_nil!
          .cascade?
          .should be_true
      end

      it "parses DROP SEQUENCE with multiple sequences" do
        stmt = Parsegres.parse("DROP SEQUENCE a, b, c").as(DROP_SEQUENCE)

        stmt.targets.size.should eq 3
        stmt.targets.map(&.name).should eq %w[a b c]
      end

      it "parses DROP SEQUENCE with a schema-qualified name" do
        stmt = Parsegres.parse("DROP SEQUENCE public.seq").as(DROP_SEQUENCE)

        stmt.targets[0].schema.should eq "public"
        stmt.targets[0].name.should eq "seq"
      end
    end

    describe "CREATE SCHEMA statements" do
      it "parses a simple CREATE SCHEMA" do
        stmt = Parsegres.parse("CREATE SCHEMA myschema").as(CREATE_SCHEMA)

        stmt.name.should eq "myschema"
        stmt.authorization.should be_nil
        stmt.if_not_exists?.should be_false
      end

      it "parses CREATE SCHEMA IF NOT EXISTS" do
        stmt = Parsegres.parse("CREATE SCHEMA IF NOT EXISTS myschema").as(CREATE_SCHEMA)

        stmt.if_not_exists?.should be_true
        stmt.name.should eq "myschema"
      end

      it "parses CREATE SCHEMA AUTHORIZATION" do
        stmt = Parsegres.parse("CREATE SCHEMA AUTHORIZATION alice").as(CREATE_SCHEMA)

        stmt.name.should be_nil
        stmt.authorization.should eq "alice"
      end

      it "parses CREATE SCHEMA with name and AUTHORIZATION" do
        stmt = Parsegres.parse("CREATE SCHEMA myschema AUTHORIZATION alice").as(CREATE_SCHEMA)

        stmt.name.should eq "myschema"
        stmt.authorization.should eq "alice"
      end
    end

    describe "DROP SCHEMA statements" do
      it "parses a simple DROP SCHEMA" do
        stmt = Parsegres.parse("DROP SCHEMA myschema").as(DROP_SCHEMA)

        stmt.targets.should eq %w[myschema]
        stmt.if_exists?.should be_false
        stmt.behavior.should be_nil
      end

      it "parses DROP SCHEMA IF EXISTS" do
        Parsegres.parse("DROP SCHEMA IF EXISTS myschema").as(DROP_SCHEMA)
          .if_exists?
          .should be_true
      end

      it "parses DROP SCHEMA CASCADE" do
        Parsegres.parse("DROP SCHEMA myschema CASCADE").as(DROP_SCHEMA)
          .behavior.not_nil!
          .cascade?
          .should be_true
      end

      it "parses DROP SCHEMA RESTRICT" do
        Parsegres.parse("DROP SCHEMA myschema RESTRICT").as(DROP_SCHEMA)
          .behavior.not_nil!
          .restrict?
          .should be_true
      end

      it "parses DROP SCHEMA with multiple schemas" do
        Parsegres.parse("DROP SCHEMA a, b").as(DROP_SCHEMA)
          .targets
          .should eq %w[a b]
      end
    end

    describe "CREATE EXTENSION statements" do
      it "parses CREATE EXTENSION" do
        stmt = Parsegres.parse("CREATE EXTENSION btree_gist").as(CREATE_EXTENSION)

        stmt.name.should eq "btree_gist"
        stmt.if_not_exists?.should be_false
      end

      it "parses CREATE EXTENSION IF NOT EXISTS" do
        stmt = Parsegres.parse("CREATE EXTENSION IF NOT EXISTS btree_gist").as(CREATE_EXTENSION)

        stmt.name.should eq "btree_gist"
        stmt.if_not_exists?.should be_true
      end
    end

    describe "DROP EXTENSION statements" do
      it "parses a simple DROP EXTENSION" do
        stmt = Parsegres.parse("DROP EXTENSION btree_gist").as(DROP_EXTENSION)

        stmt.targets.should eq ["btree_gist"]
        stmt.if_exists?.should be_false
        stmt.behavior.should be_nil
      end

      it "parses DROP EXTENSION IF EXISTS" do
        Parsegres.parse("DROP EXTENSION IF EXISTS btree_gist").as(DROP_EXTENSION)
          .if_exists?
          .should be_true
      end

      it "parses DROP EXTENSION CASCADE" do
        Parsegres.parse("DROP EXTENSION btree_gist CASCADE").as(DROP_EXTENSION)
          .behavior.not_nil!
          .cascade?
          .should be_true
      end

      it "parses DROP EXTENSION RESTRICT" do
        Parsegres.parse("DROP EXTENSION btree_gist RESTRICT").as(DROP_EXTENSION)
          .behavior.not_nil!
          .restrict?
          .should be_true
      end

      it "parses DROP EXTENSION with multiple extensions" do
        Parsegres.parse("DROP EXTENSION btree_gist, postgis").as(DROP_EXTENSION)
          .targets
          .should eq ["btree_gist", "postgis"]
      end
    end

    describe "DROP TYPE statements" do
      it "parses a simple DROP TYPE" do
        stmt = Parsegres.parse("DROP TYPE timerange").as(DROP_TYPE)

        stmt.targets.size.should eq 1
        stmt.targets[0].name.should eq "timerange"
        stmt.targets[0].schema.should be_nil
        stmt.if_exists?.should be_false
        stmt.behavior.should be_nil
      end

      it "parses DROP TYPE IF EXISTS" do
        Parsegres.parse("DROP TYPE IF EXISTS timerange").as(DROP_TYPE)
          .if_exists?
          .should be_true
      end

      it "parses DROP TYPE CASCADE" do
        Parsegres.parse("DROP TYPE timerange CASCADE").as(DROP_TYPE)
          .behavior.not_nil!
          .cascade?
          .should be_true
      end

      it "parses DROP TYPE RESTRICT" do
        Parsegres.parse("DROP TYPE timerange RESTRICT").as(DROP_TYPE)
          .behavior.not_nil!
          .restrict?
          .should be_true
      end

      it "parses DROP TYPE with multiple types" do
        stmt = Parsegres.parse("DROP TYPE timerange, daterange").as(DROP_TYPE)

        stmt.targets.size.should eq 2
        stmt.targets.map(&.name).should eq %w[timerange daterange]
      end

      it "parses DROP TYPE with a schema-qualified name" do
        stmt = Parsegres.parse("DROP TYPE public.timerange").as(DROP_TYPE)

        stmt.targets[0].schema.should eq "public"
        stmt.targets[0].name.should eq "timerange"
      end
    end

    describe "CREATE TYPE ... AS RANGE statements" do
      it "parses CREATE TYPE name AS RANGE with SUBTYPE" do
        stmt = Parsegres.parse(<<-SQL).as(CREATE_RANGE_TYPE)
          CREATE TYPE timerange AS RANGE(
            SUBTYPE = time
          )
        SQL

        stmt.name.should eq "timerange"
        stmt.schema.should be_nil
        stmt.subtype.should eq "time"
      end

      it "parses a schema-qualified CREATE TYPE" do
        stmt = Parsegres.parse("CREATE TYPE public.timerange AS RANGE(SUBTYPE = time)").as(CREATE_RANGE_TYPE)

        stmt.schema.should eq "public"
        stmt.name.should eq "timerange"
      end
    end

    describe "transaction control statements" do
      it "parses BEGIN" do
        Parsegres.parse("BEGIN").should be_a(Parsegres::AST::BeginStatement)
      end

      it "parses BEGIN WORK" do
        Parsegres.parse("BEGIN WORK").should be_a(Parsegres::AST::BeginStatement)
      end

      it "parses BEGIN TRANSACTION" do
        Parsegres.parse("BEGIN TRANSACTION").should be_a(Parsegres::AST::BeginStatement)
      end

      it "parses COMMIT" do
        Parsegres.parse("COMMIT").should be_a(Parsegres::AST::CommitStatement)
      end

      it "parses COMMIT WORK" do
        Parsegres.parse("COMMIT WORK").should be_a(Parsegres::AST::CommitStatement)
      end

      it "parses COMMIT TRANSACTION" do
        Parsegres.parse("COMMIT TRANSACTION").should be_a(Parsegres::AST::CommitStatement)
      end

      it "parses ROLLBACK" do
        Parsegres.parse("ROLLBACK").should be_a(Parsegres::AST::RollbackStatement)
      end

      it "parses ROLLBACK WORK" do
        Parsegres.parse("ROLLBACK WORK").should be_a(Parsegres::AST::RollbackStatement)
      end

      it "parses ROLLBACK TRANSACTION" do
        Parsegres.parse("ROLLBACK TRANSACTION").should be_a(Parsegres::AST::RollbackStatement)
      end

      it "parses SAVEPOINT" do
        stmt = Parsegres.parse("SAVEPOINT my_sp").as(Parsegres::AST::SavepointStatement)
        stmt.name.should eq "my_sp"
      end

      it "parses RELEASE SAVEPOINT" do
        stmt = Parsegres.parse("RELEASE SAVEPOINT my_sp").as(Parsegres::AST::ReleaseSavepointStatement)
        stmt.name.should eq "my_sp"
      end

      it "parses RELEASE without the SAVEPOINT keyword" do
        stmt = Parsegres.parse("RELEASE my_sp").as(Parsegres::AST::ReleaseSavepointStatement)
        stmt.name.should eq "my_sp"
      end

      it "parses ROLLBACK TO SAVEPOINT" do
        stmt = Parsegres.parse("ROLLBACK TO SAVEPOINT my_sp").as(Parsegres::AST::RollbackToSavepointStatement)
        stmt.name.should eq "my_sp"
      end

      it "parses ROLLBACK TO without the SAVEPOINT keyword" do
        stmt = Parsegres.parse("ROLLBACK TO my_sp").as(Parsegres::AST::RollbackToSavepointStatement)
        stmt.name.should eq "my_sp"
      end
    end

    describe "DISTINCT ON" do
      it "parses SELECT DISTINCT ON (...)" do
        stmt = Parsegres.parse("SELECT DISTINCT ON (id, name) id, name FROM t").as(SELECT)
        stmt.distinct?.should be_true
        stmt.distinct_on.not_nil!.size.should eq 2
        stmt.distinct_on.not_nil![0].as(Parsegres::AST::ColumnRef).column.should eq "id"
        stmt.distinct_on.not_nil![1].as(Parsegres::AST::ColumnRef).column.should eq "name"
        stmt.columns.size.should eq 2
        stmt.columns[0].expr.as(Parsegres::AST::ColumnRef).column.should eq "id"
        stmt.columns[1].expr.as(Parsegres::AST::ColumnRef).column.should eq "name"
      end
    end

    describe "function with subquery argument" do
      it "parses ARRAY(SELECT ...)" do
        stmt = Parsegres.parse("SELECT ARRAY(SELECT id FROM t) FROM t2").as(SELECT)
        func = stmt.columns[0].expr.as(Parsegres::AST::FunctionCall)
        func.name.should eq "ARRAY"
        func.args[0].should be_a(Parsegres::AST::SubqueryExpr)
      end

      it "parses ARRAY(SELECT ... INTERSECT SELECT ...)" do
        stmt = Parsegres.parse("SELECT ARRAY(SELECT a FROM t INTERSECT SELECT b FROM t2) FROM t3").as(SELECT)
        func = stmt.columns[0].expr.as(Parsegres::AST::FunctionCall)
        func.args[0].should be_a(Parsegres::AST::SubqueryExpr)
      end
    end

    describe "parenthesized compound SELECT" do
      it "parses (SELECT ...) UNION (SELECT ...) in a subquery" do
        stmt = Parsegres.parse(<<-SQL).as(SELECT)
          SELECT x FROM ((SELECT 1 AS x) UNION (SELECT 2 AS x)) AS t
        SQL

        ref = stmt.from[0].as(Parsegres::AST::SubqueryRef)
        ref.alias_name.should eq "t"
        compound = ref.query.as(CompoundSelect)
        compound.op.union?.should be_true
      end

      it "parses a bare (SELECT ...) as a from-subquery" do
        stmt = Parsegres.parse("SELECT x FROM (SELECT 1 AS x) AS t").as(SELECT)
        stmt.from[0].as(Parsegres::AST::SubqueryRef).alias_name.should eq "t"
      end
    end

    describe "subqueries" do
      it "parses a scalar subquery" do
        Parsegres.parse("SELECT (SELECT count(*) FROM orders WHERE user_id = u.id) FROM users u").as(SELECT)
          .columns[0]
          .expr.as(Parsegres::AST::SubqueryExpr)
          .query.as(SELECT)
          .from[0].as(Parsegres::AST::TableRef)
          .name
          .should eq "orders"
      end

      it "parses a complex INSERT ... SELECT with JSON operators, subscripts, and table functions" do
        stmt = Parsegres.parse(<<-SQL).as(INSERT)
          INSERT INTO conversations (id, participants, subject, message_count, last_message_at)
          SELECT
            conversation_id,
            (
              SELECT array_agg(DISTINCT id)
              FROM unnest(
                array_agg(DISTINCT sender_id) ||
                array_agg(DISTINCT recipient_id)
              ) AS id
            ) as participants,
            coalesce(
              (
                SELECT array_agg(DISTINCT subject) AS subject
                FROM unnest(array_agg(headers#>>'{subject,0}')) AS subject
                ORDER BY subject
              )[1],
              ''
            ) AS subject,
            count(conversation_id) AS message_count,
            max(sent_at) AS last_message_at
          FROM messages
          GROUP BY conversation_id
        SQL

        stmt.table.should eq "conversations"
        stmt.columns.should eq ["id", "participants", "subject", "message_count", "last_message_at"]
        select_stmt = stmt.source.as(SelectSource).query.as(SELECT)
        select_stmt.columns.size.should eq 5
        select_stmt.from[0].as(Parsegres::AST::TableRef).name.should eq "messages"
      end

      it "parses IN (subquery)" do
        Parsegres.parse("SELECT 1 FROM t WHERE id IN (SELECT id FROM active_users)").as(SELECT)
          .where.as(Parsegres::AST::InSubqueryExpr)
          .subquery.as(SELECT)
          .from[0].as(Parsegres::AST::TableRef)
          .name
          .should eq "active_users"
      end
    end

    describe "window functions" do
      it "parses func() OVER (PARTITION BY ... ORDER BY ...)" do
        func = Parsegres.parse("SELECT row_number() OVER (PARTITION BY dept ORDER BY salary DESC) FROM t").as(SELECT)
          .columns[0].expr.as(Parsegres::AST::FunctionCall)
        func.name.should eq "row_number"
        over = func.over.not_nil!
        over.partition_by.size.should eq 1
        over.partition_by[0].as(Parsegres::AST::ColumnRef).column.should eq "dept"
        over.order_by.size.should eq 1
        over.order_by[0].direction.not_nil!.desc?.should be_true
      end

      it "parses func() OVER (ORDER BY ...)" do
        func = Parsegres.parse("SELECT rank() OVER (ORDER BY score) FROM t").as(SELECT)
          .columns[0].expr.as(Parsegres::AST::FunctionCall)
        func.name.should eq "rank"
        func.over.not_nil!.partition_by.should be_empty
        func.over.not_nil!.order_by.size.should eq 1
      end

      it "parses func() OVER () with no spec" do
        func = Parsegres.parse("SELECT count(*) OVER () FROM t").as(SELECT)
          .columns[0].expr.as(Parsegres::AST::FunctionCall)
        func.name.should eq "count"
        func.over.should_not be_nil
      end

      it "parses window function with ROWS BETWEEN frame" do
        func = Parsegres.parse("SELECT sum(x) OVER (ORDER BY d ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM t").as(SELECT)
          .columns[0].expr.as(Parsegres::AST::FunctionCall)
        func.name.should eq "sum"
        func.over.not_nil!.order_by.size.should eq 1
      end

      it "parses PARTITION BY with multiple columns and NULLS FIRST" do
        over = Parsegres.parse("SELECT row_number() OVER (PARTITION BY a, b ORDER BY c ASC NULLS FIRST) FROM t").as(SELECT)
          .columns[0].expr.as(Parsegres::AST::FunctionCall)
          .over.not_nil!

        over.partition_by.size.should eq 2
        over.order_by[0].nulls_order.not_nil!.first?.should be_true
      end
    end

    describe "typed string literals" do
      it "parses interval 'N days'" do
        expr = Parsegres.parse("SELECT NOW() - interval '45 days' FROM t").as(SELECT)
          .columns[0].expr.as(Parsegres::AST::BinaryExpr)
        cast = expr.right.as(Parsegres::AST::CastExpr)

        expr.op.should eq "-"
        cast.type_name.should eq "interval"
        cast.expr.as(Parsegres::AST::StringLiteral).value.should eq "45 days"
      end

      it "parses date 'YYYY-MM-DD'" do
        cast = Parsegres.parse("SELECT date '2023-01-01' FROM t").as(SELECT)
          .columns[0].expr.as(Parsegres::AST::CastExpr)

        cast.type_name.should eq "date"
        cast.expr.as(Parsegres::AST::StringLiteral).value.should eq "2023-01-01"
      end
    end

    describe "CTE materialization hints" do
      it "parses WITH name AS NOT MATERIALIZED (...)" do
        cte = Parsegres.parse("WITH t AS NOT MATERIALIZED (SELECT 1) SELECT * FROM t").as(SELECT)
          .ctes[0]

        cte.name.should eq "t"
        cte.materialized.should be_false
      end

      it "parses WITH name AS MATERIALIZED (...)" do
        Parsegres.parse("WITH t AS MATERIALIZED (SELECT 1) SELECT * FROM t").as(SELECT)
          .ctes[0]
          .materialized
          .should be_true
      end

      it "leaves materialized nil when not specified" do
        Parsegres.parse("WITH t AS (SELECT 1) SELECT * FROM t").as(SELECT)
          .ctes[0]
          .materialized
          .should be_nil
      end
    end

    describe "CREATE RULE" do
      it "parses CREATE OR REPLACE RULE ... DO INSTEAD ()" do
        stmt = Parsegres.parse(<<-SQL).as(Parsegres::AST::CreateRuleStatement)
          CREATE OR REPLACE RULE my_rule AS
          ON DELETE TO my_table
          DO INSTEAD ()
        SQL

        stmt.name.should eq "my_rule"
        stmt.or_replace?.should be_true
        stmt.table.should eq "my_table"
      end

      it "parses CREATE RULE ... DO INSTEAD NOTHING" do
        stmt = Parsegres.parse(<<-SQL).as(Parsegres::AST::CreateRuleStatement)
          CREATE RULE my_rule AS
          ON INSERT TO my_table
          DO INSTEAD NOTHING
        SQL

        stmt.name.should eq "my_rule"
        stmt.or_replace?.should be_false
      end
    end
  end
end
