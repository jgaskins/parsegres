require "./token"
require "./citext"

module Parsegres
  class Lexer
    KEYWORDS = {
      CIText["SELECT"]       => :select,
      CIText["FROM"]         => :from,
      CIText["WHERE"]        => :where,
      CIText["AND"]          => :and,
      CIText["OR"]           => :or,
      CIText["NOT"]          => :not,
      CIText["JOIN"]         => :join,
      CIText["INNER"]        => :inner,
      CIText["LEFT"]         => :left,
      CIText["RIGHT"]        => :right,
      CIText["FULL"]         => :full,
      CIText["OUTER"]        => :outer,
      CIText["CROSS"]        => :cross,
      CIText["NATURAL"]      => :natural,
      CIText["ON"]           => :on,
      CIText["USING"]        => :using,
      CIText["AS"]           => :as,
      CIText["GROUP"]        => :group,
      CIText["BY"]           => :by,
      CIText["HAVING"]       => :having,
      CIText["ORDER"]        => :order,
      CIText["ASC"]          => :asc,
      CIText["DESC"]         => :desc,
      CIText["NULLS"]        => :nulls,
      CIText["FIRST"]        => :first,
      CIText["LAST"]         => :last,
      CIText["LIMIT"]        => :limit,
      CIText["OFFSET"]       => :offset,
      CIText["IN"]           => :in,
      CIText["BETWEEN"]      => :between,
      CIText["LIKE"]         => :like,
      CIText["ILIKE"]        => :i_like,
      CIText["IS"]           => :is,
      CIText["NULL"]         => :null,
      CIText["CASE"]         => :case,
      CIText["WHEN"]         => :when,
      CIText["THEN"]         => :then,
      CIText["ELSE"]         => :else,
      CIText["END"]          => :end,
      CIText["TRUE"]         => :true,
      CIText["FALSE"]        => :false,
      CIText["DISTINCT"]     => :distinct,
      CIText["ALL"]          => :all,
      CIText["EXISTS"]       => :exists,
      CIText["UNION"]        => :union,
      CIText["EXCEPT"]       => :except,
      CIText["INTERSECT"]    => :intersect,
      CIText["WITH"]         => :with,
      CIText["RECURSIVE"]    => :recursive,
      CIText["INSERT"]       => :insert,
      CIText["INTO"]         => :into,
      CIText["VALUES"]       => :values,
      CIText["DEFAULT"]      => :default,
      CIText["RETURNING"]    => :returning,
      CIText["UPDATE"]       => :update,
      CIText["SET"]          => :set,
      CIText["ONLY"]         => :only,
      CIText["DELETE"]       => :delete,
      CIText["CREATE"]       => :create,
      CIText["TABLE"]        => :table,
      CIText["TEMP"]         => :temp,
      CIText["TEMPORARY"]    => :temporary,
      CIText["IF"]           => :if,
      CIText["PRIMARY"]      => :primary,
      CIText["KEY"]          => :key,
      CIText["REFERENCES"]   => :references,
      CIText["FOREIGN"]      => :foreign,
      CIText["CHECK"]        => :check,
      CIText["UNIQUE"]       => :unique,
      CIText["CONSTRAINT"]   => :constraint,
      CIText["ALTER"]        => :alter,
      CIText["ADD"]          => :add,
      CIText["DROP"]         => :drop,
      CIText["COLUMN"]       => :column,
      CIText["RENAME"]       => :rename,
      CIText["TO"]           => :to,
      CIText["CASCADE"]      => :cascade,
      CIText["RESTRICT"]     => :restrict,
      CIText["INDEX"]        => :index,
      CIText["CONCURRENTLY"] => :concurrently,
      CIText["VIEW"]         => :view,
      CIText["TRUNCATE"]     => :truncate,
      CIText["SEQUENCE"]     => :sequence,
      CIText["SCHEMA"]       => :schema,
      CIText["BEGIN"]        => :begin,
      CIText["COMMIT"]       => :commit,
      CIText["ROLLBACK"]     => :rollback,
      CIText["SAVEPOINT"]    => :savepoint,
      CIText["RELEASE"]      => :release,
      CIText["EXTENSION"]    => :extension,
      CIText["EXCLUDE"]      => :exclude,
      CIText["TYPE"]         => :type,
      CIText["DO"]           => :do,
      CIText["OVER"]         => :over,
      CIText["PARTITION"]    => :partition,
    } of CIText => TokenType

    def initialize(@source : String)
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
                  Token.new(:float, @source[start...@pos], start)
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
      string = String.build do |str|
        loop do
          raise LexError.new("Unterminated string literal", start) if at_end?
          ch = current_char
          if ch == '\''
            advance
            if !at_end? && current_char == '\'' # escaped ''
              str << '\''
              advance
            else
              break
            end
          elsif ch == '\\'
            advance
            raise LexError.new("Unterminated string literal", start) if at_end?
            case current_char
            when 'n'  then str << '\n'
            when 't'  then str << '\t'
            when 'r'  then str << '\r'
            when '\\' then str << '\\'
            when '\'' then str << '\''
            else           str << '\\' << current_char
            end
            advance
          else
            str << ch
            advance
          end
        end
      end
      Token.new(:string, string, start)
    end

    private def scan_quoted_identifier(start : Int32) : Token
      advance # opening "
      string = String.build do |str|
        loop do
          raise LexError.new("Unterminated quoted identifier", start) if at_end?
          ch = current_char
          if ch == '"'
            advance
            if !at_end? && current_char == '"'
              str << '"'
              advance
            else
              break
            end
          else
            str << ch
            advance
          end
        end
      end
      Token.new(:identifier, string, start)
    end

    private def scan_dollar(start : Int32) : Token
      advance # $
      if !at_end? && current_char.ascii_number?
        num_start = @pos
        while !at_end? && current_char.ascii_number?
          advance
        end
        Token.new(:dollar_param, @source[num_start...@pos], start)
      else
        # Dollar-quoted string: $tag$...$tag$  (tag may be empty: $$...$$)
        tag_start = @pos
        while !at_end? && (current_char.ascii_alphanumeric? || current_char == '_')
          advance
        end
        raise LexError.new("Unexpected '$' (expected digit for $N parameter or '$' for dollar-quote)", start) unless !at_end? && current_char == '$'
        tag = @source[tag_start...@pos]
        advance # consume the closing $ of the opening delimiter

        string = String.build do |str|
          loop do
            raise LexError.new("Unterminated dollar-quoted string", start) if at_end?
            if current_char == '$'
              advance
              ctag_start = @pos
              while !at_end? && (current_char.ascii_alphanumeric? || current_char == '_')
                advance
              end
              ctag = @source[ctag_start...@pos]
              if !at_end? && current_char == '$' && ctag == tag
                advance # consume closing $
                break
              else
                # Not the closing delimiter — emit as content and continue
                str << '$'
                str << ctag
              end
            else
              str << current_char
              advance
            end
          end
        end
        Token.new(:string, string, start)
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
        if !at_end? && current_char.downcase == 'e'
          advance
          advance if !at_end? && current_char.in?({'+', '-'})
          while !at_end? && current_char.ascii_number?
            advance
          end
        end
        Token.new(:float, @source[start...@pos], start)
      else
        Token.new(:integer, @source[start...@pos], start)
      end
    end

    private def scan_word(start : Int32) : Token
      while !at_end? && (current_char.ascii_alphanumeric? || current_char == '_')
        advance
      end
      text = @source[start...@pos]
      kind = KEYWORDS.fetch(CIText.new(text), TokenType::Identifier)
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
            raise LexError.new("Unterminated block comment", @pos) if @pos + 1 >= @source.size
            if @source[@pos] == '*' && @source[@pos + 1] == '/'
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
      @source[@pos]
    end

    private def peek_char : Char
      @pos + 1 < @source.size ? @source[@pos + 1] : '\0'
    end

    private def advance
      @pos += 1
    end

    private def at_end? : Bool
      @pos >= @source.size
    end
  end
end
