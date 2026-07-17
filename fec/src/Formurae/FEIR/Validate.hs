module Formurae.FEIR.Validate
  ( ValidationConfig(..)
  , ValidationPath(..)
  , IdNamespace(..)
  , ValidationIssue(..)
  , ValidationError(..)
  , validateFEProgram
  ) where

import Data.List (group, nub, sort, sortBy)
import Data.Ord (comparing)
import Numeric.Natural (Natural)

import Formurae.FEIR.Codec
  ( computeProfileFingerprint
  , encodePredicateNF
  , encodeScalarNF
  )
import Formurae.FEIR.PrimitiveManifest
import Formurae.FEIR.SExpr (renderSExpr)
import Formurae.FEIR.Syntax

-- | External, versioned contracts which are intentionally not duplicated in
-- the FEIR wire tree.
data ValidationConfig = ValidationConfig
  { validationExpectedRegistryId :: Maybe RegistryId
  , validationExpectedPrimitiveManifestId :: Maybe PrimitiveManifestId
  , validationPrimitiveSignatures :: [PrimitiveSignature]
  }

data ValidationPath
  = ProgramPath
  | ModelPath
  | AxisPath AxisId
  | ParameterPath ParamId
  | FunctionPath FunctionId
  | FieldPath FieldId
  | GeometryPath GeometryId
  | ProfilePath
  | DerivativeRulePath Int
  | InitializerPath Int
  | ActionPath Int
  | EquationPath EquationId
  | NodePath NodeId
  | TensorComponentPath Basis
  | ScalarChildPath Int
  | PredicateChildPath Int
  | OpaquePath SemanticKey
  | AttributePath AttributeId
  | RawHelperPath RawHelperId
  | OriginPath OriginId
  | ProvenancePath NodeId
  deriving (Eq, Ord, Show)

data IdNamespace
  = ModelIds
  | SourceIds
  | RegistryIds
  | PrimitiveManifestIds
  | ProfileIds
  | AxisIds
  | ParameterIds
  | FunctionIds
  | FieldIds
  | GeometryIds
  | RawHelperIds
  | OriginIds
  | NodeIds
  | EquationIds
  | OpaqueOperationIds
  | SemanticKeys
  | RequestGroupIds
  | AttributeIds
  deriving (Eq, Ord, Show)

data ValidationIssue
  = EmptyIdentifier IdNamespace
  | NonPositiveIdentifier IdNamespace Int
  | DuplicateIdentifier IdNamespace String
  | UnknownReference IdNamespace String
  | RegistryIdMismatch RegistryId RegistryId
  | PrimitiveManifestIdMismatch PrimitiveManifestId PrimitiveManifestId
  | PrimitiveSignatureTableManifestMismatch
      PrimitiveManifestId PrimitiveManifestId
  | InvalidPrimitiveSignatureTable String
  | InvalidDimension Int
  | AxisCountMismatch Int Int
  | AxisIdSequenceMismatch [AxisId] [AxisId]
  | DuplicateName String String
  | NonCanonicalOrder String
  | InvalidSourceLocation SourceLocation
  | InvalidShape [Int]
  | TensorAxisDimensionMismatch Int [Int]
  | VarianceCountMismatch Int Int
  | InvalidDifferentialFormOrder Int Int
  | ComponentBasisMismatch [Basis] [Basis]
  | InvalidBasis Basis [Int]
  | InvalidLayout Layout TensorType
  | DeclaredVarianceCountMismatch Int Int
  | DeclaredVarianceMismatch Int Variance Variance
  | NonCanonicalExact Integer Integer
  | NonCanonicalScalarForm String
  | NonCanonicalPredicateForm String
  | DivisionByZero
  | InvalidFunctionArity Int
  | FunctionClassMismatch FunctionId FunctionClass FunctionClass
  | FunctionArityMismatch FunctionId Int Int
  | NonCanonicalFieldArguments [ScalarNF] [ScalarNF]
  | NonCanonicalMultiIndex [(AxisId, Natural)]
  | RefOutsideActionStream NodeId
  | RefNotPreceding NodeId
  | FieldValueNotAvailable FieldId TimeSlot
  | InvalidTargetTime TimeSlot TimeSlot
  | ComponentUpdateTargetNotAllowed FieldId Basis
  | InvalidFieldLifetime FieldId Lifetime Lifetime
  | TensorTypeMismatch TensorType TensorType
  | InvalidDerivativeRuleOrder Int
  | InvalidFormalAccuracy Int
  | InvalidLatticeFamily LatticeClass StencilFamily
  | DuplicateDerivativeRule LatticeClass (Maybe Int)
  | ProfileFingerprintMismatch Fingerprint Fingerprint
  | EmptyOpaqueSemanticKey
  | EmptyOpaqueRequestGroup
  | UnknownOpaqueOperation OpId
  | OpaqueOperandCountMismatch OpId Int Int
  | OpaqueOperandCategoryMismatch OpId Int ValueCategory
  | OpaqueOutputCategoryMismatch OpId ValueCategory Basis
  | OpaqueEffectContextMismatch OpId PrimitiveEffect
  | OpaquePlacementContractMismatch OpId PlacementRule Basis
  | ConflictingOpaqueSemanticKey SemanticKey
  | UnverifiedOrthogonalGeometry
  | InvalidEmbeddedGeometry
  | EmptyProvenance
  deriving (Eq, Ord, Show)

data ValidationError = ValidationError
  { validationErrorPath :: [ValidationPath]
  , validationErrorIssue :: ValidationIssue
  } deriving (Eq, Ord, Show)

data Environment = Environment
  { environmentConfig :: ValidationConfig
  , environmentProgram :: FEProgram
  , environmentAxisIds :: [AxisId]
  , environmentParameterIds :: [ParamId]
  , environmentFunctionDecls :: [FunctionDecl]
  , environmentFieldDecls :: [LogicalFieldDecl]
  , environmentGeometryId :: GeometryId
  , environmentOriginIds :: [OriginId]
  , environmentNodeIds :: [NodeId]
  , environmentSource :: SourceIdentity
  }

data ValueContext
  = StaticValueContext
  | InitializerValueContext
  | StepValueContext [NodeId] [FieldId] [FieldId]

data TargetStage = InitializerStage | UpdateStage

validateFEProgram
    :: ValidationConfig -> FEProgram -> Either [ValidationError] ()
validateFEProgram config program =
  case errors of
    [] -> Right ()
    _ -> Left errors
  where
    environment = makeEnvironment config program
    errors = concat
      [ validateHeader environment
      , validateOrigins environment
      , validateAxes environment
      , validateParameters environment
      , validateFunctions environment
      , validateFields environment
      , validateGeometry environment
      , validateProfile environment
      , validateRawHelpers environment
      , validateEquationAndNodeIdentities environment
      , validateInitializers environment
      , validateActions environment
      , validateProvenance environment
      , validateOpaqueSemanticKeys environment
      ]

makeEnvironment :: ValidationConfig -> FEProgram -> Environment
makeEnvironment config program = Environment
  { environmentConfig = config
  , environmentProgram = program
  , environmentAxisIds = map axisDeclId (feProgramAxes program)
  , environmentParameterIds = map parameterDeclId (feProgramParameters program)
  , environmentFunctionDecls = feProgramFunctions program
  , environmentFieldDecls = feProgramFields program
  , environmentGeometryId = geometryDeclId (feProgramGeometry program)
  , environmentOriginIds = originKeys (feProgramOrigins program)
  , environmentNodeIds = actionNodeIds (feProgramStepActions program)
  , environmentSource = modelIdentitySource (feProgramModel program)
  }

