-- |
-- Module      :  $Header$
-- Copyright   :  (c) 2013-2015 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable

{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

module Cryptol.ModuleSystem.Renamer (
    NamingEnv(), shadowing
  , BindsNames(..)
  , checkNamingEnv
  , Rename(..), runRenamer
  , RenamerError(..)
  , RenamerWarning(..)
  ) where

import Cryptol.ModuleSystem.Name
import Cryptol.ModuleSystem.NamingEnv
import Cryptol.Prims.Syntax
import Cryptol.Parser.AST
import Cryptol.Parser.Names (tnamesP)
import Cryptol.Parser.Position
import Cryptol.Utils.Panic (panic)
import Cryptol.Utils.PP

import MonadLib
import qualified Data.Map as Map

import GHC.Generics (Generic)
import Control.DeepSeq
import Data.Maybe (fromMaybe)

#if __GLASGOW_HASKELL__ < 710
import Control.Applicative(Applicative(..),(<$>))
import Data.Foldable (foldMap)
import Data.Monoid (Monoid(..))
import Data.Traversable (traverse)
#endif


-- Errors ----------------------------------------------------------------------

data RenamerError
  = MultipleSyms (Located PName) [Name]
    -- ^ Multiple imported symbols contain this name

  | UnboundExpr (Located PName)
    -- ^ Expression name is not bound to any definition

  | UnboundType (Located PName)
    -- ^ Type name is not bound to any definition

  | OverlappingSyms [Name]
    -- ^ An environment has produced multiple overlapping symbols

  | ExpectedValue (Located PName)
    -- ^ When a value is expected from the naming environment, but one or more
    -- types exist instead.

  | ExpectedType (Located PName)
    -- ^ When a type is missing from the naming environment, but one or more
    -- values exist with the same name.

  | FixityError (Located Name) (Located Name)
    -- ^ When the fixity of two operators conflict

  | InvalidConstraint (Type PName)
    -- ^ When it's not possible to produce a Prop from a Type.

  | MalformedConstraint (Located (Type PName))
    -- ^ When a constraint appears within another constraint
    deriving (Show,Generic)

instance NFData RenamerError

instance PP RenamerError where
  ppPrec _ e = case e of

    MultipleSyms lqn qns ->
      hang (text "[error] at" <+> pp (srcRange lqn))
         4 $ (text "Multiple definitions for symbol:" <+> pp (thing lqn))
          $$ vcat (map pp qns)

    UnboundExpr lqn ->
      hang (text "[error] at" <+> pp (srcRange lqn))
         4 (text "Value not in scope:" <+> pp (thing lqn))

    UnboundType lqn ->
      hang (text "[error] at" <+> pp (srcRange lqn))
         4 (text "Type not in scope:" <+> pp (thing lqn))

    OverlappingSyms qns ->
      hang (text "[error]")
         4 $ text "Overlapping symbols defined:"
          $$ vcat (map pp qns)

    ExpectedValue lqn ->
      hang (text "[error] at" <+> pp (srcRange lqn))
         4 (fsep [ text "Expected a value named", quotes (pp (thing lqn))
                 , text "but found a type instead"
                 , text "Did you mean `(" <> pp (thing lqn) <> text")?" ])

    ExpectedType lqn ->
      hang (text "[error] at" <+> pp (srcRange lqn))
         4 (fsep [ text "Expected a type named", quotes (pp (thing lqn))
                 , text "but found a value instead" ])

    FixityError o1 o2 ->
      hang (text "[error]")
         4 (fsep [ text "The fixities of", pp o1, text "and", pp o2
                 , text "are not compatible.  "
                 , text "You may use explicit parenthesis to disambiguate" ])

    InvalidConstraint ty ->
      hang (text "[error]" <+> maybe empty (\r -> text "at" <+> pp r) (getLoc ty))
         4 (fsep [ pp ty, text "is not a valid constraint" ])

    MalformedConstraint t ->
      hang (text "[error] at" <+> pp (srcRange t))
         4 (sep [ quotes (pp (thing t))
                , text "is not a valid argument to a constraint" ])

-- Warnings --------------------------------------------------------------------

data RenamerWarning
  = SymbolShadowed Name [Name]
    deriving (Show,Generic)

instance NFData RenamerWarning

instance PP RenamerWarning where
  ppPrec _ (SymbolShadowed new originals) =
    hang (text "[warning] at" <+> loc)
       4 $ fsep [ text "This binding for" <+> sym
                , text "shadows the existing binding" <> plural <+> text "from" ]
        $$ vcat (map pp originals)

    where
    plural | length originals > 1 = char 's'
           | otherwise            = empty

    loc = pp (nameLoc new)
    sym = pp new


-- Renaming Monad --------------------------------------------------------------

data RO = RO
  { roLoc   :: Range
  , roNames :: NamingEnv
  }

data Out = Out
  { oWarnings :: [RenamerWarning]
  , oErrors   :: [RenamerError]
  } deriving (Show)

instance Monoid Out where
  mempty      = Out [] []
  mappend l r = Out (oWarnings l `mappend` oWarnings r)
                    (oErrors   l `mappend` oErrors   r)

newtype RenameM a = RenameM
  { unRenameM :: ReaderT RO (WriterT Out SupplyM) a }

instance Functor RenameM where
  {-# INLINE fmap #-}
  fmap f m      = RenameM (fmap f (unRenameM m))

instance Applicative RenameM where
  {-# INLINE pure #-}
  pure x        = RenameM (pure x)

  {-# INLINE (<*>) #-}
  l <*> r       = RenameM (unRenameM l <*> unRenameM r)

instance Monad RenameM where
  {-# INLINE return #-}
  return x      = RenameM (return x)

  {-# INLINE (>>=) #-}
  m >>= k       = RenameM (unRenameM m >>= unRenameM . k)

runRenamer :: Supply -> NamingEnv -> RenameM a
           -> (Either [RenamerError] (a,Supply),[RenamerWarning])
runRenamer s env m = (res,oWarnings out)
  where

  ((a,out),s') = runM (unRenameM m) RO { roLoc = emptyRange, roNames = env } s

  res | null (oErrors out) = Right (a,s')
      | otherwise          = Left (oErrors out)

record :: RenamerError -> RenameM ()
record err = records [err]

records :: [RenamerError] -> RenameM ()
records errs = RenameM (put mempty { oErrors = errs })

located :: a -> RenameM (Located a)
located a = RenameM $ do
  ro <- ask
  return Located { srcRange = roLoc ro, thing = a }

withLoc :: HasLoc loc => loc -> RenameM a -> RenameM a
withLoc loc m = RenameM $ case getLoc loc of

  Just range -> do
    ro <- ask
    local ro { roLoc = range } (unRenameM m)

  Nothing -> unRenameM m

-- | Shadow the current naming environment with some more names.
shadowNames :: BindsNames env => env -> RenameM a -> RenameM a
shadowNames names m = RenameM $ do
  env <- inBase (namingEnv names)
  ro  <- ask
  put (checkEnv env (roNames ro))
  let ro' = ro { roNames = env `shadowing` roNames ro }
  local ro' (unRenameM m)

-- | Generate warnings when the left environment shadows things defined in
-- the right.  Additionally, generate errors when two names overlap in the
-- left environment.
checkEnv :: NamingEnv -> NamingEnv -> Out
checkEnv l r = Map.foldlWithKey (step neExprs) mempty (neExprs l)
     `mappend` Map.foldlWithKey (step neTypes) mempty (neTypes l)
  where

  step prj acc k ns = acc `mappend` mempty
    { oWarnings = case Map.lookup k (prj r) of
        Nothing -> []
        Just os -> [SymbolShadowed (head ns) os]
    , oErrors   = containsOverlap ns
    }

-- | Check the RHS of a single name rewrite for conflicting sources.
containsOverlap :: [Name] -> [RenamerError]
containsOverlap [_] = []
containsOverlap []  = panic "Renamer" ["Invalid naming environment"]
containsOverlap ns  = [OverlappingSyms ns]

-- | Throw errors for any names that overlap in a rewrite environment.
checkNamingEnv :: NamingEnv -> ([RenamerError],[RenamerWarning])
checkNamingEnv env = (out, [])
  where
  out    = Map.foldr check outTys (neExprs env)
  outTys = Map.foldr check mempty (neTypes env)

  check ns acc = containsOverlap ns ++ acc

supply :: SupplyM a -> RenameM a
supply m = RenameM (inBase m)


-- Renaming --------------------------------------------------------------------

class Rename f where
  rename :: f PName -> RenameM (f Name)

instance Rename Module where
  rename Module { .. } = do
    decls' <- traverse rename mDecls
    return Module { mDecls = decls', .. }

instance Rename TopDecl where
  rename td     = case td of
    Decl d      -> Decl      <$> traverse rename d
    TDNewtype n -> TDNewtype <$> traverse rename n
    Include n   -> return (Include n)

rnLocated :: (a -> RenameM b) -> Located a -> RenameM (Located b)
rnLocated f loc = withLoc loc $
  do a' <- f (thing loc)
     return loc { thing = a' }

instance Rename Decl where
  rename d      = case d of
    DSignature ns sig -> DSignature    <$> traverse (rnLocated renameVar) ns
                                       <*> rename sig
    DPragma ns p      -> DPragma       <$> traverse (rnLocated renameVar) ns
                                       <*> pure p
    DBind b           -> DBind         <$> rename b
    DPatBind pat e    -> shadowNames (namingEnv pat) $ DPatBind <$> rename pat
                                                                <*> rename e
    DType syn         -> DType         <$> rename syn
    DLocated d' r     -> withLoc r
                       $ DLocated      <$> rename d'  <*> pure r
    DFixity{}         -> panic "Renamer" ["Unexpected fixity declaration"
                                         , show d]

instance Rename Newtype where
  rename n      = do
    name' <- rnLocated renameType (nName n)
    shadowNames (nParams n) $
      do ps'   <- traverse rename (nParams n)
         body' <- traverse (rnNamed rename) (nBody n)
         return Newtype { nName   = name'
                        , nParams = ps'
                        , nBody   = body' }

renameVar :: PName -> RenameM Name
renameVar qn = do
  ro <- RenameM ask
  case Map.lookup qn (neExprs (roNames ro)) of
    Just [n]  -> return n
    Just []   -> panic "Renamer" ["Invalid expression renaming environment"]
    Just syms ->
      do n <- located qn
         record (MultipleSyms n syms)
         return (head syms)

    -- This is an unbound value. Record an error and invent a bogus real name
    -- for it.
    Nothing ->
      do n <- located qn

         case Map.lookup qn (neTypes (roNames ro)) of
           -- types existed with the name of the value expected
           Just _ -> record (ExpectedValue n)

           -- the value is just missing
           Nothing -> record (UnboundExpr n)

         supply $ liftSupply
                $ mkParameter (getIdent qn) (srcRange n)

renameType :: PName -> RenameM Name
renameType qn = do
  ro <- RenameM ask
  case Map.lookup qn (neTypes (roNames ro)) of
    Just [n]  -> return n
    Just []   -> panic "Renamer" ["Invalid type renaming environment"]
    Just syms ->
      do n <- located qn
         record (MultipleSyms n syms)
         return (head syms)

    -- This is an unbound value. Record an error and invent a bogus real name
    -- for it.
    Nothing ->
      do n <- located qn

         case Map.lookup qn (neExprs (roNames ro)) of

           -- values exist with the same name, so throw a different error
           Just _ -> record (ExpectedType n)

           -- no terms with the same name, so the type is just unbound
           Nothing -> record (UnboundType n)

         supply $ liftSupply
                $ mkParameter (getIdent qn) (srcRange n)

-- | Rename a schema, assuming that none of its type variables are already in
-- scope.
instance Rename Schema where
  rename s@(Forall ps _ _ _) = shadowNames ps (renameSchema s)

-- | Rename a schema, assuming that the type variables have already been brought
-- into scope.
renameSchema :: Schema PName -> RenameM (Schema Name)
renameSchema (Forall ps p ty loc) = Forall <$> traverse rename ps
                                           <*> traverse rename p
                                           <*> rename ty
                                           <*> pure loc

instance Rename Prop where
  rename p      = case p of
    CFin t        -> CFin     <$> rename t
    CEqual l r    -> CEqual   <$> rename l  <*> rename r
    CGeq l r      -> CGeq     <$> rename l  <*> rename r
    CArith t      -> CArith   <$> rename t
    CCmp t        -> CCmp     <$> rename t
    CLocated p' r -> withLoc r
                   $ CLocated <$> rename p' <*> pure r

    -- here, we rename the type and then require that it produces something that
    -- looks like a Prop
    CType t -> translateProp t

translateProp :: Type PName -> RenameM (Prop Name)
translateProp ty = go =<< rnType True ty
  where
  go :: Type Name -> RenameM (Prop Name)
  go t = case t of

    TLocated t' r -> (`CLocated` r) <$> go t'

    TUser n [l,r]
      | i == mkIdent "==" -> pure (CEqual l r)
      | i == mkIdent ">=" -> pure (CGeq l r)
      | i == mkIdent "<=" -> pure (CGeq r l)
      where
      i = nameIdent n

    _ ->
      do record (InvalidConstraint ty)
         return (CType t)


instance Rename Type where
  rename = rnType False

rnType :: Bool -> Type PName -> RenameM (Type Name)
rnType isProp = go
  where
  go :: Type PName -> RenameM (Type Name)
  go t = case t of
    TFun a b     -> TFun     <$> go a  <*> go b
    TSeq n a     -> TSeq     <$> go n  <*> go a
    TBit         -> return TBit
    TNum c       -> return (TNum c)
    TChar c      -> return (TChar c)
    TInf         -> return TInf

    TUser pn ps
      | i == "inf", null ps     -> return TInf
      | i == "Bit", null ps     -> return TBit

      | i == "min"              -> TApp TCMin           <$> traverse go ps
      | i == "max"              -> TApp TCMax           <$> traverse go ps
      | i == "lengthFromThen"   -> TApp TCLenFromThen   <$> traverse go ps
      | i == "lengthFromThenTo" -> TApp TCLenFromThenTo <$> traverse go ps
      | i == "width"            -> TApp TCWidth         <$> traverse go ps

        -- This should only happen in error, as fin constraints are constructed
        -- in the parser. (Cryptol.Parser.ParserUtils.mkProp)
      | i == "fin" && isProp    ->
        do locTy <- located t
           record (MalformedConstraint locTy)
           TUser undefined <$> traverse go ps

      where
      i = getIdent pn

    TUser qn ps  -> TUser    <$> renameType qn <*> traverse go ps
    TApp f xs    -> TApp f   <$> traverse go xs
    TRecord fs   -> TRecord  <$> traverse (rnNamed go) fs
    TTuple fs    -> TTuple   <$> traverse go fs
    TWild        -> return TWild
    TLocated t' r -> withLoc r
                 $ TLocated <$> go t' <*> pure r

    TParens t'   -> TParens <$> go t'

    TInfix a o _ b ->
      do op <- renameTypeOp isProp o
         a' <- go a
         b' <- go b
         mkTInfix isProp a' op b'


type TOp = Type Name -> Type Name -> Type Name

mkTInfix :: Bool -> Type Name -> (TOp,Fixity) -> Type Name -> RenameM (Type Name)

-- this should be one of the props, or an error, so just assume that its fixity
-- is `infix 0`.
mkTInfix True t@(TUser o1 [x,y]) op@(o2,f2) z =
  do let f1 = Fixity NonAssoc 0
     case compareFixity f1 f2 of
       FCLeft  -> return (o2 t z)
       FCRight -> do r <- mkTInfix True y op z
                     return (TUser o1 [x,r])

       -- Just reconstruct with the TUser part being an application. If this was
       -- a real error, it will have been caught by now.
       FCError -> return (o2 t z)

-- In this case, we know the fixities of both sides.
mkTInfix isProp t@(TApp o1 [x,y]) op@(o2,f2) z
  | Just (a1,p1) <- Map.lookup o1 tBinOpPrec =
     case compareFixity (Fixity a1 p1) f2 of
       FCLeft  -> return (o2 t z)
       FCRight -> do r <- mkTInfix isProp y op z
                     return (TApp o1 [x,r])

       -- As the fixity table is known, and this is a case where the fixity came
       -- from that table, it's a real error if the fixities didn't work out.
       FCError -> panic "Renamer" [ "fixity problem for type operators"
                                  , show (o2 t z) ]

mkTInfix isProp (TLocated t _) op z =
     mkTInfix isProp t op z

mkTInfix _ t (op,_) z =
     return (op t z)


-- | Rename a type operator, mapping it to a real type function.  When isProp is
-- True, it's assumed that the renaming is happening in the context of a Prop,
-- which allows unresolved operators to propagate without an error.  They will
-- be resolved in the CType case for Prop.
renameTypeOp :: Bool -> Located PName -> RenameM (TOp,Fixity)
renameTypeOp isProp op =
  do let sym   = thing op
         props = [ mkUnqual (mkIdent "==")
                 , mkUnqual (mkIdent ">=")
                 , mkUnqual (mkIdent "<=") ]
         lkp   = do n               <- Map.lookup (thing op) tfunNames
                    (fAssoc,fLevel) <- Map.lookup n tBinOpPrec
                    return (n,Fixity { .. })

     sym' <- renameType sym
     case lkp of
       Just (p,f) ->
            return (\x y -> TApp p [x,y], f)

       Nothing
         | isProp && sym `elem` props ->
              return (\x y -> TUser sym' [x,y], Fixity NonAssoc 0)

         | otherwise ->
           do record (UnboundType op)
              return (\x y -> TUser sym' [x,y], defaultFixity)


-- | The type renaming environment generated by a binding. This includes any
-- type variables introduced by the signature, shadowed by any type variables
-- introduced by the patterns of the binding.
bindingTypeEnv :: Bind PName -> SupplyM NamingEnv
bindingTypeEnv b =
  do sigParams <- namingEnv (bSignature b)
     patParams <- foldMap params (bParams b)
     return (patParams `shadowing` sigParams)
  where

  -- XXX the location information could be finer grained, here
  params pat =
    do let loc = fromMaybe emptyRange (getLoc pat)
       foldMap (param loc) (tnamesP pat)

  param loc qn =
    do n <- liftSupply (mkParameter (getIdent qn) loc)
       return (singletonT qn n)

-- | Rename a binding.
--
-- NOTE: this does not bind its own name into the naming context of its body.
-- The assumption here is that this has been done by the enclosing environment,
-- to allow for top-level renaming
instance Rename Bind where
  rename b      = do
    n'  <- rnLocated renameVar (bName b)
    env <- supply (bindingTypeEnv b)
    shadowNames env $ do
      (patenv,pats') <- renamePats (bParams b)
      sig'           <- traverse renameSchema (bSignature b)
      shadowNames patenv $
        do e'   <- rnLocated rename (bDef b)
           return b { bName      = n'
                    , bParams    = pats'
                    , bDef       = e'
                    , bSignature = sig'
                    , bPragmas   = bPragmas b
                    }

instance Rename BindDef where
  rename DPrim     = return DPrim
  rename (DExpr e) = DExpr <$> rename e

-- NOTE: this only renames types within the pattern.
instance Rename Pattern where
  rename p      = case p of
    PVar lv         -> PVar <$> rnLocated renameVar lv
    PWild           -> pure PWild
    PTuple ps       -> PTuple   <$> traverse rename ps
    PRecord nps     -> PRecord  <$> traverse (rnNamed rename) nps
    PList elems     -> PList    <$> traverse rename elems
    PTyped p' t     -> PTyped   <$> rename p'    <*> rename t
    PSplit l r      -> PSplit   <$> rename l     <*> rename r
    PLocated p' loc -> withLoc loc
                     $ PLocated <$> rename p'    <*> pure loc

instance Rename Expr where
  rename e = case e of
    EVar n        -> EVar <$> renameVar n
    ELit l        -> return (ELit l)
    ETuple es     -> ETuple  <$> traverse rename es
    ERecord fs    -> ERecord <$> traverse (rnNamed rename) fs
    ESel e' s     -> ESel    <$> rename e' <*> rename s
    EList es      -> EList   <$> traverse rename es
    EFromTo s n e'-> EFromTo <$> rename s
                             <*> traverse rename n
                             <*> traverse rename e'
    EInfFrom a b  -> EInfFrom<$> rename a  <*> traverse rename b
    EComp e' bs   -> do bs' <- mapM renameMatch bs
                        shadowNames (namingEnv bs')
                            (EComp <$> rename e' <*> pure bs')
    EApp f x      -> EApp    <$> rename f  <*> rename x
    EAppT f ti    -> EAppT   <$> rename f  <*> traverse rename ti
    EIf b t f     -> EIf     <$> rename b  <*> rename t  <*> rename f
    EWhere e' ds  -> shadowNames ds $ EWhere <$> rename e'
                                             <*> traverse rename ds
    ETyped e' ty  -> ETyped  <$> rename e' <*> rename ty
    ETypeVal ty   -> ETypeVal<$> rename ty
    EFun ps e'    -> do ps' <- traverse rename ps
                        shadowNames ps' (EFun ps' <$> rename e')
    ELocated e' r -> withLoc r
                   $ ELocated <$> rename e' <*> pure r

    EParens p     -> EParens <$> rename p
    EInfix x y _ z-> do op <- renameOp y
                        x' <- rename x
                        z' <- rename z
                        mkEInfix x' op z'

mkEInfix :: Expr Name             -- ^ May contain infix expressions
         -> (Located Name,Fixity) -- ^ The operator to use
         -> Expr Name             -- ^ Will not contain infix expressions
         -> RenameM (Expr Name)

mkEInfix e@(EInfix x o1 f1 y) op@(o2,f2) z =
  case compareFixity f1 f2 of
    FCLeft  -> return (EInfix e o2 f2 z)

    FCRight -> do r <- mkEInfix y op z
                  return (EInfix x o1 f1 r)

    FCError -> do record (FixityError o1 o2)
                  return (EInfix e o2 f2 z)

mkEInfix (ELocated e' _) op z =
     mkEInfix e' op z

mkEInfix e (o,f) z =
     return (EInfix e o f z)


renameOp :: Located PName -> RenameM (Located Name,Fixity)
renameOp ln = withLoc ln $
  do n  <- renameVar (thing ln)
     ro <- RenameM ask
     case Map.lookup n (neFixity (roNames ro)) of
       Just [fixity] -> return (ln { thing = n },fixity)
       _             -> return (ln { thing = n },defaultFixity)


instance Rename TypeInst where
  rename ti = case ti of
    NamedInst nty -> NamedInst <$> traverse rename nty
    PosInst ty    -> PosInst   <$> rename ty

renameMatch :: [Match PName] -> RenameM [Match Name]
renameMatch  = loop
  where
  loop ms = case ms of

    m:rest -> do
      m' <- rename m
      (m':) <$> shadowNames m' (loop rest)

    [] -> return []

renamePats :: [Pattern PName] -> RenameM (NamingEnv,[Pattern Name])
renamePats  = loop
  where
  loop ps = case ps of

    p:rest -> do
      p' <- rename p
      pe <- supply (namingEnv p')
      (env',rest') <- loop rest
      return (pe `mappend` env', p':rest')

    [] -> return (mempty, [])

instance Rename Match where
  rename m = case m of
    Match p e  ->                Match    <$> rename p <*> rename e
    MatchLet b -> shadowNames b (MatchLet <$> rename b)

instance Rename TySyn where
  rename (TySyn n ps ty) =
     shadowNames ps $ TySyn <$> rnLocated renameType n
                            <*> traverse rename ps
                            <*> rename ty


-- Utilities -------------------------------------------------------------------

rnNamed :: (a -> RenameM b) -> Named a -> RenameM (Named b)
rnNamed  = traverse
{-# INLINE rnNamed #-}
