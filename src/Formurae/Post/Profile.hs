module Formurae.Post.Profile
  ( RuleSource(..)
  , ResolvedStencil(..)
  , ResolvedRule(..)
  , ResolvedAxisRule(..)
  , FieldJetProfile(..)
  , ProfileError(..)
  , validateDiscretizationProfile
  , resolveDerivativeRule
  , resolveFieldJetProfile
  , resolvedRuleRadius
  ) where

import Data.List (find, group, sort, sortBy)
import Data.Ord (comparing)
import Numeric.Natural (Natural)

import Formurae.FEIR.Syntax
import Formurae.Post.Location (latticeClassOfPolicy)
import Formurae.Post.Stencil

data RuleSource
  = OrderSpecificSource OriginId
  | ClassDefaultSource OriginId
  | StandardV1Source
  deriving (Eq, Show)

-- | An odd-order Yee rule keeps a half-offset stencil: the storage offsets
-- depend on the operand's placement bit, which is only known at lowering.
-- An even-order Yee rule is an even fold of the order-1 stage and therefore
-- resolves to an ordinary centered stencil on the operand's sub-lattice.
data ResolvedStencil
  = ResolvedCenteredStencil CenteredStencil
  | ResolvedYeeStencil StaggeredStencil
  deriving (Eq, Show)

data ResolvedRule = ResolvedRule
  { resolvedRuleLatticeClass :: LatticeClass
  , resolvedRuleDerivativeOrder :: Int
  , resolvedRuleStencilFamily :: StencilFamily
  , resolvedRuleFormalAccuracy :: Int
  , resolvedRuleSource :: RuleSource
  , resolvedRuleStencil :: ResolvedStencil
  } deriving (Eq, Show)

data ResolvedAxisRule = ResolvedAxisRule
  { resolvedAxisId :: AxisId
  , resolvedAxisDerivativeOrder :: Int
  , resolvedAxisRule :: ResolvedRule
  , resolvedAxisHalo :: Int
  } deriving (Eq, Show)

data FieldJetProfile = FieldJetProfile
  { fieldJetProfileAxes :: [ResolvedAxisRule]
  , fieldJetProfileHalo :: [(AxisId, Int)]
  } deriving (Eq, Show)

data ProfileError
  = InvalidProfileDerivativeOrder Int
  | InvalidProfileFormalAccuracy Int
  | InvalidProfileLatticeFamily LatticeClass StencilFamily
  | DuplicateProfileRule LatticeClass (Maybe Int)
  | NonCanonicalProfileRuleOrder
  | ZeroFieldJetDerivative AxisId
  | DuplicateFieldJetDerivativeAxis AxisId
  | NonCanonicalFieldJetDerivativeOrder
  | FieldJetDerivativeOrderTooLarge AxisId Natural
  | ProfileStencilError StencilError
  deriving (Eq, Show)

-- | Validate the rule table independently of FEIR parsing.  Profile
-- fingerprints and wire versions are FEIR validation concerns; this module
-- owns only the executable stencil-selection contract.
validateDiscretizationProfile
    :: DiscretizationProfile -> Either ProfileError ()
validateDiscretizationProfile profile = do
  validateDuplicateRules rules
  if rules == sortBy (comparing ruleKey) rules
    then return ()
    else Left NonCanonicalProfileRuleOrder
  mapM_ validateRule rules
  where
    rules = discretizationDerivativeRules profile

validateRule :: DerivativeRule -> Either ProfileError ()
validateRule rule = do
  case derivativeRuleOrder rule of
    Nothing -> return ()
    Just (Positive order)
      | order <= 0 -> Left (InvalidProfileDerivativeOrder order)
      | otherwise -> return ()
  let PositiveEven accuracy = derivativeRuleAccuracy rule
  if accuracy <= 0 || odd accuracy
    then Left (InvalidProfileFormalAccuracy accuracy)
    else return ()
  case (derivativeRuleLatticeClass rule, derivativeRuleFamily rule) of
    (CollocatedLattice, CenteredTaylor) -> return ()
    (StaggeredLattice, Yee) -> return ()
    (lattice, family) -> Left (InvalidProfileLatticeFamily lattice family)

