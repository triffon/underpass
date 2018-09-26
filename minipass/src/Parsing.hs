{-# LANGUAGE OverloadedStrings #-}

module Parsing
    ( module Text.Megaparsec
    , module Text.Megaparsec.Char
    , module Text.Megaparsec.Expr
    , Parseable, Parser, parser
    , lexeme, symbol, lambda, braces, curlyBraces
    , operator, word, identifier, literal, quotedString
    , floatNumber
    , ps
    , pss
    ) where

import Text.Megaparsec
import Text.Megaparsec.Char
import Text.Megaparsec.Expr
import Text.Megaparsec.Error()
import qualified Text.Megaparsec.Char.Lexer as L

import Data.Text (Text)
import qualified Data.Text as T

data Error = Error deriving (Eq, Ord, Show)

type Parser = Parsec Error Text

class Parseable t where
    parser :: Parser t

instance ShowErrorComponent Error where
    showErrorComponent _ = ""

pss :: Parseable t => String -> t
pss = ps . T.pack

ps :: Parseable t => Text -> t
ps t = case parse (parser <* eof) "input" t of
    Right d     -> d
    Left errors -> error $ parseErrorPretty errors

sc :: Parser ()
sc = L.space space1 lineCmnt blockCmnt
  where
    lineCmnt  = L.skipLineComment "//"
    blockCmnt = L.skipBlockComment "/*" "*/"

lexeme :: Parser a -> Parser a
lexeme = L.lexeme sc

symbol :: Text -> Parser Text
symbol = L.symbol sc

lambda :: Parser Text
lambda = symbol "λ"

braces :: Parser a -> Parser a
braces = between (symbol "(") (symbol ")")

curlyBraces :: Parser a -> Parser a
curlyBraces = between (symbol "{") (symbol "}")

word :: Parser a -> Parser a
word x = (lexeme . try) (x <* notFollowedBy alphaNumChar)

literal :: Text -> Parser Text
literal = (lexeme . try) . string

operator :: Text -> Parser Text
operator = literal

identifier :: Parser Text
identifier = T.pack <$> ((lexeme . try) $ ((:) <$> letterChar) <*> (many alphaNumChar))

quotedString :: Char -> Parser Text
quotedString quote = (lexeme . try) $ do
    _     <- char quote
    chars <- many character
    _     <- char quote
    return $ T.pack $ concat chars

    where
        character = return <$> nonEscaped <|> escaped

        escaped = do
            d <- char '\\'
            c <- oneOf [quote, '\\']
            return [d, c]

        nonEscaped = noneOf [quote, '\\']

floatNumber :: Parser Float
floatNumber = (lexeme . try) $ L.signed sc (lexeme ((try L.float) <|> (toFloat <$> (try L.decimal))))
    where
        toFloat :: Int -> Float
        toFloat = fromIntegral
