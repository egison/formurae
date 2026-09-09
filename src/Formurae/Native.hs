-- Native schedules use the same checked and discretized FProgram as Formura.
-- No model equations or operator names are recognized by this backend.
module Formurae.Native
  ( NativeSource(..), parseNativeSource, stageSources, renderNative ) where

import Control.Monad (unless)
import Data.Char (isAlpha, isAlphaNum, isDigit, isSpace)
import Data.List (intercalate, isPrefixOf, nub, stripPrefix)
import Data.Ratio (numerator, denominator)
import Text.ParserCombinators.ReadP
import Formurae.Common (strip, stripEgisonLineComments)
import Formurae.FEIR.Syntax (CompareOp(..), NamedConstant(..))
import Formurae.Post.FMR

-- Line numbers are retained when selecting a stage for ordinary normalization.
data NativeSource = NativeSource
  { nativeCommon :: [(Int,String)]
  , nativeStages :: [(String,[(Int,String)])]
  , nativeRuntime :: [(String,[String])]
  } deriving Show

parseNativeSource :: String -> Either String NativeSource
parseNativeSource input = finish =<< foldLines (NativeSource [] [] []) "common" numbered
  where
    numbered = zip [1..] (lines (stripEgisonLineComments input))
    foldLines result _ [] = Right result
    foldLines result section ((n,line):rest)
      | Just name <- stripPrefix "stage " line, not (null name), last name == ':' =
          let label=init name in if identifier label && label `notElem` map fst (nativeStages result)
            then foldLines result{nativeStages=nativeStages result++[(label,[])]} ("stage "++label) rest
            else Left ("invalid or duplicate stage at line "++show n)
      | line `elem` ["runtime:","prepare:","advance:","observe:"] =
          let name=init line in if name `elem` map fst (nativeRuntime result)
            then Left ("duplicate runtime section: "++name)
            else foldLines result{nativeRuntime=nativeRuntime result++[(name,[])]} name rest
      | section == "common" = foldLines result{nativeCommon=nativeCommon result++[(n,line)]} section rest
      | Just name <- stripPrefix "stage " section =
          foldLines result{nativeStages=map (\(k,v)->(k,if k==name then v++[(n,line)] else v)) (nativeStages result)} section rest
      | null (strip line) = foldLines result section rest
      | not (any isSpace (take 1 line)) = Left ("runtime command must be indented at line "++show n)
      | otherwise = foldLines result{nativeRuntime=map (\(k,v)->(k,if k==section then v++[strip line] else v)) (nativeRuntime result)} section rest
    finish result = do
      unless (not (null (nativeStages result)) && all (not.null.snd) (nativeStages result)) (Left "a native program needs nonempty stages")
      unless (all (`elem` map fst (nativeRuntime result)) ["runtime","advance"]) (Left "missing runtime or advance section")
      Right result

identifier :: String -> Bool
identifier [] = False
identifier (c:cs) = (isAlpha c || c=='_') && all (\x->isAlphaNum x || x=='_') cs

stageSources :: NativeSource -> [(String,String)]
stageSources source = [(name,select body) | (name,body)<-nativeStages source]
  where
    common=nativeCommon source
    fields=[takeWhile (\c->isAlphaNum c || c=='_') word | (_,line)<-common,
              "field":word:_ <- [words line]]
    select body = unlines [maybe "" id (lookup n (common++[(header,"step:")]++body)) | n<-[1..maxLine]]
      ++ unlines ["  "++f++"' = "++f | f<-fields, f `notElem` updated body]
      where
        header=minimum (map fst body)-1
        maxLine=maximum (header:map fst body)
    updated body=[takeWhile (\c->isAlphaNum c || c=='_') lhs | (_,line)<-body,
                     let lhs=takeWhile (/='=') (strip line), '\'' `elem` lhs,
                     not ("let " `isPrefixOf` lhs || "local " `isPrefixOf` lhs)]

