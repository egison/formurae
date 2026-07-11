{-# LANGUAGE PatternSynonyms #-}

module Formurae.Pre.Registry
  ( PreRegistry(..)
  , RegistryError(..)
  , buildRegistry
  ) where

import Data.Char (isAlphaNum)
import Data.List (find, sortOn, stripPrefix)

import Formurae.Common (strip)
import Formurae.FEIR.Codec (setProfileFingerprint)
import qualified Formurae.FEIR.Syntax as FEIR
import qualified Formurae.Index as Index
import qualified Formurae.Syntax as Surface
import Formurae.TensorExpr
  ( SourceSpan(..)
  , TensorExpr
  , parseTensorExprEither
  , pattern TEAppendIndexed
  , pattern TEApply
  , pattern TEBinary
  , pattern TECall
  , pattern TEContractWith
  , pattern TEDerivative
  , pattern TEDisjoint
  , pattern TEDot
  , pattern TEGroup
  , pattern TEIdent
  , pattern TEIf
  , pattern TENumber
  , pattern TESubrefs
  , pattern TETensorMap
  , pattern TETranspose
  , pattern TEUnary
  , pattern TEWithSymbols
  , tensorExprSpan
  )

data PreRegistry = PreRegistry
  { preRegistryModelIdentity  :: FEIR.ModelIdentity
  , preRegistryAxes           :: [FEIR.AxisDecl]
  , preRegistryParameters     :: [FEIR.ParameterDecl]
  , preRegistryFunctions      :: [FEIR.FunctionDecl]
  , preRegistryFields         :: [FEIR.LogicalFieldDecl]
  , preRegistryGeometry       :: FEIR.GeometryDecl
  , preRegistryDiscretization :: FEIR.DiscretizationProfile
  , preRegistryRawHelpers     :: [FEIR.RawHelper]
  , preRegistryOrigins        :: FEIR.OriginTable
  , preRegistryDefinitionOrigins :: [FEIR.OriginId]
  , preRegistryInitializerOrigins :: [FEIR.OriginId]
  , preRegistryStepOrigins       :: [FEIR.OriginId]
  } deriving (Eq, Ord, Show)

data RegistryError
  = MissingAxesDeclarationOrigin
  | DeclarationOriginCountMismatch String Int Int
  | MissingOrigin String
  | MissingDefinitionSourceText Int
  | InvalidTraceExpression String String
  | InvalidTraceSourceSpan String Int Int
  | UnsupportedRegistryGeometry
  deriving (Eq, Ord, Show)

data OriginKey
  = AxesOrigin
  | ParameterOrigin Int
  | HelperOrigin Int
  | FieldOrigin Int
  | ProfileOrigin Int
  | DefinitionOrigin Int
  | InitializerOrigin Int
  | StepOrigin Int
  deriving (Eq, Ord, Show)

data OriginSeed = OriginSeed
  { originSeedKey         :: OriginKey
  , originSeedLine        :: Int
  , originSeedColumn      :: Int
  , originSeedEndLine     :: Int
  , originSeedEndColumn   :: Int
  } deriving (Eq, Ord, Show)

type OriginAssignments = [(OriginKey, FEIR.OriginId)]

data TraceDefinition = TraceDefinition
  { traceDefinitionIndex      :: Int
  , traceDefinitionName       :: String
  , traceDefinitionParameters :: [String]
  , traceDefinitionSource     :: Surface.SourceText
  , traceDefinitionExpression :: TensorExpr
  } deriving (Eq, Show)

data LocatedDefinitionCall = LocatedDefinitionCall
  { locatedCallName :: String
  , locatedCallSpan :: SourceSpan
  } deriving (Eq, Show)

buildRegistry :: Surface.Model -> Either RegistryError PreRegistry
buildRegistry model = do
  axesLine <- maybe (Left MissingAxesDeclarationOrigin) Right
    (Surface.mAxesSourceLine model)
  ensureParallel "parameter origins"
    (length (Surface.mParams model)) (length (Surface.mParamSourceLines model))
  ensureParallel "helper origins"
    (length (Surface.mHelp model)) (length (Surface.mHelpSourceLines model))
  ensureParallel "helper kinds"
    (length (Surface.mHelp model)) (length (Surface.mHelpKinds model))
  ensureParallel "initializer origins"
    (length (Surface.mInits model)) (length (Surface.mInitSourceTexts model))
  case (Surface.mMetric model, Surface.mEmbed model) of
    (Just _, Just _) -> Left UnsupportedRegistryGeometry
    _ -> Right ()
  let sourceIdentity = modelSourceIdentity model
      seeds = originSeeds axesLine model
  traces <- buildExpansionTraces sourceIdentity model
  let (assignments, originTable) =
        assignOrigins sourceIdentity traces seeds
  axes <- buildAxes assignments model
  parameters <- buildParameters assignments model
  functions <- buildFunctions assignments model
  fields <- buildFields assignments model
  profile <- buildProfile assignments model
  rawHelpers <- buildRawHelpers assignments model
  geometry <- buildGeometry assignments model
  definitionOrigins <- mapM (originFor assignments . DefinitionOrigin)
    [1 .. length (Surface.mDefs model)]
  initializerOrigins <- mapM (originFor assignments . InitializerOrigin)
    [1 .. length (Surface.mInits model)]
  stepOrigins <- mapM (originFor assignments . StepOrigin)
    [1 .. length (Surface.mSteps model)]
  Right PreRegistry
    { preRegistryModelIdentity = FEIR.ModelIdentity
        (FEIR.ModelId ("model:" ++ Surface.mName model))
        (Surface.mName model) sourceIdentity
    , preRegistryAxes = axes
    , preRegistryParameters = parameters
    , preRegistryFunctions = functions
    , preRegistryFields = fields
    , preRegistryGeometry = geometry
    , preRegistryDiscretization = profile
    , preRegistryRawHelpers = rawHelpers
    , preRegistryOrigins = originTable
    , preRegistryDefinitionOrigins = definitionOrigins
    , preRegistryInitializerOrigins = initializerOrigins
    , preRegistryStepOrigins = stepOrigins
    }

ensureParallel :: String -> Int -> Int -> Either RegistryError ()
ensureParallel label expected actual
  | expected == actual = Right ()
  | otherwise = Left (DeclarationOriginCountMismatch label expected actual)

modelSourceIdentity :: Surface.Model -> FEIR.SourceIdentity
modelSourceIdentity model = FEIR.SourceIdentity
  (FEIR.SourceId ("source:" ++ Surface.mSourcePath model))
  (Surface.mSourcePath model)

originSeeds :: Int -> Surface.Model -> [OriginSeed]
originSeeds axesLine model =
  OriginSeed AxesOrigin axesLine 1 axesLine 1
  : parameterSeeds ++ helperSeeds ++ fieldSeeds ++ profileSeeds
    ++ definitionSeeds ++ initializerSeeds ++ stepSeeds
  where
    parameterSeeds =
      [OriginSeed (ParameterOrigin index) line 1 line 1
      | (index, line) <- zip [1 ..] (Surface.mParamSourceLines model)]
    helperSeeds =
      [OriginSeed (HelperOrigin index) line 1 line 1
      | (index, line) <- zip [1 ..] (Surface.mHelpSourceLines model)]
    fieldSeeds =
      [OriginSeed (FieldOrigin index) (Surface.fdSourceLine field) 1
         (Surface.fdSourceLine field) 1
      | (index, field) <- zip [1 ..] (Surface.mFieldDecls model)]
    profileSeeds =
      [OriginSeed (ProfileOrigin index) line 1 line 1
      | (index, declaration) <- zip [1 ..] (Surface.mDiscretizationDecls model)
      , let line = Surface.discretizationSourceLine declaration]
    definitionSeeds =
      [sourceSeed (DefinitionOrigin index) source
      | (index, definition) <- zip [1 ..] (Surface.mDefs model)
      , Just source <- [Surface.defSourceText definition]]
    initializerSeeds =
      [sourceSeed (InitializerOrigin index) source
      | (index, source) <- zip [1 ..] (Surface.mInitSourceTexts model)]
    stepSeeds =
      [sourceSeed (StepOrigin index) (Surface.sSourceText step)
      | (index, step) <- zip [1 ..] (Surface.mSteps model)]

sourceSeed :: OriginKey -> Surface.SourceText -> OriginSeed
sourceSeed key source = OriginSeed
  { originSeedKey = key
  , originSeedLine = startLine
  , originSeedColumn = startColumn
  , originSeedEndLine = endLine
  , originSeedEndColumn = endColumn
  }
  where
    (startLine, startColumn) = case Surface.sourcePositionMap source of
      firstPosition : _ ->
        (Surface.positionLine firstPosition,
         Surface.positionColumn firstPosition)
      [] -> (Surface.sourceLine source, Surface.sourceColumn source)
    (endLine, endColumn) = case reverse (Surface.sourcePositionMap source) of
      lastPosition : _ ->
        (Surface.positionLine lastPosition,
         Surface.positionColumn lastPosition)
      [] -> (startLine, startColumn)

assignOrigins
  :: FEIR.SourceIdentity
  -> [(OriginKey, [FEIR.ExpansionFrame])]
  -> [OriginSeed]
  -> (OriginAssignments, FEIR.OriginTable)
assignOrigins sourceIdentity traces seeds =
  (assignments, FEIR.OriginTable origins)
  where
    sortedSeeds = sortOn (\seed -> (originSeedLine seed, originSeedColumn seed,
                                     originSeedKey seed)) seeds
    assignments =
      [(originSeedKey seed, FEIR.OriginId identifier)
      | (identifier, seed) <- zip [1 ..] sortedSeeds]
    origins =
      [(FEIR.OriginId identifier,
        seedOrigin sourceIdentity (traceFor (originSeedKey seed)) seed)
      | (identifier, seed) <- zip [1 ..] sortedSeeds]
    traceFor key = maybe [] id (lookup key traces)

seedOrigin
  :: FEIR.SourceIdentity
  -> [FEIR.ExpansionFrame]
  -> OriginSeed
  -> FEIR.SourceOrigin
seedOrigin sourceIdentity trace seed = FEIR.SourceOrigin location trace
  where
    location = FEIR.SourceLocation
      (FEIR.sourceIdentityId sourceIdentity)
      (FEIR.sourceIdentityPath sourceIdentity)
      (originSeedLine seed)
      (originSeedEndLine seed)
      (originSeedColumn seed)
      (originSeedEndColumn seed)

-- | Build equation-level user-definition expansion traces before Egison
-- evaluates the expressions.  The trace is provenance only: it is attached
-- to OriginTable entries and never enters a FunctionData/FieldJet identity.
-- Calls are visited in source order and definition bodies are expanded
-- depth-first.  If one equation contains several independent calls this
-- deterministic sequence is the v1 equation-level trace; no claim is made
-- that an individual CAS-generated term has a unique dynamic call stack.
buildExpansionTraces
  :: FEIR.SourceIdentity
  -> Surface.Model
  -> Either RegistryError [(OriginKey, [FEIR.ExpansionFrame])]
buildExpansionTraces sourceIdentity model = do
  definitions <- buildTraceDefinitions model
  initializerTraces <- mapM (initializerTrace definitions)
    (zip3 [1 ..] (Surface.mInits model) (Surface.mInitSourceTexts model))
  stepTraces <- mapM (stepTrace definitions)
    (zip [1 ..] (Surface.mSteps model))
  Right (initializerTraces ++ stepTraces)
  where
    initializerTrace definitions (index, initializer, source) = do
      trace <- case initializer of
        Surface.ICas _ _ -> traceSource definitions (length definitions)
          [] sourceIdentity source
        Surface.ICasIndex _ _ _ -> traceSource definitions
          (length definitions) [] sourceIdentity source
        _ -> Right []
      Right (InitializerOrigin index, trace)

    stepTrace definitions (index, step) = do
      trace <- traceSource definitions (length definitions) [] sourceIdentity
        (Surface.sSourceText step)
      Right (StepOrigin index, trace)

buildTraceDefinitions
  :: Surface.Model -> Either RegistryError [TraceDefinition]
buildTraceDefinitions model = mapM build
  (zip [1 ..] (Surface.mDefs model))
  where
    build (index, definition) = do
      source <- maybe (Left (MissingDefinitionSourceText index)) Right
        (Surface.defSourceText definition)
      expression <- parseTraceExpression
        ("definition " ++ Surface.defName definition) source
      Right TraceDefinition
        { traceDefinitionIndex = index
        , traceDefinitionName = Surface.defName definition
        , traceDefinitionParameters =
            map definitionParameterBase (Surface.defParams definition)
        , traceDefinitionSource = source
        , traceDefinitionExpression = expression
        }

definitionParameterBase :: String -> String
definitionParameterBase = takeWhile isAlphaNum

parseTraceExpression
  :: String -> Surface.SourceText -> Either RegistryError TensorExpr
parseTraceExpression context source =
  case parseTensorExprEither (Surface.sourceTranslated source) of
    Left message -> Left (InvalidTraceExpression context message)
    Right expression -> Right expression

traceSource
  :: [TraceDefinition]
  -> Int
  -> [Int]
  -> FEIR.SourceIdentity
  -> Surface.SourceText
  -> Either RegistryError [FEIR.ExpansionFrame]
traceSource definitions visibleThrough stack sourceIdentity source = do
  expression <- parseTraceExpression "origin expression" source
  traceExpression definitions visibleThrough stack sourceIdentity
    source [] expression

traceExpression
  :: [TraceDefinition]
  -> Int
  -> [Int]
  -> FEIR.SourceIdentity
  -> Surface.SourceText
  -> [String]
  -> TensorExpr
  -> Either RegistryError [FEIR.ExpansionFrame]
traceExpression definitions visibleThrough stack sourceIdentity source
    boundNames expression =
  concat <$> mapM expand (collectDefinitionCalls resolvable boundNames expression)
  where
    resolvable name = resolveDefinition definitions visibleThrough name /= Nothing

    expand call =
      case resolveDefinition definitions visibleThrough (locatedCallName call) of
        Nothing -> Right []
        Just definition -> do
          definitionLocation <- sourceLocationForSpan sourceIdentity
            (traceDefinitionSource definition)
            (tensorExprSpan (traceDefinitionExpression definition))
          callLocation <- sourceLocationForSpan sourceIdentity source
            (locatedCallSpan call)
          let frame = FEIR.ExpansionFrame
                (traceDefinitionName definition)
                definitionLocation callLocation
              identifier = traceDefinitionIndex definition
          nested <- if identifier `elem` stack
            then Right []
            else traceExpression definitions (identifier - 1)
              (identifier : stack) sourceIdentity
              (traceDefinitionSource definition)
              (traceDefinitionParameters definition)
              (traceDefinitionExpression definition)
          Right (frame : nested)

resolveDefinition
  :: [TraceDefinition] -> Int -> String -> Maybe TraceDefinition
resolveDefinition definitions visibleThrough name =
  find ((== name) . traceDefinitionName)
    (reverse (take visibleThrough definitions))

collectDefinitionCalls
  :: (String -> Bool) -> [String] -> TensorExpr -> [LocatedDefinitionCall]
collectDefinitionCalls isDefinition = go
  where
    go boundNames expression =
      case expression of
        TENumber _ -> []
        TEIdent name _
          | isVisible boundNames name -> [callAt name expression]
          | otherwise -> []
        TEUnary _ body -> go boundNames body
        TECall function arguments ->
          applicationCalls boundNames function arguments
        TEApply function arguments ->
          applicationCalls boundNames function arguments
        TEIf condition yes no -> concatMap (go boundNames) [condition, yes, no]
        TEAppendIndexed body _ -> go boundNames body
        TEWithSymbols names body -> go (names ++ boundNames) body
        TEContractWith _ body -> go boundNames body
        TETensorMap function body ->
          go boundNames function ++ go boundNames body
        TESubrefs body _ -> go boundNames body
        TETranspose _ body -> go boundNames body
        TEDisjoint parts -> concatMap (go boundNames) parts
        TEDerivative _ body -> go boundNames body
        TEDot parts -> concatMap (go boundNames) parts
        TEBinary _ lhs rhs -> go boundNames lhs ++ go boundNames rhs
        TEGroup body -> go boundNames body

    applicationCalls boundNames function arguments =
      case definitionHead boundNames function of
        Just call -> call : concatMap (go boundNames) arguments
        Nothing -> go boundNames function ++ concatMap (go boundNames) arguments

    definitionHead boundNames function =
      case function of
        TEIdent name _
          | isVisible boundNames name -> Just (callAt name function)
        TEGroup body -> definitionHead boundNames body
        _ -> Nothing

    isVisible boundNames name =
      name `notElem` boundNames && isDefinition name

    callAt name expression = LocatedDefinitionCall name (tensorExprSpan expression)

sourceLocationForSpan
  :: FEIR.SourceIdentity
  -> Surface.SourceText
  -> SourceSpan
  -> Either RegistryError FEIR.SourceLocation
sourceLocationForSpan sourceIdentity source spanValue
  | start < 1 || finish < start || finish > length positions =
      Left (InvalidTraceSourceSpan (Surface.sourcePath source) start finish)
  | otherwise =
      let firstPosition = positions !! (start - 1)
          lastPosition = positions !! (finish - 1)
      in Right FEIR.SourceLocation
          { FEIR.sourceLocationSource = FEIR.sourceIdentityId sourceIdentity
          , FEIR.sourceLocationPath = FEIR.sourceIdentityPath sourceIdentity
          , FEIR.sourceLocationLine = Surface.positionLine firstPosition
          , FEIR.sourceLocationEndLine = Surface.positionLine lastPosition
          , FEIR.sourceLocationStartColumn = Surface.positionColumn firstPosition
          , FEIR.sourceLocationEndColumn = Surface.positionColumn lastPosition
          }
  where
    SourceSpan start finish = spanValue
    positions = Surface.sourcePositionMap source

originFor :: OriginAssignments -> OriginKey -> Either RegistryError FEIR.OriginId
originFor assignments key =
  case lookup key assignments of
    Just originId -> Right originId
    Nothing -> Left (MissingOrigin (show key))

buildAxes
  :: OriginAssignments -> Surface.Model -> Either RegistryError [FEIR.AxisDecl]
buildAxes assignments model = do
  origin <- originFor assignments AxesOrigin
  Right
    [FEIR.AxisDecl (FEIR.AxisId identifier) sourceName canonicalName origin
    | (identifier, sourceName, canonicalName) <-
        zip3 [1 ..] (Surface.mAxes model) canonicalAxisNames]
  where
    canonicalAxisNames = take (Surface.mDim model) ["x", "y", "z"]

buildParameters
  :: OriginAssignments -> Surface.Model
  -> Either RegistryError [FEIR.ParameterDecl]
buildParameters assignments model =
  mapM build (zip3 [1 ..] (Surface.mParams model) [1 ..])
  where
    build (identifier, (name, rawValue), originIndex) = do
      origin <- originFor assignments (ParameterOrigin originIndex)
      Right (FEIR.ParameterDecl (FEIR.ParamId identifier)
        name name rawValue origin)

buildFunctions
  :: OriginAssignments -> Surface.Model
  -> Either RegistryError [FEIR.FunctionDecl]
buildFunctions assignments model = do
  intrinsics <- mapM buildIntrinsic
    (zip [1 ..] intrinsicSpecifications)
  externs <- mapM buildExternal externalHelpers
  Right (intrinsics ++ externs)
  where
    buildIntrinsic (identifier, (name, arity)) = do
      origin <- case
          [helperIndex
          | (helperIndex, (kind, helper)) <- zip [1 ..]
              (zip (Surface.mHelpKinds model) (Surface.mHelp model))
          , kind == Surface.ExternalHelper
          , externalName helper == Just name] of
        [] -> Right Nothing
        helperIndex : _ -> Just <$> originFor assignments
          (HelperOrigin helperIndex)
      Right (FEIR.FunctionDecl (FEIR.FunctionId identifier)
        name name (Just arity) FEIR.IntrinsicFunction origin)
    externalHelpers =
      [(index, name)
      | (index, (kind, helper)) <- zip [1 ..]
          (zip (Surface.mHelpKinds model) (Surface.mHelp model))
      , kind == Surface.ExternalHelper
      , Just name <- [externalName helper]
      , name `notElem` map fst intrinsicSpecifications]
    buildExternal (helperIndex, name) = do
      origin <- originFor assignments (HelperOrigin helperIndex)
      let identifier = length intrinsicSpecifications
                       + externalOrdinal helperIndex externalHelpers
      Right (FEIR.FunctionDecl (FEIR.FunctionId identifier)
        name name Nothing FEIR.ExternalFunction (Just origin))

intrinsicSpecifications :: [(String, Int)]
intrinsicSpecifications =
  [ ("sin", 1), ("cos", 1), ("tan", 1)
  , ("asin", 1), ("acos", 1), ("atan", 1), ("atan2", 2)
  , ("sinh", 1), ("cosh", 1), ("tanh", 1)
  , ("exp", 1), ("log", 1), ("sqrt", 1), ("pow", 2), ("fabs", 1)
  ]

externalName :: String -> Maybe String
externalName helper = strip <$> stripPrefix "extern function :: " (strip helper)

externalOrdinal :: Int -> [(Int, String)] -> Int
externalOrdinal helperIndex helpers =
  case [ordinal | (ordinal, (index, _)) <- zip [1 ..] helpers,
                  index == helperIndex] of
    ordinal : _ -> ordinal
    [] -> error "externalOrdinal: missing helper"

buildFields
  :: OriginAssignments -> Surface.Model
  -> Either RegistryError [FEIR.LogicalFieldDecl]
buildFields assignments model = do
  userFields <- mapM buildUserField
    (zip [1 ..] (Surface.mFieldDecls model))
  localFields <- mapM buildLocalField
    (zip [1 ..] (indexedLocalSteps model))
  Right (userFields ++ localFields)
  where
    buildUserField (identifier, field) = do
      origin <- originFor assignments (FieldOrigin identifier)
      Right (logicalFieldFromSurface model (FEIR.FieldId identifier) origin field)
    buildLocalField (localIndex, (stepIndex, step)) = do
      origin <- originFor assignments (StepOrigin stepIndex)
      let identifier = length (Surface.mFieldDecls model) + localIndex
      Right (FEIR.LogicalFieldDecl
        (FEIR.FieldId identifier) (Surface.sNm step) FEIR.CollocatedPolicy
        (FEIR.TensorType [] [] 0) FEIR.ScalarLayout []
        FEIR.StepLocalLifetime origin)

logicalFieldFromSurface
  :: Surface.Model -> FEIR.FieldId -> FEIR.OriginId -> Surface.FieldDecl
  -> FEIR.LogicalFieldDecl
logicalFieldFromSurface model identifier origin field =
  FEIR.LogicalFieldDecl
    identifier (Surface.fdName field) (mapPolicy (Surface.fdPolicy field))
    tensorType layout declaredVariances FEIR.UserStateLifetime origin
  where
    rank = Index.componentRank (Surface.fdKind field)
    shape = replicate rank (Surface.mDim model)
    explicitVariances = fmap (map (mapVariance . Index.ixVariance))
      (Index.fieldIndexParts field)
    semanticVariances = maybe (replicate rank FEIR.VarianceDown) id explicitVariances
    declaredVariances = maybe (replicate rank Nothing) (map Just) explicitVariances
    differentialFormOrder = case Surface.fdKind field of
      Surface.Form degree -> degree
      _ -> 0
    tensorType = FEIR.TensorType shape semanticVariances differentialFormOrder
    layout = case Surface.fdKind field of
      Surface.Scalar -> FEIR.ScalarLayout
      Surface.Vector -> FEIR.VectorLayout
      Surface.Form _ -> FEIR.FormLayout
      Surface.SymM -> FEIR.SymmetricLayout
      Surface.AntiM -> FEIR.AntisymmetricLayout
      Surface.Tensor2 -> FEIR.FullLayout

mapVariance :: Surface.Variance -> FEIR.Variance
mapVariance Surface.VUp = FEIR.VarianceUp
mapVariance Surface.VDown = FEIR.VarianceDown

mapPolicy :: Surface.GridPolicy -> FEIR.GridPolicy
mapPolicy Surface.Collocated = FEIR.CollocatedPolicy
mapPolicy Surface.Primal = FEIR.PrimalPolicy
mapPolicy Surface.Dual = FEIR.DualPolicy

buildGeometry
  :: OriginAssignments -> Surface.Model -> Either RegistryError FEIR.GeometryDecl
buildGeometry assignments model = do
  axesOrigin <- originFor assignments AxesOrigin
  let identifier = FEIR.GeometryId 1
      sourceName = Surface.mMetricName model
      normalForm = placeholderGeometryNF (Surface.mDim model)
      axes = map FEIR.axisDeclId <$> buildAxes assignments model
  axisIds <- axes
  Right $ case (Surface.mMetric model, Surface.mEmbed model) of
    (Nothing, Nothing) ->
      FEIR.GeometryDecl identifier sourceName Nothing FEIR.EuclideanGeometry
    (Just _, Nothing) ->
      FEIR.GeometryDecl identifier sourceName (Just axesOrigin)
        (FEIR.OrthogonalScaleGeometry
          [(axisId, FEIR.Exact 1 1) | axisId <- axisIds] normalForm)
    (Nothing, Just embedding) ->
      FEIR.GeometryDecl identifier sourceName (Just axesOrigin)
        (FEIR.EmbeddedOrthogonalGeometry
          (replicate (length embedding) (FEIR.Exact 0 1)) normalForm)
    (Just _, Just _) -> error "buildGeometry: mutually exclusive geometry inputs"

placeholderGeometryNF :: Int -> FEIR.GeometryNF
placeholderGeometryNF dimension = FEIR.GeometryNF
  identity identity
  [(FEIR.AxisId axis, FEIR.Exact 1 1) | axis <- [1 .. dimension]]
  (FEIR.Exact 1 1) True
  where
    identity = FEIR.TensorNF [dimension, dimension]
      [FEIR.VarianceDown, FEIR.VarianceDown] 0
      [ (FEIR.Basis [row, column],
          FEIR.Exact (if row == column then 1 else 0) 1)
      | row <- [1 .. dimension], column <- [1 .. dimension]
      ]

indexedLocalSteps :: Surface.Model -> [(Int, Surface.Step)]
indexedLocalSteps model =
  [(index, step) | (index, step) <- zip [1 ..] (Surface.mSteps model),
                   Surface.sk step == Surface.KLocal]

buildProfile
  :: OriginAssignments -> Surface.Model
  -> Either RegistryError FEIR.DiscretizationProfile
buildProfile assignments model = do
  rules <- mapM buildRule (zip [1 ..] (Surface.mDiscretizationDecls model))
  let profile = FEIR.DiscretizationProfile
        (FEIR.VersionedProfileId "formurae-discretization@1")
        (FEIR.Fingerprint "pending")
        (sortOn profileRuleKey rules)
        FEIR.FixedAxisOrder
  Right (setProfileFingerprint profile)
  where
    buildRule (index, declaration) = do
      origin <- originFor assignments (ProfileOrigin index)
      Right (FEIR.DerivativeRule
        (mapLattice (Surface.discretizationLatticeClass declaration))
        (FEIR.Positive <$> Surface.discretizationDerivativeOrder declaration)
        (mapFamily (Surface.discretizationStencilFamily declaration))
        (FEIR.PositiveEven (Surface.discretizationFormalAccuracy declaration))
        origin)

profileRuleKey :: FEIR.DerivativeRule -> (FEIR.LatticeClass, Maybe FEIR.Positive)
profileRuleKey rule =
  (FEIR.derivativeRuleLatticeClass rule, FEIR.derivativeRuleOrder rule)

mapLattice :: Surface.SurfaceLatticeClass -> FEIR.LatticeClass
mapLattice Surface.SurfaceCollocated = FEIR.CollocatedLattice
mapLattice Surface.SurfaceStaggered = FEIR.StaggeredLattice

mapFamily :: Surface.SurfaceStencilFamily -> FEIR.StencilFamily
mapFamily Surface.SurfaceCentered = FEIR.CenteredTaylor
mapFamily Surface.SurfaceYee = FEIR.Yee

buildRawHelpers
  :: OriginAssignments -> Surface.Model -> Either RegistryError [FEIR.RawHelper]
buildRawHelpers assignments model =
  mapM build (zip [1 ..] rawHelpers)
  where
    rawHelpers =
      [(helperIndex, helper)
      | (helperIndex, (kind, helper)) <- zip [1 ..]
          (zip (Surface.mHelpKinds model) (Surface.mHelp model))
      , kind == Surface.RawHelper]
    build (rawIdentifier, (helperIndex, helper)) = do
      origin <- originFor assignments (HelperOrigin helperIndex)
      Right (FEIR.RawHelper (FEIR.RawHelperId rawIdentifier) helper origin)
