-- | Versioned, backend-independent wire types for the Formurae Egison IR.
--
-- This module deliberately does not reuse the surface-language syntax types.
-- The pre-fec producer, the Egison encoder, and post-fec must agree on these
-- types without importing parser or backend implementation details.
module Formurae.FEIR.Syntax where

import Numeric.Natural (Natural)

-- --------------------------------------------------------------------- IDs

newtype ModelId = ModelId String
  deriving (Eq, Ord, Show)

newtype SourceId = SourceId String
  deriving (Eq, Ord, Show)

newtype RegistryId = RegistryId String
  deriving (Eq, Ord, Show)

newtype PrimitiveManifestId = PrimitiveManifestId String
  deriving (Eq, Ord, Show)

newtype Fingerprint = Fingerprint String
  deriving (Eq, Ord, Show)

newtype AxisId = AxisId Int
  deriving (Eq, Ord, Show)

newtype ParamId = ParamId Int
  deriving (Eq, Ord, Show)

newtype FunctionId = FunctionId Int
  deriving (Eq, Ord, Show)

newtype FieldId = FieldId Int
  deriving (Eq, Ord, Show)

newtype GeometryId = GeometryId Int
  deriving (Eq, Ord, Show)

newtype RawHelperId = RawHelperId Int
  deriving (Eq, Ord, Show)

newtype OriginId = OriginId Int
  deriving (Eq, Ord, Show)

newtype NodeId = NodeId Int
  deriving (Eq, Ord, Show)

newtype EquationId = EquationId Int
  deriving (Eq, Ord, Show)

newtype OpId = OpId String
  deriving (Eq, Ord, Show)

newtype SemanticKey = SemanticKey String
  deriving (Eq, Ord, Show)

newtype RequestGroupId = RequestGroupId String
  deriving (Eq, Ord, Show)

newtype AttributeId = AttributeId String
  deriving (Eq, Ord, Show)

-- These wrappers let validation distinguish the two positive-integer
-- contracts used by a discretization profile.  Their constructors are kept
-- available to the wire parser; FEIR validation is responsible for rejecting
-- non-positive and non-even values.
newtype Positive = Positive Int
  deriving (Eq, Ord, Show)

newtype PositiveEven = PositiveEven Int
  deriving (Eq, Ord, Show)

-- Tensor component indices are one-based, as in Egison's Tensor values.
newtype Basis = Basis [Int]
  deriving (Eq, Ord, Show)

-- ---------------------------------------------------------------- identity

data SourceIdentity = SourceIdentity
  { sourceIdentityId   :: SourceId
  , sourceIdentityPath :: FilePath
  } deriving (Eq, Ord, Show)

data ModelIdentity = ModelIdentity
  { modelIdentityId     :: ModelId
  , modelIdentityName   :: String
  , modelIdentitySource :: SourceIdentity
  } deriving (Eq, Ord, Show)

-- ----------------------------------------------------------------- origin

data SourceLocation = SourceLocation
  { sourceLocationSource      :: SourceId
  , sourceLocationPath        :: FilePath
  , sourceLocationLine        :: Int
  , sourceLocationEndLine     :: Int
  , sourceLocationStartColumn :: Int
  , sourceLocationEndColumn   :: Int
  } deriving (Eq, Ord, Show)

data ExpansionFrame = ExpansionFrame
  { expansionFrameName       :: String
  , expansionFrameDefinition :: SourceLocation
  , expansionFrameCall       :: SourceLocation
  } deriving (Eq, Ord, Show)

data SourceOrigin = SourceOrigin
  { sourceOriginLocation :: SourceLocation
  , sourceOriginTrace    :: [ExpansionFrame]
  } deriving (Eq, Ord, Show)

-- Association lists are intentional wire values.  Canonical serialization
-- sorts them by ID, and validation rejects duplicate keys.  Keeping this
-- module on @base@ avoids making the protocol depend on a Map implementation.
newtype OriginTable = OriginTable [(OriginId, SourceOrigin)]
  deriving (Eq, Ord, Show)