validateDuplicateRules :: [DerivativeRule] -> Either ProfileError ()
validateDuplicateRules rules =
  case duplicateValues (map ruleKey rules) of
    (lattice, order) : _ -> Left (DuplicateProfileRule lattice order)
    [] -> Right ()

-- | Resolve one ordinary FieldJet axis factor.  Opaque discrete requests do
-- not enter this API and therefore cannot accidentally inherit model-level
-- profile rules.
resolveDerivativeRule
    :: DiscretizationProfile
    -> LatticeClass
    -> Int
    -> Either ProfileError ResolvedRule
resolveDerivativeRule profile lattice derivativeOrder = do
  validateDiscretizationProfile profile
  if derivativeOrder <= 0
    then Left (InvalidProfileDerivativeOrder derivativeOrder)
    else return ()
  case selectedRule of
    Just (rule, source) -> resolveSelectedRule derivativeOrder rule source
    Nothing -> resolveStandardV1 lattice derivativeOrder
  where
    rules = discretizationDerivativeRules profile
    selectedRule =
      case find (matchesOrder lattice derivativeOrder) rules of
        Just rule -> Just (rule, OrderSpecificSource (derivativeRuleOrigin rule))
        Nothing ->
          case find (matchesDefault lattice) rules of
            Just rule -> Just (rule, ClassDefaultSource (derivativeRuleOrigin rule))
            Nothing -> Nothing

resolveSelectedRule
    :: Int
    -> DerivativeRule
    -> RuleSource
    -> Either ProfileError ResolvedRule
resolveSelectedRule derivativeOrder rule source =
  case (lattice, family) of
    (CollocatedLattice, CenteredTaylor) ->
      makeCenteredRule lattice derivativeOrder accuracy source
    (StaggeredLattice, Yee) -> makeYeeRule derivativeOrder accuracy source
    _ -> Left (InvalidProfileLatticeFamily lattice family)
  where
    lattice = derivativeRuleLatticeClass rule
    family = derivativeRuleFamily rule
    PositiveEven accuracy = derivativeRuleAccuracy rule

resolveStandardV1
    :: LatticeClass -> Int -> Either ProfileError ResolvedRule
resolveStandardV1 CollocatedLattice derivativeOrder =
  makeCenteredRule CollocatedLattice derivativeOrder 2 StandardV1Source
resolveStandardV1 StaggeredLattice derivativeOrder =
  makeYeeRule derivativeOrder 2 StandardV1Source

makeCenteredRule
    :: LatticeClass
    -> Int
    -> Int
    -> RuleSource
    -> Either ProfileError ResolvedRule
makeCenteredRule lattice derivativeOrder accuracy source = do
  stencil <- mapLeft ProfileStencilError
    (centeredTaylor derivativeOrder accuracy)
  Right ResolvedRule
    { resolvedRuleLatticeClass = lattice
    , resolvedRuleDerivativeOrder = derivativeOrder
    , resolvedRuleStencilFamily = CenteredTaylor
    , resolvedRuleFormalAccuracy = accuracy
    , resolvedRuleSource = source
    , resolvedRuleStencil = ResolvedCenteredStencil stencil
    }

-- | Every Yee order is the m-fold self-composition of the order-1
-- half-offset stage at the rule's formal accuracy, so identities like
-- Δ = divg∘grad and ∂³ = grad∘Δ hold exactly at every accuracy: odd
-- orders keep a half-offset stencil, even orders land back on the
-- operand's sub-lattice as centered stencils.
makeYeeRule :: Int -> Int -> RuleSource -> Either ProfileError ResolvedRule
makeYeeRule derivativeOrder accuracy source = do
  stage <- mapLeft ProfileStencilError
    (staggeredTaylorAtPairs 1 accuracy (accuracy `div` 2))
  composed <- mapLeft ProfileStencilError
    (composeStages derivativeOrder stage)
  let stencil = case composed of
        ComposedStaggered staggered -> ResolvedYeeStencil staggered
        ComposedCentered centered -> ResolvedCenteredStencil centered
  Right ResolvedRule
    { resolvedRuleLatticeClass = StaggeredLattice
    , resolvedRuleDerivativeOrder = derivativeOrder
    , resolvedRuleStencilFamily = Yee
    , resolvedRuleFormalAccuracy = accuracy
    , resolvedRuleSource = source
    , resolvedRuleStencil = stencil
    }

