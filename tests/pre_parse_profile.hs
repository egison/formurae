module Main where

import Formurae.Pre.Parse (parseModel)
import Formurae.Syntax

main :: IO ()
main = do
  model <- parseModel "profile.fme" "profile" source
  assertEqual "profile rule"
    [DiscretizationDecl
      { discretizationLatticeClass = SurfaceCollocated
      , discretizationDerivativeOrder = Just 2
      , discretizationStencilFamily = SurfaceCentered
      , discretizationFormalAccuracy = 4
      , discretizationSourceLine = 4
      }]
    (mDiscretizationDecls model)
  assertEqual "user definitions stay in source order"
    ["first", "second"] (map defName (mDefs model))
  case mDefs model of
    firstDef : _ ->
      assertEqual "analytic derivative retains the formurae-pre syntax tag"
        "pd2r1_x u" (defBody firstDef)
    [] -> fail "missing definitions"
  case mSteps model of
    firstStep : _ ->
      assertEqual "step expression is not macro-expanded"
        "second u" (sEx firstStep)
    [] -> fail "missing step"
  putStrLn "formurae-pre profile parser tests: ok"
  where
    source = unlines
      [ "mode collocated"
      , "dimension 1"
      , "axes x"
      , "discretization collocated derivative 2 centered accuracy 4"
      , "field u : scalar"
      , "def first u = ∂^2_x u"
      , "def second u = first u"
      , "init:"
      , "  u = 0"
      , "step:"
      , "  u' = second u"
      ]

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = fail
      (label ++ ": expected " ++ show expected ++ ", got " ++ show actual)
