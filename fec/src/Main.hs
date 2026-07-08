-- fec -- the Formurae compiler.
--
-- Formurae (.fe) is the mathematical surface language of this repo,
-- named after Muranushi's Formura (its Latin-looking plural, and a pun
-- on "formulae").  fec translates it into the embedded DSL form: an
-- Egison program over lib/fmrgen.egi + lib/fmrdsl.egi.  All semantics
-- (tensor index notation, differential forms, CAS expansion, the .fmr
-- printer) live on the Egison side; this is a thin, line-oriented
-- translator.  Base library only; build and run with
--
--   cabal run -v0 fec -- model.fe > model.egi
--   egison -l lib/fmrgen.egi -l lib/fmrdsl.egi model.egi > model.fmr
--
-- Formurae grammar (v1):
--   -- comment                      (kept out of the output)
--   dimension 3                     (REQUIRED; v1 supports 3 only)
--   axes x, y, z                    (REQUIRED; fixes the coordinate frame
--                                    the operators refer to.  The names map
--                                    to the internal coordinates x,y,z, so
--                                    axes r, theta, phi works in CAS exprs)
--   metric scale [h1, h2, h3]       Lame scale factors of an orthogonal
--                                   metric, written in the axis names.
--   embedding [X1, X2, ..., Xm]     coordinate map into R^m: the metric
--                                   g_ab = dX/dx_a . dX/dx_b is DERIVED
--                                   by the CAS (orthogonality is checked
--                                   symbolically and gates generation);
--                                   scale factors h_a = sqrt(g_aa).
--                                   Backquotes keep factors compact
--                                   (`(2 + cos theta)), and expandAll
--                                   removes them before the half-cell
--                                   substitution.
--                                   Enables lb (Laplace-Beltrami): the
--                                   hodge factors sqrt(g)/h_a^2 become
--                                   coefficient FIELDS evaluated by the
--                                   CAS at the half-cell placements.
--   def NAME ARG = EXPR             user-defined operator, expanded at use
--                                    sites (file scope; a body may use only
--                                    operators defined before it).  The
--                                    Laplacian is predefined exactly this
--                                    way -- def \916 u = 0 - delta (d u) --
--                                    and may be redefined.
--   param NAME = RAW                Formura parameter (double :: NAME = RAW)
--   extern NAME                     extern function :: NAME
--                                   (core scalar intrinsics such as sin,
--                                    cos, exp, sqrt, ... are also emitted
--                                    automatically when they are used)
--   raw LINE                        verbatim Formura helper line
--   field NAME : scalar             one grid field
--   field NAME : vector             3 components (NAMEx,NAMEy,NAMEz)
--   field NAME : 1-form | 2-form    3 components placed by form degree (DEC)
--   init:
--     COMP = RAW                    raw Formura initializer (component)
--     NAME = [| e1, e2, e3 |]       vector/form initializer (component-wise raw)
--     NAME = [| [| xx, xy, xz |],   symmetric-tensor initializer: full 3x3
--            [| yy, yz |], [| zz |] |]  (checked symmetric) or upper triangle;
--                                    may span lines until brackets balance
--     NAME := EXPR                  CAS initializer (printed via fmrInit)
--   step:
--     let N_i = EXPR                named tensor expression (inlined)
--     let N = EXPR                  named scalar expression (inlined)
--     local N = EXPR                intermediate grid field (emitted line)
--     N' = EXPR                     scalar / vector / k-form update
--                                   (form operators: d, delta (or codiff);
--                                    with metric scale: lb NAME)
--     N'_i = EXPR                   vector update (explicit index equation)
--   assert-dd-zero NAME'            gate generation on d(d NAME') == 0
--
-- Unicode: Greek letters transliterate to their ASCII names (theta,
-- phi, ...); the derivative sign is d (so d_x may be written as
-- either ∂_x or ∂x), the small delta is the codifferential, the minus sign
-- is '-'.  The capital delta is a prelude def (0 - delta (d u)), so it
-- is the Laplacian of the model's geometry (lap, or lb under a declared
-- metric); the derived 4th-order Laplacian is spelled with the capital
-- delta followed by 4 (lap4 is an accepted alias).  Writing d twice fuses to the
-- compact second difference (there is no d2 operator), and delta (d u) on
-- a scalar lowers to -(Laplacian), so the heat equation reads
-- u' = u - dt * delta (d u) with basic operators only; all of these
-- generate byte-identical code to their named-operator forms.
-- Nabla combinations work too: nabla-cross is curl, nabla-dot is divg,
-- and nabla^2 (or with the superscript two) is the Laplacian.
-- In index equations superscripts (~i) and subscripts (_i) are
-- interchangeable (Euclidean grids; variance is documentation), and
-- Kronecker's delta carries one index per mark (delta~i_j, or with
-- the small delta sign; the fused delta_ij is rejected).
--
-- A vector update may be written without indices (E' = E + dt * curl B);
-- bare vector names combine elementwise and curl applies to the whole
-- field.  X' in a RHS refers to the updated field (Formura's primed
-- array), so B' = B - dt * curl E' is the symplectic pair.

import Data.Char (isAlpha, isAlphaNum, isDigit, isSpace)
import Data.List (dropWhileEnd, intercalate, sort, nub, stripPrefix)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

vecOps, vecRet, deltaOps :: [String]
vecOps = ["d", "delta", "codiff", "\948", "curl", "divg", "dGrad"]
vecRet = ["curl"]
deltaOps = ["delta", "codiff", "\948"]

-- Scalar functions supported as Formura/C extern functions.  In Egison's
-- tensor notation these are scalar functions that can be lifted over tensors;
-- fec uses the list to make the Formura extern surface explicit.
scalarIntrinsics :: [String]
scalarIntrinsics =
  [ "sin", "cos", "tan"
  , "asin", "acos", "atan", "atan2"
  , "sinh", "cosh", "tanh"
  , "exp", "log", "sqrt", "pow", "fabs"
  ]

fatal :: String -> IO a
fatal msg = hPutStrLn stderr ("fec: error: " ++ msg) >> exitFailure

-- ---------------------------------------------------------------- model

data Kind = Scalar | Vector Bool | Form Int | SymM deriving (Eq, Show)

data Init = IRaw String String | IVec String [String]
          | ISym String [String]   -- xx, yy, zz, xy, xz, yz
          | ICas String String

data SK = KLet | KLocal | KEq deriving Eq

data Step = Step { sk :: SK, sNm :: String, sIdx :: [String], sEx :: String }

data Model = Model
  { mName   :: String
  , mDim    :: Int
  , mAxes   :: [String]
  , mParams :: [(String, String)]
  , mHelp   :: [String]
  , mFlds   :: [(String, Kind)]
  , mInits  :: [Init]
  , mSteps  :: [Step]
  , mDd     :: Maybe String
  , mMetric :: Maybe [String]
  , mEmbed  :: Maybe [String]
  , mDefs   :: [(String, (String, String))]  -- name -> (param, body); latest first
  }

kindOf :: Model -> String -> Maybe Kind
kindOf m nm = lookup nm (mFlds m)

declaredExterns :: [String] -> [String]
declaredExterns = foldr collect []
  where
    collect h acc =
      case stripPrefix "extern function :: " (strip h) of
        Just nm | not (null (strip nm)) -> strip nm : acc
        _ -> acc

autoScalarExterns :: Model -> [String] -> [String]
autoScalarExterns m helps =
  [ "extern function :: " ++ nm
  | nm <- scalarIntrinsics
  , nm `notElem` declared
  , any (usesFunctionName nm) (modelExprTexts m)
  ]
  where
    declared = declaredExterns helps

modelExprTexts :: Model -> [String]
modelExprTexts m =
  map snd (mParams m)
  ++ helperExprs (mHelp m)
  ++ concatMap initExpr (mInits m)
  ++ map sEx (mSteps m)
  ++ maybe [] id (mMetric m)
  ++ map (snd . snd) (mDefs m)
  where
    helperExprs = filter isExprHelper
    isExprHelper h =
      let s = strip h
      in not (null s)
         && take 1 s /= "#"
         && stripPrefix "extern function :: " s == Nothing
    initExpr it = case it of
      IRaw _ rhs -> [rhs]
      IVec _ es -> es
      ISym _ es -> es
      ICas _ ex -> [ex]

usesFunctionName :: String -> String -> Bool
usesFunctionName nm = go . tokenize
  where
    go [] = False
    go (TId w False : ts)
      | w == nm =
          case dropWhile isSpTok ts of
            TC '(' : _ -> True
            TId _ _ : _ -> True
            _ -> go ts
    go (_ : ts) = go ts

-- ------------------------------------------------------------- utilities

strip, rstrip :: String -> String
rstrip = dropWhileEnd isSpace
strip = dropWhile isSpace . rstrip

isW :: Char -> Bool
isW c = isAlphaNum c || c == '_'

stripComment :: String -> String
stripComment ('-':'-':_) = []
stripComment (c:cs) = c : stripComment cs
stripComment [] = []

-- split on a separator at paren/bracket depth 0
splitTop :: Char -> String -> [String]
splitTop sep = go 0 []
  where
    go :: Int -> String -> String -> [String]
    go _ acc [] = [strip (reverse acc)]
    go d acc (c:cs)
      | c `elem` "([" = go (d + 1) (c : acc) cs
      | c `elem` ")]" = go (d - 1) (c : acc) cs
      | c == sep && d == 0 = strip (reverse acc) : go 0 [] cs
      | otherwise = go d (c : acc) cs

-- NAME(_i)? = EXPR   with NAME = [A-Za-z][A-Za-z0-9]*
eqForm :: String -> String -> Maybe (String, Bool, String)
eqForm marker s = do
  rest0 <- if null marker then Just s else stripPrefix (marker ++ " ") s
  let rest = dropWhile isSpace rest0
  (nm, r1) <- ident rest
  let (ix, r2) = case stripPrefix "_i" r1 of
                   Just r -> (True, r)
                   Nothing -> (False, r1)
  r3 <- stripPrefix "=" (dropWhile isSpace r2)
  let ex = strip r3
  if null ex then Nothing else Just (nm, ix, ex)
  where
    ident (c:cs) | isAlpha c = let (a, b) = span isAlphaNum cs in Just (c : a, b)
    ident _ = Nothing

-- def NAME PARAM = BODY   (user-defined operator; names may be Unicode)
defForm :: String -> Maybe (String, String, String)
defForm r = do
  (nm, r1) <- identU (strip r)
  (p, r2) <- identU (dropWhile isSpace r1)
  r3 <- stripPrefix "=" (dropWhile isSpace r2)
  let body = strip r3
  if null body then Nothing else Just (nm, p, body)
  where
    identU (c:cs) | isAlpha c = let (a, b) = span isW cs in Just (c : a, b)
    identU _ = Nothing

-- NAME'(_a)(_b)? = EXPR   (a, b single index letters)
primeEqForm :: String -> Maybe (String, [String], String)
primeEqForm s = do
  (nm, r1) <- ident s
  r2 <- stripPrefix "'" r1
  let (ixs, r3) = idxs r2
  r4 <- stripPrefix "=" (dropWhile isSpace r3)
  let ex = strip r4
  if null ex then Nothing else Just (nm, ixs, ex)
  where
    ident (c:cs) | isAlpha c = let (a, b) = span isAlphaNum cs in Just (c : a, b)
    ident _ = Nothing
    idxs ('_':c:rest) | isAlpha c, not (isAlphaNum (headDef ' ' rest)) =
      let (more, r) = idxs rest in ([c] : more, r)
    idxs r = ([], r)
    headDef d [] = d
    headDef _ (c:_) = c

-- ---------------------------------------------------------------- parser

data Section = STop | SInit | SStep

-- the prelude: operators predefined as ordinary user definitions
-- (post-transliteration spelling).  A def in the file may redefine them.
prelude :: [(String, (String, String))]
prelude = [("\916", ("u", "0 - delta (d u)"))]   -- Δ = -δd, the Laplacian

parseFe :: String -> String -> IO Model
parseFe name txt = go STop (Model name 0 [] [] [] [] [] [] Nothing Nothing Nothing prelude)
                      (zip [1 :: Int ..] (lines txt))
  where
    -- dimension and axes are required: they fix the coordinate frame
    -- that gives the operators their meaning (which axis d_theta is,
    -- what an index letter in d_j ranges over)
    go _ m []
      | mDim m == 0 = fatal "dimension declaration is required (dimension 3)"
      | null (mAxes m) = fatal "axes declaration is required (e.g. axes x, y, z)"
      | length (mAxes m) /= mDim m =
          fatal ("axes declares " ++ show (length (mAxes m))
                 ++ " names for dimension " ++ show (mDim m))
      | otherwise = do
          -- resolve user-defined operators (definition order; a body may
          -- use only operators defined before it) and expand all uses
          defs <- resolveDefs (reverse (mDefs m))
          steps' <- mapM (\st -> do ex <- applyDefs defs (sEx st)
                                    return st { sEx = ex })
                         (reverse (mSteps m))
          inits' <- mapM (expandInit defs) (reverse (mInits m))
          return m { mParams = reverse (mParams m), mHelp = reverse (mHelp m)
                   , mFlds = reverse (mFlds m), mInits = inits'
                   , mSteps = steps', mDefs = defs }

    go sec m ((ln, raw):rest) = do
      let code = rstrip (stripComment raw)
          s = strip code
      if null s then go sec m rest else do
        case s of
          "init:" -> go SInit m rest
          "step:" -> go SStep m rest
          _ -> do
            let sec' = if take 1 code /= " " then STop else sec
            case sec' of
              STop -> top ln s m >>= \m' -> go STop m' rest
              -- an init line may continue over following lines until its
              -- brackets balance (tensor initializers span rows)
              SInit | bal s > 0 ->
                let (more, rest') = grab (bal s) rest
                in ini ln (s ++ " " ++ more) m >>= \m' -> go SInit m' rest'
              SInit -> ini ln s m >>= \m' -> go SInit m' rest
              SStep -> stp ln s m >>= \m' -> go SStep m' rest

    bal t = sum [1 :: Int | c <- t, c `elem` "(["] - sum [1 | c <- t, c `elem` ")]"]

    resolveDefs ds = goD [] ds
      where
        -- earlier defs are expanded into the body, so a resolved body
        -- may contain no def name at all: any survivor is a self or
        -- forward reference
        allNames = map fst ds
        goD acc [] = return acc
        goD acc ((nm, (p, body)) : more) = do
          body' <- applyDefs acc body
          case [w | TId w _ <- tokenize body', w `elem` allNames] of
            (w:_) -> fatal ("def " ++ nm ++ " uses " ++ w
                            ++ " which is not defined before it")
            [] -> goD ((nm, (p, body')) : acc) more

    -- expand operator applications: NAME ARG with ARG an identifier or
    -- a parenthesized expression.  Bodies are def-free after
    -- resolveDefs, so one pass suffices; arguments are expanded first.
    applyDefs defs s = fmap untok (goE (tokenize s))
      where
        goE [] = return []
        goE (TId nm False : ts)
          | Just (p, body) <- lookup nm defs = do
              let (_, rest) = span isSpTok ts
              (arg, rest') <- case rest of
                (TC '(' : r) -> case closeParenT 1 r [] of
                  Just (inner, r') -> return (untok inner, r')
                  Nothing -> fatal ("unbalanced argument to " ++ nm)
                (TId a pr : r) -> return (a ++ (if pr then "'" else ""), r)
                _ -> fatal ("operator " ++ nm ++ " needs an argument")
              arg' <- fmap untok (goE (tokenize arg))
              let argS = if all (\c -> isW c || c == '\'') arg'
                           then arg' else "(" ++ arg' ++ ")"
                  bodyT = concatMap (substP p argS) (tokenize body)
              fmap ((TC '(' : bodyT ++ [TC ')']) ++) (goE rest')
        goE (t : ts) = fmap (t :) (goE ts)
        substP p argS (TId w pr)
          | w == p = tokenize (argS ++ (if pr then "'" else ""))
        substP _ _ t = [t]

    expandInit defs it = case it of
      ICas nm ex -> do ex' <- applyDefs defs ex
                       return (ICas nm ex')
      _ -> return it

    grab _ [] = ("", [])
    grab d ((_, raw):rest) =
      let t = strip (rstrip (stripComment raw))
          d' = d + bal t
      in if d' <= 0
           then (t, rest)
           else let (more, rest') = grab d' rest
                in (t ++ " " ++ more, rest')

    top ln s m
      | Just r <- stripPrefix "def " s =
          case defForm r of
            Just (nm, p, body) -> return m { mDefs = (nm, (p, body)) : mDefs m }
            Nothing -> fatal ("bad def (line " ++ show ln
                              ++ "): def NAME ARG = EXPR")
      | Just r <- stripPrefix "param " s =
          case break (== '=') r of
            (nm, '=':v) | not (null (strip nm)) && not (null (strip v)) ->
              return m { mParams = (strip nm, strip v) : mParams m }
            _ -> fatal ("bad param (line " ++ show ln ++ ")")
      | Just r <- stripPrefix "extern " s =
          return m { mHelp = ("extern function :: " ++ strip r) : mHelp m }
      | s == "raw" = return m { mHelp = "" : mHelp m }
      | Just r <- stripPrefix "raw " s = return m { mHelp = r : mHelp m }
      | Just r <- stripPrefix "field " s =
          case break (== ':') r of
            (nm0, ':':k0) ->
              let nm = strip nm0
                  k = strip k0
              in if not (validName nm)
                   then fatal ("bad field name: " ++ nm ++ " (line " ++ show ln ++ ")")
                   else case k of
                     "scalar" -> add nm Scalar
                     "vector" -> add nm (Vector False)
                     "vector @ staggered" -> add nm (Vector True)
                     "symmetric @ staggered" -> add nm SymM
                     "1-form" -> add nm (Form 1)
                     "2-form" -> add nm (Form 2)
                     _ -> fatal ("bad field kind: " ++ k ++ " (line " ++ show ln ++ ")")
            _ -> fatal ("bad field decl: " ++ s ++ " (line " ++ show ln ++ ")")
      | Just r <- stripPrefix "assert-dd-zero " s = return m { mDd = Just (strip r) }
      | Just r <- stripPrefix "embedding " s =
          case strip r of
            ('[':r1) | last r1 == ']' ->
              return m { mEmbed = Just (splitTop ',' (init r1)) }
            _ -> fatal ("bad embedding (line " ++ show ln ++ ")")
      | Just r <- stripPrefix "metric scale " s =
          case strip r of
            ('[':r1) | last r1 == ']' ->
              let es = splitTop ',' (init r1)
              in if length es == 3
                   then return m { mMetric = Just es }
                   else fatal ("metric scale needs 3 factors (line " ++ show ln ++ ")")
            _ -> fatal ("bad metric scale (line " ++ show ln ++ ")")
      | Just r <- stripPrefix "dimension " s = dim r
      | Just r <- stripPrefix "dim " s = dim r
      | Just r <- stripPrefix "axes " s =
          return m { mAxes = map strip (splitTop ',' r) }
      | otherwise = fatal ("unrecognized: " ++ s ++ " (line " ++ show ln ++ ")")
      where
        add nm k = return m { mFlds = (nm, k) : mFlds m }
        validName (c:cs) = isAlpha c && all isAlphaNum cs
        validName [] = False
        dim r | all isDigit (strip r), n <- read (strip r) =
                  if n /= (3 :: Int)
                    then fatal ("v1 supports dimension 3 only (got " ++ show n ++ ")")
                    else return m { mDim = n }
              | otherwise = fatal ("bad dimension (line " ++ show ln ++ ")")

    ini ln s m
      | Just (nm, ex) <- casForm s = return m { mInits = ICas nm ex : mInits m }
      | Just (nm, rhs) <- rawForm s =
          case (kindOf m nm, vecLit rhs) of
            (Just SymM, Just rows) -> do
              rows' <- mapM (\r -> case vecLit (strip r) of
                        Just es -> return (map strip es)
                        Nothing -> fatal ("symmetric initializer rows must be [| ... |] (line "
                                          ++ show ln ++ ")")) rows
              comps <- case rows' of
                -- full 3x3: must be symmetric; the upper triangle is used
                [r1@[_, _, _], r2@[_, _, _], r3@[_, _, _]]
                  | r1 !! 1 == r2 !! 0 && r1 !! 2 == r3 !! 0 && r2 !! 2 == r3 !! 1 ->
                      return [r1 !! 0, r2 !! 1, r3 !! 2, r1 !! 1, r1 !! 2, r2 !! 2]
                  | otherwise ->
                      fatal ("symmetric initializer is not symmetric (line " ++ show ln ++ ")")
                -- upper triangle by rows: [| xx,xy,xz |], [| yy,yz |], [| zz |]
                [[xx, xy, xz], [yy, yz], [zz]] -> return [xx, yy, zz, xy, xz, yz]
                _ -> fatal ("symmetric initializer needs 3x3 or upper-triangle rows (line "
                            ++ show ln ++ ")")
              return m { mInits = ISym nm comps : mInits m }
            (k, Just elems) -> do
              let ok = case k of
                         Just (Vector _) -> True
                         Just (Form _) -> True
                         _ -> False
              if not ok
                then fatal ("[| ... |] initializer needs a vector/form/symmetric field: "
                            ++ nm ++ " (line " ++ show ln ++ ")")
                else if length elems /= 3
                  then fatal ("[| ... |] initializer needs 3 components (line "
                              ++ show ln ++ ")")
                  else return m { mInits = IVec nm elems : mInits m }
            _ -> return m { mInits = IRaw nm rhs : mInits m }
      | otherwise = fatal ("bad init: " ++ s ++ " (line " ++ show ln ++ ")")
      where
        casForm t = do
          (nm, r1) <- identW t
          let (nm', r1') = case stripPrefix "'" r1 of
                             Just r -> (nm ++ "'", r)
                             Nothing -> (nm, r1)
          r2 <- stripPrefix ":=" (dropWhile isSpace r1')
          let ex = strip r2
          if null ex then Nothing else Just (nm', ex)
        rawForm t = do
          (nm, r1) <- identW t
          r2 <- stripPrefix "=" (dropWhile isSpace r1)
          let ex = strip r2
          if null ex then Nothing else Just (nm, ex)
        identW (c:cs) | isAlpha c = let (a, b) = span isW cs in Just (c : a, b)
        identW _ = Nothing
        vecLit t = do
          r1 <- stripPrefix "[|" t
          let r2 = reverse r1
          r3 <- stripPrefix "]|" r2
          return (splitTop ',' (reverse r3))

    -- superscripts (~i) and subscripts (_i) are interchangeable in step
    -- equations (Euclidean grids; the variance is documentation), so
    -- v'~i = ... + \8706_j s~i~j normalizes to the underscore form here
    stp ln s0 m
      | Just bad <- banned =
          fatal (bad ++ " (line " ++ show ln ++ ")")
      | Just (nm, ix, ex) <- eqForm "let" s =
          return m { mSteps = Step KLet nm (if ix then ["i"] else []) ex : mSteps m }
      | Just (nm, _, ex) <- eqForm "local" s =
          return m { mSteps = Step KLocal nm [] ex : mSteps m }
      | Just (nm, ixs, ex) <- primeEqForm s =
          return m { mSteps = Step KEq nm ixs ex : mSteps m }
      | otherwise = fatal ("bad step eq: " ++ s ++ " (line " ++ show ln ++ ")")
      where
        s = map (\c -> if c == '~' then '_' else c) s0
        -- not part of the language: d2 is d applied twice, and the
        -- Kronecker delta carries one index per mark
        banned = foldr (\t acc -> check t `orElse` acc) Nothing (tokenize s)
        check (TId nm _)
          | take 3 nm == "d2_" =
              Just ("d2 is not an operator; write d_a (d_a u) for the second difference: " ++ nm)
          | ("delta" : ps) <- splitOn '_' nm, any ((> 1) . length) ps =
              Just ("Kronecker delta takes one index per mark (delta~i_j): " ++ nm)
        check _ = Nothing
        orElse (Just x) _ = Just x
        orElse Nothing y = y

-- --------------------------------------------------- expression rewriting

data Tok = TId String Bool   -- identifier, followed-by-prime
         | TC Char

tokenize :: String -> [Tok]
tokenize [] = []
tokenize (c:cs)
  | isAlpha c =
      let (a, b) = span isW cs
      in case b of
           ('\'':b') -> TId (c : a) True : tokenize b'
           _ -> TId (c : a) False : tokenize b
  | otherwise = TC c : tokenize cs

data Elem = EId String Bool | EC Char | ERaw String
          | EMarkV String | EMarkL String

-- the field to which lb is applied, if any (scans the same
-- preprocessed form the rewriter uses, so Δ and delta (d u) count)
lbTarget :: Model -> Maybe String
lbTarget m = case concatMap scan (mSteps m) of
               (nm:_) -> Just nm
               [] -> Nothing
  where
    scan st = go (tokenize (stepPre m (sEx st)))
    go (TId "lb" False : ts) =
      case dropWhile isSp ts of
        (TId nm False : rest) | kindOf m nm == Just Scalar -> nm : go rest
        _ -> go ts
    go (_ : ts) = go ts
    go [] = []
    isSp (TC c) = isSpace c
    isSp _ = False


-- ------------------------------------ tensor index equations (staggered)
--
-- v'_i   = v_i + (dt / rho0) * d_j s_i_j
-- s'_i_j = s_i_j + dt * (la * delta_ij * d_k v'_k + mu * (d_i v'_j + d_j v'_i))
--
-- Free indices come from the left-hand side; a repeated index letter
-- inside a term is summed over 1..3 (Einstein convention).  delta_ij is
-- Kronecker's delta, and epsilon_i_j_k is the 3D Levi-Civita symbol.
-- d_a applied to a staggered field component is the
-- half-cell difference anchored at the placement of the TARGET
-- component (Virieux/Yee); symmetric components are canonicalized
-- (s_2_1 means s_1_2).

data ITok = II String | IC Char deriving Eq

itok :: String -> [ITok]
itok [] = []
itok (c:cs)
  | isAlpha c =
      let (a, b) = span (\ch -> isAlphaNum ch || ch == '_' || ch == '\'') cs
      in II (c : a) : itok b
  | otherwise = IC c : itok cs

splitOn :: Char -> String -> [String]
splitOn ch = foldr step [[]]
  where
    step c acc@(cur:rest) | c == ch = [] : acc
                          | otherwise = (c : cur) : rest
    step _ [] = [[]]

plOf :: [Bool] -> String
plOf hs = "[" ++ intercalate ", " [if h then "1 / 2" else "0" | h <- hs] ++ "]"

placeV :: Int -> String
placeV a = plOf [a == 1, a == 2, a == 3]

placeS :: Int -> Int -> String
placeS a b | a == b = plOf [False, False, False]
           | otherwise = plOf [c == a || c == b | c <- [1, 2, 3]]

leviCivita3 :: [Int] -> Int
leviCivita3 xs
  | sort xs /= [1, 2, 3] = 0
  | xs `elem` [[1, 2, 3], [2, 3, 1], [3, 1, 2]] = 1
  | otherwise = -1

indexContractionDots :: String -> String
indexContractionDots = go Nothing
  where
    go _ [] = []
    go prev ('.':cs)
      | maybe False isSpace prev
      , case cs of
          c:_ -> isSpace c
          [] -> False
      = '*' : go (Just '*') cs
    go _ (c:cs) = c : go (Just c) cs

indexDefs :: Model -> Step -> IO [String]
indexDefs m st =
  case (kindOf m (sNm st), sIdx st) of
    (Just (Vector True), [fi]) ->
      mapM (\a -> comp [(fi, a)] (placeV a) (base ++ show a)) [1, 2, 3]
    (Just SymM, [fi, fj]) ->
      mapM (\(a, b) -> comp [(fi, a), (fj, b)] (placeS a b) (base ++ show a ++ show b))
           ([(1,1),(2,2),(3,3),(1,2),(1,3),(2,3)] :: [(Int, Int)])
    _ -> fatal ("index equation has wrong indices for its field kind: " ++ sNm st)
  where
    base = "feq" ++ sNm st
    comp env anchor defnm = do
      e <- ixExpand m env anchor (sEx st)
      return ("def " ++ defnm ++ " := " ++ e)

-- expand one component: parens are independent regions, a repeated
-- index letter is summed over the smallest term containing it, then
-- names and derivatives are resolved
ixExpand :: Model -> [(String, Int)] -> String -> String -> IO String
ixExpand m env anchor expr = expandRegion env (itok (indexContractionDots expr))
  where
    -- a region is a +/- separated list of terms
    expandRegion env' ts = goR env' (0 :: Int) [] ts
    goR env' _ cur [] = expandTerm env' (reverse cur)
    goR env' d cur (t@(IC c) : rest)
      | c `elem` "([" = goR env' (d + 1) (t : cur) rest
      | c `elem` ")]" = goR env' (d - 1) (t : cur) rest
      | d == 0 && c `elem` "+-" = do
          e1 <- expandTerm env' (reverse cur)
          e2 <- goR env' 0 [] rest
          return (e1 ++ [c] ++ e2)
    goR env' d cur (t : rest) = goR env' d (t : cur) rest

    -- one term: sum its own (depth-0) dummies, then resolve
    expandTerm env' ts =
      case levelDummies env' ts of
        (k:_) -> do
          parts <- mapM (\n -> expandTerm ((k, n) : env') ts) [1, 2, 3]
          return ("(" ++ intercalate " + " parts ++ ")")
        [] -> resolve env' ts

    levelDummies env' ts = nub (go2 (0 :: Int) ts)
      where
        go2 _ [] = []
        go2 d (IC c : rest)
          | c `elem` "([" = go2 (d + 1) rest
          | c `elem` ")]" = go2 (d - 1) rest
          | otherwise = go2 d rest
        go2 d (II w : rest)
          | d == 0 = [l | l <- idxLetters w, lookup l env' == Nothing] ++ go2 d rest
          | otherwise = go2 d rest

    idxLetters w =
      let (_, parts) = splitIdent w
      in [ pt | pt <- parts, length pt == 1, all isAlpha pt ]

    splitIdent w = case splitOn '_' w of
      (b : parts) -> (b, parts)
      [] -> (w, [])

    fieldBase w = (takeWhile (/= '\'') w, length (filter (== '\'') w))

    resolveIx env' pt
      | all isDigit pt = Just (read pt)
      | otherwise = lookup pt env'

    -- resolve a dummy-free term; parens recurse as fresh regions
    resolve _ [] = return ""
    resolve env' (IC '(' : rest) = do
      let (inner, rest') = matchParen (0 :: Int) [] rest
      e <- expandRegion env' inner
      fmap (("(" ++ e ++ ")") ++) (resolve env' rest')
    resolve env' (IC c : rest) = fmap ([c] ++) (resolve env' rest)
    resolve env' (II w : rest)
      -- Kronecker delta, one index per mark: delta~i_j / \948~i_j
      -- (normalized to delta_i_j).  The fused delta_ij is rejected at
      -- parse time.
      | ("epsilon", [p@[_], q@[_], r@[_]]) <- splitIdentW = do
          vals <- mapM (need env') [p, q, r]
          fmap ((show (leviCivita3 vals)) ++) (resolve env' rest)
      | ("delta", [p@[_], q@[_]]) <- splitIdentW = do
          pv <- need env' p
          qv <- need env' q
          fmap ((if pv == qv then "1" else "0") ++) (resolve env' rest)
      | ("d", [k]) <- splitIdentW = do
          n <- need env' k
          let rest1 = dropWhile isSp rest
          case rest1 of
            (II opw : rest2) -> do
              ref <- fieldRef env' opw
              fmap (deriv n ref ++) (resolve env' rest2)
            _ -> fatal ("d_" ++ k ++ " needs a field operand: " ++ expr)
      | isField = do
          ref <- fieldRef env' w
          fmap (fst ref ++) (resolve env' rest)
      | otherwise = fmap (w ++) (resolve env' rest)
      where
        splitIdentW = splitIdent w
        isField = kindOf m (fst (fieldBase (fst splitIdentW))) /= Nothing
                    && not (null (snd splitIdentW))

    matchParen d acc (IC ')' : rest)
      | d == 0 = (reverse acc, rest)
      | otherwise = matchParen (d - 1) (IC ')' : acc) rest
    matchParen d acc (t@(IC '(') : rest) = matchParen (d + 1) (t : acc) rest
    matchParen d acc (t : rest) = matchParen d (t : acc) rest
    matchParen _ acc [] = (reverse acc, [])

    isSp (IC c) = isSpace c
    isSp _ = False

    need env' l = case resolveIx env' l of
      Just n -> return n
      Nothing -> fatal ("unresolved index '" ++ l ++ "' in: " ++ expr)

    fieldRef env' w = do
      let (b, parts) = splitIdent w
          (fname, primes) = fieldBase b
      ns <- mapM (need env') parts
      case (kindOf m fname, ns) of
        (Just (Vector True), [a]) ->
          return (fname ++ replicate primes '\'' ++ "_" ++ show a, placeV a)
        (Just SymM, [a, b2]) ->
          let (lo, hi) = (min a b2, max a b2)
          in return (fname ++ replicate primes '\'' ++ "_" ++ show lo ++ "_" ++ show hi,
                     placeS a b2)
        (Just Scalar, []) ->
          return (fname ++ replicate primes '\'', plOf [False, False, False])
        _ -> fatal ("bad field reference in index equation: " ++ w)

    deriv n (comp, place) =
      "dYee " ++ show n ++ " " ++ anchor ++ " (" ++ comp ++ ", " ++ place ++ ")"

isIndexKind :: Maybe Kind -> Bool
isIndexKind (Just (Vector True)) = True
isIndexKind (Just SymM) = True
isIndexKind _ = False

-- names X whose updated value X' is referenced in some step RHS
primedRefs :: Model -> [String]
primedRefs m = sort (nub [nm | st <- mSteps m, TId nm True <- tokenize (sEx st)
                             , kindOf m nm /= Nothing])

opPass :: Model -> [String] -> [Tok] -> [Elem]
opPass m lets = go
  where
    forms = [(n, d) | (n, Form d) <- mFlds m]
    vecs = [n | (n, Vector False) <- mFlds m]
    go [] = []
    go (TId op False : ts)
      | op `elem` vecOps
      , (sp@(_:_), ts1) <- span isSpaceTok ts
      , (TId nm pr : ts2) <- ts1 =
          case lookup nm forms of
            Just _ ->
              let fn = if op `elem` deltaOps then "codiff" else "dForm"
                  tag = nm ++ (if pr then "fN" else "f")
              in EMarkL ("formComps (" ++ fn ++ " " ++ tag ++ ")") : go ts2
            Nothing
              | op == "d" || op `elem` deltaOps ->
                  EId op False : map toElem sp ++ go ts1
              | nm `elem` vecs || nm `elem` lets ->
                  let core = op ++ " " ++ nm ++ (if pr then "'" else "") ++ "_#"
                  in (if op `elem` vecRet then EMarkV core else ERaw core) : go ts2
              | otherwise -> EId op False : map toElem sp ++ go ts1
    go (t : ts) = toElem t : go ts
    isSpaceTok (TC c) = isSpace c
    isSpaceTok _ = False
    toElem (TId n p) = EId n p
    toElem (TC c) = EC c

-- rename user axis names to the internal coordinates x,y,z
renameAxes :: Model -> String -> String
renameAxes m = concatMap out . tokenize
  where
    out (TId nm pr) = subst nm ++ (if pr then "'" else "")
    out (TC c) = [c]
    subst nm = case lookup nm (zip (mAxes m) ["x", "y", "z"]) of
                 Just v -> v
                 Nothing -> nm

-- the Laplace-Beltrami stencil: flux divergence over the coefficient
-- fields generated for the declared metric
lbExpansion :: String
lbExpansion = "((dYee 1 [0, 0, 0] (f1, [1 / 2, 0, 0]) + dYee 2 [0, 0, 0] (f2, [0, 1 / 2, 0]) + dYee 3 [0, 0, 0] (f3, [0, 0, 1 / 2])) / sg)"

-- mathematical derivative operators, resolved by axis name
mathOps :: Model -> String -> String
mathOps m = concatMap out . tokenize
  where
    axmap = zip (mAxes m) ["1", "2", "3"]
    out (TId nm pr)
      | not pr, Just rest <- stripPrefix "d2_" nm, Just n <- lookup rest axmap = "dC2 " ++ n
      | not pr, Just rest <- stripPrefix "d_" nm, Just n <- lookup rest axmap = "dC " ++ n
      | not pr, nm == "lap4" = ['\916', '4']   -- alias of the main spelling Δ4
      | otherwise = nm ++ (if pr then "'" else "")
    out (TC c) = [c]

metricOn :: Model -> Bool
metricOn m = mMetric m /= Nothing || mEmbed m /= Nothing

-- shared step-expression preprocessing: fuse repeated d, lower
-- delta (d u), rename axes, resolve math operators (incl. Δ)
stepPre :: Model -> String -> String
stepPre m = mathOps m . renameAxes m . lowerDeltaD m . fuseDD

isSpTok :: Tok -> Bool
isSpTok (TC c) = isSpace c
isSpTok _ = False

untok :: [Tok] -> String
untok = concatMap out
  where
    out (TId nm pr) = nm ++ (if pr then "'" else "")
    out (TC c) = [c]

-- collect tokens up to the ')' closing an already-consumed '('
closeParenT :: Int -> [Tok] -> [Tok] -> Maybe ([Tok], [Tok])
closeParenT _ [] _ = Nothing
closeParenT n (TC '(' : ts) acc = closeParenT (n + 1) ts (TC '(' : acc)
closeParenT n (TC ')' : ts) acc
  | n == 1 = Just (reverse acc, ts)
  | otherwise = closeParenT (n - 1) ts (TC ')' : acc)
closeParenT n (t : ts) acc = closeParenT n ts (t : acc)

-- d_a (d_a X) fuses to the compact second difference d2_a (X): repeated
-- derivatives pair up as staggered half-cell differences (forward then
-- backward), which is the d2_ stencil -- not the double-width central
-- composition -- so writing d twice generates byte-identical code.
fuseDD :: String -> String
fuseDD = untok . go . tokenize
  where
    go (TId d1 False : ts)
      | Just ax <- stripPrefix "d_" d1
      , (_, TC '(' : ts1) <- span isSpTok ts
      , (_, TId d2 False : ts2) <- span isSpTok ts1
      , stripPrefix "d_" d2 == Just ax
      , Just (inner, rest) <- closeParenT 1 ts2 []
      = TId ("d2_" ++ ax) False : TC '(' : go inner ++ (TC ')' : go rest)
    go (t : ts) = t : go ts
    go [] = []

-- delta (d u) on a scalar field lowers to minus the Laplacian: the
-- codifferential of the exterior derivative is -lap (flat) or -lb
-- (with a declared metric), so `u' = u - dt * delta (d u)` is the heat
-- equation written with the basic operators only.
lowerDeltaD :: Model -> String -> String
lowerDeltaD m = untok . go . tokenize
  where
    lapNm = if metricOn m then "lb" else "lap"
    go (TId "delta" False : ts)
      | (_, TC '(' : ts1) <- span isSpTok ts
      , (_, TId "d" False : ts2) <- span isSpTok ts1
      , Just (inner, rest) <- closeParenT 1 ts2 []
      = case bareIdent inner of
          Just (nm, pr) | kindOf m nm == Just Scalar ->
            tokenize ("((0 - 1) * " ++ lapNm ++ " " ++ nm ++ (if pr then "'" else "") ++ ")")
              ++ go rest
          -- compound operand: flat geometry only (the metric flux
          -- machinery is anchored to a named field)
          _ | not (metricOn m) ->
            tokenize ("((0 - 1) * lap (" ++ untok inner ++ "))") ++ go rest
          _ -> TId "delta" False : go ts
    go (t : ts) = t : go ts
    go [] = []
    bareIdent ts = case filter (not . isSpTok) ts of
      [TId nm pr] -> Just (nm, pr)
      [TC '(', TId nm pr, TC ')'] -> Just (nm, pr)
      _ -> Nothing

rewrite :: Model -> [String] -> Maybe String -> String -> IO String
rewrite m lets mk expr = fmap concat (mapM render (attach elems))
  where
    elems = lbPass (opPass m lets (tokenize (stepPre m expr)))
    lbPass [] = []
    lbPass (EId "lb" False : rest0) =
      case dropWhile isSp rest0 of
        (EId nm False : rest) | kindOf m nm == Just Scalar ->
          ERaw lbExpansion : lbPass rest
        _ -> EId "lb" False : lbPass rest0
      where isSp (EC c) = isSpace c
            isSp _ = False
    lbPass (e : rest) = e : lbPass rest
    forms = [n | (n, Form _) <- mFlds m]
    vecs = [n | (n, Vector False) <- mFlds m]
    -- pair each element with the next character (to skip function calls)
    attach es = zip es (map nextC (drop 1 (map Just es) ++ [Nothing]))
    nextC (Just (EC c)) = Just c
    nextC _ = Nothing
    render (EId nm pr, nxt) =
      case mk of
        Just k | (nm `elem` forms || nm `elem` vecs || nm `elem` lets)
                 && nxt /= Just '(' ->
          return (nm ++ (if pr then "'" else "") ++ "_" ++ k)
        _ -> return (nm ++ (if pr then "'" else ""))
    render (EC c, _) = return [c]
    render (ERaw t, _) = return t
    render (EMarkV t, _) =
      case mk of
        Just k -> return ("(" ++ t ++ ")_" ++ k)
        Nothing -> return ("(" ++ t ++ ")")
    render (EMarkL t, _) =
      case mk of
        Just "i" -> fatal ("forms cannot appear in an unindexed vector equation: " ++ expr)
        Just k -> return ("nth " ++ k ++ " (" ++ t ++ ")")
        Nothing -> return ("(" ++ t ++ ")")

-- ---------------------------------------------------------------- emitter

escQ :: String -> String
escQ = concatMap (\c -> if c == '"' then "\\\"" else [c])

escH :: String -> String
escH = concatMap esc
  where
    esc '\\' = "\\\\"
    esc '"' = "\\\""
    esc c = [c]

emit :: Model -> IO String
emit m = do
  if length (mAxes m) /= mDim m
    then fatal ("axes count (" ++ show (length (mAxes m))
                ++ ") does not match dimension (" ++ show (mDim m) ++ ")")
    else return ()
  let lets = [sNm st | st <- mSteps m, sk st == KLet]
      prims = primedRefs m
  if mMetric m /= Nothing && mEmbed m /= Nothing
    then fatal "declare either 'metric scale' or 'embedding', not both"
    else return ()
  mtx <- case (lbTarget m, mMetric m, mEmbed m) of
    (Just _, Nothing, Nothing) ->
      fatal "lb needs a 'metric scale [...]' or 'embedding [...]' declaration"
    (Just u, Just hs, _) -> return (Just (u, map (renameAxes m) hs))
    (Just u, Nothing, Just _) -> return (Just (u, ["feH1", "feH2", "feH3"]))
    (Nothing, _, _) -> return Nothing
  let embDefs = case mEmbed m of
        Nothing -> []
        Just es ->
          [ "def feX : [MathValue] := [" ++ intercalate ", " (map (renameAxes m) es) ++ "]"
          , "def feGd (a: Integer) : MathValue := sum (map (\\e -> (\8706/\8706 e (nth a [x, y, z])) ^ 2) feX)"
          , "def feGo (a: Integer) (b: Integer) : MathValue := sum (map (\\e -> \8706/\8706 e (nth a [x, y, z]) * \8706/\8706 e (nth b [x, y, z])) feX)"
          , "def feH1 := unquoteAll (expandAll (sqrt (feGd 1)))"
          , "def feH2 := unquoteAll (expandAll (sqrt (feGd 2)))"
          , "def feH3 := unquoteAll (expandAll (sqrt (feGd 3)))"
          ]
      orthoGate = case mEmbed m of
        Nothing -> []
        Just _ -> [("feGo 1 2 = 0 && feGo 1 3 = 0 && feGo 2 3 = 0",
                    "# ERROR: the embedding is not orthogonal (g_12, g_13, g_23 must vanish symbolically); general metrics are not supported yet")]
  body <- mapM (stepDefs lets) (mSteps m)
  items <- mapM (stepItem lets) (mSteps m)
  inits <- mapM (initLine lets) (mInits m)
  let sqgOf [h1, h2, h3] = "(" ++ h1 ++ ") * (" ++ h2 ++ ") * (" ++ h3 ++ ")"
      sqgOf _ = ""
      mtDecls = case mtx of
        Nothing -> []
        Just _ -> [ "def " ++ n ++ " := function (x, y, z)"
                  | n <- ["ca", "cb", "cc", "sg", "f1", "f2", "f3"] ]
      mtInits = case mtx of
        Nothing -> []
        Just (_, hs) ->
          [ "fmrInit \"" ++ n ++ "\" (substitute [(" ++ ax ++ ", " ++ ax ++ " + h"
            ++ ax ++ " / 2)] (" ++ sqgOf hs ++ " / ((" ++ h ++ ") ^ 2)))"
          | (n, ax, h) <- zip3 ["ca", "cb", "cc"] ["x", "y", "z"] hs ]
          ++ [ "fmrInit \"sg\" (" ++ sqgOf hs ++ ")" ]
      mtFlds = case mtx of
        Nothing -> []
        Just _ -> [("ca", Scalar), ("cb", Scalar), ("cc", Scalar), ("sg", Scalar)]
      mtFlux = case mtx of
        Nothing -> []
        Just (u, _) ->
          [ "[fmrEq \"f1\" (ca * dYee 1 [1 / 2, 0, 0] (" ++ u ++ ", [0, 0, 0]))]"
          , "[fmrEq \"f2\" (cb * dYee 2 [0, 1 / 2, 0] (" ++ u ++ ", [0, 0, 0]))]"
          , "[fmrEq \"f3\" (cc * dYee 3 [0, 0, 1 / 2] (" ++ u ++ ", [0, 0, 0]))]"
          ]
      mtPass = case mtx of
        Nothing -> []
        Just _ -> [ "scalarEq \"" ++ n ++ "\" (" ++ n ++ ")"
                  | n <- ["ca", "cb", "cc", "sg"] ]
      stepItems = mtFlux ++ [it | Just it <- items] ++ mtPass
      header =
        [ "--"
        , "-- GENERATED by fec (the Formurae compiler) from " ++ mName m
            ++ ".fe -- edit the .fe, not this file"
        , "--"
        , "" ] ++
        (if null (mParams m) then []
         else [ "declare symbol " ++ intercalate ", " (map fst (mParams m)), "" ])
      fieldDecls = concatMap fdecl (mFlds m)
      primDecls = concatMap pdecl prims
      localDecls = [ "def " ++ sNm st ++ " := function (x, y, z)"
                   | st <- mSteps m, sk st == KLocal ] ++ embDefs ++ mtDecls
      ddDef = case mDd m of
        Nothing -> []
        Just g -> ["def feDD := nth 1 (formComps (dForm (dForm "
                   ++ dropWhileEnd (== '\'') g ++ "fN)))"]
      feParams = "def feParams := ["
                 ++ intercalate ", " [ "(\"" ++ n ++ "\", \"" ++ v ++ "\")"
                                     | (n, v) <- mParams m ] ++ "]"
      explicitHelps = mHelp m ++ (case mEmbed m of
                              Just _ -> ["extern function :: sqrt"]
                              Nothing -> [])
      helps = autoScalarExterns m explicitHelps ++ explicitHelps
      feHelpers
        | null helps = ["def feHelpers : [String] := []"]
        | otherwise = "def feHelpers :="
            : [ (if i == (0 :: Int) then "  [ " else "  , ") ++ "\"" ++ escH h ++ "\""
              | (i, h) <- zip [0 ..] helps ] ++ ["  ]"]
      kindnum Scalar = "0"
      kindnum SymM = "2"
      kindnum _ = "1"
      feFlds = "def feFlds : [(String, Integer)] := ["
               ++ intercalate ", " [ "(\"" ++ n ++ "\", " ++ kindnum k ++ ")"
                                   | (n, k) <- mFlds m ++ mtFlds ] ++ "]"
      feInits = "def feInits :="
        : [ (if i == (0 :: Int) then "  [ " else "  , ") ++ ln
          | (i, ln) <- zip [0 ..] (concat inits ++ mtInits) ] ++ ["  ]"]
      feSteps = "def feSteps := " ++ intercalate " ++ " stepItems
      -- user axis names live only in the .fe (they are renamed to the
      -- internal x,y,z); the generated program stays on x,y,z so that
      -- Formura's derived names (dx, to_pos_x, ...) match the printer,
      -- the yaml, and the drivers
      emitter = "emitModelOn " ++ show (mDim m) ++ " [\"x\", \"y\", \"z\"]"
      gates = orthoGate ++ (case mDd m of
                Just _ -> [("feDD = 0",
                            "# ERROR: d . d /= 0 on this grid -- refusing to generate")]
                Nothing -> [])
      emitCall = "print (" ++ emitter ++ " feParams feHelpers feFlds feInits feSteps)"
      nest [] = emitCall
      nest ((c, msg):gs) =
        "if " ++ c ++ " then (" ++ nest gs ++ ") else print \"" ++ escH msg ++ "\""
      mainDef
        | null gates = [ "def main (args: [String]) : IO () := " ++ emitCall ]
        | otherwise = [ "def main (args: [String]) : IO () :=", "  " ++ nest gates ]
  return (unlines (header ++ fieldDecls ++ primDecls ++ localDecls ++ [""]
                   ++ concat body ++ ddDef ++ [""]
                   ++ [feParams] ++ feHelpers ++ [feFlds] ++ feInits
                   ++ [feSteps] ++ [""] ++ mainDef))
  where
    fdecl (nm, Scalar) = ["def " ++ nm ++ " := function (x, y, z)"]
    fdecl (nm, Vector _) =
      ["def " ++ nm ++ "_i := generateTensor (\\[i] -> function (x, y, z)) [3]"]
    fdecl (nm, SymM) =
      ["def " ++ nm ++ "_i_j := generateTensor (\\[i, j] -> function (x, y, z)) [3, 3]"]
    fdecl (nm, Form k) =
      [ "def " ++ nm ++ "_i := generateTensor (\\[i] -> function (x, y, z)) [3]"
      , "def " ++ nm ++ "f : (Integer, Integer, [MathValue]) := (0, " ++ show k
        ++ ", [" ++ nm ++ "_1, " ++ nm ++ "_2, " ++ nm ++ "_3])" ]
    pdecl nm = case kindOf m nm of
      Just Scalar -> ["def " ++ nm ++ "' := function (x, y, z)"]
      Just (Vector _) ->
        ["def " ++ nm ++ "'_i := generateTensor (\\[i] -> function (x, y, z)) [3]"]
      Just SymM ->
        ["def " ++ nm ++ "'_i_j := generateTensor (\\[i, j] -> function (x, y, z)) [3, 3]"]
      Just (Form k) ->
        [ "def " ++ nm ++ "'_i := generateTensor (\\[i] -> function (x, y, z)) [3]"
        , "def " ++ nm ++ "fN : (Integer, Integer, [MathValue]) := (0, " ++ show k
          ++ ", [" ++ nm ++ "'_1, " ++ nm ++ "'_2, " ++ nm ++ "'_3])" ]
      Nothing -> []
    stepDefs lets st = case sk st of
      KLet | sIdx st == ["i"] -> do
               e <- rewrite m lets Nothing (sEx st)
               return ["def " ++ sNm st ++ "_i := withSymbols [i] " ++ e]
           | otherwise -> do
               e <- rewrite m lets Nothing (sEx st)
               return ["def " ++ sNm st ++ " := " ++ e]
      KEq
        | isIndexKind (kindOf m (sNm st)) -> indexDefs m st
        | sIdx st == ["i"] -> do
            e <- rewrite m lets Nothing (sEx st)
            return ["def feq" ++ sNm st ++ "_i := withSymbols [i] " ++ e]
        | kindOf m (sNm st) == Just (Vector False) && null (sIdx st) -> do
            e <- rewrite m lets (Just "i") (sEx st)
            return ["def feq" ++ sNm st ++ "_i := withSymbols [i] " ++ e]
      _ -> return []
    stepItem lets st = case sk st of
      KLet -> return Nothing
      KLocal -> do
        e <- rewrite m lets Nothing (sEx st)
        return (Just ("[fmrEq \"" ++ sNm st ++ "\" (" ++ e ++ ")]"))
      KEq
        | Just (Vector True) <- kindOf m (sNm st) ->
            let nm = sNm st
            in return (Just ("vecEqs \"" ++ nm ++ "\" feq" ++ nm ++ "1 feq"
                             ++ nm ++ "2 feq" ++ nm ++ "3"))
        | Just SymM <- kindOf m (sNm st) ->
            let nm = sNm st
            in return (Just ("symEqs \"" ++ nm ++ "\" "
                             ++ unwords ["feq" ++ nm ++ show a ++ show b
                                        | (a, b) <- [(1,1),(2,2),(3,3),(1,2),(1,3),(2,3)] :: [(Int,Int)]]))
        | not (null (sIdx st)) || kindOf m (sNm st) == Just (Vector False) ->
            let nm = sNm st
            in return (Just ("vecEqs \"" ++ nm ++ "\" feq" ++ nm ++ "_1 feq"
                             ++ nm ++ "_2 feq" ++ nm ++ "_3"))
        | Just (Form _) <- kindOf m (sNm st) -> do
            cs <- mapM (\k -> rewrite m lets (Just (show (k :: Int))) (sEx st)) [1, 2, 3]
            return (Just ("vecEqs \"" ++ sNm st ++ "\" "
                          ++ unwords ["(" ++ c ++ ")" | c <- cs]))
        | otherwise -> do
            e <- rewrite m lets Nothing (sEx st)
            return (Just ("scalarEq \"" ++ sNm st ++ "\" (" ++ e ++ ")"))
    initLine lets it = case it of
      IRaw nm rhs -> return ["\"  " ++ nm ++ "[i,j,k] = " ++ escQ rhs ++ "\""]
      IVec nm els -> return [ "\"  " ++ nm ++ suf ++ "[i,j,k] = " ++ escQ el ++ "\""
                            | (suf, el) <- zip ["x", "y", "z"] els ]
      ISym nm els -> return [ "\"  " ++ nm ++ suf ++ "[i,j,k] = " ++ escQ el ++ "\""
                            | (suf, el) <- zip ["xx", "yy", "zz", "xy", "xz", "yz"] els ]
      ICas nm ex -> do
        e <- rewrite m lets Nothing ex
        return ["fmrInit \"" ++ nm ++ "\" (" ++ e ++ ")"]

-- Unicode input: Greek letters transliterate to their ASCII names.  A
-- partial-derivative sign followed immediately by an identifier is the
-- coordinate/indexed derivative operator (so `∂x` and `∂_x` both become
-- d_x, and `∂x (∂x u)` fuses to the compact second difference).  A bare
-- partial sign still becomes d.  The small delta becomes the
-- codifferential, and the minus sign becomes '-'.  The capital delta
-- (Laplacian) is model-dependent and resolved in mathOps instead.
transliterate :: String -> String
transliterate = go
  where
    go [] = []
    go ('\8706':'_':cs) = "d_" ++ go cs
    go ('\8706':cs@(c:_))
      | isAlpha c =
          let (nm, rest) = span isW cs
          in "d_" ++ concatMap tr nm ++ go rest
    go ('\8706':cs) = "d" ++ go cs
    go (c:cs) = tr c ++ go cs

    tr '\952' = "theta"    -- θ
    tr '\966' = "phi"      -- φ
    tr '\961' = "rho"      -- ρ
    tr '\964' = "tau"      -- τ
    tr '\954' = "kappa"    -- κ
    tr '\955' = "lambda"   -- λ
    tr '\956' = "mu"       -- μ
    tr '\957' = "nu"       -- ν
    tr '\949' = "epsilon"  -- ε
    tr '\963' = "sigma"    -- σ
    tr '\968' = "psi"      -- ψ
    tr '\969' = "omega"    -- ω
    tr '\945' = "alpha"    -- α
    tr '\946' = "beta"     -- β
    tr '\947' = "gamma"    -- γ
    tr '\951' = "eta"      -- η
    tr '\958' = "xi"       -- ξ
    tr '\950' = "zeta"     -- ζ
    tr '\967' = "chi"      -- χ
    tr '\960' = "pi"       -- π
    tr '\948' = "delta"    -- δ
    tr '\8722' = "-"       -- − (minus sign)
    tr c = [c]

-- nabla combinations, resolved before parsing: ∇^2 (or ∇²) is the
-- Laplacian (the capital delta, so lap or lb by geometry), ∇× is curl,
-- ∇· (or ∇.) is divergence.  A space after ∇ is allowed.  A bare ∇
-- passes through (and fails downstream) -- gradients of scalars are
-- written d u (forms) instead.
nablaPass :: String -> String
nablaPass = go
  where
    go [] = []
    go ('\8711':cs) =
      case dropWhile (== ' ') cs of
        ('^':'2':r)  -> '\916' : go r
        ('\178':r)   -> '\916' : go r
        ('\215':r)   -> " curl " ++ go r
        ('\183':r)   -> " divg " ++ go r
        ('.':r)      -> " divg " ++ go r
        _            -> '\8711' : go cs
    go (c:cs) = c : go cs

main :: IO ()
main = do
  args <- getArgs
  case args of
    [path] -> do
      txt <- fmap (nablaPass . transliterate) (readFile path)
      let name = takeWhile (/= '.') (reverse (takeWhile (/= '/') (reverse path)))
      m <- parseFe name txt
      out <- emit m
      putStr out
    _ -> fatal "usage: fec model.fe > model.egi"
