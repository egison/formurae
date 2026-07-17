module Formurae.Post.Compile
  ( PostError(..)
  , DerivativeMetadataError(..)
  , WideDerivativeError(..)
  , GridWholeDerivativeError(..)
  , wideDerivativeOperationId
  , gridWholeDerivativeOperationId
  , compileProgram
  ) where

import Data.List (find)
import qualified Data.Ratio as Ratio

import qualified Formurae.FEIR.PrimitiveBindings as Primitives
import Formurae.FEIR.Syntax
import qualified Formurae.Post.BackendPlan as Backend
import Formurae.Post.ExplicitStencil
import Formurae.Post.FMR
import Formurae.Post.Location
import Formurae.Post.Normalize (normalizeExpr)
import Formurae.Post.PrimitiveContract
import Formurae.Post.Profile
import Formurae.Post.Stencil
  ( StaggeredStencil
  , StencilError
  , centeredTaylorAtRadius
  , centeredWeights
  , staggeredTaylorAtPairs
  , staggeredTwiceWeights
  )

data DerivativeMetadataError
  = DerivativeMissingAttribute AttributeId
  | DerivativeDuplicateAttribute AttributeId
  | DerivativeUnknownAttribute AttributeId
  | DerivativeInvalidAttribute AttributeId AttributeValue
  | DerivativeInvalidResultBasis Basis
  | DerivativeInvalidOperand
  | DerivativeOrderOutOfRange Integer
  | DerivativeRadiusOutOfRange Integer
  deriving (Eq, Show)

data WideDerivativeError
  = WideMetadataError DerivativeMetadataError
  | WideOrderExceedsDiameter Int Int
  | WideStencilFailure StencilError
  deriving (Eq, Show)

data GridWholeDerivativeError
  = GridWholeMetadataError DerivativeMetadataError
  | GridWholeOrderMustBeOne Int
  | GridWholeRadiusMustBeOne Int
  | GridWholeStencilFailure StencilError
  deriving (Eq, Show)

wideDerivativeOperationId :: OpId
wideDerivativeOperationId = Primitives.derivativeCoordinateWideOpId

gridWholeDerivativeOperationId :: OpId
gridWholeDerivativeOperationId = Primitives.derivativeGridWholeOpId

orderedDerivativeOperationId :: OpId
orderedDerivativeOperationId = Primitives.derivativeOrderedOpId

resampleOperationId :: OpId
resampleOperationId = Primitives.resampleExplicitOpId

data PostError
  = PostAtOrigin OriginId PostError
  | PostBackendPlanError Backend.BackendPlanError
  | PostFMRError FMRError
  | PostLocationError LocationError
  | PostUnknownField FieldId
  | PostUnknownParameter ParamId
  | PostUnknownFunction FunctionId
  | PostUnknownAxis AxisId
  | PostUnknownBinding NodeId
  | PostTensorBindingUsedAsScalar NodeId
  | PostMissingTensorComponent Basis
  | PostNonScalarComponent Basis [Int]
  | PostUnsupportedDerivative FieldJet
  | PostUnsupportedOpaque OpId
  | PostWideDerivativeError SemanticKey WideDerivativeError
  | PostGridWholeDerivativeError SemanticKey GridWholeDerivativeError
  | PostPrimitiveContractError SemanticKey PrimitiveContractError
  | PostExplicitStencilError SemanticKey ExplicitStencilError
  | PostDerivativeLatticeMismatch SemanticKey LatticeClass LatticeClass
  | PostProfileError ProfileError
  | PostInvalidReferencePlacement Placement Placement
  | PostInvalidTarget FieldTarget
  | PostInvalidAuxiliaryPlan String
  | PostDuplicateAssignment String
  deriving (Eq, Show)

data CompileEnvironment = CompileEnvironment
  { compileProgramInput :: FEProgram
  , compileBindings :: [(NodeId, FEValue)]
  }

compileProgram :: FEProgram -> Either PostError FProgram
compileProgram program = do
  -- No FEIR operation carries a materializing storage effect any more;
  -- the plan step remains as program-level validation of the opaque
  -- occurrences (pure-local requests only, no effects in initializers).
  mapBackendPlanError (Backend.planBackendEffects program)
  let initialEnvironment = CompileEnvironment program []
  userStateStorage <- concatMapM (fieldStorage program) stateFields
  initializerAssignments <- concatMapM (compileInitializer initialEnvironment)
    (feProgramInitializers program)
  (bindings, frozenInitializers, stepAssignments, frozenStateNames) <-
    compileActions initialEnvironment (feProgramStepActions program)
  let _ = bindings
      parameters =
        [ (parameterDeclBackendName parameter, parameterDeclRawValue parameter)
        | parameter <- feProgramParameters program
        ]
      externalHelpers =
        map ("extern function :: " ++) (uniqueValues
          [ functionDeclBackendName function
          | function <- feProgramFunctions program
          , functionDeclClass function == ExternalFunction
            || (functionDeclClass function == IntrinsicFunction
                && (functionDeclId function `elem` usedFunctionIds
                    || functionDeclOrigin function /= Nothing))
          ])
      usedFunctionIds = uniqueValues (programFunctionIds program)
      rawHelpers = map rawHelperText (feProgramRawHelpers program)
      allInitializers = initializerAssignments ++ frozenInitializers
      allStepAssignments = stepAssignments
  ensureUniqueTargets (allInitializers ++ allStepAssignments)
  Right FProgram
    { fProgramDimension = feProgramDimension program
    , fProgramAxes = map axisDeclSourceName (feProgramAxes program)
    , fProgramParameters = parameters
    , fProgramHelpers = externalHelpers ++ rawHelpers
    , fProgramStateStorage = userStateStorage ++ frozenStateNames
    , fProgramInitializers = allInitializers
    , fProgramStepAssignments = allStepAssignments
    }
  where
    stateFields =
      [ field
      | field <- feProgramFields program
      , logicalFieldLifetime field == UserStateLifetime
      ]

compileActions
    :: CompileEnvironment
    -> [FEAction]
    -> Either PostError
         ( [(NodeId, FEValue)]
         , [FAssignment]
         , [FAssignment]
         , [String]
         )
compileActions environment actions = go environment [] ([], [], []) actions
  where
    -- Materializations and updates enter one stream in source order;
    -- separating them would change the meaning of references to earlier
    -- NextTime values.  Frozen materializations (geometry-only locals)
    -- contribute initializer assignments and state names on the side.
    go _current bindings (initializers, assignments, frozenState) [] =
      Right (reverse bindings, initializers, assignments, frozenState)
    go current bindings (initializers, assignments, frozenState) (action : rest) =
      case action of
        BindValue nodeId value _ ->
          let nextEnvironment = current
                { compileBindings = (nodeId, value) : compileBindings current }
          in go nextEnvironment ((nodeId, value) : bindings)
               (initializers, assignments, frozenState) rest
        Materialize fieldId value materializeOrigin -> do
          (frozenInitializers, materializationAssignments, frozenNames) <-
            withPostOrigin materializeOrigin $ do
              field <- lookupField current fieldId
              compileMaterialization current field value
          go current bindings
            ( initializers ++ frozenInitializers
            , assignments ++ materializationAssignments
            , frozenState ++ frozenNames
            ) rest
        UpdateField equation -> do
          updateAssignments <- compileEquation current StepEquation equation
          go current bindings
            ( initializers
            , assignments ++ updateAssignments
            , frozenState
            ) rest

