{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
module Data.MultiPool.Persist.Postgresql
    ( initMultiPool
    , initMultiPool'
    , getLastLSN
    , gatherLSNs
    ) where
import Control.Monad.IO.Unlift
import Control.Monad.Logger
import Control.Monad.Reader
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM
import Data.MultiPool
import Data.MultiPool.Persist.Sql
import Database.Persist.Postgresql
import Database.Persist.Postgresql.Common

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

-- TODO 9.6 support?
getLastLSN :: MonadIO m => ReaderT SqlReadBackend m LSN
getLastLSN = (unSingle . head) <$> unsafeRead [sqlQQ|SELECT pg_last_wal_replay_lsn() AS lsn|]

gatherLSNs :: MonadUnliftIO m => MultiPool SqlBackend -> m (HashMap (InstanceName SqlReadBackend) LSN)
gatherLSNs p = fmap HM.fromList $ forReplicas p $ \ident pool -> runSqlPool ((,) <$> pure ident <*> getLastLSN) pool
