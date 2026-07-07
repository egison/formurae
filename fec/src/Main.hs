-- fec -- the .fe compiler.
--
-- Translates the surface DSL (.fe) into the embedded DSL form: an
-- Egison program over lib/fmrgen.egi + lib/fmrdsl.egi.  All semantics
-- (tensor index notation, differential forms, CAS expansion, the .fmr
-- printer) live on the Egison side; this is a thin, line-oriented
-- translator.  Base library only; build and run with
--
--   cabal run -v0 fec -- model.fe > model.egi
--   egison -l lib/fmrgen.egi -l lib/fmrdsl.egi model.egi > model.fmr
--
-- .fe grammar (v1):
--   -- comment                      (kept out of the output)
--   dimension 3                     (default 3; v1 supports 3 only)
--   axes x, y, z                    (default x,y,z; the names are mapped to
--                                    the internal coordinates x,y,z, so
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
--   param NAME = RAW                Formura parameter (double :: NAME = RAW)
--   extern NAME                     extern function :: NAME
--   raw LINE                        verbatim Formura helper line
--   field NAME : scalar             one grid field
--   field NAME : vector             3 components (NAMEx,NAMEy,NAMEz)
--   field NAME : 1-form | 2-form    3 components placed by form degree (DEC)
--   init:
--     COMP = RAW                    raw Formura initializer (component)
--     NAME = [| e1, e2, e3 |]       vector/form initializer (component-wise raw)
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

fatal :: String -> IO a
fatal msg = hPutStrLn stderr ("fec: error: " ++ msg) >> exitFailure

-- ---------------------------------------------------------------- model

data Kind = Scalar | Vector | Form Int deriving (Eq, Show)

data Init = IRaw String String | IVec String [String] | ICas String String

data SK = KLet | KLocal | KEq deriving Eq

data Step = Step { sk :: SK, sNm :: String, sIx :: Bool, sEx :: String }

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
  }

kindOf :: Model -> String -> Maybe Kind
kindOf m nm = lookup nm (mFlds m)

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

-- NAME'(_i)? = EXPR
primeEqForm :: String -> Maybe (String, Bool, String)
primeEqForm s = do
  (nm, r1) <- ident s
  r2 <- stripPrefix "'" r1
  let (ix, r3) = case stripPrefix "_i" r2 of
                   Just r -> (True, r)
                   Nothing -> (False, r2)
  r4 <- stripPrefix "=" (dropWhile isSpace r3)
  let ex = strip r4
  if null ex then Nothing else Just (nm, ix, ex)
  where
    ident (c:cs) | isAlpha c = let (a, b) = span isAlphaNum cs in Just (c : a, b)
    ident _ = Nothing

-- ---------------------------------------------------------------- parser

data Section = STop | SInit | SStep

parseFe :: String -> String -> IO Model
parseFe name txt = go STop (Model name 3 ["x", "y", "z"] [] [] [] [] [] Nothing Nothing Nothing)
                      (zip [1 :: Int ..] (lines txt))
  where
    go _ m [] = return m { mParams = reverse (mParams m), mHelp = reverse (mHelp m)
                         , mFlds = reverse (mFlds m), mInits = reverse (mInits m)
                         , mSteps = reverse (mSteps m) }
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
              SInit -> ini ln s m >>= \m' -> go SInit m' rest
              SStep -> stp ln s m >>= \m' -> go SStep m' rest

    top ln s m
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
                     "vector" -> add nm Vector
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
          case vecLit rhs of
            Just elems -> do
              let ok = case kindOf m nm of
                         Just Vector -> True
                         Just (Form _) -> True
                         _ -> False
              if not ok
                then fatal ("[| ... |] initializer needs a vector/form field: "
                            ++ nm ++ " (line " ++ show ln ++ ")")
                else if length elems /= 3
                  then fatal ("[| ... |] initializer needs 3 components (line "
                              ++ show ln ++ ")")
                  else return m { mInits = IVec nm elems : mInits m }
            Nothing -> return m { mInits = IRaw nm rhs : mInits m }
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

    stp ln s m
      | Just (nm, ix, ex) <- eqForm "let" s =
          return m { mSteps = Step KLet nm ix ex : mSteps m }
      | Just (nm, _, ex) <- eqForm "local" s =
          return m { mSteps = Step KLocal nm False ex : mSteps m }
      | Just (nm, ix, ex) <- primeEqForm s =
          return m { mSteps = Step KEq nm ix ex : mSteps m }
      | otherwise = fatal ("bad step eq: " ++ s ++ " (line " ++ show ln ++ ")")

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

-- the field to which lb is applied, if any
lbTarget :: Model -> Maybe String
lbTarget m = case concatMap scan (mSteps m) of
               (nm:_) -> Just nm
               [] -> Nothing
  where
    scan st = go (tokenize (sEx st))
    go (TId "lb" False : ts) =
      case dropWhile isSp ts of
        (TId nm False : rest) | kindOf m nm == Just Scalar -> nm : go rest
        _ -> go ts
    go (_ : ts) = go ts
    go [] = []
    isSp (TC c) = isSpace c
    isSp _ = False

