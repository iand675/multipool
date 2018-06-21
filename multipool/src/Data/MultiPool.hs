{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE RecordWildCards #-}

module Data.MultiPool where

import Control.Exception
import Control.Monad.Reader
import Control.Monad.Logger
import Data.Hashable
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM
import Data.Pool
import Data.Text (Text)
import Data.Text.Encoding
import Data.Typeable
import Data.IORef
-- Todo: separate out implementations
import Data.ByteString (ByteString)

newtype InstanceName backend = InstanceName
  { rawInstanceName :: Hashed Text
  } deriving (Show, Eq, Ord)

mkInstanceName :: Text -> InstanceName backend
mkInstanceName = InstanceName . hashed

instance Hashable (InstanceName backend) where
  hashWithSalt s r = hashWithSalt s (rawInstanceName r)
  hash = hash . rawInstanceName

data InstanceDoesNotExist backend = InstanceDoesNotExist
  { instanceDoesNotExist :: InstanceName backend
  } deriving (Show, Eq, Typeable)

instance (Show (InstanceDoesNotExist backend), Typeable backend) => Exception (InstanceDoesNotExist backend)

class Monad m => MultiPoolBackend m backend where
  type Masters backend :: *
  type Masters backend = Pool (MasterConnection backend)
  type Replicas backend :: *
  type Replicas backend = HashMap (ReplicaIdentifier backend) (Pool (ReplicaConnection backend))

  type MasterConnection backend :: *
  type ReplicaConnection backend :: *

  type MasterIdentifier backend :: *
  type MasterIdentifier backend = ()
  type ReplicaIdentifier backend :: *
  type ReplicaIdentifier backend = InstanceName backend

  runWriteAny :: MultiPool backend -> ReaderT (MasterConnection backend) m a -> m a
  runWrite :: MultiPool backend -> MasterIdentifier backend -> ReaderT (MasterConnection backend) m a -> m a

  runReadMaster :: MultiPool backend -> MasterIdentifier backend -> ReaderT (ReplicaConnection backend) m a -> m a
  runReadAnyMaster :: MultiPool backend -> ReaderT (ReplicaConnection backend) m a -> m a
  runReadAny :: MultiPool backend -> ReaderT (ReplicaConnection backend) m a -> m a
  runRead :: MultiPool backend -> ReplicaIdentifier backend -> ReaderT (ReplicaConnection backend) m a -> m a


-- Invariant: MultiPool should not be modified after creation?
data MultiPool backend = MultiPool
  { multiPoolMaster :: !(Masters backend)
  , multiPoolReplica :: !(Replicas backend)
  , multiPoolAnyMasterSelector :: MultiPool backend -> IO (MasterIdentifier backend)
  , multiPoolAnyReplicaSelector :: MultiPool backend -> IO (Maybe (ReplicaIdentifier backend))
  }

forReplicas :: (MultiPoolBackend m backend, Replicas backend ~ HashMap k v) => MultiPool backend -> (k -> v -> m a) -> m [a]
forReplicas pool f = forM (HM.toList (multiPoolReplica pool)) $ \(k, v) -> f k v

roundRobin :: MonadIO m => [choice] -> m (a -> IO (Maybe choice))
roundRobin [] = return $ const $ return Nothing
roundRobin choices = do
  let infiniteChoice = cycle choices
  picker <- liftIO $ newIORef infiniteChoice
  return $ const $ atomicModifyIORef' picker $ \l -> case l of
    (x:xs) -> (xs, Just x)
    [] -> error "roundRobin: should have matched empty list in first clause"
