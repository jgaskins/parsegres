module Parsegres
  class Lexer
    KEYWORDS = {
      "SELECT"       => :select,
      "FROM"         => :from,
      "WHERE"        => :where,
      "AND"          => :and,
      "OR"           => :or,
      "NOT"          => :not,
      "JOIN"         => :join,
      "INNER"        => :inner,
      "LEFT"         => :left,
      "RIGHT"        => :right,
      "FULL"         => :full,
      "OUTER"        => :outer,
      "CROSS"        => :cross,
      "NATURAL"      => :natural,
      "ON"           => :on,
      "USING"        => :using,
      "AS"           => :as,
      "GROUP"        => :group,
      "BY"           => :by,
      "HAVING"       => :having,
      "ORDER"        => :order,
      "ASC"          => :asc,
      "DESC"         => :desc,
      "NULLS"        => :nulls,
      "FIRST"        => :first,
      "LAST"         => :last,
      "LIMIT"        => :limit,
      "OFFSET"       => :offset,
      "IN"           => :in,
      "BETWEEN"      => :between,
      "LIKE"         => :like,
      "ILIKE"        => :i_like,
      "IS"           => :is,
      "NULL"         => :null,
      "CASE"         => :case,
      "WHEN"         => :when,
      "THEN"         => :then,
      "ELSE"         => :else,
      "END"          => :end,
      "TRUE"         => :true,
      "FALSE"        => :false,
      "DISTINCT"     => :distinct,
      "ALL"          => :all,
      "EXISTS"       => :exists,
      "UNION"        => :union,
      "EXCEPT"       => :except,
      "INTERSECT"    => :intersect,
      "WITH"         => :with,
      "RECURSIVE"    => :recursive,
      "INSERT"       => :insert,
      "INTO"         => :into,
      "VALUES"       => :values,
      "DEFAULT"      => :default,
      "RETURNING"    => :returning,
      "UPDATE"       => :update,
      "SET"          => :set,
      "ONLY"         => :only,
      "DELETE"       => :delete,
      "CREATE"       => :create,
      "TABLE"        => :table,
      "TEMP"         => :temp,
      "TEMPORARY"    => :temporary,
      "IF"           => :if,
      "PRIMARY"      => :primary,
      "KEY"          => :key,
      "REFERENCES"   => :references,
      "FOREIGN"      => :foreign,
      "CHECK"        => :check,
      "UNIQUE"       => :unique,
      "CONSTRAINT"   => :constraint,
      "ALTER"        => :alter,
      "ADD"          => :add,
      "DROP"         => :drop,
      "COLUMN"       => :column,
      "RENAME"       => :rename,
      "TO"           => :to,
      "CASCADE"      => :cascade,
      "RESTRICT"     => :restrict,
      "INDEX"        => :index,
      "CONCURRENTLY" => :concurrently,
      "VIEW"         => :view,
      "TRUNCATE"     => :truncate,
      "SEQUENCE"     => :sequence,
      "SCHEMA"       => :schema,
      "BEGIN"        => :begin,
      "COMMIT"       => :commit,
      "ROLLBACK"     => :rollback,
      "SAVEPOINT"    => :savepoint,
      "RELEASE"      => :release,
      "EXTENSION"    => :extension,
      "EXCLUDE"      => :exclude,
      "TYPE"         => :type,
      "DO"           => :do,
      "OVER"         => :over,
      "PARTITION"    => :partition,
    } of String => TokenType

    def initialize(@source : String)
      @chars = @source.chars
      @pos = 0
    end

    def tokenize : Array(Token)
      tokens = Array(Token).new
      loop do
        skip_whitespace_and_comments
        start = @pos
        break if at_end?

        ch = current_char

        tok = case ch
              when '\''
                scan_string(start)
              when '"'
                scan_quoted_identifier(start)
              when '$'
                scan_dollar(start)
              when .ascii_number?
                scan_number(start)
              when .ascii_letter?, '_'
                scan_word(start)
              when '='
                advance
                Token.new(:eq, "=", start)
              when '<'
                advance
                if !at_end? && current_char == '='
                  advance
                  Token.new(:lt_eq, "<=", start)
                elsif !at_end? && current_char == '>'
                  advance
                  Token.new(:not_eq, "<>", start)
                elsif !at_end? && current_char == '@'
                  advance
                  Token.new(:contained_by, "<@", start)
                elsif !at_end? && current_char == '<'
                  advance
                  Token.new(:shift_left, "<<", start)
                else
                  Token.new(:lt, "<", start)
                end
              when '>'
                advance
                if !at_end? && current_char == '='
                  advance
                  Token.new(:gt_eq, ">=", start)
                elsif !at_end? && current_char == '>'
                  advance
                  Token.new(:shift_right, ">>", start)
                else
                  Token.new(:gt, ">", start)
                end
              when '!'
                advance
                if !at_end? && current_char == '='
                  advance
                  Token.new(:not_eq, "!=", start)
                elsif !at_end? && current_char == '~'
                  advance
                  if !at_end? && current_char == '*'
                    advance
                    Token.new(:not_tilde_star, "!~*", start)
                  else
                    Token.new(:not_tilde, "!~", start)
                  end
                else
                  raise LexError.new("Unexpected '!' (did you mean '!=', '!~', or '!~*'?)", start)
                end
              when '+'
                advance
                Token.new(:plus, "+", start)
              when '-'
                advance
                if !at_end? && current_char == '>'
                  advance
                  if !at_end? && current_char == '>'
                    advance
                    Token.new(:arrow_text, "->>", start)
                  else
                    Token.new(:arrow, "->", start)
                  end
                else
                  Token.new(:minus, "-", start)
                end
              when '*'
                advance
                Token.new(:star, "*", start)
              when '/'
                advance
                Token.new(:slash, "/", start)
              when '%'
                advance
                Token.new(:percent, "%", start)
              when '#'
                advance
                if !at_end? && current_char == '>'
                  advance
                  if !at_end? && current_char == '>'
                    advance
                    Token.new(:json_path_text, "#>>", start)
                  else
                    Token.new(:json_path, "#>", start)
                  end
                else
                  raise LexError.new("Unexpected '#' (did you mean '#>' or '#>>'?)", start)
                end
              when '&'
                advance
                if !at_end? && current_char == '&'
                  advance
                  Token.new(:overlap, "&&", start)
                else
                  Token.new(:bit_and, "&", start)
                end
              when '|'
                advance
                if !at_end? && current_char == '|'
                  advance
                  Token.new(:concat, "||", start)
                else
                  Token.new(:bit_or, "|", start)
                end
              when ':'
                advance
                if !at_end? && current_char == ':'
                  advance
                  Token.new(:cast, "::", start)
                else
                  raise LexError.new("Unexpected ':' (did you mean '::'?)", start)
                end
              when '('
                advance
                Token.new(:l_paren, "(", start)
              when ')'
                advance
                Token.new(:r_paren, ")", start)
              when '['
                advance
                Token.new(:l_bracket, "[", start)
              when ']'
                advance
                Token.new(:r_bracket, "]", start)
              when ','
                advance
                Token.new(:comma, ",", start)
              when ';'
                advance
                Token.new(:semicolon, ";", start)
              when '.'
                advance
                if !at_end? && current_char.ascii_number?
                  while !at_end? && current_char.ascii_number?
                    advance
                  end
                  if !at_end? && (current_char == 'e' || current_char == 'E')
                    advance
                    advance if !at_end? && (current_char == '+' || current_char == '-')
                    while !at_end? && current_char.ascii_number?
                      advance
                    end
                  end
                  Token.new(:float, @chars[start...@pos].join, start)
                else
                  Token.new(:dot, ".", start)
                end
              when '@'
                advance
                if !at_end? && current_char == '>'
                  advance
                  Token.new(:contains, "@>", start)
                elsif !at_end? && current_char == '@'
                  advance
                  Token.new(:text_search, "@@", start)
                else
                  raise LexError.new("Unexpected '@' (did you mean '@>' or '@@'?)", start)
                end
              when '~'
                advance
                if !at_end? && current_char == '*'
                  advance
                  Token.new(:tilde_star, "~*", start)
                else
                  Token.new(:tilde, "~", start)
                end
              when '^'
                advance
                Token.new(:power, "^", start)
              else
                raise LexError.new("Unexpected character #{ch.inspect}", start)
              end

        tokens << tok
      end

      tokens << Token.new(:eof, "", @pos)
      tokens
    end

    private def scan_string(start : Int32) : Token
      advance # opening '
      io = IO::Memory.new
      loop do
        raise LexError.new("Unterminated string literal", start) if at_end?
        ch = current_char
        if ch == '\''
          advance
          if !at_end? && current_char == '\'' # escaped ''
            io << '\''
            advance
          else
            break
          end
        elsif ch == '\\'
          advance
          raise LexError.new("Unterminated string literal", start) if at_end?
          case current_char
          when 'n' ; io << '\n'
          when 't' ; io << '\t'
          when 'r' ; io << '\r'
          when '\\'; io << '\\'
          when '\''; io << '\''
          else       io << '\\'; io << current_char
          end
          advance
        else
          io << ch
          advance
        end
      end
      Token.new(:string, io.to_s, start)
    end

    private def scan_quoted_identifier(start : Int32) : Token
      advance # opening "
      io = IO::Memory.new
      loop do
        raise LexError.new("Unterminated quoted identifier", start) if at_end?
        ch = current_char
        if ch == '"'
          advance
          if !at_end? && current_char == '"'
            io << '"'
            advance
          else
            break
          end
        else
          io << ch
          advance
        end
      end
      Token.new(:identifier, io.to_s, start)
    end

    private def scan_dollar(start : Int32) : Token
      advance # $
      if !at_end? && current_char.ascii_number?
        num_start = @pos
        while !at_end? && current_char.ascii_number?
          advance
        end
        Token.new(:dollar_param, @chars[num_start...@pos].join, start)
      else
        # Dollar-quoted string: $tag$...$tag$  (tag may be empty: $$...$$)
        tag_start = @pos
        while !at_end? && (current_char.ascii_alphanumeric? || current_char == '_')
          advance
        end
        raise LexError.new("Unexpected '$' (expected digit for $N parameter or '$' for dollar-quote)", start) unless !at_end? && current_char == '$'
        tag = @chars[tag_start...@pos].join
        advance # consume the closing $ of the opening delimiter

        io = IO::Memory.new
        loop do
          raise LexError.new("Unterminated dollar-quoted string", start) if at_end?
          if current_char == '$'
            advance
            ctag_start = @pos
            while !at_end? && (current_char.ascii_alphanumeric? || current_char == '_')
              advance
            end
            ctag = @chars[ctag_start...@pos].join
            if !at_end? && current_char == '$' && ctag == tag
              advance # consume closing $
              break
            else
              # Not the closing delimiter — emit as content and continue
              io << '$'
              io << ctag
            end
          else
            io << current_char
            advance
          end
        end
        Token.new(:string, io.to_s, start)
      end
    end

    private def scan_number(start : Int32) : Token
      while !at_end? && current_char.ascii_number?
        advance
      end
      if !at_end? && current_char == '.' && peek_char != '.'
        advance # .
        while !at_end? && current_char.ascii_number?
          advance
        end
        if !at_end? && (current_char == 'e' || current_char == 'E')
          advance
          advance if !at_end? && (current_char == '+' || current_char == '-')
          while !at_end? && current_char.ascii_number?
            advance
          end
        end
        Token.new(:float, @chars[start...@pos].join, start)
      else
        Token.new(:integer, @chars[start...@pos].join, start)
      end
    end

    private def scan_word(start : Int32) : Token
      while !at_end? && (current_char.ascii_alphanumeric? || current_char == '_')
        advance
      end
      text = @chars[start...@pos].join
      kind = KEYWORDS[text.upcase]? || TokenType::Identifier
      Token.new(kind, text, start)
    end

    private def skip_whitespace_and_comments
      loop do
        skip_whitespace
        break if at_end?

        # -- line comment
        if current_char == '-' && peek_char == '-'
          while !at_end? && current_char != '\n'
            advance
          end
          next
        end

        # /* block comment */
        if current_char == '/' && peek_char == '*'
          @pos += 2
          loop do
            raise LexError.new("Unterminated block comment", @pos) if @pos + 1 >= @chars.size
            if @chars[@pos] == '*' && @chars[@pos + 1] == '/'
              @pos += 2
              break
            end
            @pos += 1
          end
          next
        end

        break
      end
    end

    private def skip_whitespace
      while !at_end? && current_char.ascii_whitespace?
        advance
      end
    end

    private def current_char : Char
      @chars[@pos]
    end

    private def peek_char : Char
      @pos + 1 < @chars.size ? @chars[@pos + 1] : '\0'
    end

    private def advance
      @pos += 1
    end

    private def at_end? : Bool
      @pos >= @chars.size
    end
  end
end