programFunctionIds :: FEProgram -> [FunctionId]
programFunctionIds program =
  concatMap initializerFunctionIds (feProgramInitializers program)
  ++ concatMap actionFunctionIds (feProgramStepActions program)

initializerFunctionIds :: FEInitializer -> [FunctionId]
initializerFunctionIds initializer =
  case initializer of
    AnalyticInitializer equation -> tensorFunctionIds (feEquationRhs equation)
    RawInitializer _ _ _ -> []

actionFunctionIds :: FEAction -> [FunctionId]
actionFunctionIds action =
  case action of
    BindValue _ value _ -> valueFunctionIds value
    Materialize _ value _ -> valueFunctionIds value
    UpdateField equation -> tensorFunctionIds (feEquationRhs equation)

valueFunctionIds :: FEValue -> [FunctionId]
valueFunctionIds value =
  case value of
    ScalarValue scalar -> scalarFunctionIds scalar
    TensorValue tensor -> tensorFunctionIds tensor

tensorFunctionIds :: TensorNF -> [FunctionId]
tensorFunctionIds tensor = concatMap
  (scalarFunctionIds . snd) (tensorNFComponents tensor)

scalarFunctionIds :: ScalarNF -> [FunctionId]
scalarFunctionIds scalar =
  case scalar of
    Exact _ _ -> []
    NamedConstant _ -> []
    Parameter _ -> []
    Coordinate _ -> []
    Add terms -> concatMap recurse terms
    Mul factors -> concatMap recurse factors
    Div numerator denominator -> recurse numerator ++ recurse denominator
    Pow base exponentValue -> recurse base ++ recurse exponentValue
    Intrinsic functionId arguments ->
      functionId : concatMap recurse arguments
    AnalyticCall functionId arguments ->
      functionId : concatMap recurse arguments
    Select predicate yes no ->
      predicateFunctionIds predicate ++ recurse yes ++ recurse no
    FieldJet _ -> []
    OpaqueDiscrete opaque -> concatMap valueFunctionIds
      (opaqueDiscreteOperands opaque)
    Ref _ -> []
  where
    recurse = scalarFunctionIds

predicateFunctionIds :: PredicateNF -> [FunctionId]
predicateFunctionIds predicate =
  case predicate of
    BoolExact _ -> []
    Compare _ lhs rhs -> recurse lhs ++ recurse rhs
    Not body -> predicateFunctionIds body
    And bodies -> concatMap predicateFunctionIds bodies
    Or bodies -> concatMap predicateFunctionIds bodies
  where
    recurse = scalarFunctionIds

data EquationStage = InitializerEquation | StepEquation

compileInitializer
    :: CompileEnvironment -> FEInitializer -> Either PostError [FAssignment]
compileInitializer environment initializer =
  case initializer of
    AnalyticInitializer equation ->
      compileEquation environment InitializerEquation equation
    RawInitializer target raw origin -> withPostOrigin origin $ do
      (field, basis) <- resolveTarget environment target
      name <- mapFMRError (storageName field basis)
      indices <- indexNames environment
      case target of
        FieldComponentTarget _ CurrentTime _ ->
          Right [FAssignment (InitialTarget name indices) (FRawExpr raw)]
        WholeFieldTarget _ CurrentTime ->
          Right [FAssignment (InitialTarget name indices) (FRawExpr raw)]
        _ -> Left (PostInvalidTarget target)

compileEquation
    :: CompileEnvironment
    -> EquationStage
    -> FEEquation
    -> Either PostError [FAssignment]
compileEquation environment stage equation = withPostOrigin
  (feEquationOrigin equation) $ do
  field <- targetField environment (feEquationTarget equation)
  targetBases <- targetBasesFor environment field (feEquationTarget equation)
  mapM (compileBasis field) targetBases
  where
    compileBasis field basis = do
      targetPlacement <- mapLocationError
        (componentPlacement (programDimension environment)
          (logicalFieldPolicy field) basis)
      component <- tensorComponent basis (feEquationRhs equation)
      expression <- lowerScalar environment targetPlacement component
      name <- mapFMRError (storageName field basis)
      case stage of
        InitializerEquation -> do
          indices <- indexNames environment
          Right (FAssignment (InitialTarget name indices) (normalizeExpr expression))
        StepEquation ->
          Right (FAssignment (StepUpdateTarget name) (normalizeExpr expression))

-- A materialization splits by what its value references.  Components that
-- reference field state are step bindings recomputed every step.  A value
-- built purely from geometry (no field jets, no discrete operations, no
-- step references) is frozen instead: it becomes persistent state,
-- initialized once from the coordinates and carried unchanged through the
-- step, exactly like the geometry coefficient fields of the backend
-- request plans.  Persistence also gives it the declared boundary
-- treatment (mirror and fixed walls reflect state arrays), which a
-- per-step recomputation from the raw grid index cannot express.
compileMaterialization
    :: CompileEnvironment
    -> LogicalFieldDecl
    -> FEValue
    -> Either PostError ([FAssignment], [FAssignment], [String])
compileMaterialization environment field value = do
  bases <- mapFMRError (independentBases (programDimension environment) field)
  if valueIsGeometryOnly value
    then do
      frozen <- mapM compileFrozenBasis bases
      Right ( [initializer | (initializer, _, _) <- frozen]
            , [carry | (_, carry, _) <- frozen]
            , [name | (_, _, name) <- frozen]
            )
    else do
      assignments <- mapM compileBasis bases
      Right ([], assignments, [])
  where
    componentScalar basis =
      case value of
        ScalarValue expression
          | basis == Basis [] -> Right expression
          | otherwise -> Left (PostNonScalarComponent basis [])
        TensorValue tensor -> tensorComponent basis tensor
    compileBasis basis = do
      targetPlacement <- mapLocationError
        (componentPlacement (programDimension environment)
          (logicalFieldPolicy field) basis)
      scalar <- componentScalar basis
      expression <- lowerScalar environment targetPlacement scalar
      name <- mapFMRError (storageName field basis)
      Right (FAssignment (StepBindingTarget name) (normalizeExpr expression))
    compileFrozenBasis basis = do
      targetPlacement <- mapLocationError
        (componentPlacement (programDimension environment)
          (logicalFieldPolicy field) basis)
      scalar <- componentScalar basis
      expression <- lowerScalar environment targetPlacement scalar
      name <- mapFMRError (storageName field basis)
      indices <- indexNames environment
      reference <- gridReference environment name
        (replicate (programDimension environment) 0)
      Right ( FAssignment (InitialTarget name indices)
                (normalizeExpr expression)
            , FAssignment (StepUpdateTarget name) reference
            , name
            )

valueIsGeometryOnly :: FEValue -> Bool
valueIsGeometryOnly value =
  case value of
    ScalarValue scalar -> scalarIsGeometryOnly scalar
    TensorValue tensor ->
      all (scalarIsGeometryOnly . snd) (tensorNFComponents tensor)

