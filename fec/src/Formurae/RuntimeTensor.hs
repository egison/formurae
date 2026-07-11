module Formurae.RuntimeTensor
  ( RuntimeTensorExpr(..)
  , RuntimeTensorBinding(..)
  , runtimeTensorBindingNames
  , runtimeIndexedBindingNames
  , hygienicIndexParts
  , nativeResultIndicesSafe
  , renderRuntimeTensorExpr
  , renderCheckedRuntimeTensor
  , renderRuntimeScalar
  ) where

import Data.Char (isDigit)
import Data.List (intercalate, nub)

import Formurae.Common (reservedInternalPrefix)
import Formurae.Index
import Formurae.Syntax
import Formurae.TensorExpr

data RuntimeTensorBinding = RuntimeTensorBinding
  { runtimeBindingName    :: String
  , runtimeBindingIndices :: [IxPart]
  , runtimeBindingPolicy  :: Maybe GridPolicy
  } deriving (Eq, Show)

runtimeTensorBindingNames :: [RuntimeTensorBinding] -> [String]
runtimeTensorBindingNames = map runtimeBindingName

runtimeIndexedBindingNames :: [RuntimeTensorBinding] -> [String]
runtimeIndexedBindingNames =
  map runtimeBindingName . filter (not . null . runtimeBindingIndices)

hygienicIndexParts :: [IxPart] -> [IxPart]
hygienicIndexParts parts = map rename parts
  where
    symbolicNames = nub
      [name | IxPart _ name <- parts, not (all isDigit name)]
    replacements = zip symbolicNames
      [reservedInternalPrefix ++ "Index" ++ show n | n <- [1 :: Int ..]]
    rename part@(IxPart variance name) =
      case lookup name replacements of
        Just replacement -> IxPart variance replacement
        Nothing -> part

-- The compact native emitter intentionally erases explicit indices from
-- whole-tensor operands.  That is correct inside a coordinate operator (the
-- operator consumes the whole tensor), but not for a direct result operand:
-- `hessian u + A_j_i` must preserve the transpose requested on `A`.
--
-- Keep the fast native path only when every direct symbolic tensor view has
-- exactly the result indices.  The general runtime renderer handles all other
-- orders and variances without losing information.
nativeResultIndicesSafe
  :: [String] -> Model -> [RuntimeTensorBinding] -> [IxPart] -> TensorExpr -> Bool
nativeResultIndicesSafe nativeMarkers m bindings targetIndices = check []
  where
    targetNames = map ixName targetIndices

    check aliases expression =
      case expression of
        TENumber _ -> True
        TEIdent base parts -> directViewSafe aliases base parts
        TEUnary _ body -> check aliases body
        TECall function arguments ->
          all (check aliases) (function : arguments)
        TEApply (TEIdent marker []) [_]
          | marker `elem` nativeMarkers -> True
        TEApply function arguments ->
          all (check aliases) (function : arguments)
        TEIf condition yes no ->
          all (check aliases) [condition, yes, no]
        TEAppendIndexed body _ -> check aliases body
        TEWithSymbols names body ->
          let localAliases =
                zip names targetNames
                ++ [(name, replacement) | (name, replacement) <- aliases,
                                           name `notElem` names]
          in check localAliases body
        TEContractWith _ body -> check aliases body
        TETensorMap function body -> check aliases function && check aliases body
        TESubrefs body _ -> check aliases body
        TETranspose _ _ -> False
        TEDisjoint parts -> all (check aliases) parts
        TEDerivative _ _ -> False
        TEDot parts -> all (check aliases) parts
        TEBinary _ lhs rhs -> check aliases lhs && check aliases rhs
        TEGroup body -> check aliases body

    directViewSafe aliases base parts
      | null parts = True
      | not (all (isSymbolicPart . renamePart aliases) parts) = True
      | isTensorValue base = map (renamePart aliases) parts == targetIndices
      | otherwise = True

    isTensorValue base =
      let (fieldName, _) = fieldBaseOf base
      in case kindOf m fieldName of
           Just kind -> componentRank kind > 0
           Nothing -> bindingOf fieldName /= Nothing

    bindingOf name =
      case [binding | binding <- bindings, runtimeBindingName binding == name] of
        binding : _ -> Just binding
        [] -> Nothing

    isSymbolicPart (IxPart _ name) =
      not (null name) && not (all isDigit name)
    renamePart aliases (IxPart variance name) =
      IxPart variance $ case lookup name aliases of
        Just replacement -> replacement
        Nothing -> name

