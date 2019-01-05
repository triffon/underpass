{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module LambdaCalculus.UserTerms where

import qualified Data.HashMap.Lazy as HM
import qualified Data.HashSet as HS
import           Control.Exception (throw, Exception)
import           Data.Dynamic (Typeable)

import qualified LambdaCalculus.LambdaTypes as T
import           LambdaCalculus.LambdaTypes (Ref(..), Typed(..))
import           LambdaCalculus.Lambda (LambdaTerm)
import qualified LambdaCalculus.Lambda as L
import           LambdaCalculus.UserTypeSystem
import           Utils.Resolver
import           Utils.Maths
import qualified Utils.Parsing as P

instance (Typed c t) => Typed (Ref c) (Ref t) where
    typeOf (UnresolvedName _ _)  = T.Bot
    typeOf (BasicRef  x)         = T.basicTransform BasicRef $ typeOf x

newtype ConstRef c = ConstRef (Ref c)

deriving newtype instance (Show c) => Show (ConstRef c)
deriving newtype instance (Eq c) => Eq (ConstRef c)
deriving newtype instance (PartialOrd c) => PartialOrd (ConstRef c)

instance (Eq t, PartialOrd t, Typed c t) => Typed (ConstRef c) (TypeWrapper t) where
    typeOf (ConstRef (BasicRef c)) = wrapType' $ typeOf c
    typeOf (ConstRef            _) = T.Bot

resolveTypes :: (Typed c t, Eq t, PartialOrd t) => TypeWrappers t -> LambdaTerm (Ref t) (Ref c) -> LambdaTerm (TypeWrapper t) (ConstRef c)
resolveTypes m = L.transformConst ConstRef (resolveBasicType m)

data CR c t = CR -- const resolver
instance (Eq t, PartialOrd t, Typed c t) => Resolvable (CR c t) where
    type Resolvee    (CR c t) = LambdaTerm (TypeWrapper t) (ConstRef c)
    type ResolveKey  (CR c t) = T.Name
    type Resolved    (CR c t) = LambdaTerm (TypeWrapper t) (ConstWrapper c)

    fv CR (L.Constant (ConstRef (T.BasicRef _))) = HS.empty
    fv CR (L.Constant (ConstRef (T.UnresolvedName _ name))) = HS.fromList [name]
    fv CR (L.Application a b) = HS.union (fv CR a) (fv CR b)
    fv CR (L.Lambda _ _ a) = fv CR a
    fv CR (L.Variable _) = HS.empty

    substituteAll CR m = L.transform resolveRef T.Basic
        where
            resolveRef (ConstRef (T.BasicRef x)) = L.Constant $ ConstWrapper x
            resolveRef (ConstRef (T.UnresolvedName pos name))
                | (Just c) <- HM.lookup name m = c
                | otherwise = throw $ NoSuchConst pos name

-- exceptions
data ConstException
    = NoSuchConst P.SourcePos T.Name
    deriving (Typeable, Exception, Show)