scalarIsGeometryOnly :: ScalarNF -> Bool
scalarIsGeometryOnly scalar =
  case scalar of
    Exact _ _ -> True
    NamedConstant _ -> True
    Parameter _ -> True
    Coordinate _ -> True
    Add terms -> all recurse terms
    Mul factors -> all recurse factors
    Div numerator denominator -> recurse numerator && recurse denominator
    Pow base exponentValue -> recurse base && recurse exponentValue
    Intrinsic _ arguments -> all recurse arguments
    AnalyticCall _ arguments -> all recurse arguments
    Select predicate yes no ->
      predicateIsGeometryOnly predicate && recurse yes && recurse no
    FieldJet _ -> False
    OpaqueDiscrete _ -> False
    Ref _ -> False
  where
    recurse = scalarIsGeometryOnly

predicateIsGeometryOnly :: PredicateNF -> Bool
predicateIsGeometryOnly predicate =
  case predicate of
    BoolExact _ -> True
    Compare _ lhs rhs -> scalarIsGeometryOnly lhs && scalarIsGeometryOnly rhs
    Not body -> predicateIsGeometryOnly body
    And bodies -> all predicateIsGeometryOnly bodies
    Or bodies -> all predicateIsGeometryOnly bodies


gridReference
    :: CompileEnvironment -> String -> [Int] -> Either PostError FExpr
gridReference environment name offsets = do
  indices <- indexNames environment
  if length offsets == length indices
    then Right (FGridReference name
      (zipWith GridIndex indices (map fromIntegral offsets)))
    else Left (PostInvalidAuxiliaryPlan
      ("grid offset dimension mismatch for " ++ name))

axisStep :: CompileEnvironment -> AxisId -> Either PostError FExpr
axisStep environment axisId = do
  axis <- lookupAxis environment axisId
  Right (FVariable ("d" ++ axisDeclSourceName axis))

lowerScalar
    :: CompileEnvironment -> Placement -> ScalarNF -> Either PostError FExpr
lowerScalar environment targetPlacement =
  lowerScalarShifted environment targetPlacement
    (replicate (programDimension environment) 0)

lowerScalarShifted
    :: CompileEnvironment
    -> Placement
    -> [Int]
    -> ScalarNF
    -> Either PostError FExpr
lowerScalarShifted environment targetPlacement sampleOffsets scalar =
  case scalar of
    Exact numerator denominator -> Right (FExact numerator denominator)
    NamedConstant constantName -> Right (FNamedConstant constantName)
    Parameter parameterId ->
      FVariable . parameterDeclBackendName <$> lookupParameter environment parameterId
    Coordinate axisId ->
      lowerCoordinateShifted environment targetPlacement sampleOffsets axisId
    Add terms -> FAdd <$> mapM recurse terms
    Mul factors -> FMul <$> mapM recurse factors
    Div numerator denominator ->
      FDiv <$> recurse numerator <*> recurse denominator
    Pow base exponentValue ->
      FPow <$> recurse base <*> recurse exponentValue
    Intrinsic functionId arguments ->
      lowerCallShifted environment targetPlacement sampleOffsets
        functionId arguments
    AnalyticCall functionId arguments ->
      lowerCallShifted environment targetPlacement sampleOffsets
        functionId arguments
    Select predicate yes no ->
      FSelect
        <$> lowerPredicateShifted environment targetPlacement
              sampleOffsets predicate
        <*> recurse yes
        <*> recurse no
    FieldJet jet
      | null (fieldJetMultiIndex jet) ->
          lowerFieldReferenceShifted environment targetPlacement
            sampleOffsets jet
      | otherwise -> lowerFieldDerivativeShifted environment targetPlacement
          sampleOffsets jet
    OpaqueDiscrete opaque ->
      lowerOpaqueShifted environment targetPlacement sampleOffsets opaque
    Ref nodeId -> do
      value <- lookupBinding environment nodeId
      case value of
        ScalarValue expression -> recurse expression
        TensorValue _ -> Left (PostTensorBindingUsedAsScalar nodeId)
  where
    recurse = lowerScalarShifted environment targetPlacement sampleOffsets

lowerOpaqueShifted
    :: CompileEnvironment
    -> Placement
    -> [Int]
    -> OpaqueDiscrete
    -> Either PostError FExpr
lowerOpaqueShifted environment targetPlacement sampleOffsets opaque
  | opaqueDiscreteOpId opaque == wideDerivativeOperationId =
      lowerWideDerivative environment targetPlacement sampleOffsets opaque
  | opaqueDiscreteOpId opaque == gridWholeDerivativeOperationId =
      lowerGridWholeDerivative environment targetPlacement sampleOffsets opaque
  | opaqueDiscreteOpId opaque == orderedDerivativeOperationId =
      lowerOrderedDerivative environment targetPlacement sampleOffsets opaque
  | opaqueDiscreteOpId opaque == resampleOperationId =
      lowerResample environment targetPlacement sampleOffsets opaque
  | otherwise = Left (PostUnsupportedOpaque (opaqueDiscreteOpId opaque))

lowerOrderedDerivative
    :: CompileEnvironment
    -> Placement
    -> [Int]
    -> OpaqueDiscrete
    -> Either PostError FExpr
lowerOrderedDerivative environment targetPlacement sampleOffsets opaque = do
  request <- mapPrimitiveContract opaque
    (parseOrderedDerivativeRequest (programDimension environment) opaque)
  location <- inferScalarLocation environment
    (opaqueDiscreteSemanticKey opaque) (orderedDerivativeOperand request)
  let sourcePlacement = case scalarLocationCapability location of
        LocatedCapability placement -> placement
        ConstantCapability -> targetPlacement
        SampleableCapability -> targetPlacement
      staggered = scalarLocationLattice location == Just StaggeredLattice
  plan <- mapExplicitStencil opaque
    (orderedFirstDerivativeStencil staggered
      (orderedDerivativeAxes request) sourcePlacement)
  if orderedStencilTarget plan == targetPlacement
    then Right ()
    else mapExplicitStencil opaque (Left
      (ExplicitStencilTargetMismatch targetPlacement
        (orderedStencilTarget plan)))
  samples <- mapM (lowerSample sourcePlacement
      (orderedDerivativeOperand request))
    (orderedStencilSamples plan)
  denominatorFactors <- mapM (axisStep environment)
    (orderedStencilDenominatorAxes plan)
  let denominator = case denominatorFactors of
        [] -> FExact 1 1
        [factor] -> factor
        factors -> FMul factors
  Right (normalizeExpr (FDiv
    (normalizeExpr (FAdd samples)) (normalizeExpr denominator)))
  where
    lowerSample sourcePlacement operand (offsets, coefficient) = do
      shifted <- addSampleOffsets sampleOffsets offsets
      sample <- lowerScalarShifted environment sourcePlacement shifted
        operand
      Right (normalizeExpr (FMul [exactExpr coefficient, sample]))

lowerResample
    :: CompileEnvironment
    -> Placement
    -> [Int]
    -> OpaqueDiscrete
    -> Either PostError FExpr
