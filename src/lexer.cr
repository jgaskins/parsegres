require "./error"
require "./token"

module Parsegres
  class Lexer
    KEYWORDS = {
      "SELECT"       => TokenType::Select,
      "FROM"         => TokenType::From,
      "WHERE"        => TokenType::Where,
      "AND"          => TokenType::And,
      "OR"           => TokenType::Or,
      "NOT"          => TokenType::Not,
      "JOIN"         => TokenType::Join,
      "INNER"        => TokenType::Inner,
      "LEFT"         => TokenType::Left,
      "RIGHT"        => TokenType::Right,
      "FULL"         => TokenType::Full,
      "OUTER"        => TokenType::Outer,
      "CROSS"        => TokenType::Cross,
      "NATURAL"      => TokenType::Natural,
      "ON"           => TokenType::On,
      "USING"        => TokenType::Using,
      "AS"           => TokenType::As,
      "GROUP"        => TokenType::Group,
      "BY"           => TokenType::By,
      "HAVING"       => TokenType::Having,
      "ORDER"        => TokenType::Order,
      "ASC"          => TokenType::Asc,
      "DESC"         => TokenType::Desc,
      "NULLS"        => TokenType::Nulls,
      "FIRST"        => TokenType::First,
      "LAST"         => TokenType::Last,
      "LIMIT"        => TokenType::Limit,
      "OFFSET"       => TokenType::Offset,
      "IN"           => TokenType::In,
      "BETWEEN"      => TokenType::Between,
      "LIKE"         => TokenType::Like,
      "ILIKE"        => TokenType::ILike,
      "IS"           => TokenType::Is,
      "NULL"         => TokenType::Null,
      "CASE"         => TokenType::Case,
      "WHEN"         => TokenType::When,
      "THEN"         => TokenType::Then,
      "ELSE"         => TokenType::Else,
      "END"          => TokenType::End,
      "TRUE"         => TokenType::True,
      "FALSE"        => TokenType::False,
      "DISTINCT"     => TokenType::Distinct,
      "ALL"          => TokenType::All,
      "EXISTS"       => TokenType::Exists,
      "UNION"        => TokenType::Union,
      "EXCEPT"       => TokenType::Except,
      "INTERSECT"    => TokenType::Intersect,
      "WITH"         => TokenType::With,
      "RECURSIVE"    => TokenType::Recursive,
      "INSERT"       => TokenType::Insert,
      "INTO"         => TokenType::Into,
      "VALUES"       => TokenType::Values,
      "DEFAULT"      => TokenType::Default,
      "RETURNING"    => TokenType::Returning,
      "UPDATE"       => TokenType::Update,
      "SET"          => TokenType::Set,
      "ONLY"         => TokenType::Only,
      "DELETE"       => TokenType::Delete,
      "CREATE"       => TokenType::Create,
      "TABLE"        => TokenType::Table,
      "TEMP"         => TokenType::Temp,
      "TEMPORARY"    => TokenType::Temporary,
      "IF"           => TokenType::If,
      "PRIMARY"      => TokenType::Primary,
      "KEY"          => TokenType::Key,
      "REFERENCES"   => TokenType::References,
      "FOREIGN"      => TokenType::Foreign,
      "CHECK"        => TokenType::Check,
      "UNIQUE"       => TokenType::Unique,
      "CONSTRAINT"   => TokenType::Constraint,
      "ALTER"        => TokenType::Alter,
      "ADD"          => TokenType::Add,
      "DROP"         => TokenType::Drop,
      "COLUMN"       => TokenType::Column,
      "RENAME"       => TokenType::Rename,
      "TO"           => TokenType::To,
      "CASCADE"      => TokenType::Cascade,
      "RESTRICT"     => TokenType::Restrict,
      "INDEX"        => TokenType::Index,
      "CONCURRENTLY" => TokenType::Concurrently,
      "VIEW"         => TokenType::View,
      "TRUNCATE"     => TokenType::Truncate,
      "SEQUENCE"     => TokenType::Sequence,
      "SCHEMA"       => TokenType::Schema,
      "BEGIN"        => TokenType::Begin,
      "COMMIT"       => TokenType::Commit,
      "ROLLBACK"     => TokenType::Rollback,
      "EXTENSION"    => TokenType::Extension,
      "EXCLUDE"      => TokenType::Exclude,
      "TYPE"         => TokenType::Type,
      "DO"           => TokenType::Do,
      "OVER"         => TokenType::Over,
      "PARTITION"    => TokenType::Partition,
    }

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
                Token.new(TokenType::Eq, "=", start)
              when '<'
                advance
                if !at_end? && current_char == '='
                  advance
                  Token.new(TokenType::LtEq, "<=", start)
                elsif !at_end? && current_char == '>'
                  advance
                  Token.new(TokenType::NotEq, "<>", start)
                elsif !at_end? && current_char == '@'
                  advance
                  Token.new(TokenType::ContainedBy, "<@", start)
                elsif !at_end? && current_char == '<'
                  advance
                  Token.new(TokenType::ShiftLeft, "<<", start)
                else
                  Token.new(TokenType::Lt, "<", start)
                end
              when '>'
                advance
                if !at_end? && current_char == '='
                  advance
                  Token.new(TokenType::GtEq, ">=", start)
                elsif !at_end? && current_char == '>'
                  advance
                  Token.new(TokenType::ShiftRight, ">>", start)
                else
                  Token.new(TokenType::Gt, ">", start)
                end
              when '!'
                advance
                if !at_end? && current_char == '='
                  advance
                  Token.new(TokenType::NotEq, "!=", start)
                elsif !at_end? && current_char == '~'
                  advance
                  if !at_end? && current_char == '*'
                    advance
                    Token.new(TokenType::NotTildeStar, "!~*", start)
                  else
                    Token.new(TokenType::NotTilde, "!~", start)
                  end
                else
                  raise LexError.new("Unexpected '!' (did you mean '!=', '!~', or '!~*'?)", start)
                end
              when '+'
                advance; Token.new(TokenType::Plus, "+", start)
              when '-'
                advance
                if !at_end? && current_char == '>'
                  advance
                  if !at_end? && current_char == '>'
                    advance
                    Token.new(TokenType::ArrowText, "->>", start)
                  else
                    Token.new(TokenType::Arrow, "->", start)
                  end
                else
                  Token.new(TokenType::Minus, "-", start)
                end
              when '*'
                advance; Token.new(TokenType::Star, "*", start)
              when '/'
                advance; Token.new(TokenType::Slash, "/", start)
              when '%'
                advance; Token.new(TokenType::Percent, "%", start)
              when '#'
                advance
                if !at_end? && current_char == '>'
                  advance
                  if !at_end? && current_char == '>'
                    advance
                    Token.new(TokenType::JsonPathText, "#>>", start)
                  else
                    Token.new(TokenType::JsonPath, "#>", start)
                  end
                else
                  raise LexError.new("Unexpected '#' (did you mean '#>' or '#>>'?)", start)
                end
              when '&'
                advance
                if !at_end? && current_char == '&'
                  advance
                  Token.new(TokenType::Overlap, "&&", start)
                else
                  Token.new(TokenType::BitAnd, "&", start)
                end
              when '|'
                advance
                if !at_end? && current_char == '|'
                  advance
                  Token.new(TokenType::Concat, "||", start)
                else
                  Token.new(TokenType::BitOr, "|", start)
                end
              when ':'
                advance
                if !at_end? && current_char == ':'
                  advance
                  Token.new(TokenType::Cast, "::", start)
                else
                  raise LexError.new("Unexpected ':' (did you mean '::'?)", start)
                end
              when '('
                advance; Token.new(TokenType::LParen, "(", start)
              when ')'
                advance; Token.new(TokenType::RParen, ")", start)
              when '['
                advance; Token.new(TokenType::LBracket, "[", start)
              when ']'
                advance; Token.new(TokenType::RBracket, "]", start)
              when ','
                advance; Token.new(TokenType::Comma, ",", start)
              when ';'
                advance; Token.new(TokenType::Semicolon, ";", start)
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
                  Token.new(TokenType::Float, @chars[start...@pos].join, start)
                else
                  Token.new(TokenType::Dot, ".", start)
                end
              when '@'
                advance
                if !at_end? && current_char == '>'
                  advance
                  Token.new(TokenType::Contains, "@>", start)
                elsif !at_end? && current_char == '@'
                  advance
                  Token.new(TokenType::TextSearch, "@@", start)
                else
                  raise LexError.new("Unexpected '@' (did you mean '@>' or '@@'?)", start)
                end
              when '~'
                advance
                if !at_end? && current_char == '*'
                  advance
                  Token.new(TokenType::TildeStar, "~*", start)
                else
                  Token.new(TokenType::Tilde, "~", start)
                end
              when '^'
                advance; Token.new(TokenType::Power, "^", start)
              else
                raise LexError.new("Unexpected character #{ch.inspect}", start)
              end

        tokens << tok
      end

      tokens << Token.new(TokenType::EOF, "", @pos)
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
      Token.new(TokenType::String, io.to_s, start)
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
      Token.new(TokenType::Identifier, io.to_s, start)
    end

    private def scan_dollar(start : Int32) : Token
      advance # $
      if !at_end? && current_char.ascii_number?
        num_start = @pos
        while !at_end? && current_char.ascii_number?
          advance
        end
        Token.new(TokenType::DollarParam, @chars[num_start...@pos].join, start)
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
        Token.new(TokenType::String, io.to_s, start)
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
        Token.new(TokenType::Float, @chars[start...@pos].join, start)
      else
        Token.new(TokenType::Integer, @chars[start...@pos].join, start)
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
