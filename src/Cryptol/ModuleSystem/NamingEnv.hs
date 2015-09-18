-- |
-- Module      :  $Header$
-- Copyright   :  (c) 2013-2015 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable

{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE CPP #-}

module Cryptol.ModuleSystem.NamingEnv where

import Cryptol.ModuleSystem.Interface
import Cryptol.ModuleSystem.Name
import Cryptol.Parser.AST
import Cryptol.Parser.Names (namesP)
import Cryptol.Parser.Position
import qualified Cryptol.TypeCheck.AST as T
import Cryptol.Utils.PP
import Cryptol.Utils.Panic (panic)

import Data.Maybe (catMaybes,fromMaybe)
import qualified Data.Map as Map

import GHC.Generics (Generic)
import Control.DeepSeq

#if __GLASGOW_HASKELL__ < 710
import Control.Applicative (Applicative, (<$>), (<*>), pure)
import Data.Monoid (Monoid(..))
import Data.Foldable (foldMap)
import Data.Traversable (traverse)
#endif


-- Naming Environment ----------------------------------------------------------

-- XXX The fixity environment should be removed, and Name should include fixity
-- information.
data NamingEnv = NamingEnv { neExprs :: Map.Map PName [Name]
                             -- ^ Expr renaming environment
                           , neTypes :: Map.Map PName [Name]
                             -- ^ Type renaming environment
                           , neFixity:: Map.Map Name [Fixity]
                             -- ^ Expression-level fixity environment
                           } deriving (Show, Generic)

instance NFData NamingEnv

instance Monoid NamingEnv where
  mempty        =
    NamingEnv { neExprs  = Map.empty
              , neTypes  = Map.empty
              , neFixity = Map.empty }

  mappend l r   =
    NamingEnv { neExprs  = Map.unionWith (++) (neExprs  l) (neExprs  r)
              , neTypes  = Map.unionWith (++) (neTypes  l) (neTypes  r)
              , neFixity = Map.unionWith (++) (neFixity l) (neFixity r) }

  mconcat envs  =
    NamingEnv { neExprs  = Map.unionsWith (++) (map neExprs  envs)
              , neTypes  = Map.unionsWith (++) (map neTypes  envs)
              , neFixity = Map.unionsWith (++) (map neFixity envs) }


-- | Singleton type renaming environment.
singletonT :: PName -> Name -> NamingEnv
singletonT qn tn = mempty { neTypes = Map.singleton qn [tn] }

-- | Singleton expression renaming environment.
singletonE :: PName -> Name -> NamingEnv
singletonE qn en = mempty { neExprs = Map.singleton qn [en] }

-- | Like mappend, but when merging, prefer values on the lhs.
shadowing :: NamingEnv -> NamingEnv -> NamingEnv
shadowing l r = NamingEnv
  { neExprs  = Map.union (neExprs  l) (neExprs  r)
  , neTypes  = Map.union (neTypes  l) (neTypes  r)
  , neFixity = Map.union (neFixity l) (neFixity r) }

travNamingEnv :: Applicative f => (Name -> f Name) -> NamingEnv -> f NamingEnv
travNamingEnv f ne = NamingEnv <$> neExprs' <*> neTypes' <*> pure (neFixity ne)
  where
    neExprs' = traverse (traverse f) (neExprs ne)
    neTypes' = traverse (traverse f) (neTypes ne)

-- | Things that define exported names.
class BindsNames a where
  namingEnv :: a -> SupplyM NamingEnv

instance BindsNames NamingEnv where
  namingEnv = return

instance BindsNames a => BindsNames (Maybe a) where
  namingEnv = foldMap namingEnv

instance BindsNames a => BindsNames [a] where
  namingEnv = foldMap namingEnv

-- | Generate a type renaming environment from the parameters that are bound by
-- this schema.
instance BindsNames (Schema PName) where
  namingEnv (Forall ps _ _ _) = foldMap namingEnv ps

-- -- | Produce a naming environment from an interface file, that contains a
-- -- mapping only from unqualified names to qualified ones.
-- instance BindsNames Iface where
--   namingEnv = namingEnv . ifPublic

-- -- | Translate a set of declarations from an interface into a naming
-- -- environment.
-- instance BindsNames IfaceDecls where
--   namingEnv binds = mconcat [ types, newtypes, vars ]
--     where

--     types = mempty
--       { neTypes = Map.map (map (TFromMod . ifTySynName)) (ifTySyns binds)
--       }

--     newtypes = mempty
--       { neTypes = Map.map (map (TFromMod . T.ntName)) (ifNewtypes binds)
--       , neExprs = Map.map (map (EFromMod . T.ntName)) (ifNewtypes binds)
--       }

--     vars = mempty
--       { neExprs  = Map.map (map (EFromMod . ifDeclName)) (ifDecls binds)
--       , neFixity = Map.fromList [ (n,fs) | ds <- Map.elems (ifDecls binds)
--                                          , all ifDeclInfix ds
--                                          , let fs = catMaybes (map ifDeclFixity ds)
--                                                n  = ifDeclName (head ds) ]
--       }


-- -- | Translate names bound by the patterns of a match into a renaming
-- -- environment.
-- instance BindsNames Match where
--   namingEnv m = case m of
--     Match p _  -> namingEnv p
--     MatchLet b -> namingEnv b

-- instance BindsNames Bind where
--   namingEnv b = singletonE (thing qn) (EFromBind qn) `mappend` fixity
--     where
--     qn = bName b

--     fixity = case bFixity b of
--                Just f  -> mempty { neFixity = Map.singleton (thing qn) [f] }
--                Nothing -> mempty

-- | Generate the naming environment for a type parameter.
instance BindsNames (TParam PName) where
  namingEnv TParam { .. } =
    do let range = fromMaybe emptyRange tpRange
       n <- liftSupply (mkParameter (getIdent tpName) range)
       return (singletonT tpName n)

-- -- | Generate an expression renaming environment from a pattern.  This ignores
-- -- type parameters that can be bound by the pattern.
-- instance BindsNames Pattern where
--   namingEnv p = foldMap unqualBind (namesP p)
--     where
--     unqualBind qn = singletonE (thing qn) (EFromBind qn)

-- -- | The naming environment for a single module.  This is the mapping from
-- -- unqualified internal names to fully qualified names.
-- instance BindsNames Module where
--   namingEnv m = foldMap topDeclEnv (mDecls m)
--     where
--     topDeclEnv td = case td of
--       Decl d      -> declEnv (tlValue d)
--       TDNewtype n -> newtypeEnv (tlValue n)
--       Include _   -> mempty

--     qual = fmap (\qn -> mkQual (thing (mName m)) (unqual qn))

--     qualBind ln = singletonE (thing ln) (EFromBind (qual ln))
--     qualType ln = singletonT (thing ln) (TFromSyn (qual ln))

--     declEnv d = case d of
--       DSignature ns _sig    -> foldMap qualBind ns
--       DPragma ns _p         -> foldMap qualBind ns
--       DBind b               -> qualBind (bName b) `mappend` fixity b
--       DPatBind _pat _e      -> panic "ModuleSystem" ["Unexpected pattern binding"]
--       DFixity{}             -> panic "ModuleSystem" ["Unexpected fixity declaration"]
--       DType (TySyn lqn _ _) -> qualType lqn
--       DLocated d' _         -> declEnv d'

--     fixity b =
--       case bFixity b of
--         Just f  -> mempty { neFixity = Map.singleton (thing (qual (bName b))) [f] }
--         Nothing -> mempty

--     newtypeEnv n = singletonT (thing qn) n
--          `mappend` singletonE (thing qn) n
--       where
--       qn = nName n

-- -- | The naming environment for a single declaration, unqualified.  This is
-- -- meanat to be used for things like where clauses.
-- instance BindsNames Decl where
--   namingEnv d = case d of
--     DSignature ns _sig    -> foldMap qualBind ns
--     DPragma ns _p         -> foldMap qualBind ns
--     DBind b               -> qualBind (bName b)
--     DPatBind _pat _e      -> panic "ModuleSystem" ["Unexpected pattern binding"]
--     DFixity{}             -> panic "ModuleSystem" ["Unexpected fixity declaration"]
--     DType (TySyn lqn _ _) -> qualType lqn
--     DLocated d' _         -> namingEnv d'
--     where
--     qualBind ln = singletonE (thing ln) (thing ln)
--     qualType ln = singletonT (thing ln) (thing ln)