lowerResample environment targetPlacement sampleOffsets opaque = do
  request <- mapPrimitiveContract opaque
    (parseResampleRequest (programDimension environment) opaque)
  let explicitTarget = placementFromBits (resampleTargetBits request)
  if explicitTarget == targetPlacement
    then Right ()
    else mapExplicitStencil opaque (Left
      (ExplicitStencilTargetMismatch targetPlacement explicitTarget))
  location <- inferScalarLocation environment
    (opaqueDiscreteSemanticKey opaque) (resampleOperand request)
  case scalarLocationCapability location of
    ConstantCapability ->
      lowerScalarShifted environment explicitTarget sampleOffsets
        (resampleOperand request)
    SampleableCapability ->
      lowerScalarShifted environment explicitTarget sampleOffsets
        (resampleOperand request)
    LocatedCapability sourcePlacement -> do
      stencil <- mapExplicitStencil opaque
        (resampleLinearStencil sourcePlacement explicitTarget)
      samples <- mapM (lowerSample sourcePlacement (resampleOperand request))
        stencil
      Right (normalizeExpr (FAdd samples))
  where
    lowerSample sourcePlacement operand (offsets, coefficient) = do
      shifted <- addSampleOffsets sampleOffsets offsets
      sample <- lowerScalarShifted environment sourcePlacement shifted operand
      Right (normalizeExpr (FMul [exactExpr coefficient, sample]))

placementFromBits :: [Bool] -> Placement
placementFromBits = Placement . map
  (\bit -> if bit then HalfPoint else IntegerPoint)

addSampleOffsets :: [Int] -> [Int] -> Either PostError [Int]
addSampleOffsets lhs rhs
  | length lhs == length rhs = Right (zipWith (+) lhs rhs)
  | otherwise = Left (PostInvalidAuxiliaryPlan
      "explicit stencil sample offset dimension mismatch")

data CoordinateDerivativeRequest = CoordinateDerivativeRequest
  { derivativeRequestOrder :: Int
  , derivativeRequestAxis :: AxisId
  , derivativeRequestRadius :: Int
  , derivativeRequestOperand :: ScalarNF
  }

data ScalarLocationInfo = ScalarLocationInfo
  { scalarLocationCapability :: Capability
  , scalarLocationLattice :: Maybe LatticeClass
  }

lowerWideDerivative
    :: CompileEnvironment
    -> Placement
    -> [Int]
    -> OpaqueDiscrete
    -> Either PostError FExpr
lowerWideDerivative environment targetPlacement sampleOffsets opaque = do
  request <- mapWideError opaque
    (mapLeft WideMetadataError (parseDerivativeRequest opaque))
  validateWideRequest opaque request
  _ <- lookupAxis environment (derivativeRequestAxis request)
  location <- inferScalarLocation environment
    (opaqueDiscreteSemanticKey opaque) (derivativeRequestOperand request)
  let sourcePlacement =
        case scalarLocationCapability location of
          LocatedCapability placement -> placement
          ConstantCapability -> targetPlacement
          SampleableCapability -> targetPlacement
  naturalTarget <- derivativeNaturalTarget request sourcePlacement
    (scalarLocationLattice location)
  if naturalTarget == targetPlacement
    then Right ()
    else Left (PostInvalidReferencePlacement targetPlacement naturalTarget)
  weights <-
    if naturalTarget == sourcePlacement
      then do
        let accuracy = maximalCenteredAccuracy
              (derivativeRequestOrder request) (derivativeRequestRadius request)
        stencil <- mapWideError opaque
          (mapLeft WideStencilFailure
            (centeredTaylorAtRadius
              (derivativeRequestOrder request) accuracy
              (derivativeRequestRadius request)))
        Right (centeredWeights stencil)
      else do
        -- Odd staggered orders land on the toggled sub-lattice; the samples
        -- stay on the operand's own sub-lattice, so the attribute radius
        -- counts sample pairs and the effective radius is radius − 1/2.
        let pairs = derivativeRequestRadius request
            accuracy = maximalStaggeredAccuracy
              (derivativeRequestOrder request) pairs
        stencil <- mapWideError opaque
          (mapLeft WideStencilFailure
            (staggeredTaylorAtPairs
              (derivativeRequestOrder request) accuracy pairs))
        staggeredStorageWeights sourcePlacement
          (derivativeRequestAxis request) stencil
  samples <- mapM (lowerSample request sourcePlacement) weights
  step <- axisStep environment (derivativeRequestAxis request)
  let numerator = normalizeExpr (FAdd samples)
      denominator = FPow step
        (FExact (toInteger (derivativeRequestOrder request)) 1)
  Right (normalizeExpr (FDiv numerator denominator))
  where
    lowerSample request sourcePlacement (offset, coefficient) = do
      let AxisId axisNumber = derivativeRequestAxis request
          offsets = adjustOffset axisNumber offset sampleOffsets
      sample <- lowerScalarShifted environment sourcePlacement offsets
        (derivativeRequestOperand request)
      Right (normalizeExpr (FMul [exactExpr coefficient, sample]))

lowerGridWholeDerivative
    :: CompileEnvironment
    -> Placement
    -> [Int]
    -> OpaqueDiscrete
    -> Either PostError FExpr
lowerGridWholeDerivative environment targetPlacement sampleOffsets opaque = do
  request <- mapGridWholeError opaque
    (mapLeft GridWholeMetadataError (parseDerivativeRequest opaque))
  validateGridWholeRequest opaque request
  _ <- lookupAxis environment (derivativeRequestAxis request)
  location <- inferScalarLocation environment
    (opaqueDiscreteSemanticKey opaque) (derivativeRequestOperand request)
  let sourcePlacement =
        case scalarLocationCapability location of
          LocatedCapability placement -> placement
          ConstantCapability -> targetPlacement
          SampleableCapability -> targetPlacement
  naturalTarget <- derivativeNaturalTarget request sourcePlacement
    (scalarLocationLattice location)
  if naturalTarget == targetPlacement
    then Right ()
    else Left (PostInvalidReferencePlacement targetPlacement naturalTarget)
  weights <- gridWholeWeights opaque request sourcePlacement
    (scalarLocationLattice location)
  samples <- mapM (lowerSample request sourcePlacement) weights
  step <- axisStep environment (derivativeRequestAxis request)
  Right (normalizeExpr
    (FDiv (normalizeExpr (FAdd samples)) step))
  where
    lowerSample request sourcePlacement (offset, coefficient) = do
      let AxisId axisNumber = derivativeRequestAxis request
          offsets = adjustOffset axisNumber offset sampleOffsets
      sample <- lowerScalarShifted environment sourcePlacement offsets
        (derivativeRequestOperand request)
      Right (normalizeExpr (FMul [exactExpr coefficient, sample]))

gridWholeWeights
    :: OpaqueDiscrete
    -> CoordinateDerivativeRequest
    -> Placement
    -> Maybe LatticeClass
    -> Either PostError [(Int, Rational)]