-- Raw parameter values and raw constant initializers use a small arithmetic
-- grammar, rather than being copied into executable C without validation.
rawExpr :: String -> Either String String
rawExpr input = case [x | (x,rest)<-readP_to_S (spaces *> expr <* spaces <* eof) input, null rest] of
  [] -> Left ("unsupported native scalar expression: "++input)
  xs -> Right (last xs)
  where
    spaces=skipSpaces
    tok s=spaces *> string s <* spaces
    expr=chainl1 term (((\a b->"("++a++"+"++b++")") <$ tok "+") +++ ((\a b->"("++a++"-"++b++")") <$ tok "-"))
    term=chainl1 unary (((\a b->"("++a++"*"++b++")") <$ (tok "*" <* notFollowStar)) +++ ((\a b->"("++a++"/"++b++")") <$ tok "/"))
    notFollowStar = do rest<-look; if "*" `isPrefixOf` rest then pfail else pure ()
    power=do a<-atom; (do _<-tok "**" +++ tok "^"; b<-unary; pure ("pow("++a++","++b++")")) +++ pure a
    unary=(tok "-" *> ((\a->"(-"++a++")") <$> unary)) +++ (tok "+" *> unary) +++ power
    atom=between (tok "(") (tok ")") expr
      +++ (do s<-spaces *> munch1 (\c->c `elem` "0123456789."); e<-option "" (do c<-satisfy (`elem` "eE"); sign<-option "" ((:[]) <$> satisfy (`elem` "+-")); ds<-munch1 (`elem` "0123456789"); pure(c:sign++ds)); spaces; pure (if all (`elem` "0123456789") s && null e then s++".0" else s++e))
      +++ (do n<-spaces *> munch1 (\c->isAlphaNum c || c=='_'); if not(identifier n) then pfail else pure (); spaces;
              (do args<-between (tok "(") (tok ")") (sepBy expr (tok ","));
                  if (n `elem` ["sin","cos","exp","sqrt","log","fabs"] && length args==1) || (n `elem` ["pow","fmin","fmax"] && length args==2) then pure(n++"("++intercalate "," args++")") else pfail)
                +++ pure (if n=="pi" then "N_PI" else n))

