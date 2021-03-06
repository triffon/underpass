{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveGeneric #-}

module LambdaCalculus.Lambda where

import           Utils.Exception (Exception, throw)
import           Data.Dynamic (Typeable)
import           GHC.Generics (Generic)
import           Data.Hashable (Hashable(..))
import           Data.Aeson (ToJSON(..), object, (.=))
import           Control.Monad (fail)
import qualified Data.Text as Text
import           Data.Text (Text)

import           Utils.Maths
import           Utils.Parsing (Parser, Parseable, parser, (<|>))
import qualified Utils.Parsing as P

import qualified LambdaCalculus.LambdaTypes as T
import           LambdaCalculus.LambdaTypes (Typed, typeOf)
import           LambdaCalculus.Context



data LambdaTerm t c where
    Constant    :: Typed c t => c                   -> LambdaTerm t c
    Application :: Typed c t => LambdaTerm t c      -> LambdaTerm t c      -> LambdaTerm t c
    Lambda      :: Typed c t => VarName             -> T.ApplicativeType t -> LambdaTerm t c -> LambdaTerm t c
    Variable    :: Typed c t => Index               -> LambdaTerm t c
    Cast        :: Typed c t => T.ApplicativeType t -> LambdaTerm t c      -> LambdaTerm t c

instance (Show t, Show c) => Show (LambdaTerm t c) where
    show = showTerm emptyContext

showTerm :: (Show t, Show c) => VarContext t -> LambdaTerm t c -> String
showTerm _ (Constant c) = show c
showTerm context (Application a b) = "(" <> showTerm context a <> " " <> showTerm context b <> ")"
showTerm context (Lambda x t a) = "λ " <> Text.unpack x <> ": " <> show t <> " ⇒ " <> showTerm (push (x, t) context) a
showTerm context (Variable i)
    | Just (x, _) <- at i context = Text.unpack x
    | otherwise = "<var " <> show i <> ">"
showTerm context (Cast t x) = show t <> "[" <> showTerm context x <> "]"


instance (MSemiLattice (T.ApplicativeType t), Typed c t) => Typed (LambdaTerm t c) t where
    typeOf = typeOfTerm True emptyContext

typeOfTerm :: (MSemiLattice (T.ApplicativeType t), Typed c t) => Bool -> VarContext t -> LambdaTerm t c -> T.ApplicativeType t
typeOfTerm _ _ (Constant c) = typeOf c
typeOfTerm safe context (Application a b)
    | safe,     tb <!  p = q
    | not safe, tb <!> p = q
    | otherwise = throw $ CannotApply (a, ta) (b, tb)
    where
        (p, q) = T.inferApp ta
        ta = typeOfTerm safe context a
        tb = typeOfTerm safe context b
typeOfTerm safe context (Lambda x t a) = T.Application t (typeOfTerm safe (push (x, t) context) a)
typeOfTerm _ context (Variable i)
    | Just (_, t) <- at i context = t
    | otherwise = throw $ UnknownVar i
typeOfTerm _ _ (Cast t _) = t

transform :: (Typed c1 t1, Typed c2 t2) => (c1 -> LambdaTerm t2 c2) -> (t1 -> T.ApplicativeType t2) -> LambdaTerm t1 c1 -> LambdaTerm t2 c2
transform f _ (Constant c)      = f c
transform f g (Application a b) = Application (transform f g a) (transform f g b)
transform f g (Lambda x t a)    = Lambda x (T.transform g t) (transform f g a)
transform _ _ (Variable i)      = Variable i
transform f g (Cast t x)        = Cast (T.transform g t) (transform f g x)

transformConst :: (Typed c1 t1, Typed c2 t2) => (c1 -> c2) -> (t1 -> T.ApplicativeType t2) -> LambdaTerm t1 c1 -> LambdaTerm t2 c2
transformConst f _ (Constant c)      = Constant $ f c
transformConst f g (Application a b) = Application (transformConst f g a) (transformConst f g b)
transformConst f g (Lambda x t a)    = Lambda x (T.transform g t) (transformConst f g a)
transformConst _ _ (Variable i)      = Variable i
transformConst f g (Cast t x)        = Cast (T.transform g t) (transformConst f g x)


removeUselessCasts :: (Eq t, Typed c t) => LambdaTerm t c -> LambdaTerm t c
removeUselessCasts = removeUselessCasts' emptyContext

removeUselessCasts' :: (Eq t, Typed c t) => VarContext t -> LambdaTerm t c -> LambdaTerm t c
removeUselessCasts' context (Cast t x)
    | tx == t   = x'
    | otherwise = Cast t x'
    where
        tx = typeOfTerm False context x
        x' = removeUselessCasts' context x
removeUselessCasts' context (Application a b) = Application (removeUselessCasts' context a) (removeUselessCasts' context b)
removeUselessCasts' context (Lambda x t a)    = Lambda x t (removeUselessCasts' (push (x, t) context) a)
removeUselessCasts' _ term = term

