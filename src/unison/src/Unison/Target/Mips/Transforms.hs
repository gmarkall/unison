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
module Unison.Target.Mips.Transforms
    (rs2ts,
     normalizeCallPrologue,
     normalizeCallEpilogue,
     extractReturnRegs) where

import Unison
import MachineIR
import Unison.Target.Mips.MipsRegisterDecl
import Unison.Target.Mips.SpecsGen.MipsInstructionDecl

-- | Gives patterns as sequences of instructions and replacements where
-- | registers are transformed into temporaries

rs2ts _ (
  m @ SingleOperation {
          oOpr = (Natural mi @ Linear {
                                   oIs = [TargetInstruction mName],
                                   oDs  = [Register rlo, Register rhi]})}
  :
  mflo @ SingleOperation {
          oOpr = (Natural mfloi @ Linear {oIs = [TargetInstruction MFLO]})}
  :
  mfhi @ SingleOperation {
          oOpr = (Natural mfhii @ Linear {oIs = [TargetInstruction MFHI]})}
  :
  rest) (ti, _, _) | mName `elem` [MULT, MULTu] =
  let tlo = mkPreAssignedTemp ti (Register rlo)
      thi = mkPreAssignedTemp (ti + 1) (Register rhi)
  in
   (
     rest,
     [m    {oOpr = Natural mi {oDs = [tlo, thi]}},
      mflo {oOpr = Natural mfloi {oUs = [tlo]}},
      mfhi {oOpr = Natural mfhii {oUs = [thi]}}]
   )

rs2ts _ (
  m @ SingleOperation {
        oOpr = (Natural mi @ (Linear {
                                 oIs = [TargetInstruction mName],
                                 oDs  = [Register rlo, Register rhi]}))}
  :
  mfhi @ SingleOperation {
        oOpr = (Natural mfhii @ Linear {oIs = [TargetInstruction MFHI]})}
  :
  rest) (ti, _, _) | mName `elem` [MULT, MULTu] =
  let tlo = mkPreAssignedTemp ti (Register rlo)
      thi = mkPreAssignedTemp (ti + 1) (Register rhi)
  in
   (
     rest,
     [m    {oOpr = Natural mi {oDs = [tlo, thi]}},
      mfhi {oOpr = Natural mfhii {oUs = [thi]}}]
   )

rs2ts _ (
  m @ SingleOperation {
        oOpr = Natural mi @ (Linear {
                                oIs = [TargetInstruction mName],
                                oDs  = [Register rlo, Register rhi]})}
  :
  mflo @ SingleOperation {
        oOpr = Natural mfloi @ (Linear {oIs = [TargetInstruction MFLO]})}
  :
  rest) (ti, _, _) | mName `elem` [MULT, MULTu] =
  let tlo = mkPreAssignedTemp ti (Register rlo)
      thi = mkPreAssignedTemp (ti + 1) (Register rhi)
  in
   (
     rest,
     [m    {oOpr = Natural mi {oDs = [tlo, thi]}},
      mflo {oOpr = Natural mfloi {oUs = [tlo]}}]
   )

rs2ts _ (
  d @ SingleOperation {
        oOpr = Natural di @ (Linear {
                                oIs = [TargetInstruction DIV],
                                oDs  = [Register rlo, Register rhi]})}
  :
  mflo @ SingleOperation {
        oOpr = Natural mfloi @ (Linear {oIs = [TargetInstruction MFLO]})}
  :
  rest) (ti, _, _) =
  let tlo = mkPreAssignedTemp ti (Register rlo)
      thi = mkPreAssignedTemp (ti + 1) (Register rhi)
  in
   (
     rest,
     [d    {oOpr = Natural di {oDs = [tlo, thi]}},
      mflo {oOpr = Natural mfloi {oUs = [tlo]}}]
   )


