{-|
Copyright   :  Copyright (c) 2016, SICS Swedish ICT AB
License     :  BSD3 (see the LICENSE file)
Maintainer  :  rcas@sics.se
-}
{-
Main authors:
  Roberto Castaneda Lozano <rcas@sics.se>

This file is part of Unison, see http://unison-code.github.io
-}
{-# LANGUAGE DeriveDataTypeable, RecordWildCards #-}
module Unison.Tools.Run (run) where

import System.IO
import System.Directory
import System.Process
import Control.Monad
import Data.List.Split

import Unison.Driver
import qualified Unison.Tools.Import as Import
import qualified Unison.Tools.Linearize as Linearize
import qualified Unison.Tools.Extend as Extend
import qualified Unison.Tools.Augment as Augment
import qualified Unison.Tools.Model as Model
import qualified Unison.Tools.Export as Export
import qualified Unison.Tools.Normalize as Normalize

run (estimateFreq, noCC, noReserved, maxBlockSize, implementFrames, function,
     goal, noCross, oldModel, expandCopies, rematerialize, baseFile, scaleFreq,
     applyBaseFile, tightPressureBound, strictlyBetter, removeReds, keepNops,
     solverFlags, inFile, debug, verbose, intermediate, lint, outFile, outTemp,
     presolver, solver)
     targetWithOption =

  do tmp <- getTemporaryDirectory
     prefix <- unisonPrefixFile tmp
     let maybePutStrLn = when verbose . hPutStrLn stderr

     mirInput <- readFile inFile
     let uniFile = addExtension prefix "uni"
     maybePutStrLn "Running 'uni import'..."
     Import.run
       (estimateFreq, noCC, noReserved, maxBlockSize, implementFrames, function,
        goal, inFile, debug, intermediate, lint, Just uniFile)
       mirInput targetWithOption
     uniInput <- readFile uniFile

     let lssaUniFile = addExtension prefix "lssa.uni"
     maybePutStrLn "Running 'uni linearize'..."
     Linearize.run
       (uniFile, debug, intermediate, lint, Just lssaUniFile)
       uniInput targetWithOption
     lssaUniInput <- readFile lssaUniFile

     let extUniFile = addExtension prefix "ext.uni"
     maybePutStrLn "Running 'uni extend'..."
     Extend.run
       (lssaUniFile, debug, intermediate, lint, Just extUniFile)
       lssaUniInput targetWithOption
     extUniInput <- readFile extUniFile

     let altUniFile = addExtension prefix "alt.uni"
     maybePutStrLn "Running 'uni augment'..."
     Augment.run
       (implementFrames, noCross, oldModel, expandCopies, rematerialize,
        extUniFile, debug, intermediate, lint, Just altUniFile)
       extUniInput targetWithOption
     altUniInput <- readFile altUniFile

     baseFile' <-
       normalize (prefix, estimateFreq, debug, verbose, targetWithOption)
       baseFile

     let jsonFile = addExtension prefix "json"
     maybePutStrLn "Running 'uni model'..."
     Model.run
       (baseFile', scaleFreq, oldModel, applyBaseFile, tightPressureBound,
        strictlyBetter, Just jsonFile)
       altUniInput targetWithOption

     let extJsonFile   = addExtension prefix "ext.json"
         presolverPath = case presolver of
                          Just path -> path
                          Nothing -> "gecode-presolver"
     maybePutStrLn ("Running '" ++ presolverPath ++ "'...")
     callProcess presolverPath
       (["-o", extJsonFile] ++ ["--verbose" | verbose] ++
        ["-t", "180000", jsonFile])

     let outJsonFile = addExtension prefix "out.json"
         splitFlags  = [flag | flag <- splitOn " " solverFlags, not (null flag)]
         solverPath  = case solver of
                          Just path -> path
                          Nothing -> "gecode-solver"
     maybePutStrLn ("Running '" ++ solverPath ++ "'...")
     callProcess solverPath
       (["-o", outJsonFile] ++ ["--verbose" | verbose] ++ splitFlags ++
        [extJsonFile])

     let unisonMirFile =
           case outFile of
            Just file -> Just file
            Nothing -> if outTemp then Just (addExtension prefix "unison.mir")
                       else Nothing
     maybePutStrLn "Running 'uni export'..."
     Export.run
       (removeReds, keepNops, baseFile', tightPressureBound, debug,
        outJsonFile, unisonMirFile)
       altUniInput targetWithOption

     return prefix

addExtension prefix ext = prefix ++ "." ++ ext

normalize _ Nothing = return Nothing
normalize (prefix, estimateFreq, debug, verbose, targetWithOption)
  (Just baseFile) =
  do let llvmMirFile = addExtension prefix "llvm.mir"
     asmMirInput <- readFile baseFile
     when verbose $ hPutStrLn stderr "Running 'uni normalize'..."
     Normalize.run
       (estimateFreq, debug, Just llvmMirFile)
       asmMirInput targetWithOption
     return (Just llvmMirFile)
