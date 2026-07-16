{-# LANGUAGE PatternSynonyms #-}

-- | Emit the model-specific Egison normalization unit.  This module only
-- describes logical fields and continuum expressions.  It deliberately has
-- no stencil, placement, storage-name, or FMR printer vocabulary.
module Formurae.Pre.EmitEgison
  ( EmitError(..)
  , emitNormalizationUnit
  ) where

import Control.Monad (foldM)
import Data.Char (isAlpha, isAlphaNum, isDigit, isSpace)
import Data.List (dropWhileEnd, find, intercalate, nub, sort)
import Text.Read (readMaybe)

import Formurae.Common (analyticDerivativeName, mapEgisonCodeIdentifiers)
import Formurae.FEIR.Codec (encodeFEProgram)
import Formurae.FEIR.RegistryFingerprint (computeRegistryId)
import Formurae.FEIR.SExpr (SExpr(..))
import qualified Formurae.FEIR.Syntax as FEIR
import Formurae.Index
  ( componentIndices
  , fieldIndexParts
  , internalCoordNames
  , ixVariance
  , parseIndexedIdent
  )
import Formurae.Pre.FormOperator
import Formurae.Pre.Registry
import qualified Formurae.Syntax as Surface
import Formurae.TensorExpr

data EmitError
  = EmitRegistryError RegistryError
  | EmitAtSource Surface.SourceText EmitError
  | EmitMissingField String
  | EmitMissingInitializerOrigin Int
  | EmitMissingStepOrigin Int
  | EmitExpressionError String
  | EmitUnsupportedInitializer String
  deriving (Eq, Show)

data DynamicEncoding
  = EncodeScalar
  | EncodeTensor FEIR.TensorType FEIR.Layout
  deriving (Eq, Ord, Show)

data DynamicValue = DynamicValue
  { dynamicId       :: Int
  , dynamicName     :: String
  , dynamicSource   :: String
  , dynamicEncoding :: DynamicEncoding
  , dynamicResultIndices :: [Surface.IxPart]
  , dynamicBinding  :: Maybe String
  , dynamicAtGeometryBoundary :: Bool
  , dynamicOrigin   :: Maybe FEIR.OriginId
  , dynamicSourceText :: Maybe Surface.SourceText
  } deriving (Eq, Show)

data PreparedDefinition = PreparedDefinition
  { preparedDefinitionId :: Int
  , preparedDefinitionSurface :: Surface.Def
  , preparedDefinitionBody :: String
  , preparedDefinitionIsRawEgison :: Bool
  } deriving (Eq, Show)

data BuildState = BuildState
  { buildNextDynamic  :: Int
  , buildNextEquation :: Int
  , buildNextNode     :: Int
  , buildDynamics     :: [DynamicValue]
  }

initialBuildState :: BuildState
initialBuildState = BuildState 1 1 1 []

-- | Generate one self-contained normalization unit.  The shared libraries
-- named in the header must be loaded by the pipeline; their definitions are
-- referenced, never copied into the generated model.
emitNormalizationUnit
  :: FEIR.PrimitiveManifestId
  -> Surface.Model
  -> IO (Either EmitError String)
emitNormalizationUnit manifestId model =
  case buildRegistry model of
    Left err -> pure (Left (EmitRegistryError err))
    Right registry -> do
      prepared <- prepareProgram manifestId model registry
      case prepared of
        Left err -> pure (Left err)
        Right (programWithoutRegistryId, dynamics0) -> do
          definitionsResult <- prepareDefinitions model
          dynamicsResult <- mapM (prepareDynamic model) dynamics0
          geometryDeclarationsResult <- prepareGeometryDeclarations model
          pure $ do
            definitions <- definitionsResult
            dynamics <- sequence dynamicsResult
            geometryDeclarations <- geometryDeclarationsResult
            let registryId = computeRegistryId programWithoutRegistryId
                program = programWithoutRegistryId
                  { FEIR.feProgramRegistryId = registryId }
            Right (renderUnit model registry geometryDeclarations
              definitions dynamics program)

prepareProgram
  :: FEIR.PrimitiveManifestId
  -> Surface.Model
  -> PreRegistry
  -> IO (Either EmitError (FEIR.FEProgram, [DynamicValue]))
prepareProgram manifestId model registry = pure $ do
  (geometry, stateAfterGeometry) <-
    prepareGeometry model registry initialBuildState
  (initializers, stateAfterInitializers) <-
    prepareInitializers model registry stateAfterGeometry
  (actions, finalState) <- prepareActions model registry stateAfterInitializers
  let provenance = FEIR.ProvenanceTable
        [ (FEIR.NodeId node, [origin])
        | (FEIR.BindValue (FEIR.NodeId node) _ origin) <- actions
        ]
      program = FEIR.FEProgram
        { FEIR.feProgramVersion = 1
        , FEIR.feProgramModel = preRegistryModelIdentity registry
        , FEIR.feProgramRegistryId = FEIR.RegistryId "pending"
        , FEIR.feProgramPrimitiveManifestId = manifestId
        , FEIR.feProgramDiscretization = preRegistryDiscretization registry
        , FEIR.feProgramMode = mapMode (Surface.selectedMode model)
        , FEIR.feProgramDimension = Surface.mDim model
        , FEIR.feProgramAxes = preRegistryAxes registry
        , FEIR.feProgramGeometry = geometry
        , FEIR.feProgramParameters = preRegistryParameters registry
        , FEIR.feProgramFunctions = preRegistryFunctions registry
        , FEIR.feProgramFields = preRegistryFields registry
        , FEIR.feProgramInitializers = initializers
        , FEIR.feProgramStepActions = actions
        , FEIR.feProgramRawHelpers = preRegistryRawHelpers registry
        , FEIR.feProgramOrigins = preRegistryOrigins registry
        , FEIR.feProgramProvenance = provenance
        }
  Right (program, reverse (buildDynamics finalState))

prepareGeometry
  :: Surface.Model
  -> PreRegistry
  -> BuildState
  -> Either EmitError (FEIR.GeometryDecl, BuildState)
prepareGeometry model registry state0 =
  case FEIR.geometryDeclKind declaration of
    FEIR.EuclideanGeometry -> Right (declaration, state0)
    FEIR.OrthogonalScaleGeometry _ _ -> do
      let (metricDynamic, state1) = geometryDynamic
            "feGeometryMetric"
            (EncodeTensor covariantMetricType FEIR.FullLayout) state0
          (inverseDynamic, state2) = geometryDynamic
            "feGeometryInverseMetric"
            (EncodeTensor contravariantMetricType FEIR.FullLayout) state1
          (scaleDynamics, state3) = addScaleDynamics axisIds state2
          (volumeDynamic, state4) = geometryDynamic
            "feGeometryVolume" EncodeScalar state3
          normalForm = geometryNormalForm metricDynamic inverseDynamic
            scaleDynamics volumeDynamic
      Right (declaration
        { FEIR.geometryDeclKind = FEIR.OrthogonalScaleGeometry
            [ (axisId, scalarMarker (dynamicId dynamic))
            | (axisId, dynamic) <- zip axisIds scaleDynamics
            ] normalForm
        }, state4)
    FEIR.EmbeddedOrthogonalGeometry placeholderEmbedding _ -> do
      let (metricDynamic, state1) = geometryDynamic
            "feGeometryMetric"
            (EncodeTensor covariantMetricType FEIR.FullLayout) state0
          (inverseDynamic, state2) = geometryDynamic
            "feGeometryInverseMetric"
            (EncodeTensor contravariantMetricType FEIR.FullLayout) state1
          (scaleDynamics, state3) = addScaleDynamics axisIds state2
          (volumeDynamic, state4) = geometryDynamic
            "feGeometryVolume" EncodeScalar state3
          (embeddingDynamics, state5) = addEmbeddingDynamics
            (length placeholderEmbedding) state4
          normalForm = geometryNormalForm metricDynamic inverseDynamic
            scaleDynamics volumeDynamic
      Right (declaration
        { FEIR.geometryDeclKind = FEIR.EmbeddedOrthogonalGeometry
            (map (scalarMarker . dynamicId) embeddingDynamics) normalForm
        }, state5)
  where
    declaration = preRegistryGeometry registry
    dimension = Surface.mDim model
    axisIds = map FEIR.AxisId [1 .. dimension]
    covariantMetricType = FEIR.TensorType [dimension, dimension]
      [FEIR.VarianceDown, FEIR.VarianceDown] 0
    contravariantMetricType = FEIR.TensorType [dimension, dimension]
      [FEIR.VarianceUp, FEIR.VarianceUp] 0

    geometryDynamic source encoding state =
      addDynamic source encoding [] Nothing True
        (FEIR.geometryDeclOrigin declaration) Nothing state

    addScaleDynamics axes state = addMany
      ["feGeometryScale " ++ show axis | FEIR.AxisId axis <- axes] state
    addEmbeddingDynamics count state = addMany
      ["nth " ++ show index ++ " feGeometryEmbedding"
      | index <- [1 .. count]] state
    addMany sources state = foldl addOne ([], state) sources
      where
        addOne (values, current) source =
          let (value, next) = geometryDynamic source EncodeScalar current
          in (values ++ [value], next)

    geometryNormalForm metric inverse scales volume = FEIR.GeometryNF
      (tensorMarker covariantMetricType (dynamicId metric))
      (tensorMarker contravariantMetricType (dynamicId inverse))
      [ (axisId, scalarMarker (dynamicId scale))
      | (axisId, scale) <- zip axisIds scales
      ]
      (scalarMarker (dynamicId volume)) True

prepareInitializers
  :: Surface.Model
  -> PreRegistry
  -> BuildState
  -> Either EmitError ([FEIR.FEInitializer], BuildState)
prepareInitializers model registry state0 =
  foldM prepare ([], state0) indexedInitializers
  where
    indexedInitializers = zip3 (Surface.mInits model)
      (preRegistryInitializerOrigins registry)
      (Surface.mInitSourceTexts model)

    prepare (result, state) (initializer, origin, sourceText) = do
      (items, nextState) <- prepareInitializer initializer origin sourceText state
      Right (result ++ items, nextState)

    prepareInitializer (Surface.ICas name source) origin sourceText state = do
      field <- fieldNamed registry name
      let tensorType = FEIR.logicalFieldTensorType field
          layout = FEIR.logicalFieldLayout field
          (dynamic, nextState) = addDynamic source
            (EncodeTensor tensorType layout)
            [] Nothing False (Just origin) (Just sourceText) state
          equation = FEIR.FEEquation
            (FEIR.EquationId (buildNextEquation state))
            (FEIR.WholeFieldTarget (FEIR.logicalFieldId field) FEIR.CurrentTime)
            (tensorMarker tensorType (dynamicId dynamic)) origin
      Right ([FEIR.AnalyticInitializer equation], nextState
        { buildNextEquation = buildNextEquation state + 1 })
    prepareInitializer (Surface.ICasIndex name indices source) origin sourceText state = do
      field <- fieldNamed registry name
      let tensorType = FEIR.logicalFieldTensorType field
          layout = FEIR.logicalFieldLayout field
          (dynamic, nextState) = addDynamic source
            (EncodeTensor tensorType layout)
            indices Nothing False (Just origin) (Just sourceText) state
          equation = FEIR.FEEquation
            (FEIR.EquationId (buildNextEquation state))
            (FEIR.WholeFieldTarget (FEIR.logicalFieldId field) FEIR.CurrentTime)
            (tensorMarker tensorType (dynamicId dynamic)) origin
      Right ([FEIR.AnalyticInitializer equation], nextState
        { buildNextEquation = buildNextEquation state + 1 })
    prepareInitializer (Surface.IRaw name raw) origin _ state = do
      field <- fieldNamed registry name
      Right
        ([FEIR.RawInitializer
            (FEIR.FieldComponentTarget (FEIR.logicalFieldId field)
              FEIR.CurrentTime (FEIR.Basis [])) raw origin], state)
    prepareInitializer (Surface.IVec name values) origin _ state =
      rawComponents name values origin state
    prepareInitializer (Surface.ISym name values) origin _ state =
      rawComponents name values origin state
    prepareInitializer (Surface.IAnti name values) origin _ state =
      rawComponents name values origin state
    prepareInitializer (Surface.ITensor2 name values) origin _ state =
      rawComponents name values origin state

    rawComponents name values origin state = do
      field <- fieldNamed registry name
      kind <- maybe (Left (EmitUnsupportedInitializer name)) Right
        (Surface.kindOf model name)
      let bases = componentIndices (Surface.mDim model) kind
      if length bases /= length values
        then Left (EmitUnsupportedInitializer name)
        else Right
          ( [ FEIR.RawInitializer
                (FEIR.FieldComponentTarget (FEIR.logicalFieldId field)
                  FEIR.CurrentTime (FEIR.Basis basis)) value origin
            | (basis, value) <- zip bases values
            ]
          , state
          )

prepareActions
  :: Surface.Model
  -> PreRegistry
  -> BuildState
  -> Either EmitError ([FEIR.FEAction], BuildState)
prepareActions model registry state0 =
  foldM prepare ([], state0) indexedSteps
  where
    indexedSteps = zip (Surface.mSteps model)
      (preRegistryStepOrigins registry)

    prepare (result, state) (step, origin) = do
      (action, nextState) <- prepareStep step origin state
      Right (result ++ [action], nextState)

    prepareStep step origin state =
      case Surface.sk step of
        Surface.KLet ->
          let encoding = case Surface.sIdx step of
                [] -> EncodeScalar
                indices -> EncodeTensor
                  (indexedTensorType model indices) FEIR.FullLayout
              (dynamic, nextState) = addDynamic
                (Surface.sEx step) encoding (Surface.sIdx step)
                (Just (Surface.sNm step)) False
                (Just origin) (Just (Surface.sSourceText step)) state
              node = FEIR.NodeId (buildNextNode state)
              value = markerValue encoding (dynamicId dynamic)
          in Right (FEIR.BindValue node value origin, nextState
               { buildNextNode = buildNextNode state + 1 })
        Surface.KLocal -> do
          field <- fieldNamed registry (Surface.sNm step)
          let tensorType = FEIR.logicalFieldTensorType field
              encoding = case FEIR.logicalFieldLayout field of
                FEIR.ScalarLayout -> EncodeScalar
                layout -> EncodeTensor tensorType layout
              (dynamic, nextState) = addDynamic
                (Surface.sEx step) encoding (Surface.sIdx step) Nothing False
                (Just origin) (Just (Surface.sSourceText step)) state
          Right
            ( FEIR.Materialize (FEIR.logicalFieldId field)
                (markerValue encoding (dynamicId dynamic)) origin
            , nextState
            )
        Surface.KEq -> do
          field <- fieldNamed registry (Surface.sNm step)
          let tensorType = FEIR.logicalFieldTensorType field
              layout = FEIR.logicalFieldLayout field
              (dynamic, nextState) = addDynamic
                (Surface.sEx step) (EncodeTensor tensorType layout)
                (Surface.sIdx step) Nothing False
                (Just origin) (Just (Surface.sSourceText step)) state
              equation = FEIR.FEEquation
                (FEIR.EquationId (buildNextEquation state))
                (FEIR.WholeFieldTarget (FEIR.logicalFieldId field) FEIR.NextTime)
                (tensorMarker tensorType (dynamicId dynamic)) origin
          Right (FEIR.UpdateField equation, nextState
            { buildNextEquation = buildNextEquation state + 1 })

addDynamic
  :: String -> DynamicEncoding -> [Surface.IxPart] -> Maybe String -> Bool
  -> Maybe FEIR.OriginId -> Maybe Surface.SourceText
  -> BuildState
  -> (DynamicValue, BuildState)
addDynamic source encoding resultIndices binding geometryBoundary origin sourceText state = (dynamic, state
  { buildNextDynamic = identifier + 1
  , buildDynamics = dynamic : buildDynamics state
  })
  where
    identifier = buildNextDynamic state
    dynamic = DynamicValue identifier
      ("FormuraeInternalValue" ++ show identifier) source encoding resultIndices binding
      geometryBoundary origin sourceText

markerValue :: DynamicEncoding -> Int -> FEIR.FEValue
markerValue EncodeScalar identifier =
  FEIR.ScalarValue (scalarMarker identifier)
markerValue (EncodeTensor tensorType _layout) identifier =
  FEIR.TensorValue (tensorMarker tensorType identifier)

scalarMarker :: Int -> FEIR.ScalarNF
scalarMarker identifier = FEIR.Ref (FEIR.NodeId (negate identifier))

tensorMarker :: FEIR.TensorType -> Int -> FEIR.TensorNF
tensorMarker tensorType identifier = FEIR.TensorNF
  (FEIR.tensorTypeShape tensorType)
  (FEIR.tensorTypeVariances tensorType)
  (FEIR.tensorTypeDfOrder tensorType)
  [ (FEIR.Basis basis, scalarMarker identifier)
  | basis <- fullBases (FEIR.tensorTypeShape tensorType)
  ]

fullBases :: [Int] -> [[Int]]
fullBases [] = [[]]
fullBases (size : rest) =
  [index : suffix | index <- [1 .. size], suffix <- fullBases rest]

indexedTensorType :: Surface.Model -> [Surface.IxPart] -> FEIR.TensorType
indexedTensorType model indices = FEIR.TensorType
  (replicate (length indices) (Surface.mDim model))
  (map (mapVariance . ixVariance) indices)
  0

fieldNamed :: PreRegistry -> String -> Either EmitError FEIR.LogicalFieldDecl
fieldNamed registry name =
  maybe (Left (EmitMissingField name)) Right $ find
    ((== name) . FEIR.logicalFieldSourceName) (preRegistryFields registry)

mapMode :: Surface.Mode -> FEIR.Mode
mapMode Surface.CollocatedMode = FEIR.CollocatedMode
mapMode Surface.DecMode = FEIR.DecMode

mapVariance :: Surface.Variance -> FEIR.Variance
mapVariance Surface.VUp = FEIR.VarianceUp
mapVariance Surface.VDown = FEIR.VarianceDown

prepareGeometryDeclarations
  :: Surface.Model -> IO (Either EmitError [String])
prepareGeometryDeclarations model =
  case (Surface.mMetric model, Surface.mEmbed model) of
    (Nothing, Nothing) -> pure (Right euclideanGeometryLines)
    (Just scaleFactors, Nothing) -> do
      prepared <- mapM prepare scaleFactors
      pure $ geometryLines GeometryFromScale <$> sequence prepared
    (Nothing, Just embedding) -> do
      prepared <- mapM prepare embedding
      pure $ geometryLines GeometryFromEmbedding <$> sequence prepared
    (Just _, Just _) -> pure (Left
      (EmitExpressionError "metric scale and embedding are mutually exclusive"))
  where
    -- Lower numbers before renaming coordinates.  Otherwise a legal axis
    -- named @e3@ would make the exponent in @1e3@ look like that axis.
    prepare source = pure $
      renameGeometryCoordinates model <$> lowerDecimalLiterals source
    dimension = Surface.mDim model
    axes = [1 .. dimension]
    offDiagonalPairs =
      [(row, column) | row <- axes, column <- axes, row < column]
    orthogonalityCondition = case offDiagonalPairs of
      [] -> "True"
      pairs -> intercalate " && "
        ["FE.tensorComponentAt feGeometryMetricRaw " ++ show [row, column]
          ++ " = 0"
        | (row, column) <- pairs]

    geometryLines source values =
      sourceDefinitions source values
      ++ [ "def feGeometryOrthogonalityVerified : Bool := assert \"embedding/metric must be symbolically orthogonal\" ("
             ++ orthogonalityCondition ++ ")"
         , "def feGeometryInverseMetricRaw := "
             ++ attachTensorVariances [Surface.VUp, Surface.VUp]
                  "FE.inverseDiagonalMetricTensor feDimension feGeometryScaleRaw"
         , "def feGeometryMetric := match feGeometryOrthogonalityVerified as bool with"
         , "  | #True -> feGeometryMetricRaw"
         , "def feGeometryScale axis := match feGeometryOrthogonalityVerified as bool with"
         , "  | #True -> feGeometryScaleRaw axis"
         , "def feGeometryInverseMetric := match feGeometryOrthogonalityVerified as bool with"
         , "  | #True -> feGeometryInverseMetricRaw"
         , "def feGeometryVolume := match feGeometryOrthogonalityVerified as bool with"
         , "  | #True -> FE.orthogonalVolume " ++ show axes
             ++ " feGeometryScaleRaw"
         , ""
         ]

    euclideanGeometryLines =
      [ "def feGeometryScale axis := 1"
      , "def feGeometryMetric := "
          ++ attachTensorVariances [Surface.VDown, Surface.VDown]
               "FE.diagonalMetricTensor feDimension (\\axis -> 1)"
      , "def feGeometryInverseMetric := "
          ++ attachTensorVariances [Surface.VUp, Surface.VUp]
               "FE.inverseDiagonalMetricTensor feDimension (\\axis -> 1)"
      , "def feGeometryVolume := 1"
      , ""
      ]

    sourceDefinitions GeometryFromScale values =
      [ "def feGeometryScaleRaw axis := nth axis " ++ renderList values
      , "def feGeometryMetricRaw := "
          ++ attachTensorVariances [Surface.VDown, Surface.VDown]
               "FE.diagonalMetricTensor feDimension feGeometryScaleRaw"
      ]
    sourceDefinitions GeometryFromEmbedding values =
      [ "def feGeometryEmbedding := " ++ renderList values
      , "def feGeometryMetricRaw := "
          ++ attachTensorVariances [Surface.VDown, Surface.VDown]
               "FE.metricTensor feDimension (FE.inducedMetric feCoordinates feGeometryEmbedding)"
      , "def feGeometryScaleRaw axis := sqrt (FE.tensorComponentAt feGeometryMetricRaw [axis, axis])"
      ]

data GeometryDefinitionSource
  = GeometryFromScale
  | GeometryFromEmbedding

renameGeometryCoordinates :: Surface.Model -> String -> String
renameGeometryCoordinates model =
  Surface.untok . map rename . Surface.tokenize
  where
    coordinateNames = zip (Surface.mAxes model) (internalCoordNames model)
    rename (Surface.TId name primed) =
      Surface.TId (maybe name id (lookup name coordinateNames)) primed
    rename token = token

prepareDefinitions
  :: Surface.Model
  -> IO (Either EmitError [PreparedDefinition])
prepareDefinitions model = go [] [] (zip [1 ..] (Surface.mDefs model))
  where
    go _ prepared [] = pure (Right (reverse prepared))
    go prior prepared ((index, definition) : rest) = do
      let source = Surface.defBody definition
          parsedSource = parseTensorExprEither source
          rawEgison = case parsedSource of
            Left _ -> True
            Right _ -> False
      result <- case parsedSource of
        Left _ -> pure (Right (renameRawCoordinates model source))
        Right _ -> prepareExpression model prior
          (Surface.defName definition : map fst prior)
          (map definitionParameterBase (Surface.defParams definition))
          source
      case result of
        Left err -> pure (Left (maybe err (`EmitAtSource` err)
          (Surface.defSourceText definition)))
        Right body ->
          go ((Surface.defName definition,
                "FormuraeInternalDefinition" ++ show index) : prior)
             (PreparedDefinition index definition body rawEgison : prepared)
             rest

renameRawCoordinates :: Surface.Model -> String -> String
renameRawCoordinates model = mapEgisonCodeIdentifiers renameCoordinate
  where
    coordinateNames = zip (Surface.mAxes model) (internalCoordNames model)
    renameCoordinate name = maybe name id (lookup name coordinateNames)

-- A decimal or exponent literal in a surface expression denotes the exact
-- rational it spells: FEIR carries exact rationals, and Egison would read
-- the literal as Float, which symbolic normalization rejects.  Rewrite such
-- literals into integer fractions before they enter the generated unit.
-- Raw Egison definition bodies and raw @=@ initializers are left alone;
-- there a literal keeps Egison's own Float meaning.
lowerDecimalLiterals :: String -> Either EmitError String
lowerDecimalLiterals = outsideString False
  where
    -- The Bool records whether the preceding non-space token ended an atom.
    -- It lets a leading-dot decimal be recognized without mistaking the
    -- second dot in a range such as @1..n@ for the start of @.n@.
    outsideString _ [] = Right []
    outsideString _ ('"' : rest) = ('"' :) <$> insideString rest
    outsideString previousAtom source@('.' : next : _)
      | not previousAtom, isDigit next = do
          (literal, remaining) <- numericLiteral source
          rendered <- exactLiteralText literal
          (rendered ++) <$> outsideString True remaining
    outsideString _ (first : rest)
      | isAlpha first || first == '_' =
          let (suffix, remaining) = span isIdentifierCharacter rest
          in ((first : suffix) ++) <$> outsideString True remaining
      | isDigit first =
          do
            (literal, remaining) <- numericLiteral (first : rest)
            rendered <- exactLiteralText literal
            (rendered ++) <$> outsideString True remaining
      | isSpace first = (first :) <$> outsideString False rest
      | first `elem` ")]" = (first :) <$> outsideString True rest
      | first == '.' = (first :) <$> outsideString True rest
      | otherwise = (first :) <$> outsideString False rest
    insideString [] = Right []
    insideString ('\\' : escaped : rest) =
      ('\\' :) . (escaped :) <$> insideString rest
    insideString ('"' : rest) = ('"' :) <$> outsideString True rest
    insideString (char : rest) = (char :) <$> insideString rest
    isIdentifierCharacter char = isAlphaNum char || char == '_'

    -- (digits ['.' digits] | '.' digits)
    -- [('e'|'E') ['+'|'-'] digits].  The dot and exponent marker are
    -- consumed only when digits follow, so ranges and identifiers after a
    -- number remain separate tokens.
    numericLiteral source =
      Right ((integerDigits, fractionDigits, exponentValue), afterExponent)
      where
        (integerDigits, afterInteger) = case source of
          '.' : _ -> ("0", source)
          _ -> span isDigit source
        (fractionDigits, afterFraction) = case afterInteger of
          '.' : next : _ | isDigit next ->
            span isDigit (drop 1 afterInteger)
          _ -> ("", afterInteger)
        (exponentValue, afterExponent) = case afterFraction of
          marker : rest | marker `elem` "eE" ->
            case rest of
              sign : next : _ | sign `elem` "+-", isDigit next ->
                let (digits, remaining) = span isDigit (drop 1 rest)
                in (Just (parseExponent sign digits), remaining)
              next : _ | isDigit next ->
                let (digits, remaining) = span isDigit rest
                in (Just (parseExponent '+' digits), remaining)
              _ -> (Nothing, afterFraction)
          _ -> (Nothing, afterFraction)
        parseExponent sign digits = applySign sign magnitude
          where
            significantDigits = dropWhile (== '0') digits
            magnitude
              | null significantDigits = 0
              | length significantDigits > 3 = maxDecimalExponent + 1
              | otherwise = read significantDigits
        applySign sign magnitude
          | sign == '-' = negate magnitude
          | otherwise = magnitude

    exactLiteralText literal@(integerDigits, fractionDigits, exponentValue)
      | null fractionDigits, Nothing <- exponentValue = Right integerDigits
      | digitCount > maxDecimalDigits = decimalError literal
          ("has more than " ++ show maxDecimalDigits ++ " digits")
      | mantissa == 0 = Right "0"
      | abs decimalExponent > maxDecimalExponent = decimalError literal
          ("has exponent outside the supported range +/-"
           ++ show maxDecimalExponent)
      | abs shift > maxDecimalScale = decimalError literal
          ("needs a power of ten outside the supported range +/-"
           ++ show maxDecimalScale)
      | shift >= 0 =
          let value = mantissa * powerTen shift
          in if isInfinite (fromInteger value :: Double)
               then decimalError literal "is outside the finite backend range"
               else Right (show value)
      | safeRational = Right ("(" ++ show mantissa ++ " / "
          ++ show denominator ++ ")")
      | otherwise = decimalError literal
          "cannot be lowered without inexact numerator/denominator rounding in the double backend"
      where
        significant = dropWhileEnd (== '0') fractionDigits
        mantissa = read (integerDigits ++ significant) :: Integer
        decimalExponent = maybe 0 id exponentValue
        shift = decimalExponent - toInteger (length significant)
        digitCount = length integerDigits + length fractionDigits
        denominator = powerTen (negate shift)
        divisor = gcd (abs mantissa) denominator
        reducedNumerator = abs mantissa `div` divisor
        reducedDenominator = denominator `div` divisor
        safeRational = exactDoubleInteger reducedNumerator
          && exactDoubleInteger reducedDenominator

    decimalError (integerDigits, fractionDigits, exponentValue) reason =
      Left (EmitExpressionError
        ("decimal literal " ++ renderLiteral integerDigits fractionDigits exponentValue
         ++ " " ++ reason))

    renderLiteral integerDigits fractionDigits exponentValue =
      integerDigits
      ++ (if null fractionDigits then "" else "." ++ fractionDigits)
      ++ maybe "" (('e' :) . show) exponentValue

    -- A division in generated C is correctly rounded when both reduced
    -- integer operands arrive exactly as binary64 values.  Test that
    -- property directly: powers of ten such as 10^20 can be exact even
    -- though they are larger than 2^53.
    exactDoubleInteger value =
      let converted = fromInteger value :: Double
      in not (isInfinite converted)
         && (truncate converted :: Integer) == value
    maxDecimalDigits = 309 :: Int
    maxDecimalExponent = 308 :: Integer
    maxDecimalScale = 308 :: Integer
    powerTen :: Integer -> Integer
    powerTen value = 10 ^ (fromInteger value :: Int)

prepareDynamic
  :: Surface.Model -> DynamicValue -> IO (Either EmitError DynamicValue)
prepareDynamic model dynamic = do
  result <- prepareExpression model [] (map Surface.defName (Surface.mDefs model)) []
    (dynamicSource dynamic)
  pure $ case result of
    Left err -> Left (maybe err (`EmitAtSource` err)
      (dynamicSourceText dynamic))
    Right source -> Right (dynamic { dynamicSource = source })

prepareExpression
  :: Surface.Model
  -> [(String, String)]
  -> [String]
  -> [String]
  -> String
  -> IO (Either EmitError String)
prepareExpression model userDefinitions shadowedNames boundNames source = do
  preprocessed <- preprocessTensorExpr model source
  pure $ case parseTensorExprEither preprocessed of
    Left message -> Left (EmitExpressionError message)
    Right expression -> contextualize model userDefinitions shadowedNames
      boundNames expression >>= lowerDecimalLiterals . renderTensorExpr

contextualize
  :: Surface.Model
  -> [(String, String)]
  -> [String]
  -> [String]
  -> TensorExpr
  -> Either EmitError TensorExpr
contextualize model userDefinitions shadowedNames boundNames expression
  | hasVariableGeometry model
  , Just _ <- matchHodgeExteriorHodge operatorScope expression =
      Left (EmitExpressionError
        "hodge (d (hodge A)) cannot be analytically expanded on variable metric geometry; write canonical δ A so the compiler preserves the weighted discrete adjoint")
  | Surface.selectedMode model == Surface.CollocatedMode
  , Just operand <- matchScalarDeltaExpression operatorScope expression = do
      operand' <- walk operand
      Right (TEApply (TEIdent "FormuraeInternalScalarDelta" [])
        [applicationArgument operand'])
  | otherwise = case expression of
    TENumber value -> Right (TENumber value)
    TEIdent name parts
      | null parts
      , name == "True" -> Right (TEIdent "Formurae.predicateTrue" [])
      | null parts
      , name == "False" -> Right (TEIdent "Formurae.predicateFalse" [])
      | null parts
      , Just operator <- canonicalOperator name
      , canonicalOperatorIsVisible operatorScope operator ->
          TEIdent <$> resolveCanonicalOperator operator <*> pure []
      | null parts
      , Just qualified <- resolvedFunction name ->
          Right (TEIdent qualified [])
      | null parts
      , not (isLexicallyShadowed name)
      , Just completedParts <- indexedLetCompletion name ->
          Right (TEIdent name completedParts)
      | otherwise -> Right (TEIdent name parts)
    TEUnary "!" body ->
      TEApply (TEIdent "Formurae.predicateNot" []) . (: []) <$> walk body
    TEUnary operator body -> TEUnary operator <$> walk body
    TECall (TEIdent name parts) arguments
      | isExplicitPrimitiveName name
      , not (isLexicallyShadowed name) ->
          contextualizeExplicitPrimitive name parts arguments
    TECall function arguments ->
      TECall <$> walk function <*> mapM walk arguments
    TEApply (TEIdent name []) arguments
      | Just qualified <- resolvedFunction name ->
          contextualizeResolvedCall qualified arguments
    TEApply (TEIdent name parts) arguments
      | isExplicitPrimitiveName name
      , not (isLexicallyShadowed name) ->
          contextualizeExplicitPrimitive name parts arguments
    TEApply (TEIdent name []) arguments
      | name == analyticDerivativeName ->
          case arguments of
            -- The Egison tensor idiom: differentiating by the ambient
            -- coordinates vector (optionally indexed) yields the analytic
            -- derivative axis, anonymous unless an index is applied.
            [value, TEIdent "coordinates" parts] -> do
              value' <- walk value
              Right (TEApply (TEIdent "∂/∂" [])
                [applicationArgument value', TEIdent "coordinates" parts])
            [value, TEIdent axis []] -> do
              axisId <- gridAxisId "∂/∂" axis
              value' <- walk value
              Right (analyticDerivative 1
                (internalCoordNames model !! (axisId - 1)) value')
            _ -> Left (EmitExpressionError
              "∂/∂ needs one operand and one coordinate, or the ambient coordinates vector")
    TEApply (TEIdent derivative parts) arguments
      | Just (order, radius) <- coordinateDerivativeName derivative
      , [Surface.IxPart _ axis] <- parts -> do
          arguments' <- mapM walk arguments
          case arguments' of
            [argument]
              -- An unprimed first derivative is the lattice's natural
              -- radius-one difference (placement-directed on staggered
              -- fields); orders and primes request centered stencils.
              | order == 1 && radius == 1 -> do
                  axisId <- gridAxisId derivative axis
                  Right (TEApply
                    (TEIdent "FormuraeInternalGridWholeDerivative" [])
                    [TENumber (show axisId), applicationArgument argument])
              | otherwise -> do
                  axisId <- gridAxisId derivative axis
                  Right (TEApply
                    (TEIdent "FormuraeInternalCoordinateWideDerivative" [])
                    [ TENumber (show axisId)
                    , TENumber (show order)
                    , TENumber (show radius)
                    , argument
                    ])
            _ -> Left (EmitExpressionError
              (derivative ++ " coordinate derivative needs one operand"))
    TEApply function arguments ->
      TEApply <$> walk function <*> mapM walk arguments
    TEIf condition yes no -> do
      condition' <- walk condition
      yes' <- walk yes
      no' <- walk no
      Right (TEApply (TEIdent "Formurae.select" [])
        [ applicationArgument condition'
        , applicationArgument yes'
        , applicationArgument no'
        ])
    TEAppendIndexed body parts -> TEAppendIndexed <$> walk body <*> pure parts
    TEWithSymbols names body -> TEWithSymbols names <$> walk body
    TEContractWith reducer body -> TEContractWith reducer <$> walk body
    TETensorMap function body -> TETensorMap <$> walk function <*> walk body
    TESubrefs body parts -> TESubrefs <$> walk body <*> pure parts
    TETranspose names body -> TETranspose names <$> walk body
    TEDisjoint parts -> TEDisjoint <$> mapM walk parts
    TEDerivative parts body -> do
      body' <- walk body
      Right (foldr indexedDerivativePart body' parts)
    TEGridDerivativeChain parts body -> do
      body' <- walk body
      axisIds <- mapM quotedAxisId parts
      case axisIds of
        [] -> Left (EmitExpressionError
          "quoted derivative chain needs one or more coordinate indices")
        [_] -> Left (EmitExpressionError
          "a single quoted derivative is redundant; write the coordinate derivative unquoted and reserve backquotes for ordered chains")
        _ -> Right (TEApply
          (TEIdent "FormuraeInternalOrderedDerivative" [])
          [integerVector axisIds, applicationArgument body'])
    TETensorLiteral elements parts ->
      TETensorLiteral <$> mapM walk elements <*> pure parts
    TEDot parts -> do
      parts' <- mapM walk parts
      case lookup "." userDefinitions of
        Just internalName -> Right (applyUserDot internalName parts')
        Nothing -> Right (TEDot parts')
    TEBinary operator lhs rhs
      | Just constructor <- predicateBinaryConstructor operator -> do
          lhs' <- walk lhs
          rhs' <- walk rhs
          Right (TEApply (TEIdent constructor [])
            [applicationArgument lhs', applicationArgument rhs'])
      | otherwise -> TEBinary operator <$> walk lhs <*> walk rhs
    TEGroup body -> TEGroup <$> walk body
  where
    walk value = contextualize model userDefinitions
      shadowedNames boundNames value
    applyUserDot internalName (first : rest) =
      foldl apply first rest
      where
        apply lhs rhs = TEApply (TEIdent internalName [])
          [applicationArgument lhs, applicationArgument rhs]
    applyUserDot _ [] = TEDot []
    resolvedFunction name
      | name `elem` boundNames = Nothing
      | Just internalName <- lookup name userDefinitions = Just internalName
      | name `elem` shadowedNames = Nothing
      | Just _ <- canonicalOperator name = Nothing
      | otherwise = lookup name continuumOperators
    operatorScope = OperatorScope
      (boundNames ++ shadowedNames ++ map fst userDefinitions
        ++ map Surface.defName (Surface.mDefs model))
    resolveCanonicalOperator operator =
      case canonicalOperatorModeError (Surface.selectedMode model) operator of
        Just message -> Left (EmitExpressionError message)
        Nothing
          | operator == CanonicalHodgeLaplacian
          , hasVariableGeometry model -> Left (EmitExpressionError
              "canonical Δ_H is not supported for variable metric geometry; write its metric-dependent discretization explicitly")
          | otherwise -> Right (canonicalInternalName operator)
    isLexicallyShadowed name =
      name `elem` boundNames
      || name `elem` shadowedNames
      || any ((== name) . fst) userDefinitions
    indexedLetCompletion name =
      case [ map anonymousPart (Surface.sIdx step)
           | step <- Surface.mSteps model
           , Surface.sk step == Surface.KLet
           , Surface.sNm step == name
           , not (null (Surface.sIdx step))
           ] of
        [parts] -> Just parts
        _ -> Nothing
    anonymousPart (Surface.IxPart variance _) =
      Surface.IxPart variance "#"
    indexedDerivativePart part value =
      TEContractWith "+" $
        TEAppendIndexed
          (TEGroup (TEApply (TEIdent "FormuraeInternalDiff" []) [value]))
          [part]
    contextualizeResolvedCall qualified arguments = do
      arguments' <- mapM walk arguments
      Right (TEApply (TEIdent qualified []) arguments')
    gridAxisId name axis =
      case [ identifier
           | (identifier, sourceName, canonicalName) <-
               zip3 [1 :: Int ..] (Surface.mAxes model) (internalCoordNames model)
           , axis == sourceName || axis == canonicalName
           ] of
        identifier : _ -> Right identifier
        [] -> Left (EmitExpressionError
          (name ++ " uses unknown coordinate " ++ axis))
    quotedAxisId (Surface.IxPart Surface.VDown axis) =
      gridAxisId "quoted derivative" axis
    quotedAxisId (Surface.IxPart Surface.VUp axis) =
      Left (EmitExpressionError
        ("quoted derivative coordinate index must be covariant: ~" ++ axis))
    contextualizeExplicitPrimitive name parts arguments
      | name == "resample" =
          case (parts, arguments) of
            ([], value : bits) -> do
              value' <- walk value
              bitValues <- mapM (explicitPlacementBit name) bits
              if length bitValues == Surface.mDim model
                then Right (TEApply (TEIdent "FormuraeInternalResampleExplicit" [])
                  [integerVector bitValues,
                   applicationArgument value'])
                else Left (EmitExpressionError
                  (name ++ " needs exactly " ++ show (Surface.mDim model)
                    ++ " absolute placement bits after its operand"))
            _ -> Left (EmitExpressionError
              (name ++ " takes an unindexed operand call and absolute placement bits"))
      | otherwise = Left (EmitExpressionError
          ("unknown explicit primitive " ++ name))
    explicitPlacementBit :: String -> TensorExpr -> Either EmitError Int
    explicitPlacementBit name candidate =
      case ungroup candidate of
        TENumber "0" -> Right 0
        TENumber "1" -> Right 1
        _ -> Left (EmitExpressionError
          (name ++ " absolute placement bits must be literal 0 or 1"))
    ungroup (TEGroup body) = ungroup body
    ungroup value = value
    integerVector :: [Int] -> TensorExpr
    integerVector [] = TEIdent "[||]" []
    integerVector values = TEIdent
      ("[| " ++ intercalate ", " (map show values) ++ " |]") []
    applicationArgument value@(TEApply _ _) = TEGroup value
    applicationArgument value@(TECall _ _) = TEGroup value
    applicationArgument value = value

predicateBinaryConstructor :: String -> Maybe String
predicateBinaryConstructor operator = lookup operator
  [ ("==", "Formurae.predicateEq")
  , ("!=", "Formurae.predicateNe")
  , ("<", "Formurae.predicateLt")
  , ("<=", "Formurae.predicateLe")
  , (">", "Formurae.predicateGt")
  , (">=", "Formurae.predicateGe")
  , ("&&", "Formurae.predicateAnd")
  , ("||", "Formurae.predicateOr")
  ]

isExplicitPrimitiveName :: String -> Bool
isExplicitPrimitiveName name = name == "resample"

continuumOperators :: [(String, String)]
continuumOperators =
  [ ("grad", "FormuraeInternalGrad")
  , ("dGrad", "FormuraeInternalDGrad")
  , ("divg", "FormuraeInternalDivg")
  , ("curl", "FormuraeInternalCurl")
  , ("hessian", "FormuraeInternalHessian")
  , ("lap", "FormuraeInternalLap")
  , ("Δ", "FormuraeInternalScalarDelta")
  , ("d", "FormuraeInternalD")
  , ("hodge", "FormuraeInternalHodge")
  , ("δ", "FormuraeInternalCodiff")
  , ("ΔH", "FormuraeInternalHodgeLaplacian")
  ]

canonicalInternalName :: CanonicalOperator -> String
canonicalInternalName operator = case operator of
  CanonicalExteriorD -> "FormuraeInternalD"
  CanonicalHodge -> "FormuraeInternalHodge"
  CanonicalCodifferential -> "FormuraeInternalCodiff"
  CanonicalScalarLaplacian -> "FormuraeInternalScalarDelta"
  CanonicalHodgeLaplacian -> "FormuraeInternalHodgeLaplacian"

coordinateDerivativeName :: String -> Maybe (Int, Int)
coordinateDerivativeName name = do
  rest <- stripPrefix "pd" name
  let (orderText, radiusPart) = span isDigit rest
  radiusText <- stripPrefix "r" radiusPart
  order <- readMaybe orderText
  radius <- readMaybe radiusText
  if order > 0 && radius > 0 then Just (order, radius) else Nothing

stripPrefix :: String -> String -> Maybe String
stripPrefix [] value = Just value
stripPrefix (expected : rest) (actual : value)
  | expected == actual = stripPrefix rest value
stripPrefix _ _ = Nothing

analyticDerivative :: Int -> String -> TensorExpr -> TensorExpr
analyticDerivative order axis = applyRepeated order
  where
    applyRepeated 0 value = value
    applyRepeated count value = applyRepeated (count - 1)
      (TEApply (TEIdent "∂/∂" [])
        [groupAppliedValue value, TEIdent axis []])
    groupAppliedValue value@(TEApply _ _) = TEGroup value
    groupAppliedValue value = value

renderUnit
  :: Surface.Model
  -> PreRegistry
  -> [String]
  -> [PreparedDefinition]
  -> [DynamicValue]
  -> FEIR.FEProgram
  -> String
renderUnit model registry geometryDeclarations definitions dynamics program = unlines $
  header
  ++ diagnosticMetadata registry dynamics
  ++ symbolDeclarations
  ++ modelEnvironmentDeclarations
  ++ geometryDeclarations
  ++ ambientOperatorDeclarations
  ++ concatMap (fieldDeclarations model) (Surface.mFieldDecls model)
  ++ localDeclarations
  ++ registryDeclarations model registry
  ++ definitionDeclarations (Surface.mDim model) definitions
  ++ dynamicDeclarations dynamics
  ++ encoderDeclarations
  ++ continuumAssertionDeclarations model
  ++ [ "def feProgram := " ++ renderWire dynamics (encodeFEProgram program)
     , ""
     , mainDeclaration model
     ]
  where
    header =
      [ "--"
      , "-- GENERATED by pre-fec from " ++ Surface.mSourcePath model
      , "-- Load the Formurae libraries together with this unit in one"
      , "-- initial recursive binding batch; use"
      , "-- tools/run_formurae_normalization.sh."
      , "--"
      , ""
      ]
    coordinateNames = internalCoordNames model
    parameterNames = map FEIR.parameterDeclSourceName
      (preRegistryParameters registry)
    symbolDeclarations =
      ["declare symbol " ++ intercalate ", " coordinateNames]
      ++ ["declare symbol " ++ intercalate ", " parameterNames
         | not (null parameterNames)]
      ++ ["declare symbol " ++ intercalate ", " indexNames]
      ++ [""]
    modelEnvironmentDeclarations =
      [ "def feDimension : Integer := " ++ show (Surface.mDim model)
      , "def feCoordinates : Vector MathValue := [| "
          ++ intercalate ", " coordinateNames ++ " |]"
      , "def dimension : Integer := feDimension"
      , "def coordinates : Vector MathValue := feCoordinates"
      ]
      ++ [""]
    ambientOperatorDeclarations =
      [ "def feGeometryScales : Vector MathValue := [| "
          ++ intercalate ", " geometryScaleValues ++ " |]"
      , "def feGeometryId : Integer := 1"
      , "def fePrimitiveManifestId : String := "
          ++ show (primitiveManifestText (FEIR.feProgramPrimitiveManifestId program))
      , "def metric_i_j := " ++ ambientGeometryValue "feGeometryMetric_i_j"
      , "def inverseMetric~i~j := "
          ++ ambientGeometryValue "feGeometryInverseMetric~i~j"
      , "def volume := " ++ ambientGeometryValue "feGeometryVolume"
      , "def epsilon : Tensor Integer := ε dimension"
      , "def FormuraeInternalKroneckerDelta : Tensor Integer := FE.kroneckerDelta dimension"
      ]
      ++ concat
        [ [ "def " ++ metricName ++ "_i_j := metric_i_j"
          , "def " ++ metricName ++ "~i~j := inverseMetric~i~j"
          ]
        | metricName <- maybe [] (: []) (Surface.mMetricName model)
        ]
      ++ operatorDeclarations
      ++ [ ""
         ]
    operatorDeclarations = concat
      [ whenUsed "FormuraeInternalDiff"
          ["def FormuraeInternalDiff value := Formurae.gridDiff value"]
      , whenUsed "FormuraeInternalGrad"
          ["def FormuraeInternalGrad u := Formurae.grad u"]
      , whenUsed "FormuraeInternalDGrad"
          ["def FormuraeInternalDGrad X := Formurae.dGrad X"]
      , whenUsed "FormuraeInternalDivg"
          ["def FormuraeInternalDivg X := Formurae.divg X"]
      , whenUsed "FormuraeInternalCurl"
          ["def FormuraeInternalCurl X := Formurae.curl X"]
      , whenUsed "FormuraeInternalHessian"
          ["def FormuraeInternalHessian u := Formurae.hessian u"]
      , whenUsed "FormuraeInternalLap"
          ["def FormuraeInternalLap u := Formurae.lap u"]
      , whenUsed "FormuraeInternalScalarDelta" scalarDeltaDeclarations
      , whenUsed "FormuraeInternalD"
          ["def FormuraeInternalD A := Formurae.d A"]
      , whenUsed "FormuraeInternalHodge"
          ["def FormuraeInternalHodge A := Formurae.hodge A"]
      , whenUsed "FormuraeInternalCodiff" codiffDeclarations
      , whenUsed "FormuraeInternalHodgeLaplacian"
          ["def FormuraeInternalHodgeLaplacian A := Formurae.hodgeLaplacian A"]
      , whenUsed "FormuraeInternalCoordinateWideDerivative"
          ["def FormuraeInternalCoordinateWideDerivative axis order radius value := Formurae.coordinateWideDerivative axis order radius value"]
      , whenUsed "FormuraeInternalGridWholeDerivative"
          ["def FormuraeInternalGridWholeDerivative axis value := Formurae.gridWholeDerivative axis value"]
      , whenUsed "FormuraeInternalOrderedDerivative"
          ["def FormuraeInternalOrderedDerivative axes value := Formurae.gridDerivativeChain axes value"]
      , whenUsed "FormuraeInternalResampleExplicit"
          ["def FormuraeInternalResampleExplicit bits value := Formurae.resampleExplicit bits value"]
      ]
    whenUsed name declarations
      | name `elem` requiredOperatorIdentifiers = declarations
      | name == "FormuraeInternalD", Surface.mDd model /= Nothing = declarations
      | otherwise = []
    preparedIdentifiers = nub
      [ fst (parseIndexedIdent name)
      | source <- map preparedDefinitionBody definitions
                  ++ map dynamicSource dynamics
      , Surface.TId name _ <- Surface.tokenize source
      ]
    requiredOperatorIdentifiers = nub
      (preparedIdentifiers
       ++ [ internalName
          | definition <- definitions
          , preparedDefinitionIsRawEgison definition
          , surfaceName <- identifiersIn (preparedDefinitionBody definition)
          , Just internalName <- [lookup surfaceName continuumOperators]
          ])
    identifiersIn source =
      [base
      | Surface.TId name _ <- Surface.tokenize source
      , let (base, parts) = parseIndexedIdent name
      , null parts]
    scalarDeltaDeclarations
      | variableGeometry =
          ["def FormuraeInternalScalarDelta u := Formurae.lbOrthogonal u"]
      | otherwise =
          ["def FormuraeInternalScalarDelta u := Formurae.scalarLaplacian u"]
    codiffDeclarations
      | variableGeometry =
          ["def FormuraeInternalCodiff A := Formurae.metricCodiff A"]
      | otherwise =
          ["def FormuraeInternalCodiff A := Formurae.codiff A"]
    variableGeometry = case (Surface.mMetric model, Surface.mEmbed model) of
      (Nothing, Nothing) -> False
      _ -> True
    geometryScaleValues
      | variableGeometry =
          ["FEIR.unquoteAll (feGeometryScale " ++ show axis ++ ")"
          | axis <- [1 .. Surface.mDim model]]
      | otherwise = replicate (Surface.mDim model) "1"
    -- User step expressions read these ambient values directly, so the
    -- rule-suppression quotes of a quoted embedding/scale must be stripped
    -- here, as for feGeometryScales above; only the GeometryNF dynamics keep
    -- quotes until their own FEIR encode boundary.
    ambientGeometryValue value
      | variableGeometry = "FEIR.unquoteAll " ++ value
      | otherwise = value
    localDeclarations = concatMap localFieldDeclarations
      [ Surface.localDeclAsField local
      | step <- Surface.mSteps model
      , Just local <- [Surface.sLocalDecl step]
      ]
    localFieldDeclarations field =
      fieldVersionDeclarations model field "" "Current" ++ [""]
    encoderDeclarations =
      [ "def FormuraeInternalAtOrigin marker thunk :="
      , "  io $ do print marker"
      , "          return (thunk ())"
      , ""
      , "def FormuraeInternalEncodeScalar value := FEIR.encodeScalar feParameters feCoordinatesRegistry feFields feIntrinsics feAnalytics value"
      , "def FormuraeInternalEncodeTensor expectedShape variances degree value :="
      , "  let actualVariances := Formurae.logicalTensorVariances value"
      , "      actualDegree := dfOrder value"
      , "      exactMetadata := actualVariances = variances && actualDegree = degree"
      , "      completesOmittedDownIndices := degree = 0"
      , "                                      && actualDegree > 0"
      , "                                      && actualVariances = variances"
      , "   in match assert \"normalized equation tensor metadata mismatch\""
      , "                   (tensorShape value = expectedShape"
      , "                    && (exactMetadata || completesOmittedDownIndices)) as bool with"
      , "        | #True -> FEIR.encodeTensorWithMetadata feParameters feCoordinatesRegistry feFields feIntrinsics feAnalytics variances degree value"
      , ""
      ]

-- The machine runner resolves the last active origin when Egison aborts
-- before a FEIR value exists.  Human-readable provenance lives in comments,
-- so it cannot affect normalization or the FEIR fingerprint.
diagnosticMetadata :: PreRegistry -> [DynamicValue] -> [String]
diagnosticMetadata registry dynamics =
  concatMap renderOrigin activeOrigins
  ++ ["" | not (null activeOrigins)]
  where
    activeOrigins = nub
      [origin | dynamic <- dynamics, Just origin <- [dynamicOrigin dynamic]]
    FEIR.OriginTable originTable = preRegistryOrigins registry

    renderOrigin origin@(FEIR.OriginId identifier) =
      case lookup origin originTable of
        Nothing -> []
        Just sourceOrigin ->
          ["-- FORMURAE-DIAGNOSTIC-BEGIN " ++ show identifier]
          ++ map ("-- FORMURAE-DIAGNOSTIC " ++)
               (renderSourceDiagnostic sourceOrigin)
          ++ ["-- FORMURAE-DIAGNOSTIC-END " ++ show identifier]

renderSourceDiagnostic :: FEIR.SourceOrigin -> [String]
renderSourceDiagnostic sourceOrigin =
  ("pre-fec: error: " ++ renderSourceLocation location
    ++ ": Egison normalization failed")
  : map renderExpansion (FEIR.sourceOriginTrace sourceOrigin)
  where
    location = FEIR.sourceOriginLocation sourceOrigin
    renderExpansion frame =
      "  expanded from " ++ FEIR.expansionFrameName frame
      ++ " at " ++ renderSourceLocation (FEIR.expansionFrameCall frame)
      ++ " (defined at "
      ++ renderSourceLocation (FEIR.expansionFrameDefinition frame) ++ ")"

renderSourceLocation :: FEIR.SourceLocation -> String
renderSourceLocation location =
  FEIR.sourceLocationPath location
  ++ ":" ++ show (FEIR.sourceLocationLine location)
  ++ ":" ++ show (FEIR.sourceLocationStartColumn location)

primitiveManifestText :: FEIR.PrimitiveManifestId -> String
primitiveManifestText (FEIR.PrimitiveManifestId value) = value

continuumAssertionDeclarations :: Surface.Model -> [String]
continuumAssertionDeclarations model =
  case Surface.mDd model of
    Nothing -> []
    Just value ->
      [ "def feContinuumDD := foldl (\\acc component -> acc + component ^ 2) 0 (tensorToList (FormuraeInternalD (FormuraeInternalD "
          ++ value ++ ")))"
      , "def feContinuumAssertions : Bool := assert \"continuum identity d(d A) = 0 failed\" (feContinuumDD = 0)"
      , ""
      ]

mainDeclaration :: Surface.Model -> String
mainDeclaration model =
  case Surface.mDd model of
    Nothing ->
      "def main (args: [String]) : IO () := print (FEIR.render feProgram)"
    Just _ ->
      "def main (args: [String]) : IO () := match feContinuumAssertions as bool with | #True -> print (FEIR.render feProgram)"

fieldDeclarations :: Surface.Model -> Surface.FieldDecl -> [String]
fieldDeclarations model field =
  fieldVersionDeclarations model field "" "Current"
  ++ fieldVersionDeclarations model field "'" "Next"
  ++ [""]

fieldVersionDeclarations
  :: Surface.Model -> Surface.FieldDecl -> String -> String -> [String]
fieldVersionDeclarations model field primes slot =
  case Surface.fdKind field of
    Surface.Scalar -> [scalarDeclaration]
    Surface.Vector -> [fullTensorDeclaration 1]
    Surface.Tensor2 -> [fullTensorDeclaration 2]
    Surface.SymM -> canonicalRank2 True
    Surface.AntiM -> canonicalRank2 False
    Surface.Form degree
      | degree == 0 -> [scalarDeclaration]
      | otherwise ->
          [ "def " ++ rawName ++ " := " ++ generatedTensor degree
          , "def " ++ publicName ++ " := FE.canonicalFormTensor"
              ++ " (FE.tensorComponentAt " ++ rawName ++ ") feDimension "
              ++ show degree
          ]
  where
    publicName = Surface.fdName field ++ primes
    rawName = fieldRawName field slot
    coordinateArguments = intercalate ", " (internalCoordNames model)
    scalarDeclaration =
      "def " ++ publicName ++ " := function (" ++ coordinateArguments ++ ")"
    generatedTensor rank =
      "generateTensor (\\[" ++ intercalate ", " (take rank indexNames)
      ++ "] -> function (" ++ coordinateArguments ++ ")) "
      ++ show (replicate rank (Surface.mDim model))
    fullTensorDeclaration rank =
      "def " ++ publicName ++ " := "
      ++ attachFieldTensorMetadata field rank (generatedTensor rank)
    canonicalRank2 symmetric =
      [ "def " ++ rawName ++ " := " ++ generatedTensor 2
      , "def " ++ publicName ++ " := "
          ++ attachFieldTensorMetadata field 2
               ("generateTensor (\\[i, j] -> " ++ component ++ ") "
                 ++ show [Surface.mDim model, Surface.mDim model])
      ]
      where
        at a b = "FE.tensorComponentAt " ++ rawName ++ " [" ++ a ++ ", " ++ b ++ "]"
        component
          | symmetric = "if i <= j then " ++ at "i" "j" ++ " else " ++ at "j" "i"
          | otherwise = "if i = j then 0 else if i < j then "
              ++ at "i" "j" ++ " else 0 - " ++ at "j" "i"

indexNames :: [String]
indexNames = ["i", "j", "k", "l", "m", "n"]

metadataIndexNames :: [String]
metadataIndexNames =
  [ "formuraeTensorIndex1"
  , "formuraeTensorIndex2"
  , "formuraeTensorIndex3"
  ]

attachFieldTensorMetadata
  :: Surface.FieldDecl -> Int -> String -> String
attachFieldTensorMetadata field rank expression =
  attachTensorVariances variances expression
  where
    variances = case fieldIndexParts field of
      Just parts -> map (ixVariance) parts
      Nothing -> replicate rank Surface.VDown

attachTensorVariances :: [Surface.Variance] -> String -> String
attachTensorVariances variances expression =
  "(" ++ expression ++ ")" ++ concat
    [ varianceMarker variance ++ name
    | (variance, name) <- zip variances metadataIndexNames
    ]

fieldRawName :: Surface.FieldDecl -> String -> String
fieldRawName field slot =
  "FormuraeInternalField" ++ show (Surface.fdSourceLine field)
  ++ slot ++ "Raw"

registryDeclarations
  :: Surface.Model -> PreRegistry -> [String]
registryDeclarations model registry =
  [ "def feParameters := " ++ renderParameterRegistry
  , "def feCoordinatesRegistry := " ++ renderCoordinateRegistry
  , "def feFields := " ++ renderFieldRegistry
  , "def feIntrinsics := " ++ renderIntrinsicRegistry
  , "def feAnalytics := []"
  , ""
  ]
  where
    renderParameterRegistry = renderList
      ["(" ++ FEIR.parameterDeclSourceName parameter ++ ", "
        ++ show identifier ++ ")"
      | parameter <- preRegistryParameters registry
      , let FEIR.ParamId identifier = FEIR.parameterDeclId parameter]
    renderCoordinateRegistry = renderList
      ["(" ++ FEIR.axisDeclCanonicalName axis ++ ", "
        ++ show identifier ++ ")"
      | axis <- preRegistryAxes registry
      , let FEIR.AxisId identifier = FEIR.axisDeclId axis]
    renderIntrinsicRegistry = renderList
      ["(" ++ show (FEIR.functionDeclSourceName function) ++ ", "
        ++ show identifier ++ ")"
      | function <- preRegistryFunctions registry
      , FEIR.functionDeclClass function == FEIR.IntrinsicFunction
      , let FEIR.FunctionId identifier = FEIR.functionDeclId function]
    renderFieldRegistry = renderList (concatMap fieldEntries
      (preRegistryFields registry))
    fieldEntries logicalField =
      case find ((== FEIR.logicalFieldSourceName logicalField) . Surface.fdName)
             (Surface.mFieldDecls model) of
        Just surfaceField ->
          currentEntry surfaceField "current" "Current"
          ++ currentEntry surfaceField "next" "Next"
        Nothing -> case find
            ((== FEIR.logicalFieldSourceName logicalField) . Surface.fdName)
            localFields of
          Just localField -> currentEntry localField "current" "Current"
          Nothing -> []
      where
        currentEntry surfaceField timeSlot slot =
          [ entry logicalField timeSlot basis
              (fieldComponentExpression surfaceField slot timeSlot basis)
          | basis <- componentIndices (Surface.mDim model)
              (Surface.fdKind surfaceField)
          ]
    localFields =
      [Surface.localDeclAsField local
      | step <- Surface.mSteps model
      , Just local <- [Surface.sLocalDecl step]]
    entry
      :: FEIR.LogicalFieldDecl -> String -> [Int] -> String -> String
    entry logicalField timeSlot basis value =
      let FEIR.FieldId identifier = FEIR.logicalFieldId logicalField
      in "FEIR.fieldEntry " ++ show identifier ++ " " ++ show timeSlot
         ++ " " ++ show basis ++ " (" ++ value ++ ")"

fieldComponentExpression
  :: Surface.FieldDecl -> String -> String -> [Int] -> String
fieldComponentExpression field slot timeSlot basis =
  case Surface.fdKind field of
    Surface.Scalar -> publicName
    Surface.Form 0 -> publicName
    Surface.SymM -> rawComponent
    Surface.AntiM -> rawComponent
    Surface.Form _ -> rawComponent
    _ -> "FE.tensorComponentAt " ++ publicName ++ " " ++ show basis
  where
    publicName = Surface.fdName field ++ if timeSlot == "next" then "'" else ""
    rawComponent = "FE.tensorComponentAt " ++ fieldRawName field slot
      ++ " " ++ show basis

definitionDeclarations :: Int -> [PreparedDefinition] -> [String]
definitionDeclarations _ [] = []
definitionDeclarations dimension definitions =
  renderAll [] definitions
  where
    renderAll _ [] = []
    renderAll prior (prepared : rest) =
      renderDefinition prior prepared
      ++ renderAll ((definitionName, internalName) : prior) rest
      where
        definitionName = Surface.defName (preparedDefinitionSurface prepared)
        internalName = internalDefinitionName (preparedDefinitionId prepared)

    renderDefinition prior prepared =
      [ "def FormuraeInternalDefinition" ++ show index
          ++ concatMap (\parameter -> " " ++ definitionParameterBase parameter)
               (Surface.defParams definition)
          ++ " := " ++ wrapBody
               (checkedBody rawEgison definition (scopedBody prior prepared))
      , "def " ++ publicDefinitionName (Surface.defName definition)
          ++ " := FormuraeInternalDefinition" ++ show index
      , ""
      ]
      where
        index = preparedDefinitionId prepared
        definition = preparedDefinitionSurface prepared
        rawEgison = preparedDefinitionIsRawEgison prepared
        wrapBody
          | rawEgison = withIndexSymbolsMultiline
          | otherwise = withIndexSymbols

    scopedBody prior prepared
      | not (preparedDefinitionIsRawEgison prepared) = body
      | null aliases = body
      | otherwise = renderAliasBindings aliases body
      where
        definition = preparedDefinitionSurface prepared
        body = preparedDefinitionBody prepared
        formalNames = map definitionParameterBase (Surface.defParams definition)
        currentName = Surface.defName definition
        usedNames = nub
          [base
          | Surface.TId name _ <- Surface.tokenize body
          , let (base, parts) = parseIndexedIdent name
          , null parts]
        aliases =
          [ (name, target)
          | name <- usedNames
          , name /= currentName
          , name `notElem` formalNames
          , name /= "."
          , Just target <- [lookup name prior `orElse` lookup name continuumOperators]
          ]

    renderAliasBindings [] body = body
    renderAliasBindings (firstAlias : restAliases) body =
      "let " ++ renderAlias firstAlias
      ++ concat ["\n    " ++ renderAlias alias | alias <- restAliases]
      ++ "\n in (\n" ++ indentLines 2 body ++ "\n)"

    renderAlias (name, target) = name ++ " := " ++ target

    orElse (Just value) _ = Just value
    orElse Nothing fallback = fallback

    internalDefinitionName index =
      "FormuraeInternalDefinition" ++ show index

    checkedBody rawEgison definition body = foldr check body
      [ (parameter, parts)
      | parameter <- Surface.defParams definition
      , not (isPatternEllipsis parameter)
      , let (_, parts) = parseIndexedIdent parameter
      , not (null parts)
      ]
      where
        check (parameter, parts) inner =
          let prefix =
                "match assert " ++ show
                  ("indexed parameter " ++ parameter
                    ++ " metadata mismatch in " ++ Surface.defName definition)
                ++ " (tensorShape " ++ definitionParameterBase parameter
                ++ " = " ++ show (replicate (length parts) dimension)
                ++ " && Formurae.logicalTensorVariances "
                ++ definitionParameterBase parameter ++ " = "
                ++ show (map (varianceName . mapParameterVariance) parts)
                ++ ") as bool with"
          in if rawEgison
               then prefix ++ "\n  | #True -> (\n"
                    ++ indentLines 4 inner ++ "\n  )"
               else prefix ++ " | #True -> " ++ inner

    withIndexSymbolsMultiline source =
      "withSymbols [" ++ intercalate ", " indexNames ++ "] (\n"
      ++ indentLines 2 source ++ "\n)"

    indentLines count source = intercalate "\n"
      [replicate count ' ' ++ line | line <- lines source]

    isPatternEllipsis parameter =
      length parameter >= 3 && drop (length parameter - 3) parameter == "..."

    mapParameterVariance (Surface.IxPart Surface.VUp _) = FEIR.VarianceUp
    mapParameterVariance (Surface.IxPart Surface.VDown _) = FEIR.VarianceDown

    publicDefinitionName "." = "(.)"
    publicDefinitionName name = name

definitionParameterBase :: String -> String
definitionParameterBase = takeWhile isAlphaNum

dynamicDeclarations :: [DynamicValue] -> [String]
dynamicDeclarations dynamics = concatMap declarations dynamics ++ [""]
  where
    declarations dynamic =
      ["def " ++ dynamicDefinitionHead dynamic
        ++ dynamicDefinitionType dynamic ++ " := "
        ++ dynamicSource dynamic]
      ++ ["def " ++ binding ++ renderIndexParts (dynamicResultIndices dynamic)
            ++ " := " ++ dynamicName dynamic
            ++ renderIndexParts (dynamicResultIndices dynamic)
         | Just binding <- [dynamicBinding dynamic]]

dynamicDefinitionHead :: DynamicValue -> String
dynamicDefinitionHead dynamic =
  dynamicName dynamic ++ renderIndexParts (dynamicResultIndices dynamic)

-- Indexed top-level definitions must be monomorphic here.  Otherwise an
-- overloaded tensor operator leaves an implicit type-class dictionary lambda
-- behind the indexed Var, and a later whole-tensor reference observes that
-- lambda instead of the normalized tensor value.
dynamicDefinitionType :: DynamicValue -> String
dynamicDefinitionType dynamic =
  case (dynamicEncoding dynamic, dynamicResultIndices dynamic) of
    (EncodeTensor _ _, _ : _) -> " : Tensor MathValue"
    _ -> ""

dynamicBoundaryReference :: DynamicValue -> String
dynamicBoundaryReference dynamic =
  dynamicName dynamic ++ concat
    [ varianceMarker variance ++ name
    | (Surface.IxPart variance _, name) <-
        zip (dynamicResultIndices dynamic) metadataIndexNames
    ]

renderIndexParts :: [Surface.IxPart] -> String
renderIndexParts = concatMap renderPart
  where
    renderPart (Surface.IxPart variance name) =
      varianceMarker variance ++ name

varianceMarker :: Surface.Variance -> String
varianceMarker Surface.VUp = "~"
varianceMarker Surface.VDown = "_"

withIndexSymbols :: String -> String
withIndexSymbols source =
  "withSymbols [" ++ intercalate ", " indexNames ++ "] (" ++ source ++ ")"

renderWire :: [DynamicValue] -> SExpr -> String
renderWire dynamics expression
  | isTensorRecord expression
  , [identifier] <- nub (sort (negativeMarkers expression))
  , Just dynamic <- dynamicById identifier
  , EncodeTensor tensorType layout <- dynamicEncoding dynamic =
      atOrigin dynamic ("FormuraeInternalEncodeTensor "
      ++ show (FEIR.tensorTypeShape tensorType) ++ " "
      ++ show (map varianceName (FEIR.tensorTypeVariances tensorType)) ++ " "
      ++ show (FEIR.tensorTypeDfOrder tensorType) ++ " "
      ++ layoutCheckedTensorBoundaryValue layout dynamic)
  | List [Atom "ref", Atom identifierText] <- expression
  , Just negativeIdentifier <- readMaybe identifierText
  , negativeIdentifier < (0 :: Int)
  , Just dynamic <- dynamicById (negate negativeIdentifier)
  , EncodeScalar <- dynamicEncoding dynamic =
      atOrigin dynamic
        ("FormuraeInternalEncodeScalar " ++ scalarBoundaryValue dynamic)
  | Atom value <- expression = "FEIR.atom " ++ show value
  | StringAtom value <- expression = "FEIR.string " ++ show value
  | List values <- expression =
      "FEIR.list " ++ renderList (map (renderWire dynamics) values)
  where
    dynamicById identifier = find ((== identifier) . dynamicId) dynamics
    atOrigin dynamic value =
      case dynamicOrigin dynamic of
        Nothing -> value
        Just (FEIR.OriginId identifier) ->
          "FormuraeInternalAtOrigin "
          ++ show ("@@FORMURAE_ACTIVE_ORIGIN:" ++ show identifier ++ "@@")
          ++ " (\\_ -> " ++ value ++ ")"
    scalarBoundaryValue dynamic
      | dynamicAtGeometryBoundary dynamic =
          "(FEIR.unquoteAll " ++ dynamicBoundaryReference dynamic ++ ")"
      | otherwise = dynamicBoundaryReference dynamic
    tensorBoundaryValue dynamic
      | dynamicAtGeometryBoundary dynamic =
          "(FEIR.unquoteTensor " ++ dynamicBoundaryReference dynamic ++ ")"
      | otherwise = dynamicBoundaryReference dynamic
    layoutCheckedTensorBoundaryValue layout dynamic =
      case layout of
        FEIR.SymmetricLayout ->
          "(Formurae.requireSymmetricRank2 " ++ tensorBoundaryValue dynamic ++ ")"
        FEIR.AntisymmetricLayout ->
          "(Formurae.requireAntisymmetricRank2 " ++ tensorBoundaryValue dynamic ++ ")"
        _ -> tensorBoundaryValue dynamic

isTensorRecord :: SExpr -> Bool
isTensorRecord (List (Atom "tensor" : _)) = True
isTensorRecord _ = False

negativeMarkers :: SExpr -> [Int]
negativeMarkers (List [Atom "ref", Atom value]) =
  case readMaybe value of
    Just identifier | identifier < (0 :: Int) -> [negate identifier]
    _ -> []
negativeMarkers (List values) = concatMap negativeMarkers values
negativeMarkers _ = []

varianceName :: FEIR.Variance -> String
varianceName FEIR.VarianceUp = "up"
varianceName FEIR.VarianceDown = "down"

renderList :: [String] -> String
renderList values = "[" ++ intercalate ", " values ++ "]"
