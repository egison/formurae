module Formurae.RuntimeTensor
  ( RuntimeTensorExpr(..)
  , renderRuntimeTensorExpr
  , renderCheckedRuntimeTensor
  ) where

import Data.Char (isDigit)
import Data.List (intercalate, nub)

import Formurae.Index
import Formurae.Syntax
import Formurae.TensorExpr

-- A tensor expression rendered for evaluation by Egison.  Symbolic indices
-- are hoisted into one `withSymbols` scope by the equation emitter; this keeps
-- them attached long enough for `tensorIndices` to validate the result.
data RuntimeTensorExpr = RuntimeTensorExpr
  { runtimeTensorText    :: String
  , runtimeTensorSymbols :: [String]
  } deriving (Eq, Show)

renderRuntimeTensorExpr
  :: Model
  -> [String]
  -> GridPolicy
  -> [IxPart]
  -> String
  -> TensorExpr
  -> IO (Either String RuntimeTensorExpr)
renderRuntimeTensorExpr m lets targetPolicy targetIndices targetBasis expression = do
  return $ do
    rendered <- render [] expression
    let targetNames = map ixName targetIndices
        ordered
          | length targetNames > 1 =
              "transpose [" ++ intercalate ", " targetNames ++ "] ("
              ++ rendered ++ ")"
          | otherwise = rendered
    return RuntimeTensorExpr
      { runtimeTensorText = ordered
      , runtimeTensorSymbols = nub
          (filter isSymbolic targetNames ++ symbolicNames [] expression)
      }
  where
    lhsNames = map ixName targetIndices

    render aliases expr =
      case expr of
        TENumber number -> Right number
        TEIdent base parts -> Right (renderIdent base (renameParts aliases parts))
        TEUnary op body -> do
          bodyText <- render aliases body
          Right ("(" ++ op ++ bodyText ++ ")")
        TECall function arguments -> do
          functionText <- render aliases function
          argumentTexts <- mapM (render aliases) arguments
          Right (functionText ++ "(" ++ intercalate ", " argumentTexts ++ ")")
        TEApply (TEIdent function functionParts) [argument]
          | Just (order, radius, part) <-
              derivativeOpParts (function ++ concatMap ixSuffix functionParts) ->
              renderCoordinateDerivative aliases order radius
                (renamePart aliases part) argument
        TEApply function arguments -> do
          functionText <- render aliases function
          argumentTexts <- mapM (render aliases) arguments
          Right (unwords (parenthesize functionText : map parenthesize argumentTexts))
        TEIf condition yes no -> do
          conditionText <- render aliases condition
          yesText <- render aliases yes
          noText <- render aliases no
          Right ("if " ++ conditionText ++ " then " ++ yesText
                 ++ " else " ++ noText)
        TEAppendIndexed body parts -> do
          bodyText <- render aliases body
          Right ("(" ++ bodyText ++ ")"
                 ++ concatMap ixSuffix (renameParts aliases parts))
        -- Definition expansion has already alpha-renamed local indices where
        -- required.  Hoisting the declarations keeps the result indices alive
        -- until the runtime signature check instead of anonymizing them at an
        -- inner `withSymbols` boundary.
        TEWithSymbols names body ->
          let localAliases =
                zip names lhsNames
                ++ [(name, replacement) | (name, replacement) <- aliases,
                                           name `notElem` names]
          in render localAliases body
        TEContractWith reducer body -> do
          bodyText <- render aliases body
          Right ("contractWith " ++ renderReducer reducer
                 ++ " (" ++ bodyText ++ ")")
        TETensorMap function body -> do
          functionText <- render aliases function
          bodyText <- materializeTensor aliases body
          Right ("tensorMap " ++ parenthesize functionText
                 ++ " " ++ parenthesize bodyText)
        TESubrefs body parts -> do
          bodyText <- render aliases body
          Right (renderDynamicRefs bodyText (renameParts aliases parts))
        TETranspose names body -> do
          renderTranspose aliases (map (renameName aliases) names) body
        TEDisjoint parts -> do
          texts <- mapM (render aliases) parts
          Right (intercalate " !. " (map parenthesize texts))
        TEDerivative parts body ->
          renderIndexedDerivative aliases (renameParts aliases parts) body
        TEDot parts -> do
          texts <- mapM (render aliases) parts
          Right (intercalate " . " (map parenthesize texts))
        TEBinary op lhs rhs -> do
          lhsText <- render aliases lhs
          rhsText <- render aliases rhs
          Right ("(" ++ lhsText ++ " " ++ op ++ " " ++ rhsText ++ ")")
        TEGroup body -> do
          bodyText <- render aliases body
          Right ("(" ++ bodyText ++ ")")

    renderIndexedDerivative aliases parts body = do
      let (derivativeParts, sourceExpression) = flatten parts body
      source <- derivativeSource aliases sourceExpression
      let helper = partialTensor source (length derivativeParts)
          allParts = derivativeParts ++ derivativeSourceParts source
      Right ("(" ++ helper ++ ")" ++ concatMap ixSuffix allParts)

    renderCoordinateDerivative aliases order radius part body = do
      axis <- coordinateAxis part
      source <- derivativeSource aliases body
      if radius == 1
        then do
          let helper = partialTensor source order
              selectedDerivativeParts = replicate order (IxPart VDown (show axis))
              allParts = selectedDerivativeParts ++ derivativeSourceParts source
          Right ("(" ++ helper ++ ")" ++ concatMap ixSuffix allParts)
        else do
          component <- render aliases body
          Right ("∂ " ++ show order ++ " " ++ show radius ++ " "
                 ++ axisName axis ++ " " ++ parenthesize component)

    partialTensor source order =
      "FE.partialChainTensor (feTensorDerivative " ++ show targetPolicy
      ++ " " ++ show (derivativeSourcePolicy source) ++ ") "
      ++ targetBasis ++ " feAxisIds " ++ show order ++ " "
      ++ parenthesize (derivativeSourceTensor source)

    coordinateAxis (IxPart _ name) =
      case lookup name (zip (internalCoordNames m) (axisRange m)) of
        Just axis -> Right axis
        Nothing -> Left ("runtime coordinate derivative has a symbolic axis: " ++ name)

    axisName axis =
      case drop (axis - 1) (internalCoordNames m) of
        name : _ -> name
        [] -> "x"

    renderIdent base parts
      | base == "epsilon", not (null parts) =
          "(ε feDim)" ++ concatMap ixSuffix parts
      | base == "delta", not (null parts) =
          "(FE.metricTensor feDim (\\i j -> if i = j then 1 else 0))"
          ++ concatMap ixSuffix parts
      | base == metricPreludeName, length parts == 2 =
          "(FE.metricTensor feDim (\\i j -> if i = j then 1 else 0))"
          ++ concatMap ixSuffix parts
      | Just metricName <- mMetricName m
      , base == metricName
      , [first, second] <- parts =
          metricInternalBase (ixVariance first) (ixVariance second)
          ++ concatMap ixSuffix parts
      | otherwise = base ++ concatMap ixSuffix parts

    symbolicNames aliases = nub . filter isSymbolic . collectNames aliases
    isSymbolic name =
      not (null name)
      && not (all isDigit name)
      && name `notElem` internalCoordNames m

    collectNames aliases expr =
      case expr of
        TENumber _ -> []
        TEIdent _ parts -> map ixName (renameParts aliases parts)
        TEUnary _ body -> collectNames aliases body
        TECall function arguments ->
          concatMap (collectNames aliases) (function : arguments)
        TEApply function arguments ->
          concatMap (collectNames aliases) (function : arguments)
        TEIf condition yes no ->
          concatMap (collectNames aliases) [condition, yes, no]
        TEAppendIndexed body parts ->
          collectNames aliases body ++ map ixName (renameParts aliases parts)
        TEWithSymbols names body ->
          let localAliases =
                zip names lhsNames
                ++ [(name, replacement) | (name, replacement) <- aliases,
                                           name `notElem` names]
          in collectNames localAliases body
        TEContractWith _ body -> collectNames aliases body
        TETensorMap function body ->
          collectNames aliases function ++ collectNames aliases body
        TESubrefs body parts ->
          collectNames aliases body ++ map ixName (renameParts aliases parts)
        TETranspose names body ->
          map (renameName aliases) names ++ collectNames aliases body
        TEDisjoint parts -> concatMap (collectNames aliases) parts
        TEDerivative parts body ->
          map ixName (renameParts aliases parts) ++ collectNames aliases body
        TEDot parts -> concatMap (collectNames aliases) parts
        TEBinary _ lhs rhs -> collectNames aliases lhs ++ collectNames aliases rhs
        TEGroup body -> collectNames aliases body

    flatten accumulated (TEDerivative more body) =
      flatten (accumulated ++ more) body
    flatten accumulated body = (accumulated, body)

    derivativeSource aliases sourceExpression =
      case sourceExpression of
        TEGroup body -> derivativeSource aliases body
        TEAppendIndexed (TEIdent base existing) appended ->
          sourceFromIdent base (renameParts aliases (existing ++ appended))
        TEIdent base parts -> sourceFromIdent base (renameParts aliases parts)
        _ -> Left ("runtime indexed derivative needs a field operand: "
                   ++ renderTensorExpr sourceExpression)

    sourceFromIdent base parts =
      let (fieldName, _) = fieldBaseOf base
      in case kindOf m fieldName of
           Just Scalar
             | null parts -> Right DerivativeSource
                 { derivativeSourceTensor = "FE.scalarTensor " ++ parenthesize base
                 , derivativeSourceParts = []
                 , derivativeSourcePolicy = fieldPolicyOf m fieldName
                 }
           Just kind
             | length parts == componentRank kind -> Right DerivativeSource
                 { derivativeSourceTensor = base
                 , derivativeSourceParts = parts
                 , derivativeSourcePolicy = fieldPolicyOf m fieldName
                 }
           Nothing
             | fieldName `elem` lets && not (null parts) -> Right DerivativeSource
                 { derivativeSourceTensor = base
                 , derivativeSourceParts = parts
                 , derivativeSourcePolicy = Collocated
                 }
           _ -> Left ("runtime indexed derivative needs a fully indexed field operand: "
                      ++ base ++ concatMap ixSuffix parts)

    materializeTensor aliases body =
      case body of
        TEGroup inner -> materializeTensor aliases inner
        TEIdent base [] -> do
          parts <- inferredTensorParts base
          Right (renderIdent base parts)
        _ -> render aliases body

    renderTranspose aliases names body =
      case body of
        TEGroup inner -> renderTranspose aliases names inner
        TEIdent base parts0 -> do
          parts <- if null parts0
                     then inferredTensorParts base
                     else Right (renameParts aliases parts0)
          if length names /= length parts
            then Left "transpose index list length does not match tensor rank"
            else Right (renderIdent base
                   [IxPart (ixVariance part) name
                   | (part, name) <- zip parts names])
        _ -> do
          bodyText <- render aliases body
          Right ("transpose [" ++ intercalate ", " names ++ "] "
                 ++ parenthesize bodyText)

    inferredTensorParts base =
      let (fieldName, _) = fieldBaseOf base
      in case kindOf m fieldName of
           Just kind
             | componentRank kind > 0
             , length lhsNames >= componentRank kind ->
                 let variances =
                       case fieldDeclOf m fieldName >>= fieldIndexParts of
                         Just declared
                           | length declared == componentRank kind ->
                               map ixVariance declared
                         _ -> replicate (componentRank kind) VDown
                 in Right
                      [IxPart variance name
                      | (variance, name) <-
                          zip variances (take (componentRank kind) lhsNames)]
           Nothing
             | fieldName `elem` lets
             , not (null lhsNames) ->
                 Right [IxPart VDown name | name <- lhsNames]
           _ -> Left ("cannot infer tensor indices for " ++ base)

    renameParts aliases = map (renamePart aliases)
    renamePart aliases (IxPart variance name) =
      IxPart variance (renameName aliases name)
    renameName aliases name =
      case lookup name aliases of
        Just replacement -> replacement
        Nothing -> name

