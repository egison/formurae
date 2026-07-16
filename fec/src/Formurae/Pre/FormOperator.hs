{-# LANGUAGE PatternSynonyms #-}

-- | Name-resolved recognition of Formurae's canonical form/metric surface.
--
-- This module deliberately stops before either Egison normalization or FEIR
-- construction.  In particular, the scalar identity @0 - δ (d u)@ must be
-- recognized while its application tree and lexical scope are still intact;
-- rediscovering it from normalized scalar algebra would be both ambiguous and
-- too late to select the conservative nearest-neighbour metric plan.
module Formurae.Pre.FormOperator
  ( CanonicalOperator(..)
  , OperatorScope(..)
  , canonicalOperator
  , canonicalOperatorName
  , canonicalOperatorIsVisible
  , matchCanonicalUnary
  , matchScalarDeltaExpression
  , matchHodgeExteriorHodge
  , canonicalOperatorModeError
  , hasVariableGeometry
  ) where

import Formurae.Syntax
import Formurae.TensorExpr

data CanonicalOperator
  = CanonicalExteriorD
  | CanonicalHodge
  | CanonicalCodifferential
  | CanonicalScalarLaplacian
  | CanonicalHodgeLaplacian
  deriving (Eq, Ord, Show)

-- | Names hidden by lexical parameters or user definitions.  Callers retain
-- their existing source-order visibility rules and pass the names that are
-- shadowing at the expression being elaborated.
newtype OperatorScope = OperatorScope
  { operatorShadowedNames :: [String]
  } deriving (Eq, Ord, Show)

canonicalOperator :: String -> Maybe CanonicalOperator
canonicalOperator name = case name of
  "d" -> Just CanonicalExteriorD
  "hodge" -> Just CanonicalHodge
  "δ" -> Just CanonicalCodifferential
  "Δ" -> Just CanonicalScalarLaplacian
  -- parseModel maps the canonical source spelling Δ_H to this atomic name
  -- before underscore can be interpreted as a tensor-index marker.
  "ΔH" -> Just CanonicalHodgeLaplacian
  _ -> Nothing

canonicalOperatorName :: CanonicalOperator -> String
canonicalOperatorName operator = case operator of
  CanonicalExteriorD -> "d"
  CanonicalHodge -> "hodge"
  CanonicalCodifferential -> "δ"
  CanonicalScalarLaplacian -> "Δ"
  CanonicalHodgeLaplacian -> "Δ_H"

canonicalOperatorIsVisible :: OperatorScope -> CanonicalOperator -> Bool
canonicalOperatorIsVisible scope operator =
  internalName operator `notElem` operatorShadowedNames scope
  where
    internalName CanonicalHodgeLaplacian = "ΔH"
    internalName value = canonicalOperatorName value

-- | Match one unindexed unary application of a visible canonical operator.
-- Parentheses around the application or function head do not change the
-- surface identity.  Both whitespace application and call syntax are
-- accepted because TensorExpr intentionally preserves that distinction.
matchCanonicalUnary
    :: OperatorScope
    -> CanonicalOperator
    -> TensorExpr
    -> Maybe TensorExpr
matchCanonicalUnary scope expected expression
  | not (canonicalOperatorIsVisible scope expected) = Nothing
  | otherwise = case ungroup expression of
      TEApply function [operand]
        | canonicalHead function == Just expected -> Just operand
      TECall function [operand]
        | canonicalHead function == Just expected -> Just operand
      _ -> Nothing
  where
    canonicalHead function = case ungroup function of
      TEIdent name [] -> canonicalOperator name
      _ -> Nothing

-- | Recognize exactly @0 - δ (d u)@ modulo grouping.  The two operator
-- heads must both resolve to the canonical surface definitions.  Algebraic
-- near misses, indexed heads, user definitions, and bound parameters are
-- intentionally not folded.
matchScalarDeltaExpression :: OperatorScope -> TensorExpr -> Maybe TensorExpr
matchScalarDeltaExpression scope expression = do
  (zero, codifferentialApplication) <- case ungroup expression of
    TEBinary "-" lhs rhs -> Just (ungroup lhs, rhs)
    _ -> Nothing
  case zero of
    TENumber "0" -> pure ()
    _ -> Nothing
  exteriorApplication <- matchCanonicalUnary scope
    CanonicalCodifferential codifferentialApplication
  matchCanonicalUnary scope CanonicalExteriorD exteriorApplication

-- | Recognize the mathematical composition @hodge (d (hodge A))@ modulo
-- grouping and call syntax.  On a variable metric this must not be expanded
-- as ordinary pointwise Egison algebra: doing so loses the weighted discrete
-- adjoint that the canonical codifferential lowers to.  Callers either lower
-- a canonical codifferential or reject this explicit composition before
-- normalization.
matchHodgeExteriorHodge :: OperatorScope -> TensorExpr -> Maybe TensorExpr
matchHodgeExteriorHodge scope expression = do
  exteriorApplication <- matchCanonicalUnary scope CanonicalHodge expression
  innerHodge <- matchCanonicalUnary scope CanonicalExteriorD exteriorApplication
  matchCanonicalUnary scope CanonicalHodge innerHodge

-- Only the canonical standard name is mode-restricted.  A user definition
-- that shadows the same spelling remains an ordinary function.
canonicalOperatorModeError :: Mode -> CanonicalOperator -> Maybe String
canonicalOperatorModeError mode operator = case (mode, operator) of
  (CollocatedMode, CanonicalCodifferential) -> decOnly
  (CollocatedMode, CanonicalHodgeLaplacian) -> decOnly
  (DecMode, CanonicalScalarLaplacian) ->
    Just "canonical scalar Δ requires mode collocated; use Δ_H for differential forms"
  _ -> Nothing
  where
    decOnly = Just ("canonical " ++ canonicalOperatorName operator
      ++ " requires mode dec")

hasVariableGeometry :: Model -> Bool
hasVariableGeometry model = case (mMetric model, mEmbed model) of
  (Nothing, Nothing) -> False
  _ -> True

ungroup :: TensorExpr -> TensorExpr
ungroup (TEGroup expression) = ungroup expression
ungroup expression = expression
