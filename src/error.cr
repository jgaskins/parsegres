module Parsegres
  class Error < Exception; end

  class LexError < Error
    getter position : Int32

    def initialize(message : String, @position : Int32)
      super(message)
    end
  end

  class ParseError < Error
    getter token : Token

    def initialize(message : String, @token : Token)
      super(message)
    end
  end
end