renderNative :: NativeSource -> [(String,FProgram)] -> Either String String
renderNative source programs = do
  first<-case programs of []->Left "no normalized stages"; (_,p):_->Right p
  let state=fProgramStateStorage first
      axes=fProgramAxes first
  unless (length axes==2 && all (\(_,p)->fProgramStateStorage p==state && fProgramAxes p==axes && fProgramParameters p==fProgramParameters first) programs)
    (Left "native schedules require two-dimensional stages with identical state declarations")
  unless (all (all (`elem` ["extern function :: "++n | n<-["sin","cos","tan","asin","acos","atan","atan2","sinh","cosh","tanh","exp","sqrt","log","fabs","pow","fmin","fmax"]]).fProgramHelpers.snd) programs) (Left "raw helper declarations are not supported by the native backend")
  params<-mapM (\(n,v)-> do e<-rawExpr v; pure ("const double "++n++"="++e++";")) (fProgramParameters first)
  let parameters=unlines (["const double d"++a++"=_formurae_s->spacing["++show k++"];" | (k,a)<-zip [0::Int ..] axes]++params)
      enum=unlines ["enum {"++intercalate "," (map ("N_"++) state)++", N_FIELDS};"]
      names="static const char *n_names[]={"++intercalate "," (map show state)++"};\n"
      arrays=[(n,"_formurae_s->field[N_"++n++"]")|n<-state]
  initial<-assignments True axes parameters arrays (fProgramInitializers first)
  stages<-mapM (\(name,p)->do body<-assignments False axes parameters arrays (fProgramStepAssignments p); pure ("static void stage_"++name++"(NState *_formurae_s){\n"++body++"}\n")) programs
  schedule<-mapM (\section->do body<-mapM (command state (map fst programs)) (maybe [] id (lookup section (nativeRuntime source))); pure ("static void model_"++section++"(NState *_formurae_s){\n"++unlines body++"}\n")) ["prepare","advance","observe"]
  settings<-renderSettings state (maybe [] id (lookup "runtime" (nativeRuntime source)))
  pure ("/* Generated from checked Formurae tensor definitions. */\n#include \"formurae_native.h\"\n"++enum++names
    ++"static void model_init(NState *_formurae_s){\n"++initial++"}\n"++concat stages++concat schedule++settings
    ++"#ifndef FORMURAE_NATIVE_NO_MAIN\nint main(int argc,char **argv){return n_main(argc,argv,&n_model);}\n#endif\n")
  where
    assignments initial axes parameters state assignments0 = do
      let assignments1=filter (not.identity) assignments0
          identity (FAssignment (StepUpdateTarget n) (FGridReference m ix))=n==m && all ((==0).gridIndexOffset) ix
          identity _=False
          target (InitialTarget n _)=n
          target (StepBindingTarget n)=n
          target (StepUpdateTarget n)=n++"'"
          temps=nub [target (fAssignmentTarget a)|a<-assignments1, not initial]
          pointers=state++[(n,"_formurae_tmp_"++safe n)|n<-temps]
          safe=concatMap (\c->if c=='\'' then "_next" else [c])
          tempDecl=unlines ["double *_formurae_tmp_"++safe n++"=n_scratch(_formurae_s,"++show k++");"|(k,n)<-zip [0::Int ..] temps]
      linesC<-mapM (\a->do
          e<-expression pointers (fAssignmentExpr a)
          dest<-maybe (Left ("unknown target "++target(fAssignmentTarget a))) Right (lookup (target(fAssignmentTarget a)) pointers)
          let coords=if initial then unlines ["double "++axis++"="++idx++"*d"++axis++";"|(axis,idx)<-zip axes ["i","j"]] else ""
          pure ("for(int i=0;i<_formurae_s->total;i++) for(int j=0;j<_formurae_s->ny;j++){size_t _formurae_p=(size_t)i*_formurae_s->ny+j;\n"++coords++dest++"[_formurae_p]="++e++";}\n")) assignments1
      let copies=["memcpy(_formurae_s->field[N_"++n++"],_formurae_tmp_"++safe(n++"'")++",_formurae_s->count*sizeof(double));"|FAssignment (StepUpdateTarget n) _<-assignments1]
      pure (parameters++tempDecl++concat linesC++unlines copies)
    expression pointers e=case e of
      FExact n d->Right ("("++show n++".0/"++show d++".0)")
      FNamedConstant Pi->Right "N_PI"
      FVariable n->Right (maybe n (++"[_formurae_p]") (lookup n pointers))
      FGridReference n ix->do
        a<-maybe (Left ("unknown field reference "++n)) Right (lookup n pointers)
        unless (length ix==2 && all ((==1).denominator.gridIndexOffset) ix) (Left "native C requires integral, collocated grid offsets")
        let offsets=[gridIndexBase v++"+("++show(numerator(gridIndexOffset v))++")"|v<-ix]
        Right ("n_at(_formurae_s,"++a++","++intercalate "," offsets++")")
      FAdd xs->joined "+" "0" xs
      FMul xs->joined "*" "1" xs
      FDiv a b->binary "/" a b
      FPow a b->call "pow" [a,b]
      FCall n xs->call n xs
      FCompare op a b->binary (case op of CompareEq->"=="; CompareNe->"!="; CompareLt->"<"; CompareLe->"<="; CompareGt->">"; CompareGe->">=") a b
      FSelect c a b->do x<-rec c;y<-rec a;z<-rec b;Right("("++x++"?"++y++":"++z++")")
      FRawExpr raw->rawExpr raw
      where
        rec=expression pointers
        joined op zero xs=do ys<-mapM rec xs;Right(if null ys then zero else "("++intercalate op ys++")")
        binary op a b=joined op "" [a,b]
        call n xs=do ys<-mapM rec xs;Right(n++"("++intercalate "," ys++")")

resolve :: [String] -> String -> Either String [String]
resolve fields name =
  let converted=indices name
      found=if converted `elem` fields then [converted] else
        [n|n<-fields,Just suffix<-[stripPrefix converted n],componentSuffix suffix]
  in if null found then Left("unknown runtime field: "++name) else Right found
  where
    indices []=[]
    indices ('~':xs)="_up"++indices xs
    indices ('_':c:xs)|c `elem` ['1'..'9']="_down"++(c:indices xs)
    indices(c:xs)=c:indices xs
    componentSuffix suffix=any match ["_up","_down","_"]
      where
        match prefix=case stripPrefix prefix suffix of
          Just rest -> let (digits,tail0)=span isDigit rest
            in not(null digits) && (null tail0 || componentSuffix tail0)
          Nothing -> False
