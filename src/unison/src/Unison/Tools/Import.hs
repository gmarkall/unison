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
module Unison.Tools.Import (run) where

import Data.List
import Data.Maybe
import System.FilePath
import Control.Monad

import Unison.Base
import Unison.Driver
import Unison.Tools.Lint (invokeLint)

import qualified MachineIR as MachineIR

import Unison.Construction.AddDelimiters
import Unison.Construction.LiftGoal
import Unison.Construction.BuildFunction

import MachineIR.Transformations.LiftCustomProperties
import MachineIR.Transformations.LiftJumpTables
import MachineIR.Transformations.SimplifyFallthroughs
import MachineIR.Transformations.SplitTerminators
import MachineIR.Transformations.RenameMachineBlocks

import Unison.Transformations.RenameBlocks
import Unison.Transformations.PostponeBranches
import Unison.Transformations.RenameTemps
import Unison.Transformations.SortGlobalTemps
import Unison.Transformations.RenameOperations
import Unison.Transformations.EstimateFrequency
import Unison.Transformations.NormalizeFrequency
import Unison.Transformations.AddPragmas
import Unison.Transformations.RunTargetTransforms

import Unison.Tools.Import.DropDebugLocations
import Unison.Tools.Import.NormalizePhis
import Unison.Tools.Import.LiftMemoryPartitions
import Unison.Tools.Import.DropEHLabels
import Unison.Tools.Import.ExtractSubRegs
import Unison.Tools.Import.LowerInsertSubRegs
import Unison.Tools.Import.LowerSubRegVirtuals

import Unison.Tools.Import.RunPreProcess
import Unison.Tools.Import.CorrectDoubleBranches
import Unison.Tools.Import.AdjustPhiLabels
import Unison.Tools.Import.SimplifyCombinations
import Unison.Tools.Import.RemoveUselessVirtuals
import Unison.Tools.Import.RelocateDefines
import Unison.Tools.Import.ExtractCallRegs
import Unison.Tools.Import.LiftRegs
import Unison.Tools.Import.EnforceCallerSaved
import Unison.Tools.Import.LiftUndefRegs
import Unison.Tools.Import.KillUnusedTemps
import Unison.Tools.Import.ExtractRegs
import Unison.Tools.Import.EnforceCalleeSaved
import Unison.Tools.Import.ReserveRegs
import Unison.Tools.Import.ImplementFrameOperations
import Unison.Tools.Import.FoldCopies
import Unison.Tools.Import.SplitBlocks
import Unison.Tools.Import.RepairCSSA
import Unison.Tools.Import.AdvancePhis

run (estimateFreq, noCC, noReserved, maxBlockSize, implementFrames, function,
     goal, mirFile, debug, intermediate, lint, uniFile) mir target =
    let mf = selectFunction function $ MachineIR.parse mir
        (mf', partialMfs) =
            applyTransformations
            (mirTransformations estimateFreq)
            target mf
        ff = buildFunction target mf'
        (f, partialFs) =
            applyTransformations
            (uniTransformations (goal, noCC, noReserved, maxBlockSize,
                                 estimateFreq, implementFrames))
            target ff
        baseName = takeBaseName mirFile
    in do when debug $
               putStr (toPlainText (partialMfs ++ partialFs))
          when intermediate $
               mapM_ (writeIntermediateFile "uni" baseName) partialFs
          emitOutput uniFile (show f)
          when lint $
               invokeLint f target

mirTransformations estimateFreq =
    [(dropDebugLocations, "dropDebugLocations", True),
     (normalizePhis, "normalizePhis", True),
     (liftCustomProperties, "liftMemoryPartitions", True),
     (liftJumpTables, "liftJumpTables", True),
     (liftMemoryPartitions, "liftMemoryPartitions", True),
     (simplifyFallthroughs, "simplifyFallthroughs", True),
     (renameMachineBlocks, "renameMachineBlocks", True),
     (splitTerminators estimateFreq, "splitTerminators", True),
     (renameMachineBlocks, "renameMachineBlocks", True),
     (dropEHLabels, "dropEHLabels", True),
     (extractSubRegs, "extractSubRegs", True),
     (lowerInsertSubRegs, "lowerInsertSubRegs", True),
     (lowerSubRegVirtuals, "lowerSubRegVirtuals", True),
     (runPreProcess, "runPreProcess", True)]

uniTransformations (goal, noCC, noReserved, maxBlockSize, estimateFreq,
                    implementFrames) =
    [(liftGoal goal, "liftGoal", True),
     (addDelimiters, "addDelimiters", True),
     (postponeBranches, "postponeBranches", True),
     (correctDoubleBranches, "correctDoubleBranches", True),
     (adjustPhiLabels, "adjustPhiLabels", True),
     (simplifyCombinations, "simplifyCombinations", True),
     (removeUselessVirtuals, "removeUselessVirtuals", True),
     (relocateDefines, "relocateDefines", True),
     (runTargetTransforms ImportPreLift, "runTargetTransforms", True),
     (extractCallRegs, "extractCallRegs", True),
     (liftRegs, "liftRegs", True),
     (runTargetTransforms ImportPostLift, "runTargetTransforms", True),
     (enforceCallerSaved, "enforceCallerSaved", not noCC),
     (enforceCalleeSaved, "enforceCalleeSaved", not noCC),
     (reserveRegs, "reserveRegs", not noReserved),
     (implementFrameOperations implementFrames, "implementFrameOperations", True),
     (liftUndefRegs, "liftUndefRegs", True),
     (killUnusedTemps, "killUnusedTemps", True),
     (extractRegs, "extractRegs", True),
     (foldCopies, "foldCopies", True),
     (splitBlocks (fromJust maxBlockSize), "splitBlocks", isJust maxBlockSize),
     (renameBlocks, "renameBlocks", True),
     (repairCSSA, "repairCSSA", True),
     (advancePhis, "advancePhis", True),
     (postponeBranches, "postponeBranches", True),
     (renameTemps, "renameTemps", True),
     (sortGlobalTemps, "sortGlobalTemps", True),
     (renameOperations, "renameOperations", True),
     (estimateFrequency, "estimateFrequency", estimateFreq),
     (normalizeFrequency, "normalizeFrequency", True),
     (addPragmas importPragmas, "addPragmas", True)]

importPragmas =
    [("lint",
      "--nomustconflicts=false " ++
      "--nocostoverflow=false " ++
      "--nocomponentconflicts=false")]

selectFunction Nothing [mf] = mf
selectFunction (Just name) mfs =
  case find (\mf -> MachineIR.mfName mf == name) mfs of
    Just mf -> mf
    Nothing -> error ("could not find specified MIR function " ++ show name)
