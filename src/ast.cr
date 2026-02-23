module Parsegres
  module AST
    abstract class Node; end

    abstract class Statement < Node; end

    abstract class Expr < Node; end

    abstract class FromItem < Node; end

    # ── Statements ────────────────────────────────────────────────────────────

    class SelectStatement < Statement
      property ctes : Array(CTEDefinition) = [] of CTEDefinition
      property? recursive : Bool = false
      property? distinct : Bool = false
      property distinct_on : Array(Expr)? = nil
      property columns : Array(SelectColumn) = [] of SelectColumn
      property from : Array(FromItem) = [] of FromItem
      property where : Expr? = nil
      property group_by : Array(Expr) = [] of Expr
      property having : Expr? = nil
      property order_by : Array(OrderByItem) = [] of OrderByItem
      property limit : Expr? = nil
      property offset : Expr? = nil
    end

    class InsertStatement < Statement
      property ctes : Array(CTEDefinition) = [] of CTEDefinition
      property? recursive : Bool = false
      property schema : String? = nil
      property table : String
      property columns : Array(String)? = nil
      property source : InsertSource
      property returning : Array(SelectColumn) = [] of SelectColumn

      def initialize(@table, @source)
      end
    end

    class UpdateStatement < Statement
      property ctes : Array(CTEDefinition) = [] of CTEDefinition
      property? recursive : Bool = false
      property schema : String? = nil
      property table : String
      property? only : Bool = false
      property alias_name : String? = nil
      property assignments : Array(Assignment)
      property from : Array(FromItem) = [] of FromItem
      property where : Expr? = nil
      property returning : Array(SelectColumn) = [] of SelectColumn

      def initialize(@table, @assignments)
      end
    end

    record Assignment, column : String, value : Expr

    class DeleteStatement < Statement
      property ctes : Array(CTEDefinition) = [] of CTEDefinition
      property? recursive : Bool = false
      property schema : String? = nil
      property table : String
      property? only : Bool = false
      property alias_name : String? = nil
      property using : Array(FromItem) = [] of FromItem
      property where : Expr? = nil
      property returning : Array(SelectColumn) = [] of SelectColumn

      def initialize(@table)
      end
    end

    # ── CREATE TABLE ──────────────────────────────────────────────────────────

    class CreateTableStatement < Statement
      property schema : String? = nil
      property name : String
      property? temporary : Bool = false
      property? if_not_exists : Bool = false
      property columns : Array(ColumnDef) = [] of ColumnDef
      property constraints : Array(TableConstraint) = [] of TableConstraint

      def initialize(@name)
      end
    end

    class ColumnDef < Node
      property name : String
      property type_name : String
      property constraints : Array(ColumnConstraint) = [] of ColumnConstraint

      def initialize(@name, @type_name)
      end
    end

    # Column-level constraints

    abstract class ColumnConstraint < Node
      property constraint_name : String? = nil
    end

    class NotNullConstraint < ColumnConstraint; end

    class NullConstraint < ColumnConstraint; end

    class PrimaryKeyColumnConstraint < ColumnConstraint; end

    class UniqueColumnConstraint < ColumnConstraint; end

    class DefaultConstraint < ColumnConstraint
      property expr : Expr

      def initialize(@expr)
      end
    end

    class CheckColumnConstraint < ColumnConstraint
      property expr : Expr

      def initialize(@expr)
      end
    end

    class ReferencesConstraint < ColumnConstraint
      property ref_schema : String? = nil
      property ref_table : String
      property ref_column : String? = nil

      def initialize(@ref_table)
      end
    end

    # Table-level constraints

    abstract class TableConstraint < Node
      property constraint_name : String? = nil
    end

    class PrimaryKeyTableConstraint < TableConstraint
      property columns : Array(String)

      def initialize(@columns)
      end
    end

    class UniqueTableConstraint < TableConstraint
      property columns : Array(String)

      def initialize(@columns)
      end
    end

    class CheckTableConstraint < TableConstraint
      property expr : Expr

      def initialize(@expr)
      end
    end

    record ExcludeElement, column : String, operator : String

    class ExcludeTableConstraint < TableConstraint
      property using : String? = nil
      property elements : Array(ExcludeElement)

      def initialize(@elements)
      end
    end

    class ForeignKeyTableConstraint < TableConstraint
      property columns : Array(String)
      property ref_schema : String? = nil
      property ref_table : String
      property ref_columns : Array(String)? = nil

      def initialize(@columns, @ref_table)
      end
    end

    # ── ALTER TABLE ───────────────────────────────────────────────────────────

    enum DropBehavior
      Restrict
      Cascade
    end

    class AlterTableStatement < Statement
      property schema : String? = nil
      property name : String
      property? if_exists : Bool = false
      property? only : Bool = false
      property actions : Array(AlterTableAction)

      def initialize(@name, @actions)
      end
    end

    abstract class AlterTableAction < Node; end

    class AddColumnAction < AlterTableAction
      property? if_not_exists : Bool = false
      property column : ColumnDef

      def initialize(@column)
      end
    end

    class DropColumnAction < AlterTableAction
      property column : String
      property? if_exists : Bool = false
      property behavior : DropBehavior? = nil

      def initialize(@column)
      end
    end

    class AlterColumnTypeAction < AlterTableAction
      property column : String
      property type_name : String

      def initialize(@column, @type_name)
      end
    end

    class AlterColumnSetDefaultAction < AlterTableAction
      property column : String
      property expr : Expr

      def initialize(@column, @expr)
      end
    end

    class AlterColumnDropDefaultAction < AlterTableAction
      property column : String

      def initialize(@column)
      end
    end

    class AlterColumnSetNotNullAction < AlterTableAction
      property column : String

      def initialize(@column)
      end
    end

    class AlterColumnDropNotNullAction < AlterTableAction
      property column : String

      def initialize(@column)
      end
    end

    class RenameColumnAction < AlterTableAction
      property old_name : String
      property new_name : String

      def initialize(@old_name, @new_name)
      end
    end

    class RenameTableAction < AlterTableAction
      property new_name : String

      def initialize(@new_name)
      end
    end

    class AddConstraintAction < AlterTableAction
      property constraint : TableConstraint

      def initialize(@constraint)
      end
    end

    class DropConstraintAction < AlterTableAction
      property name : String
      property? if_exists : Bool = false
      property behavior : DropBehavior? = nil

      def initialize(@name)
      end
    end

    # ── DROP TABLE ────────────────────────────────────────────────────────────

    record DropTableTarget, schema : String?, name : String

    class DropTableStatement < Statement
      property targets : Array(DropTableTarget)
      property? if_exists : Bool = false
      property behavior : DropBehavior? = nil

      def initialize(@targets)
      end
    end

    # ── CREATE INDEX / DROP INDEX ─────────────────────────────────────────────

    class IndexElement < Node
      property column : String
      property expr : Expr? = nil
      property direction : OrderByItem::Direction? = nil
      property nulls_order : OrderByItem::NullsOrder? = nil

      def initialize(@column)
      end
    end

    class CreateIndexStatement < Statement
      property? unique : Bool = false
      property? concurrently : Bool = false
      property? if_not_exists : Bool = false
      property index_name : String? = nil
      property? only : Bool = false
      property table_schema : String? = nil
      property table_name : String
      property using : String? = nil
      property columns : Array(IndexElement)
      property where : Expr? = nil

      def initialize(@table_name, @columns)
      end
    end

    record DropIndexTarget, schema : String?, name : String

    class DropIndexStatement < Statement
      property targets : Array(DropIndexTarget)
      property? concurrently : Bool = false
      property? if_exists : Bool = false
      property behavior : DropBehavior? = nil

      def initialize(@targets)
      end
    end

    # ── CREATE VIEW / DROP VIEW ───────────────────────────────────────────────

    class CreateViewStatement < Statement
      property? or_replace : Bool = false
      property? temporary : Bool = false
      property? if_not_exists : Bool = false
      property schema : String? = nil
      property name : String
      property columns : Array(String)? = nil
      property query : Statement

      def initialize(@name, @query)
      end
    end

    record DropViewTarget, schema : String?, name : String

    class DropViewStatement < Statement
      property targets : Array(DropViewTarget)
      property? if_exists : Bool = false
      property behavior : DropBehavior? = nil

      def initialize(@targets)
      end
    end

    # ── TRUNCATE ──────────────────────────────────────────────────────────────

    record TruncateTarget, schema : String?, name : String, only : Bool

    class TruncateStatement < Statement
      enum IdentityBehavior
        Restart
        Continue
      end

      property targets : Array(TruncateTarget)
      property identity : IdentityBehavior? = nil
      property behavior : DropBehavior? = nil

      def initialize(@targets)
      end
    end

    # ── CREATE / ALTER / DROP SEQUENCE ────────────────────────────────────────

    class SequenceOptions < Node
      property increment : Int64? = nil
      property min_value : Int64? = nil
      property? no_min_value : Bool = false
      property max_value : Int64? = nil
      property? no_max_value : Bool = false
      property start : Int64? = nil
      property restart : Int64? = nil
      property? restart_default : Bool = false
      property cache : Int64? = nil
      property cycle : Bool? = nil # true=CYCLE, false=NO CYCLE, nil=unspecified
      property owned_by : String? = nil
    end

    class CreateSequenceStatement < Statement
      property? temporary : Bool = false
      property? if_not_exists : Bool = false
      property schema : String? = nil
      property name : String
      property options : SequenceOptions

      def initialize(@name)
        @options = SequenceOptions.new
      end
    end

    class AlterSequenceStatement < Statement
      property? if_exists : Bool = false
      property schema : String? = nil
      property name : String
      property options : SequenceOptions

      def initialize(@name)
        @options = SequenceOptions.new
      end
    end

    record DropSequenceTarget, schema : String?, name : String

    class DropSequenceStatement < Statement
      property targets : Array(DropSequenceTarget)
      property? if_exists : Bool = false
      property behavior : DropBehavior? = nil

      def initialize(@targets)
      end
    end

    # ── CREATE / DROP EXTENSION ───────────────────────────────────────────────

    class CreateExtensionStatement < Statement
      property name : String
      property? if_not_exists : Bool = false

      def initialize(@name)
      end
    end

    class DropExtensionStatement < Statement
      property targets : Array(String)
      property? if_exists : Bool = false
      property behavior : DropBehavior? = nil

      def initialize(@targets)
      end
    end

    # ── CREATE / DROP TYPE ────────────────────────────────────────────────────

    class CreateRangeTypeStatement < Statement
      property schema : String? = nil
      property name : String
      property subtype : String

      def initialize(@name, @subtype)
      end
    end

    record DropTypeTarget, schema : String?, name : String

    class DropTypeStatement < Statement
      property targets : Array(DropTypeTarget)
      property? if_exists : Bool = false
      property behavior : DropBehavior? = nil

      def initialize(@targets)
      end
    end

    # ── CREATE / DROP SCHEMA ──────────────────────────────────────────────────

    class CreateSchemaStatement < Statement
      property? if_not_exists : Bool = false
      property name : String? = nil
      property authorization : String? = nil

      def initialize
      end
    end

    class DropSchemaStatement < Statement
      property targets : Array(String)
      property? if_exists : Bool = false
      property behavior : DropBehavior? = nil

      def initialize(@targets)
      end
    end

    # ── Transaction control ───────────────────────────────────────────────────

    class BeginStatement < Statement; end

    class CommitStatement < Statement; end

    class RollbackStatement < Statement; end

    class CreateRuleStatement < Statement
      property name : String
      property? or_replace : Bool = false
      property table : String
      property table_schema : String? = nil

      def initialize(@name, @table)
      end
    end

    class DoStatement < Statement
      property code : String
      property language : String? = nil

      def initialize(@code)
      end
    end

    abstract class InsertSource < Node; end

    class ValuesSource < InsertSource
      property rows : Array(Array(Expr))

      def initialize(@rows)
      end
    end

    class SelectSource < InsertSource
      property query : Statement

      def initialize(@query)
      end
    end

    class DefaultValuesSource < InsertSource; end

    # ── CTEs ──────────────────────────────────────────────────────────────────

    class CTEDefinition < Node
      property name : String
      property columns : Array(String)? = nil
      property query : Statement
      property materialized : Bool? = nil # nil=unspecified, true=MATERIALIZED, false=NOT MATERIALIZED

      def initialize(@name, @query)
      end
    end

    # ── Set operations ────────────────────────────────────────────────────────
    #
    # Precedence: INTERSECT binds tighter than UNION / EXCEPT.
    # The tree structure encodes this: each CompoundSelect node holds two
    # Statement children, so nesting naturally reflects precedence.

    class CompoundSelect < Statement
      enum Op
        Union
        UnionAll
        Intersect
        IntersectAll
        Except
        ExceptAll
      end

      property op : Op
      property left : Statement
      property right : Statement
      # CTEs and ORDER BY / LIMIT / OFFSET belong to the outermost node only.
      property ctes : Array(CTEDefinition) = [] of CTEDefinition
      property? recursive : Bool = false
      property order_by : Array(OrderByItem) = [] of OrderByItem
      property limit : Expr? = nil
      property offset : Expr? = nil

      def initialize(@op, @left, @right)
      end
    end

    # ── Column list ───────────────────────────────────────────────────────────

    class SelectColumn < Node
      property expr : Expr
      property alias_name : String? = nil

      def initialize(@expr)
      end
    end

    # ── FROM items ────────────────────────────────────────────────────────────

    class TableRef < FromItem
      property schema : String? = nil
      property name : String
      property alias_name : String? = nil

      def initialize(@name)
      end
    end

    class TableFunctionRef < FromItem
      property func : FunctionCall
      property alias_name : String? = nil

      def initialize(@func)
      end
    end

    class SubqueryRef < FromItem
      property query : Statement
      property alias_name : String

      def initialize(@query, @alias_name)
      end
    end

    class JoinExpr < FromItem
      enum Kind
        Inner
        Left
        Right
        Full
        Cross
      end

      property kind : Kind
      property left : FromItem
      property right : FromItem
      property on : Expr? = nil
      property using : Array(String)? = nil

      def initialize(@kind, @left, @right)
      end
    end

    # ── Literals ──────────────────────────────────────────────────────────────

    class IntegerLiteral < Expr
      property value : Int64

      def initialize(@value)
      end
    end

    class FloatLiteral < Expr
      property value : Float64

      def initialize(@value)
      end
    end

    class StringLiteral < Expr
      property value : String

      def initialize(@value)
      end
    end

    class BoolLiteral < Expr
      property value : Bool

      def initialize(@value)
      end
    end

    class NullLiteral < Expr; end

    class DefaultExpr < Expr; end

    class ParamRef < Expr
      property index : Int32

      def initialize(@index)
      end
    end

    # ── Column and wildcard references ────────────────────────────────────────

    class ColumnRef < Expr
      property table : String? = nil
      property column : String # "*" for table.*

      def initialize(@column)
      end
    end

    class Wildcard < Expr; end

    # ── Compound expressions ──────────────────────────────────────────────────

    class BinaryExpr < Expr
      property op : String
      property left : Expr
      property right : Expr

      def initialize(@op, @left, @right)
      end
    end

    class UnaryExpr < Expr
      property op : String
      property operand : Expr

      def initialize(@op, @operand)
      end
    end

    class IsNullExpr < Expr
      property operand : Expr
      property? negated : Bool

      def initialize(@operand, @negated = false)
      end
    end

    class BetweenExpr < Expr
      property operand : Expr
      property low : Expr
      property high : Expr
      property? negated : Bool

      def initialize(@operand, @low, @high, @negated = false)
      end
    end

    class InListExpr < Expr
      property operand : Expr
      property list : Array(Expr)
      property? negated : Bool

      def initialize(@operand, @list, @negated = false)
      end
    end

    class InSubqueryExpr < Expr
      property operand : Expr
      property subquery : Statement
      property? negated : Bool

      def initialize(@operand, @subquery, @negated = false)
      end
    end

    class LikeExpr < Expr
      property operand : Expr
      property pattern : Expr
      property? negated : Bool
      property? ilike : Bool

      def initialize(@operand, @pattern, @negated = false, @ilike = false)
      end
    end

    class WindowSpec < Node
      property partition_by : Array(Expr) = [] of Expr
      property order_by : Array(OrderByItem) = [] of OrderByItem
    end

    class FunctionCall < Expr
      property schema : String? = nil
      property name : String
      property args : Array(Expr)
      property? distinct : Bool = false
      property? star : Bool = false
      property filter : Expr? = nil
      property over : WindowSpec? = nil

      def initialize(@name, @args = [] of Expr)
      end
    end

    class SubscriptExpr < Expr
      property expr : Expr
      property index : Expr

      def initialize(@expr, @index)
      end
    end

    class CastExpr < Expr
      property expr : Expr
      property type_name : String

      def initialize(@expr, @type_name)
      end
    end

    class CaseExpr < Expr
      property subject : Expr? = nil
      property whens : Array(CaseWhen)
      property else : Expr? = nil

      def initialize(@whens = [] of CaseWhen)
      end
    end

    record CaseWhen, condition : Expr, result : Expr

    class SubqueryExpr < Expr
      property query : Statement

      def initialize(@query)
      end
    end

    class ExistsExpr < Expr
      property query : Statement

      def initialize(@query)
      end
    end

    # ── ORDER BY ─────────────────────────────────────────────────────────────

    class OrderByItem < Node
      enum Direction
        Asc; Desc
      end
      enum NullsOrder
        First; Last
      end

      property expr : Expr
      property direction : Direction = Direction::Asc
      property nulls_order : NullsOrder? = nil

      def initialize(@expr)
      end
    end
  end
end