gridWholeWeights opaque request sourcePlacement lattice =
  case lattice of
    Just StaggeredLattice ->
      let AxisId axisNumber = derivativeRequestAxis request
      in yeeFirstWeights sourcePlacement axisNumber
    _ -> do
      stencil <- mapGridWholeError opaque
        (mapLeft GridWholeStencilFailure
          (centeredTaylorAtRadius 1 2 1))
      Right (centeredWeights stencil)

validateGridWholeRequest
    :: OpaqueDiscrete
    -> CoordinateDerivativeRequest
    -> Either PostError ()
validateGridWholeRequest opaque request = do
  if derivativeRequestOrder request == 1
    then Right ()
    else mapGridWholeError opaque
      (Left (GridWholeOrderMustBeOne (derivativeRequestOrder request)))
  if derivativeRequestRadius request == 1
    then Right ()
    else mapGridWholeError opaque
      (Left (GridWholeRadiusMustBeOne (derivativeRequestRadius request)))

validateWideRequest
    :: OpaqueDiscrete
    -> CoordinateDerivativeRequest
    -> Either PostError ()
validateWideRequest opaque request =
  if toInteger (derivativeRequestOrder request)
      <= 2 * toInteger (derivativeRequestRadius request)
    then Right ()
    else mapWideError opaque (Left (WideOrderExceedsDiameter
      (derivativeRequestOrder request) (derivativeRequestRadius request)))

derivativeNaturalTarget
    :: CoordinateDerivativeRequest
    -> Placement
    -> Maybe LatticeClass
    -> Either PostError Placement
derivativeNaturalTarget request sourcePlacement lattice =
  case lattice of
    Just StaggeredLattice -> mapLocationError
      (derivativePlacement
        [(derivativeRequestAxis request, fromIntegral (derivativeRequestOrder request))]
        sourcePlacement)
    _ -> Right sourcePlacement

maximalCenteredAccuracy :: Int -> Int -> Int
maximalCenteredAccuracy derivativeOrder radius =
  2 * radius - derivativeOrder
  + if even derivativeOrder then 2 else 1

-- | Half-offset symmetric stencils are parity-matched for odd orders, so
-- they carry the same +2 bonus as even orders on integer offsets:
-- 2 * (pairs − 1/2) − order + 2.
maximalStaggeredAccuracy :: Int -> Int -> Int
maximalStaggeredAccuracy derivativeOrder pairs =
  2 * pairs - derivativeOrder + 1

parseDerivativeRequest
    :: OpaqueDiscrete
    -> Either DerivativeMetadataError CoordinateDerivativeRequest
parseDerivativeRequest opaque = do
  validateAttributeSet attributes
  if opaqueDiscreteResultBasis opaque == Basis []
    then Right ()
    else Left (DerivativeInvalidResultBasis (opaqueDiscreteResultBasis opaque))
  operand <-
    case opaqueDiscreteOperands opaque of
      [ScalarValue scalar] -> Right scalar
      _ -> Left DerivativeInvalidOperand
  orderValue <- requireDerivativeAttribute orderAttribute attributes
  order <- parsePositiveNatural DerivativeOrderOutOfRange orderAttribute orderValue
  axesValue <- requireDerivativeAttribute orderedAxesAttribute attributes
  axis <-
    case axesValue of
      AttributeValues [AttributeAxis axisId] -> Right axisId
      _ -> Left (DerivativeInvalidAttribute orderedAxesAttribute axesValue)
  radiusValue <- requireDerivativeAttribute radiusAttribute attributes
  radius <- parsePositiveNatural DerivativeRadiusOutOfRange
    radiusAttribute radiusValue
  if radius <= (maxBound - 2) `div` 2
    then Right ()
    else Left (DerivativeRadiusOutOfRange (toInteger radius))
  Right CoordinateDerivativeRequest
    { derivativeRequestOrder = order
    , derivativeRequestAxis = axis
    , derivativeRequestRadius = radius
    , derivativeRequestOperand = operand
    }
  where
    attributes = opaqueDiscreteAttributes opaque

validateAttributeSet :: [Attribute] -> Either DerivativeMetadataError ()
validateAttributeSet attributes = do
  case firstDuplicate (map attributeId attributes) of
    Just duplicate -> Left (DerivativeDuplicateAttribute duplicate)
    Nothing -> Right ()
  case [identifier | identifier <- map attributeId attributes,
                     identifier `notElem` derivativeAttributeIds] of
    unknown : _ -> Left (DerivativeUnknownAttribute unknown)
    [] -> Right ()

requireDerivativeAttribute
    :: AttributeId
    -> [Attribute]
    -> Either DerivativeMetadataError AttributeValue
requireDerivativeAttribute requested attributes =
  case
    [attributeValue attribute | attribute <- attributes,
                                attributeId attribute == requested] of
    [value] -> Right value
    [] -> Left (DerivativeMissingAttribute requested)
    _ -> Left (DerivativeDuplicateAttribute requested)

parsePositiveNatural
    :: (Integer -> DerivativeMetadataError)
    -> AttributeId
    -> AttributeValue
    -> Either DerivativeMetadataError Int
parsePositiveNatural outOfRange attributeIdentifier value =
  case value of
    AttributeNatural natural
      | integerValue > 0
      , integerValue <= toInteger (maxBound :: Int) ->
          Right (fromInteger integerValue)
      | otherwise -> Left (outOfRange integerValue)
      where
        integerValue = toInteger natural
    _ -> Left (DerivativeInvalidAttribute attributeIdentifier value)

inferScalarLocation
    :: CompileEnvironment
    -> SemanticKey
    -> ScalarNF
    -> Either PostError ScalarLocationInfo
inferScalarLocation environment semanticKey scalar =
  case scalar of
    Exact _ _ -> Right constantLocation
    NamedConstant _ -> Right constantLocation
    Parameter _ -> Right constantLocation
    Coordinate _ -> Right sampleableLocation
    Add values -> inferMany values
    Mul values -> inferMany values
    Div numerator denominator -> inferMany [numerator, denominator]
    Pow base power -> inferMany [base, power]
    Intrinsic _ arguments -> inferCall arguments
    AnalyticCall _ arguments -> inferCall arguments
    Select predicate yes no -> do
      predicateLocation <- inferPredicateLocation environment semanticKey predicate
      yesLocation <- inferScalarLocation environment semanticKey yes
      noLocation <- inferScalarLocation environment semanticKey no
      joinScalarLocations semanticKey predicateLocation yesLocation
        >>= (\joined -> joinScalarLocations semanticKey joined noLocation)
    FieldJet jet -> inferFieldJetLocation environment jet
    OpaqueDiscrete opaque
      | opaqueDiscreteOpId opaque == wideDerivativeOperationId ->
          inferWideLocation environment opaque
      | opaqueDiscreteOpId opaque == gridWholeDerivativeOperationId ->
          inferGridWholeLocation environment opaque
      | opaqueDiscreteOpId opaque == orderedDerivativeOperationId ->
          inferOrderedDerivativeLocation environment opaque
      | opaqueDiscreteOpId opaque == resampleOperationId ->
          inferResampleLocation environment opaque
      | otherwise -> Left (PostUnsupportedOpaque (opaqueDiscreteOpId opaque))
    Ref nodeId -> do
      value <- lookupBinding environment nodeId
      case value of
        ScalarValue expression -> inferScalarLocation environment semanticKey expression
        TensorValue _ -> Left (PostTensorBindingUsedAsScalar nodeId)
  where
    inferMany values = do
      locations <- mapM (inferScalarLocation environment semanticKey) values
      foldScalarLocations semanticKey locations
    inferCall [] = Right sampleableLocation
    inferCall arguments = inferMany arguments