rs2ts _ (
  SingleOperation {
    oId = ucloId, oOpr = Virtual (VirtualCopy {oVirtualCopyS = tUclo,
                                                oVirtualCopyD = Register rlo})}
  :
  SingleOperation {
    oId = uchoId, oOpr = Virtual (VirtualCopy {oVirtualCopyS = tUchi,
                                                oVirtualCopyD = Register rhi})}
  :
  madd @ SingleOperation {
           oOpr = Natural mi @ (Linear {oIs = [TargetInstruction MADD],
                                         oUs  = [_, _, u1, u2]})}
  :
  SingleOperation {
    oId = dcloId, oOpr = Virtual (VirtualCopy {oVirtualCopyD = tDclo})}
  :
  SingleOperation {
    oId = dchoId, oOpr = Virtual (VirtualCopy {oVirtualCopyD = tDchi})}
  :
  rest) (ti, _, _) =
  let tlo  = mkPreAssignedTemp ti (Register rlo)
      thi  = mkPreAssignedTemp (ti + 1) (Register rhi)
      tlo' = mkPreAssignedTemp (ti + 2) (Register rlo)
      thi' = mkPreAssignedTemp (ti + 3) (Register rhi)
  in
   (
     rest,
     [mkLinear ucloId [TargetInstruction MTLO] [tUclo] [tlo],
      mkLinear uchoId [TargetInstruction MTHI] [tUchi] [thi],
      madd {oOpr = Natural mi {oUs = [tlo, thi, u1, u2], oDs = [tlo', thi']}},
      mkLinear dcloId [TargetInstruction MFLO] [tlo'] [tDclo],
      mkLinear dchoId [TargetInstruction MFHI] [thi'] [tDchi]
     ]
   )

rs2ts _ (inst : rest) _ = (rest, [inst])

-- | Matches call prologues and pre-assigns a temp to the return address

normalizeCallPrologue _ (
  c @ SingleOperation {oOpr = Virtual (ci @ VirtualCopy {
                                                oVirtualCopyD = Register r})}
  :
  ca1 : ca2 : ca3 : ca4 : ca5
  :
  j @ SingleOperation {oOpr = Natural ji @ (Call {oCallUs = [Register r']})}
  :
  rest) (ti, _, _) | r == r' && all isVirtualCopy [ca1, ca2, ca3, ca4, ca5] =
  let t = mkTemp ti
  in
    (rest,
     [c {oOpr = Virtual ci {oVirtualCopyD = t}},
      ca1, ca2, ca3, ca4, ca5,
      j {oOpr = Natural ji {oCallUs = [preAssign t (Register r)]}}]
    )

normalizeCallPrologue _ (
  c @ SingleOperation {oOpr = Virtual (ci @ VirtualCopy {
                                                oVirtualCopyD = Register r})}
  :
  ca1 : ca2 : ca3 : ca4
  :
  j @ SingleOperation {oOpr = Natural ji @ (Call {oCallUs = [Register r']})}
  :
  rest) (ti, _, _) | r == r' && all isVirtualCopy [ca1, ca2, ca3, ca4] =
  let t = mkTemp ti
  in
    (rest,
     [c {oOpr = Virtual ci {oVirtualCopyD = t}},
      ca1, ca2, ca3, ca4,
      j {oOpr = Natural ji {oCallUs = [preAssign t (Register r)]}}]
    )

normalizeCallPrologue _ (
  c @ SingleOperation {oOpr = Virtual (ci @ VirtualCopy {
                                                oVirtualCopyD = Register r})}
  :
  ca1 : ca2 : ca3
  :
  j @ SingleOperation {oOpr = Natural ji @ (Call {oCallUs = [Register r']})}
  :
  rest) (ti, _, _) | r == r' && all isVirtualCopy [ca1, ca2, ca3] =
  let t = mkTemp ti
  in
    (rest,
     [c {oOpr = Virtual ci {oVirtualCopyD = t}},
      ca1, ca2, ca3,
      j {oOpr = Natural ji {oCallUs = [preAssign t (Register r)]}}]
    )

normalizeCallPrologue _ (
  c @ SingleOperation {oOpr = Virtual (ci @ VirtualCopy {
                                                oVirtualCopyD = Register r})}
  :
  ca1 : ca2
  :
  j @ SingleOperation {oOpr = Natural ji @ (Call {oCallUs = [Register r']})}
  :
  rest) (ti, _, _) | r == r' && all isVirtualCopy [ca1, ca2] =
  let t = mkTemp ti
  in
    (rest,
     [c {oOpr = Virtual ci {oVirtualCopyD = t}},
      ca1, ca2,
      j {oOpr = Natural ji {oCallUs = [preAssign t (Register r)]}}]
    )

normalizeCallPrologue _ (
  c @ SingleOperation {oOpr = Virtual (ci @ VirtualCopy {
                                                oVirtualCopyD = Register r})}
  :
  ca
  :
  j @ SingleOperation {oOpr = Natural ji @ (Call {oCallUs = [Register r']})}
  :
  rest) (ti, _, _) | r == r' && isVirtualCopy ca =
  let t = mkTemp ti
  in
    (rest,
     [c {oOpr = Virtual ci {oVirtualCopyD = t}},
      ca,
      j {oOpr = Natural ji {oCallUs = [preAssign t (Register r)]}}]
    )

normalizeCallPrologue _ (
  c @ SingleOperation {oOpr = Virtual (ci @ VirtualCopy {
                                                oVirtualCopyD = Register r})}
  :
  j @ SingleOperation {oOpr = Natural ji @ (Call {oCallUs = [Register r']})}
  :
  rest) (ti, _, _) | r == r' =
  let t = mkTemp ti
  in
    (rest,
     [c {oOpr = Virtual ci {oVirtualCopyD = t}},
      j {oOpr = Natural ji {oCallUs = [preAssign t (Register r)]}}]
    )

normalizeCallPrologue _ (inst : rest) _ = (rest, [inst])

-- | Matches call epilogues

normalizeCallEpilogue _ (
  lw @ SingleOperation {
          oOpr = Natural (Linear {oIs = [TargetInstruction LW],
                                   oUs  = [Bound MachineImm {},
                                           Register (TargetRegister SP)],
                                   oDs  = []})}
  :
  c1 @ SingleOperation {
        oOpr = Virtual VirtualCopy {oVirtualCopyS = Register _,
                                    oVirtualCopyD = t}}
  :
  c2 @ SingleOperation {
        oOpr = Virtual VirtualCopy {oVirtualCopyS = Register _,
                                    oVirtualCopyD = t'}}
  :
  rest) _ | all isTemporary [t, t'] = (rest, [c1, c2, lw])

normalizeCallEpilogue _ (
  lw @ SingleOperation {
          oOpr = Natural (Linear {oIs = [TargetInstruction LW],
                                   oUs  = [Bound MachineImm {},
                                           Register (TargetRegister SP)],
                                   oDs  = []})}
  :
  c @ SingleOperation {
        oOpr = Virtual VirtualCopy {oVirtualCopyS = Register _,
                                     oVirtualCopyD = t}}
  :
  rest) _ | isTemporary t = (rest, [c, lw])

normalizeCallEpilogue _ (inst : rest) _ = (rest, [inst])

{-
    o41: [V0] <- (copy) [t5]
    o42: [] <- RetRA []
    o49: [] <- (out) [V0]

    ->

    o41: [t'] <- (copy) [t5]
    o42: [] <- RetRA []
    o49: [] <- (out) [t':V0]
    -}

extractReturnRegs _ (
  c @ SingleOperation {oOpr = Virtual (ci @ VirtualCopy {
                                                oVirtualCopyD = Register ret})}
  :
  r @ SingleOperation {oOpr = Natural Branch {oBranchIs = [TargetInstruction RetRA]}}
  :
  o @ SingleOperation {oOpr = Virtual
                               (Delimiter oi @ (Out {oOuts = [Register ret']}))}
  :
  rest) (ti, _, _) | ret == ret' =
  let t = mkTemp ti
  in
   (
    rest,
    [c {oOpr = Virtual ci {oVirtualCopyD = t}},
     r,
     o {oOpr = Virtual (Delimiter oi {
                            oOuts = [preAssign t (Register ret)]})}]
   )

extractReturnRegs _ (inst : rest) _ = (rest, [inst])
