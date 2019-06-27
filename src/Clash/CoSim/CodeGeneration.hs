{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE CPP #-}

{-|
Module      : Clash.CoSim.CodeGeneration
Description : Template Haskell utilities

This module contains the logic for generating coSim/N/ functions and their
declarations. It also houses general template haskell functions used elsewhere.
-}
module Clash.CoSim.CodeGeneration
    ( coSimGen
    , applyE
    ) where

#ifdef CABAL
import Paths_clash_cosim
#else
import Clash.CoSim.Paths_clash_cosim
#endif

import Clash.Annotations.Primitive (Primitive(..), HDL(..))
import Clash.CoSim.Types
import Clash.Prelude (Clock, Signal, KnownDomain)
import System.Environment (getEnv)
import Language.Haskell.TH
import Control.Monad (replicateM)

--------------------------------------
---- TEMPLATE HASKELL TOOLS ----------
--------------------------------------
-- | Put arrow in between types. That is, conceptually, evaluating
-- `arrow a b` ~ `a -> (b)`. Note you can use infix notation.
arrow :: Type -> Type -> Type
arrow t1 t2 = AppT (AppT ArrowT t1) t2

-- | Apply arrows repeatedly from [left] to right. That is, conceptually,
-- evaluating `arrowsR [a, b] c` ~ `a -> (b -> c)`.
arrowsR :: [Type] -> Type -> Type
arrowsR [] t = t
arrowsR ts t = arrow (head ts) (arrowsR (tail ts) t)

-- | Convenience function to apply a list of arguments to a function
applyE :: Foldable t => ExpQ -> t Name -> ExpQ
applyE = foldl (\f x -> [| $f $(varE x) |])

--------------------------------------
---- CODE GENERATION -----------------
--------------------------------------
-- | Generate coSim/N/ functions and their annotations. Inspect the result of this
-- function by passing @-ddump-splices@ to ghc. The number of instances generated
-- is dependent on the environment variable COSIM_MAX_NUMBER_OF_ARGUMENTS (defaults
-- to 16.)
coSimGen :: Q [Dec]
coSimGen = do
#ifdef CABAL
    -- We're running in a CABAL environment, so we know this environment
    -- variable is set:
    m <- read <$> runIO (getEnv "COSIM_MAX_NUMBER_OF_CLOCKS")
    n <- read <$> runIO (getEnv "COSIM_MAX_NUMBER_OF_ARGUMENTS")
#else
    let m = 1
    let n = 16
#endif


    concat <$> (sequence  [coSimGen' clks args | clks <- [0..m], args <-  [1..n]])

coSimGen' :: Int -> Int -> Q [Dec]
coSimGen' clks args = do
    let coSimName = mkName $ "coSimC" ++ show clks ++ "_A" ++ show args

    -- Type signature
    coSimType <- SigD coSimName <$> coSimTypeGen clks args

    -- Function declaration and body
    let coSim = FunD coSimName [Clause [] (NormalB $ VarE $ mkName "coSimN") []]

    -- NOINLINE pragma
    let inline = PragmaD $ InlineP coSimName NoInline FunLike AllPhases

    -- Clash blackbox pragma
    primDir        <- runIO $ getDataFileName "src/prims/verilog"
    primitiveAnn   <- [| Primitive Verilog primDir |]
    let blackboxAnn = PragmaD $ AnnP (ValueAnnotation coSimName) primitiveAnn

    return [coSimType, coSim, inline, blackboxAnn]




-- | Generate type signature of coSim function
coSimTypeGen
    :: Int
    -- ^ The number of clock arguments
    -> Int
    -- ^ Type signature for coSimN
    -> Q Type
coSimTypeGen clks args = do
    -- Generate "random" names for type variables
    let ids = concat $ drop 1 $ (`replicateM` ['a'..'z']) <$> [0..]
    let argNames     = map mkName (take args ids)
    let argTypeNames = map (return . VarT) argNames

    let resultName = mkName "result"
    let result     = return $ VarT resultName

    let domName = mkName "dom"
    let dom     = return $ VarT domName

    -- Generate contraints:
    argConstraints <- sequence $ map (\name -> [t| ClashType $name |]) argTypeNames
    resConstraint  <- [t| ClashType $result |]
    kdConstraint   <- [t| KnownDomain $dom |]
    let constraints = kdConstraint : resConstraint : argConstraints

    -- Generate type:
    fixedArgs      <- sequence [[t| String |], [t| String |], [t| CoSimSettings |]]
    clkSignalTypes <- sequence (replicate clks [t|Clock $dom |])
    argSignalTypes <- sequence $ map (\name -> [t| Signal $dom $name |]) argTypeNames
    resSignalType  <- [t| Signal $dom $result |]

    let ctx = (fixedArgs ++ clkSignalTypes ++ argSignalTypes) `arrowsR` resSignalType
    let varNames = resultName : domName : argNames
    return $ ForallT (map PlainTV varNames) constraints ctx
