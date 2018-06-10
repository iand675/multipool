{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
module Data.MultiPool.Persist.Postgresql
    ( initMultiPool
    , initMultiPool'
    , runReadCurrent
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
  => (MultiPool SqlBackend -> IO (Maybe (InstanceName SqlReadBackend))) -- Strategy for selectin the replica instance when calling 'runReadAny'. 'roundRobin' is the current default.
  -> ConnectionString -- ^ Master connection string
  -> Int -- ^ Max number of connections to master instance
  -> [(InstanceName SqlReadBackend, ConnectionString, Int)] -- ^ Replica connection details
  -> m (MultiPool SqlBackend)
initMultiPool' multiPoolAnyReplicaSelector str n is = do
  multiPoolMaster <- createPostgresqlPool str n
  replicas <- mapM (\(inst, connStr, numConns) -> (,) <$> pure inst <*> createPostgresqlPool connStr numConns) is
  let multiPoolReplica = HM.fromList replicas
      multiPoolAnyMasterSelector = const $ pure ()
  return $ MultiPool {..}

-- | Performs a read on the first replica found that sufficiently up-to-date with the given LSN. This function can be combined with 'gatherLSNs' and some sort of caching mechanism to provide a simple way to scale out reads. An great article on this concept can be found [here](https://brandur.org/postgres-reads)
--
-- If no replica is up-to-date with the given LSN, the master instance will be used to run the query.
runReadCurrent ::
     MonadUnliftIO m
  => MultiPool SqlBackend
  -> HashMap (InstanceName SqlReadBackend) LSN
  -> LSN
  -> ReaderT SqlReadBackend m a
  -> m a
runReadCurrent b lsnMap lsn m =
  case validLsnPools of
    [] -> runReadAnyMaster b m
    (pool:_) -> runSqlPool m $ snd pool
  where
    validLsnPools =
      HM.toList $
      HM.intersectionWith
        (\pool _ -> pool)
        (multiPoolReplica b)
        (HM.filter (>= lsn) lsnMap)

-- TODO 9.6 support?
getLastLSN :: MonadIO m => ReaderT SqlReadBackend m LSN
getLastLSN = (unSingle . head) <$> unsafeRead [sqlQQ|SELECT pg_last_wal_replay_lsn() AS lsn|]

gatherLSNs :: MonadUnliftIO m => MultiPool SqlBackend -> m (HashMap (InstanceName SqlReadBackend) LSN)
gatherLSNs p = fmap HM.fromList $ forReplicas p $ \ident pool -> runSqlPool ((,) <$> pure ident <*> getLastLSN) pool