apply :: Typed c t => [LambdaTerm t c] -> LambdaTerm t c
apply = foldl1 Application

instance (Parseable t, Parseable c, Typed c t) => Parseable (LambdaTerm t c) where
    parser = fst <$> parseTerm emptyContext

parseTerm :: (Parseable t, Parseable c, Typed c t) => VarContext t -> Parser (LambdaTerm t c, T.ApplicativeType t)
parseTerm = parseApplication

parseNonApplication :: (Parseable t, Parseable c, Typed c t) => VarContext t -> Parser (LambdaTerm t c, T.ApplicativeType t)
parseNonApplication context
    =   parseLambda context
    <|> parseCast context
    <|> parseVariable context
    <|> parseConstant
    <|> P.braces (parseTerm context)

parseConstant :: (Parseable t, Parseable c, Typed c t) => Parser (LambdaTerm t c, T.ApplicativeType t)
parseConstant = do
    c <- Constant <$> parser
    return (c, typeOf c)

parseLambda :: (Parseable t, Parseable c, Typed c t) => VarContext t -> Parser (LambdaTerm t c, T.ApplicativeType t)
parseLambda context = do
    _                <- P.word "lambda" <|> P.operator "\\" <|> P.operator "λ"
    declarations     <- P.sepBy1 parseVariableDeclaration (P.operator ",")
    _                <- P.operator "=>" <|> P.operator "⇒"
    term             <- parseTerm (foldr push context $ reverse declarations)
    pure $ makeAbstraction declarations term

makeAbstraction :: Typed c t => [(VarName, T.ApplicativeType t)] -> (LambdaTerm t c, T.ApplicativeType t) -> (LambdaTerm t c, T.ApplicativeType t)
makeAbstraction [] t = t
makeAbstraction ((var, varType):rest) t = (Lambda var varType term, T.Application varType termType)
    where
        (term, termType) = makeAbstraction rest t

parseCast :: (Parseable t, Parseable c, Typed c t) => VarContext t -> Parser (LambdaTerm t c, T.ApplicativeType t)
parseCast context = P.try $ do
    newType          <- parser
    _                <- P.operator "["
    (term, termType) <- parseTerm context
    _                <- P.operator "]"
    pure $ case newType <!> termType of
        True  -> (Cast newType term, newType)
        False -> throw $ CannotCast (term, termType) newType

parseApplication :: (Parseable t, Parseable c, Typed c t) => VarContext t -> Parser (LambdaTerm t c, T.ApplicativeType t)
parseApplication context = foldl1 makeApplication
    <$> P.some (parseNonApplication context)
    where
        makeApplication left@(x, ab) right@(y, c)
            | c <!> a               = (Application x y, b)
            | otherwise             = throw $ CannotApply left right
            where (a, b) = T.inferApp ab

parseVariableDeclaration :: (Parseable t) => Parser (VarName, T.ApplicativeType t)
parseVariableDeclaration =
        P.try (do
        var     <- parseVariableName
        _       <- P.operator ":"
        varType <- parser
        return (var, varType))
    <|> P.try (do
        var     <- parseVariableName
        return (var, bot)
    )

