-- |
-- Module      :  Main
-- Copyright   :  (c) 2015-2016 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Main where

import qualified Data.Text    as T
import qualified Data.Text.IO as T
import           System.FilePath ((</>))
import qualified System.Directory   as Dir

import qualified Cryptol.Eval as E
import qualified Cryptol.Eval.Monad as E
import qualified Cryptol.Eval.Value as E

import qualified Cryptol.ModuleSystem.Base      as M
import qualified Cryptol.ModuleSystem.Env       as M
import qualified Cryptol.ModuleSystem.Monad     as M
import qualified Cryptol.ModuleSystem.NamingEnv as M
import           Cryptol.ModuleSystem.Interface (noIfaceParams)

import qualified Cryptol.Parser           as P
import qualified Cryptol.Parser.AST       as P
import qualified Cryptol.Parser.NoInclude as P

import qualified Cryptol.Symbolic as S
import qualified Cryptol.Symbolic.Value as S

import qualified Cryptol.TypeCheck     as T
import qualified Cryptol.TypeCheck.AST as T

import qualified Cryptol.Utils.Ident as I
import           Cryptol.Utils.Logger(quietLogger)

import qualified Data.SBV.Dynamic as SBV

import Criterion.Main

main :: IO ()
main = do
  cd <- Dir.getCurrentDirectory
  defaultMain [
    bgroup "parser" [
        parser "Prelude" "lib/Cryptol.cry"
      , parser "Extras"  "lib/Cryptol/Extras.cry"
      , parser "PreludeWithExtras" "bench/data/PreludeWithExtras.cry"
      , parser "BigSequence" "bench/data/BigSequence.cry"
      , parser "BigSequenceHex" "bench/data/BigSequenceHex.cry"
      , parser "AES" "bench/data/AES.cry"
      , parser "SHA512" "bench/data/SHA512.cry"
      ]
   , bgroup "typechecker" [
        tc cd "Prelude" "lib/Cryptol.cry"
      , tc cd "Extras"  "lib/Cryptol/Extras.cry"
      , tc cd "PreludeWithExtras" "bench/data/PreludeWithExtras.cry"
      , tc cd "BigSequence" "bench/data/BigSequence.cry"
      , tc cd "BigSequenceHex" "bench/data/BigSequenceHex.cry"
      , tc cd "AES" "bench/data/AES.cry"
      , tc cd "SHA512" "bench/data/SHA512.cry"
      ]
   , bgroup "conc_eval" [
        ceval cd "AES" "bench/data/AES.cry" "bench_correct"
      , ceval cd "ZUC" "bench/data/ZUC.cry" "ZUC_TestVectors"
      , ceval cd "SHA512" "bench/data/SHA512.cry" "testVector1 ()"
      ]
   , bgroup "sym_eval" [
        seval cd "AES" "bench/data/AES.cry" "bench_correct"
      , seval cd "ZUC" "bench/data/ZUC.cry" "ZUC_TestVectors"
      , seval cd "SHA512" "bench/data/SHA512.cry" "testVector1 ()"
      ]
   ]

-- | Evaluation options, mostly used by `trace`.
-- Since the benchmarks likely do not use base, these don't matter very much
evOpts :: E.EvalOpts
evOpts = E.EvalOpts { E.evalLogger = quietLogger
                    , E.evalPPOpts = E.defaultPPOpts
                    }

-- | Make a benchmark for parsing a Cryptol module
parser :: String -> FilePath -> Benchmark
parser name path =
  env (T.readFile path) $ \(~bytes) ->
    bench name $ nfIO $ do
      let cfg = P.defaultConfig
                { P.cfgSource  = path
                , P.cfgPreProc = P.guessPreProc path
                }
      case P.parseModule cfg bytes of
        Right pm -> return pm
        Left err -> error (show err)

-- | Make a benchmark for typechecking a Cryptol module. Does parsing
-- in the setup phase in order to isolate typechecking
tc :: String -> String -> FilePath -> Benchmark
tc cd name path =
  let withLib = M.withPrependedSearchPath [cd </> "lib"] in
  let setup = do
        bytes <- T.readFile path
        let cfg = P.defaultConfig
                { P.cfgSource  = path
                , P.cfgPreProc = P.guessPreProc path
                }
            Right pm = P.parseModule cfg bytes
        menv <- M.initialModuleEnv
        (Right ((prims, scm, tcEnv), menv'), _) <- M.runModuleM (evOpts,menv) $ withLib $ do
          -- code from `loadModule` and `checkModule` in
          -- `Cryptol.ModuleSystem.Base`
          let pm' = M.addPrelude pm
          M.loadDeps pm'
          Right nim <- M.io (P.removeIncludesModule path pm')
          npm <- M.noPat nim
          (tcEnv,declsEnv,scm) <- M.renameModule npm
          prims <- if P.thing (P.mName pm) == I.preludeName
                   then return (M.toPrimMap declsEnv)
                   else M.getPrimMap
          return (prims, scm, tcEnv)
        return (prims, scm, tcEnv, menv')
  in env setup $ \ ~(prims, scm, tcEnv, menv) ->
    bench name $ nfIO $ M.runModuleM (evOpts,menv) $ withLib $ do
      let act = M.TCAction { M.tcAction = T.tcModule
                           , M.tcLinter = M.moduleLinter (P.thing (P.mName scm))
                           , M.tcPrims  = prims
                           }
      M.typecheck act scm noIfaceParams tcEnv

ceval :: String -> String -> FilePath -> T.Text -> Benchmark
ceval cd name path expr =
  let withLib = M.withPrependedSearchPath [cd </> "lib"] in
  let setup = do
        menv <- M.initialModuleEnv
        (Right (texpr, menv'), _) <- M.runModuleM (evOpts,menv) $ withLib $ do
          m <- M.loadModuleByPath path
          M.setFocusedModule (T.mName m)
          let Right pexpr = P.parseExpr expr
          (_, texpr, _) <- M.checkExpr pexpr
          return texpr
        return (texpr, menv')
  in env setup $ \ ~(texpr, menv) ->
    bench name $ nfIO $ E.runEval evOpts $ do
      env' <- E.evalDecls (S.allDeclGroups menv) mempty
      (e :: E.Value) <- E.evalExpr env' texpr
      E.forceValue e


seval :: String -> String -> FilePath -> T.Text -> Benchmark
seval cd name path expr =
  let withLib = M.withPrependedSearchPath [cd </> "lib"] in
  let setup = do
        menv <- M.initialModuleEnv
        (Right (texpr, menv'), _) <- M.runModuleM (evOpts,menv) $ withLib $ do
          m <- M.loadModuleByPath path
          M.setFocusedModule (T.mName m)
          let Right pexpr = P.parseExpr expr
          (_, texpr, _) <- M.checkExpr pexpr
          return texpr
        return (texpr, menv')
  in env setup $ \ ~(texpr, menv) ->
    bench name $ nfIO $ E.runEval evOpts $ do
      env' <- E.evalDecls (S.allDeclGroups menv) mempty
      (e :: S.Value) <- E.evalExpr env' texpr
      E.io $ SBV.generateSMTBenchmark False $
         return (S.fromVBit e)