validateHeader :: Environment -> [ValidationError]
validateHeader environment = concat
  [ nonEmptyStringId [ProgramPath, ModelPath] ModelIds modelIdText
  , nonEmptyStringId [ProgramPath, ModelPath] SourceIds sourceIdText
  , nonEmptyStringId [ProgramPath] RegistryIds registryText
  , nonEmptyStringId [ProgramPath] PrimitiveManifestIds manifestText
  , [validationError [ProgramPath]
       (RegistryIdMismatch expected (feProgramRegistryId program))
    | Just expected <- [validationExpectedRegistryId config]
    , expected /= feProgramRegistryId program]
  , [validationError [ProgramPath]
       (PrimitiveManifestIdMismatch expected
          (feProgramPrimitiveManifestId program))
    | Just expected <- [validationExpectedPrimitiveManifestId config]
    , expected /= feProgramPrimitiveManifestId program]
  , case validatePrimitiveManifest signatureManifest of
      Left problem ->
        [validationError [ProgramPath]
          (InvalidPrimitiveSignatureTable (show problem))]
      Right _ -> []
  , [validationError [ProgramPath]
       (PrimitiveSignatureTableManifestMismatch expected signatureManifestId)
    | Just expected <- [validationExpectedPrimitiveManifestId config]
    , expected /= signatureManifestId]
  , [validationError [ProgramPath] (InvalidDimension dimension)
    | dimension <= 0]
  , [validationError [ProgramPath]
       (AxisCountMismatch dimension (length (feProgramAxes program)))
    | dimension > 0 && length (feProgramAxes program) /= dimension]
  ]
  where
    program = environmentProgram environment
    config = environmentConfig environment
    dimension = feProgramDimension program
    ModelId modelIdText = modelIdentityId (feProgramModel program)
    SourceId sourceIdText = sourceIdentityId (environmentSource environment)
    RegistryId registryText = feProgramRegistryId program
    PrimitiveManifestId manifestText = feProgramPrimitiveManifestId program
    signatureManifest = PrimitiveManifest
      (validationPrimitiveSignatures config)
    signatureManifestId = primitiveManifestId signatureManifest

validateAxes :: Environment -> [ValidationError]
validateAxes environment = concat
  [ numericIdErrors AxisIds AxisPath axisNumber axisIds
  , duplicateIdErrors AxisIds (map show axisIds) [ProgramPath]
  , [validationError [ProgramPath]
       (AxisIdSequenceMismatch expectedAxisIds axisIds)
    | dimension > 0 && axisIds /= expectedAxisIds]
  , duplicateNameErrors "axis source name"
      (map axisDeclSourceName axes) [ProgramPath]
  , duplicateNameErrors "axis canonical name"
      (map axisDeclCanonicalName axes) [ProgramPath]
  , concatMap validateAxis axes
  ]
  where
    program = environmentProgram environment
    axes = feProgramAxes program
    axisIds = map axisDeclId axes
    dimension = feProgramDimension program
    expectedAxisIds = map AxisId [1 .. dimension]
    axisNumber (AxisId value) = value

    validateAxis axis = concat
      [ [validationError path (EmptyIdentifier AxisIds)
        | null (axisDeclSourceName axis)]
      , [validationError path (EmptyIdentifier AxisIds)
        | null (axisDeclCanonicalName axis)]
      , validateOriginReference environment path (axisDeclOrigin axis)
      ]
      where
        path = [ProgramPath, AxisPath (axisDeclId axis)]

validateParameters :: Environment -> [ValidationError]
validateParameters environment = concat
  [ numericIdErrors ParameterIds ParameterPath parameterNumber ids
  , duplicateIdErrors ParameterIds (map show ids) [ProgramPath]
  , canonicalIdOrder "parameters" ids [ProgramPath]
  , duplicateNameErrors "parameter source name"
      (map parameterDeclSourceName parameters) [ProgramPath]
  , duplicateNameErrors "parameter backend name"
      (map parameterDeclBackendName parameters) [ProgramPath]
  , concatMap validateParameter parameters
  ]
  where
    parameters = feProgramParameters (environmentProgram environment)
    ids = map parameterDeclId parameters
    parameterNumber (ParamId value) = value

    validateParameter parameter = concat
      [ [validationError path (EmptyIdentifier ParameterIds)
        | null (parameterDeclSourceName parameter)]
      , [validationError path (EmptyIdentifier ParameterIds)
        | null (parameterDeclBackendName parameter)]
      , validateOriginReference environment path (parameterDeclOrigin parameter)
      ]
      where
        path = [ProgramPath, ParameterPath (parameterDeclId parameter)]

validateFunctions :: Environment -> [ValidationError]
validateFunctions environment = concat
  [ numericIdErrors FunctionIds FunctionPath functionNumber ids
  , duplicateIdErrors FunctionIds (map show ids) [ProgramPath]
  , canonicalIdOrder "functions" ids [ProgramPath]
  , duplicateNameErrors "function source name"
      (map functionDeclSourceName functions) [ProgramPath]
  , duplicateNameErrors "function backend name"
      (map functionDeclBackendName functions) [ProgramPath]
  , concatMap validateFunction functions
  ]
  where
    functions = environmentFunctionDecls environment
    ids = map functionDeclId functions
    functionNumber (FunctionId value) = value

    validateFunction function = concat
      [ [validationError path (EmptyIdentifier FunctionIds)
        | null (functionDeclSourceName function)]
      , [validationError path (EmptyIdentifier FunctionIds)
        | null (functionDeclBackendName function)]
      , [validationError path (InvalidFunctionArity arity)
        | Just arity <- [functionDeclArity function], arity < 0]
      , maybe [] (validateOriginReference environment path)
          (functionDeclOrigin function)
      ]
      where
        path = [ProgramPath, FunctionPath (functionDeclId function)]

validateFields :: Environment -> [ValidationError]
validateFields environment = concat
  [ numericIdErrors FieldIds FieldPath fieldNumber ids
  , duplicateIdErrors FieldIds (map show ids) [ProgramPath]
  , canonicalIdOrder "fields" ids [ProgramPath]
  , duplicateNameErrors "field source name"
      (map logicalFieldSourceName fields) [ProgramPath]
  , concatMap validateField fields
  ]
  where
    fields = environmentFieldDecls environment
    ids = map logicalFieldId fields
    fieldNumber (FieldId value) = value

    validateField field = concat
      [ [validationError path (EmptyIdentifier FieldIds)
        | null (logicalFieldSourceName field)]
      , validateTensorType environment path tensorType
      , validateFieldLayout path field
      , validateDeclaredVariances path field
      , validateOriginReference environment path (logicalFieldOrigin field)
      ]
      where
        path = [ProgramPath, FieldPath (logicalFieldId field)]
        tensorType = logicalFieldTensorType field

validateGeometry :: Environment -> [ValidationError]
validateGeometry environment = concat
  [ numericIdErrors GeometryIds GeometryPath geometryNumber [geometryId]
  , maybe [] (validateOriginReference environment path)
      (geometryDeclOrigin geometry)
  , case geometryDeclKind geometry of
      EuclideanGeometry -> []
      OrthogonalScaleGeometry scales geometryNF -> concat
        [ validateAxisScalarList environment path StaticValueContext scales
        , validateGeometryNF environment path geometryNF
        ]
      EmbeddedOrthogonalGeometry embedding geometryNF -> concat
        [ [validationError path InvalidEmbeddedGeometry | null embedding]
        , concat
            [ validateScalar environment StaticValueContext
                (path ++ [ScalarChildPath index]) scalar
            | (index, scalar) <- zip [0 ..] embedding
            ]
        , validateGeometryNF environment path geometryNF
        ]
  ]
  where
    geometry = feProgramGeometry (environmentProgram environment)
    geometryId = geometryDeclId geometry
    geometryNumber (GeometryId value) = value
    path = [ProgramPath, GeometryPath geometryId]