inferPredicateLocation
    :: CompileEnvironment
    -> SemanticKey
    -> PredicateNF
    -> Either PostError ScalarLocationInfo
inferPredicateLocation environment semanticKey predicate =
  case predicate of
    BoolExact _ -> Right constantLocation
    Compare _ lhs rhs -> inferMany [lhs, rhs]
    Not body -> inferPredicateLocation environment semanticKey body
    And bodies -> inferPredicates bodies
    Or bodies -> inferPredicates bodies
  where
    inferMany values = do
      locations <- mapM (inferScalarLocation environment semanticKey) values
      foldScalarLocations semanticKey locations
    inferPredicates values = do
      locations <- mapM (inferPredicateLocation environment semanticKey) values
      foldScalarLocations semanticKey locations

inferFieldJetLocation
    :: CompileEnvironment -> FieldJet -> Either PostError ScalarLocationInfo
inferFieldJetLocation environment jet = do
  field <- lookupField environment (fieldJetFieldId jet)
  source <- mapLocationError
    (componentPlacement (programDimension environment)
      (logicalFieldPolicy field) (fieldJetBasis jet))
  target <- mapLocationError
    (derivativePlacementForPolicy (logicalFieldPolicy field)
      (fieldJetMultiIndex jet) source)
  Right ScalarLocationInfo
    { scalarLocationCapability = LocatedCapability target
    , scalarLocationLattice = Just
        (latticeClassOfPolicy (logicalFieldPolicy field))
    }

inferWideLocation
    :: CompileEnvironment
    -> OpaqueDiscrete
    -> Either PostError ScalarLocationInfo
inferWideLocation environment opaque = do
  request <- mapWideError opaque
    (mapLeft WideMetadataError (parseDerivativeRequest opaque))
  validateWideRequest opaque request
  location <- inferScalarLocation environment
    (opaqueDiscreteSemanticKey opaque) (derivativeRequestOperand request)
  case scalarLocationCapability location of
    LocatedCapability source -> do
      target <- derivativeNaturalTarget request source
        (scalarLocationLattice location)
      Right location { scalarLocationCapability = LocatedCapability target }
    _ -> Right location

inferGridWholeLocation
    :: CompileEnvironment
    -> OpaqueDiscrete
    -> Either PostError ScalarLocationInfo
inferGridWholeLocation environment opaque = do
  request <- mapGridWholeError opaque
    (mapLeft GridWholeMetadataError (parseDerivativeRequest opaque))
  validateGridWholeRequest opaque request
  location <- inferScalarLocation environment
    (opaqueDiscreteSemanticKey opaque) (derivativeRequestOperand request)
  case scalarLocationCapability location of
    LocatedCapability source -> do
      target <- derivativeNaturalTarget request source
        (scalarLocationLattice location)
      Right location { scalarLocationCapability = LocatedCapability target }
    _ -> Right location

inferOrderedDerivativeLocation
    :: CompileEnvironment
    -> OpaqueDiscrete
    -> Either PostError ScalarLocationInfo
inferOrderedDerivativeLocation environment opaque = do
  request <- mapPrimitiveContract opaque
    (parseOrderedDerivativeRequest (programDimension environment) opaque)
  location <- inferScalarLocation environment
    (opaqueDiscreteSemanticKey opaque) (orderedDerivativeOperand request)
  case scalarLocationCapability location of
    LocatedCapability source -> do
      plan <- mapExplicitStencil opaque
        (orderedFirstDerivativeStencil
          (scalarLocationLattice location == Just StaggeredLattice)
          (orderedDerivativeAxes request) source)
      Right location
        { scalarLocationCapability =
            LocatedCapability (orderedStencilTarget plan) }
    _ -> Right location

inferResampleLocation
    :: CompileEnvironment
    -> OpaqueDiscrete
    -> Either PostError ScalarLocationInfo
inferResampleLocation environment opaque = do
  request <- mapPrimitiveContract opaque
    (parseResampleRequest (programDimension environment) opaque)
  _ <- inferScalarLocation environment
    (opaqueDiscreteSemanticKey opaque) (resampleOperand request)
  let bits = resampleTargetBits request
  Right ScalarLocationInfo
    { scalarLocationCapability = LocatedCapability (placementFromBits bits)
    , scalarLocationLattice = Just
        (if or bits then StaggeredLattice else CollocatedLattice)
    }

joinScalarLocations
    :: SemanticKey
    -> ScalarLocationInfo
    -> ScalarLocationInfo
    -> Either PostError ScalarLocationInfo
joinScalarLocations semanticKey lhs rhs = do
  capability <- mapLocationError
    (joinCapability (scalarLocationCapability lhs)
      (scalarLocationCapability rhs))
  lattice <- joinLattice (scalarLocationLattice lhs)
    (scalarLocationLattice rhs)
  Right ScalarLocationInfo
    { scalarLocationCapability = capability
    , scalarLocationLattice = case capability of
        LocatedCapability _ -> lattice
        _ -> Nothing
    }
  where
    joinLattice Nothing value = Right value
    joinLattice value Nothing = Right value
    joinLattice left@(Just lhsLattice) (Just rhsLattice)
      | lhsLattice == rhsLattice = Right left
      | otherwise = Left (PostDerivativeLatticeMismatch semanticKey
          lhsLattice rhsLattice)

foldScalarLocations
    :: SemanticKey
    -> [ScalarLocationInfo]
    -> Either PostError ScalarLocationInfo
foldScalarLocations _ [] = Right constantLocation
foldScalarLocations semanticKey (first : rest) = foldl step (Right first) rest
  where
    step result value = result >>= (\joined ->
      joinScalarLocations semanticKey joined value)

constantLocation :: ScalarLocationInfo
constantLocation = ScalarLocationInfo ConstantCapability Nothing

sampleableLocation :: ScalarLocationInfo
sampleableLocation = ScalarLocationInfo SampleableCapability Nothing

mapWideError
    :: OpaqueDiscrete
    -> Either WideDerivativeError a
    -> Either PostError a
mapWideError opaque = either
  (Left . PostWideDerivativeError (opaqueDiscreteSemanticKey opaque)) Right

mapGridWholeError
    :: OpaqueDiscrete
    -> Either GridWholeDerivativeError a
    -> Either PostError a
mapGridWholeError opaque = either
  (Left . PostGridWholeDerivativeError
    (opaqueDiscreteSemanticKey opaque)) Right

mapPrimitiveContract
    :: OpaqueDiscrete
    -> Either PrimitiveContractError value
    -> Either PostError value
mapPrimitiveContract opaque = either
  (Left . PostPrimitiveContractError
    (opaqueDiscreteSemanticKey opaque)) Right