newtype ProvenanceTable = ProvenanceTable [(NodeId, [OriginId])]
  deriving (Eq, Ord, Show)

-- -------------------------------------------------------------- core enums

data Mode
  = CollocatedMode
  | DecMode
  deriving (Eq, Ord, Show)

data GridPolicy
  = CollocatedPolicy
  | PrimalPolicy
  | DualPolicy
  deriving (Eq, Ord, Show)

data Variance
  = VarianceUp
  | VarianceDown
  deriving (Eq, Ord, Show)

data Layout
  = ScalarLayout
  | VectorLayout
  | SymmetricLayout
  | AntisymmetricLayout
  | FullLayout
  | FormLayout
  deriving (Eq, Ord, Show)

data Lifetime
  = UserStateLifetime
  | StepLocalLifetime
  deriving (Eq, Ord, Show)

data TimeSlot
  = CurrentTime
  | NextTime
  deriving (Eq, Ord, Show)

data FunctionClass
  = IntrinsicFunction
  | AnalyticFunction
  | ExternalFunction
  deriving (Eq, Ord, Show)

data CompareOp
  = CompareEq
  | CompareNe
  | CompareLt
  | CompareLe
  | CompareGt
  | CompareGe
  deriving (Eq, Ord, Show)

-- ---------------------------------------------------------- logical registry

-- | The declared shape of the domain along one axis.  This is a property of
-- the model's logical registry, not of the discretization profile: a bounded
-- axis is a different domain, and every derivative along it shares the one
-- declared boundary treatment.  The ghost fill value keeps backend semantics
-- as a raw string, exactly like a parameter's raw value.
data BoundaryCondition
  = PeriodicBoundary
  | SbpBoundary
  | GhostBoundary String
  deriving (Eq, Ord, Show)

data AxisDecl = AxisDecl
  { axisDeclId            :: AxisId
  , axisDeclSourceName    :: String
  , axisDeclCanonicalName :: String
  , axisDeclBoundary      :: BoundaryCondition
  , axisDeclOrigin        :: OriginId
  } deriving (Eq, Ord, Show)

data ParameterDecl = ParameterDecl
  { parameterDeclId          :: ParamId
  , parameterDeclSourceName  :: String
  , parameterDeclBackendName :: String
  , parameterDeclRawValue    :: String
  , parameterDeclOrigin      :: OriginId
  } deriving (Eq, Ord, Show)

data FunctionDecl = FunctionDecl
  { functionDeclId          :: FunctionId
  , functionDeclSourceName  :: String
  , functionDeclBackendName :: String
  , functionDeclArity       :: Maybe Int
  , functionDeclClass       :: FunctionClass
  , functionDeclOrigin      :: Maybe OriginId
  } deriving (Eq, Ord, Show)

data TensorType = TensorType
  { tensorTypeShape     :: [Int]
  , tensorTypeVariances :: [Variance]
  , tensorTypeDfOrder   :: Int
  } deriving (Eq, Ord, Show)

data LogicalFieldDecl = LogicalFieldDecl
  { logicalFieldId                :: FieldId
  , logicalFieldSourceName        :: String
  , logicalFieldPolicy            :: GridPolicy
  , logicalFieldTensorType        :: TensorType
  , logicalFieldLayout            :: Layout
  -- | A 'Nothing' entry represents a syntactically unmarked tensor axis.  Its
  -- semantic variance is still explicit in 'logicalFieldTensorType', while
  -- post-fec uses this declaration metadata for deterministic storage
  -- projection without confusing an unmarked axis with an explicit subscript.
  , logicalFieldDeclaredVariances :: [Maybe Variance]
  , logicalFieldLifetime          :: Lifetime
  , logicalFieldOrigin            :: OriginId
  } deriving (Eq, Ord, Show)