resolvedRuleRadius :: ResolvedRule -> Int
resolvedRuleRadius rule =
  case resolvedRuleStencil rule of
    ResolvedCenteredStencil stencil -> centeredRadius stencil
    ResolvedYeeStencil stage -> staggeredPairCount stage

resolveFieldJetProfile
    :: DiscretizationProfile
    -> GridPolicy
    -> FieldJet
    -> Either ProfileError FieldJetProfile
resolveFieldJetProfile profile policy fieldJet = do
  validateDiscretizationProfile profile
  multiIndex <- validateFieldJetMultiIndex (fieldJetMultiIndex fieldJet)
  axes <- mapM resolveAxis multiIndex
  Right FieldJetProfile
    { fieldJetProfileAxes = axes
    , fieldJetProfileHalo =
        [(resolvedAxisId axis, resolvedAxisHalo axis) | axis <- axes]
    }
  where
    lattice = latticeClassOfPolicy policy
    resolveAxis (axis, derivativeOrder) = do
      rule <- resolveDerivativeRule profile lattice derivativeOrder
      Right ResolvedAxisRule
        { resolvedAxisId = axis
        , resolvedAxisDerivativeOrder = derivativeOrder
        , resolvedAxisRule = rule
        , resolvedAxisHalo = resolvedRuleRadius rule
        }

validateFieldJetMultiIndex
    :: [(AxisId, Natural)] -> Either ProfileError [(AxisId, Int)]
validateFieldJetMultiIndex multiIndex = do
  case [axis | (axis, multiplicity) <- multiIndex, multiplicity == 0] of
    axis : _ -> Left (ZeroFieldJetDerivative axis)
    [] -> return ()
  case duplicateValues (map fst multiIndex) of
    axis : _ -> Left (DuplicateFieldJetDerivativeAxis axis)
    [] -> return ()
  if map fst multiIndex == sort (map fst multiIndex)
    then return ()
    else Left NonCanonicalFieldJetDerivativeOrder
  mapM convertOrder multiIndex
  where
    convertOrder (axis, multiplicity)
      | toInteger multiplicity > toInteger (maxBound :: Int) =
          Left (FieldJetDerivativeOrderTooLarge axis multiplicity)
      | otherwise = Right (axis, fromIntegral multiplicity)

matchesOrder :: LatticeClass -> Int -> DerivativeRule -> Bool
matchesOrder lattice derivativeOrder rule =
  derivativeRuleLatticeClass rule == lattice
  && derivativeRuleOrder rule == Just (Positive derivativeOrder)

matchesDefault :: LatticeClass -> DerivativeRule -> Bool
matchesDefault lattice rule =
  derivativeRuleLatticeClass rule == lattice
  && derivativeRuleOrder rule == Nothing

ruleKey :: DerivativeRule -> (LatticeClass, Maybe Int)
ruleKey rule =
  (derivativeRuleLatticeClass rule, order)
  where
    order = case derivativeRuleOrder rule of
      Nothing -> Nothing
      Just (Positive value) -> Just value

duplicateValues :: Ord value => [value] -> [value]
duplicateValues = duplicateHeads . group . sort
  where
    duplicateHeads [] = []
    duplicateHeads (values : rest) =
      case values of
        first : _
          | length values > 1 -> first : duplicateHeads rest
        _ -> duplicateHeads rest

mapLeft :: (left -> other) -> Either left right -> Either other right
mapLeft transform result =
  case result of
    Left err -> Left (transform err)
    Right value -> Right value
