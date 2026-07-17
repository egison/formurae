module Main where

import Data.Ratio ((%))
import Numeric.Natural (Natural)

import Formurae.FEIR.Codec (setProfileFingerprint)
import Formurae.FEIR.Syntax
import Formurae.Post.Profile
import Formurae.Post.Stencil

origin1, origin2, origin3 :: OriginId
origin1 = OriginId 1
origin2 = OriginId 2
origin3 = OriginId 3

axisX, axisY :: AxisId
axisX = AxisId 1
axisY = AxisId 2

profile :: DiscretizationProfile
profile = profileWith
  [ DerivativeRule CollocatedLattice Nothing CenteredTaylor
      (PositiveEven 2) origin1
  , DerivativeRule CollocatedLattice (Just (Positive 2)) CenteredTaylor
      (PositiveEven 4) origin2
  , DerivativeRule StaggeredLattice Nothing Yee
      (PositiveEven 2) origin3
  ]

profileWith :: [DerivativeRule] -> DiscretizationProfile
profileWith rules = setProfileFingerprint
  (DiscretizationProfile
    (Fingerprint "pending") rules FixedAxisOrder)

fieldJet :: [(AxisId, Natural)] -> FieldJet
fieldJet multiIndex = FieldJetValue
  (FieldId 1) CurrentTime (Basis [])
  [Coordinate axisX, Coordinate axisY] multiIndex

main :: IO ()
main = do
  assertEqual "valid profile" (Right ())
    (validateDiscretizationProfile profile)
  checkPrecedence
  checkMixedHalo
  checkStaggered
  checkInvalidProfiles
  checkInvalidFieldJetMultiIndex
  putStrLn "post profile tests: ok"

checkPrecedence :: IO ()
checkPrecedence = do
  first <- assertRight "class default beats standard-v1"
    (resolveDerivativeRule profile CollocatedLattice 1)
  assertEqual "class default accuracy" 2
    (resolvedRuleFormalAccuracy first)
  assertEqual "class default source" (ClassDefaultSource origin1)
    (resolvedRuleSource first)
  assertEqual "class default radius" 1 (resolvedRuleRadius first)

  second <- assertRight "order-specific beats class default"
    (resolveDerivativeRule profile CollocatedLattice 2)
  assertEqual "order-specific accuracy" 4
    (resolvedRuleFormalAccuracy second)
  assertEqual "order-specific source" (OrderSpecificSource origin2)
    (resolvedRuleSource second)
  assertEqual "order-specific compact radius" 2
    (resolvedRuleRadius second)
  case resolvedRuleStencil second of
    ResolvedCenteredStencil stencil ->
      assertEqual "order-specific exact five-point weights"
        [ (-2, (-1) / 12), (-1, 4 / 3), (0, (-5) / 2)
        , (1, 4 / 3), (2, (-1) / 12)
        ]
        (centeredWeights stencil)
    _ -> fail "order-specific centered rule selected a non-centered stencil"

  let onlyOverride = profileWith
        [DerivativeRule CollocatedLattice (Just (Positive 2)) CenteredTaylor
           (PositiveEven 4) origin2]
  fallback <- assertRight "standard-v1 is the final fallback"
    (resolveDerivativeRule onlyOverride CollocatedLattice 1)
  assertEqual "standard fallback source" StandardV1Source
    (resolvedRuleSource fallback)
  assertEqual "standard fallback p2" 2
    (resolvedRuleFormalAccuracy fallback)

checkMixedHalo :: IO ()
checkMixedHalo = do
  plan <- assertRight "mixed FieldJet profile"
    (resolveFieldJetProfile profile CollocatedPolicy
      (fieldJet [(axisX, 2), (axisY, 1)]))
  assertEqual "mixed axes preserve canonical order"
    [axisX, axisY] (map resolvedAxisId (fieldJetProfileAxes plan))
  assertEqual "mixed axes resolve per-axis order"
    [2, 1] (map resolvedAxisDerivativeOrder (fieldJetProfileAxes plan))
  assertEqual "order-2 override changes only x accuracy"
    [4, 2]
    (map (resolvedRuleFormalAccuracy . resolvedAxisRule)
      (fieldJetProfileAxes plan))
  assertEqual "axis-specific halo"
    [(axisX, 2), (axisY, 1)] (fieldJetProfileHalo plan)