data RawHelper = RawHelper
  { rawHelperId     :: RawHelperId
  , rawHelperText   :: String
  , rawHelperOrigin :: OriginId
  } deriving (Eq, Ord, Show)

-- --------------------------------------------------------------- geometry

data GeometryDecl = GeometryDecl
  { geometryDeclId         :: GeometryId
  , geometryDeclSourceName :: Maybe String
  , geometryDeclOrigin     :: Maybe OriginId
  , geometryDeclKind       :: GeometryKind
  } deriving (Eq, Ord, Show)

data GeometryKind
  = EuclideanGeometry
  | OrthogonalScaleGeometry [(AxisId, ScalarNF)] GeometryNF
  | EmbeddedOrthogonalGeometry [ScalarNF] GeometryNF
  deriving (Eq, Ord, Show)

data GeometryNF = GeometryNF
  { geometryMetricComponents      :: TensorNF
  , geometryInverseMetric         :: TensorNF
  , geometryScaleFactors          :: [(AxisId, ScalarNF)]
  , geometryVolumeElement         :: ScalarNF
  , geometryOrthogonalityVerified :: Bool
  } deriving (Eq, Ord, Show)

-- --------------------------------------------------------- discretization

data DiscretizationProfile = DiscretizationProfile
  { discretizationProfileFingerprint :: Fingerprint
  , discretizationDerivativeRules    :: [DerivativeRule]
  , discretizationMixedRule          :: MixedStencilRule
  } deriving (Eq, Ord, Show)

data DerivativeRule = DerivativeRule
  { derivativeRuleLatticeClass :: LatticeClass
  , derivativeRuleOrder        :: Maybe Positive
  , derivativeRuleFamily       :: StencilFamily
  , derivativeRuleAccuracy     :: PositiveEven
  , derivativeRuleOrigin       :: OriginId
  } deriving (Eq, Ord, Show)

data LatticeClass
  = CollocatedLattice
  | StaggeredLattice
  deriving (Eq, Ord, Show)

data StencilFamily
  = CenteredTaylor
  | Yee
  deriving (Eq, Ord, Show)

data MixedStencilRule
  = FixedAxisOrder
  deriving (Eq, Ord, Show)

-- ------------------------------------------------------------- expressions

data TensorNF = TensorNF
  { tensorNFShape      :: [Int]
  , tensorNFVariances  :: [Variance]
  , tensorNFDfOrder    :: Int
  , tensorNFComponents :: [(Basis, ScalarNF)]
  } deriving (Eq, Ord, Show)

-- Closed, backend-independent mathematical constants.  Their symbolic
-- identity is preserved through FEIR; a backend chooses its numeric
-- representation only at the final rendering boundary.
data NamedConstant
  = Pi
  deriving (Eq, Ord, Show)

data ScalarNF
  = Exact Integer Integer
  | NamedConstant NamedConstant
  | Parameter ParamId
  | Coordinate AxisId
  | Add [ScalarNF]
  | Mul [ScalarNF]
  | Div ScalarNF ScalarNF
  | Pow ScalarNF ScalarNF
  | Intrinsic FunctionId [ScalarNF]
  | AnalyticCall FunctionId [ScalarNF]
  | Select PredicateNF ScalarNF ScalarNF
  | FieldJet FieldJet
  | OpaqueDiscrete OpaqueDiscrete
  | Ref NodeId
  deriving (Eq, Ord, Show)

data PredicateNF
  = BoolExact Bool
  | Compare CompareOp ScalarNF ScalarNF
  | Not PredicateNF
  | And [PredicateNF]
  | Or [PredicateNF]
  deriving (Eq, Ord, Show)

data FieldJet = FieldJetValue
  { fieldJetFieldId    :: FieldId
  , fieldJetTimeSlot   :: TimeSlot
  , fieldJetBasis      :: Basis
  , fieldJetArguments  :: [ScalarNF]
  , fieldJetMultiIndex :: [(AxisId, Natural)]
  } deriving (Eq, Ord, Show)

