{-| Implementation of the iallocator interface.

-}

module Ganeti.HTools.IAlloc
    (
      parseData
    , formatResponse
    ) where

import Data.Either ()
--import Data.Maybe
import Control.Monad
import Text.JSON (JSObject, JSValue(JSBool, JSString, JSArray),
                  makeObj, encodeStrict, decodeStrict,
                  fromJSObject, toJSString)
--import Text.Printf (printf)
import qualified Ganeti.HTools.Node as Node
import qualified Ganeti.HTools.Instance as Instance
import Ganeti.HTools.Loader
import Ganeti.HTools.Utils
import Ganeti.HTools.Types

data RqType
    = Allocate String Instance.Instance
    | Relocate Int
    deriving (Show)

data Request = Request RqType IdxNode IdxInstance NameList NameList
    deriving (Show)

parseBaseInstance :: String
                  -> JSObject JSValue
                  -> Result (String, Instance.Instance)
parseBaseInstance n a = do
  disk <- case fromObj "disk_usage" a of
            Bad _ -> do
                all_d <- fromObj "disks" a >>= asObjectList
                szd <- mapM (fromObj "size") all_d
                let sze = map (+128) szd
                    szf = (sum sze)::Int
                return szf
            x@(Ok _) -> x
  mem <- fromObj "memory" a
  let running = "running"
  return $ (n, Instance.create n mem disk running 0 0)

parseInstance :: NameAssoc
              -> String
              -> JSObject JSValue
              -> Result (String, Instance.Instance)
parseInstance ktn n a = do
    base <- parseBaseInstance n a
    nodes <- fromObj "nodes" a
    pnode <- readEitherString $ head nodes
    snode <- readEitherString $ (head . tail) nodes
    pidx <- lookupNode ktn n pnode
    sidx <- lookupNode ktn n snode
    return (n, Instance.setBoth (snd base) pidx sidx)

parseNode :: String -> JSObject JSValue -> Result (String, Node.Node)
parseNode n a = do
    let name = n
    mtotal <- fromObj "total_memory" a
    mnode <- fromObj "reserved_memory" a
    mfree <- fromObj "free_memory" a
    dtotal <- fromObj "total_disk" a
    dfree <- fromObj "free_disk" a
    offline <- fromObj "offline" a
    drained <- fromObj "offline" a
    return $ (name, Node.create n mtotal mnode mfree dtotal dfree
                      (offline || drained))

parseData :: String -> Result Request
parseData body = do
  decoded <- fromJResult $ decodeStrict body
  let obj = decoded
  -- request parser
  request <- fromObj "request" obj
  rname <- fromObj "name" request
  -- existing node parsing
  nlist <- fromObj "nodes" obj
  let ndata = fromJSObject nlist
  nobj <- (mapM (\(x,y) -> asJSObject y >>= parseNode x)) ndata
  let (ktn, nl) = assignIndices Node.setIdx nobj
  -- existing instance parsing
  ilist <- fromObj "instances" obj
  let idata = fromJSObject ilist
  iobj <- (mapM (\(x,y) -> asJSObject y >>= parseInstance ktn x)) idata
  let (kti, il) = assignIndices Instance.setIdx iobj
  optype <- fromObj "type" request
  rqtype <-
      case optype of
        "allocate" ->
            do
              inew <- parseBaseInstance rname request
              let (iname, io) = inew
              return $ Allocate iname io
        "relocate" ->
            do
              ridx <- lookupNode kti rname rname
              return $ Relocate ridx
        other -> fail $ ("Invalid request type '" ++ other ++ "'")

  return $ Request rqtype nl il (swapPairs ktn) (swapPairs kti)

formatResponse :: Bool -> String -> [String] -> String
formatResponse success info nodes =
    let
        e_success = ("success", JSBool success)
        e_info = ("info", JSString . toJSString $ info)
        e_nodes = ("nodes", JSArray $ map (JSString . toJSString) nodes)
    in encodeStrict $ makeObj [e_success, e_info, e_nodes]
