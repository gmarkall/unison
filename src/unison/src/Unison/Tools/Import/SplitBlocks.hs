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
module Unison.Tools.Import.SplitBlocks (splitBlocks) where

import Data.List
import Data.List.Split
import Data.Ord
import qualified Data.Map as M

import Unison

splitBlocks maxBlockSize f @ Function {fCode = code} _target =
  let bid     = newBlockIndex code
      oid     = newId code
      ((_, _, lastB),
          bs) = mapAccumL (splitBlock maxBlockSize) (bid, oid, M.empty) code
      code'   = mapToOperationInBlocks (applyToPhiOps (applyMap lastB)) (concat bs)
  in f {fCode = code'}

splitBlock maxSize acc b @ Block {bCode = code} =
  let last     = toInteger $ length code - 3
      (_, ps)  = mapAccumL (splittable code) Splittable (zip [0..] code)
      possible = concat (init ps)
      ideal    = [maxSize, maxSize + maxSize .. last]
      final    = map (\i -> minimumBy (comparing (distanceTo i)) possible) ideal
      lengths  = distances (toInteger $ length code) final
  in case lengths of
      []      -> (acc, [b])
      lengths -> splitIntoBlocks lengths acc b

data SplitState i = Splittable | WithinPack | WithinCall | PostCall Integer

{-
This assumes the following code sequence for function calls:
  [] <- callr [...]
  [t1, t2, ...] <- (fun) [...] (call: (the one before))
  [] <- (kill) [t1, t2, ...] (optional)
-}

splittable _ Splittable (_, o) | isDelimiter o = (Splittable, [])
splittable _ Splittable (_, o) | isCall o = (WithinCall, [])
splittable _ WithinCall (p, o) | isFun o = (PostCall p, [])
splittable _ (PostCall p') (p, o)
    | isKill o  = (Splittable, [p])
    | otherwise = (Splittable, [p', p])
splittable code Splittable (_, o) | isPacked code o = (WithinPack, [])
splittable _ WithinPack (p, o)
     | isPack o = (Splittable, [p])
     | otherwise = (WithinPack, [])
splittable _ Splittable (p, _) = (Splittable, [p])

isPacked code o = any (isPackedTemp code) $ filter isTemporary (oDefs o)

isPackedTemp code t =
  let t' = undoPreAssign t
  in any isPack $users t' code

distanceTo x y = abs (y - x)

distances n (x:list) = x+1:distances1 n (x:list)
distances _ []       = []

distances1 n (x:y:list) = y-x:distances1 n (y:list)
distances1 n (x:[])     = [n-x-1]
distances1 _ []         = []

splitIntoBlocks lengths (bid, oid, lastB)
                Block {bLab = l, bCode = code, bAs = attrs} =
  let codes  = splitPlaces lengths code
      bs1    = zipWith (curry mkNewBlock) [bid..] codes
      bs2    = (head bs1) {bLab = l} : tail bs1
      bs3    = copyBlockAttrs attrs [(aEntry, copyEntry)] (head bs2) : tail bs2
      bs4    = init bs3 ++ [copyBlockAttrs attrs
                            [(aExit, copyExit), (aReturn, copyReturn)]
                            (last bs3)]
      bs5    = map (copyBlockAttrs attrs [(aFreq, copyFreq)]) bs4
      bs6    = zipWith (curry addIn) [oid..] bs5
      bs7    = zipWith (curry addOut) [newId bs6..] bs6
      bs8    = [head bs7] ++ map addSplit (tail bs7)
      bid'   = newBlockIndex bs8
      oid'   = newId bs8
      lastB' = M.insert l (bLab $ last bs8) lastB
  in ((bid', oid', lastB'), bs8)

addIn (oid, b @ Block {bCode = code})
  | any isIn code = b
  | otherwise     = b {bCode = mkIn oid [] : code}

addOut (oid, b @ Block {bCode = code})
  | any isOut code = b
  | otherwise      = b {bCode = code ++ [mkOut oid []]}

mkNewBlock (bid, code) = mkBlock bid mkNullBlockAttributes code

copyBlockAttrs srcAttrs afs b @ Block {bAs = dstAttrs} =
  b {bAs = foldl (copyBlockAttr srcAttrs) dstAttrs afs}

copyBlockAttr srcAttrs dstAttrs (af, cf) = cf dstAttrs (af srcAttrs)

copyEntry  attrs v = attrs {aEntry = v}
copyFreq   attrs v = attrs {aFreq = v}
copyExit   attrs v = attrs {aExit = v}
copyReturn attrs v = attrs {aReturn = v}

applyToPhiOps lastB o
    | isPhi o = mapToOperandIf isBlockRef (replaceBlockRef lastB) o
    | otherwise = o

replaceBlockRef lastB (BlockRef l) = mkBlockRef (lastB l)

addSplit b @ Block {bAs = attrs} = b {bAs = attrs {aSplit = True}}