validateGeometryNF
    :: Environment -> [ValidationPath] -> GeometryNF -> [ValidationError]
validateGeometryNF environment path geometryNF = concat
  [ [validationError path UnverifiedOrthogonalGeometry
    | not (geometryOrthogonalityVerified geometryNF)]
  , validateMetricTensor "metric" (geometryMetricComponents geometryNF)
  , validateMetricTensor "inverse metric" (geometryInverseMetric geometryNF)
  , validateAxisScalarList environment path StaticValueContext
      (geometryScaleFactors geometryNF)
  , validateScalar environment StaticValueContext
      (path ++ [ScalarChildPath 0]) (geometryVolumeElement geometryNF)
  ]
  where
    dimension = feProgramDimension (environmentProgram environment)
    validateMetricTensor label tensor =
      [validationError path (InvalidShape (tensorNFShape tensor))
      | tensorNFShape tensor /= [dimension, dimension]]
      ++ validateTensorNF environment StaticValueContext path tensor
      ++ [validationError path (NonCanonicalOrder label)
         | tensorNFComponents tensor /= sortBy (comparing fst)
             (tensorNFComponents tensor)]

validateAxisScalarList
    :: Environment
    -> [ValidationPath]
    -> ValueContext
    -> [(AxisId, ScalarNF)]
    -> [ValidationError]
validateAxisScalarList environment path context values =
  [validationError path (NonCanonicalOrder "axis scalar list")
  | map fst values /= environmentAxisIds environment]
  ++ concat
    [ validateSimpleReference path AxisIds (show axisId)
        (axisId `elem` environmentAxisIds environment)
    | (axisId, _) <- values
    ]
  ++ concat
    [ validateScalar environment context
        (path ++ [ScalarChildPath index]) scalar
    | (index, (_, scalar)) <- zip [0 ..] values
    ]

validateProfile :: Environment -> [ValidationError]
validateProfile environment = concat
  [ nonEmptyStringId path ProfileIds fingerprintText
  , duplicateRuleErrors rules
  , [validationError path (NonCanonicalOrder "derivative rules")
    | rules /= sortBy (comparing derivativeRuleKey) rules]
  , concat
      [ validateRule index rule
      | (index, rule) <- zip [0 ..] rules
      ]
  , [validationError path
       (ProfileFingerprintMismatch expectedFingerprint declaredFingerprint)
    | expectedFingerprint /= declaredFingerprint]
  ]
  where
    profile = feProgramDiscretization (environmentProgram environment)
    rules = discretizationDerivativeRules profile
    path = [ProgramPath, ProfilePath]
    declaredFingerprint@(Fingerprint fingerprintText) =
      discretizationProfileFingerprint profile
    expectedFingerprint = computeProfileFingerprint profile

    validateRule index rule = concat
      [ case derivativeRuleOrder rule of
          Just (Positive order)
            | order <= 0 ->
                [validationError rulePath (InvalidDerivativeRuleOrder order)]
          _ -> []
      , let PositiveEven accuracy = derivativeRuleAccuracy rule
        in [validationError rulePath (InvalidFormalAccuracy accuracy)
           | accuracy <= 0 || odd accuracy]
      , [validationError rulePath
           (InvalidLatticeFamily (derivativeRuleLatticeClass rule)
             (derivativeRuleFamily rule))
        | not (validLatticeFamily rule)]
      , validateOriginReference environment rulePath
          (derivativeRuleOrigin rule)
      ]
      where
        rulePath = path ++ [DerivativeRulePath index]

validateRawHelpers :: Environment -> [ValidationError]
validateRawHelpers environment = concat
  [ numericIdErrors RawHelperIds RawHelperPath rawNumber ids
  , duplicateIdErrors RawHelperIds (map show ids) [ProgramPath]
  , canonicalIdOrder "raw helpers" ids [ProgramPath]
  , concatMap validateRawHelper helpers
  ]
  where
    helpers = feProgramRawHelpers (environmentProgram environment)
    ids = map rawHelperId helpers
    rawNumber (RawHelperId value) = value
    validateRawHelper helper =
      validateOriginReference environment
        [ProgramPath, RawHelperPath (rawHelperId helper)]
        (rawHelperOrigin helper)

validateEquationAndNodeIdentities :: Environment -> [ValidationError]
validateEquationAndNodeIdentities environment = concat
  [ numericIdErrors EquationIds EquationPath equationNumber equationIds
  , duplicateIdErrors EquationIds (map show equationIds) [ProgramPath]
  , numericIdErrors NodeIds NodePath nodeNumber nodeIds
  , duplicateIdErrors NodeIds (map show nodeIds) [ProgramPath]
  ]
  where
    program = environmentProgram environment
    equationIds = programEquationIds program
    nodeIds = environmentNodeIds environment
    equationNumber (EquationId value) = value
    nodeNumber (NodeId value) = value

validateInitializers :: Environment -> [ValidationError]
validateInitializers environment = concat
  [ validateInitializer index initializer
  | (index, initializer) <- zip [0 ..]
      (feProgramInitializers (environmentProgram environment))
  ]
  where
    validateInitializer index initializer =
      case initializer of
        AnalyticInitializer equation ->
          validateEquation environment InitializerValueContext
            InitializerStage path equation
        RawInitializer target _ origin -> concat
          [ validateTarget environment InitializerStage path target
          , validateOriginReference environment path origin
          ]
      where
        path = [ProgramPath, InitializerPath index]

validateActions :: Environment -> [ValidationError]
validateActions environment = go 0 [] [] [] actions
  where
    actions = feProgramStepActions (environmentProgram environment)

    go _ _ _ _ [] = []
    go index availableNodes availableLocals availableNext (action : rest) =
      errors ++ go (index + 1) nextNodes nextLocals nextFields rest
      where
        path = [ProgramPath, ActionPath index]
        context = StepValueContext availableNodes availableLocals availableNext
        (errors, nextNodes, nextLocals, nextFields) =
          case action of
            BindValue node value origin ->
              ( validateOriginReference environment path origin
                ++ validateFEValue environment context path value
              , availableNodes ++ [node]
              , availableLocals
              , availableNext
              )
            Materialize fieldId value origin ->
              ( validateOriginReference environment path origin
                ++ validateMaterializeTarget environment path fieldId value
                ++ validateFEValue environment context path value
              , availableNodes
              , availableLocals ++ [fieldId]
              , availableNext
              )
            UpdateField equation ->
              (validateEquation environment context UpdateStage path equation
              , availableNodes
              , availableLocals
              , availableNext ++ [targetFieldId (feEquationTarget equation)]
              )

validateProvenance :: Environment -> [ValidationError]
validateProvenance environment = concat
  [ numericIdErrors NodeIds ProvenancePath nodeNumber keys
  , duplicateIdErrors NodeIds (map show keys) [ProgramPath]
  , [validationError [ProgramPath] (NonCanonicalOrder "provenance table")
    | keys /= sort keys]
  , concatMap validateEntry entries
  ]
  where
    ProvenanceTable entries =
      feProgramProvenance (environmentProgram environment)
    keys = map fst entries
    nodeNumber (NodeId value) = value

    validateEntry (node, origins) = concat
      [ [validationError path (UnknownReference NodeIds (show node))
        | node `notElem` environmentNodeIds environment]
      , [validationError path EmptyProvenance | null origins]
      , duplicateIdErrors OriginIds (map show origins) path
      , [validationError path (NonCanonicalOrder "provenance origins")
        | origins /= sort origins]
      , concatMap (validateOriginReference environment path) origins
      ]
      where
        path = [ProgramPath, ProvenancePath node]

