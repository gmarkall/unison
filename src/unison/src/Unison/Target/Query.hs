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
module Unison.Target.Query
    (resourceManager,
     ResourceManager(..),
     capacityMap,
     InstructionManager(..),
     instructionManager,
     tempLatencies,
     latencies,
     dataLatency,
     tempsToInfo,
     regClassOf)
    where

import Data.List
import Data.Maybe
import qualified Data.Map as M

import Common.Util

import Unison.Base hiding (toNode)
import Unison.Predicates
import Unison.Constructors
import Unison.Util
import Unison.Target.API

data ResourceManager i s = ResourceManager {
      iResources :: [IndexedResource s],
      iUsages    :: Instruction i -> [IndexedUsage s]
}

-- | Builds a representation of the resource model, including query
--   functions. Information about the resource model should be accessed through
--   this interface.
resourceManager :: Ord s => TargetWithOptions i r rc s -> ResourceManager i s
resourceManager target =
    let resf   = resources target
        res2id = M.fromList (zip (map resName resf) [0..])
        usf    = usages target
        usf'   = modelUsages resf usf
    in
     ResourceManager {
       iResources = map (\r -> IndexedResource (res2id M.! (resName r)) r) resf,
       iUsages    = map (\u -> IndexedUsage (res2id M.! (resource u)) u) . usf'
       }

modelUsages _ _ (General NullInstruction) = []
modelUsages _ _ (General VirtualInstruction) = []
modelUsages resf _ (General BarrierInstruction) =
  [Usage rn rc 1 | Resource {resName = rn, resCapacity = rc} <- resf]
modelUsages _ usf (TargetInstruction i) = usf i

data InstructionManager i r = InstructionManager {
      indexedInstructions    :: [IndexedInstruction i],
      oIInstructions         :: BlockOperation i r -> [IndexedInstruction i],
      activatorIInstructions :: BlockOperation i r -> [IndexedInstruction i],
      toIndexedInstruction   :: Instruction i -> IndexedInstruction i
}

capacityMap target =
    M.fromList [(resName r, resCapacity r) | r <- resources target]

-- | Builds an indexed representation of instructions.
instructionManager code =
    let instrs = IndexedInstruction 0 (General NullInstruction) :
                 IndexedInstruction 1 (General VirtualInstruction) :
                 IndexedInstruction 2 (General BarrierInstruction) :
                 map mkIndexedInstruction (zip [3..] (targetInstructions code))
        i2ii   = M.fromList $ [(instr, IndexedInstruction i instr) |
                               (IndexedInstruction i instr) <- instrs]
    in
      InstructionManager {
        indexedInstructions    = instrs,
        oIInstructions         = operationInstructions i2ii,
        activatorIInstructions = operationActivators i2ii,
        toIndexedInstruction   = (M.!) i2ii
    }

targetInstructions code =
  (nub $ concatMap oInstructions code) \\
  [mkNullInstruction, mkVirtualInstruction, mkBarrierInstruction]

mkIndexedInstruction (i, instr) = IndexedInstruction i instr

operationInstructions i2ii o = map ((M.!) i2ii) (oInstructions o)

operationActivators i2ii o = map ((M.!) i2ii) (oActivators o)

-- | Gives an association list with temporaries in the operation and operand
-- latencies corresponding to the given instruction.
tempLatencies oif o i =
  nub $ sort $ [(i, l) | (i, TemporaryInfo _ l) <- tempsToInfo oif o i]

-- | Gives an association list with temporaries in the operation and operand
-- info corresponding to the given instruction.
tempsToInfo oif o i =
  let (uInfo, dInfo) = oif i
  in zip (oUses o ++ oDefs o) (uInfo ++ dInfo)

-- | Gives the register class of t for the first instruction of operation o.
regClassOf oif o t =
  let i   = targetInst $ oInstructions o
      tif = M.fromList $ tempsToInfo oif o i
  in oiRegClass $ tif M.! t

-- | Gives the latency of an operation corresponding to all its instructions.
latencies rm o = map (instrLatency rm) (oAnnInstructions o)

-- | Gives the longest occupation time for the resource usages of the given
-- instruction
instrLatency _ (General NullInstruction, _) = Nothing
instrLatency _ (_, VirtualType (DelimiterType InType)) = Just 1
instrLatency _ (_, VirtualType FunType) = Just 1
instrLatency _ (General _, _) = Just 0
instrLatency rm (ti @ TargetInstruction {}, _) =
    Just $ maybeMax 0 $ map (occupation . usage) (iUsages rm ti)

-- | Gives the data latency for temporaries ts between instructions p and c.
dataLatency lfs t2ls ts p c =
  let t2l = M.fromListWith min $ concatMap (t2ls c) $ oTargetInstrs c
      l   = maximum $ map (operandLatency t2l) ts
  in map (fmap (+l)) (lfs p)

oTargetInstrs i = [o | (TargetInstruction o) <- oInstructions i]

operandLatency t2l t =
  let singleTemp = fromSingleton . extractTemps
      t'         = singleTemp t
      t2l'       = expandTemps t2l
  in fromMaybe 0 (M.lookup t' t2l')

expandTemps t2l =
  M.fromList $ concatMap (\(p, l) -> [(t, l) | t <- extractTemps p,
                                      not (isNullTemporary t)]) (M.toList t2l)