-- A tensor expression rendered for evaluation by Egison.  Symbolic indices
-- are hoisted into one `withSymbols` scope by the equation emitter; this keeps
-- them attached long enough for `tensorIndices` to validate the result.
data RuntimeTensorExpr = RuntimeTensorExpr
  { runtimeTensorText    :: String
  , runtimeTensorSymbols :: [String]
  } deriving (Eq, Show)

renderRuntimeTensorExpr
  :: Model
  -> [RuntimeTensorBinding]
  -> GridPolicy
  -> [IxPart]
  -> String
  -> TensorExpr
  -> IO (Either String RuntimeTensorExpr)
renderRuntimeTensorExpr m bindings targetPolicy targetIndices targetBasis expression = do
  return $ do
    rendered <- if null targetIndices
                  then render [] expression
                  else materializeTensor [] expression
    let targetNames = safeLhsNames
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
    rawSymbolNames = nub
      (filter isRawSymbolic (lhsNames ++ collectRawNames expression))
    hygienicNames =
      zip rawSymbolNames
        [reservedInternalPrefix ++ "Index" ++ show n | n <- [1 :: Int ..]]
    safeLhsNames = map (renameName []) lhsNames

    render aliases expr =
      case expr of
        TENumber number -> Right number
        TEIdent base parts -> do
          validateReferenceParts base parts
          Right (renderIdent base (renameParts aliases parts))
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
        TEApply (TEIdent "sharp" []) [operand] -> renderSharp operand
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
      case coordinateAxis part of
        Right axis -> do
          source <- derivativeSource aliases body
          if radius > 1 && odd order && wideOddPlacementMismatch source
            then Left "wide odd-order coordinate derivative needs a placement-aware stencil"
          else if radius == 1
            then do
              let helper = partialTensor source order
                  selectedDerivativeParts = replicate order (IxPart VDown (show axis))
                  allParts = selectedDerivativeParts ++ derivativeSourceParts source
              Right ("(" ++ helper ++ ")" ++ concatMap ixSuffix allParts)
            else do
              component <- render aliases body
              Right ("∂ " ++ show order ++ " " ++ show radius ++ " "
                     ++ axisName axis ++ " " ++ parenthesize component)
        Left _ -> do
          source <- derivativeSource aliases body
          renderSymbolicCoordinateDerivative source order radius

    renderSymbolicCoordinateDerivative source order radius =
      case (safeLhsNames, targetIndices, derivativeSourceParts source) of
        ([name], [IxPart variance _], [])
          | radius > 1
          , odd order
          , wideOddPlacementMismatch source ->
              Left "wide odd-order symbolic derivative needs a placement-aware stencil"
          | otherwise ->
              Right ("(FE.diagonalCoordinateDerivative (feTensorDerivative "
                     ++ show targetPolicy ++ " "
                     ++ show (derivativeSourcePolicy source)
                     ++ ") ∂ feCoords feAxisIds " ++ show order ++ " "
                     ++ show radius ++ " "
                     ++ parenthesize (derivativeSourceTensor source) ++ ")"
                     ++ ixSuffix (IxPart variance name))
        _ -> Left "symbolic coordinate derivative needs a scalar operand and rank-1 target"

    -- The scalar wide-stencil helper samples around the source lattice and
    -- cannot express the half-cell shift required by an odd derivative whose
    -- result lives on a different lattice.  Check every target component (and
    -- every contracted source component) before selecting that helper.
    wideOddPlacementMismatch source =
      any componentMismatch targetComponents
      where
        targetComponents = indexTuples (length targetIndices)
        sourceNames = nub
          [name | IxPart _ name <- derivativeSourceParts source,
                  not (null name), not (all isDigit name),
                  name `notElem` safeLhsNames]
        componentMismatch targetComponent =
          let targetEnvironment = zip safeLhsNames targetComponent
          in any (sourceMismatch targetComponent targetEnvironment)
                 (indexTuples (length sourceNames))
        sourceMismatch targetComponent targetEnvironment sourceComponent =
          let environment = targetEnvironment ++ zip sourceNames sourceComponent
              sourceIndices = map (resolveIndex environment)
                                  (derivativeSourceParts source)
          in componentPlacement m targetPolicy targetComponent
             /= componentPlacement m (derivativeSourcePolicy source) sourceIndices
        resolveIndex environment (IxPart _ name) =
          case lookup name environment of
            Just axis -> axis
            Nothing -> read name
        indexTuples rank = sequence (replicate rank (axisRange m))

    renderSharp operand =
      case operand of
        TEGroup body -> renderSharp body
        TEIdent base [] ->
          let (fieldName, primes) = fieldBaseOf base
              wrapper = fieldName ++ if primes == 0 then "f" else "fN"
          in case kindOf m fieldName of
               Just (Form 1)
                 | name : _ <- safeLhsNames ->
                     Right ("(snd (FE.sharp feMusicalScale " ++ wrapper
                            ++ "))~" ++ name)
               Just (Form degree) ->
                 Left ("sharp expects a 1-form, but " ++ fieldName
                       ++ " is a " ++ show degree ++ "-form")
               _ -> Left "sharp expects a 1-form operand"
        _ -> Left "sharp expects an unindexed 1-form operand"

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
        _ | containsBareTensor sourceExpression ->
          Left "compound derivative of a bare tensor needs explicit component indices"
        _ -> do
          component <- render aliases sourceExpression
          sourcePolicy <- inferDerivativeSourcePolicy sourceExpression
          let inferredParts = compoundFreeParts sourceExpression
              sourceParts = renameParts aliases inferredParts
          Right DerivativeSource
            { derivativeSourceTensor =
                if null sourceParts
                  then "FE.scalarTensor " ++ parenthesize component
                  else component
            , derivativeSourceParts = sourceParts
            , derivativeSourcePolicy = maybe targetPolicy id sourcePolicy
            }

    -- Free indices on a compound derivative operand describe the component
    -- basis of its value tensor.  Keeping them separate from the derivative
    -- axes lets FE.partialChainTensor pass the actual staggered source basis
    -- to feTensorDerivative (`∂_x (A_i * 2)` must use source basis [i]).
    compoundFreeParts expr = nub $ case expr of
      TENumber _ -> []
      TEIdent _ parts -> symbolicParts parts
      TEUnary _ body -> compoundFreeParts body
      TECall _ arguments -> concatMap compoundFreeParts arguments
      TEApply _ arguments -> concatMap compoundFreeParts arguments
      TEIf condition yes no ->
        compoundFreeParts condition
        ++ compoundFreeParts yes
        ++ compoundFreeParts no
      TEAppendIndexed body parts ->
        compoundFreeParts body ++ symbolicParts parts
      TEWithSymbols names body ->
        map (renameLocalPart (zip names lhsNames)) (compoundFreeParts body)
      TEContractWith _ body -> contractParts (compoundFreeParts body)
      TETensorMap _ body -> compoundFreeParts body
      TESubrefs body parts ->
        compoundFreeParts body ++ symbolicParts parts
      TETranspose names body ->
        let bodyParts = compoundFreeParts body
        in if length names == length bodyParts
             then [IxPart (ixVariance part) name
                  | (part, name) <- zip bodyParts names]
             else bodyParts
      TEDisjoint parts -> concatMap compoundFreeParts parts
      TEDerivative parts body ->
        symbolicParts parts ++ compoundFreeParts body
      TEDot parts -> contractParts (concatMap compoundFreeParts parts)
      TEBinary op lhs rhs
        | op == "+" || op == "-" ->
            nub (compoundFreeParts lhs ++ compoundFreeParts rhs)
        | otherwise -> compoundFreeParts lhs ++ compoundFreeParts rhs
      TEGroup body -> compoundFreeParts body
      where
        symbolicParts = filter (isRawSymbolic . ixName)
        renameLocalPart localAliases (IxPart variance name) =
          IxPart variance $ case lookup name localAliases of
            Just replacement -> replacement
            Nothing -> name
        contractParts parts =
          let names = nub (map ixName parts)
              contracted =
                [name | name <- names,
                        any (isVariance name VUp) parts,
                        any (isVariance name VDown) parts]
          in [part | part <- parts, ixName part `notElem` contracted]
        isVariance name variance (IxPart actual partName) =
          name == partName && variance == actual

    containsBareTensor expr =
      case expr of
        TENumber _ -> False
        TEIdent base parts
          | null parts, referenceRank base > 0 -> True
          | otherwise -> False
        TEUnary _ body -> containsBareTensor body
        TECall function arguments ->
          any containsBareTensor (function : arguments)
        TEApply function arguments ->
          any containsBareTensor (function : arguments)
        TEIf condition yes no ->
          any containsBareTensor [condition, yes, no]
        TEAppendIndexed body _ -> containsBareTensor body
        TEWithSymbols _ body -> containsBareTensor body
        TEContractWith _ body -> containsBareTensor body
        TETensorMap function body ->
          containsBareTensor function || containsBareTensor body
        TESubrefs body _ -> containsBareTensor body
        TETranspose _ body -> containsBareTensor body
        TEDisjoint parts -> any containsBareTensor parts
        TEDerivative _ body -> containsBareTensor body
        TEDot parts -> any containsBareTensor parts
        TEBinary _ lhs rhs ->
          containsBareTensor lhs || containsBareTensor rhs
        TEGroup body -> containsBareTensor body

    referenceRank base =
      let fieldName = fst (fieldBaseOf base)
      in case kindOf m fieldName of
           Just kind -> componentRank kind
           Nothing -> maybe 0 (length . runtimeBindingIndices)
                        (bindingOf fieldName)

    -- A coordinate derivative may act on a complete expression, not only on
    -- one field identifier (`∂_x (u * u / 2)` or `∂_x (A_i * 2)`).  The
    -- rank-zero container supplies the derivative source axis while Egison's
    -- attached free indices remain on the contained value.  Final rank and
    -- per-basis placement are still checked by the frontend validator and by
    -- FE.checkedTensorSignature.
    inferDerivativeSourcePolicy sourceExpression =
      case sourceExpression of
        TENumber _ -> Right Nothing
        TEIdent base parts -> Right (referencePolicy base parts)
        TEUnary _ body -> inferDerivativeSourcePolicy body
        TECall _ arguments -> mergePolicies arguments
        TEApply (TEIdent function functionParts) [body]
          | Just (order, _, _) <-
              derivativeOpParts (function ++ concatMap ixSuffix functionParts) ->
              fmap (fmap (applyDerivativeParity order))
                   (inferDerivativeSourcePolicy body)
        TEApply (TEIdent "sharp" []) [body] -> inferDerivativeSourcePolicy body
        TEApply _ arguments -> mergePolicies arguments
        TEIf condition yes no -> mergePolicies [condition, yes, no]
        TEAppendIndexed body _ -> inferDerivativeSourcePolicy body
        TEWithSymbols _ body -> inferDerivativeSourcePolicy body
        TEContractWith _ body -> inferDerivativeSourcePolicy body
        TETensorMap _ body -> inferDerivativeSourcePolicy body
        TESubrefs body _ -> inferDerivativeSourcePolicy body
        TETranspose _ body -> inferDerivativeSourcePolicy body
        TEDisjoint parts -> mergePolicies parts
        TEDerivative parts body ->
          fmap (fmap (applyDerivativeParity (length parts)))
               (inferDerivativeSourcePolicy body)
        TEDot parts -> mergePolicies parts
        TEBinary _ lhs rhs -> mergePolicies [lhs, rhs]
        TEGroup body -> inferDerivativeSourcePolicy body
      where
        referencePolicy base parts =
          let fieldName = fst (fieldBaseOf base)
          in if length parts == 2
                && (fieldName == metricPreludeName
                    || Just fieldName == mMetricName m)
               then Nothing
               else case kindOf m fieldName of
                 Just _ -> Just (fieldPolicyOf m fieldName)
                 Nothing -> runtimeBindingPolicy =<< bindingOf fieldName
        mergePolicies expressions = do
          inferred <- mapM inferDerivativeSourcePolicy expressions
          case nub [policy | Just policy <- inferred] of
            [] -> Right Nothing
            policy : policies
              | all (sameScalarPlacement policy) policies -> Right (Just policy)
              | otherwise ->
                  Left "coordinate derivative operand has incompatible grid policies"
        sameScalarPlacement lhs rhs =
          componentPlacement m lhs [] == componentPlacement m rhs []
        applyDerivativeParity order policy
          | even order = policy
          | policy == Collocated = Collocated
          | policy == Primal = Dual
          | otherwise = Primal

    sourceFromIdent base parts =
      let (fieldName, _) = fieldBaseOf base
      in do
        validateReferenceParts base parts
        case kindOf m fieldName of
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
             | Just binding <- bindingOf fieldName
             , null (runtimeBindingIndices binding)
             , null parts -> Right DerivativeSource
                 { derivativeSourceTensor = "FE.scalarTensor " ++ parenthesize base
                 , derivativeSourceParts = []
                 , derivativeSourcePolicy =
                     maybe targetPolicy id (runtimeBindingPolicy binding)
                 }
             | Just binding <- bindingOf fieldName
             , not (null parts) -> Right DerivativeSource
                 { derivativeSourceTensor = base
                 , derivativeSourceParts = parts
                 , derivativeSourcePolicy =
                     maybe targetPolicy id (runtimeBindingPolicy binding)
                 }
           _ -> Left ("runtime indexed derivative needs a fully indexed field operand: "
                      ++ base ++ concatMap ixSuffix parts)

    materializeTensor aliases body =
      case body of
        TEGroup inner -> materializeTensor aliases inner
        TEIdent base [] -> do
          case inferredTensorParts base of
            Right parts -> Right (renderIdent base parts)
            Left _ -> render aliases body
        TEUnary op inner -> do
          innerText <- materializeTensor aliases inner
          Right ("(" ++ op ++ innerText ++ ")")
        TECall function arguments -> do
          functionText <- render aliases function
          argumentTexts <- mapM (materializeTensor aliases) arguments
          Right (functionText ++ "(" ++ intercalate ", " argumentTexts ++ ")")
        TEApply (TEIdent function functionParts) [_]
          | derivativeOpParts (function ++ concatMap ixSuffix functionParts)
              /= Nothing -> render aliases body
        TEApply (TEIdent "sharp" []) [_] -> render aliases body
        TEApply function arguments -> do
          functionText <- render aliases function
          argumentTexts <- mapM (materializeTensor aliases) arguments
          Right (unwords (parenthesize functionText : map parenthesize argumentTexts))
        TEIf condition yes no -> do
          conditionText <- render aliases condition
          yesText <- materializeTensor aliases yes
          noText <- materializeTensor aliases no
          Right ("if " ++ conditionText ++ " then " ++ yesText
                 ++ " else " ++ noText)
        TEBinary op lhs rhs -> do
          lhsText <- materializeTensor aliases lhs
          rhsText <- materializeTensor aliases rhs
          Right ("(" ++ lhsText ++ " " ++ op ++ " " ++ rhsText ++ ")")
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
          if length names /= length lhsNames
            then Left "transpose index list length does not match tensor rank"
            else do
              bodyText <- materializeTensor aliases body
              Right ("transpose [" ++ intercalate ", " names ++ "] "
                     ++ parenthesize bodyText)

    inferredTensorParts base =
      let (fieldName, _) = fieldBaseOf base
      in case kindOf m fieldName of
           Just kind
             | componentRank kind > 0
             , length safeLhsNames >= componentRank kind ->
                 let variances =
                       case fieldDeclOf m fieldName >>= fieldIndexParts of
                         Just declared
                           | length declared == componentRank kind ->
                               map ixVariance declared
                         _ -> replicate (componentRank kind) VDown
                 in Right
                      [IxPart variance name
                      | (variance, name) <-
                          zip variances (take (componentRank kind) safeLhsNames)]
           Nothing
             | Just binding <- bindingOf fieldName
             , null (runtimeBindingIndices binding) ->
                 Left ("cannot infer tensor indices for scalar binding " ++ base)
             | Just binding <- bindingOf fieldName
             , not (null safeLhsNames) ->
                 let variances = map ixVariance (runtimeBindingIndices binding)
                 in if length variances <= length safeLhsNames
                      then Right
                        [IxPart variance name
                        | (variance, name) <- zip variances safeLhsNames]
                      else Left ("cannot infer tensor indices for " ++ base)
           _ -> Left ("cannot infer tensor indices for " ++ base)

    bindingOf name =
      case [binding | binding <- bindings, runtimeBindingName binding == name] of
        binding : _ -> Just binding
        [] -> Nothing

    validateReferenceParts base parts =
      let fieldName = fst (fieldBaseOf base)
          variances = map ixVariance parts
      in if length parts == 2
            && (fieldName == metricPreludeName || Just fieldName == mMetricName m)
           then Right ()
           else
             case bindingOf fieldName of
               Just binding
                 | not (null parts)
                 , variances /= map ixVariance (runtimeBindingIndices binding) ->
                     Left ("indexed let " ++ fieldName
                           ++ " is referenced with incompatible index variance: "
                           ++ base ++ concatMap ixSuffix parts)
               _ ->
                 case fieldDeclOf m fieldName >>= fieldIndexParts of
                   Just declared
                     | not (null parts)
                     , variances /= map ixVariance declared ->
                         Left ("field " ++ fieldName
                               ++ " is referenced with incompatible index variance: "
                               ++ base ++ concatMap ixSuffix parts)
                   _ -> Right ()

    renameParts aliases = map (renamePart aliases)
    renamePart aliases (IxPart variance name) =
      IxPart variance (renameName aliases name)
    renameName aliases name =
      let aliased = case lookup name aliases of
                      Just replacement -> replacement
                      Nothing -> name
      in case lookup aliased hygienicNames of
           Just replacement -> replacement
           Nothing -> aliased

    isRawSymbolic name =
      not (null name)
      && not (all isDigit name)
      && name `notElem` internalCoordNames m

    collectRawNames expr =
      case expr of
        TENumber _ -> []
        TEIdent _ parts -> map ixName parts
        TEUnary _ body -> collectRawNames body
        TECall function arguments ->
          concatMap collectRawNames (function : arguments)
        TEApply function arguments ->
          concatMap collectRawNames (function : arguments)
        TEIf condition yes no ->
          concatMap collectRawNames [condition, yes, no]
        TEAppendIndexed body parts ->
          collectRawNames body ++ map ixName parts
        TEWithSymbols names body -> names ++ collectRawNames body
        TEContractWith _ body -> collectRawNames body
        TETensorMap function body ->
          collectRawNames function ++ collectRawNames body
        TESubrefs body parts -> collectRawNames body ++ map ixName parts
        TETranspose names body -> names ++ collectRawNames body
        TEDisjoint parts -> concatMap collectRawNames parts
        TEDerivative parts body -> map ixName parts ++ collectRawNames body
        TEDot parts -> concatMap collectRawNames parts
        TEBinary _ lhs rhs -> collectRawNames lhs ++ collectRawNames rhs
        TEGroup body -> collectRawNames body

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

renderRuntimeScalar :: RuntimeTensorExpr -> String
renderRuntimeScalar runtime =
  case runtimeTensorSymbols runtime of
    [] -> runtimeTensorText runtime
    symbols ->
      "withSymbols [" ++ intercalate ", " symbols ++ "] ("
      ++ runtimeTensorText runtime ++ ")"

renderReducer :: String -> String
renderReducer reducer
  | reducer == "+" || reducer == "*" = "(" ++ reducer ++ ")"
  | otherwise = "(FE.symbolicBinary " ++ show reducer ++ ")"

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
