{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE RecordWildCards #-}

{-# LANGUAGE QuasiQuotes #-}
module Lib where

import Control.Exception
import Control.Monad.Reader
import Control.Monad.Logger
import Control.Monad.IO.Unlift
import Data.Hashable
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM
import Data.Pool
import Data.Text (Text)
import Data.Text.Encoding
import Data.Typeable
import Data.IORef
import Database.Persist.Sql
import Database.Persist.Sql.Types.Internal
-- Todo: separate out implementations
import Control.Monad.Morph
import Data.ByteString (ByteString)
import Database.Persist.Postgresql

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


instance MonadUnliftIO m => MultiPoolBackend m SqlBackend where
  type MasterConnection SqlBackend = SqlWriteBackend
  type ReplicaConnection SqlBackend = SqlReadBackend
  type ReplicaIdentifier SqlBackend = InstanceName SqlReadBackend

  runWriteAny b m = runWrite b () m
  runWrite b () m = runSqlPool m (multiPoolMaster b)

  runReadMaster b () m = runReadAnyMaster b m
  runReadAnyMaster b m = runSqlPool (readToWrite m) (multiPoolMaster b)
  runReadAny b m = do
    mident <- liftIO $ multiPoolAnyReplicaSelector b b
    case mident of
      Nothing -> runReadAnyMaster b m
      Just ident -> runRead b ident m
  runRead b ident m = case HM.lookup ident (multiPoolReplica b) of
    Nothing -> throw (InstanceDoesNotExist ident)
    Just repl -> runSqlPool m repl

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

initMultiPool ::
     (MonadLogger m, MonadUnliftIO m)
  => ConnectionString
  -> Int
  -> [(InstanceName SqlReadBackend, ConnectionString, Int)]
  -> m (MultiPool SqlBackend)
initMultiPool mc mn rl = do
  rr <- roundRobin $ map (\(i, _, _) -> i) rl
  initMultiPool' rr mc mn rl

initMultiPool' ::
     (MonadLogger m, MonadUnliftIO m)
  => (MultiPool SqlBackend -> IO (Maybe (InstanceName SqlReadBackend)))
  -> ConnectionString
  -> Int
  -> [(InstanceName SqlReadBackend, ConnectionString, Int)]
  -> m (MultiPool SqlBackend)
initMultiPool' multiPoolAnyReplicaSelector str n is = do
  multiPoolMaster <- createPostgresqlPool str n
  replicas <- mapM (\(inst, connStr, numConns) -> (,) <$> pure inst <*> createPostgresqlPool connStr numConns) is
  let multiPoolReplica = HM.fromList replicas
      multiPoolAnyMasterSelector = const $ pure ()
  return $ MultiPool {..}

unsafeRead :: ReaderT SqlBackend m a -> ReaderT SqlReadBackend m a
unsafeRead = withReaderT persistBackend

getLastLSN :: MonadIO m => ReaderT SqlReadBackend m LSN
getLastLSN = (unSingle . head) <$> unsafeRead [sqlQQ|SELECT pg_last_wal_replay_lsn() AS lsn|]


newtype LSN = LSN ByteString
  deriving (Show, Eq, Ord)

instance PersistField LSN where
  toPersistValue (LSN bs) = PersistDbSpecific bs
  fromPersistValue (PersistDbSpecific t) = Right $ LSN t
  fromPersistValue (PersistText t) = Right $ LSN $ encodeUtf8 t
  fromPersistValue (PersistByteString t) = Right $ LSN t
  fromPersistValue _ = Left "Could not decode LSN"

gatherLSNs :: MonadUnliftIO m => MultiPool SqlBackend -> m [(InstanceName SqlReadBackend, LSN)]
gatherLSNs p = forReplicas p $ \ident pool -> runSqlPool ((,) <$> pure ident <*> getLastLSN) pool
{-

-- Postgresql only at the moment
data LSNCache = LSNCache
  { lsnCacheMap :: !(HashMap (ReplicaIdentifier SqlBackend) (IORef LSN))
  }
-}
