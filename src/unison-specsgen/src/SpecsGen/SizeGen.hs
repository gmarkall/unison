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
module SpecsGen.SizeGen (emitSize) where

import SpecsGen.SimpleYaml
import SpecsGen.HsGen

emitSize targetName is =
    let us2ids = infoToIds iSize is
        rhss   = map (mkOpcRhs idToHsCon toSizeRhs) us2ids
    in [hsModule
        (moduleName targetName "Size")
        (Just [hsExportVar "size"])
        [instructionDeclImport targetName]
        [simpleOpcFunBind "size" rhss]]

toSizeRhs = toHsInt
