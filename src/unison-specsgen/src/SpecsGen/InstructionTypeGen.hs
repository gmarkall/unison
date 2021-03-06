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
module SpecsGen.InstructionTypeGen (emitInstructionType) where

import SpecsGen.SimpleYaml
import SpecsGen.HsGen

emitInstructionType targetName is =
    let us2ids = infoToIds iType is
        rhss   = map (mkOpcRhs idToHsCon toInstructionTypeRhs) us2ids
    in [hsModule
        (moduleName targetName "InstructionType")
        (Just [hsExportVar "instructionType"])
        [unisonImport, instructionDeclImport targetName]
        [simpleOpcFunBind "instructionType" rhss]]

toInstructionTypeRhs = toHsCon . toInstructionType

toInstructionType t = toOpType t ++ "InstructionType"