mapExplicitStencil
    :: OpaqueDiscrete
    -> Either ExplicitStencilError value
    -> Either PostError value
mapExplicitStencil opaque = either
  (Left . PostExplicitStencilError
    (opaqueDiscreteSemanticKey opaque)) Right

mapLeft :: (left -> right) -> Either left value -> Either right value
mapLeft convert result =
  case result of
    Left value -> Left (convert value)
    Right value -> Right value

firstDuplicate :: Eq a => [a] -> Maybe a
firstDuplicate values = go [] values
  where
    go _ [] = Nothing
    go seen (value : rest)
      | value `elem` seen = Just value
      | otherwise = go (value : seen) rest

orderAttribute, orderedAxesAttribute, radiusAttribute :: AttributeId
orderAttribute = AttributeId "order"
orderedAxesAttribute = AttributeId "ordered-axes"
radiusAttribute = AttributeId "radius"

derivativeAttributeIds :: [AttributeId]
derivativeAttributeIds = [orderAttribute, orderedAxesAttribute, radiusAttribute]

lowerPredicateShifted
    :: CompileEnvironment
    -> Placement
    -> [Int]
    -> PredicateNF
    -> Either PostError FExpr
lowerPredicateShifted environment targetPlacement sampleOffsets predicate =
  case predicate of
    BoolExact True -> Right (FExact 1 1)
    BoolExact False -> Right (FExact 0 1)
    Compare operator lhs rhs ->
      FCompare operator
        <$> lowerScalarShifted environment targetPlacement sampleOffsets lhs
        <*> lowerScalarShifted environment targetPlacement sampleOffsets rhs
    Not body ->
      FCompare CompareEq
        <$> lowerPredicateShifted environment targetPlacement sampleOffsets body
        <*> pure (FExact 0 1)
    And bodies ->
      FMul <$> mapM recurse bodies
    Or bodies -> do
      lowered <- mapM recurse bodies
      Right (FCompare CompareGt (FAdd lowered) (FExact 0 1))
  where
    recurse = lowerPredicateShifted environment targetPlacement sampleOffsets

lowerCallShifted
    :: CompileEnvironment
    -> Placement
    -> [Int]
    -> FunctionId
    -> [ScalarNF]
    -> Either PostError FExpr
lowerCallShifted environment targetPlacement sampleOffsets functionId arguments = do
  function <- lookupFunction environment functionId
  lowered <- mapM
    (lowerScalarShifted environment targetPlacement sampleOffsets) arguments
  Right (FCall (functionDeclBackendName function) lowered)

lowerCoordinateShifted
    :: CompileEnvironment
    -> Placement
    -> [Int]
    -> AxisId
    -> Either PostError FExpr
lowerCoordinateShifted environment (Placement bits) sampleOffsets
    axisId@(AxisId axisNumber) = do
  axis <- lookupAxis environment axisId
  indices <- indexNames environment
  case ( drop (axisNumber - 1) bits
       , drop (axisNumber - 1) indices
       , drop (axisNumber - 1) sampleOffsets
       ) of
    (bit : _, index : _, offset : _) ->
      let halfOffset = case bit of
            IntegerPoint -> 0
            HalfPoint -> 1 / 2
          totalOffset = fromIntegral offset + halfOffset
          shiftedIndex
            | totalOffset == 0 = FVariable index
            | otherwise = FAdd [FVariable index, exactExpr totalOffset]
          step = FVariable ("d" ++ axisDeclSourceName axis)
      in Right (FMul [shiftedIndex, step])
    _ -> Left (PostUnknownAxis axisId)

lowerFieldReferenceShifted
    :: CompileEnvironment
    -> Placement
    -> [Int]
    -> FieldJet
    -> Either PostError FExpr
lowerFieldReferenceShifted environment targetPlacement sampleOffsets jet = do
  field <- lookupField environment (fieldJetFieldId jet)
  sourcePlacement <- mapLocationError
    (componentPlacement (programDimension environment)
      (logicalFieldPolicy field) (fieldJetBasis jet))
  if sourcePlacement /= targetPlacement
    then Left (PostInvalidReferencePlacement targetPlacement sourcePlacement)
    else do
      name <- mapFMRError (storageName field (fieldJetBasis jet))
      indices <- indexNames environment
      let storage =
            case fieldJetTimeSlot jet of
              CurrentTime -> name
              NextTime -> name ++ "'"
      if length sampleOffsets == length indices
        then Right (FGridReference storage
          (zipWith GridIndex indices (map fromIntegral sampleOffsets)))
        else Left (PostInvalidAuxiliaryPlan
          ("sample offset dimension mismatch for " ++ storage))

lowerFieldDerivativeShifted
    :: CompileEnvironment
    -> Placement
    -> [Int]
    -> FieldJet
    -> Either PostError FExpr
lowerFieldDerivativeShifted environment targetPlacement sampleOffsets jet = do
  field <- lookupField environment (fieldJetFieldId jet)
  sourcePlacement <- mapLocationError
    (componentPlacement (programDimension environment)
      (logicalFieldPolicy field) (fieldJetBasis jet))
  naturalTarget <- mapLocationError
    (derivativePlacementForPolicy (logicalFieldPolicy field)
      (fieldJetMultiIndex jet) sourcePlacement)
  if naturalTarget /= targetPlacement
    then Left (PostInvalidReferencePlacement targetPlacement naturalTarget)
    else return ()
  profilePlan <- mapProfileError
    (resolveFieldJetProfile
      (feProgramDiscretization (compileProgramInput environment))
      (logicalFieldPolicy field) jet)
  axisStencils <- mapM (axisStencil sourcePlacement)
    (fieldJetProfileAxes profilePlan)
  indices <- indexNames environment
  name <- mapFMRError (storageName field (fieldJetBasis jet))
  denominatorFactors <- mapM denominatorFactor
    (fieldJetProfileAxes profilePlan)
  let storage =
        case fieldJetTimeSlot jet of
          CurrentTime -> name
          NextTime -> name ++ "'"
      weightedOffsets = foldl combineOffsets
        [(sampleOffsets, 1)] axisStencils
      numerator = FAdd
        [ normalizeExpr (FMul
            [ exactExpr coefficient
            , FGridReference storage
                (zipWith GridIndex indices (map fromIntegral offsets))
            ])
        | (offsets, coefficient) <- weightedOffsets
        ]
      denominator =
        case denominatorFactors of
          [] -> FExact 1 1
          [factor] -> factor
          factors -> FMul factors
  Right (normalizeExpr (FDiv (normalizeExpr numerator) (normalizeExpr denominator)))
  where
    denominatorFactor resolvedAxis = do
      step <- axisStep environment (resolvedAxisId resolvedAxis)
      Right (FPow step
        (FExact (toInteger (resolvedAxisDerivativeOrder resolvedAxis)) 1))

    axisStencil sourcePlacement resolvedAxis = do
      let AxisId axisNumber = resolvedAxisId resolvedAxis
          rule = resolvedAxisRule resolvedAxis
      weights <-
        case resolvedRuleStencil rule of
          ResolvedCenteredStencil stencil -> Right (centeredWeights stencil)
          ResolvedYeeStencil stage ->
            staggeredStorageWeights sourcePlacement
              (resolvedAxisId resolvedAxis) stage
      Right (axisNumber, weights)

