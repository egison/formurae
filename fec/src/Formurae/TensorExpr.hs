{-# LANGUAGE PatternSynonyms #-}

module Formurae.TensorExpr
  ( TensorExpr
  , SourceSpan(..)
  , SourceLocation(..)
  , ExpansionFrame(..)
  , SourceOrigin(..)
  , noSourceSpan
  , tensorExprSpan
  , tensorExprOrigin
  , pattern TENumber
  , pattern TEIdent
  , pattern TEUnary
  , pattern TECall
  , pattern TEApply
  , pattern TEIf
  , pattern TEAppendIndexed
  , pattern TEWithSymbols
  , pattern TEContractWith
  , pattern TETensorMap
  , pattern TESubrefs
  , pattern TETranspose
  , pattern TEDisjoint
  , pattern TEDerivative
  , pattern TEDot
  , pattern TEBinary
  , pattern TEGroup
  , TensorInfo(..)
  , DiagIx(..)
  , ElaboratedTensorExpr(..)
  , parseTensorExpr
  , parseTensorExprEither
  , parseSourceTensorExpr
  , sourceLocationForSpan
  , renderTensorExpr
  , transformTensorExprM
  , normalizeTensorExpr
  , preprocessTensorExpr
  , elaborateTensorExpr
  , expandDefs
  , expandDefsWithSource
  , strictEinstein
  , validateFieldRefParts
  ) where

import Data.Char (isAlphaNum, isDigit, isSpace)
import Data.List (intercalate, isSuffixOf, nub)
import Control.Monad (foldM)

import Formurae.Common (fatal, strip, validSurfaceName)
import Formurae.Index
import Formurae.Syntax

data SourceSpan = SourceSpan
  { sourceStart :: Int
  , sourceEnd   :: Int
  } deriving (Eq, Show)

noSourceSpan :: SourceSpan
noSourceSpan = SourceSpan 0 0

data SourceLocation = SourceLocation
  { locationPath        :: FilePath
  , locationLine        :: Int
  , locationEndLine     :: Int
  , locationStartColumn :: Int
  , locationEndColumn   :: Int
  } deriving (Eq, Show)

data ExpansionFrame = ExpansionFrame
  { expansionName       :: String
  , expansionDefinition :: SourceLocation
  , expansionCall       :: SourceLocation
  } deriving (Eq, Show)

data SourceOrigin = SourceOrigin
  { originLocation :: SourceLocation
  , originTrace    :: [ExpansionFrame]
  } deriving (Eq, Show)

data TensorExpr = TensorExpr
  { tensorExprSpan :: SourceSpan
  , tensorExprOrigin :: Maybe SourceOrigin
  , tensorExprNode :: TensorExprNode
  } deriving (Eq, Show)

data TensorExprNode
  = TENumberNode String
  | TEIdentNode String [IxPart]
  | TEUnaryNode String TensorExpr
  | TECallNode TensorExpr [TensorExpr]
  | TEApplyNode TensorExpr [TensorExpr]
  | TEIfNode TensorExpr TensorExpr TensorExpr
  | TEAppendIndexedNode TensorExpr [IxPart]
  | TEWithSymbolsNode [String] TensorExpr
  | TEContractWithNode String TensorExpr
  | TETensorMapNode TensorExpr TensorExpr
  | TESubrefsNode TensorExpr [IxPart]
  | TETransposeNode [String] TensorExpr
  | TEDisjointNode [TensorExpr]
  | TEDerivativeNode [IxPart] TensorExpr
  | TEDotNode [TensorExpr]
  | TEBinaryNode String TensorExpr TensorExpr
  | TEGroupNode TensorExpr
  deriving (Eq, Show)

-- `tensorMap` is explicit scalar-to-tensor lifting.  `subrefs` and
-- `transpose` operate on the symbolic index sequence before component
-- lowering; `!.` is a disjoint product and never contracts an index pair.

pattern TENumber :: String -> TensorExpr
pattern TENumber s <- TensorExpr _ _ (TENumberNode s)
  where TENumber s = TensorExpr noSourceSpan Nothing (TENumberNode s)

pattern TEIdent :: String -> [IxPart] -> TensorExpr
pattern TEIdent base parts <- TensorExpr _ _ (TEIdentNode base parts)
  where TEIdent base parts = TensorExpr noSourceSpan Nothing (TEIdentNode base parts)

pattern TEUnary :: String -> TensorExpr -> TensorExpr
pattern TEUnary op e <- TensorExpr _ _ (TEUnaryNode op e)
  where TEUnary op e = TensorExpr noSourceSpan Nothing (TEUnaryNode op e)

pattern TECall :: TensorExpr -> [TensorExpr] -> TensorExpr
pattern TECall f args <- TensorExpr _ _ (TECallNode f args)
  where TECall f args = TensorExpr noSourceSpan Nothing (TECallNode f args)

pattern TEApply :: TensorExpr -> [TensorExpr] -> TensorExpr
pattern TEApply f args <- TensorExpr _ _ (TEApplyNode f args)
  where TEApply f args = TensorExpr noSourceSpan Nothing (TEApplyNode f args)

pattern TEIf :: TensorExpr -> TensorExpr -> TensorExpr -> TensorExpr
pattern TEIf c t e <- TensorExpr _ _ (TEIfNode c t e)
  where TEIf c t e = TensorExpr noSourceSpan Nothing (TEIfNode c t e)

pattern TEAppendIndexed :: TensorExpr -> [IxPart] -> TensorExpr
pattern TEAppendIndexed e parts <- TensorExpr _ _ (TEAppendIndexedNode e parts)
  where TEAppendIndexed e parts = TensorExpr noSourceSpan Nothing (TEAppendIndexedNode e parts)

pattern TEWithSymbols :: [String] -> TensorExpr -> TensorExpr
pattern TEWithSymbols names body <- TensorExpr _ _ (TEWithSymbolsNode names body)
  where TEWithSymbols names body = TensorExpr noSourceSpan Nothing (TEWithSymbolsNode names body)

pattern TEContractWith :: String -> TensorExpr -> TensorExpr
pattern TEContractWith reducer body <- TensorExpr _ _ (TEContractWithNode reducer body)
  where TEContractWith reducer body = TensorExpr noSourceSpan Nothing (TEContractWithNode reducer body)

pattern TETensorMap :: TensorExpr -> TensorExpr -> TensorExpr
pattern TETensorMap f body <- TensorExpr _ _ (TETensorMapNode f body)
  where TETensorMap f body = TensorExpr noSourceSpan Nothing (TETensorMapNode f body)

pattern TESubrefs :: TensorExpr -> [IxPart] -> TensorExpr
pattern TESubrefs body parts <- TensorExpr _ _ (TESubrefsNode body parts)
  where TESubrefs body parts = TensorExpr noSourceSpan Nothing (TESubrefsNode body parts)

pattern TETranspose :: [String] -> TensorExpr -> TensorExpr
pattern TETranspose names body <- TensorExpr _ _ (TETransposeNode names body)
  where TETranspose names body = TensorExpr noSourceSpan Nothing (TETransposeNode names body)

pattern TEDisjoint :: [TensorExpr] -> TensorExpr
pattern TEDisjoint parts <- TensorExpr _ _ (TEDisjointNode parts)
  where TEDisjoint parts = TensorExpr noSourceSpan Nothing (TEDisjointNode parts)

pattern TEDerivative :: [IxPart] -> TensorExpr -> TensorExpr
pattern TEDerivative parts body <- TensorExpr _ _ (TEDerivativeNode parts body)
  where TEDerivative parts body = TensorExpr noSourceSpan Nothing (TEDerivativeNode parts body)

pattern TEDot :: [TensorExpr] -> TensorExpr
pattern TEDot parts <- TensorExpr _ _ (TEDotNode parts)
  where TEDot parts = TensorExpr noSourceSpan Nothing (TEDotNode parts)

pattern TEBinary :: String -> TensorExpr -> TensorExpr -> TensorExpr
pattern TEBinary op lhs rhs <- TensorExpr _ _ (TEBinaryNode op lhs rhs)
  where TEBinary op lhs rhs = TensorExpr noSourceSpan Nothing (TEBinaryNode op lhs rhs)

pattern TEGroup :: TensorExpr -> TensorExpr
pattern TEGroup e <- TensorExpr _ _ (TEGroupNode e)
  where TEGroup e = TensorExpr noSourceSpan Nothing (TEGroupNode e)

{-# COMPLETE TENumber, TEIdent, TEUnary, TECall, TEApply, TEIf,
             TEAppendIndexed, TEWithSymbols, TEContractWith, TETensorMap,
             TESubrefs, TETranspose, TEDisjoint, TEDerivative, TEDot,
             TEBinary, TEGroup #-}

data DiagIx = DiagIx
  { diagName :: String
  , diagUp   :: IxPart
  , diagDown :: IxPart
  } deriving (Eq, Show)

data TensorInfo = TensorInfo
  { tiFreeIx :: [IxPart]
  , tiDiagIx :: [DiagIx]
  , tiRank   :: Int
  } deriving (Eq, Show)

data ElaboratedTensorExpr = ElaboratedTensorExpr
  { eteExpr     :: TensorExpr
  , eteInfo     :: TensorInfo
  , eteTermInfo :: [TensorInfo]
  } deriving (Eq, Show)

parseTensorExpr :: String -> TensorExpr
parseTensorExpr src =
  case parseTensorExprEither src of
    Right expr -> expr
    Left msg -> errorWithoutStackTrace ("tensor expression parse error: " ++ msg)

parseTensorExprEither :: String -> Either String TensorExpr
parseTensorExprEither src = parseTensorTokensE src (trimTensorIToks (itok src))

parseSourceTensorExpr :: SourceText -> Either String TensorExpr
parseSourceTensorExpr source =
  annotateSource source <$> parseTensorExprEither (sourceTranslated source)

parseTensorExprIO :: String -> String -> IO TensorExpr
parseTensorExprIO context src =
  case parseTensorExprEither src of
    Right expr -> return expr
    Left msg -> fatal (context ++ ": " ++ msg)

renderTensorExpr :: TensorExpr -> String
renderTensorExpr (TENumber s) = s
renderTensorExpr (TEIdent base parts) = base ++ concatMap ixSuffix parts
renderTensorExpr (TEUnary op e) = op ++ renderTensorUnaryArg e
renderTensorExpr (TECall f args) =
  renderTensorAtom f ++ "(" ++ intercalate ", " (map renderTensorExpr args) ++ ")"
renderTensorExpr (TEApply f args) =
  unwords (renderTensorAtom f : map renderTensorAtom args)
renderTensorExpr (TEIf c t e) =
  "if " ++ renderTensorExpr c ++ " then " ++ renderTensorExpr t
  ++ " else " ++ renderTensorExpr e
renderTensorExpr (TEAppendIndexed e parts) =
  renderTensorAtom e ++ "..." ++ concatMap ixSuffix parts
renderTensorExpr (TEWithSymbols names body) =
  "withSymbols [" ++ intercalate ", " names ++ "] " ++ renderTensorExpr body
renderTensorExpr (TEContractWith reducer body) =
  "contractWith " ++ renderReducer reducer ++ " " ++ renderContractBody body
renderTensorExpr (TETensorMap f body) =
  "tensorMap " ++ renderTensorAtom f ++ " " ++ renderTensorAtom body
renderTensorExpr (TESubrefs body parts) =
  "subrefs " ++ renderTensorAtom body ++ " ["
  ++ intercalate ", " (map ixSuffix parts) ++ "]"
renderTensorExpr (TETranspose names body) =
  "transpose [" ++ intercalate ", " names ++ "] " ++ renderTensorAtom body
renderTensorExpr (TEDisjoint parts) =
  intercalate " !. " (map renderTensorDotPart parts)
renderTensorExpr (TEDerivative parts body) =
  let (parts', body') = flattenDerivative parts body
  in unwords (map (\p -> "d" ++ ixSuffix p) parts' ++ [renderTensorAtom body'])
renderTensorExpr (TEDot parts) = intercalate " . " (map renderTensorDotPart parts)
renderTensorExpr (TEBinary op lhs rhs) =
  renderTensorBinarySide op lhs ++ " " ++ op ++ " " ++ renderTensorBinarySide op rhs
renderTensorExpr (TEGroup e) = "(" ++ renderTensorExpr e ++ ")"

flattenDerivative :: [IxPart] -> TensorExpr -> ([IxPart], TensorExpr)
flattenDerivative acc (TEDerivative parts body) =
  flattenDerivative (acc ++ parts) body
flattenDerivative acc body = (acc, body)

normalizeTensorExpr :: String -> String
normalizeTensorExpr = renderTensorExpr . parseTensorExpr

preprocessTensorExpr :: Model -> String -> IO String
preprocessTensorExpr m src = do
  ast <- parseTensorExprIO "bad tensor expression" src
  return (renderTensorExpr (preprocessTensorAst m ast))

preprocessTensorAst :: Model -> TensorExpr -> TensorExpr
preprocessTensorAst m expr =
  case expr of
    TENumber _ -> expr
    TEIdent base parts ->
      keep (TEIdent (renameAxisIdent base parts) parts)
    TEUnary op body ->
      keep (TEUnary op (pre body))
    TECall f args ->
      keep (TECall (pre f) (map pre args))
    TEApply (TEIdent "compose" []) [f, g] ->
      keep (TEDot [pre f, pre g])
    TEApply (TEIdent fn fnParts) args
      | Just (ordr, radius, part) <- derivativeOpParts (fn ++ concatMap ixSuffix fnParts)
      , let part' = renameDerivativePart part ->
          keep (TEApply (TEIdent ("pd" ++ show ordr ++ "r" ++ show radius) [part'])
                  (map pre args))
    TEApply f args ->
      keep (TEApply (pre f) (map pre args))
    TEIf c t e ->
      keep (TEIf (pre c) (pre t) (pre e))
    TEAppendIndexed e parts ->
      keep (TEAppendIndexed (pre e) parts)
    TEWithSymbols names body ->
      keep (TEWithSymbols names (pre body))
    TEContractWith reducer body ->
      keep (TEContractWith reducer (pre body))
    TETensorMap f body ->
      keep (TETensorMap (pre f) (pre body))
    TESubrefs body parts ->
      keep (TESubrefs (pre body) parts)
    TETranspose names body ->
      keep (TETranspose names (pre body))
    TEDisjoint parts ->
      keep (TEDisjoint (map pre parts))
    TEDerivative parts body
      | otherwise ->
          keep (foldr lowerDerivativePart (pre body) parts)
    TEDot parts ->
      keep (TEDot (map pre parts))
    TEBinary op lhs rhs ->
      keep (TEBinary op (pre lhs) (pre rhs))
    TEGroup body ->
      keep (TEGroup (pre body))
  where
    pre = preprocessTensorAst m
    keep = copyTensorMetadata expr
    axmap = zip (mAxes m) (internalCoordNames m)
    renameDerivativePart (IxPart v nm) =
      case lookup nm axmap of
        Just axis' -> IxPart v axis'
        Nothing -> IxPart v nm
    lowerDerivativePart part body =
      case lookup (ixName part) axmap of
        Just axis' ->
          TEApply (TEIdent "pd1r1" [IxPart (ixVariance part) axis']) [body]
        Nothing ->
          TEDerivative [part] body
    renameAxisIdent base parts
      | null parts
      , (nm, 0) <- fieldBaseOf base
      , Just nm' <- lookup nm axmap = nm'
      | otherwise = base

elaborateTensorExpr :: Model -> [String] -> [IxPart] -> TensorExpr -> IO ElaboratedTensorExpr
elaborateTensorExpr m lets lhs expr = do
  termOccs <- tensorTermOccurrences m lets lhs [] expr
  let termInfos = map tensorInfoFromOccurrences termOccs
      mergedInfo = mergeTensorInfos termInfos
  return (ElaboratedTensorExpr expr mergedInfo termInfos)

tensorTermOccurrences :: Model -> [String] -> [IxPart] -> [(String, String)] -> TensorExpr -> IO [[IxPart]]
tensorTermOccurrences m lets lhs aliases expr =
  case expr of
    TEBinary op l r | op == "+" || op == "-" -> do
      lTerms <- tensorTermOccurrences m lets lhs aliases l
      rTerms <- tensorTermOccurrences m lets lhs aliases r
      return (lTerms ++ rTerms)
    _ -> tensorOccurrenceAlternatives m lets lhs aliases expr

tensorOccurrenceAlternatives :: Model -> [String] -> [IxPart] -> [(String, String)] -> TensorExpr -> IO [[IxPart]]
tensorOccurrenceAlternatives m lets lhs aliases expr =
  case expr of
    TENumber _ -> return [[]]
    TEIdent base parts -> fmap (: []) (indexedIdentOccurrences m lets base parts (base ++ concatMap ixSuffix parts))
    TEUnary _ body ->
      tensorOccurrenceAlternatives m lets lhs aliases body
    TECall f args -> do
      occ <- fmap concat (mapM (wholeExpressionOccurrences m lets lhs aliases) (f : args))
      return [occ]
    TEApply f args -> do
      occ <- fmap concat (mapM (wholeExpressionOccurrences m lets lhs aliases) (f : args))
      return [occ]
    TEIf c t e -> do
      cTerms <- tensorTermOccurrences m lets [] aliases c
      mapM_ requireScalarCondition cTerms
      tAlts <- tensorOccurrenceAlternatives m lets lhs aliases t
      eAlts <- tensorOccurrenceAlternatives m lets lhs aliases e
      return (tAlts ++ eAlts)
    TEAppendIndexed (TEIdent base existing) parts -> do
      tensorOccurrenceAlternatives m lets lhs aliases
        (TEIdent base (existing ++ map (renameIxPart aliases) parts))
    TEAppendIndexed e parts -> do
      alts <- tensorOccurrenceAlternatives m lets lhs aliases e
      return [occ ++ map (renameIxPart aliases) parts | occ <- alts]
    TEWithSymbols names body -> do
      let lhsNames = map ixName lhs
          aliases' = zip names lhsNames ++ aliases
      tensorOccurrenceAlternatives m lets lhs aliases' body
    TEContractWith _ body -> do
      bodyTerms <- tensorTermOccurrences m lets lhs aliases body
      return (map removeContractedOccurrences bodyTerms)
    TETensorMap _ body ->
      tensorOccurrenceAlternatives m lets lhs aliases
        (materializeTensorOccurrence m lhs body)
    TESubrefs body parts -> do
      tensorOccurrenceAlternatives m lets lhs aliases
        (TEAppendIndexed body parts)
    TETranspose names body ->
      tensorOccurrenceAlternatives m lets lhs aliases
        (transposeOccurrenceAst m names body)
    TEDisjoint parts -> do
      alts <- mapM (tensorOccurrenceAlternatives m lets lhs aliases) parts
      return (cartesianConcat alts)
    TEDerivative parts body -> do
      bodyTerms <- tensorOccurrenceAlternatives m lets lhs aliases body
      return [map (renameIxPart aliases) parts ++ occ | occ <- bodyTerms]
    TEDot parts -> do
      partAlts <- mapM (tensorOccurrenceAlternatives m lets lhs aliases) parts
      return (map removeContractedOccurrences (cartesianConcat partAlts))
    TEBinary op l r
      | op == "+" || op == "-" -> tensorTermOccurrences m lets lhs aliases expr
      | otherwise -> do
          lAlts <- tensorOccurrenceAlternatives m lets lhs aliases l
          rAlts <- tensorOccurrenceAlternatives m lets lhs aliases r
          return [lo ++ ro | lo <- lAlts, ro <- rAlts]
    TEGroup e -> tensorTermOccurrences m lets lhs aliases e
  where
    requireScalarCondition occurrences =
      let info = tensorInfoFromOccurrences occurrences
      in if tiRank info == 0
           then return ()
           else fatal ("if condition must be scalar: " ++ renderTensorExpr expr)

cartesianConcat :: [[[IxPart]]] -> [[IxPart]]
cartesianConcat [] = [[]]
cartesianConcat (xs:xss) =
  [x ++ rest | x <- xs, rest <- cartesianConcat xss]

wholeExpressionOccurrences :: Model -> [String] -> [IxPart] -> [(String, String)] -> TensorExpr -> IO [IxPart]
wholeExpressionOccurrences m lets lhs aliases expr =
  fmap (nub . concat) (tensorTermOccurrences m lets lhs aliases expr)

indexedIdentOccurrences :: Model -> [String] -> String -> [IxPart] -> String -> IO [IxPart]
indexedIdentOccurrences m lets base0 parts w =
  let (base, _) = fieldBaseOf base0
  in case () of
       _
         | base == metricPreludeName
         , length parts == 2
         , all isIndexedMetricPart parts ->
             metricIdentOccurrences "internal metric" parts w
         | Just metricNm <- mMetricName m
         , base == metricNm
         , length parts == 2
         , all isIndexedMetricPart parts ->
             metricIdentOccurrences metricNm parts w
         | base == "epsilon", not (null parts) ->
             if mDim m /= 3
               then fatal ("epsilon currently requires dimension 3: " ++ w)
               else if length parts == 3 && all isSingleAlphaIx parts
               then return parts
               else fatal ("epsilon takes three single marked indices, e.g. epsilon~i~j~k: " ++ w)
         | base == "delta", not (null parts) ->
             kroneckerIdentOccurrences parts w
         | base == "d", not (null parts) ->
             derivativeIdentOccurrences parts w
         | Just (_, _, part) <- derivativeOpParts w ->
             if isCoordinatePart part
               then return []
               else derivativeIdentOccurrences [part] w
         | fieldDeclOf m base /= Nothing && not (null parts) -> do
             validateFieldRefParts m lets w
             return (symbolicIxParts parts)
         | base `elem` lets && not (null parts) ->
             return (symbolicIxParts parts)
         | Just metricNm <- mMetricName m
         , base == metricNm
         , not (null parts) ->
             metricIdentOccurrences metricNm parts w
         | otherwise ->
             return []
  where
    isCoordinatePart (IxPart _ nm) =
      nm `elem` mAxes m || nm `elem` internalCoordNames m

metricIdentOccurrences :: String -> [IxPart] -> String -> IO [IxPart]
metricIdentOccurrences metricNm parts w =
  if length parts == 2 && all isIndexedMetricPart parts
    then return parts
    else fatal ("metric tensor " ++ metricNm ++ " needs exactly two marked indices: " ++ w)

kroneckerIdentOccurrences :: [IxPart] -> String -> IO [IxPart]
kroneckerIdentOccurrences [p, q] w
  | all isIndexedMetricPart [p, q] =
      if isMixedIxPair p q
        then return (symbolicIxParts [p, q])
        else fatal ("Kronecker delta indices must be mixed, e.g. delta~i_j; use metric g and g~i~j/g_i_j for metric components: " ++ w)
kroneckerIdentOccurrences _ w =
  fatal ("Kronecker delta takes two marked indices, e.g. delta~i_j or delta_i~1: " ++ w)

derivativeIdentOccurrences :: [IxPart] -> String -> IO [IxPart]
derivativeIdentOccurrences [p] _ = return [p]
derivativeIdentOccurrences _ w =
  fatal ("indexed derivative takes one marked index, e.g. d_i or d~i: " ++ w)

isIndexedMetricPart :: IxPart -> Bool
isIndexedMetricPart (IxPart _ nm) = all isAlphaNum nm && not (null nm)

symbolicIxParts :: [IxPart] -> [IxPart]
symbolicIxParts =
  filter (\p -> not (all isDigit (ixName p)))

isMixedIxPair :: IxPart -> IxPart -> Bool
isMixedIxPair (IxPart VUp _) (IxPart VDown _) = True
isMixedIxPair (IxPart VDown _) (IxPart VUp _) = True
isMixedIxPair _ _ = False

renameIxPart :: [(String, String)] -> IxPart -> IxPart
renameIxPart aliases (IxPart v nm) =
  case lookup nm aliases of
    Just nm' -> IxPart v nm'
    Nothing -> IxPart v nm

tensorInfoFromOccurrences :: [IxPart] -> TensorInfo
tensorInfoFromOccurrences occs =
  let names = nub (map ixName occs)
      diags = concatMap diagForName names
      diagNames = map diagName diags
      free = [p | p <- occs, ixName p `notElem` diagNames]
  in TensorInfo free diags (length free + length diags)
  where
    sameName nm (IxPart _ nm') = nm == nm'
    diagForName nm =
      case filter (sameName nm) occs of
        [u@(IxPart VUp _), d@(IxPart VDown _)] -> [DiagIx nm u d]
        [d@(IxPart VDown _), u@(IxPart VUp _)] -> [DiagIx nm u d]
        _ -> []

mergeTensorInfos :: [TensorInfo] -> TensorInfo
mergeTensorInfos [] = TensorInfo [] [] 0
mergeTensorInfos infos =
  let frees = nub (concatMap tiFreeIx infos)
      diags = nub (concatMap tiDiagIx infos)
  in TensorInfo frees diags (length frees + length diags)

removeContractedOccurrences :: [IxPart] -> [IxPart]
removeContractedOccurrences occs =
  let info = tensorInfoFromOccurrences occs
      contracted = map diagName (tiDiagIx info)
  in [p | p <- occs, ixName p `notElem` contracted]

transposeOccurrenceAst :: Model -> [String] -> TensorExpr -> TensorExpr
transposeOccurrenceAst m names body =
  case stripGroupAst body of
    TEIdent base parts
      | null parts ->
          let vars = case fieldDeclOf m (fst (fieldBaseOf base)) >>= fieldIndexParts of
                       Just ps | length ps == length names -> map ixVariance ps
                       _ -> replicate (length names) VDown
          in TEIdent base [IxPart v n | (v, n) <- zip vars names]
      | length parts == length names ->
          TEIdent base [IxPart (ixVariance p) n | (p, n) <- zip parts names]
    _ -> body

materializeTensorOccurrence :: Model -> [IxPart] -> TensorExpr -> TensorExpr
materializeTensorOccurrence m lhs body =
  case body of
    TEIdent base [] ->
      let fname = fst (fieldBaseOf base)
      in case kindOf m fname of
           Just kind
             | componentRank kind == length lhs
             , componentRank kind > 0 ->
                 let vars = case fieldDeclOf m fname >>= fieldIndexParts of
                              Just ps | length ps == length lhs -> map ixVariance ps
                              _ -> replicate (length lhs) VDown
                 in TEIdent base [IxPart v (ixName p) | (v, p) <- zip vars lhs]
           Nothing
             | not (null lhs) ->
                 TEIdent base [IxPart VDown (ixName p) | p <- lhs]
           _ -> body
    TEIdent _ _ -> body
    TEUnary op e -> TEUnary op (materializeTensorOccurrence m lhs e)
    TECall f args -> TECall (materializeTensorOccurrence m lhs f)
                           (map (materializeTensorOccurrence m lhs) args)
    TEApply f args -> TEApply (materializeTensorOccurrence m lhs f)
                             (map (materializeTensorOccurrence m lhs) args)
    TEIf c t e -> TEIf (materializeTensorOccurrence m lhs c)
                      (materializeTensorOccurrence m lhs t)
                      (materializeTensorOccurrence m lhs e)
    TEAppendIndexed e parts -> TEAppendIndexed (materializeTensorOccurrence m lhs e) parts
    TEWithSymbols names e -> TEWithSymbols names (materializeTensorOccurrence m lhs e)
    TEContractWith r e -> TEContractWith r (materializeTensorOccurrence m lhs e)
    TETensorMap f e -> TETensorMap (materializeTensorOccurrence m lhs f)
                                  (materializeTensorOccurrence m lhs e)
    TESubrefs e parts -> TESubrefs (materializeTensorOccurrence m lhs e) parts
    TETranspose names e -> TETranspose names (materializeTensorOccurrence m lhs e)
    TEDisjoint es -> TEDisjoint (map (materializeTensorOccurrence m lhs) es)
    TEDerivative parts e -> TEDerivative parts (materializeTensorOccurrence m lhs e)
    TEDot es -> TEDot (map (materializeTensorOccurrence m lhs) es)
    TEBinary op l r -> TEBinary op (materializeTensorOccurrence m lhs l)
                               (materializeTensorOccurrence m lhs r)
    TEGroup e -> TEGroup (materializeTensorOccurrence m lhs e)
    TENumber _ -> body

parseTensorTokensE :: String -> [ITok] -> Either String TensorExpr
parseTensorTokensE src ts0 =
  let ts = trimTensorIToks ts0
      sp = sourceSpanOf src ts
  in fmap (setTensorSpan sp) $
       case parseIfExprE src ts of
         Just e -> e
         Nothing ->
           case splitTopBinaryOpsI ["||"] False ts of
             Just (lhs, op, rhs) ->
               TEBinary op <$> parse lhs <*> parse rhs
             Nothing ->
               case splitTopBinaryOpsI ["&&"] False ts of
                 Just (lhs, op, rhs) ->
                   TEBinary op <$> parse lhs <*> parse rhs
                 Nothing ->
                   case splitTopBinaryOpsI ["<=", ">=", "==", "!=", "<", ">"] False ts of
                     Just (lhs, op, rhs) ->
                       TEBinary op <$> parse lhs <*> parse rhs
                     Nothing ->
                         case splitTopAddI ts of
                         Just (lhs, op, rhs) ->
                           TEBinary op <$> parse lhs <*> parse rhs
                         Nothing ->
                           case splitTopDisjointI ts of
                             (_:_:_) ->
                               TEDisjoint <$> mapM parse (splitTopDisjointI ts)
                             _ ->
                               case splitTopDotsI ts of
                                 (_:_:_) | not (hasEllipsisAtTop ts) ->
                                   TEDot <$> mapM parse (splitTopDotsI ts)
                                 _ ->
                                   case splitTopMulDivI ts of
                                     Just (lhs, op, rhs) ->
                                       TEBinary op <$> parse lhs <*> parse rhs
                                     Nothing ->
                                       case splitTopPowerI ts of
                                         Just (lhs, op, rhs) ->
                                           TEBinary op <$> parse lhs <*> parse rhs
                                         Nothing -> parseTensorAtomE src ts
  where
    parse = parseTensorTokensE src

setTensorSpan :: SourceSpan -> TensorExpr -> TensorExpr
setTensorSpan sp (TensorExpr _ origin node) = TensorExpr sp origin node

copyTensorMetadata :: TensorExpr -> TensorExpr -> TensorExpr
copyTensorMetadata source (TensorExpr _ _ node) =
  TensorExpr (tensorExprSpan source) (tensorExprOrigin source) node

annotateSource :: SourceText -> TensorExpr -> TensorExpr
annotateSource source expr =
  let rebuilt = mapTensorChildren (annotateSource source) expr
      origin = SourceOrigin (sourceLocationForSpan source (tensorExprSpan expr)) []
  in TensorExpr (tensorExprSpan expr) (Just origin) (tensorExprNode rebuilt)

sourceLocationForSpan :: SourceText -> SourceSpan -> SourceLocation
sourceLocationForSpan source spanValue =
  SourceLocation
    { locationPath = sourcePath source
    , locationLine = positionLine mappedStart
    , locationEndLine = positionLine mappedEnd
    , locationStartColumn = positionColumn mappedStart
    , locationEndColumn = positionColumn mappedEnd
    }
  where
    positions = sourcePositionMap source
    translatedLength = length (sourceTranslated source)
    startOffset = boundedOffset (sourceStart spanValue)
    endOffset = boundedOffset (sourceEnd spanValue)
    mappedStart = mapPosition startOffset
    mappedEnd = mapPosition endOffset
    boundedOffset value
      | translatedLength <= 0 = 1
      | value <= 0 = 1
      | value > translatedLength = translatedLength
      | otherwise = value
    mapPosition value =
      case drop (value - 1) positions of
        mapped : _ -> mapped
        [] -> SourcePosition (sourceLine source)
                 (sourceColumn source + value - 1)

mapTensorChildren :: (TensorExpr -> TensorExpr) -> TensorExpr -> TensorExpr
mapTensorChildren walk expr =
  copyTensorMetadata expr $
    case expr of
      TENumber value -> TENumber value
      TEIdent base parts -> TEIdent base parts
      TEUnary op body -> TEUnary op (walk body)
      TECall fn args -> TECall (walk fn) (map walk args)
      TEApply fn args -> TEApply (walk fn) (map walk args)
      TEIf condition yes no -> TEIf (walk condition) (walk yes) (walk no)
      TEAppendIndexed body parts -> TEAppendIndexed (walk body) parts
      TEWithSymbols names body -> TEWithSymbols names (walk body)
      TEContractWith reducer body -> TEContractWith reducer (walk body)
      TETensorMap fn body -> TETensorMap (walk fn) (walk body)
      TESubrefs body parts -> TESubrefs (walk body) parts
      TETranspose names body -> TETranspose names (walk body)
      TEDisjoint parts -> TEDisjoint (map walk parts)
      TEDerivative parts body -> TEDerivative parts (walk body)
      TEDot parts -> TEDot (map walk parts)
      TEBinary op lhs rhs -> TEBinary op (walk lhs) (walk rhs)
      TEGroup body -> TEGroup (walk body)

-- Top-down, span-preserving transformation used by backend request lowering.
-- Returning Just replaces the whole current subtree; returning Nothing walks
-- its children and rebuilds the same node with the original source span.
transformTensorExprM
  :: Monad m
  => (TensorExpr -> m (Maybe TensorExpr))
  -> TensorExpr
  -> m TensorExpr
transformTensorExprM transform expr = do
  replacement <- transform expr
  case replacement of
    Just expr' -> return (copyTensorMetadata expr expr')
    Nothing -> copyTensorMetadata expr <$> descend expr
  where
    walk = transformTensorExprM transform
    descend current =
      case current of
        TENumber value -> return (TENumber value)
        TEIdent base parts -> return (TEIdent base parts)
        TEUnary op body -> TEUnary op <$> walk body
        TECall fn args -> TECall <$> walk fn <*> mapM walk args
        TEApply fn args -> TEApply <$> walk fn <*> mapM walk args
        TEIf cond yes no -> TEIf <$> walk cond <*> walk yes <*> walk no
        TEAppendIndexed body parts -> TEAppendIndexed <$> walk body <*> pure parts
        TEWithSymbols names body -> TEWithSymbols names <$> walk body
        TEContractWith reducer body -> TEContractWith reducer <$> walk body
        TETensorMap fn body -> TETensorMap <$> walk fn <*> walk body
        TESubrefs body parts -> TESubrefs <$> walk body <*> pure parts
        TETranspose names body -> TETranspose names <$> walk body
        TEDisjoint parts -> TEDisjoint <$> mapM walk parts
        TEDerivative parts body -> TEDerivative parts <$> walk body
        TEDot parts -> TEDot <$> mapM walk parts
        TEBinary op lhs rhs -> TEBinary op <$> walk lhs <*> walk rhs
        TEGroup body -> TEGroup <$> walk body

sourceSpanOf :: String -> [ITok] -> SourceSpan
sourceSpanOf _ ts =
  case trimTensorIToks ts of
    [] -> noSourceSpan
    tokens@(firstToken:_)
      | start > 0 && finish > 0 -> SourceSpan start finish
      | otherwise -> noSourceSpan
      where
        start = itokOffset firstToken
        finalToken = foldl (\_ token -> token) firstToken tokens
        finish = itokOffset finalToken + itokWidth finalToken - 1

parseTensorAtomE :: String -> [ITok] -> Either String TensorExpr
parseTensorAtomE src ts =
  case stripOuterGroupI ts of
    Just inner -> TEGroup <$> parse inner
    Nothing ->
      case parseContractWithExprE src ts of
        Just e -> e
        Nothing ->
          case parseTensorMapExprE src ts of
            Just e -> e
            Nothing ->
              case parseSubrefsExprE src ts of
                Just e -> e
                Nothing ->
                  case parseTransposeExprE src ts of
                    Just e -> e
                    Nothing ->
                      case parseWithSymbolsExprE src ts of
                        Just e -> e
                        Nothing ->
                          case parseDerivativeExprE src ts of
                            Just e -> e
                            Nothing ->
                              case parseAppendExprE src ts of
                                Just e -> e
                                Nothing ->
                                  case parseCallExprE src ts of
                                    Just e -> e
                                    Nothing ->
                                      case parseApplyExprE src ts of
                                        Just e -> e
                                        Nothing ->
                                          case parseUnaryExprE src ts of
                                            Just e -> e
                                            Nothing ->
                                              case parseNumberExpr ts of
                                                Just e -> Right e
                                                Nothing ->
                                                  case ts of
                                                    [II w] ->
                                                      let (base, parts) = parseIndexedIdent w
                                                      in Right (TEIdent base parts)
                                                    [IC '∂'] -> Right (TEIdent "∂" [])
                                                    _ -> parseError src ts "unsupported scalar expression atom"
  where
    parse = parseTensorTokensE src

parseContractWithExprE :: String -> [ITok] -> Maybe (Either String TensorExpr)
parseContractWithExprE src ts =
  case dropWhile isSpaceITok ts of
    II "contractWith" : rest ->
      Just $
        case parseReducerI (dropWhile isSpaceITok rest) of
          Nothing -> parseError src ts "contractWith needs a reducer, e.g. (+) or max"
          Just (reducer, rest1) ->
            let body = dropWhile isSpaceITok rest1
            in if null body
                 then parseError src ts "contractWith needs a body"
                 else TEContractWith reducer <$> parseTensorTokensE src body
    _ -> Nothing

parseTensorMapExprE :: String -> [ITok] -> Maybe (Either String TensorExpr)
parseTensorMapExprE src ts =
  case splitTopSpaceI (dropWhile isSpaceITok ts) of
    [kw, f, body] | renderIToks kw == "tensorMap" ->
      Just (TETensorMap <$> parseTensorTokensE src f <*> parseTensorTokensE src body)
    _ -> Nothing

parseSubrefsExprE :: String -> [ITok] -> Maybe (Either String TensorExpr)
parseSubrefsExprE src ts =
  case splitTopSpaceI (dropWhile isSpaceITok ts) of
    [kw, body, indices] | renderIToks kw == "subrefs" ->
      Just $
        case parseIxListI indices of
          Nothing -> parseError src ts "subrefs needs an index list, e.g. [~i, _j]"
          Just parts -> TESubrefs <$> parseTensorTokensE src body <*> pure parts
    _ -> Nothing

parseTransposeExprE :: String -> [ITok] -> Maybe (Either String TensorExpr)
parseTransposeExprE src ts =
  case splitTopSpaceI (dropWhile isSpaceITok ts) of
    [kw, names, body] | renderIToks kw == "transpose" ->
      Just $
        case parseNameListI names of
          Nothing -> parseError src ts "transpose needs a name list, e.g. [j, i]"
          Just ns -> TETranspose ns <$> parseTensorTokensE src body
    _ -> Nothing

parseIxListI :: [ITok] -> Maybe [IxPart]
parseIxListI ts = do
  inside <- bracketInsideI ts
  mapM parseOne (splitTopCommaI inside)
  where
    parseOne item =
      let text = renderIToks (trimTensorIToks item)
      in case parseMarkedPrefix text of
           Just ([p], "") -> Just p
           Just ([], nm) | validSurfaceName nm -> Just (IxPart VDown nm)
           _ -> Nothing

parseNameListI :: [ITok] -> Maybe [String]
parseNameListI ts = do
  inside <- bracketInsideI ts
  mapM parseOne (splitTopCommaI inside)
  where
    parseOne item =
      case trimTensorIToks item of
        [II nm] | validSurfaceName nm -> Just nm
        [IC '~', II nm] | validSurfaceName nm -> Just nm
        [IC '_', II nm] | validSurfaceName nm -> Just nm
        _ -> Nothing

bracketInsideI :: [ITok] -> Maybe [ITok]
bracketInsideI ts =
  case trimTensorIToks ts of
    IC '[' : rest ->
      case closeGroupI ']' rest [] of
        Just (inside, remaining)
          | null (trimTensorIToks remaining) -> Just inside
        _ -> Nothing
    _ -> Nothing

parseWithSymbolsExprE :: String -> [ITok] -> Maybe (Either String TensorExpr)
parseWithSymbolsExprE src ts =
  case dropWhile isSpaceITok ts of
    II "withSymbols" : rest ->
      Just $
        case parseSymbolListTx (dropWhile isSpaceITok rest) of
          Nothing -> parseError src ts "withSymbols needs a bracketed symbol list"
          Just (names, body)
            | null (trimTensorIToks body) ->
                parseError src ts "withSymbols needs a body"
            | otherwise ->
                TEWithSymbols names <$> parseTensorTokensE src body
    _ -> Nothing

parseDerivativeExprE :: String -> [ITok] -> Maybe (Either String TensorExpr)
parseDerivativeExprE src ts =
  case collectDerivatives [] (dropWhile isSpaceITok ts) of
    Just (parts, rest)
      | not (null parts) ->
          Just $
            if null (trimTensorIToks rest)
              then parseError src ts "indexed derivative needs an operand"
              else TEDerivative parts <$> parseTensorTokensE src rest
    _ -> Nothing
  where
    collectDerivatives acc (II w : rest)
      | (base, [p]) <- parseIndexedIdent w
      , base == "d" || base == "∂" =
          collectDerivatives (acc ++ [p]) (dropWhile isSpaceITok rest)
    collectDerivatives acc (partial@(IC '∂') : marker@(IC mark) : name@(II nm) : rest)
      | mark == '~' || mark == '_' =
          case parseMarkedPrefix (mark : nm) of
            Just ([p], "") ->
              collectDerivatives (acc ++ [p]) (dropWhile isSpaceITok rest)
            _ -> Just (acc, partial : marker : name : rest)
    collectDerivatives acc rest = Just (acc, rest)

parseAppendExprE :: String -> [ITok] -> Maybe (Either String TensorExpr)
parseAppendExprE src ts =
  case breakTopEllipsis ts of
    Just (headT, suffixT) ->
      Just $
        case indexedSuffixOnlyI suffixT of
          Just parts -> TEAppendIndexed <$> parseTensorTokensE src headT <*> pure parts
          Nothing -> parseError src ts "append-index syntax needs marked indices after ..."
    Nothing -> Nothing

parseCallExprE :: String -> [ITok] -> Maybe (Either String TensorExpr)
parseCallExprE src ts = do
  (headT, argsT) <- trailingParenCallI ts
  Just (TECall <$> parseTensorTokensE src headT
               <*> mapM (parseTensorTokensE src) (splitTopCommaI argsT))

parseApplyExprE :: String -> [ITok] -> Maybe (Either String TensorExpr)
parseApplyExprE src ts =
  case splitTopSpaceI ts of
    f:args@(_:_) ->
      Just (TEApply <$> parseTensorTokensE src f
                    <*> mapM (parseTensorTokensE src) args)
    _ -> Nothing

parseUnaryExprE :: String -> [ITok] -> Maybe (Either String TensorExpr)
parseUnaryExprE src (IC op : rest)
  | op == '+' || op == '-'
  , not (null (trimTensorIToks rest)) =
      Just (TEUnary [op] <$> parseTensorTokensE src rest)
parseUnaryExprE _ _ = Nothing

parseNumberExpr :: [ITok] -> Maybe TensorExpr
parseNumberExpr ts =
  let s = renderIToks ts
  in if isNumberText s then Just (TENumber s) else Nothing

parseIfExprE :: String -> [ITok] -> Maybe (Either String TensorExpr)
parseIfExprE src ts0 =
  case trimTensorIToks ts0 of
    II "if" : rest ->
      Just $
        case breakTopKeywordI "then" rest of
          Nothing -> parseError src ts0 "if expression needs then"
          Just (condT, thenRest) ->
            case breakTopKeywordI "else" thenRest of
              Nothing -> parseError src ts0 "if expression needs else"
              Just (thenT, elseT) ->
                TEIf <$> parseTensorTokensE src condT
                     <*> parseTensorTokensE src thenT
                     <*> parseTensorTokensE src elseT
    _ -> Nothing

parseError :: String -> [ITok] -> String -> Either String a
parseError src ts msg =
  Left (msg ++ near ++ column ++ " in: " ++ src)
  where
    frag = renderIToks (trimTensorIToks ts)
    near
      | null frag = " at end"
      | frag == strip src = ""
      | otherwise = " near: " ++ frag
    column =
      case sourceColumnOfTokens src (trimTensorIToks ts) of
        Just n -> " at column " ++ show n
        Nothing -> ""

sourceColumnOfTokens :: String -> [ITok] -> Maybe Int
sourceColumnOfTokens src [] = Just (length src + 1)
sourceColumnOfTokens _ (token:_)
  | itokOffset token > 0 = Just (itokOffset token)
  | otherwise = Nothing

renderReducer :: String -> String
renderReducer "+" = "(+)"
renderReducer "*" = "(*)"
renderReducer reducer = reducer

renderContractBody :: TensorExpr -> String
renderContractBody body@(TEGroup _) = renderTensorExpr body
renderContractBody body = renderTensorAtom body

renderTensorAtom :: TensorExpr -> String
renderTensorAtom e@(TENumber _) = renderTensorExpr e
renderTensorAtom e@(TEIdent _ _) = renderTensorExpr e
renderTensorAtom e@(TECall _ _) = renderTensorExpr e
renderTensorAtom e@(TEApply _ _) = renderTensorExpr e
renderTensorAtom e@(TEAppendIndexed _ _) = renderTensorExpr e
renderTensorAtom e@(TETensorMap _ _) = renderTensorExpr e
renderTensorAtom e@(TESubrefs _ _) = renderTensorExpr e
renderTensorAtom e@(TETranspose _ _) = renderTensorExpr e
renderTensorAtom e@(TEDisjoint _) = renderTensorExpr e
renderTensorAtom e@(TEGroup _) = renderTensorExpr e
renderTensorAtom e = "(" ++ renderTensorExpr e ++ ")"

renderTensorUnaryArg :: TensorExpr -> String
renderTensorUnaryArg e@(TENumber _) = renderTensorExpr e
renderTensorUnaryArg e@(TEIdent _ _) = renderTensorExpr e
renderTensorUnaryArg e@(TECall _ _) = renderTensorExpr e
renderTensorUnaryArg e@(TEApply _ _) = renderTensorExpr e
renderTensorUnaryArg e@(TEAppendIndexed _ _) = renderTensorExpr e
renderTensorUnaryArg e@(TETensorMap _ _) = renderTensorExpr e
renderTensorUnaryArg e@(TESubrefs _ _) = renderTensorExpr e
renderTensorUnaryArg e@(TETranspose _ _) = renderTensorExpr e
renderTensorUnaryArg e@(TEDisjoint _) = renderTensorExpr e
renderTensorUnaryArg e@(TEGroup _) = renderTensorExpr e
renderTensorUnaryArg e = "(" ++ renderTensorExpr e ++ ")"

renderTensorDotPart :: TensorExpr -> String
renderTensorDotPart e@(TEBinary _ _ _) = "(" ++ renderTensorExpr e ++ ")"
renderTensorDotPart e = renderTensorExpr e

renderTensorBinarySide :: String -> TensorExpr -> String
renderTensorBinarySide parentOp e@(TEBinary op _ _)
  | parentOp `elem` ["+", "*"] && op == parentOp = renderTensorExpr e
  | otherwise = "(" ++ renderTensorExpr e ++ ")"
renderTensorBinarySide _ e@(TEDot _) = "(" ++ renderTensorExpr e ++ ")"
renderTensorBinarySide _ e = renderTensorExpr e

splitTopAddI :: [ITok] -> Maybe ([ITok], String, [ITok])
splitTopAddI = splitTopBinaryOpsI ["+", "-"] True

splitTopMulDivI :: [ITok] -> Maybe ([ITok], String, [ITok])
splitTopMulDivI = splitTopBinaryOpsI ["*", "/"] False

splitTopPowerI :: [ITok] -> Maybe ([ITok], String, [ITok])
splitTopPowerI = splitTopBinaryOpsRightI ["**", "^"] False

splitTopBinaryOpsI :: [String] -> Bool -> [ITok] -> Maybe ([ITok], String, [ITok])
splitTopBinaryOpsI ops rejectUnary = go (0 :: Int) [] Nothing
  where
    ops' = sortOps ops

    go _ _ found [] = found
    go d acc found toks@(token@(IC c) : rest)
      | c `elem` "([" = go (d + 1) (token : acc) found rest
      | c `elem` ")]" = go (d - 1) (token : acc) found rest
      | d == 0
      , Just (op, after) <- matchAnyOp ops' toks
      , not (isPowerStar op acc after)
      , not rejectUnary || binaryOpAllowed acc =
          let lhs = trimTensorIToks (reverse acc)
              rhs = trimTensorIToks after
              opToks = take (length op) toks
          in go d (reverse opToks ++ acc) (Just (lhs, op, rhs)) after
    go d acc found (t : rest) = go d (t : acc) found rest

splitTopBinaryOpsRightI :: [String] -> Bool -> [ITok] -> Maybe ([ITok], String, [ITok])
splitTopBinaryOpsRightI ops rejectUnary = go (0 :: Int) []
  where
    ops' = sortOps ops

    go _ _ [] = Nothing
    go d acc toks@(token@(IC c) : rest)
      | c `elem` "([" = go (d + 1) (token : acc) rest
      | c `elem` ")]" = go (d - 1) (token : acc) rest
      | d == 0
      , Just (op, after) <- matchAnyOp ops' toks
      , not (isPowerStar op acc after)
      , not rejectUnary || binaryOpAllowed acc =
          Just (trimTensorIToks (reverse acc), op, trimTensorIToks after)
    go d acc (t : rest) = go d (t : acc) rest

splitTopDisjointI :: [ITok] -> [[ITok]]
splitTopDisjointI = go (0 :: Int) []
  where
    go _ acc [] = [trimTensorIToks (reverse acc)]
    go d acc (IC '!' : IC '.' : rest)
      | d == 0
      , leftSpaceI acc
      , rightSpaceI rest =
          trimTensorIToks (reverse acc) : go d [] rest
    go d acc (t@(IC c) : rest)
      | c `elem` "([" = go (d + 1) (t : acc) rest
      | c `elem` ")]" = go (d - 1) (t : acc) rest
    go d acc (t : rest) = go d (t : acc) rest

sortOps :: [String] -> [String]
sortOps = foldr insertLonger []
  where
    insertLonger op [] = [op]
    insertLonger op xs@(x:rest)
      | length op >= length x = op : xs
      | otherwise = x : insertLonger op rest

matchAnyOp :: [String] -> [ITok] -> Maybe (String, [ITok])
matchAnyOp [] _ = Nothing
matchAnyOp (op:ops) toks =
  case stripOpPrefix op toks of
    Just rest -> Just (op, rest)
    Nothing -> matchAnyOp ops toks

stripOpPrefix :: String -> [ITok] -> Maybe [ITok]
stripOpPrefix [] rest = Just rest
stripOpPrefix (c:cs) (IC t : rest)
  | c == t = stripOpPrefix cs rest
stripOpPrefix _ _ = Nothing

isPowerStar :: String -> [ITok] -> [ITok] -> Bool
isPowerStar "*" acc after =
  case (acc, after) of
    (_, IC '*' : _) -> True
    (IC '*' : _, _) -> True
    _ -> False
isPowerStar _ _ _ = False

binaryOpAllowed :: [ITok] -> Bool
binaryOpAllowed acc =
  case dropWhile isSpaceITok acc of
    [] -> False
    IC p : _ | p `elem` "([,+-*/^=<>&|!" -> False
    II e : rest | (e == "e" || e == "E") && exponentMarkerContext rest -> False
    _ -> True
  where
    exponentMarkerContext (IC c : _) = isDigit c || c == '.'
    exponentMarkerContext _ = False

splitTopDotsI :: [ITok] -> [[ITok]]
splitTopDotsI = go (0 :: Int) []
  where
    go _ acc [] = [trimTensorIToks (reverse acc)]
    go d acc (t@(IC c) : rest)
      | c `elem` "([" = go (d + 1) (t : acc) rest
      | c `elem` ")]" = go (d - 1) (t : acc) rest
      | d == 0
      , c == '.'
      , leftSpaceI acc
      , rightSpaceI rest =
              trimTensorIToks (reverse acc) : go d [] rest
    go d acc (t : rest) = go d (t : acc) rest

splitTopCommaI :: [ITok] -> [[ITok]]
splitTopCommaI = splitTopCharI ','

splitTopCharI :: Char -> [ITok] -> [[ITok]]
splitTopCharI sep = go (0 :: Int) []
  where
    go _ acc [] = [trimTensorIToks (reverse acc)]
    go d acc (t@(IC c) : rest)
      | c `elem` "([" = go (d + 1) (t : acc) rest
      | c `elem` ")]" = go (d - 1) (t : acc) rest
      | d == 0, c == sep =
          trimTensorIToks (reverse acc) : go d [] rest
    go d acc (t : rest) = go d (t : acc) rest

splitTopSpaceI :: [ITok] -> [[ITok]]
splitTopSpaceI = filter (not . null) . go (0 :: Int) []
  where
    go _ acc [] = [trimTensorIToks (reverse acc)]
    go d acc (t@(IC c) : rest)
      | c `elem` "([" = go (d + 1) (t : acc) rest
      | c `elem` ")]" = go (d - 1) (t : acc) rest
      | d == 0, isSpace c =
          trimTensorIToks (reverse acc) : go d [] (dropWhile isSpaceITok rest)
    go d acc (t : rest) = go d (t : acc) rest

trailingParenCallI :: [ITok] -> Maybe ([ITok], [ITok])
trailingParenCallI ts0 =
  let ts = trimTensorIToks ts0
  in case reverse ts of
       IC ')' : insideRev ->
         case findTrailingOpen (0 :: Int) [] insideRev of
           Just (argsT, headRev) ->
             let headRaw = reverse headRev
                 headT = trimTensorIToks headRaw
             in if null headT || lastIsSpaceI headRaw
                  then Nothing
                  else Just (headT, argsT)
           Nothing -> Nothing
       _ -> Nothing
  where
    findTrailingOpen _ _ [] = Nothing
    findTrailingOpen d acc (token@(IC ')') : rest) =
      findTrailingOpen (d + 1) (token : acc) rest
    findTrailingOpen d acc (token@(IC '(') : rest)
      | d == 0 = Just (trimTensorIToks acc, rest)
      | otherwise = findTrailingOpen (d - 1) (token : acc) rest
    findTrailingOpen d acc (t : rest) = findTrailingOpen d (t : acc) rest

    lastIsSpaceI toks =
      case reverse toks of
        IC c : _ -> isSpace c
        _ -> False

breakTopKeywordI :: String -> [ITok] -> Maybe ([ITok], [ITok])
breakTopKeywordI kw = go (0 :: Int) []
  where
    go _ _ [] = Nothing
    go d acc (t@(IC c) : rest)
      | c `elem` "([" = go (d + 1) (t : acc) rest
      | c `elem` ")]" = go (d - 1) (t : acc) rest
    go 0 acc (II w : rest)
      | w == kw = Just (trimTensorIToks (reverse acc), trimTensorIToks rest)
    go d acc (t : rest) = go d (t : acc) rest

isNumberText :: String -> Bool
isNumberText s =
  case reads s :: [(Double, String)] of
    [(_, "")] -> any isDigit s && startsNumber s
    _ -> False
  where
    startsNumber (c:_) = isDigit c || c == '.'
    startsNumber [] = False

leftSpaceI :: [ITok] -> Bool
leftSpaceI (IC c : _) = isSpace c
leftSpaceI _ = False

rightSpaceI :: [ITok] -> Bool
rightSpaceI (IC c : _) = isSpace c
rightSpaceI _ = False

hasEllipsisAtTop :: [ITok] -> Bool
hasEllipsisAtTop ts =
  case breakTopEllipsis ts of
    Just _ -> True
    Nothing -> False

breakTopEllipsis :: [ITok] -> Maybe ([ITok], [ITok])
breakTopEllipsis = go (0 :: Int) []
  where
    go _ _ [] = Nothing
    go d acc (token@(IC c) : rest)
      | c `elem` "([" = go (d + 1) (token : acc) rest
      | c `elem` ")]" = go (d - 1) (token : acc) rest
    go 0 acc (IC '.' : IC '.' : IC '.' : rest) =
      Just (trimTensorIToks (reverse acc), rest)
    go d acc (t : rest) = go d (t : acc) rest

stripOuterGroupI :: [ITok] -> Maybe [ITok]
stripOuterGroupI ts =
  case trimTensorIToks ts of
    IC '(' : rest ->
      case closeGroupI ')' rest [] of
        Just (inner, rest') | all isSpaceITok rest' -> Just inner
        _ -> Nothing
    _ -> Nothing

closeGroupI :: Char -> [ITok] -> [ITok] -> Maybe ([ITok], [ITok])
closeGroupI close toks acc0 = go (0 :: Int) acc0 toks
  where
    go _ _ [] = Nothing
    go d acc (token@(IC c) : rest)
      | c == close && d == 0 = Just (reverse acc, rest)
      | c == close = go (d - 1) (token : acc) rest
      | (close == ')' && c == '(') || (close == ']' && c == '[') =
          go (d + 1) (token : acc) rest
    go d acc (t : rest) = go d (t : acc) rest

parseReducerI :: [ITok] -> Maybe (String, [ITok])
parseReducerI (IC '(' : rest0) =
  case dropWhile isSpaceITok rest0 of
    IC op : rest1 | op `elem` "+*" ->
      case dropWhile isSpaceITok rest1 of
        IC ')' : rest2 -> Just ([op], rest2)
        _ -> Nothing
    _ -> Nothing
parseReducerI (II nm : rest)
  | validSurfaceName nm = Just (nm, rest)
parseReducerI _ = Nothing

parseSymbolListTx :: [ITok] -> Maybe ([String], [ITok])
parseSymbolListTx (IC '[' : rest) =
  case breakSymbolListTx (0 :: Int) [] rest of
    Just (inside, rest1) -> Just (symbolNamesTx inside, dropWhile isSpaceITok rest1)
    Nothing -> Nothing
parseSymbolListTx _ = Nothing

breakSymbolListTx :: Int -> [ITok] -> [ITok] -> Maybe ([ITok], [ITok])
breakSymbolListTx _ _ [] = Nothing
breakSymbolListTx d acc (token@(IC ']') : rest)
  | d == 0 = Just (reverse acc, rest)
  | otherwise = breakSymbolListTx (d - 1) (token : acc) rest
breakSymbolListTx d acc (token@(IC '[') : rest) =
  breakSymbolListTx (d + 1) (token : acc) rest
breakSymbolListTx d acc (t : rest) = breakSymbolListTx d (t : acc) rest

symbolNamesTx :: [ITok] -> [String]
symbolNamesTx = go
  where
    go [] = []
    go (II nm : rest) | validSurfaceName nm = nm : go rest
    go (_ : rest) = go rest

indexedSuffixOnlyI :: [ITok] -> Maybe [IxPart]
indexedSuffixOnlyI ts =
  let (parts, rest) = indexedSuffixTx ts
  in if null (trimTensorIToks rest) then Just parts else Nothing

indexedSuffixTx :: [ITok] -> ([IxPart], [ITok])
indexedSuffixTx (marker@(IC m) : name@(II nm) : rest)
  | m == '~' || m == '_' =
      case parseMarkedPrefix (m : nm) of
        Just (parts, suffixRest) | null suffixRest ->
          let (more, rest') = indexedSuffixTx rest
          in (parts ++ more, rest')
        _ -> ([], marker : name : rest)
indexedSuffixTx ts = ([], ts)

trimTensorIToks :: [ITok] -> [ITok]
trimTensorIToks = dropWhile isSpaceITok . reverse . dropWhile isSpaceITok . reverse . dropWhile isSpaceITok

renderIToks :: [ITok] -> String
renderIToks = concatMap outI
  where
    outI (II w) = w
    outI (IC c) = [c]

isSpaceITok :: ITok -> Bool
isSpaceITok (IC c) = isSpace c
isSpaceITok _ = False

-- Expand operator applications on the TensorExpr AST.  Resolved bodies are
-- def-free, but higher-order substitution can introduce another definition.
-- Bound the nesting of such expansions so self-application is diagnosed
-- instead of making fec diverge.
maxDefExpansionDepth :: Int
maxDefExpansionDepth = 128

expandDefs :: [Def] -> String -> IO String
expandDefs defs s = renderTensorExpr <$> expandDefsAst defs s

expandDefsAst :: [Def] -> String -> IO TensorExpr
expandDefsAst defs s = do
  ast <- parseTensorExprIO "bad tensor expression" s
  expandDefExpr (map (\df -> df { defSourceText = Nothing }) defs) ast

-- Expand the original, source-annotated expression through the original
-- bodies of user definitions.  Unlike `expandDefs`, this path preserves the
-- definition-site origin of each introduced subtree and records every call
-- site crossed on the way to it.
expandDefsWithSource :: [Def] -> SourceText -> IO TensorExpr
expandDefsWithSource defs source = do
  ast <- case parseSourceTensorExpr source of
           Right expression -> return expression
           Left message -> fatal ("bad source-mapped tensor expression: " ++ message)
  expandDefExpr defs ast

expandDefExpr :: [Def] -> TensorExpr -> IO TensorExpr
expandDefExpr = expandDefExprAt maxDefExpansionDepth

expandDefExprAt :: Int -> [Def] -> TensorExpr -> IO TensorExpr
expandDefExprAt fuel defs expr =
  case expr of
    TENumber _ -> return expr
    TEIdent nm [] | Just df <- lookupDef nm defs, null (defParams df) ->
      applyDefAtCall defs df expr []
    TEIdent _ _ -> return expr
    TEUnary op body ->
      keepSpan (TEUnary op <$> expand body)
    TECall f args ->
      keepSpan (TECall <$> expand f <*> mapM expand args)
    TEApply (TEIdent nm []) args
      | Just df <- lookupDef nm defs -> do
          if fuel <= 0
            then fatal ("operator expansion exceeded " ++ show maxDefExpansionDepth
                        ++ " nested applications near " ++ renderTensorExpr expr
                        ++ "; possible higher-order recursion")
            else return ()
          args' <- mapM expand args
          let n = length (defParams df)
          if length args' < n
            then fatal ("operator " ++ defName df ++ " needs "
                        ++ show n ++ " argument(s)")
            else return ()
          let (used, rest) = splitAt n args'
          -- Combine surplus arguments before re-expansion.  A higher-order
          -- body may return a function (pass lap u) or a partial application
          -- (apply apply lap u), and both must see the surplus arguments as
          -- part of the same application node.
          body0 <- applyDefAtCall defs df expr used
          let result0 = appendApplyArgs body0 rest
          result <- expandDefExprAt (fuel - 1) defs result0
          return (setTensorSpan (tensorExprSpan expr) result)
    TEApply f args -> do
      f' <- expand f
      args' <- mapM expand args
      let result0 = copyTensorMetadata expr (appendApplyArgs f' args')
      if hasDefinitionHead result0
        then do
          result <- expandDefExprAt fuel defs result0
          return (setTensorSpan (tensorExprSpan expr) result)
        else return (setTensorSpan (tensorExprSpan expr) result0)
    TEIf c t e ->
      keepSpan (TEIf <$> expand c <*> expand t <*> expand e)
    TEAppendIndexed (TEIdent base0 parts) appendParts -> do
      keepSpan (return (TEAppendIndexed (TEIdent base0 parts) appendParts))
    TEAppendIndexed e parts ->
      keepSpan (TEAppendIndexed <$> expand e <*> pure parts)
    TEWithSymbols names body ->
      keepSpan (TEWithSymbols names <$> expand body)
    TEContractWith reducer body ->
      keepSpan (TEContractWith reducer <$> expand body)
    TETensorMap f body ->
      keepSpan (TETensorMap <$> expand f <*> expand body)
    TESubrefs body parts ->
      keepSpan (TESubrefs <$> expand body <*> pure parts)
    TETranspose names body ->
      keepSpan (TETranspose names <$> expand body)
    TEDisjoint parts ->
      keepSpan (TEDisjoint <$> mapM expand parts)
    TEDerivative parts body ->
      keepSpan (TEDerivative parts <$> expand body)
    TEDot parts
      | Just dotDef <- lookupDef "." defs -> do
          if fuel <= 0
            then fatal ("operator expansion exceeded " ++ show maxDefExpansionDepth
                        ++ " nested applications near " ++ renderTensorExpr expr
                        ++ "; possible higher-order recursion")
            else return ()
          parts' <- mapM expand parts
          body0 <- expandDotAst defs dotDef expr parts'
          body <- expandDefExprAt (fuel - 1) defs body0
          return (setTensorSpan (tensorExprSpan expr) body)
      | otherwise ->
          keepSpan (TEDot <$> mapM expand parts)
    TEBinary op lhs rhs ->
      keepSpan (TEBinary op <$> expand lhs <*> expand rhs)
    TEGroup body ->
      keepSpan (TEGroup <$> expand body)
  where
    expand = expandDefExprAt fuel defs
    keepSpan action = copyTensorMetadata expr <$> action
    appendApplyArgs body [] = body
    appendApplyArgs (TEGroup body) outer = appendApplyArgs body outer
    appendApplyArgs (TEApply f inner) outer = appendApplyArgs f (inner ++ outer)
    appendApplyArgs body outer = copyTensorMetadata body (TEApply body outer)
    hasDefinitionHead (TEApply (TEIdent nm []) _) =
      case lookupDef nm defs of
        Just _ -> True
        Nothing -> False
    hasDefinitionHead _ = False

lookupDef :: String -> [Def] -> Maybe Def
lookupDef nm defs =
  case [df | df <- defs, defName df == nm] of
    df:_ -> Just df
    [] -> Nothing

expandDotAst :: [Def] -> Def -> TensorExpr -> [TensorExpr] -> IO TensorExpr
expandDotAst _ _ _ [] = return (TENumber "1")
expandDotAst _ _ _ [p] = return p
expandDotAst defs dotDef call (p:ps) =
  foldM (\lhs rhs -> applyDefAtCall defs dotDef call [lhs, rhs]) p ps

applyDefAtCall :: [Def] -> Def -> TensorExpr -> [TensorExpr] -> IO TensorExpr
applyDefAtCall defs df call args = do
  body <- applyDefAst defs df args
  return (addDefinitionExpansion df call body)

applyDefAst :: [Def] -> Def -> [TensorExpr] -> IO TensorExpr
applyDefAst _ df args = do
  ast <- case defSourceText df of
           Just source ->
             case parseSourceTensorExpr source of
               Right expression -> return expression
               Left message -> fatal ("in def " ++ defName df ++ ": " ++ message)
           Nothing -> parseTensorExprIO ("in def " ++ defName df) (defBody df)
  let env = zip (map defParamBase (defParams df)) (map argInfo args)
  substExpr df env ast
  where
    defParamBase p = fst (parseIndexedIdent (stripPatternEllipsis p))
    stripPatternEllipsis p
      | "..." `isSuffixOf` p = take (length p - 3) p
      | otherwise = p

addDefinitionExpansion :: Def -> TensorExpr -> TensorExpr -> TensorExpr
addDefinitionExpansion df call body =
  case (defSourceText df, tensorExprOrigin call) of
    (Just definitionSource, Just callOrigin) ->
      addFrame frame (originTrace callOrigin) body
      where
        frame = ExpansionFrame
          { expansionName = defName df
          , expansionDefinition =
              sourceLocationForSpan definitionSource
                (SourceSpan 1 (max 1 (length (sourceTranslated definitionSource))))
          , expansionCall = originLocation callOrigin
          }
    _ -> body
  where
    addFrame frame inherited expr =
      let rebuilt = mapTensorChildren (addFrame frame inherited) expr
          origin = case tensorExprOrigin expr of
            Just current ->
              Just current
                { originTrace = frame : nub (originTrace current ++ inherited) }
            Nothing -> Nothing
      in TensorExpr (tensorExprSpan expr) origin (tensorExprNode rebuilt)

type ArgInfo = (TensorExpr, Maybe (String, Int, [IxPart]))

argInfo :: TensorExpr -> ArgInfo
argInfo expr =
  case stripGroupAst expr of
    TEIdent base0 parts ->
      let (base, primes) = fieldBaseOf base0
      in (expr, Just (base, primes, parts))
    _ -> (expr, Nothing)

substExpr :: Def -> [(String, ArgInfo)] -> TensorExpr -> IO TensorExpr
substExpr df env expr =
  case expr of
    TENumber _ -> return expr
    TEIdent base0 parts ->
      let (base, primes) = fieldBaseOf base0
      in case lookup base env of
           Just arg | null parts -> return (argWithPrimes arg primes)
                    | otherwise -> argWithParts df arg primes parts
           Nothing -> return expr
    TEUnary op body ->
      keepSpan (TEUnary op <$> subst body)
    TECall f args ->
      keepSpan (TECall <$> subst f <*> mapM subst args)
    TEApply f args ->
      keepSpan (TEApply <$> subst f <*> mapM subst args)
    TEIf c t e ->
      keepSpan (TEIf <$> subst c <*> subst t <*> subst e)
    TEAppendIndexed (TEIdent base0 parts) appendParts ->
      let (base, primes) = fieldBaseOf base0
      in case lookup base env of
           Just arg -> return (argWithAppendParts arg primes parts appendParts)
           Nothing -> return expr
    TEAppendIndexed e parts ->
      keepSpan (TEAppendIndexed <$> subst e <*> pure parts)
    TEWithSymbols names body ->
      keepSpan (TEWithSymbols names <$> subst body)
    TEContractWith reducer body ->
      keepSpan (TEContractWith reducer <$> subst body)
    TETensorMap f body ->
      keepSpan (TETensorMap <$> subst f <*> subst body)
    TESubrefs body parts ->
      keepSpan (TESubrefs <$> subst body <*> pure parts)
    TETranspose names body ->
      keepSpan (TETranspose names <$> subst body)
    TEDisjoint parts ->
      keepSpan (TEDisjoint <$> mapM subst parts)
    TEDerivative parts body ->
      keepSpan (TEDerivative parts <$> subst body)
    TEDot parts ->
      keepSpan (TEDot <$> mapM subst parts)
    TEBinary op lhs rhs ->
      keepSpan (TEBinary op <$> subst lhs <*> subst rhs)
    TEGroup e ->
      keepSpan (TEGroup <$> subst e)
  where
    subst = substExpr df env
    keepSpan action = copyTensorMetadata expr <$> action

argWithPrimes :: ArgInfo -> Int -> TensorExpr
argWithPrimes (arg, Just (base, primes0, parts)) primes =
  copyTensorMetadata arg
    (TEIdent (base ++ replicate (primes0 + primes) '\'') parts)
argWithPrimes (arg, Nothing) primes
  | primes == 0 = arg
  | otherwise =
      copyTensorMetadata arg
        (TEApply (TEIdent (renderTensorAtom arg ++ replicate primes '\'') []) [])

argWithParts :: Def -> ArgInfo -> Int -> [IxPart] -> IO TensorExpr
argWithParts _ (arg, _) primes parts
  | TEWithSymbols names body <- stripGroupAst arg
  , length names == length parts =
      let body' = renameLocalIxAst (zip names parts) body
      in return (argWithPrimes (body', argInfoSimple body') primes)
  where
    argInfoSimple expr =
      case stripGroupAst expr of
        TEIdent base0 parts0 ->
          let (base, primes0) = fieldBaseOf base0
          in Just (base, primes0, parts0)
        _ -> Nothing
argWithParts _ (arg, Just (base, primes0, _)) primes parts =
  return (copyTensorMetadata arg
            (TEIdent (base ++ replicate (primes0 + primes) '\'') parts))
argWithParts _ (arg, Nothing) primes parts =
  return (appendPartsWithPrimes arg primes parts)

argWithAppendParts :: ArgInfo -> Int -> [IxPart] -> [IxPart] -> TensorExpr
argWithAppendParts (arg, Just (base, primes0, argParts)) primes parts appendParts =
  let keptParts = if null parts then argParts else parts
  in copyTensorMetadata arg
       (TEIdent (base ++ replicate (primes0 + primes) '\'')
                (keptParts ++ appendParts))
argWithAppendParts (arg, Nothing) primes parts appendParts =
  appendPartsWithPrimes arg primes (parts ++ appendParts)

appendPartsWithPrimes :: TensorExpr -> Int -> [IxPart] -> TensorExpr
appendPartsWithPrimes arg primes parts =
  let arg' = if primes == 0
               then arg
               else copyTensorMetadata arg
                      (TEApply (TEIdent (renderTensorAtom arg ++ replicate primes '\'') []) [])
  in copyTensorMetadata arg (TEAppendIndexed arg' parts)

renameLocalIxAst :: [(String, IxPart)] -> TensorExpr -> TensorExpr
renameLocalIxAst aliases expr =
  case expr of
    TENumber _ -> expr
    TEIdent base parts ->
      keep (TEIdent base (renameParts parts))
    TEUnary op body ->
      keep (TEUnary op (rename body))
    TECall f args ->
      keep (TECall (rename f) (map rename args))
    TEApply f args ->
      keep (TEApply (rename f) (map rename args))
    TEIf c t e ->
      keep (TEIf (rename c) (rename t) (rename e))
    TEAppendIndexed e parts ->
      keep (TEAppendIndexed (rename e) (renameParts parts))
    TEWithSymbols names body ->
      let aliases' = [(nm, p) | (nm, p) <- aliases, nm `notElem` names]
      in keep (TEWithSymbols names (renameLocalIxAst aliases' body))
    TEContractWith reducer body ->
      keep (TEContractWith reducer (rename body))
    TETensorMap f body ->
      keep (TETensorMap (rename f) (rename body))
    TESubrefs body parts ->
      keep (TESubrefs (rename body) (renameParts parts))
    TETranspose names body ->
      keep (TETranspose (map renameName names) (rename body))
    TEDisjoint parts ->
      keep (TEDisjoint (map rename parts))
    TEDerivative parts body ->
      keep (TEDerivative (renameParts parts) (rename body))
    TEDot parts ->
      keep (TEDot (map rename parts))
    TEBinary op lhs rhs ->
      keep (TEBinary op (rename lhs) (rename rhs))
    TEGroup body ->
      keep (TEGroup (rename body))
  where
    rename = renameLocalIxAst aliases
    keep = copyTensorMetadata expr
    renameParts =
      map (\p@(IxPart _ nm) ->
             case lookup nm aliases of
               Just p' -> p'
               Nothing -> p)
    renameName nm =
      case lookup nm aliases of
        Just (IxPart _ nm') -> nm'
        Nothing -> nm

stripGroupAst :: TensorExpr -> TensorExpr
stripGroupAst (TEGroup e) = stripGroupAst e
stripGroupAst e = e

-- Free indices come from the left-hand side.  Repeated upper/lower index
-- letters form diagonal axes; only contractWith, or `.` via contractWith,
-- folds those axes.
-- delta~i_j is Kronecker's delta, and epsilon~i~j~k is the 3D Levi-Civita
-- symbol.
strictEinstein :: Model -> [String] -> [IxPart] -> String -> IO ()
strictEinstein m lets lhs expr = do
  parsed <- parseTensorExprIO "bad tensor expression" expr
  ete <- elaborateTensorExpr m lets lhs parsed
  mapM_ checkTermInfo (eteTermInfo ete)
  where
    checkTermInfo info = do
      case tiDiagIx info of
        d:_ -> fatal ("index " ++ diagName d ++ " is diagonal but not contracted; use contractWith or . in: " ++ expr)
        [] -> return ()
      mapM_ checkFree lhs
      mapM_ checkExtraFree extraFreeNames
      where
        frees = tiFreeIx info
        lhsNames = map ixName lhs
        extraFreeNames = nub [nm | IxPart _ nm <- frees, nm `notElem` lhsNames]
        sameName nm (IxPart _ nm') = nm == nm'
        checkFree lp@(IxPart lv ln) =
          case filter (sameName ln) frees of
            [IxPart rv _] | rv == lv -> return ()
            [] -> fatal ("free index " ++ showIx lp ++ " is missing in term: " ++ expr)
            [_] -> fatal ("free index " ++ showIx lp ++ " has wrong variance in term: " ++ expr)
            _ -> fatal ("free index " ++ ixName lp ++ " appears more than once in term: " ++ expr)
        checkExtraFree nm =
          fatal ("index " ++ nm ++ " is free but not on the left-hand side in term: " ++ expr)

showIx :: IxPart -> String
showIx (IxPart VUp nm) = "~" ++ nm
showIx (IxPart VDown nm) = "_" ++ nm

validateFieldRefParts :: Model -> [String] -> String -> IO ()
validateFieldRefParts m lets w =
  let (base0, parts) = parseIndexedIdent w
      (fname, _) = fieldBaseOf base0
  in case fieldDeclOf m fname of
       Just fd -> validateDecl fd parts
       Nothing | fname `elem` lets -> return ()
       _ -> return ()
  where
    validateDecl fd parts =
      case (fdIndex fd, parts) of
        (Nothing, []) -> return ()
        (Nothing, _ : _) ->
          case kindOf m (fdName fd) of
            Just kind | componentRank kind == length parts -> return ()
            _ ->
              fatal ("field " ++ fdName fd ++ " has no declared index variance; use the indexed field syntax in its declaration")
        (Just _, []) ->
          fatal ("indexed tensor field " ++ fdName fd
                 ++ " must be referenced with indices")
        (Just (FieldIndex [Plain decl]), _) ->
          if sameVarianceList decl parts
            then return ()
            else fatal ("field " ++ fdName fd ++ " is referenced with incompatible index variance: " ++ w)
        (Just (FieldIndex [Symmetric decl]), _) ->
          if sameVarianceList decl parts || sameVarianceList (reverse decl) parts
            then return ()
            else fatal ("symmetric field " ++ fdName fd ++ " is referenced with incompatible index variance: " ++ w)
        (Just (FieldIndex [Antisymmetric decl]), _) ->
          if sameVarianceList decl parts || sameVarianceList (reverse decl) parts
            then return ()
            else fatal ("antisymmetric field " ++ fdName fd ++ " is referenced with incompatible index variance: " ++ w)
        _ -> fatal ("unsupported field index declaration for " ++ fdName fd)