data OpaqueDiscrete = OpaqueDiscreteCall
  { opaqueDiscreteOpId         :: OpId
  , opaqueDiscreteSemanticKey  :: SemanticKey
  , opaqueDiscreteRequestGroup :: RequestGroupId
  , opaqueDiscreteResultBasis  :: Basis
  , opaqueDiscreteOperands     :: [FEValue]
  , opaqueDiscreteAttributes   :: [Attribute]
  } deriving (Eq, Ord, Show)

-- The design document uses "DiscreteCall" for the payload record and
-- "OpaqueDiscrete" for its ScalarNF node.  Keep the descriptive wire type
-- name while providing the design spelling to producer/consumer code.
type DiscreteCall = OpaqueDiscrete

data Attribute = Attribute
  { attributeId    :: AttributeId
  , attributeValue :: AttributeValue
  } deriving (Eq, Ord, Show)

-- Opaque primitive attributes are typed wire values rather than unparsed
-- strings.  The recursive list form covers structured, primitive-specific
-- metadata while the ID-specific alternatives preserve registry validation.
data AttributeValue
  = AttributeExact Integer Integer
  | AttributeNatural Natural
  | AttributeInteger Integer
  | AttributeBoolean Bool
  | AttributeString String
  | AttributeAxis AxisId
  | AttributeParameter ParamId
  | AttributeFunction FunctionId
  | AttributeField FieldId
  | AttributeGeometry GeometryId
  | AttributeGridPolicy GridPolicy
  | AttributeTimeSlot TimeSlot
  | AttributeBasis Basis
  | AttributeValues [AttributeValue]
  deriving (Eq, Ord, Show)

data FEValue
  = ScalarValue ScalarNF
  | TensorValue TensorNF
  deriving (Eq, Ord, Show)

-- -------------------------------------------------------- actions and model

-- A whole-field target is used by tensor-valued analytic initializers and
-- updates.  Raw component initializers use the component alternative, which
-- removes the ambiguity present when a target carried only a FieldId.
data FieldTarget
  = WholeFieldTarget FieldId TimeSlot
  | FieldComponentTarget FieldId TimeSlot Basis
  deriving (Eq, Ord, Show)

data FEEquation = FEEquation
  { feEquationId     :: EquationId
  , feEquationTarget :: FieldTarget
  , feEquationRhs    :: TensorNF
  , feEquationOrigin :: OriginId
  } deriving (Eq, Ord, Show)

data FEAction
  = BindValue NodeId FEValue OriginId
  | Materialize FieldId FEValue OriginId
  | UpdateField FEEquation
  deriving (Eq, Ord, Show)

data FEInitializer
  = AnalyticInitializer FEEquation
  | RawInitializer FieldTarget String OriginId
  deriving (Eq, Ord, Show)

data FEProgram = FEProgram
  { feProgramModel               :: ModelIdentity
  , feProgramRegistryId          :: RegistryId
  , feProgramPrimitiveManifestId :: PrimitiveManifestId
  , feProgramDiscretization      :: DiscretizationProfile
  , feProgramMode                :: Mode
  , feProgramDimension           :: Int
  , feProgramAxes                :: [AxisDecl]
  , feProgramGeometry            :: GeometryDecl
  , feProgramParameters          :: [ParameterDecl]
  , feProgramFunctions           :: [FunctionDecl]
  , feProgramFields              :: [LogicalFieldDecl]
  , feProgramInitializers        :: [FEInitializer]
  , feProgramStepActions         :: [FEAction]
  , feProgramRawHelpers          :: [RawHelper]
  , feProgramOrigins             :: OriginTable
  , feProgramProvenance          :: ProvenanceTable
  } deriving (Eq, Ord, Show)
