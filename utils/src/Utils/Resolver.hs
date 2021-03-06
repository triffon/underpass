{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE StandaloneDeriving #-}

module Utils.Resolver where

-- import qualified Data.HashMap.Lazy as HM
import           Data.HashMap.Lazy (HashMap)
import qualified Data.HashMap.Lazy as HM
import qualified Data.HashSet as HS
import           Data.HashSet (HashSet)
import           Data.Hashable (Hashable)
import qualified Data.Graph as G
import           Utils.Exception (throw, Exception)
import           Data.Dynamic (Typeable)

type Library a = HashMap (ResolveKey a) (Resolved a)

class (Show a, Typeable a, Eq (ResolveKey a), Ord (ResolveKey a), Hashable (ResolveKey a), Show (ResolveKey a)) => Resolvable a where
    type ResolveKey a
    type Resolvee a
    type Resolved a

    fv :: a -> Resolvee a -> HashSet (ResolveKey a)

    substituteAll :: a -> Library a -> Resolvee a -> (Resolved a)

    preprocess :: a -> ResolveKey a -> Resolved a -> Resolved a
    preprocess _ _ = id

resolveLibrary :: (Resolvable a) => a -> [(ResolveKey a, Resolvee a)] -> Library a
resolveLibrary r = (resolveLibraryFromTable r) . (makeTable r)

resolveLibraryFromTable :: (Resolvable a) => a -> HashMap (ResolveKey a) (Resolvee a) -> Library a
resolveLibraryFromTable r plib = foldr (addToLibrary r) (emptyLib r) $ map (\k -> (k, plib HM.! k)) keys
    where
        keys = topoSort $ map (\(k, v) -> (k, HS.toList $ fv r v)) $ HM.toList plib

addToLibrary :: (Resolvable a) => a -> (ResolveKey a, Resolvee a) -> Library a -> Library a
addToLibrary r (k, v) lib = HM.insert k (preprocess r k $ resolveItem r lib v) lib

resolveItem :: (Resolvable a) => a -> Library a -> (Resolvee a) -> (Resolved a)
resolveItem = substituteAll -- maybe don't need a second name for this shit? just maybe?

getItem :: (Resolvable a) => a -> ResolveKey a -> Library a -> Maybe (Resolved a)
getItem _ key lib = HM.lookup key lib

emptyLib :: (Resolvable a) => a -> Library a
emptyLib _ = HM.empty

mergeLib :: (Resolvable a) => a -> Library a -> Library a -> Library a
mergeLib _ = HM.union

topoSort :: (Eq a, Ord a) => [(a, [a])] -> [a]
topoSort l = map (vertex . index) $ G.topSort graph
    where
        vertex ((), k, _) = k
        (graph, index, _) = G.graphFromEdges $ map (\(k, e) -> ((), k, e)) l

makeTable :: (Resolvable a) => a -> [(ResolveKey a, Resolvee a)] -> HashMap (ResolveKey a) (Resolvee a)
makeTable _ [] = HM.empty
makeTable r ((k, v):xs)
    | HM.member k rest = throw $ DefinedTwice r k
    | otherwise                        = HM.insert k v rest
    where
        rest = makeTable r xs

data ResolverException a
    = DefinedTwice a (ResolveKey a)
    | Loop         a [ResolveKey a] -- todo: throw this

    deriving (Typeable)

deriving instance (Resolvable a) => Show (ResolverException a)
deriving instance (Resolvable a) => Exception (ResolverException a)
