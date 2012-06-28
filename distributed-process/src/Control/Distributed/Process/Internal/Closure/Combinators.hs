module Control.Distributed.Process.Internal.Closure.Combinators 
  ( -- * Generic combinators
    closureApply
  , closureConst
  , closureUnit
    -- * Arrow combinators for processes
  , CP
  , cpIntro
  , cpElim
  , cpId
  , cpComp
  , cpFirst
  , cpSwap
  , cpSecond
  , cpPair
  , cpCopy
  , cpFanOut
  , cpLeft
  , cpMirror
  , cpRight
  , cpEither
  , cpUntag
  , cpFanIn
  , cpApply
    -- * Derived process operators
  , cpBind
  , cpSeq
  ) where

import Prelude hiding (lookup)
import qualified Data.ByteString.Lazy as BS (empty)
import Data.Binary (encode)
import Data.Typeable (typeOf, Typeable)
import Control.Distributed.Process.Internal.Types
  ( Closure(..)
  , Static(..)
  , StaticLabel(..)
  , Process
  )
import Control.Distributed.Process.Internal.TypeRep () -- Binary instances

--------------------------------------------------------------------------------
-- Generic closure combinators                                                -- 
--------------------------------------------------------------------------------

closureApply :: Closure (a -> b) -> Closure a -> Closure b
closureApply (Closure (Static labelf) envf) (Closure (Static labelx) envx) = 
  Closure (Static ClosureApply) $ encode (labelf, envf, labelx, envx)

closureConst :: forall a b. (Typeable a, Typeable b) 
          => Closure (a -> b -> a)
closureConst = Closure (Static ClosureConst) (encode $ typeOf aux)
  where
    aux :: a -> b -> a
    aux = undefined

closureUnit :: Closure ()
closureUnit = Closure (Static ClosureUnit) BS.empty

--------------------------------------------------------------------------------
-- Arrow combinators for processes                                            -- 
--------------------------------------------------------------------------------

type CP a b = Closure (a -> Process b)

cpIntro :: (Typeable a, Typeable b)
        => Closure (Process b) -> CP a b 
cpIntro = closureApply closureConst 

cpElim :: Typeable a 
       => CP () a -> Closure (Process a)
cpElim = flip closureApply closureUnit 

cpId :: forall a. Typeable a 
     => CP a a 
cpId = Closure (Static CpId) (encode $ typeOf aux)
  where
    aux :: a -> Process a
    aux = undefined

cpComp :: forall a b c. (Typeable a, Typeable b, Typeable c) 
       => CP a b -> CP b c -> CP a c
cpComp f g = comp `closureApply` f `closureApply` g 
  where
    comp :: Closure ((a -> Process b) -> (b -> Process c) -> a -> Process c)
    comp = Closure (Static CpComp) (encode $ typeOf aux)
    
    aux :: (a -> Process b) -> (b -> Process c) -> a -> Process c
    aux = undefined

cpFirst :: forall a b c. (Typeable a, Typeable b, Typeable c)
        => CP a b -> CP (a, c) (b, c)
cpFirst = closureApply first
  where
    first :: Closure ((a -> Process b) -> (a, c) -> Process (b, c))
    first = Closure (Static CpFirst) (encode $ typeOf aux)

    aux :: (a -> Process b) -> (a, c) -> Process (b, c)
    aux = undefined

cpSwap :: forall a b. (Typeable a, Typeable b)
       => CP (a, b) (b, a)
cpSwap = Closure (Static CpSwap) (encode $ typeOf aux)
  where
    aux :: (a, b) -> Process (b, a)
    aux = undefined

cpSecond :: (Typeable a, Typeable b, Typeable c)
         => CP a b -> CP (c, a) (c, b)
cpSecond f = cpSwap `cpComp` cpFirst f `cpComp` cpSwap

cpPair :: (Typeable a, Typeable a', Typeable b, Typeable b')
        => CP a b -> CP a' b' -> CP (a, a') (b, b')
cpPair f g = cpFirst f `cpComp` cpSecond g

cpCopy :: forall a. Typeable a 
       => CP a (a, a)
cpCopy = Closure (Static CpCopy) (encode $ typeOf aux)
  where
    aux :: a -> Process (a, a)
    aux = undefined

cpFanOut :: (Typeable a, Typeable b, Typeable c)
         => CP a b -> CP a c -> CP a (b, c)
cpFanOut f g = cpCopy `cpComp` (f `cpPair` g)         

cpLeft :: forall a b c. (Typeable a, Typeable b, Typeable c)
       => CP a b -> CP (Either a c) (Either b c)
cpLeft = closureApply left
  where
    left :: Closure ((a -> Process b) -> Either a c -> Process (Either b c)) 
    left = Closure (Static CpLeft) (encode $ typeOf aux)

    aux :: (a -> Process b) -> Either a c -> Process (Either b c)
    aux = undefined

cpMirror :: forall a b. (Typeable a, Typeable b)
         => CP (Either a b) (Either b a)
cpMirror = Closure (Static CpMirror) (encode $ typeOf aux)
  where
    aux :: Either a b -> Process (Either b a)
    aux = undefined

cpRight :: forall a b c. (Typeable a, Typeable b, Typeable c)
        => CP a b -> CP (Either c a) (Either c b)
cpRight f = cpMirror `cpComp` cpLeft f `cpComp` cpMirror 

cpEither :: (Typeable a, Typeable a', Typeable b, Typeable b')
         => CP a b -> CP a' b' -> CP (Either a a') (Either b b')
cpEither f g = cpLeft f `cpComp` cpRight g

cpUntag :: forall a. Typeable a
        => CP (Either a a) a
cpUntag = Closure (Static CpUntag) (encode $ typeOf aux)
  where
    aux :: Either a a -> Process a
    aux = undefined

cpFanIn :: (Typeable a, Typeable b, Typeable c) 
        => CP a c -> CP b c -> CP (Either a b) c
cpFanIn f g = (f `cpEither` g) `cpComp` cpUntag 

cpApply :: forall a b. (Typeable a, Typeable b)
        => CP (CP a b, a) b
cpApply = Closure (Static CpApply) $ encode ( typeOf aux
                                            , typeOf (undefined :: a) 
                                            , typeOf (undefined :: Process b)
                                            )
  where
    aux :: (Closure (a -> Process b), a) -> Process b
    aux = undefined

--------------------------------------------------------------------------------
-- Some derived operators for processes                                       -- 
--------------------------------------------------------------------------------

cpBind :: (Typeable a, Typeable b) 
       => Closure (Process a) -> Closure (a -> Process b) -> Closure (Process b)
cpBind x f = cpElim $ cpIntro x `cpComp` f

cpSeq :: Closure (Process ()) -> Closure (Process ()) -> Closure (Process ())
cpSeq p q = p `cpBind` cpIntro q
