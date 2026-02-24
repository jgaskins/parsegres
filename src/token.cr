module Parsegres
  enum TokenType
    # Literals
    Integer
    Float
    String
    DollarParam # $1, $2, ...

    # Identifiers
    Identifier

    # Keywords
    Select; From; Where; And; Or; Not
    Join; Inner; Left; Right; Full; Outer; Cross; Natural
    On; Using; As
    Group; By; Having
    Order; Asc; Desc; Nulls; First; Last
    Limit; Offset
    In; Between; Like; ILike; Is; Null
    Case; When; Then; Else; End
    True; False
    Distinct; All
    Exists
    Union; Except; Intersect
    With; Recursive
    Insert; Into; Values; Default; Returning
    Update; Set; Only
    Delete
    Create; Table; Temp; Temporary; If
    Primary; Key; References; Foreign; Check; Unique; Constraint
    Alter; Add; Drop; Column; Rename; To; Cascade; Restrict
    Index; Concurrently
    View; Truncate; Sequence; Schema; Begin; Commit; Rollback
    Extension; Exclude; Type; Do
    Over; Partition

    # Operators
    Eq           # =
    NotEq        # <> or !=
    Lt           # <
    Gt           # >
    LtEq         # <=
    GtEq         # >=
    Plus         # +
    Minus        # -
    Star         # *
    Slash        # /
    Percent      # %
    Concat       # ||
    Overlap      # &&
    JsonPath     # #>
    JsonPathText # #>>
    Arrow        # ->
    ArrowText    # ->>
    Contains     # @>
    ContainedBy  # <@
    TextSearch   # @@
    Tilde        # ~  (binary: regex match; unary: bitwise NOT)
    TildeStar    # ~* (case-insensitive regex match)
    NotTilde     # !~
    NotTildeStar # !~*
    Power        # ^
    BitAnd       # &
    BitOr        # |
    ShiftLeft    # <<
    ShiftRight   # >>
    Cast         # ::

    # Punctuation
    Dot
    Comma
    Semicolon
    LParen
    RParen
    LBracket
    RBracket

    EOF
  end

  record Token, type : TokenType, value : ::String, pos : Int32
end
