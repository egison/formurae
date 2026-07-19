{-# LANGUAGE PatternSynonyms #-}

-- | Syntax support for the mathematical surface expressions accepted by
-- pre-fec.  This module deliberately stops at parsing, source spans,
-- coordinate-name preprocessing, and rendering; Egison owns tensor
-- elaboration and symbolic normalization.
module Formurae.TensorExpr
  ( TensorExpr
  , SourceSpan(..)
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
  , pattern TETensorMap
  , pattern TESubrefs
  , pattern TETranspose
  , pattern TEDisjoint
  , pattern TEDerivative
  , pattern TEGridDerivativeChain
  , pattern TETensorLiteral
  , pattern TEDot
  , pattern TEBinary
  , pattern TEGroup
  , parseTensorExpr
  , parseTensorExprEither
  , renderTensorExpr
  , preprocessTensorExpr
  ) where

import Data.Char (isDigit, isSpace)
import Data.List (elemIndex, intercalate)

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
  | TETensorMapNode TensorExpr TensorExpr
  | TESubrefsNode TensorExpr [IxPart]
  | TETransposeNode [String] TensorExpr
  | TEDisjointNode [TensorExpr]
  | TEDerivativeNode [IxPart] TensorExpr
  | TEGridDerivativeChainNode [IxPart] TensorExpr
  | TETensorLiteralNode [TensorExpr] [IxPart]
  | TEDotNode [TensorExpr]
  | TEBinaryNode String TensorExpr TensorExpr
  | TEGroupNode TensorExpr
  deriving (Eq, Show)

-- `tensorMap` is explicit scalar-to-tensor lifting.  `subrefs` and
-- `transpose` operate on the symbolic index sequence before component
-- lowering; `!.` is a disjoint product and never contracts an index pair.

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

pattern TETensorMap :: TensorExpr -> TensorExpr -> TensorExpr
pattern TETensorMap f body <- TensorExpr _ (TETensorMapNode f body)
  where TETensorMap f body = TensorExpr noSourceSpan (TETensorMapNode f body)

pattern TESubrefs :: TensorExpr -> [IxPart] -> TensorExpr
pattern TESubrefs body parts <- TensorExpr _ (TESubrefsNode body parts)
  where TESubrefs body parts = TensorExpr noSourceSpan (TESubrefsNode body parts)

pattern TETranspose :: [String] -> TensorExpr -> TensorExpr
pattern TETranspose names body <- TensorExpr _ (TETransposeNode names body)
  where TETranspose names body = TensorExpr noSourceSpan (TETransposeNode names body)

pattern TEDisjoint :: [TensorExpr] -> TensorExpr
pattern TEDisjoint parts <- TensorExpr _ (TEDisjointNode parts)
  where TEDisjoint parts = TensorExpr noSourceSpan (TEDisjointNode parts)

pattern TEDerivative :: [IxPart] -> TensorExpr -> TensorExpr
pattern TEDerivative parts body <- TensorExpr _ (TEDerivativeNode parts body)
  where TEDerivative parts body = TensorExpr noSourceSpan (TEDerivativeNode parts body)

-- A quoted whole-expression derivative chain.  Axes are stored in
-- application order, innermost first, so @[x, y]@ denotes @G_y(G_x(e))@.
-- Keeping this distinct from 'TEDerivative' prevents analytic
-- differentiation from distributing through the operand.
pattern TEGridDerivativeChain :: [IxPart] -> TensorExpr -> TensorExpr
pattern TEGridDerivativeChain parts body <-
  TensorExpr _ (TEGridDerivativeChainNode parts body)
  where
    TEGridDerivativeChain parts body =
      TensorExpr noSourceSpan (TEGridDerivativeChainNode parts body)

-- An Egison tensor literal keeps its component expressions structured so
-- discrete requests inside a component cannot escape effect analysis or
-- contextualization through the raw-Egison fallback.  The optional suffix
-- is the literal's explicitly marked result-index sequence.
pattern TETensorLiteral :: [TensorExpr] -> [IxPart] -> TensorExpr
pattern TETensorLiteral elements parts <-
  TensorExpr _ (TETensorLiteralNode elements parts)
  where
    TETensorLiteral elements parts =
      TensorExpr noSourceSpan (TETensorLiteralNode elements parts)

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
             TEAppendIndexed, TEWithSymbols, TEContractWith, TETensorMap,
             TESubrefs, TETranspose, TEDisjoint, TEDerivative,
             TEGridDerivativeChain, TETensorLiteral, TEDot, TEBinary,
             TEGroup #-}

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
renderTensorExpr (TEGridDerivativeChain parts body) =
  renderGridDerivativeChain parts body
renderTensorExpr (TETensorLiteral elements parts) =
  renderTensorLiteral elements ++ concatMap ixSuffix parts
renderTensorExpr (TEDot parts) = intercalate " . " (map renderTensorDotPart parts)
renderTensorExpr (TEBinary op lhs rhs) =
  renderTensorBinarySide op lhs ++ " " ++ op ++ " " ++ renderTensorBinarySide op rhs
renderTensorExpr (TEGroup e) = "(" ++ renderTensorExpr e ++ ")"

flattenDerivative :: [IxPart] -> TensorExpr -> ([IxPart], TensorExpr)
flattenDerivative acc (TEDerivative parts body) =
  flattenDerivative (acc ++ parts) body
flattenDerivative acc body = (acc, body)

renderGridDerivativeChain :: [IxPart] -> TensorExpr -> String
renderGridDerivativeChain [] body = renderTensorExpr body
renderGridDerivativeChain (part:parts) body =
  foldl wrapOuter renderInner parts
  where
    renderInner = "`(d" ++ ixSuffix part ++ " " ++ renderTensorAtom body ++ ")"
    wrapOuter inner outerPart =
      "`(d" ++ ixSuffix outerPart ++ " (" ++ inner ++ "))"

renderTensorLiteral :: [TensorExpr] -> String
renderTensorLiteral [] = "[||]"
renderTensorLiteral elements =
  "[| " ++ intercalate ", " (map renderTensorExpr elements) ++ " |]"

preprocessTensorExpr :: Model -> String -> IO String
preprocessTensorExpr m src = do
  ast <- parseTensorExprIO "bad tensor expression" src
  return (renderTensorExpr (preprocessTensorAst m ast))

preprocessTensorAst :: Model -> TensorExpr -> TensorExpr
preprocessTensorAst m expr =
  case expr of
    TENumber _ -> expr
    TEIdent base parts
      | Just projected <- projectAxisComponents base parts ->
          keep projected
    TEIdent base parts ->
      keep (TEIdent (renameAxisIdent base parts) parts)
    TEUnary op body ->
      keep (TEUnary op (pre body))
    TECall f args ->
      keep (TECall (pre f) (map pre args))
    TEApply (TEIdent fn fnParts) args
      | Just (ordr, radius, part) <- derivativeOpParts (fn ++ concatMap ixSuffix fnParts)
      , let part' = renameDerivativePart part ->
          keep (TEApply (TEIdent ("pd" ++ show ordr ++ "r" ++ show radius) [part'])
                  (map pre args))
      | Just (order, part) <- sbpOpParts (fn ++ concatMap ixSuffix fnParts)
      , let part' = renameDerivativePart part ->
          keep (TEApply (TEIdent ("sbpd" ++ show order) [part'])
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
    TEGridDerivativeChain parts body ->
      keep (TEGridDerivativeChain (map renameDerivativePart parts) (pre body))
    TETensorLiteral elements parts ->
      keep (TETensorLiteral (map pre elements) parts)
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
    -- A concrete-axis subscript on a declared indexed field or local
    -- projects one component: the axis renames to its one-based position,
    -- which Egison reads as concrete tensor access.  The bound tensor value
    -- carries the symmetric and antisymmetric mirror entries (signs and the
    -- zero diagonal included), so no canonicalization is needed here.
    -- Non-axis subscripts keep their symbolic reading, exactly as for the
    -- coordinate derivative.
    projectAxisComponents base parts = do
      indexDecl <- lookup base (indexedFieldDeclarations m)
      positions <- mapM (axisPosition . ixName) parts
      if not (null parts) && indexDeclAcceptsParts indexDecl parts
        then Just (TEIdent base
          [ IxPart (ixVariance part) (show position)
          | (part, position) <- zip parts positions
          ])
        else Nothing
    axisPosition name = fmap (+ 1) (elemIndex name (mAxes m))

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
                                         Nothing ->
                                           case parseTensorLiteralExprE src ts of
                                             Just literal -> literal
                                             Nothing -> parseTensorAtomE src ts
  where
    parse = parseTensorTokensE src

setTensorSpan :: SourceSpan -> TensorExpr -> TensorExpr
setTensorSpan sp (TensorExpr _ node) = TensorExpr sp node

copyTensorMetadata :: TensorExpr -> TensorExpr -> TensorExpr
copyTensorMetadata source (TensorExpr _ node) =
  TensorExpr (tensorExprSpan source) node

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
  case parseGridDerivativeExprE src ts of
    Just e -> e
    Nothing ->
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
                                      case parseUnaryExprE src ts of
                                        Just e -> e
                                        Nothing ->
                                          case parseCallExprE src ts of
                                            Just e -> e
                                            Nothing ->
                                              case parseApplyExprE src ts of
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

-- Parse Egison's native tensor literal while retaining every component as a
-- TensorExpr child.  Only the adjacent @[|@ opener is claimed here; ordinary
-- bracketed/raw Egison constructs keep their existing fallback behavior.
-- The optional trailing marked sequence describes the literal result, as in
-- @[| x, y |]_i@ or a rank-two @[| ... |]~i_j@.
parseTensorLiteralExprE
    :: String -> [ITok] -> Maybe (Either String TensorExpr)
parseTensorLiteralExprE src ts0 =
  case trimTensorIToks ts0 of
    open@(IC '[') : pipe@(IC '|') : rest
      | tokensAdjacent open pipe -> Just $
          case closeGroupI ']' rest [] of
            Nothing -> parseError src ts0
              "tensor literal needs a closing |]"
            Just (insideWithPipe, remaining) ->
              case removeClosingPipe insideWithPipe of
                Nothing -> parseError src ts0
                  "tensor literal needs a closing |]"
                Just inside ->
                  case indexedSuffixOnlyI (trimTensorIToks remaining) of
                    Nothing -> parseError src remaining
                      "tensor literal result suffix needs marked indices"
                    Just parts ->
                      TETensorLiteral <$> parseElements inside <*> pure parts
    _ -> Nothing
  where
    removeClosingPipe tokens =
      case reverse (dropTrailingSpaces tokens) of
        IC '|' : reversedInside ->
          Just (trimTensorIToks (reverse reversedInside))
        _ -> Nothing

    dropTrailingSpaces =
      reverse . dropWhile isSpaceITok . reverse

    parseElements [] = Right []
    parseElements tokens =
      let elements = splitTopCommaI tokens
      in if any (null . trimTensorIToks) elements
           then parseError src tokens
             "tensor literal components cannot be empty"
           else mapM (parseTensorTokensE src) elements

-- Recognize only the Formurae-specific quoted derivative root
-- @`(d_x e)@.  Other prefix quotes remain outside the structured
-- TensorExpr grammar and continue through the existing generic/raw Egison
-- paths.  The parser also accepts the untranslated Unicode spelling so this
-- module can be tested directly; parseModel supplies the @d_x@ spelling.
parseGridDerivativeExprE
    :: String -> [ITok] -> Maybe (Either String TensorExpr)
parseGridDerivativeExprE src ts0 =
  case trimTensorIToks ts0 of
    quote@(IC '`') : open@(IC '(') : rest
      | tokensAdjacent quote open ->
          case closeGroupI ')' rest [] of
            Nothing ->
              Just (parseError src ts0
                "quoted derivative needs a closing parenthesis")
            Just (inside, remaining)
              | not (null (trimTensorIToks remaining)) ->
                  case gridDerivativePrefix inside of
                    Just _ -> Just (parseError src ts0
                      "quoted derivative must enclose the complete derivative application")
                    Nothing -> Nothing
              | otherwise ->
                  case gridDerivativePrefix inside of
                    Nothing -> Nothing
                    Just (part, operandTokens)
                      | null (trimTensorIToks operandTokens) ->
                          Just (parseError src inside
                            "quoted derivative needs an operand")
                      | otherwise ->
                          Just $ do
                            operand <- parseTensorTokensE src operandTokens
                            pure (prependGridDerivative part operand)
    _ -> Nothing

gridDerivativePrefix :: [ITok] -> Maybe (IxPart, [ITok])
gridDerivativePrefix ts =
  case dropWhile isSpaceITok ts of
    II word : rest
      | (base, [part]) <- parseIndexedIdent word
      , base == "d" || base == "∂" ->
          Just (part, dropWhile isSpaceITok rest)
    IC '∂' : IC mark : II name : rest
      | mark == '~' || mark == '_'
      , Just ([part], "") <- parseMarkedPrefix (mark : name) ->
          Just (part, dropWhile isSpaceITok rest)
    _ -> Nothing

prependGridDerivative :: IxPart -> TensorExpr -> TensorExpr
prependGridDerivative outerPart operand =
  case ungroupGridDerivative operand of
    Just (innerParts, innerOperand) ->
      TEGridDerivativeChain (innerParts ++ [outerPart]) innerOperand
    Nothing -> TEGridDerivativeChain [outerPart] operand

ungroupGridDerivative :: TensorExpr -> Maybe ([IxPart], TensorExpr)
ungroupGridDerivative (TEGridDerivativeChain parts body) = Just (parts, body)
ungroupGridDerivative (TEGroup body) = ungroupGridDerivative body
ungroupGridDerivative _ = Nothing

tokensAdjacent :: ITok -> ITok -> Bool
tokensAdjacent lhs rhs =
  itokOffset lhs > 0
  && itokOffset rhs == itokOffset lhs + itokWidth lhs

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
  | op == '+' || op == '-' || op == '!'
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
renderTensorAtom e@(TETensorLiteral _ _) = renderTensorExpr e
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
renderTensorUnaryArg e@(TETensorLiteral _ _) = renderTensorExpr e
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