yeeFirstWeights :: Placement -> Int -> Either PostError [(Int, Rational)]
yeeFirstWeights (Placement bits) axisNumber =
  case drop (axisNumber - 1) bits of
    IntegerPoint : _ -> Right [(0, -1), (1, 1)]
    HalfPoint : _ -> Right [(-1, -1), (0, 1)]
    [] -> Left (PostLocationError
      (InvalidDerivativeAxis (AxisId axisNumber) (length bits)))

-- | Map a staggered stencil's half-integer offsets to storage offsets on
-- the operand's sub-lattice.  A source sample at storage offset j sits at
-- j − 1/2 from a half-point target (integer source) and at j + 1/2 from an
-- integer target (half source), matching the Yee pair orientation.
staggeredStorageWeights
    :: Placement -> AxisId -> StaggeredStencil
    -> Either PostError [(Int, Rational)]
staggeredStorageWeights (Placement bits) axisId@(AxisId axisNumber) stencil =
  case drop (axisNumber - 1) bits of
    IntegerPoint : _ -> Right
      [ ((twiceOffset + 1) `div` 2, weight)
      | (twiceOffset, weight) <- staggeredTwiceWeights stencil
      ]
    HalfPoint : _ -> Right
      [ ((twiceOffset - 1) `div` 2, weight)
      | (twiceOffset, weight) <- staggeredTwiceWeights stencil
      ]
    [] -> Left (PostLocationError
      (InvalidDerivativeAxis axisId (length bits)))

combineOffsets
    :: [([Int], Rational)]
    -> (Int, [(Int, Rational)])
    -> [([Int], Rational)]
combineOffsets accumulated (axisNumber, weights) =
  [ (adjustOffset axisNumber offset offsets, coefficient * weight)
  | (offsets, coefficient) <- accumulated
  , (offset, weight) <- weights
  ]

adjustOffset :: Int -> Int -> [Int] -> [Int]
adjustOffset axisNumber delta offsets =
  [ if current == axisNumber then value + delta else value
  | (current, value) <- zip [1 ..] offsets
  ]

exactExpr :: Rational -> FExpr
exactExpr value = FExact (Ratio.numerator value) (Ratio.denominator value)

tensorComponent :: Basis -> TensorNF -> Either PostError ScalarNF
tensorComponent basis tensor =
  case lookup basis (tensorNFComponents tensor) of
    Just component -> Right component
    Nothing -> Left (PostMissingTensorComponent basis)

targetField
    :: CompileEnvironment -> FieldTarget -> Either PostError LogicalFieldDecl
targetField environment target =
  case target of
    WholeFieldTarget fieldId _ -> lookupField environment fieldId
    FieldComponentTarget fieldId _ _ -> lookupField environment fieldId

targetBasesFor
    :: CompileEnvironment
    -> LogicalFieldDecl
    -> FieldTarget
    -> Either PostError [Basis]
targetBasesFor environment field target =
  case target of
    WholeFieldTarget _ _ ->
      mapFMRError (independentBases (programDimension environment) field)
    FieldComponentTarget _ _ basis -> Right [basis]

resolveTarget
    :: CompileEnvironment
    -> FieldTarget
    -> Either PostError (LogicalFieldDecl, Basis)
resolveTarget environment target = do
  field <- targetField environment target
  case target of
    FieldComponentTarget _ _ basis -> Right (field, basis)
    WholeFieldTarget _ _ -> do
      bases <- mapFMRError (independentBases (programDimension environment) field)
      case bases of
        [basis] -> Right (field, basis)
        _ -> Left (PostInvalidTarget target)

fieldStorage :: FEProgram -> LogicalFieldDecl -> Either PostError [String]
fieldStorage program field =
  map snd <$> mapFMRError (storageNames (feProgramDimension program) field)

lookupField :: CompileEnvironment -> FieldId -> Either PostError LogicalFieldDecl
lookupField environment fieldId =
  case find ((== fieldId) . logicalFieldId) (feProgramFields (compileProgramInput environment)) of
    Just field -> Right field
    Nothing -> Left (PostUnknownField fieldId)

lookupParameter :: CompileEnvironment -> ParamId -> Either PostError ParameterDecl
lookupParameter environment parameterId =
  case find ((== parameterId) . parameterDeclId)
       (feProgramParameters (compileProgramInput environment)) of
    Just parameter -> Right parameter
    Nothing -> Left (PostUnknownParameter parameterId)

lookupFunction :: CompileEnvironment -> FunctionId -> Either PostError FunctionDecl
lookupFunction environment functionId =
  case find ((== functionId) . functionDeclId)
       (feProgramFunctions (compileProgramInput environment)) of
    Just function -> Right function
    Nothing -> Left (PostUnknownFunction functionId)

lookupAxis :: CompileEnvironment -> AxisId -> Either PostError AxisDecl
lookupAxis environment axisId =
  case find ((== axisId) . axisDeclId) (feProgramAxes (compileProgramInput environment)) of
    Just axis -> Right axis
    Nothing -> Left (PostUnknownAxis axisId)

lookupBinding :: CompileEnvironment -> NodeId -> Either PostError FEValue
lookupBinding environment nodeId =
  case lookup nodeId (compileBindings environment) of
    Just value -> Right value
    Nothing -> Left (PostUnknownBinding nodeId)

indexNames :: CompileEnvironment -> Either PostError [String]
indexNames environment =
  Right (take (programDimension environment) ["i", "j", "k"])

programDimension :: CompileEnvironment -> Int
programDimension = feProgramDimension . compileProgramInput

ensureUniqueTargets :: [FAssignment] -> Either PostError ()
ensureUniqueTargets assignments = go [] (map targetName assignments)
  where
    go _ [] = Right ()
    go seen (name : rest)
      | name `elem` seen = Left (PostDuplicateAssignment name)
      | otherwise = go (name : seen) rest
    targetName assignment =
      case fAssignmentTarget assignment of
        InitialTarget name _ -> "init:" ++ name
        StepBindingTarget name -> "bind:" ++ name
        StepUpdateTarget name -> "update:" ++ name

mapFMRError :: Either FMRError a -> Either PostError a
mapFMRError = either (Left . PostFMRError) Right

mapLocationError :: Either LocationError a -> Either PostError a
mapLocationError = either (Left . PostLocationError) Right

mapProfileError :: Either ProfileError a -> Either PostError a
mapProfileError = either (Left . PostProfileError) Right

mapBackendPlanError
    :: Either Backend.BackendPlanError a -> Either PostError a
mapBackendPlanError = either (Left . PostBackendPlanError) Right

withPostOrigin :: OriginId -> Either PostError a -> Either PostError a
withPostOrigin origin = either (Left . PostAtOrigin origin) Right

concatMapM :: (a -> Either e [b]) -> [a] -> Either e [b]
concatMapM function values = concat <$> mapM function values

uniqueValues :: Eq a => [a] -> [a]
uniqueValues = foldl add []
  where
    add values value
      | value `elem` values = values
      | otherwise = values ++ [value]
