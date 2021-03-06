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
{-# LANGUAGE DeriveDataTypeable, RecordWildCards, NoMonomorphismRestriction #-}
module Unison.Tools.Extend (run) where

import System.FilePath
import Control.Monad

import Unison.Driver
import Unison.Parser
import Unison.Tools.Lint (invokeLint)

import Unison.Transformations.PostponeBranches
import Unison.Transformations.RenameTemps
import Unison.Transformations.RenameOperations
import Unison.Transformations.CleanPragmas
import Unison.Transformations.AddPragmas

import Unison.Tools.Extend.ExtendWithCopies
import Unison.Tools.Extend.SortCopies
import Unison.Tools.Extend.GroupCalls

run (uniFile, debug, intermediate, lint, extUniFile) uni target =
    let f = parse target uni
        (extF, partialExtFs) =
            applyTransformations
            extenderTransformations
            target f
        baseName = takeBaseName uniFile
    in do when debug $
               putStr (toPlainText partialExtFs)
          when intermediate $
               mapM_ (writeIntermediateFile "ext.uni" baseName) partialExtFs
          emitOutput extUniFile (show extF)
          when lint $
               invokeLint extF target

extenderTransformations =
    [(extendWithCopies, "extendWithCopies", True),
     (sortCopies, "sortCopies", True),
     (postponeBranches, "postponeBranches", True),
     (groupCalls, "groupCalls", True),
     (renameTemps, "renameTemps", True),
     (renameOperations, "renameOperations", True),
     (cleanPragmas extendPragmaTools, "cleanPragmas", True),
     (addPragmas extendPragmas, "addPragmas", True)]

extendPragmas =
    [("lint",
      "--nocostoverflow=false")]

extendPragmaTools = map fst extendPragmas
