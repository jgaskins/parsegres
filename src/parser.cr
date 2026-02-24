module Parsegres
  class Parser
    # Multi-word PostgreSQL type names that can appear after ::
    private MULTIWORD_TYPES = {
      "double"    => "precision",
      "character" => "varying",
    }

    def initialize(@tokens : Array(Token))
      @pos = 0
    end

    def self.parse(sql : String) : AST::Statement
      tokens = Lexer.new(sql).tokenize
      new(tokens).parse_statement
    end

    # Entry point: handles the optional WITH clause, then delegates to
    # parse_compound which handles set operations and ORDER BY/LIMIT/OFFSET.
    def parse_statement : AST::Statement
      case current.type
      when .insert?
        parse_insert
      when .update?
        parse_update
      when .delete?
        parse_delete
      when .create?
        parse_create
      when .alter?
        parse_alter
      when .drop?
        parse_drop
      when .truncate?
        parse_truncate
      when .begin?
        parse_begin
      when .commit?
        parse_commit
      when .rollback?
        parse_rollback
      when .do?
        parse_do
      when .with?
        advance
        recursive = token(:recursive)

        ctes = [parse_cte_definition]
        while token(:comma)
          ctes << parse_cte_definition
        end

        result : AST::Statement = case current.type
        when .update?
          stmt = parse_update
          stmt.ctes = ctes
          stmt.recursive = recursive
          stmt
        when .insert?
          stmt = parse_insert
          stmt.ctes = ctes
          stmt.recursive = recursive
          stmt
        when .delete?
          stmt = parse_delete
          stmt.ctes = ctes
          stmt.recursive = recursive
          stmt
        else
          compound = parse_compound
          case compound
          when AST::SelectStatement
            compound.ctes = ctes
            compound.recursive = recursive
          when AST::CompoundSelect
            compound.ctes = ctes
            compound.recursive = recursive
          end
          compound
        end
        result
      else
        parse_compound
      end
    end

    # # Set operations
    #
    # Grammar (simplified):
    #   compound  ::= intersect_chain { (UNION | EXCEPT) [ALL | DISTINCT] intersect_chain }
    #                 [ORDER BY ...] [LIMIT ...] [OFFSET ...]
    #   intersect_chain ::= select_core { INTERSECT [ALL | DISTINCT] select_core }
    #
    # INTERSECT has higher precedence than UNION / EXCEPT. The tree structure
    # encodes this: each UNION/EXCEPT node's right child is a fully-resolved
    # INTERSECT chain.
    private def parse_compound : AST::Statement
      result = parse_intersect_level

      while current.type.union? || current.type.except?
        type = current.type
        advance
        all = token(:all)
        # DISTINCT is the default, consume if explicit
        token(:distinct) unless all
        op = if type.union?
               all ? AST::CompoundSelect::Op::UnionAll : AST::CompoundSelect::Op::Union
             else
               all ? AST::CompoundSelect::Op::ExceptAll : AST::CompoundSelect::Op::Except
             end
        result = AST::CompoundSelect.new(op, result, parse_intersect_level)
      end

      # ORDER BY / LIMIT / OFFSET apply to the entire compound result unless
      # the individual SELECT component queries have parentheses around them.
      order_by = [] of AST::OrderByItem
      if token(:order)
        consume :by
        order_by = parse_order_by_list
      end

      limit = nil
      if token(:limit)
        limit = parse_primary
      end

      offset = nil
      if token(:offset)
        offset = parse_primary
      end

      if !order_by.empty? || limit || offset
        case result
        when AST::SelectStatement
          result.order_by = order_by
          result.limit = limit
          result.offset = offset
        when AST::CompoundSelect
          result.order_by = order_by
          result.limit = limit
          result.offset = offset
        end
      end

      result
    end

    # Parses a single SELECT, or a parenthesized compound query like (SELECT ... UNION SELECT ...).
    private def parse_select_or_paren : AST::Statement
      if current.type.l_paren?
        advance
        result = parse_compound
        consume :r_paren
        result
      else
        parse_select_core
      end
    end

    private def parse_intersect_level : AST::Statement
      result = parse_select_or_paren

      while current.type.intersect?
        advance
        all = token(:all)
        token(:distinct) unless all
        op = if all
               AST::CompoundSelect::Op::IntersectAll
             else
               AST::CompoundSelect::Op::Intersect
             end
        result = AST::CompoundSelect.new(op, result, parse_select_or_paren)
      end

      result
    end

    # Parses a single SELECT statement (SELECT … HAVING). Does not consume
    # ORDER BY / LIMIT / OFFSET. Those belong to the outermost compound level.
    private def parse_select_core : AST::SelectStatement
      consume :select
      stmt = AST::SelectStatement.new

      if token(:distinct)
        stmt.distinct = true
        if token(:on)
          consume :l_paren
          stmt.distinct_on = parse_expr_list
          consume :r_paren
        end
      elsif token(:all)
        # explicit ALL, just consume
      end

      stmt.columns = parse_column_list

      if token(:from)
        stmt.from = parse_from_list
      end

      if token(:where)
        stmt.where = parse_expr
      end

      if token(:group)
        consume :by
        stmt.group_by = parse_expr_list
      end

      if token(:having)
        stmt.having = parse_expr
      end

      stmt
    end

    # Column list

    private def parse_column_list : Array(AST::SelectColumn)
      cols = [parse_select_column]
      while token(:comma)
        cols << parse_select_column
      end
      cols
    end

    private def parse_select_column : AST::SelectColumn
      if token(:star)
        col = AST::SelectColumn.new(AST::Wildcard.new)
        return col
      end

      expr = parse_expr
      col = AST::SelectColumn.new(expr)

      if token(:as)
        col.alias_name = current.value
        advance
      elsif current.type.identifier?
        col.alias_name = current.value
        advance
      end

      col
    end

    # FROM clause

    private def parse_from_list : Array(AST::FromItem)
      items = [parse_from_item_with_joins]
      while token(:comma)
        items << parse_from_item_with_joins
      end
      items
    end

    private def parse_from_item_with_joins : AST::FromItem
      left = parse_single_from_item

      loop do
        join_kind = case current.type
                    when .join?
                      advance
                      AST::JoinExpr::Kind::Inner
                    when .inner?
                      advance
                      consume :join
                      AST::JoinExpr::Kind::Inner
                    when .left?
                      advance
                      token(:outer)
                      consume :join
                      AST::JoinExpr::Kind::Left
                    when .right?
                      advance
                      token(:outer)
                      consume :join
                      AST::JoinExpr::Kind::Right
                    when .full?
                      advance
                      token(:outer)
                      consume :join
                      AST::JoinExpr::Kind::Full
                    when .cross?
                      advance
                      consume :join
                      AST::JoinExpr::Kind::Cross
                    else
                      break
                    end

        right = parse_single_from_item
        join = AST::JoinExpr.new(join_kind, left, right)

        if current.type.on?
          advance
          join.on = parse_expr
        elsif current.type.using?
          advance
          consume :l_paren
          cols = [consume(:identifier).value]
          while token(:comma)
            cols << consume(:identifier).value
          end
          consume :r_paren
          join.using = cols
        end

        left = join
      end

      left
    end

    private def parse_single_from_item : AST::FromItem
      if current.type.l_paren?
        advance
        subq = parse_statement
        consume :r_paren
        alias_name = parse_optional_alias || raise ParseError.new("Subquery in FROM requires an alias", current)
        return AST::SubqueryRef.new(subq, alias_name)
      end

      parse_table_ref
    end

    private def parse_table_ref : AST::FromItem
      name = consume_name.value
      schema = nil

      if current.type.dot?
        advance
        schema = name
        name = consume_name.value
      end

      if current.type.l_paren?
        advance
        func = parse_function_args(name)
        func.schema = schema
        ref = AST::TableFunctionRef.new(func)
        ref.alias_name = parse_optional_alias
        return ref
      end

      ref = AST::TableRef.new(name)
      ref.schema = schema
      ref.alias_name = parse_optional_alias
      ref
    end

    private def parse_optional_alias : String?
      if token(:as)
        current_then_advance.value
      elsif current.type.identifier? && !stop_word?(current.type)
        current_then_advance.value
      end
    end

    # ORDER BY

    private def parse_order_by_list : Array(AST::OrderByItem)
      items = [parse_order_by_item]
      while token(:comma)
        items << parse_order_by_item
      end
      items
    end

    private def parse_order_by_item : AST::OrderByItem
      item = AST::OrderByItem.new(parse_expr)

      if token(:asc)
        item.direction = AST::OrderByItem::Direction::Asc
      elsif token(:desc)
        item.direction = AST::OrderByItem::Direction::Desc
      end

      if token(:nulls)
        if token(:first)
          item.nulls_order = AST::OrderByItem::NullsOrder::First
        elsif token(:last)
          item.nulls_order = AST::OrderByItem::NullsOrder::Last
        else
          raise ParseError.new("Expected FIRST or LAST after NULLS", current)
        end
      end

      item
    end

    # Expression parsing (precedence, lowest → highest)
    #
    #  OR  →  AND  →  NOT  →  IS NULL / comparison / IN / BETWEEN / LIKE
    #      →  concat ||  →  + -  →  * / %  →  unary -+  →  :: cast  →  primary

    private def parse_expr : AST::Expr
      parse_or
    end

    private def parse_or : AST::Expr
      left = parse_and
      while token(:or)
        left = AST::BinaryExpr.new("OR", left, parse_and)
      end
      left
    end

    private def parse_and : AST::Expr
      left = parse_not
      while token(:and)
        left = AST::BinaryExpr.new("AND", left, parse_not)
      end
      left
    end

    private def parse_not : AST::Expr
      if token(:not)
        AST::UnaryExpr.new("NOT", parse_not)
      else
        parse_is
      end
    end

    private def parse_is : AST::Expr
      expr = parse_comparison
      if token(:is)
        negated = token(:not)
        if token(:null)
          return AST::IsNullExpr.new(expr, negated)
        elsif token(:true)
          op = negated ? "IS NOT TRUE" : "IS TRUE"
          return AST::BinaryExpr.new(op, expr, AST::BoolLiteral.new(true))
        elsif token(:false)
          op = negated ? "IS NOT FALSE" : "IS FALSE"
          return AST::BinaryExpr.new(op, expr, AST::BoolLiteral.new(false))
        else
          raise ParseError.new("Expected NULL, TRUE, or FALSE after IS#{negated ? " NOT" : ""}", current)
        end
      end
      expr
    end

    private def parse_comparison : AST::Expr
      left = parse_in_between_like

      case current.type
      when .eq?
        advance
        AST::BinaryExpr.new("=", left, parse_in_between_like)
      when .not_eq?
        advance
        AST::BinaryExpr.new("<>", left, parse_in_between_like)
      when .lt?
        advance
        AST::BinaryExpr.new("<", left, parse_in_between_like)
      when .gt?
        advance
        AST::BinaryExpr.new(">", left, parse_in_between_like)
      when .lt_eq?
        advance
        AST::BinaryExpr.new("<=", left, parse_in_between_like)
      when .gt_eq?
        advance
        AST::BinaryExpr.new(">=", left, parse_in_between_like)
      when .contains?
        advance
        AST::BinaryExpr.new("@>", left, parse_in_between_like)
      when .contained_by?
        advance
        AST::BinaryExpr.new("<@", left, parse_in_between_like)
      when .text_search?
        advance
        AST::BinaryExpr.new("@@", left, parse_in_between_like)
      when .tilde?
        advance
        AST::BinaryExpr.new("~", left, parse_in_between_like)
      when .tilde_star?
        advance
        AST::BinaryExpr.new("~*", left, parse_in_between_like)
      when .not_tilde?
        advance
        AST::BinaryExpr.new("!~", left, parse_in_between_like)
      when .not_tilde_star?
        advance
        AST::BinaryExpr.new("!~*", left, parse_in_between_like)
      else
        left
      end
    end

    private def parse_in_between_like : AST::Expr
      left = parse_concat
      negated = false

      # Consume an optional NOT that precedes IN / BETWEEN / LIKE / ILIKE
      if current.type.not? && peek_type(1, :in, :between, :like, :i_like)
        advance
        negated = true
      end

      case current.type
      when .in?
        advance
        consume :l_paren
        if current.type.select? || current.type.with?
          subq = parse_statement
          consume :r_paren
          AST::InSubqueryExpr.new(left, subq, negated)
        else
          list = parse_expr_list
          consume :r_paren
          AST::InListExpr.new(left, list, negated)
        end
      when .between?
        advance
        low = parse_concat
        consume :and
        high = parse_concat
        AST::BetweenExpr.new(left, low, high, negated)
      when .like?
        advance
        AST::LikeExpr.new(left, parse_concat, negated, ilike: false)
      when .i_like?
        advance
        AST::LikeExpr.new(left, parse_concat, negated, ilike: true)
      else
        left
      end
    end

    private def parse_concat : AST::Expr
      left = parse_json
      while token(:concat)
        left = AST::BinaryExpr.new("||", left, parse_json)
      end
      left
    end

    private def parse_json : AST::Expr
      left = parse_bitwise
      loop do
        case current.type
        when .json_path_text?
          advance
          left = AST::BinaryExpr.new("#>>", left, parse_bitwise)
        when .json_path?
          advance
          left = AST::BinaryExpr.new("#>", left, parse_bitwise)
        when .arrow_text?
          advance
          left = AST::BinaryExpr.new("->>", left, parse_bitwise)
        when .arrow?
          advance
          left = AST::BinaryExpr.new("->", left, parse_bitwise)
        else
          break
        end
      end
      left
    end

    private def parse_bitwise : AST::Expr
      left = parse_additive
      loop do
        case current.type
        when .shift_left?
          advance
          left = AST::BinaryExpr.new("<<", left, parse_additive)
        when .shift_right?
          advance
          left = AST::BinaryExpr.new(">>", left, parse_additive)
        when .bit_and?
          advance
          left = AST::BinaryExpr.new("&", left, parse_additive)
        when .bit_or?
          advance
          left = AST::BinaryExpr.new("|", left, parse_additive)
        else
          break
        end
      end
      left
    end

    private def parse_additive : AST::Expr
      left = parse_multiplicative
      loop do
        case current.type
        when .plus?
          advance
          left = AST::BinaryExpr.new("+", left, parse_multiplicative)
        when .minus?
          advance
          left = AST::BinaryExpr.new("-", left, parse_multiplicative)
        else
          break
        end
      end
      left
    end

    private def parse_multiplicative : AST::Expr
      left = parse_power
      loop do
        case current.type
        when .star?
          advance
          left = AST::BinaryExpr.new("*", left, parse_power)
        when .slash?
          advance
          left = AST::BinaryExpr.new("/", left, parse_power)
        when .percent?
          advance
          left = AST::BinaryExpr.new("%", left, parse_power)
        else
          break
        end
      end
      left
    end

    private def parse_power : AST::Expr
      left = parse_unary
      if current.type.power?
        advance
        AST::BinaryExpr.new("^", left, parse_power)
      else
        left
      end
    end

    private def parse_unary : AST::Expr
      case current.type
      when .minus?
        advance
        AST::UnaryExpr.new("-", parse_cast)
      when .plus?
        advance
        parse_cast
      when .tilde?
        advance
        AST::UnaryExpr.new("~", parse_cast)
      else
        parse_cast
      end
    end

    private def parse_cast : AST::Expr
      expr = parse_primary
      loop do
        if token(:cast)
          expr = AST::CastExpr.new(expr, parse_type_name)
        elsif current.type.l_bracket?
          advance
          index = parse_expr
          consume :r_bracket
          expr = AST::SubscriptExpr.new(expr, index)
        elsif expr.is_a?(AST::FunctionCall) && current.type.identifier? && current.value.upcase == "FILTER"
          advance
          consume :l_paren
          consume :where
          filter_expr = parse_expr
          consume :r_paren
          expr.as(AST::FunctionCall).filter = filter_expr
        elsif expr.is_a?(AST::FunctionCall) && current.type.over?
          advance # OVER
          consume :l_paren
          spec = AST::WindowSpec.new
          if token(:partition)
            consume :by
            spec.partition_by = parse_expr_list
          end
          if token(:order)
            consume :by
            spec.order_by = parse_order_by_list
          end
          # Optional ROWS/RANGE/GROUPS frame clause
          if current.type.identifier? && (current.value.upcase == "ROWS" || current.value.upcase == "RANGE" || current.value.upcase == "GROUPS")
            advance
            if token(:between)
              parse_frame_bound
              consume :and
              parse_frame_bound
            else
              parse_frame_bound
            end
          end
          consume :r_paren
          expr.as(AST::FunctionCall).over = spec
        else
          break
        end
      end
      expr
    end

    private def parse_frame_bound : Nil
      if current.type.identifier? && current.value.upcase == "UNBOUNDED"
        advance # UNBOUNDED
        advance # PRECEDING or FOLLOWING
      elsif current.type.identifier? && current.value.upcase == "CURRENT"
        advance # CURRENT
        advance # ROW
      else
        parse_expr # offset expression
        advance    # PRECEDING or FOLLOWING
      end
    end

    private def parse_type_name : String
      name = consume(:identifier).value
      # Handle two-word type names: double precision, character varying
      if (second = MULTIWORD_TYPES[name.downcase]?)
        if current.type.identifier? && current.value.downcase == second
          advance
          name = "#{name} #{second}"
        end
      end
      # Handle precision/scale: type(n) or type(n, m)
      if current.type.l_paren?
        advance
        params = [consume(:integer).value]
        while token(:comma)
          params << consume(:integer).value
        end
        consume :r_paren
        name = "#{name}(#{params.join(", ")})"
      end
      # Handle array suffix: integer[]
      if current.type.l_bracket? && peek_type(1).r_bracket?
        advance
        advance
        name = "#{name}[]"
      end
      name
    end

    # More complete type name parser for column definitions in CREATE TABLE.
    # Extends parse_type_name with timestamp/time WITH/WITHOUT TIME ZONE.
    private def parse_column_type_name : String
      name = consume(:identifier).value
      case name.downcase
      when "double"
        if current.type.identifier? && current.value.downcase == "precision"
          name = "double precision"
          advance
        end
      when "character"
        if current.type.identifier? && current.value.downcase == "varying"
          name = "character varying"
          advance
        end
      when "timestamp", "time"
        if current.type.with?
          saved = @pos
          advance
          if current.type.identifier? && current.value.downcase == "time"
            advance
            if current.type.identifier? && current.value.downcase == "zone"
              advance
              name = "#{name} with time zone"
            else
              @pos = saved
            end
          else
            @pos = saved
          end
        elsif current.type.identifier? && current.value.downcase == "without"
          saved = @pos
          advance
          if current.type.identifier? && current.value.downcase == "time"
            advance
            if current.type.identifier? && current.value.downcase == "zone"
              advance
              name = "#{name} without time zone"
            else
              @pos = saved
            end
          else
            @pos = saved
          end
        end
      end
      # Handle precision/scale: type(n) or type(n, m)
      if current.type.l_paren?
        advance
        params = [consume(:integer).value]
        while token(:comma)
          params << consume(:integer).value
        end
        consume :r_paren
        name = "#{name}(#{params.join(", ")})"
      end
      # Handle array suffix: type[]
      if current.type.l_bracket? && peek_type(1).r_bracket?
        advance
        advance
        name = "#{name}[]"
      end
      name
    end

    private def parse_primary : AST::Expr
      case current.type
      when .integer?
        val = current.value.to_i64
        advance
        AST::IntegerLiteral.new(val)
      when .float?
        val = current.value.to_f64
        advance
        AST::FloatLiteral.new(val)
      when .string?
        val = current.value
        advance
        AST::StringLiteral.new(val)
      when .true?
        advance
        AST::BoolLiteral.new(true)
      when .false?
        advance
        AST::BoolLiteral.new(false)
      when .null?
        advance
        AST::NullLiteral.new
      when .default?
        advance
        AST::DefaultExpr.new
      when .dollar_param?
        idx = current.value.to_i32
        advance
        AST::ParamRef.new(idx)
      when .star?
        advance
        AST::Wildcard.new
      when .l_paren?
        advance
        if current.type.select? || current.type.with?
          subq = parse_statement
          consume :r_paren
          AST::SubqueryExpr.new(subq)
        else
          expr = parse_expr
          consume :r_paren
          expr
        end
      when .exists?
        advance
        consume :l_paren
        subq = parse_statement
        consume :r_paren
        AST::ExistsExpr.new(subq)
      when .case?
        parse_case_expr
      else
        # PostgreSQL allows most keywords to be used as bare column/table/function
        # names. consume_name accepts any non-operator, non-punctuation token.
        name = consume_name.value

        if current.type.string?
          # Typed string literal: typename 'string'  (e.g. interval '45 days')
          # Standard SQL type-cast syntax, equivalent to CAST('...' AS typename).
          val = current.value
          advance
          AST::CastExpr.new(AST::StringLiteral.new(val), name)
        elsif current.type.dot?
          # Qualified name or function (`schema.function_name()`), check what
          # comes afterward.
          advance
          if current.type.star?
            advance
            ref = AST::ColumnRef.new("*")
            ref.table = name
            ref
          else
            col_name = current.value
            advance
            if current.type.l_paren?
              # schema.function_name(...)
              schema = name
              func_name = col_name
              advance
              func = parse_function_args(func_name)
              func.schema = schema
              func
            else
              ref = AST::ColumnRef.new(col_name)
              ref.table = name
              ref
            end
          end
        elsif current.type.l_paren?
          advance
          parse_function_args(name)
        else
          AST::ColumnRef.new(name)
        end
      end
    end

    private def parse_function_args(name : String) : AST::FunctionCall
      func = AST::FunctionCall.new(name)

      if current.type.r_paren?
        advance
        return func
      end

      if current.type.star?
        advance
        func.star = true
        consume :r_paren
        return func
      end

      # ARRAY(SELECT ...) and similar: a subquery as the sole function argument
      if current.type.select? || current.type.with?
        subq = parse_statement
        consume :r_paren
        func.args = [AST::SubqueryExpr.new(subq)] of AST::Expr
        return func
      end

      if token(:distinct)
        func.distinct = true
      elsif token(:all)
        # explicit ALL
      end

      func.args = parse_expr_list
      consume :r_paren
      func
    end

    private def parse_case_expr : AST::CaseExpr
      consume :case
      expr = AST::CaseExpr.new

      unless current.type.when?
        expr.subject = parse_expr
      end

      while current.type.when?
        advance
        condition = parse_expr
        consume :then
        result = parse_expr
        expr.whens << AST::CaseWhen.new(condition, result)
      end

      if token(:else)
        expr.else = parse_expr
      end

      consume :end
      expr
    end

    # INSERT

    private def parse_insert : AST::InsertStatement
      consume :insert
      consume :into

      name = consume(:identifier).value
      schema = nil
      if current.type.dot?
        advance
        schema = name
        name = consume(:identifier).value
      end

      columns = nil
      if token(:l_paren)
        cols = [consume(:identifier).value]
        while token(:comma)
          cols << consume(:identifier).value
        end
        consume :r_paren
        columns = cols
      end

      source : AST::InsertSource = case current.type
      when .values?
        advance
        rows = [] of Array(AST::Expr)
        loop do
          consume :l_paren
          rows << parse_expr_list
          consume :r_paren
          break unless token(:comma)
        end
        AST::ValuesSource.new(rows)
      when .default?
        advance
        consume :values
        AST::DefaultValuesSource.new
      when .select?, .with?
        AST::SelectSource.new(parse_statement)
      else
        raise ParseError.new("Expected VALUES, DEFAULT VALUES, or SELECT after INSERT INTO", current)
      end

      stmt = AST::InsertStatement.new(name, source)
      stmt.schema = schema
      stmt.columns = columns

      if token(:returning)
        stmt.returning = parse_column_list
      end

      stmt
    end

    # CREATE {INDEX | VIEW | SEQUENCE | SCHEMA | TABLE}

    private def parse_create : AST::Statement
      offset = 1
      # Skip optional OR REPLACE (OR is a keyword; REPLACE stays an identifier)
      offset += 2 if peek_type(offset).or?
      # Skip optional UNIQUE (only valid before INDEX)
      offset += 1 if peek_type(offset).unique?
      # Skip optional TEMP / TEMPORARY
      offset += 1 if peek_type(offset).temp? || peek_type(offset).temporary?

      case peek_type(offset)
      when .index?     then parse_create_index
      when .view?      then parse_create_view
      when .sequence?  then parse_create_sequence
      when .schema?    then parse_create_schema
      when .extension? then parse_create_extension
      when .type?      then parse_create_type
      else
        if peek_type(offset).identifier? && peek_value(offset).upcase == "RULE"
          parse_create_rule
        else
          parse_create_table
        end
      end
    end

    # CREATE INDEX

    private def parse_create_index : AST::CreateIndexStatement
      consume :create
      unique = token(:unique)
      consume :index
      concurrently = token(:concurrently)

      if_not_exists = false
      if token(:if)
        consume :not
        consume :exists
        if_not_exists = true
      end

      index_name = current.type.identifier? ? consume(:identifier).value : nil

      consume :on
      only = token(:only)

      table_name = consume(:identifier).value
      table_schema = nil
      if current.type.dot?
        advance
        table_schema = table_name
        table_name = consume(:identifier).value
      end

      using = nil
      if token(:using)
        using = consume(:identifier).value
      end

      consume :l_paren
      columns = [parse_index_element]
      while token(:comma)
        columns << parse_index_element
      end
      consume :r_paren

      where = nil
      if token(:where)
        where = parse_expr
      end

      stmt = AST::CreateIndexStatement.new(table_name, columns)
      stmt.unique = unique
      stmt.concurrently = concurrently
      stmt.if_not_exists = if_not_exists
      stmt.index_name = index_name
      stmt.only = only
      stmt.table_schema = table_schema
      stmt.using = using
      stmt.where = where
      stmt
    end

    private def parse_index_element : AST::IndexElement
      if current.type.l_paren?
        advance
        expr = parse_expr
        consume :r_paren
        elem = AST::IndexElement.new("")
        elem.expr = expr
      else
        elem = AST::IndexElement.new(consume_name.value)
      end

      if token(:asc)
        elem.direction = AST::OrderByItem::Direction::Asc
      elsif token(:desc)
        elem.direction = AST::OrderByItem::Direction::Desc
      end

      if token(:nulls)
        if token(:first)
          elem.nulls_order = AST::OrderByItem::NullsOrder::First
        elsif token(:last)
          elem.nulls_order = AST::OrderByItem::NullsOrder::Last
        else
          raise ParseError.new("Expected FIRST or LAST after NULLS", current)
        end
      end

      elem
    end

    # CREATE TABLE

    private def parse_create_table : AST::CreateTableStatement
      consume :create
      temporary = token(:temporary) || token(:temp)
      consume :table

      if_not_exists = false
      if token(:if)
        consume :not
        consume :exists
        if_not_exists = true
      end

      name = consume(:identifier).value
      schema = nil
      if current.type.dot?
        advance
        schema = name
        name = consume(:identifier).value
      end

      consume :l_paren

      columns = [] of AST::ColumnDef
      constraints = [] of AST::TableConstraint

      loop do
        if table_constraint_start?
          constraints << parse_table_constraint
        else
          columns << parse_column_def
        end
        break unless token(:comma)
        break if current.type.r_paren?
      end

      consume :r_paren

      stmt = AST::CreateTableStatement.new(name)
      stmt.schema = schema
      stmt.temporary = temporary
      stmt.if_not_exists = if_not_exists
      stmt.columns = columns
      stmt.constraints = constraints
      stmt
    end

    private def table_constraint_start? : Bool
      case current.type
      when .constraint?, .primary?, .unique?, .check?, .foreign?, .exclude?
        true
      else
        false
      end
    end

    private def column_constraint_start? : Bool
      case current.type
      when .not?, .null?, .default?, .primary?, .unique?, .check?, .references?, .constraint?
        true
      else
        false
      end
    end

    private def parse_column_def : AST::ColumnDef
      name = consume_name.value
      type_name = parse_column_type_name
      col = AST::ColumnDef.new(name, type_name)

      while column_constraint_start?
        constraint_name = nil
        if token(:constraint)
          constraint_name = consume(:identifier).value
        end

        cc : AST::ColumnConstraint = case current.type
        when .not?
          advance
          consume :null
          AST::NotNullConstraint.new
        when .null?
          advance
          AST::NullConstraint.new
        when .default?
          advance
          AST::DefaultConstraint.new(parse_expr)
        when .primary?
          advance
          consume :key
          AST::PrimaryKeyColumnConstraint.new
        when .unique?
          advance
          AST::UniqueColumnConstraint.new
        when .check?
          advance
          consume :l_paren
          expr = parse_expr
          consume :r_paren
          AST::CheckColumnConstraint.new(expr)
        when .references?
          advance
          ref_table = consume(:identifier).value
          ref_schema = nil
          if current.type.dot?
            advance
            ref_schema = ref_table
            ref_table = consume(:identifier).value
          end
          ref_col = nil
          if token(:l_paren)
            ref_col = consume(:identifier).value
            consume :r_paren
          end
          # Consume optional ON DELETE / ON UPDATE referential actions
          while current.type.on?
            advance # ON
            advance # DELETE or UPDATE keyword
            case current.type
            when .cascade?, .restrict?
              advance
            when .set?
              advance
              advance # NULL or DEFAULT
            else
              # NO ACTION: two identifier tokens
              advance if current.type.identifier?
              advance if current.type.identifier?
            end
          end
          rc = AST::ReferencesConstraint.new(ref_table)
          rc.ref_schema = ref_schema
          rc.ref_column = ref_col
          rc
        else
          break
        end

        cc.constraint_name = constraint_name
        col.constraints << cc
      end

      col
    end

    private def parse_table_constraint : AST::TableConstraint
      constraint_name = nil
      if token(:constraint)
        constraint_name = consume(:identifier).value
      end

      tc : AST::TableConstraint = case current.type
      when .primary?
        advance
        consume :key
        consume :l_paren
        cols = [consume_name.value]
        while token(:comma)
          cols << consume_name.value
        end
        consume :r_paren
        AST::PrimaryKeyTableConstraint.new(cols)
      when .unique?
        advance
        consume :l_paren
        cols = [consume_name.value]
        while token(:comma)
          cols << consume_name.value
        end
        consume :r_paren
        AST::UniqueTableConstraint.new(cols)
      when .check?
        advance
        consume :l_paren
        expr = parse_expr
        consume :r_paren
        AST::CheckTableConstraint.new(expr)
      when .foreign?
        advance
        consume :key
        consume :l_paren
        cols = [consume_name.value]
        while token(:comma)
          cols << consume_name.value
        end
        consume :r_paren
        consume :references
        ref_table = consume_name.value
        ref_schema = nil
        if current.type.dot?
          advance
          ref_schema = ref_table
          ref_table = consume_name.value
        end
        ref_cols = nil
        if token(:l_paren)
          rc = [consume_name.value]
          while token(:comma)
            rc << consume_name.value
          end
          consume :r_paren
          ref_cols = rc
        end
        fk = AST::ForeignKeyTableConstraint.new(cols, ref_table)
        fk.ref_schema = ref_schema
        fk.ref_columns = ref_cols
        fk
      when .exclude?
        advance
        using = nil
        if token(:using)
          using = consume(:identifier).value
        end
        consume :l_paren
        elements = [parse_exclude_element]
        while token(:comma)
          elements << parse_exclude_element
        end
        consume :r_paren
        exc = AST::ExcludeTableConstraint.new(elements)
        exc.using = using
        exc
      else
        raise ParseError.new("Expected PRIMARY KEY, UNIQUE, CHECK, FOREIGN KEY, or EXCLUDE in table constraint", current)
      end

      tc.constraint_name = constraint_name
      tc
    end

    private def parse_exclude_element : AST::ExcludeElement
      column = consume(:identifier).value
      consume :with
      operator = case current.type
                 when .overlap? then "&&"
                 when .eq?      then "="
                 when .not_eq?  then current.value
                 when .lt?      then "<"
                 when .gt?      then ">"
                 when .lt_eq?   then "<="
                 when .gt_eq?   then ">="
                 else                raise ParseError.new("Expected operator in EXCLUDE element", current)
                 end
      advance
      AST::ExcludeElement.new(column, operator)
    end

    # DROP dispatcher

    private def parse_drop : AST::Statement
      case peek_type(1)
      when .index?     then parse_drop_index
      when .view?      then parse_drop_view
      when .sequence?  then parse_drop_sequence
      when .schema?    then parse_drop_schema
      when .extension? then parse_drop_extension
      when .type?      then parse_drop_type
      else                  parse_drop_table
      end
    end

    # DROP INDEX

    private def parse_drop_index : AST::DropIndexStatement
      consume :drop
      consume :index
      concurrently = token(:concurrently)

      if_exists = false
      if token(:if)
        consume :exists
        if_exists = true
      end

      targets = [parse_drop_index_target]
      while token(:comma)
        targets << parse_drop_index_target
      end

      stmt = AST::DropIndexStatement.new(targets)
      stmt.concurrently = concurrently
      stmt.if_exists = if_exists
      stmt.behavior = parse_drop_behavior
      stmt
    end

    private def parse_drop_index_target : AST::DropIndexTarget
      name = consume(:identifier).value
      schema = nil
      if current.type.dot?
        advance
        schema = name
        name = consume(:identifier).value
      end
      AST::DropIndexTarget.new(schema, name)
    end

    # DROP TABLE

    private def parse_drop_table : AST::DropTableStatement
      consume :drop
      consume :table

      if_exists = false
      if token(:if)
        consume :exists
        if_exists = true
      end

      targets = [parse_drop_table_target]
      while token(:comma)
        targets << parse_drop_table_target
      end

      stmt = AST::DropTableStatement.new(targets)
      stmt.if_exists = if_exists
      stmt.behavior = parse_drop_behavior
      stmt
    end

    private def parse_drop_table_target : AST::DropTableTarget
      name = consume(:identifier).value
      schema = nil
      if current.type.dot?
        advance
        schema = name
        name = consume(:identifier).value
      end
      AST::DropTableTarget.new(schema, name)
    end

    # CREATE VIEW

    private def parse_create_view : AST::CreateViewStatement
      consume :create
      or_replace = false
      if token(:or)
        consume_identifier("REPLACE")
        or_replace = true
      end
      temporary = token(:temporary) || token(:temp)
      consume :view

      if_not_exists = false
      if token(:if)
        consume :not
        consume :exists
        if_not_exists = true
      end

      name = consume(:identifier).value
      schema = nil
      if current.type.dot?
        advance
        schema = name
        name = consume(:identifier).value
      end

      columns = nil
      if token(:l_paren)
        cols = [consume(:identifier).value]
        while token(:comma)
          cols << consume(:identifier).value
        end
        consume :r_paren
        columns = cols
      end

      consume :as
      query = parse_statement

      stmt = AST::CreateViewStatement.new(name, query)
      stmt.or_replace = or_replace
      stmt.temporary = temporary
      stmt.if_not_exists = if_not_exists
      stmt.schema = schema
      stmt.columns = columns
      stmt
    end

    # DROP VIEW

    private def parse_drop_view : AST::DropViewStatement
      consume :drop
      consume :view

      if_exists = false
      if token(:if)
        consume :exists
        if_exists = true
      end

      targets = [parse_drop_view_target]
      while token(:comma)
        targets << parse_drop_view_target
      end

      stmt = AST::DropViewStatement.new(targets)
      stmt.if_exists = if_exists
      stmt.behavior = parse_drop_behavior
      stmt
    end

    private def parse_drop_view_target : AST::DropViewTarget
      name = consume(:identifier).value
      schema = nil
      if current.type.dot?
        advance
        schema = name
        name = consume(:identifier).value
      end
      AST::DropViewTarget.new(schema, name)
    end

    # TRUNCATE

    private def parse_truncate : AST::TruncateStatement
      consume :truncate
      token(:table) # optional TABLE keyword

      targets = [parse_truncate_target]
      while token(:comma)
        targets << parse_truncate_target
      end

      stmt = AST::TruncateStatement.new(targets)

      if current.type.identifier? && current.value.upcase == "RESTART"
        advance
        consume_identifier("IDENTITY")
        stmt.identity = AST::TruncateStatement::IdentityBehavior::Restart
      elsif current.type.identifier? && current.value.upcase == "CONTINUE"
        advance
        consume_identifier("IDENTITY")
        stmt.identity = AST::TruncateStatement::IdentityBehavior::Continue
      end

      stmt.behavior = parse_drop_behavior
      stmt
    end

    private def parse_truncate_target : AST::TruncateTarget
      only = token(:only)
      name = consume(:identifier).value
      schema = nil
      if current.type.dot?
        advance
        schema = name
        name = consume(:identifier).value
      end
      AST::TruncateTarget.new(schema, name, only)
    end

    # CREATE SEQUENCE

    private def parse_create_sequence : AST::CreateSequenceStatement
      consume :create
      temporary = token(:temporary) || token(:temp)
      consume :sequence

      if_not_exists = false
      if token(:if)
        consume :not
        consume :exists
        if_not_exists = true
      end

      name = consume(:identifier).value
      schema = nil
      if current.type.dot?
        advance
        schema = name
        name = consume(:identifier).value
      end

      stmt = AST::CreateSequenceStatement.new(name)
      stmt.temporary = temporary
      stmt.if_not_exists = if_not_exists
      stmt.schema = schema
      stmt.options = parse_sequence_options
      stmt
    end

    # ALTER SEQUENCE

    private def parse_alter_sequence : AST::AlterSequenceStatement
      consume :alter
      consume :sequence

      if_exists = false
      if token(:if)
        consume :exists
        if_exists = true
      end

      name = consume(:identifier).value
      schema = nil
      if current.type.dot?
        advance
        schema = name
        name = consume(:identifier).value
      end

      stmt = AST::AlterSequenceStatement.new(name)
      stmt.if_exists = if_exists
      stmt.schema = schema
      stmt.options = parse_sequence_options
      stmt
    end

    # DROP SEQUENCE

    private def parse_drop_sequence : AST::DropSequenceStatement
      consume :drop
      consume :sequence

      if_exists = false
      if token(:if)
        consume :exists
        if_exists = true
      end

      targets = [parse_drop_sequence_target]
      while token(:comma)
        targets << parse_drop_sequence_target
      end

      stmt = AST::DropSequenceStatement.new(targets)
      stmt.if_exists = if_exists
      stmt.behavior = parse_drop_behavior
      stmt
    end

    private def parse_drop_sequence_target : AST::DropSequenceTarget
      name = consume(:identifier).value
      schema = nil
      if current.type.dot?
        advance
        schema = name
        name = consume(:identifier).value
      end
      AST::DropSequenceTarget.new(schema, name)
    end

    # Sequence options (shared by CREATE SEQUENCE and ALTER SEQUENCE)

    private def parse_sequence_options : AST::SequenceOptions
      opts = AST::SequenceOptions.new
      loop do
        break unless current.type.identifier?
        case current.value.upcase
        when "INCREMENT"
          advance
          token(:by) # optional BY
          opts.increment = consume(:integer).value.to_i64
        when "MINVALUE"
          advance
          opts.min_value = consume(:integer).value.to_i64
        when "MAXVALUE"
          advance
          opts.max_value = consume(:integer).value.to_i64
        when "NO"
          advance
          if current.type.identifier?
            case current.value.upcase
            when "MINVALUE"
              advance
              opts.no_min_value = true
            when "MAXVALUE"
              advance
              opts.no_max_value = true
            when "CYCLE"
              advance
              opts.cycle = false
            else
              raise ParseError.new("Expected MINVALUE, MAXVALUE, or CYCLE after NO", current)
            end
          else
            raise ParseError.new("Expected MINVALUE, MAXVALUE, or CYCLE after NO", current)
          end
        when "START"
          advance
          token(:with) # optional WITH
          opts.start = consume(:integer).value.to_i64
        when "RESTART"
          advance
          if token(:with)
            opts.restart = consume(:integer).value.to_i64
          elsif current.type.integer?
            opts.restart = consume(:integer).value.to_i64
          else
            opts.restart_default = true
          end
        when "CACHE"
          advance
          opts.cache = consume(:integer).value.to_i64
        when "CYCLE"
          advance
          opts.cycle = true
        when "OWNED"
          advance
          consume :by
          part = consume(:identifier).value
          if current.type.dot?
            advance
            col = consume(:identifier).value
            opts.owned_by = "#{part}.#{col}"
          else
            opts.owned_by = part
          end
        else
          break
        end
      end
      opts
    end

    # DROP TYPE

    private def parse_drop_type : AST::DropTypeStatement
      consume :drop
      consume :type

      if_exists = false
      if token(:if)
        consume :exists
        if_exists = true
      end

      targets = [parse_drop_type_target]
      while token(:comma)
        targets << parse_drop_type_target
      end

      stmt = AST::DropTypeStatement.new(targets)
      stmt.if_exists = if_exists
      stmt.behavior = parse_drop_behavior
      stmt
    end

    private def parse_drop_type_target : AST::DropTypeTarget
      name = consume(:identifier).value
      schema = nil
      if current.type.dot?
        advance
        schema = name
        name = consume(:identifier).value
      end
      AST::DropTypeTarget.new(schema, name)
    end

    # CREATE TYPE

    private def parse_create_type : AST::Statement
      consume :create
      consume :type

      name = consume(:identifier).value
      schema = nil
      if current.type.dot?
        advance
        schema = name
        name = consume(:identifier).value
      end

      consume :as

      unless current.type.identifier? && current.value.upcase == "RANGE"
        raise ParseError.new("Expected RANGE after AS in CREATE TYPE", current)
      end
      advance

      consume :l_paren
      subtype = nil
      loop do
        key = consume(:identifier).value.upcase
        consume :eq
        value = consume(:identifier).value
        subtype = value if key == "SUBTYPE"
        break unless token(:comma)
        break if current.type.r_paren?
      end
      consume :r_paren

      stmt = AST::CreateRangeTypeStatement.new(name, subtype || raise(ParseError.new("SUBTYPE is required in CREATE TYPE ... AS RANGE", current)))
      stmt.schema = schema
      stmt
    end

    # DROP EXTENSION

    private def parse_drop_extension : AST::DropExtensionStatement
      consume :drop
      consume :extension

      if_exists = false
      if token(:if)
        consume :exists
        if_exists = true
      end

      targets = [consume(:identifier).value]
      while token(:comma)
        targets << consume(:identifier).value
      end

      stmt = AST::DropExtensionStatement.new(targets)
      stmt.if_exists = if_exists
      stmt.behavior = parse_drop_behavior
      stmt
    end

    # CREATE EXTENSION

    private def parse_create_extension : AST::CreateExtensionStatement
      consume :create
      consume :extension

      if_not_exists = false
      if token(:if)
        consume :not
        consume :exists
        if_not_exists = true
      end

      name = consume(:identifier).value
      stmt = AST::CreateExtensionStatement.new(name)
      stmt.if_not_exists = if_not_exists
      stmt
    end

    # CREATE RULE

    private def parse_create_rule : AST::CreateRuleStatement
      consume :create
      or_replace = false
      if token(:or)
        consume_identifier("REPLACE")
        or_replace = true
      end
      consume_identifier("RULE")
      name = consume_name.value
      consume :as
      consume :on
      advance # event: SELECT, INSERT, UPDATE, DELETE
      consume :to
      table_name = consume_name.value
      table_schema = nil
      if current.type.dot?
        advance
        table_schema = table_name
        table_name = consume_name.value
      end
      # Optional WHERE (condition)
      if token(:where)
        consume :l_paren
        parse_expr
        consume :r_paren
      end
      # DO [ALSO | INSTEAD]
      consume :do
      if current.type.identifier? && (current.value.upcase == "ALSO" || current.value.upcase == "INSTEAD")
        advance
      end
      # Action: NOTHING | (commands...) | command
      if current.type.identifier? && current.value.upcase == "NOTHING"
        advance
      elsif current.type.l_paren?
        advance
        unless current.type.r_paren?
          parse_statement
          while token(:semicolon)
            break if current.type.r_paren?
            parse_statement
          end
        end
        consume :r_paren
      else
        parse_statement
      end
      stmt = AST::CreateRuleStatement.new(name, table_name)
      stmt.or_replace = or_replace
      stmt.table_schema = table_schema
      stmt
    end

    # CREATE SCHEMA

    private def parse_create_schema : AST::CreateSchemaStatement
      consume :create
      consume :schema

      if_not_exists = false
      if token(:if)
        consume :not
        consume :exists
        if_not_exists = true
      end

      stmt = AST::CreateSchemaStatement.new
      stmt.if_not_exists = if_not_exists

      if current.type.identifier?
        if current.value.upcase == "AUTHORIZATION"
          advance
          stmt.authorization = consume(:identifier).value
        else
          stmt.name = consume(:identifier).value
          if current.type.identifier? && current.value.upcase == "AUTHORIZATION"
            advance
            stmt.authorization = consume(:identifier).value
          end
        end
      end

      stmt
    end

    # DROP SCHEMA

    private def parse_drop_schema : AST::DropSchemaStatement
      consume :drop
      consume :schema

      if_exists = false
      if token(:if)
        consume :exists
        if_exists = true
      end

      targets = [consume(:identifier).value]
      while token(:comma)
        targets << consume(:identifier).value
      end

      stmt = AST::DropSchemaStatement.new(targets)
      stmt.if_exists = if_exists
      stmt.behavior = parse_drop_behavior
      stmt
    end

    # Transaction control

    private def parse_begin : AST::BeginStatement
      consume :begin
      if current.type.identifier? && (current.value.upcase == "WORK" || current.value.upcase == "TRANSACTION")
        advance
      end
      AST::BeginStatement.new
    end

    private def parse_commit : AST::CommitStatement
      consume :commit
      if current.type.identifier? && (current.value.upcase == "WORK" || current.value.upcase == "TRANSACTION")
        advance
      end
      AST::CommitStatement.new
    end

    private def parse_rollback : AST::RollbackStatement
      consume :rollback
      if current.type.identifier? && (current.value.upcase == "WORK" || current.value.upcase == "TRANSACTION")
        advance
      end
      AST::RollbackStatement.new
    end

    private def parse_do : AST::DoStatement
      consume :do
      language = nil
      if current.type.identifier? && current.value.upcase == "LANGUAGE"
        advance
        language = consume_name.value
      end
      code = consume(:string).value
      stmt = AST::DoStatement.new(code)
      stmt.language = language
      stmt
    end

    # ALTER dispatcher

    private def parse_alter : AST::Statement
      case peek_type(1)
      when .sequence? then parse_alter_sequence
      else                 parse_alter_table
      end
    end

    # ALTER TABLE

    private def parse_alter_table : AST::AlterTableStatement
      consume :alter
      consume :table

      if_exists = false
      if token(:if)
        consume :exists
        if_exists = true
      end

      only = token(:only)

      name = consume(:identifier).value
      schema = nil
      if current.type.dot?
        advance
        schema = name
        name = consume(:identifier).value
      end

      actions = [parse_alter_table_action]
      while token(:comma)
        actions << parse_alter_table_action
      end

      stmt = AST::AlterTableStatement.new(name, actions)
      stmt.schema = schema
      stmt.if_exists = if_exists
      stmt.only = only
      stmt
    end

    private def parse_alter_table_action : AST::AlterTableAction
      case current.type
      when .add?
        advance
        explicit_column = token(:column)
        if !explicit_column && table_constraint_start?
          AST::AddConstraintAction.new(parse_table_constraint)
        else
          if_not_exists = false
          if token(:if)
            consume :not
            consume :exists
            if_not_exists = true
          end
          action = AST::AddColumnAction.new(parse_column_def)
          action.if_not_exists = if_not_exists
          action
        end
      when .drop?
        advance
        if current.type.constraint?
          advance
          if_exists = false
          if token(:if)
            consume :exists
            if_exists = true
          end
          cname = consume(:identifier).value
          action = AST::DropConstraintAction.new(cname)
          action.if_exists = if_exists
          action.behavior = parse_drop_behavior
          action
        else
          token(:column)
          if_exists = false
          if token(:if)
            consume :exists
            if_exists = true
          end
          col = consume(:identifier).value
          action = AST::DropColumnAction.new(col)
          action.if_exists = if_exists
          action.behavior = parse_drop_behavior
          action
        end
      when .alter?
        advance
        token(:column)
        col_name = consume(:identifier).value
        parse_alter_column_subaction(col_name)
      when .rename?
        advance
        if token(:to)
          AST::RenameTableAction.new(consume(:identifier).value)
        else
          token(:column)
          old_name = consume(:identifier).value
          consume :to
          new_name = consume(:identifier).value
          AST::RenameColumnAction.new(old_name, new_name)
        end
      else
        raise ParseError.new("Expected ADD, DROP, ALTER, or RENAME in ALTER TABLE action", current)
      end
    end

    private def parse_alter_column_subaction(col_name : String) : AST::AlterTableAction
      case current.type
      when .set?
        advance
        if current.type.identifier? && current.value.downcase == "data"
          advance
          if current.type.type?
            advance
            AST::AlterColumnTypeAction.new(col_name, parse_column_type_name)
          else
            raise ParseError.new("Expected TYPE after SET DATA", current)
          end
        elsif current.type.default?
          advance
          AST::AlterColumnSetDefaultAction.new(col_name, parse_expr)
        elsif current.type.not?
          advance
          consume :null
          AST::AlterColumnSetNotNullAction.new(col_name)
        else
          raise ParseError.new("Expected DATA TYPE, DEFAULT, or NOT NULL after ALTER COLUMN SET", current)
        end
      when .drop?
        advance
        if current.type.default?
          advance
          AST::AlterColumnDropDefaultAction.new(col_name)
        elsif current.type.not?
          advance
          consume :null
          AST::AlterColumnDropNotNullAction.new(col_name)
        else
          raise ParseError.new("Expected DEFAULT or NOT NULL after ALTER COLUMN DROP", current)
        end
      when .type?
        advance
        AST::AlterColumnTypeAction.new(col_name, parse_column_type_name)
      else
        raise ParseError.new("Expected SET, DROP, or TYPE in ALTER COLUMN subaction", current)
      end
    end

    private def parse_drop_behavior : AST::DropBehavior?
      if token(:cascade)
        AST::DropBehavior::Cascade
      elsif token(:restrict)
        AST::DropBehavior::Restrict
      end
    end

    # DELETE

    private def parse_delete : AST::DeleteStatement
      consume :delete
      consume :from
      only = token(:only)

      name = consume(:identifier).value
      schema = nil
      if current.type.dot?
        advance
        schema = name
        name = consume(:identifier).value
      end

      alias_name = parse_optional_alias

      using = [] of AST::FromItem
      if token(:using)
        using = parse_from_list
      end

      where = nil
      if token(:where)
        where = parse_expr
      end

      stmt = AST::DeleteStatement.new(name)
      stmt.schema = schema
      stmt.only = only
      stmt.alias_name = alias_name
      stmt.using = using
      stmt.where = where

      if token(:returning)
        stmt.returning = parse_column_list
      end

      stmt
    end

    # UPDATE

    private def parse_update : AST::UpdateStatement
      consume :update
      only = token(:only)

      name = consume(:identifier).value
      schema = nil
      if current.type.dot?
        advance
        schema = name
        name = consume(:identifier).value
      end

      alias_name = parse_optional_alias

      consume :set

      assignments = [parse_assignment]
      while token(:comma)
        assignments << parse_assignment
      end

      from = [] of AST::FromItem
      if token(:from)
        from = parse_from_list
      end

      where = nil
      if token(:where)
        where = parse_expr
      end

      stmt = AST::UpdateStatement.new(name, assignments)
      stmt.schema = schema
      stmt.only = only
      stmt.alias_name = alias_name
      stmt.from = from
      stmt.where = where

      if token(:returning)
        stmt.returning = parse_column_list
      end

      stmt
    end

    private def parse_assignment : AST::Assignment
      column = consume(:identifier).value
      consume :eq
      AST::Assignment.new(column, parse_expr)
    end

    # CTEs

    private def parse_cte_definition : AST::CTEDefinition
      name = consume(:identifier).value

      # Optional column alias list: cte_name (col1, col2) AS (...)
      columns = nil
      if token(:l_paren)
        cols = [consume(:identifier).value]
        while token(:comma)
          cols << consume(:identifier).value
        end
        consume :r_paren
        columns = cols
      end

      consume :as
      # Optional MATERIALIZED / NOT MATERIALIZED hint
      materialized = nil
      if token(:not)
        consume_identifier("MATERIALIZED")
        materialized = false
      elsif current.type.identifier? && current.value.upcase == "MATERIALIZED"
        advance
        materialized = true
      end
      consume :l_paren
      query = parse_statement
      consume :r_paren

      cte = AST::CTEDefinition.new(name, query)
      cte.columns = columns
      cte.materialized = materialized
      cte
    end

    # Helpers

    private def parse_expr_list : Array(AST::Expr)
      exprs = [parse_expr]
      while token(:comma)
        exprs << parse_expr
      end
      exprs
    end

    # Like consume(:identifier) but also accepts keyword tokens, since PostgreSQL
    # allows most keywords to be used as bare names (column names, index names, etc.)
    private def consume_name : Token
      case current.type
      when .integer?, .float?, .string?, .dollar_param?,
           .eq?, .not_eq?, .lt?, .gt?, .lt_eq?, .gt_eq?,
           .plus?, .minus?, .star?, .slash?, .percent?,
           .concat?, .overlap?, .cast?,
           .arrow?, .arrow_text?, .contains?, .contained_by?, .text_search?,
           .tilde?, .tilde_star?, .not_tilde?, .not_tilde_star?,
           .power?, .bit_and?, .bit_or?, .shift_left?, .shift_right?,
           .json_path?, .json_path_text?,
           .dot?, .comma?, .semicolon?,
           .l_paren?, .r_paren?, .l_bracket?, .r_bracket?,
           .eof?
        raise ParseError.new("Expected identifier, got #{current.value.inspect} (#{current.type})", current)
      else
        current_then_advance
      end
    end

    private def consume_identifier(expected : String) : Token
      if current.type.identifier? && current.value.upcase == expected
        current_then_advance
      else
        raise ParseError.new("Expected #{expected}, got #{current.value.inspect} (#{current.type})", current)
      end
    end

    private def consume(type : TokenType) : Token
      if current.type == type
        current_then_advance
      else
        raise ParseError.new("Expected #{type}, got #{current.value.inspect} (#{current.type})", current)
      end
    end

    private def token(type : TokenType) : Bool
      if current.type == type
        advance
        true
      else
        false
      end
    end

    private def current : Token
      @tokens[@pos]
    end

    private def peek_type(offset : Int32, *types : TokenType) : Bool
      peek_type(offset).in? types
    end

    private def peek_type(offset : Int32) : TokenType
      idx = @pos + offset
      idx < @tokens.size ? @tokens[idx].type : TokenType::EOF
    end

    private def peek_value(offset : Int32) : String
      idx = @pos + offset
      idx < @tokens.size ? @tokens[idx].value : ""
    end

    private def advance
      @pos += 1 if @pos < @tokens.size - 1
    end

    private def current_then_advance : Token
      tok = current
      advance
      tok
    end

    # Words that cannot be bare aliases (they start the next clause)
    private STOP_WORDS = Set(TokenType){
      TokenType::Where, TokenType::From, TokenType::Join,
      TokenType::Inner, TokenType::Left, TokenType::Right,
      TokenType::Full, TokenType::Cross, TokenType::Natural,
      TokenType::On, TokenType::Using, TokenType::Group,
      TokenType::Order, TokenType::Having, TokenType::Limit,
      TokenType::Offset, TokenType::Union, TokenType::Except,
      TokenType::Intersect, TokenType::And, TokenType::Or,
      TokenType::With, TokenType::Recursive,
      TokenType::Insert, TokenType::Into, TokenType::Values,
      TokenType::Default, TokenType::Returning,
      TokenType::Update, TokenType::Set, TokenType::Only,
      TokenType::Delete,
      TokenType::Create, TokenType::Table, TokenType::Temp, TokenType::Temporary,
      TokenType::If, TokenType::Primary, TokenType::Key, TokenType::References,
      TokenType::Foreign, TokenType::Check, TokenType::Unique, TokenType::Constraint,
      TokenType::Alter, TokenType::Add, TokenType::Drop, TokenType::Column,
      TokenType::Rename, TokenType::To, TokenType::Cascade, TokenType::Restrict,
      TokenType::Index, TokenType::Concurrently,
      TokenType::View, TokenType::Truncate, TokenType::Sequence,
      TokenType::Schema, TokenType::Begin, TokenType::Commit, TokenType::Rollback,
      TokenType::EOF,
    }

    private def stop_word?(type : TokenType) : Bool
      STOP_WORDS.includes?(type)
    end
  end
end