validateOrigins :: Environment -> [ValidationError]
validateOrigins environment = concat
  [ numericIdErrors OriginIds OriginPath originNumber keys
  , duplicateIdErrors OriginIds (map show keys) [ProgramPath]
  , [validationError [ProgramPath] (NonCanonicalOrder "origin table")
    | keys /= sort keys]
  , concatMap validateEntry entries
  ]
  where
    OriginTable entries = feProgramOrigins (environmentProgram environment)
    keys = map fst entries
    originNumber (OriginId value) = value
    validateEntry (originId, origin) =
      validateSourceOrigin environment [ProgramPath, OriginPath originId] origin

validateSourceOrigin
    :: Environment -> [ValidationPath] -> SourceOrigin -> [ValidationError]
validateSourceOrigin environment path origin =
  validateSourceLocation environment path (sourceOriginLocation origin)
  ++ concat
    [ validateSourceLocation environment path (expansionFrameDefinition frame)
      ++ validateSourceLocation environment path (expansionFrameCall frame)
    | frame <- sourceOriginTrace origin
    ]

validateSourceLocation
    :: Environment -> [ValidationPath] -> SourceLocation -> [ValidationError]
validateSourceLocation environment path location =
  [validationError path (InvalidSourceLocation location)
  | sourceLocationSource location /= sourceIdentityId source
    || sourceLocationPath location /= sourceIdentityPath source
    || sourceLocationLine location < 1
    || sourceLocationEndLine location < sourceLocationLine location
    || sourceLocationStartColumn location < 1
    || sourceLocationEndColumn location < 1
    || (sourceLocationLine location == sourceLocationEndLine location
        && sourceLocationEndColumn location
             < sourceLocationStartColumn location)]
  where
    source = environmentSource environment

validateEquation
    :: Environment
    -> ValueContext
    -> TargetStage
    -> [ValidationPath]
    -> FEEquation
    -> [ValidationError]
validateEquation environment context stage parentPath equation = concat
  [ validateOriginReference environment path (feEquationOrigin equation)
  , validateTarget environment stage path (feEquationTarget equation)
  , validateTensorNF environment context path (feEquationRhs equation)
  , validateEquationSignature environment path equation
  ]
  where
    path = parentPath ++ [EquationPath (feEquationId equation)]

validateTarget
    :: Environment
    -> TargetStage
    -> [ValidationPath]
    -> FieldTarget
    -> [ValidationError]
validateTarget environment stage path target =
  case lookupField environment fieldId of
    Nothing ->
      [validationError path (UnknownReference FieldIds (show fieldId))]
    Just field -> concat
      [ [validationError path (InvalidTargetTime expectedTime actualTime)
        | actualTime /= expectedTime]
      , [validationError path
           (InvalidFieldLifetime fieldId expectedLifetime actualLifetime)
        | actualLifetime /= expectedLifetime]
      , case target of
          WholeFieldTarget _ _ -> []
          FieldComponentTarget _ _ basis ->
            validateBasis path (tensorTypeShape (logicalFieldTensorType field)) basis
            ++ [validationError path
                  (ComponentUpdateTargetNotAllowed fieldId basis)
               | UpdateStage <- [stage]]
      ]
      where
        actualLifetime = logicalFieldLifetime field
        expectedLifetime = UserStateLifetime
  where
    fieldId = targetFieldId target
    actualTime = targetTimeSlot target
    expectedTime = case stage of
      InitializerStage -> CurrentTime
      UpdateStage -> NextTime

validateEquationSignature
    :: Environment -> [ValidationPath] -> FEEquation -> [ValidationError]
validateEquationSignature environment path equation =
  case lookupField environment (targetFieldId target) of
    Nothing -> []
    Just field ->
      [validationError path (TensorTypeMismatch expected actual)
      | expected /= actual]
      where
        expected = case target of
          WholeFieldTarget _ _ -> logicalFieldTensorType field
          FieldComponentTarget _ _ _ -> TensorType [] [] 0
  where
    target = feEquationTarget equation
    actual = tensorTypeOfNF (feEquationRhs equation)

validateMaterializeTarget
    :: Environment -> [ValidationPath] -> FieldId -> FEValue -> [ValidationError]
validateMaterializeTarget environment path fieldId value =
  case lookupField environment fieldId of
    Nothing ->
      [validationError path (UnknownReference FieldIds (show fieldId))]
    Just field -> concat
      [ [validationError path
           (InvalidFieldLifetime fieldId StepLocalLifetime
             (logicalFieldLifetime field))
        | logicalFieldLifetime field /= StepLocalLifetime]
      , [validationError path (TensorTypeMismatch expected actual)
        | expected /= actual]
      ]
      where
        expected = logicalFieldTensorType field
        actual = tensorTypeOfValue value

validateFEValue
    :: Environment
    -> ValueContext
    -> [ValidationPath]
    -> FEValue
    -> [ValidationError]
validateFEValue environment context path value =
  case value of
    ScalarValue scalar -> validateScalar environment context path scalar
    TensorValue tensor -> validateTensorNF environment context path tensor

validateTensorNF
    :: Environment
    -> ValueContext
    -> [ValidationPath]
    -> TensorNF
    -> [ValidationError]
validateTensorNF environment context path tensor = concat
  [ validateTensorType environment path (tensorTypeOfNF tensor)
  , [validationError path (NonCanonicalOrder "tensor components")
    | actualBases /= sort actualBases]
  , [validationError path (ComponentBasisMismatch expectedBases actualBases)
    | actualBases /= expectedBases]
  , concat
      [ validateBasis componentPath shape basis
        ++ validateScalar environment context componentPath scalar
      | (basis, scalar) <- tensorNFComponents tensor
      , let componentPath = path ++ [TensorComponentPath basis]
      ]
  ]
  where
    shape = tensorNFShape tensor
    expectedBases = fullRowMajorBases shape
    actualBases = map fst (tensorNFComponents tensor)

validateTensorType
    :: Environment -> [ValidationPath] -> TensorType -> [ValidationError]
validateTensorType environment path tensorType = concat
  [ [validationError path (InvalidShape shape)
    | any (<= 0) shape]
  , [validationError path (TensorAxisDimensionMismatch dimension shape)
    | any (/= dimension) shape]
  , [validationError path
       (VarianceCountMismatch (length shape) (length variances))
    | length variances /= length shape]
  , [validationError path
       (InvalidDifferentialFormOrder dfOrder (length shape))
    | dfOrder < 0 || dfOrder > length shape]
  ]
  where
    dimension = feProgramDimension (environmentProgram environment)
    shape = tensorTypeShape tensorType
    variances = tensorTypeVariances tensorType
    dfOrder = tensorTypeDfOrder tensorType

validateFieldLayout :: [ValidationPath] -> LogicalFieldDecl -> [ValidationError]
validateFieldLayout path field =
  [validationError path (InvalidLayout layout tensorType)
  | not valid]
  where
    layout = logicalFieldLayout field
    tensorType = logicalFieldTensorType field
    shape = tensorTypeShape tensorType
    dfOrder = tensorTypeDfOrder tensorType
    rank = length shape
    equalAxes = case shape of
      [] -> True
      firstAxis : _ -> all (== firstAxis) shape
    valid = case layout of
      ScalarLayout -> null shape && dfOrder == 0
      VectorLayout -> rank == 1 && dfOrder == 0
      SymmetricLayout -> rank == 2 && equalAxes && dfOrder == 0
      AntisymmetricLayout -> rank == 2 && equalAxes && dfOrder == 0
      FullLayout -> rank == 2 && dfOrder == 0
      FormLayout -> dfOrder == rank && equalAxes

validateDeclaredVariances
    :: [ValidationPath] -> LogicalFieldDecl -> [ValidationError]
