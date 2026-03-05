require "./ast"
require "./error"

module Parsegres
  # Serializes an AST node back to a SQL string.
  # The output uses normalized formatting: uppercase keywords, single spaces.
  # It round-trips the logical structure of the query, which makes it
  # useful for query fingerprinting (e.g. replace literals with $N placeholders).
  #
  # Usage:
  #   ast = Parsegres.parse(sql)
  #   ast.to_sql   # => "SELECT ..."
  #
  #   # Or directly:
  #   Parsegres::Printer.print(ast)
  struct Printer
    def self.print(node : AST::Node) : String
      String.build { |io| new(io).emit(node) }
    end

    def initialize(@io : IO)
    end

    # If an AST node isn't yet supported by this statement printer, it falls
    # into this method which will raise an `UnsupportedNodeType` exception.
    def emit(node : AST::Node) : Nil
      raise UnsupportedNodeType.new(<<-EOF)
        Node type not yet supported for Parsegres::Printer

        #{node.pretty_inspect}

        Please report an issue: https://github.com/jgaskins/parsegres/issues
        EOF
    end

    # TCL statements

    def emit(stmt : AST::BeginStatement) : Nil
      @io << "BEGIN"
    end

    def emit(stmt : AST::CommitStatement) : Nil
      @io << "COMMIT"
    end

    def emit(stmt : AST::RollbackStatement) : Nil
      @io << "ROLLBACK"
    end

    def emit(stmt : AST::SavepointStatement) : Nil
      @io << "SAVEPOINT "
      emit_identifier stmt.name
    end

    def emit(stmt : AST::ReleaseSavepointStatement) : Nil
      @io << "RELEASE SAVEPOINT "
      emit_identifier stmt.name
    end

    def emit(stmt : AST::RollbackToSavepointStatement) : Nil
      @io << "ROLLBACK TO SAVEPOINT "
      emit_identifier stmt.name
    end

    # Statements -----------------------------------------------------------

    def emit(stmt : AST::SelectStatement) : Nil
      emit_ctes(stmt.ctes, stmt.recursive?) unless stmt.ctes.empty?
      @io << "SELECT"
      if stmt.distinct?
        @io << " DISTINCT"
        if on = stmt.distinct_on
          @io << " ON ("
          on.each_with_index do |expr, i|
            @io << ", " if i > 0
            emit expr
          end
          @io << ")"
        end
      end

      @io << " "
      stmt.columns.each_with_index do |column, i|
        @io << ", " if i > 0
        emit_select_column column
      end

      unless stmt.from.empty?
        @io << " FROM "
        stmt.from.each_with_index do |from_item, i|
          @io << ", " if i > 0
          emit_from_item from_item
        end
      end

      if where = stmt.where
        @io << " WHERE "
        emit where
      end

      unless stmt.group_by.empty?
        @io << " GROUP BY "
        stmt.group_by.each_with_index do |expr, i|
          @io << ", " if i > 0
          emit expr
        end
      end

      if having = stmt.having
        @io << " HAVING "
        emit having
      end

      emit_order_offset_limit stmt.order_by, stmt.offset, stmt.limit
    end

    def emit(stmt : AST::CompoundSelect) : Nil
      emit_ctes stmt.ctes, stmt.recursive? unless stmt.ctes.empty?
      emit_compound_operand stmt.left, stmt.op
      @io << " " << compound_op_keyword(stmt.op) << " "
      emit_compound_operand stmt.right, stmt.op
      emit_order_offset_limit stmt.order_by, stmt.offset, stmt.limit
    end

    private def emit_compound_operand(stmt : AST::Statement, parent_op : AST::CompoundSelect::Op) : Nil
      # Wrap a nested compound in parens only when its operator has lower
      # precedence than the parent (UNION/EXCEPT inside INTERSECT).
      if stmt.is_a?(AST::CompoundSelect) && compound_op_precedence(stmt.op) < compound_op_precedence(parent_op)
        @io << "("
        emit stmt
        @io << ")"
      else
        emit stmt
      end
    end

    private def compound_op_precedence(op : AST::CompoundSelect::Op) : Int32
      op.intersect? || op.intersect_all? ? 2 : 1
    end

    private def compound_op_keyword(op : AST::CompoundSelect::Op) : String
      case op
      in .union?         then "UNION"
      in .union_all?     then "UNION ALL"
      in .intersect?     then "INTERSECT"
      in .intersect_all? then "INTERSECT ALL"
      in .except?        then "EXCEPT"
      in .except_all?    then "EXCEPT ALL"
      end
    end

    def emit(stmt : AST::InsertStatement) : Nil
      emit_ctes stmt.ctes, stmt.recursive? unless stmt.ctes.empty?
      @io << "INSERT INTO "
      emit_schema stmt.schema
      emit_identifier stmt.table
      if columns = stmt.columns
        @io << " ("
        columns.each_with_index do |column, i|
          @io << ", " if i > 0
          emit_identifier column
        end
        @io << ")"
      end

      @io << " "
      emit_insert_source stmt.source
      emit_returning stmt.returning
    end

    private def emit_insert_source(src : AST::ValuesSource) : Nil
      @io << "VALUES "
      src.rows.each_with_index do |row, row_index|
        @io << ", " if row_index > 0
        @io << "("
        row.each_with_index do |element, index|
          @io << ", " if index > 0
          emit element
        end
        @io << ")"
      end
    end

    private def emit_insert_source(src : AST::SelectSource) : Nil
      emit src.query
    end

    private def emit_insert_source(src : AST::DefaultValuesSource) : Nil
      @io << "DEFAULT VALUES"
    end

    def emit(stmt : AST::UpdateStatement) : Nil
      emit_ctes(stmt.ctes, stmt.recursive?) unless stmt.ctes.empty?
      @io << "UPDATE"
      @io << " ONLY" if stmt.only?
      @io << " "
      emit_schema stmt.schema
      emit_identifier stmt.table
      if alias_name = stmt.alias_name
        @io << " AS "
        emit_identifier alias_name
      end

      @io << " SET "
      stmt.assignments.each_with_index do |assignment, i|
        @io << ", " if i > 0
        emit_identifier assignment.column
        @io << " = "
        emit assignment.value
      end

      unless stmt.from.empty?
        @io << " FROM "
        stmt.from.each_with_index do |from_item, i|
          @io << ", " if i > 0
          emit_from_item from_item
        end
      end

      if where = stmt.where
        @io << " WHERE "
        emit where
      end

      emit_returning stmt.returning
    end

    def emit(stmt : AST::DeleteStatement) : Nil
      emit_ctes(stmt.ctes, stmt.recursive?) unless stmt.ctes.empty?
      @io << "DELETE FROM"
      @io << " ONLY" if stmt.only?
      @io << " "

      emit_schema stmt.schema
      emit_identifier stmt.table

      if alias_name = stmt.alias_name
        @io << " AS "
        emit_identifier alias_name
      end

      unless stmt.using.empty?
        @io << " USING "
        stmt.using.each_with_index do |from_item, i|
          @io << ", " if i > 0
          emit_from_item from_item
        end
      end

      if where = stmt.where
        @io << " WHERE "
        emit where
      end

      emit_returning stmt.returning
    end

    private def emit_returning(columns : Array(AST::SelectColumn)) : Nil
      return if columns.empty?
      @io << " RETURNING "
      columns.each_with_index do |column, i|
        @io << ", " if i > 0
        emit_select_column column
      end
    end

    # DDL ------------------------------------------------------------------

    def emit(stmt : AST::CreateTableStatement) : Nil
      @io << "CREATE"
      @io << " TEMPORARY" if stmt.temporary?
      @io << " TABLE"
      @io << " IF NOT EXISTS" if stmt.if_not_exists?
      @io << " "

      emit_schema stmt.schema
      emit_identifier stmt.name

      @io << " ("
      first = true
      stmt.columns.each do |column|
        @io << ", " unless first
        first = false
        emit_column_def column
      end
      stmt.constraints.each do |constraint|
        @io << ", " unless first
        first = false
        emit_table_constraint constraint
      end
      @io << ")"
    end

    private def emit_column_def(column : AST::ColumnDef) : Nil
      emit_identifier column.name
      @io << " " << column.type_name
      column.constraints.each do |constraint|
        @io << " "
        emit_column_constraint constraint
      end
    end

    private def emit_column_constraint(constraint : AST::ColumnConstraint) : Nil
      if name = constraint.constraint_name
        @io << "CONSTRAINT "
        emit_identifier name
        @io << " "
      end
      case constraint
      when AST::NotNullConstraint          then @io << "NOT NULL"
      when AST::NullConstraint             then @io << "NULL"
      when AST::PrimaryKeyColumnConstraint then @io << "PRIMARY KEY"
      when AST::UniqueColumnConstraint     then @io << "UNIQUE"
      when AST::DefaultConstraint
        @io << "DEFAULT "
        emit(constraint.expr)
      when AST::CheckColumnConstraint
        @io << "CHECK ("
        emit(constraint.expr)
        @io << ")"
      when AST::ReferencesConstraint
        @io << "REFERENCES "
        emit_schema constraint.ref_schema
        emit_identifier constraint.ref_table
        if column = constraint.ref_column
          @io << " (" << column << ")"
        end
      end
    end

    private def emit_table_constraint(constraint : AST::TableConstraint) : Nil
      if name = constraint.constraint_name
        @io << "CONSTRAINT " <<
          emit_identifier name
        @io << " "
      end
      case constraint
      when AST::PrimaryKeyTableConstraint
        @io << "PRIMARY KEY ("
        constraint.columns.each_with_index do |column, i|
          @io << ", " if i > 0
          emit_identifier column
        end
        @io << ")"
      when AST::UniqueTableConstraint
        @io << "UNIQUE ("
        constraint.columns.each_with_index do |column, i|
          @io << ", " if i > 0
          emit_identifier column
        end
        @io << ")"
      when AST::CheckTableConstraint
        @io << "CHECK ("
        emit constraint.expr
        @io << ")"
      when AST::ForeignKeyTableConstraint
        @io << "FOREIGN KEY ("
        constraint.columns.each_with_index do |column, i|
          @io << ", " if i > 0
          emit_identifier column
        end
        @io << ") REFERENCES "
        emit_schema constraint.ref_schema
        emit_identifier constraint.ref_table
        if columns = constraint.ref_columns
          @io << " ("
          columns.each_with_index do |column, i|
            @io << ", " if i > 0
            emit_identifier column
          end
          @io << ")"
        end
      when AST::ExcludeTableConstraint
        @io << "EXCLUDE"
        if using = constraint.using
          @io << " USING "
          emit_identifier using
        end
        @io << " ("
        constraint.elements.each_with_index do |element, i|
          @io << ", " if i > 0
          emit_identifier element.column
          @io << " WITH " << element.operator
        end
        @io << ")"
      end
    end

    def emit(stmt : AST::DropTableStatement) : Nil
      @io << "DROP TABLE"
      @io << " IF EXISTS" if stmt.if_exists?
      stmt.targets.each_with_index do |target, i|
        @io << (i == 0 ? " " : ", ")
        emit_schema target.schema
        emit_identifier target.name
      end
      emit_drop_behavior stmt.behavior
    end

    def emit(stmt : AST::AlterTableStatement) : Nil
      @io << "ALTER TABLE"
      @io << " IF EXISTS" if stmt.if_exists?
      @io << " ONLY" if stmt.only?
      @io << " "
      emit_schema stmt.schema
      emit_identifier stmt.name
      stmt.actions.each_with_index do |action, i|
        @io << (i == 0 ? " " : ", ")
        emit_alter_table_action action
      end
    end

    private def emit_alter_table_action(action : AST::AddColumnAction) : Nil
      @io << "ADD"
      @io << " IF NOT EXISTS" if action.if_not_exists?
      @io << " COLUMN "
      emit_column_def action.column
    end

    private def emit_alter_table_action(action : AST::DropColumnAction) : Nil
      @io << "DROP COLUMN"
      @io << " IF EXISTS" if action.if_exists?
      @io << " " << action.column
      emit_drop_behavior action.behavior
    end

    private def emit_alter_table_action(action : AST::AlterColumnTypeAction) : Nil
      @io << "ALTER COLUMN " << action.column << " TYPE " << action.type_name
    end

    private def emit_alter_table_action(action : AST::AlterColumnSetDefaultAction) : Nil
      @io << "ALTER COLUMN "
      emit_identifier action.column
      @io << " SET DEFAULT "
      emit action.expr
    end

    private def emit_alter_table_action(action : AST::AlterColumnDropDefaultAction) : Nil
      @io << "ALTER COLUMN "
      emit_identifier action.column
      @io << " DROP DEFAULT"
    end

    private def emit_alter_table_action(action : AST::AlterColumnSetNotNullAction) : Nil
      @io << "ALTER COLUMN "
      emit_identifier action.column
      @io << " SET NOT NULL"
    end

    private def emit_alter_table_action(action : AST::AlterColumnDropNotNullAction) : Nil
      @io << "ALTER COLUMN "
      emit_identifier action.column
      @io << " DROP NOT NULL"
    end

    private def emit_alter_table_action(action : AST::RenameColumnAction) : Nil
      @io << "RENAME COLUMN "
      emit_identifier action.old_name
      @io << " TO " << action.new_name
    end

    private def emit_alter_table_action(action : AST::RenameTableAction) : Nil
      @io << "RENAME TO "
      emit_identifier action.new_name
    end

    private def emit_alter_table_action(action : AST::AddConstraintAction) : Nil
      @io << "ADD "
      emit_table_constraint action.constraint
    end

    private def emit_alter_table_action(action : AST::DropConstraintAction) : Nil
      @io << "DROP CONSTRAINT"
      @io << " IF EXISTS" if action.if_exists?
      @io << " "
      emit_identifier action.name
      emit_drop_behavior action.behavior
    end

    def emit(stmt : AST::CreateIndexStatement) : Nil
      @io << "CREATE"
      @io << " UNIQUE" if stmt.unique?
      @io << " INDEX"
      @io << " CONCURRENTLY" if stmt.concurrently?
      @io << " IF NOT EXISTS" if stmt.if_not_exists?
      if name = stmt.index_name
        @io << " "
        emit_identifier name
      end
      @io << " ON"
      @io << " ONLY" if stmt.only?
      @io << " "
      emit_schema stmt.table_schema
      emit_identifier stmt.table_name
      if using = stmt.using
        @io << " USING "
        emit_identifier using
      end
      @io << " ("
      stmt.columns.each_with_index do |element, i|
        @io << ", " if i > 0
        if expr = element.expr
          emit expr
        else
          emit_identifier element.column
        end
        if direction = element.direction
          @io << ' '
          @io << direction
        end
        if nulls_order = element.nulls_order
          @io << " NULLS "
          @io << nulls_order
        end
      end
      @io << ")"
      if where = stmt.where
        @io << " WHERE "
        emit where
      end
    end

    def emit(stmt : AST::DropIndexStatement) : Nil
      @io << "DROP INDEX"
      @io << " CONCURRENTLY" if stmt.concurrently?
      @io << " IF EXISTS" if stmt.if_exists?
      stmt.targets.each_with_index do |target, i|
        @io << (i == 0 ? " " : ", ")
        emit_schema target.schema
        emit_identifier target.name
      end
      emit_drop_behavior stmt.behavior
    end

    def emit(stmt : AST::CreateViewStatement) : Nil
      @io << "CREATE"
      @io << " OR REPLACE" if stmt.or_replace?
      @io << " TEMPORARY" if stmt.temporary?
      @io << " VIEW"
      @io << " IF NOT EXISTS" if stmt.if_not_exists?
      @io << " "
      emit_schema stmt.schema
      emit_identifier stmt.name
      if columns = stmt.columns
        @io << " ("
        columns.each_with_index do |column, i|
          @io << ", " if i > 0
          emit_identifier column
        end
        @io << ")"
      end
      @io << " AS "
      emit stmt.query
    end

    def emit(stmt : AST::DropViewStatement) : Nil
      @io << "DROP VIEW"
      @io << " IF EXISTS" if stmt.if_exists?
      stmt.targets.each_with_index do |target, i|
        @io << (i == 0 ? " " : ", ")
        emit_schema target.schema
        emit_identifier target.name
      end
      emit_drop_behavior stmt.behavior
    end

    def emit(stmt : AST::TruncateStatement) : Nil
      @io << "TRUNCATE"
      stmt.targets.each_with_index do |target, i|
        @io << (i == 0 ? " " : ", ")
        @io << "ONLY " if target.only
        emit_schema target.schema
        emit_identifier target.name
      end
      if id = stmt.identity
        @io << (id.restart? ? " RESTART IDENTITY" : " CONTINUE IDENTITY")
      end
      emit_drop_behavior(stmt.behavior)
    end

    def emit(stmt : AST::CreateSequenceStatement) : Nil
      @io << "CREATE"
      @io << " TEMPORARY" if stmt.temporary?
      @io << " SEQUENCE"
      @io << " IF NOT EXISTS" if stmt.if_not_exists?
      @io << " "
      emit_schema stmt.schema
      emit_identifier stmt.name
      emit_sequence_options(stmt.options)
    end

    def emit(stmt : AST::AlterSequenceStatement) : Nil
      @io << "ALTER SEQUENCE"
      @io << " IF EXISTS" if stmt.if_exists?
      @io << " "
      emit_schema stmt.schema
      emit_identifier stmt.name
      emit_sequence_options(stmt.options)
    end

    private def emit_sequence_options(opts : AST::SequenceOptions) : Nil
      if type = opts.type
        @io << " AS " << type
      end

      if increment = opts.increment
        @io << " INCREMENT BY " << increment
      end

      if value = opts.min_value
        @io << " MINVALUE " << value
      elsif opts.no_min_value?
        @io << " NO MINVALUE"
      end

      if value = opts.max_value
        @io << " MAXVALUE " << value
      elsif opts.no_max_value?
        @io << " NO MAXVALUE"
      end

      # `opts.cycle` can be `nil`, which is unspecified (not the same as false)
      case opts.cycle
      when true
        @io << " CYCLE"
      when false
        @io << " NO CYCLE"
      end

      if value = opts.start
        @io << " START WITH " << value
      end

      if value = opts.restart
        @io << " RESTART WITH " << value
      elsif opts.restart_default?
        @io << " RESTART"
      end

      if cache = opts.cache
        @io << " CACHE " << cache
      end

      if owner = opts.owned_by
        @io << " OWNED BY "
        emit_identifier owner
      end
    end

    def emit(stmt : AST::DropSequenceStatement) : Nil
      @io << "DROP SEQUENCE"
      @io << " IF EXISTS" if stmt.if_exists?
      stmt.targets.each_with_index do |target, i|
        @io << (i == 0 ? " " : ", ")
        emit_schema target.schema
        emit_identifier target.name
      end
      emit_drop_behavior(stmt.behavior)
    end

    def emit(stmt : AST::CreateSchemaStatement) : Nil
      @io << "CREATE SCHEMA"
      @io << " IF NOT EXISTS" if stmt.if_not_exists?
      if name = stmt.name
        @io << " "
        emit_identifier name
      end
      if authorization = stmt.authorization
        @io << " AUTHORIZATION "
        emit_identifier authorization
      end
    end

    def emit(stmt : AST::DropSchemaStatement) : Nil
      @io << "DROP SCHEMA"
      @io << " IF EXISTS" if stmt.if_exists?
      stmt.targets.each_with_index do |target, i|
        @io << (i == 0 ? " " : ", ")
        emit_identifier target
      end
      emit_drop_behavior stmt.behavior
    end

    def emit(stmt : AST::CreateExtensionStatement) : Nil
      @io << "CREATE EXTENSION"
      @io << " IF NOT EXISTS" if stmt.if_not_exists?
      @io << ' '
      emit_identifier stmt.name
    end

    def emit(stmt : AST::DropExtensionStatement) : Nil
      @io << "DROP EXTENSION"
      @io << " IF EXISTS" if stmt.if_exists?
      stmt.targets.each_with_index do |target, i|
        @io << (i == 0 ? " " : ", ")
        emit_identifier target
      end
      emit_drop_behavior stmt.behavior
    end

    def emit(stmt : AST::CreateRangeTypeStatement) : Nil
      @io << "CREATE TYPE "
      emit_schema stmt.schema
      emit_identifier stmt.name
      @io << " AS RANGE (SUBTYPE = " << stmt.subtype << ")"
    end

    def emit(stmt : AST::DropTypeStatement) : Nil
      @io << "DROP TYPE"
      @io << " IF EXISTS" if stmt.if_exists?
      stmt.targets.each_with_index do |target, i|
        @io << (i == 0 ? " " : ", ")
        emit_schema target.schema
        emit_identifier target.name
      end
      emit_drop_behavior stmt.behavior
    end

    def emit(stmt : AST::DoStatement) : Nil
      @io << "DO "
      if language = stmt.language
        @io << "LANGUAGE " << language << " "
      end
      @io << "$$" << stmt.code << "$$"
    end

    def emit(stmt : AST::CreateRuleStatement) : Nil
      @io << "CREATE"
      @io << " OR REPLACE" if stmt.or_replace?
      @io << " RULE " << stmt.name << " ON "
      emit_schema stmt.table_schema
      emit_identifier stmt.table
    end

    private def emit_drop_behavior(behavior : AST::DropBehavior?) : Nil
      return unless b = behavior
      @io << ' ' << behavior
    end

    # CTEs -----------------------------------------------------------------

    private def emit_ctes(ctes : Array(AST::CTEDefinition), recursive : Bool) : Nil
      @io << "WITH "
      @io << "RECURSIVE " if recursive
      ctes.each_with_index do |cte, i|
        @io << ", " if i > 0
        emit_identifier cte.name
        if columns = cte.columns
          @io << " ("
          columns.each_with_index do |column, ci|
            @io << ", " if ci > 0
            emit_identifier column
          end
          @io << ")"
        end

        @io << " AS "
        case cte.materialized
        in Nil
          # unspecified
        in true
          @io << "MATERIALIZED "
        in false
          @io << "NOT MATERIALIZED "
        end
        @io << "("
        emit cte.query
        @io << ")"
      end
      @io << " "
    end

    # ORDER BY / LIMIT / OFFSET --------------------------------------------

    private def emit_order_offset_limit(
      order_by : Array(AST::OrderByItem),
      offset : AST::Expr?,
      limit : AST::Expr?,
    ) : Nil
      unless order_by.empty?
        @io << " ORDER BY "
        order_by.each_with_index do |item, i|
          @io << ", " if i > 0
          emit item.expr
          @io << ' '
          @io << item.direction
          if item.nulls_order
            @io << " NULLS " << item.nulls_order
          end
        end
      end
      if offset
        @io << " OFFSET "
        emit offset
      end
      if limit
        @io << " LIMIT "
        emit limit
      end
    end

    # SELECT column list ---------------------------------------------------

    private def emit_select_column(col : AST::SelectColumn) : Nil
      emit(col.expr)
      if alias_name = col.alias_name
        @io << " AS "
        emit_identifier alias_name
      end
    end

    # FROM items -----------------------------------------------------------

    private def emit_from_item(table_ref : AST::TableRef) : Nil
      emit_schema table_ref.schema
      emit_identifier table_ref.name
      if alias_name = table_ref.alias_name
        @io << " AS "
        emit_identifier alias_name
      end
    end

    private def emit_from_item(table_function : AST::TableFunctionRef) : Nil
      emit(table_function.func)
      if alias_name = table_function.alias_name
        @io << " AS "
        emit_identifier alias_name
      end
    end

    private def emit_from_item(subquery : AST::SubqueryRef) : Nil
      @io << "("
      emit subquery.query
      @io << ") AS "
      emit_identifier subquery.alias_name
    end

    private def emit_from_item(join : AST::JoinExpr) : Nil
      emit_from_item join.left

      case join.kind
      in .inner? then @io << " JOIN "
      in .left?  then @io << " LEFT JOIN "
      in .right? then @io << " RIGHT JOIN "
      in .full?  then @io << " FULL JOIN "
      in .cross? then @io << " CROSS JOIN "
      end

      # Wrap a nested join on the right side in parens to make associativity
      # explicit (the common case is a simple table ref with no nesting).
      rhs_is_join = join.right.is_a?(AST::JoinExpr)
      @io << "(" if rhs_is_join
      emit_from_item join.right
      @io << ")" if rhs_is_join
      if expr = join.on
        @io << " ON "
        emit expr
      elsif using = join.using
        @io << " USING ("
        using.each_with_index do |column, i|
          @io << ", " if i > 0
          emit_identifier column
        end
        @io << ")"
      end
    end

    # Expressions ----------------------------------------------------------

    # Operator precedence table. Lower number = looser binding.
    # Operators not in the table get precedence 45 (between comparison and concat).
    private def operator_precedence(operator : String) : Int32
      case operator
      when "OR"                                  then 10
      when "AND"                                 then 20
      when "=", "<>", "!=", "<", ">", "<=", ">=" then 40
      when "||"                                  then 50
      when "+", "-"                              then 60
      when "*", "/", "%"                         then 70
      when "^"                                   then 80
      else                                            45
      end
    end

    def emit(expr : AST::Expr, parent_prec : Int32 = 0, right_child : Bool = false) : Nil
      # TODO: Break this up into individual methods
      case expr
      when AST::IntegerLiteral
        @io << expr.value
      when AST::FloatLiteral
        @io << expr.value
      when AST::StringLiteral
        emit_string_literal expr.value
      when AST::BoolLiteral
        @io << (expr.value ? "TRUE" : "FALSE")
      when AST::NullLiteral
        @io << "NULL"
      when AST::DefaultExpr
        @io << "DEFAULT"
      when AST::ParamRef
        @io << "$" << expr.index
      when AST::ColumnRef
        if table = expr.table
          emit_identifier table
          @io << "."
        end
        emit_identifier expr.column
      when AST::Wildcard
        @io << "*"
      when AST::BinaryExpr
        p = operator_precedence(expr.op)
        # Add parens when the child would otherwise bind more loosely:
        # - left child: needs parens if its prec is strictly lower
        # - right child: needs parens if its prec is lower or equal (left-assoc)
        need_parens = p < parent_prec || (right_child && p == parent_prec)
        @io << "(" if need_parens
        emit expr.left, p, right_child: false
        @io << " " << expr.op << " "
        emit expr.right, p, right_child: true
        @io << ")" if need_parens
      when AST::UnaryExpr
        @io << expr.op
        # Keyword operators (NOT) need a space; symbol operators (-, ~) don't.
        @io << " " if expr.op[-1].ascii_letter?
        # Wrap complex operands in parens to avoid ambiguity.
        complex = expr.operand.is_a?(AST::BinaryExpr) || expr.operand.is_a?(AST::UnaryExpr)
        @io << "(" if complex
        emit expr.operand
        @io << ")" if complex
      when AST::IsNullExpr
        emit(expr.operand)
        @io << (expr.negated? ? " IS NOT NULL" : " IS NULL")
      when AST::BetweenExpr
        emit expr.operand
        @io << (expr.negated? ? " NOT BETWEEN " : " BETWEEN ")
        emit expr.low
        @io << " AND "
        emit expr.high
      when AST::InListExpr
        emit expr.operand
        @io << (expr.negated? ? " NOT IN (" : " IN (")
        expr.list.each_with_index { |e, i| @io << ", " if i > 0; emit(e) }
        @io << ")"
      when AST::InSubqueryExpr
        emit expr.operand
        @io << (expr.negated? ? " NOT IN (" : " IN (")
        emit expr.subquery
        @io << ")"
      when AST::LikeExpr
        emit expr.operand
        if expr.negated? && expr.ilike?
          @io << " NOT ILIKE "
        elsif expr.negated?
          @io << " NOT LIKE "
        elsif expr.ilike?
          @io << " ILIKE "
        else
          @io << " LIKE "
        end
        emit expr.pattern
      when AST::FunctionCall
        if s = expr.schema
          @io << s << "."
        end
        @io << expr.name << "("
        @io << "DISTINCT " if expr.distinct?
        if expr.star?
          @io << "*"
        else
          expr.args.each_with_index do |arg, i|
            @io << ", " if i > 0
            emit arg
          end
        end
        @io << ")"
        if filter = expr.filter
          @io << " FILTER (WHERE "
          emit filter
          @io << ")"
        end
        if over = expr.over
          @io << " OVER ("
          emit_window_spec over
          @io << ")"
        end
      when AST::SubscriptExpr
        emit expr.expr
        @io << "["
        emit expr.index
        @io << "]"
      when AST::CastExpr
        emit expr.expr
        @io << "::" << expr.type_name
      when AST::CaseExpr
        @io << "CASE"
        if subject = expr.subject
          @io << " "
          emit subject
        end
        expr.whens.each do |w|
          @io << " WHEN "
          emit w.condition
          @io << " THEN "
          emit w.result
        end
        if e = expr.else
          @io << " ELSE "
          emit e
        end
        @io << " END"
      when AST::SubqueryExpr
        @io << "("
        emit expr.query
        @io << ")"
      when AST::ExistsExpr
        @io << "EXISTS ("
        emit expr.query
        @io << ")"
      else
        raise "Unknown expr type: #{expr.class}"
      end
    end

    private def emit_schema(schema : Nil) : Nil
    end

    private def emit_schema(schema : String) : Nil
      emit_identifier schema
      @io << '.'
    end

    private def emit_identifier(identifier : String) : Nil
      all_word_chars = true
      identifier.each_char do |char|
        unless char.ascii_alphanumeric? || char == '_'
          all_word_chars = false
          break
        end
      end

      if all_word_chars
        @io << identifier
      else
        identifier.inspect @io
      end
    end

    # Emit a string literal, using E'...' syntax if the value contains
    # backslashes or ASCII control characters (e.g. embedded newlines).
    private def emit_string_literal(value : String) : Nil
      needs_escape = value.each_char.any? { |c| c == '\\' || c.ord < 0x20 }
      if needs_escape
        @io << "E'"
        value.each_char do |c|
          case c
          when '\'' then @io << "''"
          when '\\' then @io << "\\\\"
          when '\n' then @io << "\\n"
          when '\r' then @io << "\\r"
          when '\t' then @io << "\\t"
          else           @io << c
          end
        end
        @io << "'"
      else
        @io << "'"
        value.each_char do |c|
          if c == '\''
            @io << "''"
          else
            @io << c
          end
        end
        @io << "'"
      end
    end

    private def emit_window_spec(spec : AST::WindowSpec) : Nil
      unless spec.partition_by.empty?
        @io << "PARTITION BY "
        spec.partition_by.each_with_index do |expr, i|
          @io << ", " if i > 0
          emit expr
        end
      end
      unless spec.order_by.empty?
        @io << " " unless spec.partition_by.empty?
        @io << "ORDER BY "
        spec.order_by.each_with_index do |item, i|
          @io << ", " if i > 0
          emit item.expr
          @io << ' ' << item.direction
          if item.nulls_order
            @io << " NULLS " << item.nulls_order
          end
        end
      end
    end

    class UnsupportedNodeType < Error
    end
  end

  module AST
    class Node
      def to_s(io : IO) : Nil
        Printer.new(io).emit self
      end
    end
  end
end
