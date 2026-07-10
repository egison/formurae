module Formurae.TensorExpr
  ( TensorExpr(..)
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

data TensorExpr
  = TENumber String
  | TEIdent String [IxPart]
  | TEUnary String TensorExpr
  | TECall TensorExpr [TensorExpr]
  | TEApply TensorExpr [TensorExpr]
  | TEIf TensorExpr TensorExpr TensorExpr
  | TEAppendIndexed TensorExpr [IxPart]
  | TEWithSymbols [String] TensorExpr
  | TEContractWith String TensorExpr
  | TEDerivative [IxPart] TensorExpr
  | TEDot [TensorExpr]
  | TEBinary String TensorExpr TensorExpr
  | TEGroup TensorExpr
  deriving (Eq, Show)

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
         | fieldDeclOf m base /= Nothing && not (null parts) -> do
             validateFieldRefParts m lets w
             return parts
         | base `elem` lets && not (null parts) ->
             return parts
         | Just metricNm <- mMetricName m
         , base == metricNm
         , not (null parts) ->
             metricIdentOccurrences metricNm parts w
         | otherwise ->
             return []

metricIdentOccurrences :: String -> [IxPart] -> String -> IO [IxPart]
metricIdentOccurrences metricNm parts w =
  if length parts == 2 && all isIndexedMetricPart parts
    then return parts
    else fatal ("metric tensor " ++ metricNm ++ " needs exactly two marked indices: " ++ w)

kroneckerIdentOccurrences :: [IxPart] -> String -> IO [IxPart]
kroneckerIdentOccurrences [p, q] w
  | all isSingleAlphaIx [p, q] =
      if isMixedIxPair p q
        then return [p, q]
        else fatal ("Kronecker delta indices must be mixed, e.g. delta~i_j; use metric g and g~i~j/g_i_j for metric components: " ++ w)
kroneckerIdentOccurrences _ w =
  fatal ("Kronecker delta takes two single marked indices, e.g. delta~i_j: " ++ w)

derivativeIdentOccurrences :: [IxPart] -> String -> IO [IxPart]
derivativeIdentOccurrences [p] _ = return [p]
derivativeIdentOccurrences _ w =
  fatal ("indexed derivative takes one marked index, e.g. d_i or d~i: " ++ w)

isIndexedMetricPart :: IxPart -> Bool
isIndexedMetricPart (IxPart _ nm) = all isAlphaNum nm && not (null nm)

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
  in case parseIfExprE src ts of
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
    II e : _ | e == "e" || e == "E" -> False
    _ -> True

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

-- Expand operator applications.  Bodies are def-free after resolution,
-- so one pass suffices; arguments are expanded first.
expandDefs :: [Def] -> String -> IO String
expandDefs defs s = fmap untok (goE (tokenize s))
  where
    goE ts
      | Just (lhs, op, rhs) <- splitTopAddT ts = do
          lhs' <- goE lhs
          rhs' <- goE rhs
          return (lhs' ++ [TC ' ', TC op, TC ' '] ++ rhs')
    goE ts
      | Just dotDef <- lookupDef "." defs
      , Just parts <- splitTopDotT ts =
          fmap tokenize (expandDot dotDef parts)
    goE [] = return []
    goE (TId nm False : ts)
      | Just df <- lookupDef nm defs = do
          (args, rest') <- parseArgs (length (defParams df)) ts
          args' <- mapM (fmap untok . goE . tokenize) args
          body <- substDef df args'
          let bodyT = tokenize body
          fmap ((TC '(' : bodyT ++ [TC ')']) ++) (goE rest')
    goE (TC '(' : ts) =
      case closeParenT 1 ts [] of
        Just (inner, rest) -> do
          inner' <- goE inner
          rest' <- goE rest
          return (TC '(' : inner' ++ TC ')' : rest')
        Nothing -> fatal ("unbalanced parenthesized expression in: " ++ s)
    goE (TC '[' : ts) =
      case closeBracketT 1 ts [] of
        Just (inner, rest) -> do
          inner' <- goE inner
          rest' <- goE rest
          return (TC '[' : inner' ++ TC ']' : rest')
        Nothing -> fatal ("unbalanced bracketed expression in: " ++ s)
    goE (t : ts) = fmap (t :) (goE ts)

    lookupDef nm defs' =
      case [df | df <- defs', defName df == nm] of
        df:_ -> Just df
        [] -> Nothing

    splitTopAddT ts = goA (0 :: Int) [] ts
      where
        goA _ _ [] = Nothing
        goA d acc (t@(TC c) : rest)
          | c `elem` "([" = goA (d + 1) (t : acc) rest
          | c `elem` ")]" = goA (d - 1) (t : acc) rest
          | d == 0
          , c `elem` "+-"
          , binaryAddOp acc =
              Just (trimTok (reverse acc), c, trimTok rest)
        goA d acc (t : rest) = goA d (t : acc) rest

    binaryAddOp acc =
      case dropWhile isSpTok acc of
        [] -> False
        TC p : _ | p `elem` "([,+-*/^=" -> False
        TId e False : _ | e == "e" || e == "E" -> False
        _ -> True

    expandDot _ [] = return ""
    expandDot dotDef (p:ps) = do
      first <- fmap untok (goE p)
      foldM (dotApply dotDef) first ps

    dotApply dotDef lhs rhsT = do
      rhs <- fmap untok (goE rhsT)
      body <- substDef dotDef [lhs, rhs]
      return ("(" ++ body ++ ")")

    splitTopDotT ts =
      case goD (0 :: Int) [] ts of
        [_] -> Nothing
        parts -> Just parts
      where
        goD _ acc [] = [trimTok (reverse acc)]
        goD d acc (t@(TC c) : rest)
          | c `elem` "([" = goD (d + 1) (t : acc) rest
          | c `elem` ")]" = goD (d - 1) (t : acc) rest
          | d == 0
          , c == '.'
          , leftSpaceT acc
          , rightSpaceT rest =
              trimTok (reverse acc) : goD d [] rest
        goD d acc (t : rest) = goD d (t : acc) rest

    leftSpaceT (TC c : _) = isSpace c
    leftSpaceT _ = False

    rightSpaceT (TC c : _) = isSpace c
    rightSpaceT _ = False

    trimTok = dropWhile isSpTok . reverse . dropWhile isSpTok . reverse . dropWhile isSpTok

    parseArgs 0 ts = return ([], ts)
    parseArgs n ts = do
      let rest = dropWhile isSpTok ts
      (arg, rest') <- parseArg rest
      (args, rest'') <- parseArgs (n - 1) rest'
      return (arg : args, rest'')

    parseArg (TC '(' : r) =
      case closeParenT 1 r [] of
        Just (inner, r') ->
          let (suffix, r'') = indexedSuffixT r'
          in return ("(" ++ untok inner ++ ")" ++ suffix, r'')
        Nothing -> fatal ("unbalanced argument to operator in: " ++ s)
    parseArg (TId a pr : r) =
      let (suffix, r') = indexedSuffixT r
      in return (a ++ (if pr then "'" else "") ++ suffix, r')
    parseArg _ = fatal ("operator application needs an argument in: " ++ s)

    closeBracketT :: Int -> [Tok] -> [Tok] -> Maybe ([Tok], [Tok])
    closeBracketT _ [] _ = Nothing
    closeBracketT n (TC '[' : ts) acc = closeBracketT (n + 1) ts (TC '[' : acc)
    closeBracketT n (TC ']' : ts) acc
      | n == 1 = Just (reverse acc, ts)
      | otherwise = closeBracketT (n - 1) ts (TC ']' : acc)
    closeBracketT n (t : ts) acc = closeBracketT n ts (t : acc)

    indexedSuffixT (TC m : TId ix False : rest)
      | m == '~' || m == '_' =
          let (more, rest') = indexedSuffixT rest
          in (m : ix ++ more, rest')
    indexedSuffixT ts = ("", ts)

    substDef df args = do
      ast <- parseTensorExprIO ("in def " ++ defName df) (defBody df)
      let env = zip (defParams df) (map parseArgInfo args)
      ast' <- substExpr df env ast
      return (renderTensorExpr ast')

    substExpr df env expr =
      case expr of
        TENumber _ -> return expr
        TEIdent base0 parts ->
          let (base, primes) = fieldBaseOf base0
          in case lookup base env of
               Just arg | null parts -> parseSubst df (argWithPrimes arg primes)
                        | otherwise -> parseSubst df (argWithParts arg primes parts)
               Nothing -> return expr
        TEUnary op body -> TEUnary op <$> substExpr df env body
        TECall f args -> TECall <$> substExpr df env f <*> mapM (substExpr df env) args
        TEApply f args -> TEApply <$> substExpr df env f <*> mapM (substExpr df env) args
        TEIf c t e -> TEIf <$> substExpr df env c <*> substExpr df env t <*> substExpr df env e
        TEAppendIndexed (TEIdent base0 parts) appendParts ->
          let (base, primes) = fieldBaseOf base0
          in case lookup base env of
               Just arg -> parseSubst df (argWithAppendParts arg primes parts appendParts)
               Nothing -> return (TEAppendIndexed (TEIdent base0 parts) appendParts)
        TEAppendIndexed e parts -> TEAppendIndexed <$> substExpr df env e <*> pure parts
        TEWithSymbols names body -> TEWithSymbols names <$> substExpr df env body
        TEContractWith reducer body -> TEContractWith reducer <$> substExpr df env body
        TEDerivative parts body -> TEDerivative parts <$> substExpr df env body
        TEDot parts -> TEDot <$> mapM (substExpr df env) parts
        TEBinary op lhs rhs -> TEBinary op <$> substExpr df env lhs <*> substExpr df env rhs
        TEGroup e -> TEGroup <$> substExpr df env e

    parseSubst df srcText =
      parseTensorExprIO ("while substituting def " ++ defName df) srcText

    parseArgInfo arg =
      let sArg = strip arg
          simple = all (\c -> isAlphaNum c || c `elem` "_~'") sArg
          (base0, parts) = parseIndexedIdent sArg
          (base, primes) = fieldBaseOf base0
      in (sArg, simple, base, primes, parts)

    argWithPrimes (arg, simple, base, primes0, parts) primes
      | simple = base ++ replicate (primes0 + primes) '\'' ++ concatMap ixSuffix parts
      | primes == 0 = arg
      | otherwise = "(" ++ arg ++ ")" ++ replicate primes '\''

    argWithParts (arg, simple, base, primes0, _) primes parts
      | Just body <- reindexWithSymbols arg parts =
          if primes == 0 then body else "(" ++ body ++ ")" ++ replicate primes '\''
      | simple = base ++ replicate (primes0 + primes) '\'' ++ concatMap ixSuffix parts
      | otherwise = "(" ++ arg ++ ")" ++ concatMap ixSuffix parts

    argWithAppendParts (arg, simple, base, primes0, argParts) primes parts appendParts =
      let keptParts = if null parts then argParts else parts
      in if simple
           then base ++ replicate (primes0 + primes) '\''
                ++ concatMap ixSuffix (keptParts ++ appendParts)
           else "(" ++ arg ++ ")" ++ concatMap ixSuffix (keptParts ++ appendParts)

    reindexWithSymbols arg parts = do
      (names, body) <- parseWithSymbolsArg (stripOuterParensI (itok arg))
      if length names == length parts
        then Just (untokI (map (renameLocalIx (zip names parts)) body))
        else Nothing

    parseWithSymbolsArg ts =
      case dropWhile isSpaceI ts of
        II "withSymbols" : rest -> parseSymbolListI (dropWhile isSpaceI rest)
        _ -> Nothing

    parseSymbolListI (IC '[' : rest) =
      case breakSymbolListI (0 :: Int) [] rest of
        Just (inside, rest1) -> Just (symbolNamesI inside, dropWhile isSpaceI rest1)
        Nothing -> Nothing
    parseSymbolListI _ = Nothing

    breakSymbolListI _ _ [] = Nothing
    breakSymbolListI d acc (IC ']' : rest)
      | d == 0 = Just (reverse acc, rest)
      | otherwise = breakSymbolListI (d - 1) (IC ']' : acc) rest
    breakSymbolListI d acc (IC '[' : rest) =
      breakSymbolListI (d + 1) (IC '[' : acc) rest
    breakSymbolListI d acc (t : rest) = breakSymbolListI d (t : acc) rest

    symbolNamesI = collectSymbolNames
      where
        collectSymbolNames [] = []
        collectSymbolNames (II nm : rest)
          | validSurfaceName nm = nm : collectSymbolNames rest
        collectSymbolNames (_ : rest) = collectSymbolNames rest

    renameLocalIx aliases (II w) =
      let (base0, parts0) = parseIndexedIdent w
          parts1 = map renamePart parts0
      in II (base0 ++ concatMap ixSuffix parts1)
      where
        renamePart p@(IxPart _ nm) =
          case lookup nm aliases of
            Just p' -> p'
            Nothing -> p
    renameLocalIx _ tok = tok

    stripOuterParensI ts =
      case trimIToksLocal ts of
        IC '(' : rest ->
          case closeOuterI (0 :: Int) [] rest of
            Just (inner, rest') | all isSpaceI rest' -> stripOuterParensI inner
            _ -> trimIToksLocal ts
        trimmed -> trimmed

    closeOuterI _ _ [] = Nothing
    closeOuterI d acc (IC ')' : rest)
      | d == 0 = Just (reverse acc, rest)
      | otherwise = closeOuterI (d - 1) (IC ')' : acc) rest
    closeOuterI d acc (IC '(' : rest) =
      closeOuterI (d + 1) (IC '(' : acc) rest
    closeOuterI d acc (t : rest) = closeOuterI d (t : acc) rest

    trimIToksLocal = dropWhile isSpaceI . reverse . dropWhile isSpaceI . reverse . dropWhile isSpaceI

    untokI = concatMap outI
      where
        outI (II w) = w
        outI (IC c) = [c]

    isSpaceI (IC c) = isSpace c
    isSpaceI _ = False

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
        TEApply f args -> do
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

    stripGroupAst (TEGroup e) = stripGroupAst e
    stripGroupAst e = e

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
      ref <- derivativeOperandAst env' label body'
      let (e, _) = deriveChain ns anchor ref
      return e

    derivativeOperandAst env' _ (TEIdent base parts) =
      fieldRefParts env' base parts
    derivativeOperandAst env' label (TEGroup e) =
      derivativeOperandAst env' label e
    derivativeOperandAst env' label (TEAppendIndexed e parts) =
      derivativeOperandAst env' label (appendIndexedAst e parts)
    derivativeOperandAst _ label _ =
      fatal (label ++ " needs a field operand: " ++ expr)

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
             , all isSingleAlphaIx [p, q] -> do
                 if not (isMixedPair p q)
                   then fatal ("Kronecker delta indices must be mixed, e.g. delta~i_j; use metric g and g~i~j/g_i_j for metric components: " ++ w)
                   else return ()
                 pv <- need env' (ixName p)
                 qv <- need env' (ixName q)
                 return (if pv == qv then "1" else "0")
             | ("delta", _ : _) <- splitIdentW ->
                 fatal ("Kronecker delta takes two single marked indices, e.g. delta~i_j: " ++ w)
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
              | all isSingleAlphaIx [p, q], isMixedPair p q ->
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
      | otherwise = "(" ++ e ++ ")"

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
