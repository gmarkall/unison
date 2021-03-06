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
module SpecsGen.HsGen
    (
     constantExtendedOperation,
     expand,
     promote,
     update,
     dummySrcLoc,
     name,
     infoToIds,
     opcOpsFunBind,
     targetInstructionCon,
     simpleOpcFunBind,
     simpleFun,
     constantFun,
     simpleErrorRhs,
     hsModule,
     hsExportDataType,
     hsExportVar,
     unisonImport,
     instructionDeclImport,
     registerDeclImport,
     itineraryDeclImport,
     registerClassDeclImport,
     hsFun,
     hsDataDecl,
     hsItinDecl,
     hsInstDecl,
     opcPVar,
     mkOpcRhs,
     toHsStr,
     toHsVar,
     toHsInt,
     toHsCon,
     toHsPStr,
     toHsPVar,
     toHsList,
     opToHsVar,
     idToHsCon,
     redefNameIfIn,
     renameRedefs,
     mkOperandMap,
     toVarName,
     toRedefName,
     toVarList,
     toOpType,
     toConstantExtendedOp,
     isConstantExtendedOp,
     moduleName
    )
    where

import Data.List
import Data.Char
import qualified Data.Map as M
import Language.Haskell.Syntax
import qualified Data.Text as T
import Control.Arrow
import Text.Regex.Posix

import SpecsGen.SimpleYaml

constantExtendedOperation i
  | isConstantExtendable i =
    let oldId  = YString (oId i)
        newId  = YString $ toConstantExtendedOp $ yString oldId
        i'     = yApply (yReplaceString oldId newId) i
    in Just i'
  | otherwise = Nothing

isConstantExtendable i =
  any (isConstantExtendableOp . simplifyOperand) $ iOperands i

isConstantExtendableOp (_, YBoundInfo) = True
isConstantExtendableOp (_, YBlockRefInfo) = True
isConstantExtendableOp _ = False

expand is =
  let id2i = M.fromList $ map (\i -> (oId i, i)) is
      is'  = map (maybeExpandInstr id2i) is
  in is'

maybeExpandInstr id2i i =
  case iParent i of
   Nothing -> i
   Just p ->
     let i1 = id2i M.! p
         i2 = foldl replaceField i1 (yMap i)
         i3 = addField (YString "parent", YString p) i2
     in i3

replaceField i (YString "parent", _) = i
replaceField (YMap fs) f = YMap (map (replace f) fs)

replace (YString newk, newv) (YString oldk, oldv)
  | newk == oldk = (YString newk, newv)
  | otherwise = (YString oldk, oldv)

addField f (YMap fs) = YMap (fs ++ [f])

promote effectPats i =
    let effs   = map (\p -> second tail $ break (\c -> c == ':') p) effectPats
        effs'  = [e | (e, p) <- effs, oId i =~ p]
    in doPromote effs' i

doPromote effs i =
    let rs    = sideEffects $ iAffectedBy i
        ws    = sideEffects $ iAffects i
        i1    = foldl (explicateEffect (rs, ws)) i effs
    in i1

explicateEffect (rs, ws) i eff =
  let i1 = if eff `elem` rs then addEffectOperand (eff ++ "_use") "use" i  else i
      i2 = if eff `elem` ws then addEffectOperand (eff ++ "_def") "def" i1 else i1
      i3 = if eff `elem` rs then addToOperands (eff ++ "_use") "uses" i2 else i2
      i4 = if eff `elem` ws then addToOperands (eff ++ "_def") "defines" i3 else i3
  in i4

addEffectOperand name typ i =
    let ps = [YString "register", YString typ, YString "Unknown"]
    in yApplyTo (YString "operands")
       (yAddToSeq (YMap [(YString name, YSeq ps)])) i

addToOperands name list i = yApplyTo (YString list) (yAddToSeq (YString name)) i

update regClasses i = foldl updateRegClass i regClasses

updateRegClass i regClass =
  let (operand,
       rclass) = second tail $ break (\c -> c == ':') regClass
      (us, ds) = iUseDefs i
  in doUpdateRegClass (operand `elem` us, operand `elem` ds) (operand, rclass) i

doUpdateRegClass (False, False) _ i = i
doUpdateRegClass ud (operand, rclass) i =
  let usedef = case ud of
        (True, True) -> "usedef"
        (True, False) -> "use"
        (False, True) -> "def"
      i' = updateOperandInInstr operand
           (YSeq [YString "register",YString usedef,YString rclass]) i
  in i'

