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
module Unison.Target.ARM.OperandInfo (operandInfo) where

import Unison
import Unison.Target.ARM.ARMRegisterClassDecl
import Unison.Target.ARM.SpecsGen.ARMInstructionDecl
import qualified Unison.Target.ARM.SpecsGen as SpecsGen

-- | Gives information about the operands of each instruction

operandInfo i
  -- The generated operandInfo is wrong for these instructions
  | i `elem` [TTAILJMPd, TTAILJMPdND] =
    ([BoundInfo, BoundInfo, TemporaryInfo (RegisterClass CCR) 0],
     [])
  | otherwise = SpecsGen.operandInfo i