validateDeclaredVariances path field =
  [validationError path
     (DeclaredVarianceCountMismatch (length semantic) (length declared))
  | length declared /= length semantic]
  ++ concat
    [ case marker of
        Just actual
          | actual /= expected ->
              [validationError path
                 (DeclaredVarianceMismatch index expected actual)]
        _ -> []
    | (index, (expected, marker)) <- zip [1 ..] (zip semantic declared)
    ]
  where
    semantic = tensorTypeVariances (logicalFieldTensorType field)
    declared = logicalFieldDeclaredVariances field

validateScalar
    :: Environment
    -> ValueContext
    -> [ValidationPath]
    -> ScalarNF
    -> [ValidationError]
validateScalar environment context path scalar =
  case scalar of
    Exact numerator denominator ->
      validateExact path numerator denominator
    NamedConstant _ -> []
    Parameter parameterId ->
      validateSimpleReference path ParameterIds
        (show parameterId) (parameterId `elem` environmentParameterIds environment)
    Coordinate axisId ->
      validateSimpleReference path AxisIds
        (show axisId) (axisId `elem` environmentAxisIds environment)
    Add operands ->
      validateAdd operands
    Mul operands ->
      validateMul operands
    Div numerator denominator ->
      validateScalar environment context (childPath 0) numerator
      ++ validateScalar environment context (childPath 1) denominator
      ++ [validationError path DivisionByZero
         | denominator == Exact 0 1]
      ++ [validationError path (NonCanonicalScalarForm "unit denominator")
         | denominator == Exact 1 1]
      ++ [validationError path (NonCanonicalScalarForm "negative unit denominator")
         | denominator == Exact (-1) 1]
      ++ [validationError path (NonCanonicalScalarForm "zero numerator")
         | numerator == Exact 0 1 && denominator /= Exact 0 1]
      ++ [validationError path (NonCanonicalScalarForm "self division")
         | numerator == denominator && denominator /= Exact 0 1]
      ++ [validationError path (NonCanonicalScalarForm "foldable exact division")
         | isExactScalar numerator
         , isExactScalar denominator
         , denominator /= Exact 0 1]
    Pow base power ->
      validateScalar environment context (childPath 0) base
      ++ validateScalar environment context (childPath 1) power
      ++ [validationError path (NonCanonicalScalarForm "trivial power")
         | power == Exact 0 1 || power == Exact 1 1]
      ++ [validationError path (NonCanonicalScalarForm "unit power base")
         | base == Exact 1 1]
      ++ [validationError path (NonCanonicalScalarForm "foldable exact power")
         | foldableExactPower base power]
    Intrinsic functionId arguments ->
      validateFunctionCall environment context path
        IntrinsicFunction functionId arguments
    AnalyticCall functionId arguments ->
      validateAnalyticCall environment context path functionId arguments
    Select predicate yes no ->
      validatePredicate environment context (path ++ [PredicateChildPath 0]) predicate
      ++ validateScalar environment context (childPath 1) yes
      ++ validateScalar environment context (childPath 2) no
    FieldJet fieldJet -> validateFieldJet environment context path fieldJet
    OpaqueDiscrete opaque -> validateOpaque environment context path opaque
    Ref node -> validateRef environment context path node
  where
    childPath index = path ++ [ScalarChildPath index]
    validateScalarList operands = concat
      [ validateScalar environment context (childPath index) operand
      | (index, operand) <- zip [0 ..] operands
      ]
    validateScalarCollection label nested identity operands = concat
      [ validateScalarList operands
      , [validationError path (NonCanonicalOrder (label ++ " operands"))
        | scalarOrderKeys operands /= sort (scalarOrderKeys operands)]
      , [validationError path (NonCanonicalScalarForm
            (label ++ " requires at least two operands"))
        | length operands < 2]
      , [validationError path (NonCanonicalScalarForm
            ("nested " ++ label))
        | any nested operands]
      , [validationError path (NonCanonicalScalarForm
            (label ++ " contains an identity/absorbing operand"))
        | any identity operands]
      ]
    validateAdd operands =
      validateScalarCollection "add" isAdd isAddIdentity operands
      ++ [validationError path (NonCanonicalScalarForm
            "add contains uncombined like terms")
         | hasDuplicates (map coefficientFreeTerm operands)]
    validateMul operands =
      validateScalarCollection "mul" isMul isMulIdentity operands
      ++ [validationError path (NonCanonicalScalarForm
            "mul contains multiple exact coefficients")
         | length (filter isExactScalar operands) > 1]
      ++ [validationError path (NonCanonicalScalarForm
            "mul contains repeated symbolic factors")
         | hasDuplicates (filter (not . isExactScalar) operands)]
    isAdd (Add _) = True
    isAdd _ = False
    isMul (Mul _) = True
    isMul _ = False
    isAddIdentity (Exact 0 1) = True
    isAddIdentity _ = False
    isMulIdentity (Exact 0 1) = True
    isMulIdentity (Exact 1 1) = True
    isMulIdentity _ = False

validatePredicate
    :: Environment
    -> ValueContext
    -> [ValidationPath]
    -> PredicateNF
    -> [ValidationError]
validatePredicate environment context path predicate =
  case predicate of
    BoolExact _ -> []
    Compare _ lhs rhs ->
      validateScalar environment context (path ++ [ScalarChildPath 0]) lhs
      ++ validateScalar environment context (path ++ [ScalarChildPath 1]) rhs
      ++ [validationError path (NonCanonicalPredicateForm "self comparison")
         | lhs == rhs]
    Not body ->
      validatePredicate environment context path body
      ++ [validationError path (NonCanonicalPredicateForm "trivial not")
         | isBoolean body || isNot body]
    And parts -> validatePredicateCollection "and" isAnd parts
    Or parts -> validatePredicateCollection "or" isOr parts
  where
    validateParts parts = concat
      [ validatePredicate environment context
          (path ++ [PredicateChildPath index]) part
      | (index, part) <- zip [0 ..] parts
      ]
    validatePredicateCollection label nested parts = concat
      [ validateParts parts
      , [validationError path (NonCanonicalOrder (label ++ " predicates"))
        | predicateOrderKeys parts /= sort (predicateOrderKeys parts)]
      , [validationError path (NonCanonicalPredicateForm
            (label ++ " requires at least two operands"))
        | length parts < 2]
      , [validationError path (NonCanonicalPredicateForm
            ("nested " ++ label))
        | any nested parts]
      , [validationError path (NonCanonicalPredicateForm
            (label ++ " contains duplicate predicates"))
        | hasDuplicates parts]
      , [validationError path (NonCanonicalPredicateForm
            (label ++ " contains a boolean identity/absorbing operand"))
        | any isBoolean parts]
      ]
    isBoolean (BoolExact _) = True
    isBoolean _ = False
    isNot (Not _) = True
    isNot _ = False
    isAnd (And _) = True
    isAnd _ = False
    isOr (Or _) = True
    isOr _ = False

validateFunctionCall
    :: Environment
    -> ValueContext
    -> [ValidationPath]
    -> FunctionClass
    -> FunctionId
    -> [ScalarNF]
    -> [ValidationError]
validateFunctionCall environment context path expectedClass functionId arguments =
  case lookupFunction environment functionId of
    Nothing ->
      [validationError path (UnknownReference FunctionIds (show functionId))]
      ++ argumentErrors
    Just function -> concat
      [ [validationError path
           (FunctionClassMismatch functionId expectedClass
             (functionDeclClass function))
        | functionDeclClass function /= expectedClass]
      , [validationError path
           (FunctionArityMismatch functionId expectedArity (length arguments))
        | Just expectedArity <- [functionDeclArity function]
        , expectedArity /= length arguments]
      , argumentErrors
      ]
  where
    argumentErrors = concat
      [ validateScalar environment context
          (path ++ [ScalarChildPath index]) argument
      | (index, argument) <- zip [0 ..] arguments
      ]

validateAnalyticCall
    :: Environment
    -> ValueContext
    -> [ValidationPath]
    -> FunctionId
    -> [ScalarNF]
    -> [ValidationError]
