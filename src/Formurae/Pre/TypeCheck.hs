{-# LANGUAGE PatternSynonyms #-}

-- | Static kind checks for the small set of surface operators whose
-- mathematical domain is narrower than Egison's componentwise tensor
-- lifting.  The normalizer remains responsible for full tensor algebra, but
-- these checks run before it so a scalar-only quoted derivative or scalar
-- Laplacian cannot silently turn into a componentwise tensor operation.
--
-- The static layer distinguishes only scalar and tensor values.  Form
-- degrees are runtime data carried by the value itself (dfOrder): the
-- canonical-operator library guards them during normalization and the FEIR
-- encode boundary re-checks declared metadata, both reporting through the
-- origin table, so a fixed macro body can instantiate at every degree
-- without the checker having to know which one.
module Formurae.Pre.TypeCheck
  ( OperatorTypeError(..)
  , validateModelOperatorTypes
  ) where

import Data.Char (isAlphaNum)
import Formurae.Common (analyticDerivativeName, egisonIdentifiers, maskEgisonNonCode)
import Formurae.Index (derivativeOpParts, sbpxOpParts)
import Formurae.Pre.FormOperator
import Formurae.Syntax
import Formurae.TensorExpr

data StaticKind
  = StaticScalar
  | StaticTensor
  | StaticUnknown
  deriving (Eq, Ord, Show)

data OperatorTypeError = OperatorTypeError
  { operatorTypeErrorSource :: Maybe SourceText
  , operatorTypeErrorMessage :: String
  } deriving (Eq, Show)

type KindEnvironment = [(String, StaticKind)]

-- | Validate every structured expression.  Raw Egison definitions remain
-- behind the deliberately conservative effect boundary and are also scanned
-- here so they cannot use canonical typed operators on an unproved value.
validateModelOperatorTypes :: Model -> Either OperatorTypeError ()
validateModelOperatorTypes model = do
  mapM_ checkDefinition (mDefs model)
  mapM_ (checkGeometryExpression "metric scale")
    (maybe [] id (mMetric model))
  mapM_ (checkGeometryExpression "embedding")
    (maybe [] id (mEmbed model))
  mapM_ checkInitializer (zip (mInits model) (mInitSourceTexts model))
  checkSteps baseEnvironment (mSteps model)
  where
    baseEnvironment =
      [(fdName field, kindFromSurface (fdKind field))
      | field <- mFieldDecls model]
      ++ [(name, StaticScalar) | (name, _) <- mParams model]
      ++ [(axis, StaticScalar) | axis <- mAxes model]
      ++ [ ("π", StaticScalar)
         , ("dimension", StaticScalar)
         , ("volume", StaticScalar)
         , ("metric", StaticTensor)
         , ("inverseMetric", StaticTensor)
         , ("epsilon", StaticTensor)
         , ("coordinates", StaticTensor)
         , ("FormuraeInternalKroneckerDelta", StaticTensor)
         ]

    definitionNames = map defName (mDefs model)

    checkDefinition definition =
      let parameters =
            [(definitionParameterBase parameter, parameterKind parameter)
            | parameter <- defParams definition]
          shadowed = definitionNames ++ map fst parameters
      in case parseTensorExprEither (defBody definition) of
        Left _ -> case firstRawCanonicalOperator shadowed (defBody definition) of
          Just operator -> typeFailure (defSourceText definition)
            ("canonical " ++ canonicalOperatorName operator
             ++ " cannot be used inside an untyped raw Egison definition; "
             ++ "apply it to a declared field, typed local, or structured "
             ++ "step expression")
          Nothing -> pure ()
        Right expression -> do
          _ <- infer model shadowed (parameters ++ baseEnvironment)
                 (defSourceText definition) expression
          pure ()

    checkInitializer (initializer, source) = case initializer of
      -- CAS initializers assign one structured value to a declared field, so
      -- they must preserve the field's static kind just like step updates.
      -- Raw/component initializers are represented componentwise and retain
      -- their existing per-expression validation below.
      ICas name expression ->
        checkFieldAssignment name (Just source) expression
      ICasIndex name _ expression ->
        checkFieldAssignment name (Just source) expression
      _ -> mapM_
        (checkExpression definitionNames baseEnvironment (Just source))
        (initializerExpressions initializer)

    checkGeometryExpression context expressionSource = do
      -- Geometry expressions historically admit generic CAS backquotes that
      -- are intentionally outside TensorExpr (for example `(1 + r)).  Keep
      -- that boundary, but scan an unstructured fallback conservatively so a
      -- canonical typed operator cannot escape validation through it.
      case parseTensorExprEither expressionSource of
        Left _ -> case firstRawCanonicalOperator definitionNames expressionSource of
          Just operator -> typeFailure Nothing
            ("canonical " ++ canonicalOperatorName operator
             ++ " cannot be used inside an untyped " ++ context
             ++ " expression; rewrite it as a structured expression")
          Nothing -> pure ()
        Right expression -> do
          actual <- infer model definitionNames baseEnvironment Nothing
            expression
          requireGeometryScalar Nothing context actual

    checkFieldAssignment name source expressionSource = do
      actual <- inferExpression definitionNames baseEnvironment source
        expressionSource
      case fieldDeclOf model name of
        Just field -> requireFieldKind source field actual
        -- Parse validation guarantees that initializer/update targets exist.
        Nothing -> pure ()

    checkExpression shadowed environment source expressionSource = do
      _ <- inferExpression shadowed environment source expressionSource
      pure ()

    inferExpression shadowed environment source expressionSource = do
      expression <- case parseTensorExprEither expressionSource of
        Left message -> typeFailure source
          ("cannot type-check expression: " ++ message)
        Right value -> Right value
      infer model shadowed environment source expression

    checkSteps _ [] = pure ()
    checkSteps environment (step : rest) = do
      expression <- case parseTensorExprEither (sEx step) of
        Left message -> typeFailure (Just (sSourceText step))
          ("cannot type-check expression: " ++ message)
        Right value -> Right value
      actual <- infer model definitionNames environment
        (Just (sSourceText step)) expression
      case (sk step, sLocalDecl step) of
        (KLocal, Just local) ->
          requireLocalKind (Just (sSourceText step)) local actual
        (KEq, _) -> case fieldDeclOf model (sNm step) of
          Just field -> requireFieldKind
            (Just (sSourceText step)) field actual
          Nothing -> pure ()
        _ -> pure ()
      let nextEnvironment = case sk step of
            KLet -> bindKind (sNm step)
              (if null (sIdx step) then actual else StaticTensor) environment
            KLocal -> case sLocalDecl step of
              Just local -> bindKind (ldName local)
                (kindFromSurface (ldKind local)) environment
              Nothing -> environment
            KEq -> environment
      checkSteps nextEnvironment rest

kindFromSurface :: Kind -> StaticKind
kindFromSurface kind = case kind of
  Scalar -> StaticScalar
  -- A 0-form is a rank-zero value, so at scalar/tensor granularity it is a
  -- scalar; positive degrees are rank >= 1.  The declared degree itself is
  -- validated against the value's dfOrder at the encode boundary.
  Form 0 -> StaticScalar
  Form _ -> StaticTensor
  Vector -> StaticTensor
  SymM -> StaticTensor
  AntiM -> StaticTensor
  Tensor2 -> StaticTensor
  -- A deferred local declares nothing statically; its metadata is read
  -- from the value during normalization.
  TensorAny -> StaticUnknown

definitionParameterBase :: String -> String
definitionParameterBase = takeWhile isAlphaNum

parameterKind :: String -> StaticKind
parameterKind parameter
  | any (`elem` parameter) "_~" = StaticTensor
  | otherwise = StaticUnknown

initializerExpressions :: Init -> [String]
initializerExpressions initializer = case initializer of
  IRaw _ _ -> []
  IVec _ components -> components
  ISym _ components -> components
  IAnti _ components -> components
  ITensor2 _ components -> components
  ICas _ expression -> [expression]
  ICasIndex _ _ expression -> [expression]

bindKind :: String -> StaticKind -> KindEnvironment -> KindEnvironment
bindKind name kind environment = (name, kind) : filter ((/= name) . fst) environment

infer
  :: Model
  -> [String]
  -> KindEnvironment
  -> Maybe SourceText
  -> TensorExpr
  -> Either OperatorTypeError StaticKind
infer model shadowed environment source expression
  -- In collocated mode this exact surface identity is the canonical scalar
  -- Laplacian spelling accepted by the effect and emission passes.  Preserve
  -- its scalar result here as well instead of exposing the intermediate
  -- differential-form kinds of d and δ.
  | selectedMode model == CollocatedMode
  , Just operand <- matchScalarDeltaExpression operatorScope expression = do
      operandKind <- inferHere operand
      requireScalar "scalar Δ" operandKind
      pure StaticScalar
  | otherwise = case expression of
    TENumber _ -> pure StaticScalar
    TEIdent name parts
      | not (null parts) -> pure StaticTensor
      | Just operator <- canonicalOperator name
      , canonicalOperatorIsVisible operatorScope operator ->
          typeFailure source
            ("canonical " ++ canonicalOperatorName operator
             ++ " cannot be used as a first-class value; apply it directly "
             ++ "to one statically typed operand")
      | otherwise -> pure (maybe StaticUnknown id (lookupValue name))
    TEUnary _ body -> inferHere body
    TECall function arguments -> inferApplication function arguments
    TEApply function arguments -> inferApplication function arguments
    TEIf condition yes no -> do
      _ <- inferHere condition
      combineBranches <$> inferHere yes <*> inferHere no
    TEAppendIndexed body parts -> do
      _ <- inferHere body
      if null parts then pure StaticUnknown else pure StaticTensor
    TEWithSymbols _ body -> inferHere body
    TEContractWith reducer body -> do
      _ <- inferHere (TEIdent reducer [])
      _ <- inferHere body
      pure StaticUnknown
    TETensorMap function body -> do
      _ <- inferHere function
      _ <- inferHere body
      pure StaticTensor
    TESubrefs body _ -> do
      _ <- inferHere body
      pure StaticTensor
    TETranspose _ body -> do
      _ <- inferHere body
      pure StaticTensor
    TEDisjoint parts ->
      combineMany <$> mapM inferHere parts
    TEDerivative _ body -> inferHere body
    TEGridDerivativeChain _ body -> do
      operandKind <- inferHere body
      requireScalar "quoted derivative" operandKind
      pure StaticScalar
    TETensorLiteral elements _ -> do
      _ <- mapM inferHere elements
      pure StaticTensor
    TEDot parts -> do
      kinds <- mapM inferHere parts
      pure (if "." `elem` shadowed
        then StaticUnknown
        else case contractedDotIndices parts kinds of
          Just [] -> StaticScalar
          Just _ -> StaticTensor
          Nothing
            | all (== StaticScalar) kinds -> StaticScalar
            | otherwise -> StaticUnknown)
    TEBinary operator lhs rhs -> do
      lhsKind <- inferHere lhs
      rhsKind <- inferHere rhs
      pure (combineBinary operator lhsKind rhsKind)
    TEGroup body -> inferHere body
  where
    inferHere = infer model shadowed environment source
    operatorScope = OperatorScope shadowed

    lookupValue name =
      lookup name environment
      `orElseMaybe` lookup (dropNextPrime name) environment

    inferApplication function arguments =
      case canonicalHead function of
        Just operator -> case arguments of
          [operand] -> do
            operandKind <- inferHere operand
            inferCanonical operator operandKind
          _ -> typeFailure source
            ("canonical " ++ canonicalOperatorName operator
             ++ " is unary, but received " ++ show (length arguments)
             ++ " operands")
        Nothing -> do
          -- Computed function values still need validation.  In particular,
          -- walking the head prevents a canonical operator hidden in a
          -- conditional or other first-class expression from bypassing its
          -- typed unary boundary.
          _ <- inferHere function
          argumentKinds <- mapM inferHere arguments
          pure (ordinaryApplicationKind function argumentKinds)

    canonicalHead function = case ungroup function of
      TEIdent name []
        | Just operator <- canonicalOperator name
        , canonicalOperatorIsVisible operatorScope operator -> Just operator
      _ -> Nothing

    -- Form operators accept every operand at scalar/tensor granularity: the
    -- degree lives in the value (dfOrder) and the library rejects non-form
    -- operands and out-of-range degrees during normalization.  Only rank
    -- facts that are exact at this granularity are recorded below.
    inferCanonical operator operandKind = case operator of
      CanonicalScalarLaplacian -> do
        requireScalar "scalar Δ" operandKind
        pure StaticScalar
      CanonicalExteriorD -> case operandKind of
        -- d of a rank-zero value is a rank-one form.
        StaticScalar -> pure StaticTensor
        other -> pure other
      CanonicalHodge -> case operandKind of
        -- hodge of a rank-zero value is the rank-`dimension` volume form.
        StaticScalar -> pure StaticTensor
        -- hodge of a top-degree form is rank zero, so the rank of a tensor
        -- operand's result is unknown without its degree.
        _ -> pure StaticUnknown
      CanonicalCodifferential -> case operandKind of
        -- δ on degree zero is zero.
        StaticScalar -> pure StaticScalar
        -- δ of a 1-form is rank zero; higher degrees keep tensor rank.
        _ -> pure StaticUnknown
      -- Δ_H preserves both degree and rank.
      CanonicalHodgeLaplacian -> pure operandKind

    requireScalar operator operandKind = case operandKind of
      StaticScalar -> pure ()
      StaticUnknown -> typeFailure source
        (operator ++ " requires a statically known scalar operand; "
         ++ "untyped definition parameters cannot cross this operator boundary")
      _ -> typeFailure source
        (operator ++ " requires a scalar operand, but received "
         ++ describeKind operandKind)

    ordinaryApplicationKind function argumentKinds =
      case ungroup function of
        TEIdent name []
          | name `elem` shadowed -> StaticUnknown
          | name `elem` scalarFunctions
          , all (== StaticScalar) argumentKinds -> StaticScalar
          | name `elem` ["lap"]
          , [StaticScalar] <- argumentKinds -> StaticScalar
          | name `elem` ["grad", "dGrad"]
          , [StaticScalar] <- argumentKinds -> StaticTensor
          | name == "norm2"
          , [_] <- argumentKinds -> StaticScalar
          -- Without tensor rank in StaticKind we cannot distinguish vector
          -- divergence (scalar) from higher-rank divergence.  Preserve the
          -- unknown kind so it cannot cross a typed canonical boundary.
          | name == "divg"
          , [_] <- argumentKinds -> StaticUnknown
          | name == "resample"
          , kind : _ <- argumentKinds -> kind
          | Just _ <- derivativeOpParts name
          , [kind] <- argumentKinds -> kind
          | Just _ <- sbpxOpParts name
          , [kind] <- argumentKinds -> kind
          -- ∂/∂ by one coordinate keeps the operand's kind; ∂/∂ by the
          -- ambient coordinates vector adds a derivative axis, so only
          -- the unknown kind is safe without tensor rank.
          | name == analyticDerivativeName
          , [kind, StaticScalar] <- argumentKinds -> kind
          | name == analyticDerivativeName -> StaticUnknown
        _ -> StaticUnknown

    scalarFunctions =
      [ "sin", "cos", "tan", "asin", "acos", "atan", "atan2"
      , "sinh", "cosh", "tanh", "exp", "log", "sqrt", "pow", "fabs"
      ]

combineBranches :: StaticKind -> StaticKind -> StaticKind
combineBranches lhs rhs
  | lhs == rhs = lhs
  | otherwise = StaticUnknown

combineMany :: [StaticKind] -> StaticKind
combineMany [] = StaticScalar
combineMany (kind : rest)
  | all (== kind) rest = kind
  | otherwise = StaticUnknown

combineBinary :: String -> StaticKind -> StaticKind -> StaticKind
combineBinary operator lhs rhs
  | operator `elem` ["==", "!=", "<", ">", "<=", ">=", "&&", "||"] =
      StaticScalar
  | lhs == rhs = lhs
  | operator `elem` ["*", "/"] && lhs == StaticScalar = rhs
  | operator == "*" && rhs == StaticScalar = lhs
  | lhs == StaticUnknown || rhs == StaticUnknown = StaticUnknown
  | otherwise = StaticUnknown

describeKind :: StaticKind -> String
describeKind kind = case kind of
  StaticScalar -> "scalar"
  StaticTensor -> "ordinary tensor"
  StaticUnknown -> "an unknown value"

requireLocalKind
  :: Maybe SourceText
  -> LocalDecl
  -> StaticKind
  -> Either OperatorTypeError ()
requireLocalKind source local actual
  | actual == StaticUnknown = pure ()
  | declared == StaticUnknown = pure ()
  | localKindsCompatible declared actual = pure ()
  | otherwise = typeFailure source
      ("local " ++ ldName local ++ " declares " ++ describeKind declared
       ++ ", but its RHS has " ++ describeKind actual ++ " kind")
  where
    declared = kindFromSurface (ldKind local)

requireFieldKind
  :: Maybe SourceText
  -> FieldDecl
  -> StaticKind
  -> Either OperatorTypeError ()
requireFieldKind source field actual
  | actual == StaticUnknown = pure ()
  | localKindsCompatible declared actual = pure ()
  | otherwise = typeFailure source
      ("field " ++ fdName field ++ " declares " ++ describeKind declared
       ++ ", but its RHS has " ++ describeKind actual ++ " kind")
  where
    declared = kindFromSurface (fdKind field)

requireGeometryScalar
  :: Maybe SourceText
  -> String
  -> StaticKind
  -> Either OperatorTypeError ()
requireGeometryScalar _ _ StaticUnknown = pure ()
requireGeometryScalar _ _ StaticScalar = pure ()
requireGeometryScalar source context actual = typeFailure source
  (context ++ " expression requires a scalar value, but received "
   ++ describeKind actual)

localKindsCompatible :: StaticKind -> StaticKind -> Bool
localKindsCompatible declared actual = declared == actual

dropNextPrime :: String -> String
dropNextPrime name = case reverse name of
  '\'' : rest -> reverse rest
  _ -> name

ungroup :: TensorExpr -> TensorExpr
ungroup (TEGroup expression) = ungroup expression
ungroup expression = expression

orElseMaybe :: Maybe value -> Maybe value -> Maybe value
orElseMaybe (Just value) _ = Just value
orElseMaybe Nothing fallback = fallback

typeFailure :: Maybe SourceText -> String -> Either OperatorTypeError value
typeFailure source message = Left (OperatorTypeError source message)

-- Raw Egison bodies have no TensorExpr application tree, so an untyped
-- parameter cannot be proved to satisfy a canonical operator signature.
-- Strings are masked to keep diagnostic text inert.  Indexed Unicode delta
-- has already become the compiler-owned Kronecker identifier and therefore
-- is not confused with the unindexed canonical codifferential here.
firstRawCanonicalOperator :: [String] -> String -> Maybe CanonicalOperator
firstRawCanonicalOperator shadowed source =
  firstCanonical (egisonIdentifiers (maskEgisonNonCode source))
  where
    firstCanonical [] = Nothing
    firstCanonical (name : rest) = case canonicalOperator name of
      Just operator
        | canonicalOperatorIsVisible (OperatorScope shadowed) operator ->
            Just operator
      Nothing -> firstCanonical rest
      _ -> firstCanonical rest

contractedDotIndices :: [TensorExpr] -> [StaticKind] -> Maybe [IxPart]
contractedDotIndices expressions kinds =
  contractIndices . concat <$> sequence
    (zipWith explicitIndices expressions kinds)
  where
    explicitIndices expression kind = case ungroup expression of
      TEIdent _ parts
        | not (null parts) -> Just parts
      TEAppendIndexed _ parts
        | not (null parts) -> Just parts
      _
        | kind == StaticScalar -> Just []
        | otherwise -> Nothing

contractIndices :: [IxPart] -> [IxPart]
contractIndices [] = []
contractIndices (part : rest) =
  case removeOpposite part rest of
    Just remaining -> contractIndices remaining
    Nothing -> part : contractIndices rest
  where
    removeOpposite _ [] = Nothing
    removeOpposite (IxPart variance name) (candidate@(IxPart other name') : xs)
      | name == name' && variance /= other = Just xs
      | otherwise = (candidate :) <$> removeOpposite part xs
