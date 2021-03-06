{-|
Copyright   :  Copyright (c) 2016, SICS Swedish ICT AB
License     :  BSD3 (see the LICENSE file)
Maintainer  :  rcas@sics.se

Support to parse MIR functions (see <http://llvm.org/docs/MIRLangRef.html>).

-}
{-
Main authors:
  Roberto Castaneda Lozano <rcas@sics.se>

This file is part of Unison, see http://unison-code.github.io
-}
{-# LANGUAGE OverloadedStrings, FlexibleContexts, CPP #-}
module MachineIR.Parser
       (MachineIR.Parser.parse, mirOperand, mirFI, mirJTI) where

import Data.Maybe
import Data.Char
import Data.List.Split hiding (sepBy, endBy)
import Data.Yaml
#if (!defined(__GLASGOW_HASKELL__)) || (__GLASGOW_HASKELL__ < 710)
import Control.Applicative ((<$>),(<*>))
#endif
import Text.ParserCombinators.Parsec as P
import qualified Text.Parsec.Token as T
import Text.Parsec.Language (emptyDef)

import Common.Util
import MachineIR.Base
import MachineIR.Constructors
import MachineIR.Util

parse :: Read i => Read r => String -> [MachineFunction i r]
parse input =
  let docs = split onDocumentEnd input
  in [parseFunction (rawIR, rawMIR) | [rawIR, rawMIR] <- chunksOf 2 docs]

parseFunction :: Read i => Read r => (String, String) -> MachineFunction i r
parseFunction (rawIR, rawMIR) =
  let ir  = decodeYaml rawIR  :: String
      mir = decodeYaml rawMIR :: MIRFunction
      mjt = fmap toMachineFunctionPropertyJumpTable (jumpTable mir)
      mfs = fmap toMachineFunctionPropertyFixedStack (fixedStack mir)
      ms  = fmap toMachineFunctionPropertyStack (stack mir)
      mf  = case P.parse mirBody "" (body mir) of
        Left e -> error ("error parsing body:\n" ++ show e)
        Right mf -> mf {mfName = name mir, mfIR = ir,
                        mfProperties = maybeToList mjt ++ maybeToList mfs ++
                                       maybeToList ms}
      mf1 = mapToMachineInstruction readTargetOpcode mf
      mf2 = mapToMachineInstruction (mapToMachineOperand readOperand) mf1
  in mf2


data MIRFunction = MIRFunction {
  name :: String,
  fixedStack :: Maybe [MIRStackObject],
  stack :: Maybe [MIRStackObject],
  jumpTable :: Maybe MIRJumpTable,
  body :: String
} deriving Show

instance FromJSON MIRFunction where
    parseJSON (Object v) =
      MIRFunction <$>
      (v .: "name") <*>
      (v .:? "fixedStack") <*>
      (v .:? "stack") <*>
      (v .:? "jumpTable") <*>
      (v .: "body")
    parseJSON _ = error "Can't parse MIRFunction from YAML"

data MIRStackObject = MIRStackObject {
  sId        :: Integer,
  sOffset    :: Integer,
  sSize      :: Maybe Integer,
  sAlignment :: Integer
} deriving Show

instance FromJSON MIRStackObject where
    parseJSON (Object v) =
      MIRStackObject <$>
      (v .:  "id") <*>
      (v .:  "offset") <*>
      (v .:? "size") <*>
      (v .:  "alignment")
    parseJSON _ = error "Can't parse MIRStackObject from YAML"

data MIRJumpTable = MIRJumpTable {
  kind    :: String,
  entries :: [MIRJumpTableEntry]
} deriving Show

instance FromJSON MIRJumpTable where
    parseJSON (Object v) =
      MIRJumpTable <$>
      (v .: "kind") <*>
      (v .: "entries")
    parseJSON _ = error "Can't parse MIRJumpTable from YAML"

data MIRJumpTableEntry = MIRJumpTableEntry {
  jtId     :: Integer,
  jtBlocks :: [String]
} deriving Show

instance FromJSON MIRJumpTableEntry where
    parseJSON (Object v) =
      MIRJumpTableEntry <$>
      (v .: "id") <*>
      (v .: "blocks")
    parseJSON _ = error "Can't parse MIRJumpTableEntry from YAML"

mirBody =
  do blocks <- many mirBlock
     eof
     return (mkMachineFunction "" [] blocks "")

mirBlock =
  do id <- mirBlockId
     whiteSpace
     attrs <- option [] (parens (mirBlockAttribute `sepBy` comma))
     char ':'
     eol
     succs <- optionMaybe (try mirBlockSuccessors)
     entry <- optionMaybe (try mirBlockLiveIns)
     ret   <- optionMaybe (try mirBlockLiveOuts)
     exit  <- optionMaybe (try mirBlockExit)
     many eol
     instructions <- many mirInstruction
     many eol
     return (mkMachineBlock id
             (concatAttributes attrs succs)
             (concatInstructions id entry ret exit instructions))

mirBlockId =
  do string "bb."
     id <- decimal
     optional mirBlockName
     return id

mirBlockName =
  do char '.'
     name <- many1 alphaNumDashDotUnderscore
     return name

mirBlockAttribute =
  try mirBlockAttributeAlign <|>
  try mirBlockAttributeAddressTaken <|>
  try mirBlockAttributeName <|>
  try mirBlockAttributeFreq

mirBlockAttributeAlign =
  do string "align"
     whiteSpace
     decimal
     return Nothing

mirBlockAttributeAddressTaken =
  do string "address-taken"
     return Nothing

mirBlockAttributeName =
  do char '%'
     many1 alphaNumDashDotUnderscore
     return Nothing

mirBlockAttributeFreq =
  do string "freq"
     whiteSpace
     f <- decimal
     return (Just (mkMachineBlockPropertyFreq f))

mirBlockSuccessors =
  do whiteSpaces 2
     string "successors:"
     whiteSpace
     bs <- mirBlockSuccessor `sepBy` comma
     eol
     return (mkMachineBlockPropertySuccs (map mbrId bs))

mirBlockSuccessor =
  do mbr <- mirBlockRef
     parens decimal
     return mbr

mirBlockLiveIns =
  do whiteSpaces 2
     string "liveins:"
     whiteSpace
     liveIns <- mirOperand `sepBy` comma
     eol
     return liveIns

mirBlockLiveOuts =
  do whiteSpaces 2
     string "liveouts:"
     whiteSpace
     liveOuts <- mirOperand `sepBy` comma
     eol
     return liveOuts

mirBlockExit =
  do whiteSpaces 2
     string "exit"
     eol
     return ()

mirInstruction = try mirBundle <|> try (mirSingle 2)

mirBundle =
  do whiteSpaces 2
     opcode <- mirOpcode
     whiteSpace
     us <- mirOperand `sepBy` comma
     whiteSpace
     char '{'
     eol
     instructions <- many (try (mirSingle 4))
     whiteSpaces 2
     char '}'
     eol
     return (mkMachineBundleWithHeader
             (mkMachineSingle opcode [] us) instructions)

mirSingle n =
  do whiteSpaces n
     ds <- option [] mirDefOperands
     optional (try (string "frame-setup "))
     opcode <- mirOpcode
     whiteSpace
     us <- mirOperand `sepBy` comma
     whiteSpace
     optional mirMemOperands
     eol
     return (mkMachineSingle opcode [] (ds ++ us))

mirOpcode = try mirVirtualOpcode <|> mirTargetOpcode

mirVirtualOpcode =
  try (mirVOpc ("PHI", PHI)) <|>
  try (mirVOpc ("COPY", COPY)) <|>
  try (mirVOpc ("ENTRY", ENTRY)) <|>
  try (mirVOpc ("RETURN", RETURN)) <|>
  try (mirVOpc ("EXIT", EXIT)) <|>
  try (mirVOpc ("EXTRACT_SUBREG", EXTRACT_SUBREG)) <|>
  try (mirVOpc ("LOW", LOW)) <|>
  try (mirVOpc ("HIGH", HIGH)) <|>
  try (mirVOpc ("IMPLICIT_DEF", IMPLICIT_DEF)) <|>
  try (mirVOpc ("INSERT_SUBREG", INSERT_SUBREG)) <|>
  try (mirVOpc ("REG_SEQUENCE", REG_SEQUENCE)) <|>
  try (mirVOpc ("COMBINE", COMBINE)) <|>
  try (mirVOpc ("ADJCALLSTACKUP", ADJCALLSTACKUP)) <|>
  try (mirVOpc ("ADJCALLSTACKDOWN", ADJCALLSTACKDOWN)) <|>
  try (mirVOpc ("EH_LABEL", EH_LABEL)) <|>
  try (mirVOpc ("BLOCK_MARKER", BLOCK_MARKER)) <|>
  try (mirVOpc ("BUNDLE", BUNDLE))

mirVOpc (name, opc) =
  do string name
     return (mkMachineVirtualOpc opc)

mirTargetOpcode =
  do opc <-many1 alphaNumDashDotUnderscore
     return (mkMachineVirtualOpc (FREE_OPCODE opc))

mirDefOperands =
  do ds <- mirOperand `sepBy` comma
     string " = "
     return ds

mirOperand =
  do optional (try mirTargetFlags)
     whiteSpace
     op <- mirActualOperand
     return op

mirTargetFlags = string "target-flags(<unknown>)"

mirActualOperand =
  try mirConstantPoolIndex <|>
  try mirRegClass <|>
  try mirBlockRef <|>
  try mirJTI <|>
  try mirFI <|>
  try mirMFS <|>
  try mirReg <|>
  try mirImm <|>
  try mirNullReg <|>
  try mirGlobalAdress <|>
  try mirExternalSymbol <|>
  try mirMemPartition <|>
  try mirProperty <|>
  try mirDebugLocation <|>
  try mirMCSymbol <|>
  try mirFPImm <|>
  try mirCFIDef <|>
  try mirCFIDefOffset <|>
  try mirCFIDefReg <|>
  try mirCFIOffset <|>
  try mirRegMask

mirConstantPoolIndex =
  do string "%const."
     idx <- many1 alphaNumDashDotUnderscore
     return (mkMachineConstantPoolIndex idx)

mirReg =
  do mirRegFlag `endBy` whiteSpace
     char '%'
     mirReg <- mirSpecificReg
     return mirReg

mirJTI =
  do string "%jump-table."
     idx <- decimal
     return (mkMachineJumpTableIndex idx)

mirFI = try fixedMirFI <|> try varMirFI

fixedMirFI =
  do string "%fixed-stack."
     idx <- decimal
     return (mkMachineFrameIndex idx True)

varMirFI =
  do string "%stack."
     idx <- decimal
     optional (try fIName)
     return (mkMachineFrameIndex idx False)

mirMFS =
  do string "%frame-size"
     return mkMachineFrameSize

fIName =
  do char '.'
     string "<unnamed alloca>" <|> many1 alphaNumDashDotUnderscore
     return ()

mirSpecificReg = try mirVirtualReg <|> mirMachineReg

mirVirtualReg =
  do id <- decimal
     srid <- optionMaybe mirSubRegIndex
     td <- optionMaybe mirTiedDef
     return (case (srid, td) of
               (Nothing, td) -> mkMachineTemp id td
               (Just idx, Nothing) -> mkMachineSubTemp id idx)

mirSubRegIndex =
  do char ':'
     idx <- many1 alphaNumDashDotUnderscore
     return idx

mirTiedDef =
  do string "(tied-def "
     id <- decimal
     string ")"
     return id

mirMachineReg =
  do name <- many alphaNumDashDotUnderscore
     optional (try mirTiedDef)
     return (MachineFreeReg name)

mirRegFlag =
    try (string "implicit-def") <|>
    try (string "implicit") <|>
    try (string "def") <|>
    try (string "dead") <|>
    try (string "killed") <|>
    try (string "undef") <|>
    try (string "internal") <|>
    try (string "early-clobber") <|>
    try (string "debug-use")

mirImm =
  do imm <- signedDecimal
     return (mkMachineImm imm)

mirBlockRef =
  do char '%'
     id <- mirBlockId
     return (mkMachineBlockRef id)

mirNullReg =
  do char '_'
     return mkMachineNullReg

mirGlobalAdress =
  do char '@'
     (address, offset) <- mirAddress
     return (mkMachineGlobalAddress address offset)

mirAddress =
  do optional (string "\"\\")
     address <- many1 alphaNumDashDotUnderscore
     optional (char '"')
     whiteSpace
     offset <- try (option 0 mirOffset)
     return (address, offset)

mirOffset =
  do sign <- char '+' <|> char '-'
     whiteSpace
     offset <- decimal
     return (case sign of
                '-' -> offset * (-1)
                '+' -> offset)

mirExternalSymbol =
  do char '$'
     sym <- many1 alphaNumDashDotUnderscore
     return (mkMachineExternal sym)

mirMemPartition =
  do string "<0"
     address <- hexadecimal
     string "> = !{!\"unison-memory-partition\", i32 "
     id <- decimal
     string "}"
     return (mkMachineMemPartition address id)

mirProperty =
  do string "<0"
     address <- hexadecimal
     string "> = !{!\"unison-property\", !\""
     pr <- many1 (noneOf "\"")
     string "\"}"
     return (mkMachineProperty address pr)

mirDebugLocation =
  do string "debug-location !"
     id <- decimal
     return (mkMachineDebugLocation id)

mirMCSymbol =
  do string "<mcsymbol "
     sym <- many1 alphaNumDashDotUnderscore
     char '>'
     return (mkMachineSymbol sym)

mirFPImm =
  do string "float"
     whiteSpace
     int <- decimal
     char '.'
     fr <- decimal
     char 'e'
     exp <- mirOffset
     return (mkMachineFPImm int fr exp)

mirRegClass =
  do string "%reg-class."
     rc <- many1 alphaNumDashDotUnderscore
     return (mkMachineRegClass rc)

mirCFIDef =
  do string ".cfi_def_cfa"
     whiteSpace
     reg <- mirReg
     string ", "
     off <- signedDecimal
     return (mkMachineCFIDef (mrName reg) off)

mirCFIDefOffset =
  do string ".cfi_def_cfa_offset"
     whiteSpace
     off <- signedDecimal
     return (mkMachineCFIDefOffset off)

mirCFIDefReg =
  do string ".cfi_def_cfa_register"
     whiteSpace
     reg <- mirReg
     return (mkMachineCFIDefReg (mrName reg))

mirCFIOffset =
  do string ".cfi_offset"
     whiteSpace
     reg <- mirReg
     string ", "
     off <- signedDecimal
     return (mkMachineCFIOffset (mfrRegName reg) off)

mirRegMask =
  do string "csr_"
     name <- many1 alphaNumDashDotUnderscore
     return (mkMachineRegMask name)

mirMemOperands =
  do string "::"
     whiteSpace
     ms <- mirMemOperand `sepBy` comma
     return ms

mirMemOperand = parens nakedMirMemOperand

nakedMirMemOperand =
  do typ <- mirMemOperandType `endBy` whiteSpace
     size <- decimal
     whiteSpace
     string "from" <|> string "into"
     whiteSpace
     source <- mirMemSource
     attrs <- many mirMemOperandAttr
     return (typ, size, source, attrs)

mirMemOperandType =
    try (string "volatile") <|>
    try (string "non-temporal") <|>
    try (string "invariant") <|>
    try (string "load") <|>
    try (string "store")

mirMemSource =
    try mirPseudoSourceValue <|>
    try mirCallEntryValue <|>
    try mirIRValue <|>
    try getElementPtr

mirPseudoSourceValue =
  do v <- mirPseudoSourceValueType
     whiteSpace
     o <- try (option 0 mirOffset)
     return (v, o)

mirPseudoSourceValueType =
    try (string "stack") <|>
    try (string "got") <|>
    try (string "jump-table") <|>
    try (string "constant-pool") <|>
    try (string "unknown")

mirCallEntryValue =
  do string "call-entry"
     whiteSpace
     mo <- mirGlobalAdress <|> mirExternalSymbol
     let name (MachineGlobalAddress n _) = n
         name (MachineExternal n) = n
     return (name mo, 0)

mirIRValue =
  do char '%' <|> char '@'
     (v, o) <- mirAddress
     return (v, o)

getElementPtr =
  do char '`'
     v <- many1 (noneOf "`")
     char '`'
     whiteSpace
     o <- try (option 0 mirOffset)
     return (v, o)

mirMemOperandAttr =
  do char ','
     whiteSpace
     attr <- try mirMemAlignment <|> try mirMemTbaa <|> try mirMemAliasScope
     return attr

mirMemAlignment =
  do string "align"
     whiteSpace
     a <- decimal
     return a

mirMemTbaa =
  do string "!tbaa"
     whiteSpace
     char '!'
     tbaa <- decimal
     return tbaa

mirMemAliasScope =
  do string "!alias.scope"
     whiteSpace
     char '!'
     scope <- decimal
     return scope

whiteSpaces n = string (replicate n ' ')

eol = try (string "\n\r") <|>
      try (string "\r\n") <|>
      string "\n" <|>
      string "\r"
      <?> "eol"

lexer = T.makeTokenParser emptyDef
whiteSpace = many (char ' ')
decimal = T.decimal lexer
hexadecimal = T.hexadecimal lexer
comma = T.comma lexer

parens = between (char '(') (char ')')

alphaNumDashDotUnderscore =
  satisfy isAlphaNumDashDotUnderscore <?> "letter, digit, dash, dot or underscore symbol"

isAlphaNumDashDotUnderscore '-' = True
isAlphaNumDashDotUnderscore '_' = True
isAlphaNumDashDotUnderscore '.' = True
isAlphaNumDashDotUnderscore c = isAlphaNum c

signedDecimal =
  do s <- option 1 sign
     dec <- decimal
     return (s * dec)

sign =
  do char '-'
     return (-1)

concatAttributes attrs succs = maybeToList succs ++ catMaybes attrs

concatInstructions id entry ret exit instructions =
  let en = case id of
        0 ->
          let es = case entry of
                (Just es') -> es'
                Nothing -> []
          in [mkMachineSingle (mkMachineVirtualOpc ENTRY) [] es]
        _ -> []
      r  = case ret of
        (Just rs) -> [mkMachineSingle (mkMachineVirtualOpc RETURN) [] rs]
        Nothing -> []
      ex = case exit of
        (Just ()) -> [mkMachineSingle (mkMachineVirtualOpc EXIT) [] []]
        Nothing -> []
   in en ++ instructions ++ r ++ ex

toMachineFunctionPropertyFixedStack fso =
    mkMachineFunctionPropertyFixedFrame (map toMachineFrameObjectInfo fso)

toMachineFunctionPropertyStack fso =
    mkMachineFunctionPropertyFrame (map toMachineFrameObjectInfo fso)

toMachineFrameObjectInfo
  MIRStackObject {sId = id, sOffset = off, sSize = s, sAlignment = ali} =
    mkMachineFrameObjectInfo id off s ali

toMachineFunctionPropertyJumpTable MIRJumpTable {kind = k, entries = es} =
  let mes = map toMachineJumpTableEntry es
  in mkMachineFunctionPropertyJumpTable k mes

toMachineJumpTableEntry MIRJumpTableEntry {jtId = id, jtBlocks = bs} =
  mkMachineJumpTableEntry id (map parseMirBlockRef bs)

parseMirBlockRef b =
  case P.parse mirBlockRef "" b of
    Left e -> error ("error parsing block reference in jump table:\n" ++ show e)
    Right br -> br

readTargetOpcode mi @ MachineSingle {
                       msOpcode = MachineVirtualOpc (FREE_OPCODE opc)} =
  mi {msOpcode = mkMachineTargetOpc (read opc)}
readTargetOpcode mi = mi

readOperand (MachineFreeReg name) = mkMachineReg (read name)
readOperand mo = mo

mkMachineBundleWithHeader instruction instructions =
  let head = case instruction of
              MachineSingle {msOpcode = MachineVirtualOpc BUNDLE} -> []
              ms -> [ms]
  in mkMachineBundle (head ++ instructions)