checkStaggered :: IO ()
checkStaggered = do
  first <- assertRight "Yee order 1"
    (resolveDerivativeRule profile StaggeredLattice 1)
  assertEqual "Yee order-1 family" Yee (resolvedRuleStencilFamily first)
  assertEqual "Yee order-1 radius" 1 (resolvedRuleRadius first)
  case resolvedRuleStencil first of
    ResolvedYeeStencil stage ->
      assertEqual "Yee order-1 pair weights"
        [(-1, -1), (1, 1)] (staggeredTwiceWeights stage)
    _ -> fail "Yee order-1 rule lost its half-offset stage"
  second <- assertRight "Yee order 2"
    (resolveDerivativeRule profile StaggeredLattice 2)
  assertEqual "Yee order-2 family" Yee (resolvedRuleStencilFamily second)
  assertEqual "Yee order-2 radius" 1 (resolvedRuleRadius second)
  assertEqual "Yee class default source" (ClassDefaultSource origin3)
    (resolvedRuleSource second)
  case resolvedRuleStencil second of
    ResolvedCenteredStencil composed ->
      assertEqual "Yee order-2 composes to the compact second derivative"
        [(-1, 1), (0, -2), (1, 1)] (centeredWeights composed)
    _ -> fail "Yee order-2 rule did not compose to a centered stencil"
  assertLeft "Yee order 3 is unsupported"
    (== UnsupportedStaggeredDerivativeOrder 3)
    (resolveDerivativeRule profile StaggeredLattice 3)

  plan <- assertRight "mixed staggered per-axis rules"
    (resolveFieldJetProfile profile PrimalPolicy
      (fieldJet [(axisX, 1), (axisY, 2)]))
  assertEqual "mixed Yee halo remains one per axis"
    [(axisX, 1), (axisY, 1)] (fieldJetProfileHalo plan)

  let wideYeeProfile = profileWith
        [DerivativeRule StaggeredLattice Nothing Yee
          (PositiveEven 4) origin3]
  wideFirst <- assertRight "Yee accuracy-4 order 1"
    (resolveDerivativeRule wideYeeProfile StaggeredLattice 1)
  assertEqual "accuracy-4 order-1 accuracy" 4
    (resolvedRuleFormalAccuracy wideFirst)
  assertEqual "accuracy-4 order-1 halo" 2 (resolvedRuleRadius wideFirst)
  case resolvedRuleStencil wideFirst of
    ResolvedYeeStencil stage ->
      assertEqual "accuracy-4 half-offset weights"
        [(-3, 1 % 24), (-1, (-9) % 8), (1, 9 % 8), (3, (-1) % 24)]
        (staggeredTwiceWeights stage)
    _ -> fail "accuracy-4 order-1 rule lost its half-offset stage"
  wideSecond <- assertRight "Yee accuracy-4 order 2"
    (resolveDerivativeRule wideYeeProfile StaggeredLattice 2)
  assertEqual "accuracy-4 order-2 accuracy" 4
    (resolvedRuleFormalAccuracy wideSecond)
  assertEqual "accuracy-4 order-2 halo" 3 (resolvedRuleRadius wideSecond)
  case resolvedRuleStencil wideSecond of
    ResolvedCenteredStencil composed ->
      assertEqual "accuracy-4 order-2 is the composed pair"
        [ (-3, 1 % 576), (-2, (-3) % 32), (-1, 87 % 64), (0, (-365) % 144)
        , (1, 87 % 64), (2, (-3) % 32), (3, 1 % 576)
        ]
        (centeredWeights composed)
    _ -> fail "accuracy-4 order-2 rule did not compose to a centered stencil"

checkInvalidProfiles :: IO ()
checkInvalidProfiles = do
  let duplicate = profileWith
        [ DerivativeRule CollocatedLattice Nothing CenteredTaylor
            (PositiveEven 2) origin1
        , DerivativeRule CollocatedLattice Nothing CenteredTaylor
            (PositiveEven 4) origin2
        ]
  assertLeft "duplicate rule key"
    (== DuplicateProfileRule CollocatedLattice Nothing)
    (validateDiscretizationProfile duplicate)

  let oddAccuracy = profileWith
        [DerivativeRule CollocatedLattice Nothing CenteredTaylor
          (PositiveEven 3) origin1]
  assertLeft "centered accuracy must be positive even"
    (== InvalidProfileFormalAccuracy 3)
    (validateDiscretizationProfile oddAccuracy)

  let wrongFamily = profileWith
        [DerivativeRule CollocatedLattice Nothing Yee
          (PositiveEven 2) origin1]
  assertLeft "collocated lattice rejects Yee"
    (== InvalidProfileLatticeFamily CollocatedLattice Yee)
    (validateDiscretizationProfile wrongFamily)

  let wideYee = profileWith
        [DerivativeRule StaggeredLattice Nothing Yee
          (PositiveEven 4) origin1]
  assertEqual "Yee accepts every positive even accuracy" (Right ())
    (validateDiscretizationProfile wideYee)

  let order3Yee = profileWith
        [DerivativeRule StaggeredLattice (Just (Positive 3)) Yee
          (PositiveEven 2) origin1]
  assertLeft "Yee v1 declaration rejects order 3"
    (== UnsupportedStaggeredDerivativeOrder 3)
    (validateDiscretizationProfile order3Yee)

  let nonCanonical = profileWith
        [ DerivativeRule StaggeredLattice Nothing Yee
            (PositiveEven 2) origin1
        , DerivativeRule CollocatedLattice Nothing CenteredTaylor
            (PositiveEven 2) origin2
        ]
  assertLeft "profile rule table is canonical"
    (== NonCanonicalProfileRuleOrder)
    (validateDiscretizationProfile nonCanonical)

checkInvalidFieldJetMultiIndex :: IO ()
checkInvalidFieldJetMultiIndex = do
  assertLeft "zero FieldJet multiplicity"
    (== ZeroFieldJetDerivative axisX)
    (resolveFieldJetProfile profile CollocatedPolicy
      (fieldJet [(axisX, 0)]))
  assertLeft "duplicate FieldJet axis"
    (== DuplicateFieldJetDerivativeAxis axisX)
    (resolveFieldJetProfile profile CollocatedPolicy
      (fieldJet [(axisX, 1), (axisX, 2)]))
  assertLeft "FieldJet axes are canonical"
    (== NonCanonicalFieldJetDerivativeOrder)
    (resolveFieldJetProfile profile CollocatedPolicy
      (fieldJet [(axisY, 1), (axisX, 1)]))

assertRight :: String -> Either errorType value -> IO value
assertRight _ (Right value) = return value
assertRight label (Left _) = fail (label ++ ": expected Right")

assertLeft
    :: String
    -> (errorType -> Bool)
    -> Either errorType value
    -> IO ()
assertLeft label predicate result =
  case result of
    Left err
      | predicate err -> return ()
      | otherwise -> fail (label ++ ": unexpected error")
    Right _ -> fail (label ++ ": expected Left")

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = return ()
  | otherwise = fail
      (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)
