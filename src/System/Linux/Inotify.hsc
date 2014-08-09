{-# LANGUAGE ForeignFunctionInterface        #-}
{-# LANGUAGE RecordWildCards, NamedFieldPuns #-}
{-# LANGUAGE BangPatterns, DoAndIfThenElse   #-}
{-# LANGUAGE EmptyDataDecls                  #-}
{-# LANGUAGE DeriveDataTypeable              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving      #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  System.Linux.Inotify
-- Copyright   :  (c) 2013-2014 Leon P Smith
-- License     :  BSD3
--
-- Maintainer  :  leon@melding-monads.com
--
-- Although this module copies portions of inotify's manual page,  it may
-- be useful to consult the original in conjunction with this documentation:
--
-- <http://man7.org/linux/man-pages/man7/inotify.7.html>
--
-----------------------------------------------------------------------------

module System.Linux.Inotify
     ( Inotify
     , Watch(..)
     , Event(..)
     , Mask(..)
     , isect
     , isSubset
     , hasOverlap
     , WatchFlag
     , EventFlag
     , Cookie(..)
     , init
     , close
     , initWith
     , InotifyOptions(..)
     , defaultInotifyOptions
     , addWatch
     , addWatch_
     , rmWatch
     , getEvent
     , getEventNonBlocking
     , getEventFromBuffer
     , peekEvent
     , peekEventNonBlocking
     , peekEventFromBuffer
     , in_ACCESS
     , in_ATTRIB
     , in_CLOSE
     , in_CLOSE_WRITE
     , in_CLOSE_NOWRITE
     , in_CREATE
     , in_DELETE
     , in_DELETE_SELF
     , in_MODIFY
     , in_MOVE_SELF
     , in_MOVE
     , in_MOVED_FROM
     , in_MOVED_TO
     , in_OPEN
     , in_ALL_EVENTS
     , in_DONT_FOLLOW
     , in_EXCL_UNLINK
     , in_MASK_ADD
     , in_ONESHOT
     , in_ONLYDIR
     , in_IGNORED
     , in_ISDIR
     , in_Q_OVERFLOW
     , in_UNMOUNT
     ) where

#include "unistd.h"
#include "sys/inotify.h"

import Prelude hiding (init)

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8
import Control.Applicative
import Data.Monoid
import Data.Typeable
import Data.Function ( on )
import Data.Word
import Control.Concurrent ( threadWaitRead )
import Control.Exception ( throwIO, mask_, onException )
import qualified Control.Exception as E
import GHC.Conc ( closeFdWith )
import GHC.IO.Exception
import Control.Concurrent.MVar
import Control.Monad
import System.Posix
import Data.IORef
import Foreign
import Foreign.C
import qualified Foreign.Concurrent as FC
import System.Posix.ByteString.FilePath (RawFilePath)

import Data.Hashable

-- | 'Inotify' represents an inotify descriptor,  to which watches can be added
--   and events can be read from.   Internally, it also includes a buffer
--   of events that have been delivered to the application from the kernel
--   but haven't been processed.

data Inotify = Inotify
    { fdRef       :: {-# UNPACK #-} !(MVar Fd)
    , bufferLock  :: {-# UNPACK #-} !(MVar ())
    , buffer      :: {-# UNPACK #-} !(ForeignPtr CChar)
    , bufSize     :: {-# UNPACK #-} !Int
    , startRef    :: {-# UNPACK #-} !(IORef Int)
    , endRef      :: {-# UNPACK #-} !(IORef Int)
    } deriving (Eq, Typeable)

instance Show Inotify where
    show Inotify{buffer} = "Inotify { buffer = " ++ show buffer ++ " }"

instance Ord  Inotify where
    compare = compare `on` buffer

{-
-- I'm tempted to define 'Watch' as

data Watch = Watch
    { fd :: {-# UNPACK #-} !Fd
    , wd :: {-# UNPACK #-} !CInt
    }

-- and then give rmWatch the type

rmWatch :: Watch -> IO ()

-- An advantage would be that it would make the API possibly
-- easier to use,  and harder to misuse.   A disadvantage is
-- that this is a slightly thicker wrapper around the system calls,
-- and that storing Watches in Maps would be less efficient, at least
-- somewhat.
-}

-- | 'Watch' represents a watch descriptor,  which is used to identify
--   events and to cancel the watch.  Every watch descriptor is associated
--   with a particular inotify descriptor and can only be
--   used with that descriptor;  incorrect behavior will otherwise result.

newtype Watch = Watch CInt deriving (Eq, Ord, Show, Typeable)

instance Hashable Watch where
   hashWithSalt salt (Watch (CInt x)) = hashWithSalt salt x

-- | Represents the mask,  which in inotify terminology is a union
--   of bit flags representing various event types and watch options.
--
--   The type parameter is a phantom type that tracks whether
--   a particular flag is used to set up a watch ('WatchFlag') or
--   when receiving an event. ('EventFlag')   Polymorphic
--   parameters mean that the flag may appear in either context.

newtype Mask a = Mask Word32 deriving (Eq, Show, Typeable)

-- | Computes the union of two 'Mask's.
instance Monoid (Mask a) where
   mempty = Mask 0
   mappend (Mask a) (Mask b) = Mask (a .|. b)

-- | An empty type used to denote 'Mask' values that can be received
--   from the kernel in an inotify event message.
data EventFlag

-- | An empty type used to denote 'Mask' values that can be sent to
--   the kernel when setting up an inotify watch.
data WatchFlag

-- | Compute the intersection (bitwise and) of two masks
isect :: Mask a -> Mask a -> Mask a
isect (Mask a) (Mask b) = Mask (a .&. b)

-- | Do the two masks have any bits in common?
hasOverlap :: Mask a -> Mask a -> Bool
hasOverlap a b = isect a b /= Mask 0

-- | Are the bits of the first mask a subset of the bits of the second?
isSubset :: Mask a -> Mask a -> Bool
isSubset a b = isect a b == a

-- | File was accessed.  Includes the files of a watched directory.
in_ACCESS :: Mask a
in_ACCESS = Mask (#const IN_ACCESS)

-- | Metadata changed, e.g., permissions,  timestamps, extended  attributes,
--   link  count  (since  Linux 2.6.25), UID, GID, etc.  Includes the files of
--   a watched directory.
in_ATTRIB :: Mask a
in_ATTRIB = Mask (#const IN_ATTRIB)

-- | File was closed.  This is not a separate flag, but a convenience definition
--   such that  'in_CLOSE' '==' 'in_CLOSE_WRITE' '<>' 'in_CLOSE_NOWRITE'
in_CLOSE :: Mask a
in_CLOSE = Mask (#const IN_CLOSE)

-- | File opened for writing was closed.   Includes the files of a watched
--   directory.
in_CLOSE_WRITE :: Mask a
in_CLOSE_WRITE = Mask (#const IN_CLOSE_WRITE)

-- | File not opened for writing was closed.  Includes the files of a watched
--   directory.
in_CLOSE_NOWRITE :: Mask a
in_CLOSE_NOWRITE = Mask (#const IN_CLOSE_NOWRITE)

-- | File/directory created in watched directory.
in_CREATE :: Mask a
in_CREATE = Mask (#const IN_CREATE)

-- | File/directory  deleted  from  watched  directory.
in_DELETE :: Mask a
in_DELETE = Mask (#const IN_DELETE)

-- | Watched file/directory was itself deleted.
in_DELETE_SELF :: Mask a
in_DELETE_SELF = Mask (#const IN_DELETE_SELF)

-- | File was modified.  Includes the files of a watched
--   directory.
in_MODIFY :: Mask a
in_MODIFY = Mask (#const IN_MODIFY)

-- | Watched file/directory was itself moved.
in_MOVE_SELF :: Mask a
in_MOVE_SELF = Mask (#const IN_MOVE_SELF)

-- | File was moved.  This is not a separate flag, but a convenience definition
--   such that  'in_MOVE' '==' 'in_MOVED_FROM' '<>' 'in_MOVED_TO'.
in_MOVE :: Mask a
in_MOVE = Mask (#const IN_MOVE)

-- | File moved out of watched directory. Includes the files of a watched
--   directory.
in_MOVED_FROM :: Mask a
in_MOVED_FROM = Mask (#const IN_MOVED_FROM)

-- | File moved into watched directory. Includes the files of a watched
--   directory.
in_MOVED_TO :: Mask a
in_MOVED_TO = Mask (#const IN_MOVED_TO)

-- | File was opened.  Includes the files of a watched
--   directory.
in_OPEN :: Mask a
in_OPEN = Mask (#const IN_OPEN)

-- | A union of all flags above;  this is not a separate flag but a convenience
--   definition.
in_ALL_EVENTS :: Mask a
in_ALL_EVENTS = Mask (#const IN_ALL_EVENTS)

-- | (since Linux 2.6.15) Don't  dereference  pathname  if it is a symbolic link.
in_DONT_FOLLOW :: Mask WatchFlag
in_DONT_FOLLOW = Mask (#const IN_DONT_FOLLOW)

-- | (since Linux 2.6.36)
--      By default, when watching events on the  children
--      of a directory, events are generated for children
--      even after  they  have  been  unlinked  from  the
--      directory.   This  can result in large numbers of
--      uninteresting events for some applications (e.g.,
--      if watching /tmp, in which many applications create
--      temporary files whose names  are  immediately
--      unlinked).  Specifying IN_EXCL_UNLINK changes the
--      default behavior, so that events are  not  generated
--      for  children after they have been unlinked
--      from the watched directory.
in_EXCL_UNLINK :: Mask WatchFlag
in_EXCL_UNLINK = Mask (#const IN_EXCL_UNLINK)

-- | Add (OR) events to watch mask for  this  pathname
--   if it already exists (instead of replacing mask).
in_MASK_ADD :: Mask WatchFlag
in_MASK_ADD = Mask (#const IN_MASK_ADD)

-- | Monitor pathname for one event, then remove from watch list.
in_ONESHOT :: Mask WatchFlag
in_ONESHOT = Mask (#const IN_ONESHOT)

-- | (since Linux 2.6.15) Only watch pathname if it is a directory.
in_ONLYDIR :: Mask WatchFlag
in_ONLYDIR = Mask (#const IN_ONLYDIR)

-- | Watch was removed explicitly ('rmWatch') or automatically
--   (file was deleted, or file system was unmounted).
in_IGNORED :: Mask EventFlag
in_IGNORED = Mask (#const IN_IGNORED)

-- | Subject of this event is a directory.
in_ISDIR :: Mask EventFlag
in_ISDIR = Mask (#const IN_ISDIR)

-- | Event queue overflowed (wd is -1 for this event).  The size of the
--   queue is available at @/proc/sys/fs/inotify/max_queued_events@.
in_Q_OVERFLOW :: Mask EventFlag
in_Q_OVERFLOW = Mask (#const IN_Q_OVERFLOW)

-- | File system containing watched object was unmounted.
in_UNMOUNT :: Mask EventFlag
in_UNMOUNT = Mask (#const IN_UNMOUNT)

-- | A newtype wrapper for the 'cookie' field of the 'Event'.

newtype Cookie = Cookie Word32 deriving (Eq, Ord, Show, Typeable, Hashable)

data Event = Event
   { wd     :: {-# UNPACK #-} !Watch
     -- ^ Identifies the watch for which this event occurs.  It is one of  the
     --   watch descriptors returned by a previous call to 'addWatch' or
     --   'addWatch_'.
   , mask   :: {-# UNPACK #-} !(Mask EventFlag)
     -- ^ contains bits that describe the event that occurred
   , cookie :: {-# UNPACK #-} !Cookie
     -- ^ A unique integer that connects related events.  Currently this is
     --   only used for rename events, and allows the resulting pair of
     --   'in_MOVE_FROM' and 'in_MOVE_TO' events to be connected by the
     --   application.
   , name   :: {-# UNPACK #-} !B.ByteString
     -- ^ The name field is only present when an event is returned for a file
     --   inside a watched directory; it identifies the file pathname relative
     --   to the watched directory.
     --
     --   The proper Haskell interpretation of this seems to be to use
     --   'GHC.IO.getFileSystemEncoding' and then unpack it to a 'String'
     --   or decode it using the text package.
   } deriving (Eq, Show, Typeable)

-- | Creates an inotify socket descriptor that watches can be
--   added to and events can be read from.

init :: IO Inotify
init = initWith defaultInotifyOptions

-- | Additional configuration options for creating an Inotify descriptor.

newtype InotifyOptions = InotifyOptions {
      bufferSize :: Int -- ^ The size of the buffer used to receive events from
                        --   the kernel.   This is an artifact of this binding,
                        --   not inotify itself.
    }

-- | Default configuration options

defaultInotifyOptions :: InotifyOptions
defaultInotifyOptions = InotifyOptions { bufferSize = 2048 }

-- | Creates an inotify socket descriptor with custom configuration options.
--   Calls @inotify_init1(IN_NONBLOCK | IN_CLOEXEC)@.

initWith :: InotifyOptions -> IO Inotify
initWith InotifyOptions{..} = do
    fd <- Fd <$> throwErrnoIfMinus1 "System.Linux.Inotify.initWith"
                   (c_inotify_init1 flags)
    fdRef <- newMVar fd
    bufferLock <- newMVar ()
    let bufSize = bufferSize
    buffer   <- mallocForeignPtrBytes bufSize
    startRef <- newIORef 0
    endRef   <- newIORef 0
    let !inotify = Inotify{..}
    FC.addForeignPtrFinalizer buffer (close inotify)
    return inotify
  where flags = (#const IN_NONBLOCK) .|. (#const IN_CLOEXEC)

-- | Adds a watch on the inotify descriptor,  returns a watch descriptor.
--   The mask controls which events are delivered to your application,
--   as well as some additional options.

addWatch :: Inotify -> FilePath -> Mask WatchFlag -> IO Watch
addWatch Inotify{fdRef} path !mask = do
    withCString path $ \cpath -> do
      withFd fdRef (throwIO $! fdClosed funcName) $ \fd -> do
        Watch <$> throwErrnoPathIfMinus1 funcName path
                  (c_inotify_add_watch fd cpath mask)
  where funcName = "System.Linux.Inotify.addWatch"

-- | A variant of 'addWatch' that operates on a 'RawFilePath', which is
-- a file path represented as strict 'ByteString'.   One weakness of the
-- current implementation is that if 'addWatch_' throws an 'IOException',
-- then any unicode paths will be mangled in the error message.

addWatch_ :: Inotify -> RawFilePath -> Mask WatchFlag -> IO Watch
addWatch_ Inotify{fdRef} path !mask = do
    B.useAsCString path $ \cpath -> do
      withFd fdRef (throwIO $! fdClosed funcName) $ \fd -> do
        Watch <$> throwErrnoPathIfMinus1 funcName (B8.unpack path)
                  (c_inotify_add_watch fd cpath mask)
  where funcName = "System.Linux.Inotify.addWatch_"


-- | Stops watching a path for changes.  This watch descriptor must be
--   associated with the particular inotify port,  otherwise undefined
--   behavior can happen.
--
--   This binding ignores @inotify_rm_watch@'s errno when it is @EINVAL@,\
--   so it is ok to delete a previously removed watch descriptor.
--
--   However long lived applications that set and remove many watches
--   should still endeavor to avoid calling `rmWatch` on removed
--   watch descriptors,  due to possible wrap-around bugs.

--   The (small) downside to this behavior is that it also ignores the
--   case when,  for some slightly strange reason, 'rmWatch' is called
--   on a file descriptor that is not an inotify descriptor.
--   Unfortunately @inotify_rm_watch@ does not provide any way to
--   distinguish these cases.
--
--   Haskell's type system should prevent this from happening in almost
--   all cases.

rmWatch :: Inotify -> Watch -> IO ()
rmWatch Inotify{fdRef} !wd = do
  withFd fdRef (return ()) $ \fd -> do
    res <- c_inotify_rm_watch fd wd
    when (res == -1) $ do
      err <- getErrno
      if err == eINVAL
      then return ()
      else throwErrno funcName
  where funcName = "System.Linux.Inotify.rmWatch"
{--
-- | Stops watching a path for changes.  This version throws an exception
--   on @EINVAL@,  so it is not ok to delete a non-existant watch
--   descriptor.   Therefore this function is not thread safe,  even
--   if it's only ever called from a single thread.
--
--   The problem is that in some cases the kernel will automatically
--   delete a watch descriptor.  Although the kernel generates an
--   @IN_IGNORED@ event whenever a descriptor is deleted,  it's
--   possible that using @rmWatch'@ and @getEvent@ in different threads
--   would delete the descriptor after the kernel has delivered the
--   @IN_IGNORED@ event but before your application has acted on the
--   message.
--
--   It may not even be safe to call this function from the thread
--   that is calling @getEvent@.  I need to investigate whether or
--   not the kernel would return @EINVAL@ on a descriptor before
--   the @IN_IGNORED@ message has been delivered to your application.
--   This would make rmWatch' somewhat safer in the presence of threads,
--   but the application would still have to ensure that all delivered
--   events are processed before rmWatch' is called.

rmWatch' :: Inotify -> Watch -> IO ()
rmWatch' (Inotify (Fd !fd)) (Watch !wd) = do
    throwErrnoIfMinus1_ "System.Linux.Inotify.rmWatch'" $
      c_inotify_rm_watch fd wd
--}

-- | Returns an inotify event,  blocking until one is available.
--
--   If the inotify descriptor is closed,  this function will return
--   an event from the buffer, if available.   Otherwise,  it will
--   throw an 'IOException'.

getEvent :: Inotify -> IO Event
getEvent inotify@Inotify{..} =
    fillBufferBlocking inotify "System.Linux.Inotify.getEvent" $ do
        getMessage True inotify

-- | Returns an inotify event,  blocking until one is available.
--
--   After this returns an event, the next read from the inotify
--   descriptor will return the same event.  This read will not
--   result in a system call.
--
--   If the inotify descriptor is closed,  this function will return
--   an event from the buffer, if available.   Otherwise,  it will
--   throw an 'IOError'.

peekEvent :: Inotify -> IO Event
peekEvent inotify@Inotify{..} =
    fillBufferBlocking inotify "System.Linux.Inotify.peekEvent" $ do
        getMessage False inotify

hasEmptyBuffer :: Inotify -> IO Bool
hasEmptyBuffer Inotify{..} = do
    start <- readIORef startRef
    end   <- readIORef endRef
    return $! (start >= end)
{-# INLINE hasEmptyBuffer #-}

fillBuffer :: Inotify -> IO a -> IO a -> (Errno -> IO a) -> IO a
fillBuffer Inotify{..} action closedHandler errorHandler =
  E.mask $ \restore -> do
    numBytes <- withFd fdRef (return (-2)) $ \fd -> do
                    withForeignPtr buffer $ \ptr -> do
                        c_unsafe_read fd ptr (fromIntegral bufSize)
    if numBytes < 0
    then if numBytes == -1
         then getErrno >>= errorHandler
         else closedHandler
    else do
        writeIORef startRef 0
        writeIORef endRef (fromIntegral numBytes)
        restore action
{-# INLINE fillBuffer #-}

fillBufferBlocking :: Inotify -> String -> IO a -> IO a
fillBufferBlocking inotify@Inotify{..} funcName action =
    join $ withLock bufferLock $ do
      isEmpty <- hasEmptyBuffer inotify
      if isEmpty
      then haveLock
      else action'
  where
    action' = action >>= return . return

    haveLock = do
      fillBuffer inotify action' (throwIO $! fdClosed funcName) $ \err -> do
          if err == eAGAIN || err == eWOULDBLOCK
          then return (waitFd >> needLock)
          else if err == eINTR
               then haveLock
               else throwErrno funcName

    needLock = join $ withLock bufferLock $ haveLock

    -- FIXME: We probably need to read the MVar and wait on the fd atomically.
    --
    --   (But we don't want to hold the MVar while waiting on the fd,
    --    otherwise we'd cause close and *EventNonBlocking to block!)
    --
    --   It seems like it would be possible for this thread to read the fd,
    --   then for other threads to close the fd and then allocate a new fd,
    --   and then for this thread to wait on that newly allocated fd.
    --
    --   This should be a _relatively_ harmless condition in this particular
    --   context,  as the MVar will be re-read before we try to actually
    --   read anything from the Fd,  which will result in an exception.
    --   However, this could lead to a deadlock or near-deadlock state,
    --   where we are blocked on a new descriptor that isn't going to
    --   become readable in a timely fashion when we really should be
    --   throwing an exception immediately.
    waitFd = do
      fd <- readMVar fdRef
      if fd >= 0
      then threadWaitRead fd
      else throwIO $! fdClosed funcName

fillBufferNonBlocking :: Inotify -> String -> IO Bool
fillBufferNonBlocking inotify@Inotify{..} funcName = do
    isEmpty <- hasEmptyBuffer inotify
    if isEmpty
    then loop
    else return False
  where
    loop = do
      fillBuffer inotify (return False) (return True) $ \err -> do
          if err == eAGAIN || err == eWOULDBLOCK
          then return True
          else if err == eINTR
               then loop
               else throwErrno funcName

getMessage :: Bool -> Inotify -> IO Event
getMessage doConsume Inotify{..} = withForeignPtr buffer $ \ptr0 -> do
  start  <- readIORef startRef
  let ptr = ptr0 `plusPtr` start
  wd     <- Watch  <$> ((#peek struct inotify_event, wd    ) ptr :: IO CInt)
  mask   <- Mask   <$> ((#peek struct inotify_event, mask  ) ptr :: IO Word32)
  cookie <- Cookie <$> ((#peek struct inotify_event, cookie) ptr :: IO Word32)
  len    <-            ((#peek struct inotify_event, len   ) ptr :: IO Word32)
  name <- if len == 0
            then return B.empty
            else B.packCString ((#ptr struct inotify_event, name) ptr)
  when doConsume $ writeIORef startRef $!
                       start + (#size struct inotify_event) + fromIntegral len
  return $! Event{..}
{-# INLINE getMessage #-}

-- | Returns an inotify event only if one is immediately available.
--
--   If the inotify descriptor is closed,  this function will return
--   an event from the buffer, if available.   Otherwise,  it will
--   return 'Nothing'.
--
--   One possible downside of the current implementation is that
--   returning 'Nothing' necessarily results in a system call,  unless
--   the inotify descriptor has been closed.

getEventNonBlocking :: Inotify -> IO (Maybe Event)
getEventNonBlocking inotify@Inotify{..} = do
  withLock bufferLock $ do
    isEmpty <- fillBufferNonBlocking inotify funcName
    if isEmpty
    then return Nothing
    else do
      evt <- getMessage True inotify
      return $! Just evt
  where
    funcName = "System.Linux.Inotify.getEventNonBlocking"

-- | Returns an inotify event only if one is immediately available.
--
--   If this returns an event, then the next read from the inotify
--   descriptor will return the same event, and this read will
--   not result in a system call.
--
--   If the inotify descriptor is closed,  this function will return
--   an event from the buffer, if available.   Otherwise,  it will
--   return 'Nothing'.
--
--   One possible downside of the current implementation is that
--   returning 'Nothing' necessarily results in a system call,
--   unless the inotify descriptor has been closed.

peekEventNonBlocking :: Inotify -> IO (Maybe Event)
peekEventNonBlocking inotify@Inotify{..} = do
  withLock bufferLock $ do
    isEmpty <- fillBufferNonBlocking inotify funcName
    if isEmpty
    then return Nothing
    else do
      evt <- getMessage False inotify
      return $! Just evt
  where
    funcName = "System.Linux.Inotify.peekEventNonBlocking"

-- | Returns an inotify event only if one is available in 'Inotify's
--   buffer.  This won't ever make a system call.

getEventFromBuffer :: Inotify -> IO (Maybe Event)
getEventFromBuffer inotify@Inotify{bufferLock} = do
  withLock bufferLock $ do
    isEmpty <- hasEmptyBuffer inotify
    if isEmpty
    then return Nothing
    else do
       evt <- getMessage True inotify
       return $! Just evt

-- | Returns an inotify event only if one is available in 'Inotify's
--   buffer.  This won't ever make a system call.
--
--   If this returns an event, then the next read from the inotify
--   descriptor will return the same event,  and this read will not
--   result in a system call.

peekEventFromBuffer :: Inotify -> IO (Maybe Event)
peekEventFromBuffer inotify@Inotify{..} = do
  withLock bufferLock $ do
    isEmpty <- hasEmptyBuffer inotify
    if isEmpty
    then return Nothing
    else do
       evt <- getMessage False inotify
       return $! Just evt

-- | Closes an inotify descriptor,  freeing the resources associated
-- with it.  This will also raise an 'IOException' in any threads that
-- are blocked on 'getEvent'.
--
-- It is safe to attempt to use an inotify descriptor after it has been
-- closed:  this will result in an 'IOException', a no-op,  or a 'Nothing'
-- result as appropriate.
--
-- Descriptors will be closed after they are garbage collected, via
-- a finalizer,  although it is often preferable to call 'close' yourself.

close :: Inotify -> IO ()
close Inotify{..} = mask_ $ do
  fd <- swapMVar fdRef (-1)
  if fd >= 0
  then closeFdWith closeFd fd
  else return ()

withFd :: MVar Fd -> IO a -> (Fd -> IO a) -> IO a
withFd fdRef closed action =
    withMVar fdRef $ \fd ->
        if fd >= 0
        then action fd
        else closed
{-# INLINE withFd #-}

fdClosed :: String -> IOException
fdClosed funcName
    = IOError {
        ioe_handle      = Nothing,
        ioe_type        = IllegalOperation,
        ioe_location    = funcName,
        ioe_description = "handle is closed",
        ioe_errno       = Nothing,
        ioe_filename    = Nothing
      }

{-# INLINE withLock #-}
withLock :: MVar () -> IO b -> IO b
withLock m io =
  mask_ $ do
    _ <- takeMVar m
    b <- io `onException` putMVar m ()
    putMVar m ()
    return b

foreign import ccall unsafe "sys/inotify.h inotify_init1"
    c_inotify_init1 :: CInt -> IO CInt

foreign import ccall unsafe "sys/inotify.h inotify_add_watch"
    c_inotify_add_watch :: Fd -> CString -> Mask WatchFlag -> IO CInt

foreign import ccall unsafe "sys/inotify.h inotify_rm_watch"
    c_inotify_rm_watch :: Fd -> Watch -> IO CInt

foreign import ccall unsafe "unistd.h read"
    c_unsafe_read :: Fd -> Ptr CChar -> CSize -> IO CSsize