data DerivativeSource = DerivativeSource
  { derivativeSourceTensor :: String
  , derivativeSourceParts  :: [IxPart]
  , derivativeSourcePolicy :: GridPolicy
  }

renderCheckedRuntimeTensor
  :: Model -> String -> [IxPart] -> RuntimeTensorExpr -> String
renderCheckedRuntimeTensor m target indices runtime =
  let shape = replicate (length indices) (mDim m)
      variances = map varianceName indices
      checked =
        "FE.checkedTensorSignature "
        ++ show ("tensor signature mismatch for " ++ target) ++ " "
        ++ show shape ++ " " ++ show variances ++ " ("
        ++ runtimeTensorText runtime ++ ")"
  in case runtimeTensorSymbols runtime of
       [] -> checked
       symbols ->
         "withSymbols [" ++ intercalate ", " symbols ++ "] (" ++ checked ++ ")"
  where
    varianceName (IxPart VUp _) = "up"
    varianceName (IxPart VDown _) = "down"

renderReducer :: String -> String
renderReducer reducer
  | reducer == "+" || reducer == "*" = "(" ++ reducer ++ ")"
  | otherwise = reducer

renderDynamicRefs :: String -> [IxPart] -> String
renderDynamicRefs = foldl attach
  where
    attach body part =
      let function = case ixVariance part of
                       VUp -> "suprefs"
                       VDown -> "subrefs"
      in function ++ " " ++ parenthesize body ++ " [" ++ ixName part ++ "]"

parenthesize :: String -> String
parenthesize text = "(" ++ text ++ ")"
