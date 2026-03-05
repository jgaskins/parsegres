require "./token"
require "./error"
require "./ast"
require "./lexer"
require "./parser"
require "./printer"

module Parsegres
  VERSION = "0.1.0"

  # Parse a SQL string and return the AST root.
  # Returns AST::SelectStatement for simple queries and AST::CompoundSelect
  # for queries that use UNION / INTERSECT / EXCEPT.
  # Raises Parsegres::LexError or Parsegres::ParseError on invalid input.
  def self.parse(sql : String) : AST::Statement
    Parser.parse(sql)
  end
end