-- names X whose updated value X' is referenced in some step RHS
primedRefs :: Model -> [String]
primedRefs m = sort (nub [nm | st <- mSteps m, TId nm True <- tokenize (sEx st)
                             , kindOf m nm /= Nothing])

opPass :: Model -> [String] -> [Tok] -> [Elem]
opPass m lets = go
  where
    forms = [(n, d) | (n, Form d) <- mFlds m]
    vecs = [n | (n, Vector) <- mFlds m]
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

rewrite :: Model -> [String] -> Maybe String -> String -> IO String
rewrite m lets mk expr = fmap concat (mapM render (attach elems))
  where
    elems = lbPass (opPass m lets (tokenize (renameAxes m expr)))
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
    vecs = [n | (n, Vector) <- mFlds m]
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
          , "def feH1 := expandAll (sqrt (feGd 1))"
          , "def feH2 := expandAll (sqrt (feGd 2))"
          , "def feH3 := expandAll (sqrt (feGd 3))"
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
        , "-- GENERATED by fec from " ++ mName m ++ ".fe -- edit the .fe, not this file"
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
      helps = mHelp m ++ (case mEmbed m of
                              Just _ -> ["extern function :: sqrt"]
                              Nothing -> [])
      feHelpers
        | null helps = ["def feHelpers : [String] := []"]
        | otherwise = "def feHelpers :="
            : [ (if i == (0 :: Int) then "  [ " else "  , ") ++ "\"" ++ escH h ++ "\""
              | (i, h) <- zip [0 ..] helps ] ++ ["  ]"]
      kindnum Scalar = "0"
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
    isCas (ICas _ _) = True
    isCas _ = False
    fdecl (nm, Scalar) = ["def " ++ nm ++ " := function (x, y, z)"]
    fdecl (nm, Vector) =
      ["def " ++ nm ++ "_i := generateTensor (\\[i] -> function (x, y, z)) [3]"]
    fdecl (nm, Form k) =
      [ "def " ++ nm ++ "_i := generateTensor (\\[i] -> function (x, y, z)) [3]"
      , "def " ++ nm ++ "f : (Integer, Integer, [MathValue]) := (0, " ++ show k
        ++ ", [" ++ nm ++ "_1, " ++ nm ++ "_2, " ++ nm ++ "_3])" ]
    pdecl nm = case kindOf m nm of
      Just Scalar -> ["def " ++ nm ++ "' := function (x, y, z)"]
      Just Vector ->
        ["def " ++ nm ++ "'_i := generateTensor (\\[i] -> function (x, y, z)) [3]"]
      Just (Form k) ->
        [ "def " ++ nm ++ "'_i := generateTensor (\\[i] -> function (x, y, z)) [3]"
        , "def " ++ nm ++ "fN : (Integer, Integer, [MathValue]) := (0, " ++ show k
          ++ ", [" ++ nm ++ "'_1, " ++ nm ++ "'_2, " ++ nm ++ "'_3])" ]
      Nothing -> []
    stepDefs lets st = case sk st of
      KLet | sIx st -> do
               e <- rewrite m lets Nothing (sEx st)
               return ["def " ++ sNm st ++ "_i := withSymbols [i] " ++ e]
           | otherwise -> do
               e <- rewrite m lets Nothing (sEx st)
               return ["def " ++ sNm st ++ " := " ++ e]
      KEq | sIx st -> do
              e <- rewrite m lets Nothing (sEx st)
              return ["def feq" ++ sNm st ++ "_i := withSymbols [i] " ++ e]
          | kindOf m (sNm st) == Just Vector -> do
              e <- rewrite m lets (Just "i") (sEx st)
              return ["def feq" ++ sNm st ++ "_i := withSymbols [i] " ++ e]
      _ -> return []
    stepItem lets st = case sk st of
      KLet -> return Nothing
      KLocal -> do
        e <- rewrite m lets Nothing (sEx st)
        return (Just ("[fmrEq \"" ++ sNm st ++ "\" (" ++ e ++ ")]"))
      KEq
        | sIx st || kindOf m (sNm st) == Just Vector ->
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
      ICas nm ex -> do
        e <- rewrite m lets Nothing ex
        return ["fmrInit \"" ++ nm ++ "\" (" ++ e ++ ")"]

main :: IO ()
main = do
  args <- getArgs
  case args of
    [path] -> do
      txt <- readFile path
      let name = takeWhile (/= '.') (reverse (takeWhile (/= '/') (reverse path)))
      m <- parseFe name txt
      out <- emit m
      putStr out
    _ -> fatal "usage: fec model.fe > model.egi"