validateAnalyticCall environment context path functionId arguments =
  case lookupFunction environment functionId of
    Just function
      | functionDeclClass function /= IntrinsicFunction ->
          arityErrors function ++ argumentErrors
    _ -> validateFunctionCall environment context path
           AnalyticFunction functionId arguments
  where
    arityErrors function =
      [validationError path
         (FunctionArityMismatch functionId expectedArity (length arguments))
      | Just expectedArity <- [functionDeclArity function]
      , expectedArity /= length arguments]
    argumentErrors = concat
      [ validateScalar environment context
          (path ++ [ScalarChildPath index]) argument
      | (index, argument) <- zip [0 ..] arguments
      ]

validateFieldJet
    :: Environment
    -> ValueContext
    -> [ValidationPath]
    -> FieldJet
    -> [ValidationError]
validateFieldJet environment context path fieldJet =
  case lookupField environment fieldId of
    Nothing ->
      [validationError path (UnknownReference FieldIds (show fieldId))]
      ++ commonErrors
    Just field -> concat
      [ commonErrors
      , validateBasis path
          (tensorTypeShape (logicalFieldTensorType field))
          (fieldJetBasis fieldJet)
      , validateFieldAvailability path context field
          (fieldJetTimeSlot fieldJet)
      ]
  where
    fieldId = fieldJetFieldId fieldJet
    expectedArguments = map Coordinate (environmentAxisIds environment)
    arguments = fieldJetArguments fieldJet
    multiIndex = fieldJetMultiIndex fieldJet
    commonErrors = concat
      [ [validationError path
           (NonCanonicalFieldArguments expectedArguments arguments)
        | arguments /= expectedArguments]
      , concat
          [ validateScalar environment StaticValueContext
              (path ++ [ScalarChildPath index]) argument
          | (index, argument) <- zip [0 ..] arguments
          ]
      , validateMultiIndex environment path multiIndex
      ]

validateMultiIndex
    :: Environment
    -> [ValidationPath]
    -> [(AxisId, Natural)]
    -> [ValidationError]
validateMultiIndex environment path multiIndex = concat
  [ concat
      [ validateSimpleReference path AxisIds (show axisId)
          (axisId `elem` environmentAxisIds environment)
      | (axisId, _) <- multiIndex
      ]
  , [validationError path (NonCanonicalMultiIndex multiIndex)
    | any ((== 0) . snd) multiIndex
      || hasDuplicates (map fst multiIndex)
      || map fst multiIndex /= sort (map fst multiIndex)]
  ]

validateFieldAvailability
    :: [ValidationPath]
    -> ValueContext
    -> LogicalFieldDecl
    -> TimeSlot
    -> [ValidationError]
validateFieldAvailability path context field timeSlot =
  case context of
    StaticValueContext -> unavailable
    InitializerValueContext ->
      if lifetime == UserStateLifetime && timeSlot == CurrentTime
        then [] else unavailable
    StepValueContext _ availableLocals availableNext ->
      case (lifetime, timeSlot) of
        (UserStateLifetime, CurrentTime) -> []
        (UserStateLifetime, NextTime)
          | fieldId `elem` availableNext -> []
        (StepLocalLifetime, CurrentTime)
          | fieldId `elem` availableLocals -> []
        _ -> unavailable
  where
    fieldId = logicalFieldId field
    lifetime = logicalFieldLifetime field
    unavailable =
      [validationError path (FieldValueNotAvailable fieldId timeSlot)]

validateRef
    :: Environment
    -> ValueContext
    -> [ValidationPath]
    -> NodeId
    -> [ValidationError]
validateRef environment context path node
  | node `notElem` environmentNodeIds environment =
      [validationError path (UnknownReference NodeIds (show node))]
  | otherwise =
      case context of
        StepValueContext available _ _
          | node `elem` available -> []
          | otherwise -> [validationError path (RefNotPreceding node)]
        _ -> [validationError path (RefOutsideActionStream node)]

validateOpaque
    :: Environment
    -> ValueContext
    -> [ValidationPath]
    -> OpaqueDiscrete
    -> [ValidationError]
validateOpaque environment context parentPath opaque = concat
  [ nonEmptyStringId path OpaqueOperationIds opText
  , signatureErrors
  , [validationError path EmptyOpaqueSemanticKey | null semanticText]
  , [validationError path EmptyOpaqueRequestGroup | null requestGroupText]
  , validateLooseBasis environment path (opaqueDiscreteResultBasis opaque)
  , concat
      [ validateFEValue environment context
          (path ++ [ScalarChildPath index]) operand
      | (index, operand) <- zip [0 ..] (opaqueDiscreteOperands opaque)
      ]
  , duplicateIdErrors AttributeIds
      (map (show . attributeId) attributes) path
  , [validationError path (NonCanonicalOrder "opaque attributes")
    | map attributeId attributes /= sort (map attributeId attributes)]
  , concatMap validateAttribute attributes
  ]
  where
    opId@(OpId opText) = opaqueDiscreteOpId opaque
    semanticKey@(SemanticKey semanticText) = opaqueDiscreteSemanticKey opaque
    RequestGroupId requestGroupText = opaqueDiscreteRequestGroup opaque
    path = parentPath ++ [OpaquePath semanticKey]
    attributes = opaqueDiscreteAttributes opaque
    signatureErrors =
      case lookupSignature opId of
        Nothing ->
          [validationError path (UnknownOpaqueOperation opId)
          | not (null opText)]
        Just signature -> concat
          [ validateOperandContract signature
          , validateOutputContract signature
          , validateEffectContract signature
          , validatePlacementContract signature
          ]

    lookupSignature operationId =
      case [ signature
           | signature <- validationPrimitiveSignatures
               (environmentConfig environment)
           , primitiveSignatureOpId signature == operationId
           ] of
        [signature] -> Just signature
        _ -> Nothing

    validateOperandContract signature =
      [ validationError path
          (OpaqueOperandCountMismatch opId
            (length expectedCategories) (length operands))
      | length operands /= length expectedCategories
      ]
      ++
      [ validationError (path ++ [ScalarChildPath index])
          (OpaqueOperandCategoryMismatch opId index category)
      | (index, (category, operand)) <- zip [0 ..]
          (zip expectedCategories operands)
      , not (valueMatchesCategory category operand)
      ]
      where
        expectedCategories = primitiveSignatureInputs signature
        operands = opaqueDiscreteOperands opaque

    validateOutputContract signature =
      [ validationError path
          (OpaqueOutputCategoryMismatch opId category resultBasis)
      | not (resultBasisMatchesCategory category resultBasis)
      ]
      where
        category = primitiveSignatureOutput signature
        resultBasis = opaqueDiscreteResultBasis opaque

    validateEffectContract signature =
      case primitiveSignatureEffect signature of
        PureLocal -> []
        effect@(NeedsMaterialization _) ->
          [validationError path (OpaqueEffectContextMismatch opId effect)
          | not (isStepContext context)]

    validatePlacementContract signature =
      case primitiveSignaturePlacement signature of
        ConservativeCellPlacement ->
          [ validationError path
              (OpaquePlacementContractMismatch opId
                ConservativeCellPlacement resultBasis)
          | resultBasis /= Basis []
          ]
        _ -> []
      where
        resultBasis = opaqueDiscreteResultBasis opaque

    validateAttribute attribute =
      let attributePath = path ++ [AttributePath (attributeId attribute)]
          AttributeId attributeText = attributeId attribute
      in nonEmptyStringId attributePath AttributeIds attributeText
         ++ validateAttributeValue environment attributePath
              (attributeValue attribute)

valueMatchesCategory :: ValueCategory -> FEValue -> Bool
valueMatchesCategory ScalarCategory (ScalarValue _) = True
valueMatchesCategory TensorCategory (TensorValue tensor) =
  tensorNFDfOrder tensor == 0
