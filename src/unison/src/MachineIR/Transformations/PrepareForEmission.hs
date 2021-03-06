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
module MachineIR.Transformations.PrepareForEmission (prepareForEmission) where

import Data.List
import qualified Data.Map as M

import MachineIR

import Unison.Target.API
import Unison.Util

prepareForEmission mf target =
  let itf  = instructionType target
      bif  = branchInfo target
      oif  = operandInfo target
      fts  = M.fromList $ fallthroughBlock (mfBlocks mf)
      mf'  = mapToMachineBlock
             (addBlockSuccessor
              (itf, bif, oif, fts, mbId $ last (mfBlocks mf'))) mf
      mf'' = mapToMachineInstruction (addDefs oif) mf'
  in mf''

addBlockSuccessor (itf, bif, oif, fts, lastId)
  mb @ MachineBlock {mbProperties = mbps} =
  let succs = blockSuccessor itf bif oif fts lastId mb
      mbps' = mbps ++ [mkMachineBlockPropertySuccs succs]
  in mb {mbProperties = mbps'}

addDefs oif
  ms @ MachineSingle {msOpcode = opc, msOperands = ops, msProperties = ps} =
      case find isMachineInstructionPropertyDefs ps of
        Nothing ->
            let (_, ds) = splitMachineOperands oif opc ops
                ps'     = ps ++ [mkMachineInstructionPropertyDefs
                                 (toInteger $ length ds)]
            in ms {msProperties = ps'}
        (Just _) -> ms

blockSuccessor itf bif oif fts lastId
  MachineBlock {mbId = id, mbInstructions = mis} =
    case find (isMachineBranch itf) mis of
      Just j -> let i = fromMachineInstruction itf oif (-1, j)
                in successors bif (fts M.! id) i
      Nothing -> if id == lastId then [] else [fts M.! id]
