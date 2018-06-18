# Multipool - Generalized machinery for replicated systems
![Multipass](https://i.gifer.com/39uY.gif)

Multipool lets you manage connections for multiple masters and/or read
replicas in Haskell via a unified interface.

## Currently supported backends

`persistent-postgresql` is supported via the `multipool-persistent` and
`multipool-persistent-postgresql` packages.

## Example

```haskell
import Database.Persist
-- from postgresql-common-persistent
import Database.Persist.Postgresql.Common
-- from multipool-persistent-postgresql
import Data.MultiPool.Persist.Postgresql

share [mkPersist sqlSettings, mkMigrate "migrateAll"] [persistLowerCase|
User
    name String
    lastLsn LSN Maybe default=pg_current_wal_lsn()
    deriving Show
|]

doSomeQueries :: IO ()
doSomeQueries = do
  let masterConn = "host=localhost port=5432 user=postgres"
      replicaConn = "host=localhost port=5433 user=postgres"
  mp <- runNoLoggingT $ initMultiPool connStr 1 [(mkInstanceName "replica", connStr, 1)]

  user <- runWriteAny mp $ do
    migrateAll
    k <- insert $ User "bob" Nothing
    getJust k

  -- We got us a user.
  print r

  -- At this point maybe the user row has replicated... Or maybe not? Can't say for sure...
  mr <- runReadAny mp $ get userK
  print mr

  -- Just a little time to let replication happen...
  threadDelay 50000

  -- Get current replication status for each replica.
  -- In real-world implementations, there would be a background
  -- thread or something of the sort periodically updating an IORef
  -- or other caching mechanism.
  replicationStatusByReplica <- gatherLSNs b
  replicatedUser <- runReadCurrent mp replicationStatusByReplica (userLastLsn $ entityVal u) $ getJust (entityKey u)
  -- This always should be @Just user@ since we are only selecting from sufficiently replicated sources (or master as a fallback if no replicated sources exist.)
  print replicatedUser
```
