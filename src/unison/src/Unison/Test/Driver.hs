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
{-# LANGUAGE OverloadedStrings, FlexibleContexts, DeriveDataTypeable, CPP #-}
module Unison.Test.Driver where

import Data.Maybe
import System.Exit
import Test.HUnit
import System.Console.CmdArgs
import System.Console.CmdArgs.Explicit
import System.Directory
import System.IO
import Control.Monad
import System.FilePath hiding (addExtension)
import Data.List
import Data.Yaml
import Data.List.Split
#if (!defined(__GLASGOW_HASKELL__)) || (__GLASGOW_HASKELL__ < 710)
import Control.Applicative ((<$>),(<*>))
#endif
import qualified Data.ByteString.Lazy.Char8 as BSL
import qualified Data.Aeson as JSON
import qualified Data.HashMap.Strict as HM

import Common.Util
import Unison
import Unison.Target.API
import Unison.Tools.Run as Run
import Unison.Tools.UniArgs hiding (verbose, presolver, solver)
import Unison.Driver
import qualified Unison.Tools.Analyze as Analyze

data TestArgs = TestArgs {directory :: FilePath, presolver :: Maybe FilePath,
                          solver :: Maybe FilePath, showProgress :: Bool,
                          verbose :: Bool, update :: Bool}
              deriving (Data, Typeable, Show)

testArgs = cmdArgsMode $ TestArgs
    {
      directory    = "" &= name "d" &= help "Test directory" &= typFile,
      presolver    = Nothing &= help "Path to Unison's presolver binary" &= typFile,
      solver       = Nothing &= help "Path to Unison's solver binary" &= typFile,
      showProgress = False &= name "p" &= help "Show test progress",
      verbose      = False &= name "v" &= help "Run tests in verbose mode",
      update       = False &= help "Update test expectations with the latest results from Unison"
    }

mainWithTargets unisonTargets =
  do testArgs <- cmdArgsRun testArgs
     mirFiles <- mirFileNames (directory testArgs)
     let tests = TestList $ map (systemTest unisonTargets testArgs) mirFiles
     count <- runTestTT tests
     exitTest count

exitTest Counts {errors = 0, failures = 0} = exitSuccess
exitTest _ = exitFailure

systemTest unisonTargets testArgs mirFile =
  TestList
  [TestLabel mirFile (TestCase (runUnison unisonTargets testArgs mirFile))]

runUnison unisonTargets testArgs mirFile =
  do let argv = processValue uniArgs ["run", "--target=foo", "bar"]
     args <- cmdArgsApply argv
     mir <- readFile mirFile
     let sp = showProgress testArgs
         verb = verbose testArgs
         upd = update testArgs
         asmMirFile = addExtension (take (length mirFile - 4) mirFile) "asm.mir"
         properties = parseTestProperties unisonTargets mirFile mir
     when (verb || sp) $ hPutStrLn stderr ""
     when sp $ hPutStrLn stderr ("Running test " ++ mirFile ++ "...")
     case pickTarget (testTarget properties) unisonTargets of
      (Any target) -> do
        prefix <- Run.run
                  (estimateFreq args,
                   noCC args,
                   noReserved args,
                   maxBlockSize args,
                   implementFrames args,
                   function args,
                   Just (testGoal properties),
                   noCross args,
                   oldModel args,
                   expandCopies args,
                   rematerialize args,
                   Just asmMirFile,
                   scaleFreq args,
                   applyBaseFile args,
                   tightPressureBound args,
                   strictlyBetter args,
                   removeReds args,
                   keepNops args,
                   solverFlags args,
                   mirFile,
                   False,
                   verb,
                   intermediate args,
                   True,
                   Nothing,
                   True,
                   presolver testArgs,
                   solver testArgs)
                  (target, targetOption args)
        properties1 <- assertOutJson upd properties prefix
        let unisonMirFile = addExtension prefix "unison.mir"
        properties2 <- assertCost upd (target, targetOption args)
                       properties1 unisonMirFile
        when upd $ updateProperties properties2 mirFile mir
        return ()

addExtension prefix ext = prefix ++ "." ++ ext

mirFileNames dir = do
  names <- getDirectoryContents dir
  paths <- forM (filter (`notElem` [".", ".."]) names) $ \name -> do
    let path = dir </> name
    isDirectory <- doesDirectoryExist path
    if isDirectory then mirFileNames path
      else return [path | ".mir" `isSuffixOf` path,
                          not (".asm.mir" `isSuffixOf` path)]
  return (concat paths)

parseTestProperties unisonTargets mirFile mir =
  let docs = split onDocumentEnd mir
  in if length docs == 3 then decodeYaml (docs !! 2)  :: TestProperties
     else mkTestProperties (guessTarget unisonTargets mirFile)
          (guessGoal mirFile) Nothing Nothing Nothing

guessTarget unisonTargets mirFile =
  case find (\t -> t `isInfixOf` mirFile) (map fst unisonTargets) of
   Just target -> target
   Nothing -> error ("File " ++ show mirFile ++ " does not specify the target")

guessGoal mirFile =
  case find (\g -> g `isInfixOf` mirFile) ["speed", "size"] of
   Just goal -> goal
   Nothing -> error ("File " ++ show mirFile ++ " does not specify the goal")

updateProperties properties mirFile mir =
  do let docs = split onDocumentEnd mir
         mir' = (docs !! 0) ++ (docs !! 1) ++
                "---\n" ++ encodeYaml properties ++ "...\n"
     writeFile mirFile mir'

mkTestProperties = TestProperties

data TestProperties = TestProperties {
  testTarget :: String,
  testGoal :: String,
  testExpectedHasSolution :: Maybe Bool,
  testExpectedProven :: Maybe Bool,
  testExpectedCost :: Maybe Integer
  } deriving Show

instance FromJSON TestProperties where
  parseJSON (Object v) =
    TestProperties <$>
    (v .:  "unison-test-target") <*>
    (v .:  "unison-test-goal") <*>
    (v .:? "unison-test-expected-has-solution") <*>
    (v .:? "unison-test-expected-proven") <*>
    (v .:? "unison-test-expected-cost")
  parseJSON _ = error "Can't parse TestProperties from YAML"

instance ToJSON TestProperties where
  toJSON (TestProperties target goal expHasSolution expProven expCost) =
    object ["unison-test-target" .= target,
            "unison-test-goal" .= goal,
            "unison-test-expected-has-solution" .= expHasSolution,
            "unison-test-expected-proven" .= expProven,
            "unison-test-expected-cost" .= expCost]

assertOutJson update properties prefix =
  do let outJsonFile = addExtension prefix "out.json"
     outJson <- readFile outJsonFile
     let sol = parseSolution outJson
         expHasSolution = solFromJson sol "has_solution" :: Bool
         properties1 = if update then properties {testExpectedHasSolution =
                                                     Just expHasSolution}
                       else properties
         expProven = solFromJson sol "proven" :: Bool
         properties2 = if update then properties1 {testExpectedProven =
                                                      Just expProven}
                       else properties1
         hasSolution = testExpectedHasSolution properties2
         proven = testExpectedProven properties2
     when (isJust hasSolution) $
       assertEqual
       "* unexpected 'has_solution' value"
       (fromJust hasSolution)
       expHasSolution
     when (isJust proven) $
       assertEqual
       "* unexpected 'proven' value"
       (fromJust proven)
       expProven
     return properties2

assertCost update target properties unisonMirFile =
    do unisonMir <- readFile unisonMirFile
       let gl = lowLevelGoal properties
           ([expCost], _) =
             Analyze.analyze (False, True, False) 1.0 [gl] unisonMir target
           properties1 = if update then properties {testExpectedCost =
                                                       Just expCost}
                         else properties
           cost = testExpectedCost properties1
       when (isJust cost) $
         assertEqual
         "* unexpected 'cost' value"
         (fromJust cost)
         expCost
       return properties1

lowLevelGoal properties =
  case testGoal properties of
   "speed" -> DynamicGoal Cycles
   "size" -> StaticGoal (ResourceUsage (read "BundleWidth"))

parseSolution json =
  case JSON.decode (BSL.pack json) of
   Nothing -> error ("error parsing JSON input")
   Just (Object s) -> s

solFromJson sol key =
    case JSON.fromJSON (sol HM.! key) of
      JSON.Error e -> error ("error converting JSON input:\n" ++ show e)
      JSON.Success s -> s
