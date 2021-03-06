{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE QuasiQuotes #-}

module Verifier.SAW.Heapster.PermParser where

import Data.List
import Data.String
import Data.Maybe
import Data.Functor.Product
import Data.Functor.Constant
import Data.Functor.Compose
import Data.Type.Equality
import GHC.TypeLits
import Control.Monad.Identity
import Control.Monad.Reader
import Data.Binding.Hobbits

import Text.Parsec
import Text.Parsec.Error
-- import Text.ParserCombinators.Parsec

import Data.Parameterized.Context hiding ((:>), empty, take, zipWith, Empty)
import qualified Data.Parameterized.Context as Ctx
import Data.Parameterized.Some

import Lang.Crucible.Types
import Lang.Crucible.LLVM.MemModel
import Lang.Crucible.FunctionHandle
-- import What4.FunctionName

import Verifier.SAW.Heapster.CruUtil
import Verifier.SAW.Heapster.Permissions


-- FIXME: maybe some of these should use unsafeMbTypeRepr for efficiency?
$(mkNuMatching [t| SourcePos |])
$(mkNuMatching [t| Message |])
$(mkNuMatching [t| ParseError |])
$(mkNuMatching [t| forall s u. (NuMatching s, NuMatching u) => State s u |])
$(mkNuMatching [t| forall s u a. (NuMatching s, NuMatching u, NuMatching a) =>
                Reply s u a |])
$(mkNuMatching [t| forall a. NuMatching a => Consumed a |])
$(mkNuMatching [t| forall a. NuMatching a => Identity a |])
$(mkNuMatching [t| forall f g a. NuMatching (f (g a)) => Compose f g a |])

instance Closable ParseError where
  toClosed = unsafeClose

instance Liftable ParseError where
  mbLift = unClosed . mbLift . fmap toClosed

instance Closable SourcePos where
  toClosed = unsafeClose

instance Liftable SourcePos where
  mbLift = unClosed . mbLift . fmap toClosed


----------------------------------------------------------------------
-- * The Parsing Monad and Parsing Utilities
----------------------------------------------------------------------

-- FIXME HERE: replace all calls to show tp with our own type-printing function
-- that prints in the same format that we are parsing


-- | An element of some representation type functor @f a@ along with a
-- 'TypeRepr' for @a@
data Typed f a = Typed (TypeRepr a) (f a)

-- | Try to cast an existential 'Typed' to a particular type
castTypedMaybe :: TypeRepr a -> Some (Typed f) -> Maybe (f a)
castTypedMaybe tp (Some (Typed tp' f))
  | Just Refl <- testEquality tp tp' = Just f
castTypedMaybe _ _ = Nothing

-- | A expression variable of some existentially quantified type
type SomeName = Some (Typed Name)

-- | A parsing environment, which includes variables and function names
data ParserEnv = ParserEnv {
  parserEnvExprVars :: [(String, SomeName)],
  parserEnvPermEnv :: PermEnv
}

-- | Make a 'ParserEnv' with empty contexts and a given list of function names
mkParserEnv :: PermEnv -> ParserEnv
mkParserEnv env = ParserEnv [] env

$(mkNuMatching [t| forall f a. NuMatching (f a) => Typed f a |])
$(mkNuMatching [t| ParserEnv |])

instance NuMatchingAny1 f => NuMatchingAny1 (Typed f) where
  nuMatchingAny1Proof = nuMatchingProof

-- | Look up an expression variable by name in a 'ParserEnv'
lookupExprVar :: String -> ParserEnv -> Maybe SomeName
lookupExprVar str = lookup str . parserEnvExprVars

{-
instance BindState String where
  bindState = mbLift

instance BindState ParserEnv where
  bindState [nuP| ParserEnv evars env |] =
    ParserEnv
    (mapMaybe (\env_elem -> case env_elem of
                  [nuP| (str, Some (Typed tp mb_n)) |]
                    | Right n <- mbNameBoundP mb_n ->
                      Just (mbLift str, Some (Typed (mbLift tp) n))
                  _ -> Nothing)
     (mbList evars))
    (mbLift env)
-}

-- | The parsing monad is a 'Parsec' computation with a 'ParserEnv'
type PermParseM s = Parsec s ParserEnv

-- | Functors that support name-binding
--
-- FIXME: is this the right interface? Maybe should be related to 'MonadBind'?
{-
class (Functor f, NuMatchingAny1 f) => FunctorBind f where
  mbF :: NuMatching a => Mb ctx (f a) -> f (Mb ctx a)

instance FunctorBind Consumed where
  mbF [nuP| Consumed a |] = Consumed a
  mbF [nuP| Empty a |] = Empty a

instance (BindState s, BindState u) => FunctorBind (Reply s u) where
  mbF [nuP| Ok a s err |] = Ok a (bindState s) (mbLift err)
  mbF [nuP| Error err |] = Error (mbLift err)

instance FunctorBind Identity where
  mbF [nuP| Identity a |] = Identity a

instance (FunctorBind f, FunctorBind g) => FunctorBind (Compose f g) where
  mbF [nuP| Compose fga |] = Compose $ fmap mbF $ mbF fga
-}

{-
instance (BindState s, BindState u) => BindState (State s u) where
  bindState [nuP| State s pos u |] =
    State (bindState s) (mbLift pos) (bindState u)
-}

-- | Lift a 'ParserEnv' out of a binding except for its 'PermEnv', which should
-- be unchanged from the input
liftParserEnv :: PermEnv -> Mb ctx ParserEnv -> ParserEnv
liftParserEnv env [nuP| ParserEnv evars _ |] =
  ParserEnv
  (mapMaybe (\env_elem -> case env_elem of
                [nuP| (str, Some (Typed tp mb_n)) |]
                  | Right n <- mbNameBoundP mb_n ->
                    Just (mbLift str, Some (Typed (mbLift tp) n))
                _ -> Nothing)
   (mbList evars))
  env

-- | Lift a Parsec 'State' out of a binding except for its 'PermEnv', which
-- should be unchanged from the input
liftParsecState :: Liftable s => PermEnv -> Mb ctx (State s ParserEnv) ->
                   State s ParserEnv
liftParsecState env [nuP| State s pos u |] =
  State (mbLift s) (mbLift pos) (liftParserEnv env u)

instance Liftable s => MonadBind (ParsecT s ParserEnv Identity) where
  mbM mb_m = mkPT $ \s ->
    let env = parserEnvPermEnv $ stateUser s in
    case fmap (flip runParsecT s) mb_m of
      [nuP| Identity (Consumed (Identity (Ok a s' err))) |] ->
        Identity (Consumed (Identity (Ok a (liftParsecState env s')
                                      (mbLift err))))
      [nuP| Identity (Consumed (Identity (Error err))) |] ->
        Identity (Consumed (Identity (Error (mbLift err))))
      [nuP| Identity (Consumed (Identity (Ok a s' err))) |] ->
        Identity (Empty (Identity (Ok a (liftParsecState env s')
                                   (mbLift err))))
      [nuP| Identity (Consumed (Identity (Error err))) |] ->
        Identity (Empty (Identity (Error (mbLift err))))

-- | Run a parsing computation in a context extended with an expression variable
withExprVar :: String -> TypeRepr tp -> ExprVar tp ->
               PermParseM s a -> PermParseM s a
withExprVar str tp x m =
  do env <- getState
     putState (env { parserEnvExprVars =
                       (str, Some (Typed tp x)) : parserEnvExprVars env})
     ret <- m
     putState env
     return ret

-- | Run a parsing computation in a context extended with 0 or more expression
-- variables
withExprVars :: MapRList (Constant String) ctx -> CruCtx ctx ->
                MapRList Name ctx ->
                PermParseM s a -> PermParseM s a
withExprVars MNil CruCtxNil MNil m = m
withExprVars (xs :>: Constant x) (CruCtxCons ctx tp) (ns :>: n) m =
  withExprVars xs ctx ns $ withExprVar x tp n m

-- | Cast an existential 'Typed' to a particular type or raise an error
castTypedM :: Stream s Identity Char =>
              String -> TypeRepr a -> Some (Typed f) ->
              PermParseM s (f a)
castTypedM _ tp (Some (Typed tp' f))
  | Just Refl <- testEquality tp tp' = return f
castTypedM str tp (Some (Typed tp' _)) =
  unexpected (str ++ " of type " ++ show tp') <?>
  (str ++ " of type " ++ show tp)

-- | Parse and skip at least one space
spaces1 :: Stream s Identity Char => PermParseM s ()
spaces1 = space >> spaces

-- | Apply a parsing computation to parse inside parentheses
parseInParens :: Stream s Identity Char =>
                 PermParseM s a -> PermParseM s a
parseInParens m =
  do char '('
     ret <- m
     spaces >> char ')'
     return ret

-- | Apply a parsing computation to parse inside optional parentheses
parseInParensOpt :: Stream s Identity Char =>
                    PermParseM s a -> PermParseM s a
parseInParensOpt m = parseInParens m <|> m


----------------------------------------------------------------------
-- * Parsing Types
----------------------------------------------------------------------

-- | A 'NatRepr' for @1@
oneRepr :: NatRepr 1
oneRepr = knownRepr

-- | Parse a comma
comma :: Stream s Identity Char => PermParseM s ()
comma = char ',' >> return ()

-- | Parse an integer
integer :: Stream s Identity Char => PermParseM s Integer
integer = read <$> many1 digit

-- | Parse an integer to a 'NatRepr'
parseNatRepr :: Stream s Identity Char =>
                PermParseM s (Some (Product NatRepr (LeqProof 1)))
parseNatRepr =
  do i <- integer
     case someNat i of
       Just (Some w)
         | Left leq <- decideLeq oneRepr w -> return (Some (Pair w leq))
       Just _ -> unexpected "Zero bitvector width not allowed"
       Nothing -> error "parseNatRepr: unexpected negative bitvector width"

-- | Parse a Crucible type and build a @'KnownRepr' 'TypeRepr'@ instance for it
--
-- FIXME: we would not need to use a 'KnownReprObj' here if we changed
-- 'ValPerm_Exists' to take its type argument as a normal 'TypeRepr' instead of
-- as a 'WithKnownRepr' constraint
parseTypeKnown :: Stream s Identity Char =>
                  PermParseM s (Some (KnownReprObj TypeRepr))
parseTypeKnown =
  spaces >>
  (parseInParens parseTypeKnown <|>
   (try (string "unit") >> return (Some $ mkKnownReprObj UnitRepr)) <|>
   (try (string "nat") >> return (Some $ mkKnownReprObj NatRepr)) <|>
   (do try (string "bv" >> spaces1)
       w <- parseNatRepr
       case w of
         Some (Pair w LeqProof) ->
           withKnownNat w $ return (Some $ mkKnownReprObj $ BVRepr w)) <|>
   (do try (string "llvmptr" >> spaces1)
       w <- parseNatRepr
       case w of
         Some (Pair w LeqProof) ->
           withKnownNat w $
           return (Some $ mkKnownReprObj $ LLVMPointerRepr w)) <|>
   (do try (string "llvmframe" >> spaces1)
       w <- parseNatRepr
       case w of
         Some (Pair w LeqProof) ->
           withKnownNat w $
           return (Some $ mkKnownReprObj $ LLVMFrameRepr w)) <|>
   (do try (string "lifetime")
       return (Some $ mkKnownReprObj LifetimeRepr)) <|>
   (do try (string "rwmodality")
       return (Some $ mkKnownReprObj RWModalityRepr)) <|>
   (do try (string "permlist")
       return (Some $ mkKnownReprObj PermListRepr)) <|>
   (do try (string "struct")
       spaces
       some_fld_tps <- parseInParens parseStructFieldTypesKnown
       case some_fld_tps of
         Some fld_tps@KnownReprObj ->
           return $ Some $ mkKnownReprObj $
           StructRepr $ unKnownReprObj fld_tps) <|>
   (do try (string "perm")
       spaces
       known_tp <- parseInParens parseTypeKnown
       case known_tp of
         Some tp@KnownReprObj ->
           return $ Some $ mkKnownReprObj $ ValuePermRepr $ unKnownReprObj tp)
   <?> "type")

-- | Parse a comma-separated list of struct field types
parseStructFieldTypesKnown :: Stream s Identity Char =>
                              PermParseM s (Some (KnownReprObj
                                                  (Assignment TypeRepr)))
parseStructFieldTypesKnown =
  helper <$> reverse <$> sepBy parseTypeKnown (spaces >> char ',')
  where
    helper :: [Some (KnownReprObj TypeRepr)] ->
              Some (KnownReprObj (Assignment TypeRepr))
    helper [] = Some $ mkKnownReprObj Ctx.empty
    helper (Some tp@KnownReprObj : tps) =
      case helper tps of
        Some repr@KnownReprObj ->
          Some $ mkKnownReprObj $
          extend (unKnownReprObj repr) (unKnownReprObj tp)


-- | Parse a Crucible type as a 'TypeRepr'
parseType :: Stream s Identity Char => PermParseM s (Some TypeRepr)
parseType = mapSome unKnownReprObj <$> parseTypeKnown


----------------------------------------------------------------------
-- * Parsing Expressions
----------------------------------------------------------------------

-- | Parse a valid identifier as a 'String'
parseIdent :: Stream s Identity Char => PermParseM s String
parseIdent =
  (do spaces
      c <- letter
      cs <- many (alphaNum <|> char '_' <|> char '\'')
      return (c:cs)) <?> "identifier"

-- | Parse a valid identifier string as an expression variable
parseExprVarAndStr :: Stream s Identity Char => PermParseM s (String, SomeName)
parseExprVarAndStr =
  do str <- parseIdent
     env <- getState
     case lookupExprVar str env of
       Just x -> return (str, x)
       Nothing -> fail ("unknown variable: " ++ str)

-- | Parse a valid identifier string as an expression variable
parseExprVar :: Stream s Identity Char => PermParseM s SomeName
parseExprVar = snd <$> parseExprVarAndStr

-- | Parse an identifier as an expression variable of a specific type
parseExprVarOfType :: Stream s Identity Char => TypeRepr a ->
                      PermParseM s (ExprVar a)
parseExprVarOfType tp =
  do some_nm <- parseExprVar
     castTypedM "variable" tp some_nm

-- | Parse a single bitvector factor of the form @x*n@, @n*x@, @x@, or @n@,
-- where @x@ is a variable and @n@ is an integer. Note that this returns a
-- 'PermExpr' and not a 'BVFactor' because the latter does not include the
-- constant integer case @n@.
parseBVFactor :: (1 <= w, KnownNat w, Stream s Identity Char) =>
                 PermParseM s (PermExpr (BVType w))
parseBVFactor =
  spaces >>
  (try (do i <- integer
           spaces >> char '*' >> spaces
           x <- parseExprVarOfType knownRepr
           return $ PExpr_BV [BVFactor i x] 0)
   <|>
   try (do x <- parseExprVarOfType knownRepr
           spaces >> char '*' >> spaces
           i <- integer
           return $ PExpr_BV [BVFactor i x] 0)
   <|>
   try (do x <- parseExprVarOfType knownRepr
           return $ PExpr_BV [BVFactor 1 x] 0)
   <|>
   do i <- integer
      return $ PExpr_BV [] i)

-- | Parse a bitvector expression of the form
--
-- > f1 + ... + fn
--
-- where each @fi@ is a factor parsed by 'parseBVFactor'
parseBVExpr :: (1 <= w, KnownNat w, Stream s Identity Char) =>
               PermParseM s (PermExpr (BVType w))
parseBVExpr = parseBVExprH Proxy

-- | Helper for 'parseBVExpr'
parseBVExprH :: (1 <= w, KnownNat w, Stream s Identity Char) =>
                Proxy w -> PermParseM s (PermExpr (BVType w))
parseBVExprH w =
  (normalizeBVExpr <$> foldr1 bvAdd <$> many1 parseBVFactor)
  <?> ("expression of type bv " ++ show (natVal w))

-- | Parse an expression of a known type
parseExpr :: (Stream s Identity Char, Liftable s) => TypeRepr a ->
             PermParseM s (PermExpr a)
parseExpr UnitRepr =
  try (string "unit" >> return PExpr_Unit) <|>
  (PExpr_Var <$> parseExprVarOfType UnitRepr) <?>
  "unit expression"
parseExpr NatRepr =
  (PExpr_Nat <$> integer) <|> (PExpr_Var <$> parseExprVarOfType NatRepr) <?>
  "nat expression"
parseExpr (BVRepr w) = withKnownNat w parseBVExpr
parseExpr tp@(StructRepr fld_tps) =
  spaces >>
  ((string "struct" >> spaces >>
    parseInParens (PExpr_Struct <$> parseExprs (mkCruCtx fld_tps))) <|>
   (PExpr_Var <$> parseExprVarOfType tp)) <?>
  "struct expression"
parseExpr LifetimeRepr =
  try (string "always" >> return PExpr_Always) <|>
  (PExpr_Var <$> parseExprVarOfType LifetimeRepr) <?>
  "lifetime expression"
parseExpr tp@(LLVMPointerRepr w) =
  withKnownNat w $
  spaces >>
  ((do try (string "llvmword" >> spaces >> char '(')
       e <- parseExpr (BVRepr w)
       spaces >> char ')'
       return $ PExpr_LLVMWord e) <|>
   (do x <- parseExprVarOfType tp
       try (do spaces >> char '+'
               off <- parseBVExpr
               return $ PExpr_LLVMOffset x off) <|>
         return (PExpr_Var x)) <?>
   "llvmptr expression")
parseExpr tp@(FunctionHandleRepr _ _) =
  do str <- parseIdent
     env <- getState
     case lookupExprVar str env of
       Just some_x ->
         PExpr_Var <$> castTypedM "variable" tp some_x
       Nothing ->
         case lookupFunHandle (parserEnvPermEnv env) str of
           Just (SomeHandle hn)
             | Just Refl <- testEquality tp (handleType hn) ->
               return $ PExpr_Fun hn
           Just (SomeHandle hn) ->
             unexpected ("function " ++ str ++ " of type " ++
                         show (handleType hn))
           Nothing ->
             unexpected ("unknown variable or function: " ++ str)
parseExpr PermListRepr =
  -- FIXME: parse non-empty perm lists
  (string "[]" >> return PExpr_PermListNil) <|>
  (PExpr_Var <$> parseExprVarOfType PermListRepr) <?>
  "permission list expression"
parseExpr RWModalityRepr =
  (string "R" >> return PExpr_Read) <|> (string "W" >> return PExpr_Write)
parseExpr (ValuePermRepr tp) = PExpr_ValPerm <$> parseValPerm tp
parseExpr tp = PExpr_Var <$> parseExprVarOfType tp <?> ("expression of type "
                                                        ++ show tp)

-- | Parse a comma-separated list of expressions to a 'PermExprs'
parseExprs :: (Stream s Identity Char, Liftable s) => CruCtx ctx ->
              PermParseM s (PermExprs ctx)
parseExprs CruCtxNil = return PExprs_Nil
parseExprs (CruCtxCons CruCtxNil tp) =
  -- Special case for a 1-element context: do not parse a comma
  PExprs_Cons PExprs_Nil <$> parseExpr tp
parseExprs (CruCtxCons ctx tp) =
  do es <- parseExprs ctx
     spaces >> char ','
     e <- parseExpr tp
     return $ PExprs_Cons es e


----------------------------------------------------------------------
-- * Parsing Permissions
----------------------------------------------------------------------

-- | Parse a value permission of a known type
parseValPerm :: (Stream s Identity Char, Liftable s) => TypeRepr a ->
                PermParseM s (ValuePerm a)
parseValPerm tp =
  do spaces
     p1 <-
       (parseInParens (parseValPerm tp)) <|>
       try (string "true" >> return ValPerm_True) <|>
       (do try (string "eq" >> spaces >> char '(')
           e <- parseExpr tp
           spaces >> char ')'
           return (ValPerm_Eq e)) <|>
       (do try (string "exists" >> spaces1)
           var <- parseIdent
           spaces >> char ':'
           some_known_tp' <- parseTypeKnown
           spaces >> char '.'
           case some_known_tp' of
             Some ktp'@KnownReprObj ->
               fmap ValPerm_Exists $ mbM $ nu $ \z ->
               withExprVar var (unKnownReprObj ktp') z $
               parseValPerm tp) <|>
       (do n <- try (parseIdent >>= \n -> spaces >> char '<' >> return n)
           env <- getState
           case lookupNamedPermName (parserEnvPermEnv env) n of
             Just (SomeNamedPermName rpn)
               | Just Refl <- testEquality (namedPermNameType rpn) tp ->
                 do args <- parseExprs (namedPermNameArgs rpn)
                    spaces >> char '>'
                    return $ ValPerm_Named rpn args
             Just (SomeNamedPermName rpn) ->
               fail ("Named permission " ++ n ++ " has incorrect type")
             Nothing ->
               fail ("Unknown named permission '" ++ n ++ "'")) <|>
       (ValPerm_Conj <$> parseAtomicPerms tp) <|>
       (ValPerm_Var <$> parseExprVarOfType (ValuePermRepr tp)) <?>
       ("permission of type " ++ show tp)
     -- FIXME: I think the SAW lexer can't handle "\/" in strings...?
     -- try (spaces >> string "\\/" >> (ValPerm_Or p1 <$> parseValPerm tp)) <|>
     (try (spaces1 >> string "or" >> space) >> (ValPerm_Or p1 <$>
                                                parseValPerm tp)) <|>
       return p1

-- | Parse a @*@-separated list of atomic permissions
parseAtomicPerms :: (Stream s Identity Char, Liftable s) => TypeRepr a ->
                    PermParseM s [AtomicPerm a]
parseAtomicPerms tp =
  do p1 <- parseAtomicPerm tp
     (try (spaces >> string "*") >> (p1:) <$> parseAtomicPerms tp) <|> return [p1]

-- | Parse an atomic permission of a specific type
parseAtomicPerm :: (Stream s Identity Char, Liftable s) => TypeRepr a ->
                   PermParseM s (AtomicPerm a)
parseAtomicPerm (LLVMPointerRepr w)
  | Left LeqProof <- decideLeq oneRepr w =
    withKnownNat w
    ((Perm_LLVMField <$> parseLLVMFieldPerm False) <|>
     (Perm_LLVMArray <$> parseLLVMArrayPerm) <|>
     (do try (string "free" >> spaces >> char '(')
         e <- parseBVExpr
         spaces >> char ')'
         return $ Perm_LLVMFree e) <|>
     Perm_BVProp <$> parseBVProp)

-- | Parse a field permission @[l]ptr((rw,off) |-> p)@. If the 'Bool' flag is
-- 'True', the field permission is being parsed as part of an array permission,
-- so that @ptr@ and outer parentheses should be omitted. If the 'Bool' flag is
-- 'False', only consume input if that input starts with @( )* "ptr" ( )* "("@,
-- while if it is 'True', only consume input if it starts with @( )* "("@.
parseLLVMFieldPerm :: (Stream s Identity Char, Liftable s,
                       KnownNat w, 1 <= w) =>
                      Bool -> PermParseM s (LLVMFieldPerm w)
parseLLVMFieldPerm in_array =
  do llvmFieldLifetime <- (do try (string "[")
                              l <- parseExpr knownRepr
                              string "]"
                              return l) <|> return PExpr_Always
     if in_array then try (spaces >> char '(' >> return ())
       else try (spaces >> string "ptr" >> spaces >> char '(' >>
                 spaces >> char '(' >> return ())
     llvmFieldRW <- parseExpr knownRepr
     spaces >> comma >> spaces
     llvmFieldOffset <- parseBVExpr
     spaces >> string ")" >> spaces >> string "|->" >> spaces
     llvmFieldContents <- parseValPerm knownRepr
     if in_array then return () else spaces >> string ")" >> return ()
     return (LLVMFieldPerm {..})

-- | Parse an array permission @array(off,<len,*stride,[fp1,...])@. Only consume
-- input if that input starts with @"array" ( )* "("@.
parseLLVMArrayPerm :: (Stream s Identity Char, Liftable s,
                       KnownNat w, 1 <= w) =>
                      PermParseM s (LLVMArrayPerm w)
parseLLVMArrayPerm =
  do try (string "array" >> spaces >> char '(')
     llvmArrayOffset <- parseBVExpr
     spaces >> comma >> spaces >> char '<'
     llvmArrayLen <- parseBVExpr
     spaces >> comma >> spaces >> char '*'
     llvmArrayStride <- integer
     spaces >> comma >> spaces >> char '['
     llvmArrayFields <- sepBy1 (parseLLVMFieldPerm True) (spaces >> comma)
     let llvmArrayBorrows = []
     return LLVMArrayPerm {..}

-- | Parse a 'BVProp'
parseBVProp :: (Stream s Identity Char, Liftable s, KnownNat w, 1 <= w) =>
               PermParseM s (BVProp w)
parseBVProp =
  (try parseBVExpr >>= \e1 ->
    (do try (spaces >> string "==")
        e2 <- parseBVExpr
        return $ BVProp_Eq e1 e2) <|>
    (do try (spaces >> string "/=")
        e2 <- parseBVExpr
        return $ BVProp_Neq e1 e2) <|>
    (do try (spaces >> string "in" >> spaces)
        rng <- parseBVRange
        return $ BVProp_InRange e1 rng) <|>
    (do try (spaces >> string "not" >> spaces1 >> string "in")
        rng <- parseBVRange
        return $ BVProp_NotInRange e1 rng)) <|>
  do rng1 <- parseBVRange
     spaces
     mk_prop <-
       try (string "subset" >> return BVProp_RangeSubset) <|>
       (string "disjoint" >> return BVProp_RangesDisjoint)
     rng2 <- parseBVRange
     return $ mk_prop rng1 rng2

-- | Parse a 'BVRange' written as @{ off, len }@
parseBVRange :: (Stream s Identity Char, Liftable s, KnownNat w, 1 <= w) =>
                PermParseM s (BVRange w)
parseBVRange =
  do try (spaces >> char '{')
     bvRangeOffset <- parseBVExpr
     spaces >> comma
     bvRangeLength <- parseBVExpr
     spaces >> char '}'
     return BVRange {..}


----------------------------------------------------------------------
-- * Parsing Permission Sets and Function Permissions
----------------------------------------------------------------------

-- | A sequence of variable names and their types
data ParsedCtx ctx =
  ParsedCtx (MapRList (Constant String) ctx) (CruCtx ctx)

-- | Remove the last variable in a 'ParsedCtx'
parsedCtxUncons :: ParsedCtx (ctx :> tp) -> ParsedCtx ctx
parsedCtxUncons (ParsedCtx (xs :>: _) (CruCtxCons ctx _)) = ParsedCtx xs ctx

-- | Add a variable name and type to a 'ParsedCtx'
consParsedCtx :: String -> TypeRepr tp -> ParsedCtx ctx ->
                 ParsedCtx (ctx :> tp)
consParsedCtx x tp (ParsedCtx xs ctx) =
  ParsedCtx (xs :>: Constant x) (CruCtxCons ctx tp)

-- | A 'ParsedCtx' with a single element
singletonParsedCtx :: String -> TypeRepr tp -> ParsedCtx (RNil :> tp)
singletonParsedCtx x tp =
  ParsedCtx (MNil :>: Constant x) (CruCtxCons CruCtxNil tp)

-- | An empty 'ParsedCtx'
emptyParsedCtx :: ParsedCtx RNil
emptyParsedCtx = ParsedCtx MNil CruCtxNil

-- | Add a variable name and type to the beginning of an unknown 'ParsedCtx'
preconsSomeParsedCtx :: String -> Some TypeRepr -> Some ParsedCtx ->
                        Some ParsedCtx
preconsSomeParsedCtx x (Some (tp :: TypeRepr tp)) (Some (ParsedCtx ns tps)) =
  Some $ ParsedCtx
  (appendMapRList (MNil :>: (Constant x :: Constant String tp)) ns)
  (appendCruCtx (singletonCruCtx tp) tps)

mkArgsParsedCtx :: CruCtx ctx -> ParsedCtx ctx
mkArgsParsedCtx ctx = ParsedCtx (helper ctx) ctx where
  helper :: CruCtx ctx' -> MapRList (Constant String) ctx'
  helper CruCtxNil = MNil
  helper (CruCtxCons ctx tp) =
    helper ctx :>: Constant ("arg" ++ show (cruCtxLen ctx))

-- | Parse a typing context @x1:tp1, x2:tp2, ...@
parseCtx :: (Stream s Identity Char, Liftable s) =>
            PermParseM s (Some ParsedCtx)
parseCtx =
  (do x <- try parseIdent
      spaces >> char ':'
      some_tp <- parseType
      try (do spaces >> comma
              some_ctx' <- parseCtx
              return $ preconsSomeParsedCtx x some_tp some_ctx')
        <|>
        (case some_tp of
            Some tp -> return (Some $ singletonParsedCtx x tp))) <|>
  return (Some emptyParsedCtx)

-- | Parse a sequence @x1:p1, x2:p2, ...@ of variables and their permissions
--
-- FIXME: not used
parseDistPerms :: (Stream s Identity Char, Liftable s) =>
                  PermParseM s (Some DistPerms)
parseDistPerms =
  parseExprVar >>= \some_x ->
  case some_x of
    Some (Typed tp x) ->
      do p <- parseValPerm tp
         try (do spaces >> comma
                 some_dist_perms' <- parseDistPerms
                 case some_dist_perms' of
                   Some perms ->
                     return $ Some (DistPermsCons perms x p))
           <|>
           return (Some $ distPerms1 x p)

-- | Helper type for 'parseValuePerms'
data VarPermSpec a = VarPermSpec (Name a) (Maybe (ValuePerm a))

type VarPermSpecs = MapRList VarPermSpec

-- | Build a 'VarPermSpecs' from a list of names
mkVarPermSpecs :: MapRList Name ctx -> VarPermSpecs ctx
mkVarPermSpecs = mapMapRList (\n -> VarPermSpec n Nothing)

-- | Find a 'VarPermSpec' for a particular variable
findVarPermSpec :: Name (a :: CrucibleType) ->
                   VarPermSpecs ctx -> Maybe (Member ctx a)
findVarPermSpec _ MNil = Nothing
findVarPermSpec n (_ :>: VarPermSpec n' _)
  | Just Refl <- testEquality n n'
  = Just Member_Base
findVarPermSpec n (specs :>: _) = Member_Step <$> findVarPermSpec n specs

-- | Try to set the permission for a variable in a 'VarPermSpecs' list, raising
-- a parse error if the variable already has a permission or is one of the
-- expected variables
setVarSpecsPermM :: Stream s Identity Char =>
                    String -> Name tp -> ValuePerm tp -> VarPermSpecs ctx ->
                    PermParseM s (VarPermSpecs ctx)
setVarSpecsPermM _ n p var_specs
  | Just memb <- findVarPermSpec n var_specs
  , VarPermSpec _ Nothing <- mapRListLookup memb var_specs =
    return $ mapRListModify memb (const $ VarPermSpec n $ Just p) var_specs
setVarSpecsPermM var n _ var_specs
  | Just memb <- findVarPermSpec n var_specs =
    unexpected ("Variable " ++ var ++ " occurs more than once!")
setVarSpecsPermM var n _ var_specs =
    unexpected ("Unknown variable: " ++ var)

-- | Convert a 'VarPermSpecs' sequence to a sequence of permissions, using the
-- @true@ permission for any variables without permissions
varSpecsToPerms :: VarPermSpecs ctx -> ValuePerms ctx
varSpecsToPerms MNil = ValPerms_Nil
varSpecsToPerms (var_specs :>: VarPermSpec _ (Just p)) =
  ValPerms_Cons (varSpecsToPerms var_specs) p
varSpecsToPerms (var_specs :>: VarPermSpec _ Nothing) =
  ValPerms_Cons (varSpecsToPerms var_specs) ValPerm_True

-- | Parse a sequence @x1:p1, x2:p2, ...@ of variables and their permissions,
-- where each variable occurs at most once. The input list says which variables
-- can occur and which have already been seen. Return a sequence of the
-- permissions in the same order as the input list of variables.
parseSortedValuePerms :: (Stream s Identity Char, Liftable s) =>
                         VarPermSpecs ctx ->
                         PermParseM s (ValuePerms ctx)
parseSortedValuePerms var_specs =
  try (spaces >> string "empty" >> return (varSpecsToPerms var_specs)) <|>
  (parseExprVarAndStr >>= \(var, some_n) ->
   case some_n of
     Some (Typed tp n) ->
       do spaces >> char ':'
          p <- parseValPerm tp
          var_specs' <- setVarSpecsPermM var n p var_specs
          try (spaces >> comma >> parseSortedValuePerms var_specs') <|>
            return (varSpecsToPerms var_specs'))

-- | Run a parsing computation inside a name-binding for expressions variables
-- given by a 'ParsedCtx'. Returning the results inside a name-binding.
inParsedCtxM :: (Liftable s, NuMatching a) =>
                ParsedCtx ctx -> (MapRList Name ctx -> PermParseM s a) ->
                PermParseM s (Mb ctx a)
inParsedCtxM (ParsedCtx ids tps) f =
  mbM $ nuMulti (cruCtxProxies tps) $ \ns -> withExprVars ids tps ns (f ns)

-- | Parse a sequence @x1:p1, x2:p2, ...@ of variables and their permissions,
-- and sort the result into a 'ValuePerms' in a multi-binding that is in the
-- same order as the 'ParsedCtx' supplied on input
parseSortedMbValuePerms :: (Stream s Identity Char, Liftable s) =>
                           ParsedCtx ctx -> PermParseM s (MbValuePerms ctx)
parseSortedMbValuePerms ctx =
  inParsedCtxM ctx $ \ns ->
  parseSortedValuePerms (mkVarPermSpecs ns)

-- | Parse a function permission of the form
--
-- > (x1:tp1, ...). arg1:p1, ... -o arg1:p1', ..., argn:pn', ret:p_ret
--
-- for some arbitrary context @x1:tp1, ...@ of ghost variables
parseFunPermM :: (Stream s Identity Char, Liftable s) =>
                 CruCtx args -> TypeRepr ret ->
                 PermParseM s (SomeFunPerm args ret)
parseFunPermM args ret =
  spaces >> parseInParens parseCtx >>= \some_ghosts_ctx ->
  case some_ghosts_ctx of
    Some ghosts_ctx@(ParsedCtx _ ghosts) ->
      do spaces >> char '.'
         let args_ctx = mkArgsParsedCtx args
         let ghosts_l_ctx = consParsedCtx "l" LifetimeRepr ghosts_ctx
         perms_in <-
           inParsedCtxM ghosts_l_ctx $ const $
           parseSortedMbValuePerms args_ctx
         spaces >> string "-o"
         perms_out <-
           inParsedCtxM ghosts_l_ctx $ const $
           parseSortedMbValuePerms (consParsedCtx "ret" ret args_ctx)
         eof
         return $ SomeFunPerm $ FunPerm ghosts args ret perms_in perms_out

-- | Run the 'parseFunPermM' parsing computation on a 'String'
parseFunPermString :: PermEnv -> CruCtx args -> TypeRepr ret ->
                      String -> Either ParseError (SomeFunPerm args ret)
parseFunPermString env args ret str =
  runParser (parseFunPermM args ret) (mkParserEnv env) "" str

-- | Parse a type context from a 'String'
parseCtxString :: PermEnv -> String -> Either ParseError (Some CruCtx)
parseCtxString env str =
  runParser parseCtx (mkParserEnv env) "" str >>= \some_ctx ->
  case some_ctx of
    Some (ParsedCtx _ ctx) -> return $ Some ctx

-- | Parse a type from a 'String'
parseTypeString :: PermEnv -> String -> Either ParseError (Some TypeRepr)
parseTypeString env str =
  runParser parseType (mkParserEnv env) "" str
