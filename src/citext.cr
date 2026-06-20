module Parsegres
  struct CIText
    getter string : String

    def self.[](string : String)
      new string
    end

    def initialize(@string)
    end

    def hash(hasher)
      @string.each_char do |char|
        hasher = char.upcase.hash(hasher)
      end
      hasher
    end

    def ==(other : self)
      string.compare(other.string, case_insensitive: true) == 0
    end
  end
end
