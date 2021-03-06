{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
module RaftTypes where

import qualified Prelude (log)
import Prelude hiding (log)
import Data.Map (Map)
import qualified Data.Map as Map
import GHC.Generics
import Control.Lens
import Data.Aeson
import Control.Concurrent
import Control.Monad.State
import Control.Monad

import Data.Maybe
import Data.Text.Lazy.Encoding
import qualified Data.Text.Lazy as Text
import qualified Data.ByteString.Lazy as BS

newtype MessageId = MessageId Integer
                  deriving (Eq, Ord, Show, Num, Enum, Generic)
newtype Term = Term Integer
             deriving (Eq, Ord, Show, Num, Enum, Generic)
newtype ServerId = ServerId Integer
                 deriving (Eq, Ord, Show, Num, Enum, Generic)
newtype LogIndex = LogIndex Integer
                 deriving (Eq, Ord, Show, Num, Enum, Generic)

type ServerMap a = Map ServerId a

data Role = Booting | Leader | Follower | Candidate (ServerMap Bool)
          deriving Show

instance Eq Role where
  Leader == Leader = True
  Follower == Follower = True
  (Candidate _) == (Candidate _) = True
  _ == _ = False

type Hostname = String
type Port = Int

data LogEntry a = LogEntry {
  _entryTerm :: Term,
  _entryData :: a
  } deriving (Eq, Show, Generic)
makeLenses ''LogEntry

type IndexedEntry a = (LogIndex, LogEntry a)

data Log a = Log {
  _logEntries :: [LogEntry a]
  } deriving (Eq, Show, Generic)
makeLenses ''Log

logMap :: ([LogEntry a] -> [LogEntry b]) -> Log a -> Log b
logMap f (Log as) = Log (f as)

entry :: LogIndex -> Log a -> Maybe (LogEntry a)
entry (LogIndex nth) (Log es) = es ^? element (fromIntegral nth - 1)

instance ToJSON Term
instance FromJSON Term
instance ToJSON ServerId
instance FromJSON ServerId
instance ToJSON LogIndex
instance FromJSON LogIndex
instance ToJSON a => ToJSON (LogEntry a)
instance FromJSON a => FromJSON (LogEntry a)
instance ToJSON a => ToJSON (Log a)
instance FromJSON a => FromJSON (Log a)

data NilEntry = NilEntry
instance FromJSON NilEntry where
  parseJSON _ = return NilEntry

--- Message types

data MessageType = AppendEntries | AppendEntriesResponse
                 | RequestVote | RequestVoteResponse
                 deriving (Show, Eq, Generic)

isRequest :: MessageType -> Bool
isRequest AppendEntries = True
isRequest RequestVote = True
isRequest _ = False

isResponse :: MessageType -> Bool
isResponse AppendEntriesResponse = True
isResponse RequestVoteResponse = True
isResponse _ = False

data MessageInfo = MessageInfo {
  _msgFrom :: ServerId,
  _msgId :: MessageId
  } deriving (Show, Generic)
makeLenses ''MessageInfo

newtype EncodedArg = EncodedArg BS.ByteString
                     deriving Show
rawArg :: EncodedArg -> BS.ByteString
rawArg (EncodedArg bs) = bs

data Message = Message {
  _msgType :: MessageType,
  _msgArgs :: [(String, EncodedArg)],
  _msgInfo :: MessageInfo
  } deriving (Show, Generic)
makeLenses ''Message

info :: Lens' Message MessageInfo
info = msgInfo

type BaseMessage = MessageInfo -> Message
type PendingMessage c = (c, Message)

instance ToJSON EncodedArg where
   toJSON (EncodedArg bs) = Data.Aeson.String . Text.toStrict . decodeUtf8 $ bs

instance FromJSON EncodedArg where
  parseJSON (Data.Aeson.String txt) = pure . EncodedArg . encodeUtf8 . Text.fromStrict $ txt

instance ToJSON MessageType
instance FromJSON MessageType
instance ToJSON MessageId
instance FromJSON MessageId
instance ToJSON MessageInfo
instance FromJSON MessageInfo
instance ToJSON Message
instance FromJSON Message

--- Config types
data ClientConfig = ClientConfig {
  _clientHostname :: Hostname,
  _clientPort :: Port
  } deriving (Eq, Show, Generic)
makeLenses ''ClientConfig
data CohortConfig = CohortConfig {
  _cohortId :: ServerId,
  _cohortHostname :: Hostname,
  _cohortPort :: Port
  } deriving (Eq, Show, Generic)
makeLenses ''CohortConfig
data ClusterConfig = ClusterConfig {
  _clientConfig :: ClientConfig,
  _clusterServers :: [CohortConfig]
  } deriving (Eq, Show, Generic)
makeLenses ''ClusterConfig

--- Storage types

type PersistentState a = (Term, Maybe ServerId, Log a)


class Persist s where
  writeToStable :: ToJSON a => PersistentState a -> s a -> IO ()
  readFromStable :: FromJSON a => s a -> IO (PersistentState a)

  fromName :: String -> s a

--- Connection types

data OwnFollower = OwnFollower {
  _of_msgQueue :: MVar [Message],
  _of_queueNotEmpty :: MVar ()
  }

{-# NOINLINE newOwnFollower #-}
newOwnFollower :: IO OwnFollower
newOwnFollower = OwnFollower <$> newMVar [] <*> newEmptyMVar

data SelfConnection a = SelfConnection {
  _sc_server :: MVar a,
  _sc_msgQueue :: MVar [Message],
  _sc_queueNotEmpty :: MVar ()
  }

selfConnection :: MVar a -> OwnFollower -> SelfConnection a
selfConnection self (OwnFollower q qFlag) = SelfConnection self q qFlag

--- Server type

data ServerConfig cl s c a = ServerConfig {
  _role :: Role,
  _ownCohort :: CohortConfig,
  _ownFollower :: Maybe OwnFollower,
  _cohorts :: ServerMap c,
  _storage :: s a,
  _client :: cl a
  }
makeLenses ''ServerConfig

data Server cl s c a = Server {
  --- Raft State
  -- Follower state
  _currentTerm :: Term,
  _votedFor :: Maybe ServerId,
  _log :: Log a,
  _commitIndex :: LogIndex,
  _lastApplied :: LogIndex,
  -- Leader-only state
  _nextIndex :: Maybe (ServerMap LogIndex),
  _matchIndex :: Maybe (ServerMap LogIndex),

  --- Non-raft state
  _config :: ServerConfig cl s c a,
  _outstanding :: Map MessageId Message
  }
makeLenses ''Server
serverId :: Lens' (Server cl s c a) ServerId
serverId = config.ownCohort.cohortId

instance Show (ServerConfig cl s c a) where
  show conf = "ServerConfig (" ++ show (view role conf) ++ ") (" ++ show (view ownCohort conf) ++ ")"

instance (Show a) => Show (Server cl s c a) where
  show s = "=== Server " ++ show (view serverId s) ++ " state ===" ++ "\n"
           ++ "currentTerm: " ++ show (view currentTerm s) ++ "\n"
           ++ "votedFor: " ++ show (view votedFor s) ++ "\n"
           ++ "log: " ++ show (view log s) ++ "\n"
           ++ "commitIndex: " ++ show (view commitIndex s) ++ "\n"
           ++ "lastApplied: " ++ show (view lastApplied s) ++ "\n"
           ++ "nextIndex: " ++ showM (view nextIndex s) ++ "\n"
           ++ "matchIndex: " ++ showM (view matchIndex s) ++ "\n"
           ++ "=== end ==="
    where showM Nothing = "___"
          showM (Just x) = show x


type Raft cl s c a v = State (Server cl s c a) v

--- Accessors and helpers

-- State accessors
lastIndex :: Log a -> LogIndex
lastIndex = LogIndex . fromIntegral . length . view logEntries

viewLastLogIndex :: Server cl s c a -> LogIndex
viewLastLogIndex = lastIndex . view log

lastTerm :: Log a -> Term
lastTerm (Log []) = 0
lastTerm (Log es) = view entryTerm (last es)

viewLastLogTerm :: Server cl s c a -> Term
viewLastLogTerm = lastTerm . view log

withIndices :: Log a -> [(LogIndex, LogEntry a)]
withIndices = zip [1..] . view logEntries

logWithIndices :: Server cl s c a -> [(LogIndex, LogEntry a)]
logWithIndices = withIndices . view log

serverCohorts :: Server cl s c a -> [c]
serverCohorts = map snd . Map.toList . view (config.cohorts)

otherCohortIds :: Server cl s c a -> [ServerId]
otherCohortIds = map fst . Map.toList . view (config.cohorts)

termAtIndex :: LogIndex -> Server cl s c a -> Maybe Term
termAtIndex 0 _ = Just 0
termAtIndex i s = entry i (view log s) >>= Just . view entryTerm


-- Storage helpers
defaultPersistentState :: PersistentState e
defaultPersistentState = (0, Nothing, Log [])

injectPersistentState :: PersistentState a -> Server cl s c a  -> Server cl s c a
injectPersistentState (t, v, l) serv = set currentTerm t . set votedFor v . set log l $ serv

extractPersistentState :: Server cl s c a -> PersistentState a
extractPersistentState serv = (view currentTerm serv, view votedFor serv, view log serv)

persist :: (Persist s, ToJSON a) => Server cl s c a -> IO ()
persist serv = writeToStable (extractPersistentState serv) $ view (config.storage) serv

fromPersist :: (Persist s, FromJSON a) => Server cl s c a -> IO (Server cl s c a)
fromPersist serv = readFromStable (view (config.storage) serv) >>= return . flip injectPersistentState serv
