{-# LANGUAGE PatternSynonyms #-}

module Formurae.TensorExpr
  ( TensorExpr
  , SourceSpan(..)
  , noSourceSpan
  , tensorExprSpan
  , pattern TENumber
  , pattern TEIdent
  , pattern TEUnary
  , pattern TECall
  , pattern TEApply
  , pattern TEIf
  , pattern TEAppendIndexed
  , pattern TEWithSymbols
  , pattern TEContractWith
  , pattern TEDerivative
  , pattern TEDot
  , pattern TEBinary
  , pattern TEGroup
  , TensorInfo(..)
  , DiagIx(..)
  , ElaboratedTensorExpr(..)
  , Placement
  , zeroPlaceB
  , placeVB
  , placeSB
  , placeText
  , parseTensorExpr
  , parseTensorExprEither
  , renderTensorExpr
  , normalizeTensorExpr
  , preprocessTensorExpr
  , elaborateTensorExpr
  , ixExpand
  , expandTensorDefs
  , expandDefs
  , strictEinstein
  , validateFieldRefParts
  ) where

import Data.Char (isAlphaNum, isDigit, isSpace)
import Data.List (intercalate, isPrefixOf, nub, stripPrefix)
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

data TensorExpr = TensorExpr
  { tensorExprSpan :: SourceSpan
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
  | TEDerivativeNode [IxPart] TensorExpr
  | TEDotNode [TensorExpr]
  | TEBinaryNode String TensorExpr TensorExpr
  | TEGroupNode TensorExpr
  deriving (Eq, Show)

pattern TENumber :: String -> TensorExpr
pattern TENumber s <- TensorExpr _ (TENumberNode s)
  where TENumber s = TensorExpr noSourceSpan (TENumberNode s)

pattern TEIdent :: String -> [IxPart] -> TensorExpr
pattern TEIdent base parts <- TensorExpr _ (TEIdentNode base parts)
  where TEIdent base parts = TensorExpr noSourceSpan (TEIdentNode base parts)

pattern TEUnary :: String -> TensorExpr -> TensorExpr
pattern TEUnary op e <- TensorExpr _ (TEUnaryNode op e)
  where TEUnary op e = TensorExpr noSourceSpan (TEUnaryNode op e)

pattern TECall :: TensorExpr -> [TensorExpr] -> TensorExpr
pattern TECall f args <- TensorExpr _ (TECallNode f args)
  where TECall f args = TensorExpr noSourceSpan (TECallNode f args)

pattern TEApply :: TensorExpr -> [TensorExpr] -> TensorExpr
pattern TEApply f args <- TensorExpr _ (TEApplyNode f args)
  where TEApply f args = TensorExpr noSourceSpan (TEApplyNode f args)

pattern TEIf :: TensorExpr -> TensorExpr -> TensorExpr -> TensorExpr
pattern TEIf c t e <- TensorExpr _ (TEIfNode c t e)
  where TEIf c t e = TensorExpr noSourceSpan (TEIfNode c t e)

pattern TEAppendIndexed :: TensorExpr -> [IxPart] -> TensorExpr
pattern TEAppendIndexed e parts <- TensorExpr _ (TEAppendIndexedNode e parts)
  where TEAppendIndexed e parts = TensorExpr noSourceSpan (TEAppendIndexedNode e parts)

pattern TEWithSymbols :: [String] -> TensorExpr -> TensorExpr
pattern TEWithSymbols names body <- TensorExpr _ (TEWithSymbolsNode names body)
  where TEWithSymbols names body = TensorExpr noSourceSpan (TEWithSymbolsNode names body)

pattern TEContractWith :: String -> TensorExpr -> TensorExpr
pattern TEContractWith reducer body <- TensorExpr _ (TEContractWithNode reducer body)
  where TEContractWith reducer body = TensorExpr noSourceSpan (TEContractWithNode reducer body)

pattern TEDerivative :: [IxPart] -> TensorExpr -> TensorExpr
pattern TEDerivative parts body <- TensorExpr _ (TEDerivativeNode parts body)
  where TEDerivative parts body = TensorExpr noSourceSpan (TEDerivativeNode parts body)

pattern TEDot :: [TensorExpr] -> TensorExpr
pattern TEDot parts <- TensorExpr _ (TEDotNode parts)
  where TEDot parts = TensorExpr noSourceSpan (TEDotNode parts)

pattern TEBinary :: String -> TensorExpr -> TensorExpr -> TensorExpr
pattern TEBinary op lhs rhs <- TensorExpr _ (TEBinaryNode op lhs rhs)
  where TEBinary op lhs rhs = TensorExpr noSourceSpan (TEBinaryNode op lhs rhs)

pattern TEGroup :: TensorExpr -> TensorExpr
pattern TEGroup e <- TensorExpr _ (TEGroupNode e)
  where TEGroup e = TensorExpr noSourceSpan (TEGroupNode e)

{-# COMPLETE TENumber, TEIdent, TEUnary, TECall, TEApply, TEIf,
             TEAppendIndexed, TEWithSymbols, TEContractWith, TEDerivative,
             TEDot, TEBinary, TEGroup #-}

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

type Placement = [Bool]

zeroPlaceB :: Model -> Placement
zeroPlaceB m = replicate (mDim m) False

placeVB :: Model -> Int -> Placement
placeVB m a = [c == a | c <- axisRange m]

placeSB :: Model -> Int -> Int -> Placement
placeSB m a b
  | a == b = zeroPlaceB m
  | otherwise = [c == a || c == b | c <- axisRange m]

togglePlace :: Int -> Placement -> Placement
togglePlace a =
  zipWith (\idx bit -> if idx == a then not bit else bit) [1 :: Int ..]

placeText :: Placement -> String
placeText = plOf

parseTensorExpr :: String -> TensorExpr
parseTensorExpr src =
  case parseTensorExprEither src of
    Right expr -> expr
    Left msg -> errorWithoutStackTrace ("tensor expression parse error: " ++ msg)

parseTensorExprEither :: String -> Either String TensorExpr
parseTensorExprEither src = parseTensorTokensE src (trimTensorIToks (itok src))

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
    keep = setTensorSpan (tensorExprSpan expr)
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
      cAlts <- tensorOccurrenceAlternatives m lets lhs aliases c
      tAlts <- tensorOccurrenceAlternatives m lets lhs aliases t
      eAlts <- tensorOccurrenceAlternatives m lets lhs aliases e
      return (cartesianConcat [cAlts, tAlts, eAlts])
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
setTensorSpan sp (TensorExpr _ node) = TensorExpr sp node

sourceSpanOf :: String -> [ITok] -> SourceSpan
sourceSpanOf src ts =
  let frag = renderIToks (trimTensorIToks ts)
  in case sourceColumn src frag of
       Just start ->
         let len = max 1 (length frag)
         in SourceSpan start (start + len - 1)
       Nothing -> noSourceSpan

parseTensorAtomE :: String -> [ITok] -> Either String TensorExpr
parseTensorAtomE src ts =
  case stripOuterGroupI ts of
    Just inner -> TEGroup <$> parse inner
    Nothing ->
      case parseContractWithExprE src ts of
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
    collectDerivatives acc (IC '∂' : IC mark : II nm : rest)
      | mark == '~' || mark == '_' =
          case parseMarkedPrefix (mark : nm) of
            Just ([p], "") ->
              collectDerivatives (acc ++ [p]) (dropWhile isSpaceITok rest)
            _ -> Just (acc, IC '∂' : IC mark : II nm : rest)
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
      case sourceColumn src frag of
        Just n -> " at column " ++ show n
        Nothing -> ""

sourceColumn :: String -> String -> Maybe Int
sourceColumn src frag
  | null frag = Just (length src + 1)
  | otherwise = go (1 :: Int) src
  where
    go _ [] = Nothing
    go n s@(_:rest)
      | frag `isPrefixOf` s = Just n
      | otherwise = go (n + 1) rest

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
renderTensorAtom e@(TEGroup _) = renderTensorExpr e
renderTensorAtom e = "(" ++ renderTensorExpr e ++ ")"

renderTensorUnaryArg :: TensorExpr -> String
renderTensorUnaryArg e@(TENumber _) = renderTensorExpr e
renderTensorUnaryArg e@(TEIdent _ _) = renderTensorExpr e
renderTensorUnaryArg e@(TECall _ _) = renderTensorExpr e
renderTensorUnaryArg e@(TEApply _ _) = renderTensorExpr e
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
    go d acc found toks@(IC c : rest)
      | c `elem` "([" = go (d + 1) (IC c : acc) found rest
      | c `elem` ")]" = go (d - 1) (IC c : acc) found rest
      | d == 0
      , Just (op, after) <- matchAnyOp ops' toks
      , not (isPowerStar op acc after)
      , not rejectUnary || binaryOpAllowed acc =
          let lhs = trimTensorIToks (reverse acc)
              rhs = trimTensorIToks after
              opToks = map IC op
          in go d (reverse opToks ++ acc) (Just (lhs, op, rhs)) after
    go d acc found (t : rest) = go d (t : acc) found rest

splitTopBinaryOpsRightI :: [String] -> Bool -> [ITok] -> Maybe ([ITok], String, [ITok])
splitTopBinaryOpsRightI ops rejectUnary = go (0 :: Int) []
  where
    ops' = sortOps ops

    go _ _ [] = Nothing
    go d acc toks@(IC c : rest)
      | c `elem` "([" = go (d + 1) (IC c : acc) rest
      | c `elem` ")]" = go (d - 1) (IC c : acc) rest
      | d == 0
      , Just (op, after) <- matchAnyOp ops' toks
      , not (isPowerStar op acc after)
      , not rejectUnary || binaryOpAllowed acc =
          Just (trimTensorIToks (reverse acc), op, trimTensorIToks after)
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
    findTrailingOpen d acc (IC ')' : rest) = findTrailingOpen (d + 1) (IC ')' : acc) rest
    findTrailingOpen d acc (IC '(' : rest)
      | d == 0 = Just (trimTensorIToks acc, rest)
      | otherwise = findTrailingOpen (d - 1) (IC '(' : acc) rest
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
    go d acc (IC c : rest)
      | c `elem` "([" = go (d + 1) (IC c : acc) rest
      | c `elem` ")]" = go (d - 1) (IC c : acc) rest
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
    go d acc (IC c : rest)
      | c == close && d == 0 = Just (reverse acc, rest)
      | c == close = go (d - 1) (IC c : acc) rest
      | (close == ')' && c == '(') || (close == ']' && c == '[') =
          go (d + 1) (IC c : acc) rest
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
breakSymbolListTx d acc (IC ']' : rest)
  | d == 0 = Just (reverse acc, rest)
  | otherwise = breakSymbolListTx (d - 1) (IC ']' : acc) rest
breakSymbolListTx d acc (IC '[' : rest) =
  breakSymbolListTx (d + 1) (IC '[' : acc) rest
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
indexedSuffixTx (IC m : II nm : rest)
  | m == '~' || m == '_' =
      case parseMarkedPrefix (m : nm) of
        Just (parts, suffixRest) | null suffixRest ->
          let (more, rest') = indexedSuffixTx rest
          in (parts ++ more, rest')
        _ -> ([], IC m : II nm : rest)
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

-- Expand operator applications on the TensorExpr AST. Bodies are def-free
-- after resolution, so one pass over the parsed tree suffices; arguments are
-- expanded before substitution.
expandDefs :: [Def] -> String -> IO String
expandDefs defs s = renderTensorExpr <$> expandDefsAst defs s

expandDefsAst :: [Def] -> String -> IO TensorExpr
expandDefsAst defs s = do
  ast <- parseTensorExprIO "bad tensor expression" s
  expandDefExpr defs ast

expandDefExpr :: [Def] -> TensorExpr -> IO TensorExpr
expandDefExpr defs expr =
  case expr of
    TENumber _ -> return expr
    TEIdent nm [] | Just df <- lookupDef nm defs, null (defParams df) ->
      applyDefAst defs df []
    TEIdent _ _ -> return expr
    TEUnary op body ->
      keepSpan (TEUnary op <$> expand body)
    TECall f args ->
      keepSpan (TECall <$> expand f <*> mapM expand args)
    TEApply (TEIdent nm []) args
      | Just df <- lookupDef nm defs -> do
          args' <- mapM expand args
          let n = length (defParams df)
          if length args' < n
            then fatal ("operator " ++ defName df ++ " needs "
                        ++ show n ++ " argument(s)")
            else return ()
          let (used, rest) = splitAt n args'
          body <- applyDefAst defs df used
          if null rest
            then return (setTensorSpan (tensorExprSpan expr) body)
            else keepSpan (return (TEApply body rest))
    TEApply f args ->
      keepSpan (TEApply <$> expand f <*> mapM expand args)
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
    TEDerivative parts body ->
      keepSpan (TEDerivative parts <$> expand body)
    TEDot parts
      | Just dotDef <- lookupDef "." defs -> do
          parts' <- mapM expand parts
          body <- expandDotAst defs dotDef parts'
          return (setTensorSpan (tensorExprSpan expr) body)
      | otherwise ->
          keepSpan (TEDot <$> mapM expand parts)
    TEBinary op lhs rhs ->
      keepSpan (TEBinary op <$> expand lhs <*> expand rhs)
    TEGroup body ->
      keepSpan (TEGroup <$> expand body)
  where
    expand = expandDefExpr defs
    keepSpan action = setTensorSpan (tensorExprSpan expr) <$> action

lookupDef :: String -> [Def] -> Maybe Def
lookupDef nm defs =
  case [df | df <- defs, defName df == nm] of
    df:_ -> Just df
    [] -> Nothing

expandDotAst :: [Def] -> Def -> [TensorExpr] -> IO TensorExpr
expandDotAst _ _ [] = return (TENumber "1")
expandDotAst _ _ [p] = return p
expandDotAst defs dotDef (p:ps) =
  foldM (\lhs rhs -> applyDefAst defs dotDef [lhs, rhs]) p ps

applyDefAst :: [Def] -> Def -> [TensorExpr] -> IO TensorExpr
applyDefAst _ df args = do
  ast <- parseTensorExprIO ("in def " ++ defName df) (defBody df)
  let env = zip (defParams df) (map argInfo args)
  substExpr df env ast

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
    keepSpan action = setTensorSpan (tensorExprSpan expr) <$> action

argWithPrimes :: ArgInfo -> Int -> TensorExpr
argWithPrimes (_, Just (base, primes0, parts)) primes =
  TEIdent (base ++ replicate (primes0 + primes) '\'') parts
argWithPrimes (arg, Nothing) primes
  | primes == 0 = arg
  | otherwise =
      TEApply (TEIdent (renderTensorAtom arg ++ replicate primes '\'') []) []

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
argWithParts _ (_, Just (base, primes0, _)) primes parts =
  return (TEIdent (base ++ replicate (primes0 + primes) '\'') parts)
argWithParts _ (arg, Nothing) primes parts =
  return (appendPartsWithPrimes arg primes parts)

argWithAppendParts :: ArgInfo -> Int -> [IxPart] -> [IxPart] -> TensorExpr
argWithAppendParts (_, Just (base, primes0, argParts)) primes parts appendParts =
  let keptParts = if null parts then argParts else parts
  in TEIdent (base ++ replicate (primes0 + primes) '\'') (keptParts ++ appendParts)
argWithAppendParts (arg, Nothing) primes parts appendParts =
  appendPartsWithPrimes arg primes (parts ++ appendParts)

appendPartsWithPrimes :: TensorExpr -> Int -> [IxPart] -> TensorExpr
appendPartsWithPrimes arg primes parts =
  let arg' = if primes == 0
               then arg
               else TEApply (TEIdent (renderTensorAtom arg ++ replicate primes '\'') []) []
  in TEAppendIndexed arg' parts

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
    keep = setTensorSpan (tensorExprSpan expr)
    renameParts =
      map (\p@(IxPart _ nm) ->
             case lookup nm aliases of
               Just p' -> p'
               Nothing -> p)

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

-- Expand one component.  Indexed derivatives applied to staggered field
-- components use half-cell differences anchored at the target component
-- placement (Virieux/Yee); symmetric components are canonicalized.
ixExpand :: Model -> [String] -> [(String, Int)] -> Placement -> String -> IO String
ixExpand m lets env anchor expr = do
  parsedExpr <- parseTensorExprIO "bad tensor expression" expr
  expandAst env parsedExpr
  where
    euclideanDeclaredMetric =
      mMetricName m /= Nothing && mMetric m == Nothing && mEmbed m == Nothing

    metricIdent (base, parts) =
      case mMetricName m of
        Just metricNm | base == metricNm -> Just (metricNm, parts)
        _ -> Nothing

    isMixedPair (IxPart VUp _) (IxPart VDown _) = True
    isMixedPair (IxPart VDown _) (IxPart VUp _) = True
    isMixedPair _ _ = False

    indexedMetricPart (IxPart _ nm) = all isAlphaNum nm && not (null nm)

    metricRef (IxPart v1 _) (IxPart v2 _) a b
      | euclideanDeclaredMetric = if a == b then "1" else "0"
      | otherwise = metricInternalBase v1 v2 ++ "_" ++ show a ++ "_" ++ show b

    expandAst env' ast =
      case ast of
        TENumber s -> return s
        TEBinary "+" lhs rhs -> do
          e1 <- expandAst env' lhs
          e2 <- expandAst env' rhs
          return (joinAddPretty '+' e1 e2)
        TEBinary "-" lhs rhs -> do
          e1 <- expandAst env' lhs
          e2 <- expandAst env' rhs
          return (joinAddPretty '-' e1 e2)
        TEBinary "*" lhs rhs
          | zeroByIdentityAst env' lhs || zeroByIdentityAst env' rhs ->
              return "0"
          | otherwise -> do
              e1 <- expandAst env' lhs
              e2 <- expandAst env' rhs
              return (e1 ++ " * " ++ e2)
        TEBinary "/" lhs rhs -> do
          e1 <- expandAst env' lhs
          e2 <- expandAst env' rhs
          return (e1 ++ " / " ++ e2)
        TEBinary op lhs rhs -> do
          e1 <- expandAst env' lhs
          e2 <- expandAst env' rhs
          return (e1 ++ " " ++ op ++ " " ++ e2)
        TEUnary "+" body ->
          expandAst env' body
        TEUnary "-" body -> do
          e <- expandAst env' body
          return ("0 - " ++ operandExpr e)
        TEUnary op body -> do
          e <- expandAst env' body
          return (op ++ operandExpr e)
        TECall f args -> do
          fn <- expandAst env' f
          as <- mapM (expandAst env') args
          return (fn ++ "(" ++ intercalate ", " as ++ ")")
        TEApply f args ->
          case (f, args) of
            (TEIdent fn fnParts, [arg])
              | Just (ordr, radius, part) <- derivativeOpParts (fn ++ concatMap ixSuffix fnParts) ->
                  expandCoordinateIndexDerivativeAst env' ordr radius part arg
            (TEIdent fn fnParts, _)
              | Just _ <- derivativeOpParts (fn ++ concatMap ixSuffix fnParts) ->
                  fatal ("coordinate derivative takes one operand: " ++ expr)
            _ -> do
              fn <- expandAst env' f
              as <- mapM (expandAst env') args
              return (unwords (fn : map renderApplyText as))
        TEIf c t e -> do
          c' <- expandAst env' c
          t' <- expandAst env' t
          e' <- expandAst env' e
          return ("if " ++ c' ++ " then " ++ t' ++ " else " ++ e')
        TEWithSymbols names body ->
          expandWithSymbolsAst env' names body
        TEContractWith reducer body ->
          expandContractAst env' reducer body
        TEDot parts ->
          expandContractAst env' "+" (dotAsProduct parts)
        TEDerivative parts body ->
          expandDerivativeAst env' parts body
        TEIdent base parts ->
          resolveIdentAst env' base parts
        TEAppendIndexed e parts ->
          expandAst env' (appendIndexedAst e parts)
        TEGroup e -> do
          body <- expandAst env' e
          return ("(" ++ body ++ ")")

    dotAsProduct [] = TENumber "1"
    dotAsProduct [p] = p
    dotAsProduct (p:ps) = foldl (TEBinary "*") p ps

    appendIndexedAst (TEIdent base parts0) parts =
      TEIdent base (parts0 ++ parts)
    appendIndexedAst (TEGroup e) parts =
      appendIndexedAst e parts
    appendIndexedAst e parts =
      TEAppendIndexed e parts

    expandWithSymbolsAst env' names body =
      let vals = map snd env'
          localEnv = zip names vals
          envNoShadow = [(k, v) | (k, v) <- env', k `notElem` names]
      in expandAst (localEnv ++ envNoShadow) body

    expandContractAst env' reducer body0 = do
      let body = stripGroupAst body0
      dummies <- contractDummyNames env' body
      case dummies of
        k:_ -> do
          parts <- mapM (\n -> expandContractAst ((k, n) : env') reducer body) (axisRange m)
          return (foldReducerText reducer parts)
        [] | zeroByIdentityAst env' body -> return "0"
           | otherwise -> expandAst env' body

    contractDummyNames env' body = do
      ete <- elaborateTensorExpr m lets [] body
      return (nub [diagName d | d <- tiDiagIx (eteInfo ete)
                              , lookup (diagName d) env' == Nothing])

    expandDerivativeAst env' parts body = do
      let (parts', body') = flattenDerivative parts body
          label =
            case parts' of
              k0:_ -> "d_" ++ ixName k0
              [] -> "indexed derivative"
      ns <- mapM (need env' . ixName) parts'
      ref <- requireDerivativeOperandAst env' label body'
      let (e, _) = deriveChain ns anchor ref
      return e

    expandCoordinateIndexDerivativeAst env' ordr radius part body = do
      let label = "pd" ++ show ordr ++ "r" ++ show radius ++ ixSuffix part
      (n, isCoord) <- derivativeAxis env' part
      if isCoord
        then do
          mref <- derivativeOperandAst env' body
          case mref of
            Just ref -> do
              (e, _) <- deriveCoordinateDerivative True ordr radius n anchor ref
              return e
            Nothing -> do
              e <- expandAst env' body
              return ("∂ " ++ show ordr ++ " " ++ show radius ++ " "
                      ++ axisSymbol n ++ " " ++ operandExpr e)
        else do
          ref <- requireDerivativeOperandAst env' label body
          (e, _) <- deriveCoordinateDerivative False ordr radius n anchor ref
          return e

    derivativeAxis env' (IxPart _ nm) =
      case lookup nm (zip (internalCoordNames m) (axisRange m)) of
        Just n -> return (n, True)
        Nothing -> do
          n <- need env' nm
          return (n, False)

    requireDerivativeOperandAst env' label body = do
      mref <- derivativeOperandAst env' body
      case mref of
        Just ref -> return ref
        Nothing -> fatal (label ++ " needs a field operand: " ++ expr)

    derivativeOperandAst env' (TEIdent base parts)
      | isFieldOperand base parts =
          Just <$> fieldRefParts env' base parts
      | otherwise =
          return Nothing
    derivativeOperandAst env' (TEGroup e) =
      derivativeOperandAst env' e
    derivativeOperandAst env' (TEAppendIndexed e parts) =
      derivativeOperandAst env' (appendIndexedAst e parts)
    derivativeOperandAst _ _ =
      return Nothing

    isFieldOperand base0 parts =
      let (fname, _) = fieldBaseOf base0
      in case kindOf m fname of
           Just Scalar -> null parts
           Just _ -> not (null parts)
           Nothing -> fname `elem` lets && not (null parts)

    resolveIdentAst env' base0 parts =
      let w = base0 ++ concatMap ixSuffix parts
          splitIdentW = (base0, parts)
      in case () of
           _
             | Just (_, [p, q]) <- metricIdent splitIdentW
             , indexedMetricPart p, indexedMetricPart q -> do
                 pv <- need env' (ixName p)
                 qv <- need env' (ixName q)
                 return (metricRef p q pv qv)
             | ("epsilon", [p, q, r]) <- splitIdentW
             , all isSingleAlphaIx [p, q, r] -> do
                 if mDim m /= 3
                   then fatal ("epsilon currently requires dimension 3: " ++ w)
                   else return ()
                 vals <- mapM (need env' . ixName) [p, q, r]
                 return (show (leviCivita3 vals))
             | ("delta", [p, q]) <- splitIdentW
             , all indexedMetricPart [p, q] -> do
                 if not (isMixedPair p q)
                   then fatal ("Kronecker delta indices must be mixed, e.g. delta~i_j; use metric g and g~i~j/g_i_j for metric components: " ++ w)
                   else return ()
                 pv <- need env' (ixName p)
                 qv <- need env' (ixName q)
                 return (if pv == qv then "1" else "0")
             | ("delta", _ : _) <- splitIdentW ->
                 fatal ("Kronecker delta takes two marked indices, e.g. delta~i_j or delta_i~1: " ++ w)
             | ("epsilon", _ : _) <- splitIdentW ->
                 fatal ("epsilon takes three single marked indices, e.g. epsilon~i~j~k: " ++ w)
             | ("d", _ : _) <- splitIdentW ->
                 fatal ("indexed derivative needs a field operand: " ++ expr)
             | isFieldRef splitIdentW -> do
                 ref <- fieldRefParts env' base0 parts
                 return (fst ref)
             | Just (metricNm, _ : _) <- metricIdent splitIdentW ->
                 fatal ("metric tensor " ++ metricNm ++ " needs exactly two marked indices: " ++ w
                        ++ " (examples: " ++ metricNm ++ "~i~j, " ++ metricNm ++ "~i_j, "
                        ++ metricNm ++ "_i~j, " ++ metricNm ++ "_i_j)")
             | not (null parts) ->
                 fatal ("unknown indexed tensor: " ++ w
                        ++ " (declare metric " ++ base0
                        ++ " to use it as the metric tensor)")
             | otherwise ->
                 return w

    isFieldRef (base0, parts) =
      (kindOf m (fst (fieldBaseOf base0)) /= Nothing
       || fst (fieldBaseOf base0) `elem` lets)
      && not (null parts)

    fieldRefParts env' base0 parts = do
      let w = base0 ++ concatMap ixSuffix parts
          (fname, primes) = fieldBaseOf base0
      validateFieldRefParts m lets w
      ns <- mapM (need env' . ixName) parts
      case (kindOf m fname, ns) of
        (Just (Vector staggered), [a]) ->
          return (fname ++ replicate primes '\'' ++ "_" ++ show a,
                  if staggered then placeVB m a else zeroPlaceB m)
        (Just (Form _), [a]) ->
          return (fname ++ replicate primes '\'' ++ "_" ++ show a,
                  zeroPlaceB m)
        (Just SymM, [a, b2]) ->
          let (lo, hi) = (min a b2, max a b2)
          in return (fname ++ replicate primes '\'' ++ "_" ++ show lo ++ "_" ++ show hi,
                     placeSB m a b2)
        (Just AntiM, [a, b2]) ->
          let (lo, hi) = (min a b2, max a b2)
              comp = fname ++ replicate primes '\'' ++ "_" ++ show lo ++ "_" ++ show hi
              signed | a == b2 = "0"
                     | a < b2 = comp
                     | otherwise = "(0 - " ++ comp ++ ")"
          in return (signed, placeSB m a b2)
        (Just (Tensor2 staggered), [a, b2]) ->
          return (fname ++ replicate primes '\'' ++ "_" ++ show a ++ "_" ++ show b2,
                  if staggered then placeSB m a b2 else zeroPlaceB m)
        (Just Scalar, []) ->
          return (fname ++ replicate primes '\'', zeroPlaceB m)
        (Nothing, [a]) | fname `elem` lets, primes == 0 ->
          return (fname ++ "_" ++ show a, zeroPlaceB m)
        _ -> fatal ("bad field reference in index equation: " ++ w)

    zeroByIdentityAst env' ast =
      case ast of
        TEIdent base parts -> zeroIdent base parts
        TEAppendIndexed e parts -> zeroByIdentityAst env' (appendIndexedAst e parts)
        TEUnary _ body -> zeroByIdentityAst env' body
        TECall f args -> zeroByIdentityAst env' f || any (zeroByIdentityAst env') args
        TEApply f args -> zeroByIdentityAst env' f || any (zeroByIdentityAst env') args
        TEBinary "*" lhs rhs ->
          zeroByIdentityAst env' lhs || zeroByIdentityAst env' rhs
        TEGroup e -> zeroByIdentityAst env' e
        _ -> False
      where
        resolvedDifferent p q =
          case (resolveIx env' (ixName p), resolveIx env' (ixName q)) of
            (Just pv, Just qv) -> pv /= qv
            _ -> False
        zeroIdent base parts =
          case (base, parts) of
            ("delta", [p, q])
              | all indexedMetricPart [p, q], isMixedPair p q ->
                  resolvedDifferent p q
            _
              | euclideanDeclaredMetric
              , Just _ <- metricIdent (base, parts)
              , [p, q] <- parts
              , indexedMetricPart p
              , indexedMetricPart q ->
                  resolvedDifferent p q
              | otherwise -> False

    sumText parts =
      case filter (/= "0") (map dropOneFactor parts) of
        [] -> "0"
        [p] -> p
        ps -> "(" ++ intercalate " + " ps ++ ")"

    foldReducerText reducer parts =
      case reducer of
        "+" -> sumText parts
        "*" -> productText parts
        _ -> foldFunctionText reducer parts

    productText parts =
      case parts of
        [] -> "1"
        [p] -> p
        ps -> "(" ++ intercalate " * " ps ++ ")"

    foldFunctionText reducer parts =
      case parts of
        [] -> reducer ++ "()"
        [p] -> p
        p:ps -> foldl (\acc q -> reducer ++ "(" ++ acc ++ ", " ++ q ++ ")") p ps

    joinAddPretty op e1 e2
      | null (strip e1) = [op] ++ e2
      | op == '+' && isZeroText e1 = e2
      | op == '+' && isZeroText e2 = e1
      | op == '-' && isZeroText e2 = e1
      | otherwise = e1 ++ " " ++ [op] ++ " " ++ e2

    isZeroText s =
      case strip s of
        "0" -> True
        "(0)" -> True
        _ -> False

    dropOneFactor s =
      case stripPrefix "1 * " s of
        Just rest -> rest
        Nothing -> s

    resolveIx env' pt
      | all isDigit pt = Just (read pt)
      | otherwise = lookup pt env'

    need env' l = case resolveIx env' l of
      Just n -> return n
      Nothing -> fatal ("unresolved index '" ++ l ++ "' in: " ++ expr)

    deriveChain [] _ _ = error "empty derivative chain"
    deriveChain [n1, n2] target ref@(_, src)
      | n1 == n2 && target == src =
          ("∂ 2 1 " ++ axisSymbol n1 ++ " " ++ operandExpr (fst ref), target)
    deriveChain [n] target ref =
      let e = derivAt n target ref
      in (e, target)
    deriveChain (n:ns) target ref =
      let innerTarget = naturalPlace ns (snd ref)
          innerRef = deriveChain ns innerTarget ref
          e = derivAt n target innerRef
      in (e, target)

    deriveCoordinateDerivative isCoord ordr radius n target ref@(_, src)
      | ordr < 1 =
          return (error "coordinate derivative order must be positive")
      | radius < 1 =
          return (error "coordinate derivative radius must be positive")
      | isCoord && target == src =
          return ("∂ " ++ show ordr ++ " " ++ show radius ++ " "
                  ++ axisSymbol n ++ " " ++ operandExpr (fst ref), target)
      | radius == 1 =
          return (deriveChain (replicate ordr n) target ref)
      | target == src =
          return ("∂ " ++ show ordr ++ " " ++ show radius ++ " "
                  ++ axisSymbol n ++ " " ++ operandExpr (fst ref), target)
      | otherwise =
          fatal ("higher-radius indexed derivative requires a colocated field operand: " ++ expr)

    naturalPlace ns src = foldl (flip togglePlace) src ns

    derivAt n target (comp, place) =
      "dYee " ++ show n ++ " " ++ placeText target
      ++ " (" ++ comp ++ ", " ++ placeText place ++ ")"

    axisSymbol n =
      case drop (n - 1) (internalCoordNames m) of
        a:_ -> a
        [] -> "x"

    operandExpr e
      | all (\c -> isAlphaNum c || c == '_' || c == '\'') e = e
      | parenthesized e = e
      | otherwise = "(" ++ e ++ ")"

    parenthesized s =
      case strip s of
        t@('(':_) | last t == ')' -> closesAtEnd 0 t
        _ -> False

    closesAtEnd :: Int -> String -> Bool
    closesAtEnd 1 [')'] = True
    closesAtEnd depth (c:cs) =
      let depth' =
            case c of
              '(' -> depth + 1
              ')' -> depth - 1
              _ -> depth
      in depth' > 0 && closesAtEnd depth' cs
    closesAtEnd _ [] = False

    renderApplyText e
      | all (\c -> isAlphaNum c || c == '_' || c == '\'' || c == '.' || c == '~') e = e
      | otherwise = "(" ++ e ++ ")"

expandTensorDefs :: Model -> String -> IO String
expandTensorDefs m = go . itok
  where
    go [] = return ""
    go (II nm : rest)
      | Just td <- lookupTensorDef nm = do
          let (_, rest1) = span isSpaceI rest
          case rest1 of
            II argTok : rest2 -> do
              body <- instantiate td argTok
              body' <- expandTensorDefs m body
              tail' <- go rest2
              return ("(" ++ body' ++ ")" ++ tail')
            _ -> fatal ("tensor operator " ++ nm ++ " needs an indexed result argument")
      | otherwise = fmap (nm ++) (go rest)
    go (IC c : rest) = fmap (c :) (go rest)

    lookupTensorDef nm =
      case [td | td <- mTensorDefs m, tdName td == nm] of
        td:_ -> Just td
        [] -> Nothing

    instantiate td argTok = do
      let (argBase, callIx) = parseIndexedIdent argTok
          resultIx = tdResultIx td
      if null argBase
        then fatal ("bad argument to tensor operator " ++ tdName td ++ ": " ++ argTok)
        else return ()
      if length callIx /= length resultIx
        then fatal ("tensor operator " ++ tdName td ++ " expects result suffix "
                    ++ showIxParts resultIx ++ " but got " ++ argTok)
        else return ()
      mapM_ (uncurry sameVariance) (zip resultIx callIx)
      let env = zip (map ixName resultIx) callIx
      return (concatMap (substTok td argBase env) (itok (tdBody td)))

    sameVariance (IxPart v1 _) (IxPart v2 _)
      | v1 == v2 = return ()
      | otherwise = fatal "tensor operator result index variance mismatch"

    substTok _ _ _ (IC c) = [c]
    substTok td argBase env (II w) =
      let (base, parts) = parseIndexedIdent w
          (fname, primes) = fieldBaseOf base
          base' = if fname == tdParam td
                    then argBase ++ replicate primes '\''
                    else base
          parts' = map (substIx env) parts
      in base' ++ concatMap ixSuffix parts'

    substIx env (IxPart v nm) =
      case lookup nm env of
        Just (IxPart _ nm') -> IxPart v nm'
        Nothing -> IxPart v nm

    isSpaceI (IC c) = isSpace c
    isSpaceI _ = False