updateOperandInInstr k v (YMap fs) =
  let fs' = map (updateOperandInFields k v) fs
  in (YMap fs')

updateOperandInFields k v (YString "operands", YSeq ops) =
  (YString "operands", YSeq (map (updateOperand k v) ops))
updateOperandInFields _ _ f = f

updateOperand k v op @ (YMap [(YString k', _)])
  | k == k' = (YMap [(YString k, v)])
  | otherwise = op

yApplyTo p f (YMap s) = YMap [(k, if k == p then f v else v) | (k, v) <- s]

yAddToSeq e (YSeq s) = YSeq (s ++ [e])
yAddToSeq e YNil = YSeq [e]

sideEffects affs = [e | (YOtherSideEffect e) <- toAffectsList affs]

dummySrcLoc = SrcLoc "" 1 1
name = UnQual . HsIdent

infoToIds iF is =
    let infoId  = [(iF i, [oId i]) | i <- is]
        info2id = sort $ M.toList $ M.fromListWith (++) infoId
    in info2id

opcOpsFunBind n ((us, ds), rhss) = funBind [opcPVar, HsPTuple [us, ds]] n rhss

hsModule n e i d = HsModule dummySrcLoc (Module n) e i d

hsExportDataType n = HsEThingAll (name n)

hsExportVar n = HsEVar (name n)

unisonImport = hsImport "Unison"

instructionDeclImport targetName =
    hsImport ("Unison.Target." ++ targetName ++ ".SpecsGen." ++
              targetName ++ "InstructionDecl")

registerDeclImport targetName =
    hsImport ("Unison.Target." ++ targetName ++ "." ++
              targetName ++ "RegisterDecl")

itineraryDeclImport targetName =
    hsImport ("Unison.Target." ++ targetName ++ ".SpecsGen." ++
              targetName ++ "ItineraryDecl")

registerClassDeclImport targetName =
    hsImport ("Unison.Target." ++ targetName ++ "." ++
              targetName ++ "RegisterClassDecl")

hsImport n = HsImportDecl dummySrcLoc (Module n) False Nothing Nothing

funBind as n = hsFunBind n as

targetInstructionCon targetName = targetName ++ "Instruction"

simpleOpcFunBind n = hsFunBind n [opcPVar]

simpleFun op n = hsFun n [op]

constantFun n rhs = hsFun n [] rhs

hsFunBind n h rhss = mkHsFun n h (HsGuardedRhss rhss)
hsFun n h rhs = mkHsFun n h (HsUnGuardedRhs rhs)
mkHsFun n h g =
    HsFunBind
    [
     HsMatch
     dummySrcLoc
     (HsIdent n)
     h
     g
     []
    ]

simpleErrorRhs n =
  simpleFun (toHsPVar "a") n
  (HsApp (toHsVar "error")
   (HsParen
    (HsInfixApp (toHsStr ("unmatched: " ++ n ++ " "))
     (HsQVarOp (UnQual $ HsSymbol "++"))
                (HsApp (toHsVar "show") (toHsVar "a")))))

hsDataDecl targetName cs =
  HsDataDecl dummySrcLoc [] (HsIdent (targetInstructionCon targetName)) []
  [HsConDecl dummySrcLoc (HsIdent c) [] | c <- cs]
  [name "Eq", name "Ord"]

hsItinDecl targetName cs =
  HsDataDecl dummySrcLoc [] (HsIdent (targetName ++ "Itinerary")) []
  [HsConDecl dummySrcLoc (HsIdent c) [] | c <- cs]
  [name "Eq", name "Read", name "Show"]

hsInstDecl targetName ss =
  HsInstDecl dummySrcLoc [] (name "Show")
  [HsTyVar (HsIdent (targetInstructionCon targetName))] ss

opcPVar = toHsPVar "i"

mkOpcRhs f iF (info, ids) =
    let sids   = sort ids
        idList = map f sids
        hsInfo = iF info
        i      = toHsVar "i"
        cond   = HsInfixApp i (HsQVarOp (name "elem")) (HsList idList)
    in HsGuardedRhs dummySrcLoc cond hsInfo

toHsStr = HsLit . HsString
toHsVar = HsVar . name
toHsInt = HsLit . HsInt
toHsCon = HsCon . name
toHsPStr = HsPLit . HsString
toHsPVar = HsPVar . HsIdent
toHsList = HsList

idToHsCon = toHsCon . toOpType

renameRedefs (l1, l2) = (l1, map (redefNameIfIn l1) l2)
redefNameIfIn l s = if s `elem` l then toRedefName s else s
toRedefName = (++ "'")

mkOperandMap a =
  let o2info  = map simplifyOperand a
      o2info' = M.fromList o2info
  in o2info'

toVarName "0"   = "zero"
toVarName (c:l) = toLower c : l

toVarList = HsPList . map toHsPVar

toOpType (c:l) = stringReplace "." "" (toUpper c : l)

opToHsVar = toHsVar . toVarName

toConstantExtendedOp op = op ++ "_ce"

isConstantExtendedOp op = "_ce" `isSuffixOf` op

stringReplace s1 s2 = T.unpack . T.replace (T.pack s1) (T.pack s2) . T.pack

moduleName targetName suffix =
    "Unison.Target." ++ targetName ++ ".SpecsGen." ++ suffix