valueMatchesCategory FormCategory (TensorValue tensor) =
  tensorNFDfOrder tensor > 0
valueMatchesCategory AnyCategory _ = True
valueMatchesCategory _ _ = False

resultBasisMatchesCategory :: ValueCategory -> Basis -> Bool
resultBasisMatchesCategory ScalarCategory basis = basis == Basis []
resultBasisMatchesCategory TensorCategory (Basis indices) = not (null indices)
-- A codifferential may return a degree-zero form, whose component basis is
-- empty.  Its exact degree is an operation-specific attribute contract.
resultBasisMatchesCategory FormCategory _ = True
resultBasisMatchesCategory AnyCategory _ = True

isStepContext :: ValueContext -> Bool
isStepContext (StepValueContext _ _ _) = True
isStepContext _ = False

validateAttributeValue
    :: Environment -> [ValidationPath] -> AttributeValue -> [ValidationError]
validateAttributeValue environment path value =
  case value of
    AttributeExact numerator denominator ->
      validateExact path numerator denominator
    AttributeNatural _ -> []
    AttributeInteger _ -> []
    AttributeBoolean _ -> []
    AttributeString _ -> []
    AttributeAxis axisId ->
      validateSimpleReference path AxisIds (show axisId)
        (axisId `elem` environmentAxisIds environment)
    AttributeParameter parameterId ->
      validateSimpleReference path ParameterIds (show parameterId)
        (parameterId `elem` environmentParameterIds environment)
    AttributeFunction functionId ->
      validateSimpleReference path FunctionIds (show functionId)
        (functionId `elem` map functionDeclId
          (environmentFunctionDecls environment))
    AttributeField fieldId ->
      validateSimpleReference path FieldIds (show fieldId)
        (fieldId `elem` map logicalFieldId
          (environmentFieldDecls environment))
    AttributeGeometry geometryId ->
      validateSimpleReference path GeometryIds (show geometryId)
        (geometryId == environmentGeometryId environment)
    AttributeGridPolicy _ -> []
    AttributeTimeSlot _ -> []
    AttributeBasis basis -> validateLooseBasis environment path basis
    AttributeValues values -> concat
      [ validateAttributeValue environment
          (path ++ [ScalarChildPath index]) element
      | (index, element) <- zip [0 ..] values
      ]

validateOpaqueSemanticKeys :: Environment -> [ValidationError]
validateOpaqueSemanticKeys environment =
  [validationError [ProgramPath, OpaquePath key]
     (ConflictingOpaqueSemanticKey key)
  | key <- nub (map opaqueDiscreteSemanticKey calls)
  , let sameKey = filter ((== key) . opaqueDiscreteSemanticKey) calls
  , not (allSameOpaquePayload sameKey)
  ]
  where
    calls = collectProgramOpaqueCalls (environmentProgram environment)

allSameOpaquePayload :: [OpaqueDiscrete] -> Bool
allSameOpaquePayload [] = True
allSameOpaquePayload (first : rest) = all (sameOpaquePayload first) rest

sameOpaquePayload :: OpaqueDiscrete -> OpaqueDiscrete -> Bool
sameOpaquePayload lhs rhs =
  opaqueDiscreteOpId lhs == opaqueDiscreteOpId rhs
  && opaqueDiscreteResultBasis lhs == opaqueDiscreteResultBasis rhs
  && opaqueDiscreteOperands lhs == opaqueDiscreteOperands rhs
  && opaqueDiscreteAttributes lhs == opaqueDiscreteAttributes rhs

validateExact
    :: [ValidationPath] -> Integer -> Integer -> [ValidationError]
validateExact path numerator denominator =
  [validationError path (NonCanonicalExact numerator denominator)
  | denominator <= 0 || gcd (abs numerator) denominator /= 1]

isExactScalar :: ScalarNF -> Bool
isExactScalar (Exact _ _) = True
isExactScalar _ = False

scalarOrderKeys :: [ScalarNF] -> [String]
scalarOrderKeys = map (renderSExpr . encodeScalarNF)

predicateOrderKeys :: [PredicateNF] -> [String]
predicateOrderKeys = map (renderSExpr . encodePredicateNF)

-- Add terms are compared after removing their exact coefficient.  A constant
-- has no symbolic base, so multiple constants are likewise an uncombined
-- coefficient group.
coefficientFreeTerm :: ScalarNF -> Maybe ScalarNF
coefficientFreeTerm scalar =
  case scalar of
    Exact _ _ -> Nothing
    Mul factors ->
      case filter (not . isExactScalar) factors of
        [] -> Nothing
        [factor] -> Just factor
        symbolicFactors -> Just (Mul symbolicFactors)
    _ -> Just scalar

foldableExactPower :: ScalarNF -> ScalarNF -> Bool
foldableExactPower base power =
  case (base, power) of
    (Exact numerator _, Exact exponentValue 1) ->
      exponentValue >= 0 || numerator /= 0
    _ -> False

validateBasis
    :: [ValidationPath] -> [Int] -> Basis -> [ValidationError]
validateBasis path shape basis@(Basis indices) =
  [validationError path (InvalidBasis basis shape)
  | length indices /= length shape
    || or [index < 1 || index > size | (index, size) <- zip indices shape]]

validateLooseBasis
    :: Environment -> [ValidationPath] -> Basis -> [ValidationError]
validateLooseBasis environment path basis@(Basis indices) =
  [validationError path (InvalidBasis basis (replicate (length indices) dimension))
  | any (\index -> index < 1 || index > dimension) indices]
  where
    dimension = feProgramDimension (environmentProgram environment)

validateOriginReference
    :: Environment -> [ValidationPath] -> OriginId -> [ValidationError]
validateOriginReference environment path originId =
  validateSimpleReference path OriginIds (show originId)
    (originId `elem` environmentOriginIds environment)

validateSimpleReference
    :: [ValidationPath] -> IdNamespace -> String -> Bool -> [ValidationError]
validateSimpleReference _ _ _ True = []
validateSimpleReference path namespace rendered False =
  [validationError path (UnknownReference namespace rendered)]

nonEmptyStringId
    :: [ValidationPath] -> IdNamespace -> String -> [ValidationError]
nonEmptyStringId path namespace value =
  [validationError path (EmptyIdentifier namespace) | null value]

numericIdErrors
    :: IdNamespace
    -> (identifier -> ValidationPath)
    -> (identifier -> Int)
    -> [identifier]
    -> [ValidationError]
numericIdErrors namespace pathFor number identifiers =
  [validationError [ProgramPath, pathFor identifier]
     (NonPositiveIdentifier namespace (number identifier))
  | identifier <- identifiers, number identifier <= 0]

duplicateIdErrors
    :: IdNamespace -> [String] -> [ValidationPath] -> [ValidationError]
duplicateIdErrors namespace rendered path =
  [validationError path (DuplicateIdentifier namespace duplicate)
  | duplicate <- duplicates rendered]

duplicateNameErrors
    :: String -> [String] -> [ValidationPath] -> [ValidationError]
duplicateNameErrors label names path =
  [validationError path (DuplicateName label duplicate)
  | duplicate <- duplicates (filter (not . null) names)]

canonicalIdOrder
    :: Ord identifier
    => String -> [identifier] -> [ValidationPath] -> [ValidationError]
canonicalIdOrder label identifiers path =
  [validationError path (NonCanonicalOrder label)
  | identifiers /= sort identifiers]

duplicates :: Ord a => [a] -> [a]
duplicates = duplicateHeads . group . sort
  where
    duplicateHeads [] = []
    duplicateHeads (values : rest) =
      case values of
        first : _
          | length values > 1 -> first : duplicateHeads rest
        _ -> duplicateHeads rest