scalar :: [String] -> String -> Either String String
scalar fields name=do names<-resolve fields name;case names of [n]->Right("_formurae_s->field[N_"++n++"]");_->Left("expected a scalar component: "++name)
command :: [String] -> [String] -> String -> Either String String
command fields stages line = case words line of
  ["require",op,field,relation,bound,margin] | op `elem` ["min","max","maxabs"] && relation `elem` ["<",">"] ->do
    a<-resolve fields field
    f<-case a of [n]->Right n;_->Left "require needs one component"
    b<-case reads bound ::[(Double,String)] of [(v,"")]|not(isNaN v||isInfinite v)->Right(show v);_->Left "invalid bound"
    m<-case reads margin ::[(Int,String)] of [(v,"")]|v>=0->Right(show v);_->Left "invalid margin"
    Right("n_require(_formurae_s,"++show field++",N_"++f++",N_"++op++","++m++","++b++","++(if relation=="<" then "1" else "0")++");")
  ["call",name] | name `elem` stages -> Right ("stage_"++name++"(_formurae_s);")
  ["copy",from,to]->do a<-resolve fields from;b<-resolve fields to;unless(length a==length b)(Left "copy shape mismatch");Right(unlines["memcpy(_formurae_s->field[N_"++y++"],_formurae_s->field[N_"++x++"],_formurae_s->count*sizeof(double));"|(x,y)<-zip a b])
  ["mean",from,to]->do a<-scalar fields from;b<-scalar fields to;Right("n_mean(_formurae_s,"++a++","++b++");")
  ["ghost",kind,field,scale] | kind `elem` ["reflect","extend","odd"] ->do
    a<-resolve fields field;b<-resolve fields scale;unless(length a==length b)(Left "ghost scale shape mismatch")
    Right(unlines["n_ghost(_formurae_s,_formurae_s->field[N_"++x++"],_formurae_s->field[N_"++y++"],"++(case kind of "reflect"->"1";"extend"->"0";_->"-1")++");"|(x,y)<-zip a b])
  ["poisson",out,rhs,lower,diagonal,upper,angular]->do args<-mapM (scalar fields) [out,rhs,lower,diagonal,upper,angular];Right("n_poisson(_formurae_s,"++intercalate "," args++");")
  _ -> Left ("invalid runtime command: "++line)

renderSettings :: [String] -> [String] -> Either String String
renderSettings fields rows = do
  let settings=map words rows
      one key=case [xs|k:xs<-settings,k==key] of [xs]->Right xs;_->Left("expected one runtime "++key)
      number input=case reads input :: [(Double,String)] of [(x,"")]|not(isNaN x||isInfinite x)->Right(show x);_->Left("invalid number: "++input)
      integer input=case reads input :: [(Int,String)] of [(x,"")]|x>0->Right(show x);_->Left("expected positive integer: "++input)
      scalarId name=do ns<-resolve fields name;case ns of [n]->Right("N_"++n);_->Left("expected scalar "++name)
  grid<-one "grid" >>= mapM integer
  extent<-one "extent" >>= mapM number
  halo<-one "halo" >>= mapM integer
  time<-one "time" >>= mapM scalarId
  dt<-one "timestep" >>= mapM scalarId
  steps<-one "steps" >>= mapM integer
  every<-one "every" >>= mapM integer
  unless(map length [grid,extent,halo,time,dt,steps,every]==[2,2,1,1,1,1,1])(Left "invalid native runtime dimensions")
  outputs<-one "output" >>= fmap concat . mapM (resolve fields)
  monitors<-mapM (\xs->case xs of
      ["monitor",name,op,field,margin]->do
        f<-scalarId field
        m<-case reads margin ::[(Int,String)] of
          [(x,"")]|x>=0->Right(show x)
          _->Left "invalid monitor margin"
        unless(identifier name && op `elem` ["min","max","maxabs","sum","first"])(Left "invalid monitor")
        Right("{"++show name++","++f++",N_"++op++","++m++"}")
      _->Left "invalid monitor declaration") [xs|xs@(key:_)<-settings,key=="monitor"]
  unless(all (\key->key `elem` ["grid","extent","halo","time","timestep","steps","every","output","monitor"]) [key|key:_<-settings])(Left "unknown runtime setting")
  pure (unlines ["static const int n_outputs[]={"++intercalate "," (map("N_"++)outputs)++"};",
    "static const NMonitor n_monitors[]={"++intercalate "," monitors++"};",
    "static const NModel n_model={N_FIELDS,n_names,"++intercalate "," (grid++extent++halo++time++dt++steps++every)++",",
    "n_outputs,"++show(length outputs)++",n_monitors,"++show(length monitors)++",model_init,model_prepare,model_advance,model_observe};"])
