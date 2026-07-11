module Formurae.Post.Normalize
  ( normalizeExpr
  ) where

import Data.List (groupBy, sort)
import qualified Data.Ratio as Ratio

import Formurae.Post.FMR

normalizeExpr :: FExpr -> FExpr
normalizeExpr expression =
  case expression of
    FExact numerator denominator
      | denominator > 0 -> exact (numerator Ratio.% denominator)
      | otherwise -> expression
    FVariable _ -> expression
    FGridReference _ _ -> expression
    FAdd terms -> normalizeAdd (map normalizeExpr terms)
    FMul factors -> normalizeMul (map normalizeExpr factors)
    FDiv numerator denominator ->
      normalizeDiv (normalizeExpr numerator) (normalizeExpr denominator)
    FPow base exponentValue ->
      normalizePow (normalizeExpr base) (normalizeExpr exponentValue)
    FCall name arguments -> FCall name (map normalizeExpr arguments)
    FCompare operator lhs rhs ->
      FCompare operator (normalizeExpr lhs) (normalizeExpr rhs)
    FSelect condition yes no ->
      let normalizedCondition = normalizeExpr condition
          normalizedYes = normalizeExpr yes
          normalizedNo = normalizeExpr no
      in if normalizedYes == normalizedNo
           then normalizedYes
           else FSelect normalizedCondition normalizedYes normalizedNo
    FRawExpr _ -> expression

normalizeAdd :: [FExpr] -> FExpr
normalizeAdd normalizedTerms =
  case rebuilt of
    [] -> exact 0
    [term] -> term
    terms -> FAdd terms
  where
    flattened = concatMap flattenAdd normalizedTerms
    coefficientTerms = sort [(base, coefficient) | term <- flattened
                                                  , let (coefficient, base) = splitCoefficient term]
    grouped = groupBy (\(left, _) (right, _) -> left == right) coefficientTerms
    rebuilt = sort (concatMap rebuildGroup grouped)
    rebuildGroup [] = []
    rebuildGroup group@((base, _) : _)
      | coefficient == 0 = []
      | otherwise = [attachCoefficient coefficient base]
      where
        coefficient = sum (map snd group)

normalizeMul :: [FExpr] -> FExpr
normalizeMul normalizedFactors
  | coefficient == 0 = exact 0
  | otherwise =
      case coefficientFactor ++ remaining of
        [] -> exact 1
        [factor] -> factor
        factors -> FMul factors
  where
    flattened = concatMap flattenMul normalizedFactors
    (exactFactors, symbolicFactors) = partitionExact flattened
    coefficient = product exactFactors
    remaining = sort symbolicFactors
    coefficientFactor
      | coefficient == 1 && not (null remaining) = []
      | otherwise = [exact coefficient]

normalizeDiv :: FExpr -> FExpr -> FExpr
normalizeDiv numerator denominator =
  case (asExact numerator, asExact denominator) of
    (_, Just 0) -> FDiv numerator denominator
    (Just left, Just right) -> exact (left / right)
    (_, Just 1) -> numerator
    (Just 0, _) -> exact 0
    _ | numerator == denominator -> exact 1
    _ -> FDiv numerator denominator

normalizePow :: FExpr -> FExpr -> FExpr
normalizePow base exponentValue =
  case asExact exponentValue of
    Just 0 -> exact 1
    Just 1 -> base
    Just exponentRational
      | Ratio.denominator exponentRational == 1 ->
          case asExact base of
            Just baseValue ->
              let exponentInteger = Ratio.numerator exponentRational
              in if exponentInteger >= 0
                   then exact (baseValue ^ exponentInteger)
                   else if baseValue /= 0
                     then exact (1 / (baseValue ^ abs exponentInteger))
                     else FPow base exponentValue
            Nothing -> FPow base exponentValue
    _ -> FPow base exponentValue

flattenAdd :: FExpr -> [FExpr]
flattenAdd (FAdd terms) = concatMap flattenAdd terms
flattenAdd expression = [expression]

flattenMul :: FExpr -> [FExpr]
flattenMul (FMul factors) = concatMap flattenMul factors
flattenMul expression = [expression]

splitCoefficient :: FExpr -> (Rational, Maybe FExpr)
splitCoefficient expression =
  case expression of
    FExact _ _ -> (exactValue expression, Nothing)
    FMul factors ->
      let (exactFactors, symbolicFactors) = partitionExact factors
          coefficient = product exactFactors
      in case symbolicFactors of
           [] -> (coefficient, Nothing)
           [factor] -> (coefficient, Just factor)
           remaining -> (coefficient, Just (FMul (sort remaining)))
    _ -> (1, Just expression)

attachCoefficient :: Rational -> Maybe FExpr -> FExpr
attachCoefficient coefficient Nothing = exact coefficient
attachCoefficient coefficient (Just base)
  | coefficient == 1 = base
  | otherwise = normalizeMul [exact coefficient, base]

partitionExact :: [FExpr] -> ([Rational], [FExpr])
partitionExact = foldr step ([], [])
  where
    step expression (exactValues, symbolicValues) =
      case asExact expression of
        Just value -> (value : exactValues, symbolicValues)
        Nothing -> (exactValues, expression : symbolicValues)

asExact :: FExpr -> Maybe Rational
asExact (FExact numerator denominator)
  | denominator > 0 = Just (numerator Ratio.% denominator)
asExact _ = Nothing

exactValue :: FExpr -> Rational
exactValue expression =
  case asExact expression of
    Just value -> value
    Nothing -> error "normalizeExpr: expected exact expression"

exact :: Rational -> FExpr
exact value = FExact (Ratio.numerator value) (Ratio.denominator value)
