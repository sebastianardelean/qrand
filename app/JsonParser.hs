{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ViewPatterns      #-}

-- implementation made after Tsoding's JSON Parser available on https://github.com/tsoding/haskell-json/
module JsonParser
  (
    JsonValue
  , Input(..)
  , ParserError(..)
  , Parser(..)
  , jsonValue
  )
  
 where

import           Control.Applicative
import           Data.Char
import           Numeric


data Input = Input
  { inputLoc :: Int
  , inputStr :: String
  } deriving (Show, Eq)

-- | Pull the first character of the input if there is one still input
inputUncons :: Input                  -- input to check
            -> Maybe (Char, Input)
inputUncons (Input _ [])       = Nothing
inputUncons (Input loc (x:xs)) = Just (x, Input (loc + 1) xs)

data JsonValue
  = JsonNull
  | JsonBool Bool
  | JsonNumber Double
  | JsonString String
  | JsonArray [JsonValue]
  | JsonObject [(String, JsonValue)]
  deriving (Show, Eq)

data ParserError = ParserError Int String deriving (Show)

newtype Parser a = Parser
  { runParser :: Input -> Either ParserError (Input, a)
  }

instance Functor Parser where
  fmap f (Parser p) =
    Parser $ \input -> do
      (input', x) <- p input
      return (input', f x)

instance Applicative Parser where
  pure x = Parser $ \input -> Right (input, x)
  (Parser p1) <*> (Parser p2) =
    Parser $ \input -> do
      (input', f) <- p1 input
      (input'', a) <- p2 input'
      return (input'', f a)

instance Alternative (Either ParserError) where
  empty = Left $ ParserError 0 "empty"
  Left _ <|> e2 = e2
  e1 <|> _ = e1

instance Alternative Parser where
  empty = Parser $ const empty
  (Parser p1) <|> (Parser p2) =
    Parser $ \input -> p1 input <|> p2 input



-- | Create a parser for a single specific character
charP :: Char         -- The single character to find in the input
      -> Parser Char
charP x = Parser f
  where
    f input@(inputUncons -> Just (y, ys))
      | y == x = Right (ys, x)
      | otherwise =
        Left $
        ParserError
          (inputLoc input)
          ("Expected '" ++ [x] ++ "', but found '" ++ [y] ++ "'")
    f input =
      Left $
      ParserError
        (inputLoc input)
        ("Expected '" ++ [x] ++ "', but reached end of string")

-- | Create a parser for a specific string
stringP :: String         -- String to find in the input
        -> Parser String
stringP str =
  Parser $ \input ->
    case runParser (traverse charP str) input of
      Left _ ->
        Left $
        ParserError
          (inputLoc input)
          ("Expected \"" ++ str ++ "\", but found \"" ++ inputStr input ++ "\"")
      result -> result


-- | Parser of strings where all characters satifsfy a predicate
spanP :: String           -- description
      -> (Char -> Bool)   -- predicate
      -> Parser String
spanP desc = many . parseIf desc

-- | Parser of a character that satisfies a predicate
parseIf :: String         -- Description of the predicate
        -> (Char -> Bool) -- predicate
        -> Parser Char
parseIf desc f =
  Parser $ \input ->
    case input of
      (inputUncons -> Just (y, ys))
        | f y -> Right (ys, y)
        | otherwise ->
          Left $
          ParserError
            (inputLoc input)
            ("Expected " ++ desc ++ ", but found '" ++ [y] ++ "'")
      _ ->
        Left $
        ParserError
          (inputLoc input)
          ("Expected " ++ desc ++ ", but reached end of string")

{-
See page 12 of
http://www.ecma-international.org/publications/files/ECMA-ST/ECMA-404.pdf
-}
-- | Parser for doubles
doubleLiteral :: Parser Double
doubleLiteral =
  doubleFromParts
    <$> (minus <|> pure 1)
    <*> (read <$> digits)
    <*> ((read <$> (('0':) <$> ((:) <$> charP '.' <*> digits))) <|> pure 0)
    <*> ((e *> ((*) <$> (plus <|> minus <|> pure 1) <*> (read <$> digits))) <|> pure 0)
  where
    digits = some $ parseIf "digit" isDigit
    minus = (-1) <$ charP '-'
    plus = 1 <$ charP '+'
    e = charP 'e' <|> charP 'E'

-- | Build a Double from its parts (sign, integral part, decimal part, exponent)
doubleFromParts :: Integer  -- sign
                -> Integer  -- integral part
                -> Double   -- decimal part
                -> Integer  -- exponent
                -> Double
doubleFromParts sign int dec expo =
  fromIntegral sign * (fromIntegral int + dec) * (10 ^^ expo)



-- | Parser for characters as unicode in input
escapeUnicode :: Parser Char
escapeUnicode = chr . fst . head . readHex <$> sequenceA (replicate 4 (parseIf "hex digit" isHexDigit))

-- | Parser for characters that are scaped in the input
escapeChar :: Parser Char
escapeChar = ('"' <$ stringP "\\\"") <|>
             ('\\' <$ stringP "\\\\") <|>
             ('/' <$ stringP "\\/") <|>
             ('\b' <$ stringP "\\b") <|>
             ('\f' <$ stringP "\\f") <|>
             ('\n' <$ stringP "\\n") <|>
             ('\r' <$ stringP "\\r") <|>
             ('\t' <$ stringP "\\t") <|>
             (stringP "\\u" *> escapeUnicode)

-- | Parser of a character that is not " or \\
normalChar :: Parser Char
normalChar = parseIf "non-special character" ((&&) <$> (/= '"') <*> (/= '\\'))

-- | Parser of a string that is between double quotes (not considering any double quots that are scaped)
stringLiteral :: Parser String
stringLiteral = charP '"' *> many (normalChar <|> escapeChar) <* charP '"'

-- | Parser for white spaces
ws :: Parser String
ws = spanP "whitespace character" isSpace

-- | Creates a parser for a string of type "element1 sep1 element2 sep2 element3"
-- from a parser for separators (sep1, sep2) and and a parser form elements (element1, element2, element3).
sepBy :: Parser a   -- Parser for the separators
      -> Parser b   -- Parser for elements
      -> Parser [b]
sepBy sep element = (:) <$> element <*> many (sep *> element) <|> pure []

-- | Parser for null json
jsonNull :: Parser JsonValue
jsonNull = JsonNull <$ stringP "null"

-- | Create a parser for boolean values
jsonBool :: Parser JsonValue
jsonBool = jsonTrue <|> jsonFalse
  where
    jsonTrue = JsonBool True <$ stringP "true"
    jsonFalse = JsonBool False <$ stringP "false"



-- | Parser for json double values
jsonNumber :: Parser JsonValue
jsonNumber = JsonNumber <$> doubleLiteral

-- | Parser of literal json string values
jsonString :: Parser JsonValue
jsonString = JsonString <$> stringLiteral

-- | Parser for json arrays
jsonArray :: Parser JsonValue
jsonArray = JsonArray <$> (charP '[' *> ws *> elements <* ws <* charP ']')
  where
    elements = sepBy (ws *> charP ',' <* ws) jsonValue

-- | Parser for json objects
jsonObject :: Parser JsonValue
jsonObject =
  JsonObject <$>
  (charP '{' *> ws *> sepBy (ws *> charP ',' <* ws) pair <* ws <* charP '}')
  where
    pair = liftA2 (,) (stringLiteral <* ws <* charP ':' <* ws) jsonValue

-- | Parser for any json
jsonValue :: Parser JsonValue
jsonValue =
  jsonNull <|> jsonBool <|> jsonNumber <|> jsonString <|> jsonArray <|>
  jsonObject


