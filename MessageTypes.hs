{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
module MessageTypes where
import qualified Prelude (log)
import Prelude hiding (log)
import Data.Map as Map
import GHC.Generics
import Control.Lens
import Data.Aeson
import Control.Monad
import Data.List
import Data.ByteString.Lazy.Internal (ByteString)

import RaftTypes

data MessageType = AppendEntries | AppendEntriesResponse
                 | RequestVote | RequestVoteResponse
                 deriving Show

data MessageInfo = MessageInfo {
  _msgFrom :: ServerId,
  _msgId :: MessageId
  } deriving Show
makeLenses ''MessageInfo

data Message = Message {
  _msgType :: MessageType,
  _msgArgs :: [(String, ByteString)],
  _msgInfo :: MessageInfo
  } deriving Show
makeLenses ''Message

info :: Lens' Message MessageInfo
info = msgInfo

type BaseMessage = MessageInfo -> Message


extract :: FromJSON a => String -> Message -> Maybe a
extract name msg = find (\(s, _) -> s == name) (view msgArgs msg) >>= (decode . snd)

kTerm = "term"
kLeaderId = "leaderId"
kPrevLogIndex = "prevLogIndex"
kPrevLogTerm = "prevLogTerm"
kEntries = "entries"
kLeaderCommit = "leaderCommit"

kSuccess = "success"

kCandidateId = "candidateId"
kLastLogIndex = "lastLogIndex"
kLastLogTerm = "lastLogTerm"

kVoteGranted = "voteGranted"


term :: Message -> Maybe Term
term = extract kTerm
leaderId :: Message -> Maybe ServerId
leaderId = extract kLeaderId
prevLogIndex :: Message -> Maybe LogIndex
prevLogIndex = extract kPrevLogIndex
prevLogTerm :: Message -> Maybe Term
prevLogTerm = extract kPrevLogTerm
entries :: FromJSON e => Message -> Maybe [(LogIndex, LogEntry e)]
entries = extract kEntries
leaderCommit :: Message -> Maybe LogIndex
leaderCommit = extract kLeaderCommit

success :: Message -> Maybe Bool
success = extract kSuccess

candidateId :: Message -> Maybe ServerId
candidateId = extract kCandidateId
lastLogIndex :: Message -> Maybe LogIndex
lastLogIndex = extract kLastLogIndex
lastLogTerm :: Message -> Maybe Term
lastLogTerm = extract kLastLogTerm

voteGranted :: Message -> Maybe Bool
voteGranted = extract kVoteGranted


appendEntries :: ToJSON e => Term -> ServerId -> LogIndex -> Term -> [(LogIndex, LogEntry e)] -> LogIndex -> BaseMessage
appendEntries t lid pli plt es lc = Message AppendEntries [
  (kTerm, encode t),
  (kLeaderId, encode lid),
  (kPrevLogIndex, encode pli),
  (kPrevLogTerm, encode plt),
  (kEntries, encode es),
  (kLeaderCommit, encode lc)
  ]

appendEntriesResponse :: Term -> Bool -> BaseMessage
appendEntriesResponse t s = Message AppendEntriesResponse [
  (kTerm, encode t),
  (kSuccess, encode s)
  ]

requestVote :: Term -> ServerId -> LogIndex -> Term -> BaseMessage
requestVote t cid lli llt = Message RequestVote [
  (kTerm, encode t),
  (kCandidateId, encode cid),
  (kLastLogIndex, encode lli),
  (kLastLogTerm, encode llt)
  ]

requestVoteResponse :: Term -> Bool -> BaseMessage
requestVoteResponse t vg = Message RequestVoteResponse [
  (kTerm, encode t),
  (kVoteGranted, encode vg)
  ]

-- data AppendEntries e = AppendEntries {
--   _ae_term :: Term,
--   _leaderId :: ServerId,
--   _prevLogIndex :: LogIndex,
--   _prevLogTerm :: Term,
--   _entries :: [(LogIndex, LogEntry e)],
--   _leaderCommit :: LogIndex
--   }

-- data AppendEntriesResult = AppendEntriesResult {
--   _aer_term :: Term,
--   _success :: Bool
--   }
-- makeLenses ''AppendEntriesResult

-- data RequestVote = RequestVote {
--   _rv_term :: Term,
--   _candidateId :: ServerId,
--   _lastLogIndex :: LogIndex,
--   _lastLogTerm :: Term
--   }
-- makeLenses ''RequestVote

-- data RequestVoteResult = RequestVoteResult {
--   _rvr_term :: Term,
--   _voteGranted :: Bool
--   }
-- makeLenses ''RequestVoteResult

-- main :: IO()
-- main = do
--   let m = pure $ appendEntriesResponse 6 True :: RPC Message
--   let m' = m >>= NextResponse m >> NextRequest m >> NextResponse m
--   print m'