parseVariable :: (Parseable t, Parseable c, Typed c t) => VarContext t -> Parser (LambdaTerm t c, T.ApplicativeType t)
parseVariable context = P.try $ do
    name <- parseVariableName
    case get name context of
        Just (i, t) -> return (Variable i, t)
        Nothing     -> fail $ "variable or identifier does not exist: " <> Text.unpack name

parseVariableName :: Parser VarName
parseVariableName = P.identifier

letLambda :: Typed c t => VarName -> LambdaTerm t c -> LambdaTerm t c -> LambdaTerm t c
letLambda x a b = Application (Lambda x (typeOf a) b) a

letLambdaN :: Typed c t => [(VarName, LambdaTerm t c)] -> LambdaTerm t c -> LambdaTerm t c
letLambdaN l a = foldr f a l
    where
        f (x, b) = letLambda x b

letContextN :: Typed c t => [(VarName, LambdaTerm t c)] -> VarContext t
letContextN = foldl (flip f) emptyContext
    where
        f (x, b) = push (x, typeOf b)

parseWrap :: (Typed c t, Parseable c, Parseable t) => [(VarName, LambdaTerm t c)] -> Parser (LambdaTerm t c)
parseWrap l = letLambdaN l . fst <$> parseTerm (letContextN l)

up :: Typed c t => LambdaTerm t c -> Index -> LambdaTerm t c
up to n = up' to n 0

up' :: Typed c t => LambdaTerm t c -> Index -> Index -> LambdaTerm t c
up' (Variable x) d c
    | x >= c = Variable (x + d)
    | otherwise = Variable x
up' (Application m n) d c = Application (up' m d c) (up' n d c)
up' (Lambda t x m) d c = Lambda t x (up' m d (c + 1))
up' (Constant m) _ _ = Constant m
up' (Cast t m) d c = Cast t (up' m d c)

data LambdaException t c
    = CannotApply  (LambdaTerm t c, T.ApplicativeType t) (LambdaTerm t c, T.ApplicativeType t)
    | CannotCast   (LambdaTerm t c, T.ApplicativeType t) (T.ApplicativeType t)
    deriving (Typeable)

newtype VarException
    = UnknownVar Index
    deriving (Show, Typeable)

deriving instance (Show t, Show c) => Show (LambdaException t c)

deriving instance (Eq t, Eq c) => Eq (LambdaTerm t c)

-- hashing
data LHashBin = HVariable | HApplication | HLambda | HConstant | HCast deriving (Generic)

instance Hashable LHashBin

instance (Hashable t, Hashable c) => Hashable (LambdaTerm t c) where
    hashWithSalt salt (Variable x)      = hashWithSalt salt (HVariable, x)
    hashWithSalt salt (Lambda t x m)    = hashWithSalt salt (HLambda, t, x, m)
    hashWithSalt salt (Application m n) = hashWithSalt salt (HApplication, m, n)
    hashWithSalt salt (Constant m)      = hashWithSalt salt (HConstant, m)
    hashWithSalt salt (Cast t m)        = hashWithSalt salt (HCast, t, m)

instance (Show t, Show c, Typeable t, Typeable c) => Exception (LambdaException t c)
instance Exception VarException

-- json

instance (ToJSON t, ToJSON c) => ToJSON (LambdaTerm t c) where
    toJSON (Variable x)      = object ["_t" .= ("variable" :: Text),    "index" .= x]
    toJSON (Application m n) = object ["_t" .= ("application" :: Text), "left"  .= m, "right"   .= n]
    toJSON (Lambda t x m)    = object ["_t" .= ("lambda" :: Text),      "type"  .= t, "varname" .= x, "subterm" .= m]
    toJSON (Constant c)      = object ["_t" .= ("constant" :: Text),    "name"  .= c]
    toJSON (Cast t m)        = object ["_t" .= ("cast" :: Text),        "type"  .= t, "subterm" .= m]