hasDuplicates :: Ord a => [a] -> Bool
hasDuplicates values = not (null (duplicates values))

validationError :: [ValidationPath] -> ValidationIssue -> ValidationError
validationError = ValidationError

originKeys :: OriginTable -> [OriginId]
originKeys (OriginTable entries) = map fst entries

actionNodeIds :: [FEAction] -> [NodeId]
actionNodeIds actions = [node | BindValue node _ _ <- actions]

programEquationIds :: FEProgram -> [EquationId]
programEquationIds program =
  [feEquationId equation
  | AnalyticInitializer equation <- feProgramInitializers program]
  ++ [feEquationId equation
     | UpdateField equation <- feProgramStepActions program]

targetFieldId :: FieldTarget -> FieldId
targetFieldId target = case target of
  WholeFieldTarget fieldId _ -> fieldId
  FieldComponentTarget fieldId _ _ -> fieldId

targetTimeSlot :: FieldTarget -> TimeSlot
targetTimeSlot target = case target of
  WholeFieldTarget _ timeSlot -> timeSlot
  FieldComponentTarget _ timeSlot _ -> timeSlot

lookupField :: Environment -> FieldId -> Maybe LogicalFieldDecl
lookupField environment fieldId =
  firstMatch ((== fieldId) . logicalFieldId)
    (environmentFieldDecls environment)

lookupFunction :: Environment -> FunctionId -> Maybe FunctionDecl
lookupFunction environment functionId =
  firstMatch ((== functionId) . functionDeclId)
    (environmentFunctionDecls environment)

firstMatch :: (a -> Bool) -> [a] -> Maybe a
firstMatch _ [] = Nothing
firstMatch predicate (value : rest)
  | predicate value = Just value
  | otherwise = firstMatch predicate rest

tensorTypeOfNF :: TensorNF -> TensorType
tensorTypeOfNF tensor = TensorType
  { tensorTypeShape = tensorNFShape tensor
  , tensorTypeVariances = tensorNFVariances tensor
  , tensorTypeDfOrder = tensorNFDfOrder tensor
  }

tensorTypeOfValue :: FEValue -> TensorType
tensorTypeOfValue value = case value of
  ScalarValue _ -> TensorType [] [] 0
  TensorValue tensor -> tensorTypeOfNF tensor

fullRowMajorBases :: [Int] -> [Basis]
fullRowMajorBases [] = [Basis []]
fullRowMajorBases (size : rest) =
  [ Basis (index : indices)
  | index <- [1 .. size]
  , Basis indices <- fullRowMajorBases rest
  ]

validLatticeFamily :: DerivativeRule -> Bool
validLatticeFamily rule =
  case (derivativeRuleLatticeClass rule, derivativeRuleFamily rule) of
    (CollocatedLattice, CenteredTaylor) -> True
    (StaggeredLattice, Yee) -> True
    _ -> False

derivativeRuleKey :: DerivativeRule -> (LatticeClass, Maybe Int)
derivativeRuleKey rule =
  (derivativeRuleLatticeClass rule, orderValue)
  where
    orderValue = case derivativeRuleOrder rule of
      Nothing -> Nothing
      Just (Positive order) -> Just order

duplicateRuleErrors :: [DerivativeRule] -> [ValidationError]
duplicateRuleErrors rules =
  [validationError [ProgramPath, ProfilePath]
     (DuplicateDerivativeRule lattice order)
  | (lattice, order) <- duplicates (map derivativeRuleKey rules)]

collectProgramOpaqueCalls :: FEProgram -> [OpaqueDiscrete]
collectProgramOpaqueCalls program = concat
  [ collectGeometryOpaqueCalls (geometryDeclKind (feProgramGeometry program))
  , concatMap collectInitializerOpaqueCalls (feProgramInitializers program)
  , concatMap collectActionOpaqueCalls (feProgramStepActions program)
  ]

collectGeometryOpaqueCalls :: GeometryKind -> [OpaqueDiscrete]
collectGeometryOpaqueCalls geometryKind =
  case geometryKind of
    EuclideanGeometry -> []
    OrthogonalScaleGeometry scales geometryNF ->
      concatMap (collectScalarOpaqueCalls . snd) scales
      ++ collectGeometryNFOpaqueCalls geometryNF
    EmbeddedOrthogonalGeometry embedding geometryNF ->
      concatMap collectScalarOpaqueCalls embedding
      ++ collectGeometryNFOpaqueCalls geometryNF

collectGeometryNFOpaqueCalls :: GeometryNF -> [OpaqueDiscrete]
collectGeometryNFOpaqueCalls geometryNF = concat
  [ collectTensorOpaqueCalls (geometryMetricComponents geometryNF)
  , collectTensorOpaqueCalls (geometryInverseMetric geometryNF)
  , concatMap (collectScalarOpaqueCalls . snd)
      (geometryScaleFactors geometryNF)
  , collectScalarOpaqueCalls (geometryVolumeElement geometryNF)
  ]

collectInitializerOpaqueCalls :: FEInitializer -> [OpaqueDiscrete]
collectInitializerOpaqueCalls initializer =
  case initializer of
    AnalyticInitializer equation ->
      collectTensorOpaqueCalls (feEquationRhs equation)
    RawInitializer _ _ _ -> []

collectActionOpaqueCalls :: FEAction -> [OpaqueDiscrete]
collectActionOpaqueCalls action =
  case action of
    BindValue _ value _ -> collectValueOpaqueCalls value
    Materialize _ value _ -> collectValueOpaqueCalls value
    UpdateField equation -> collectTensorOpaqueCalls (feEquationRhs equation)

collectValueOpaqueCalls :: FEValue -> [OpaqueDiscrete]
collectValueOpaqueCalls value =
  case value of
    ScalarValue scalar -> collectScalarOpaqueCalls scalar
    TensorValue tensor -> collectTensorOpaqueCalls tensor

collectTensorOpaqueCalls :: TensorNF -> [OpaqueDiscrete]
collectTensorOpaqueCalls =
  concatMap (collectScalarOpaqueCalls . snd) . tensorNFComponents

collectScalarOpaqueCalls :: ScalarNF -> [OpaqueDiscrete]
collectScalarOpaqueCalls scalar =
  case scalar of
    Exact _ _ -> []
    NamedConstant _ -> []
    Parameter _ -> []
    Coordinate _ -> []
    Add operands -> concatMap collectScalarOpaqueCalls operands
    Mul operands -> concatMap collectScalarOpaqueCalls operands
    Div lhs rhs -> collectScalarOpaqueCalls lhs ++ collectScalarOpaqueCalls rhs
    Pow lhs rhs -> collectScalarOpaqueCalls lhs ++ collectScalarOpaqueCalls rhs
    Intrinsic _ arguments -> concatMap collectScalarOpaqueCalls arguments
    AnalyticCall _ arguments -> concatMap collectScalarOpaqueCalls arguments
    Select predicate yes no ->
      collectPredicateOpaqueCalls predicate
      ++ collectScalarOpaqueCalls yes
      ++ collectScalarOpaqueCalls no
    FieldJet _ -> []
    OpaqueDiscrete opaque ->
      opaque : concatMap collectValueOpaqueCalls (opaqueDiscreteOperands opaque)
    Ref _ -> []

collectPredicateOpaqueCalls :: PredicateNF -> [OpaqueDiscrete]
collectPredicateOpaqueCalls predicate =
  case predicate of
    BoolExact _ -> []
    Compare _ lhs rhs ->
      collectScalarOpaqueCalls lhs ++ collectScalarOpaqueCalls rhs
    Not body -> collectPredicateOpaqueCalls body
    And parts -> concatMap collectPredicateOpaqueCalls parts
    Or parts -> concatMap collectPredicateOpaqueCalls parts
