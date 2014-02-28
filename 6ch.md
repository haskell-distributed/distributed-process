---
layout: tutorial
sections: ['Introduction', 'Unexpected Messages', 'Hiding Implementation Details', 'Using Typed Channels']
categories: tutorial
title: Advanced Managed Processes
---

### Introduction

In this tutorial, we will look at some advanced ways of programming Cloud Haskell
using the managed process API.

### Unexpected Messages

The process definition's [`UnhandledMessagePolicy`][policy] provides a way for
processes to respond to unexpected inputs. This proves surprisingly important,
since it is always possible for messages to unexpectedly arrive in a process'
mailbox, either those which do not match the server's expected types or which
fail one or more match conditions against the message body.

As we will see shortly, there are various ways to ensure that only certain
messages (i.e., types) are sent to a process, but in the presense of monitoring
and other system management facilities and since the node controller is
responsible - both conceptually and by implementation - for dispatching messages
to each process' mailbox, it is impractical to make real guarantees about a
process' total input domain. Such policies are best enforced with session types,
which is part of the Cloud Haskell roadmap, but unconnected to managed processes.

During development, the handy `Log` option will write an info message to the
[_SystemLog_][3] with information about unexpected inputs (including type info),
whilst in production, the obvious choice is between the silent `Drop` and its
explosive sibling, `Terminate`. Since in Cloud Haskell's open messaging architecture,
it is impossible to guarantee against unexpected messages (even in the presence
 of advanced protocol enforcement tools such as session types), whichever option
is chosen, the server must have some policy for dealing with unexpected messages.

------
> ![Warning: ][alert] Watch out for unhandled deliveries, especially when using
> the `Drop` policy. In particular, unhandled message _types_ are a common cause
> of application failure and when servers discard messages without notifying their
> clients, deadlocks will quickly ensue!
------

### Hiding Implementation Details

Whilst there is nothing to stop clients from sending messages directly to a
managed process, there are ways to avoid this (in most cases) by hiding our
`ProcessId`, either behind a _newtype_ or some other opaque data structure).
The author of the server is then able to force clients through API calls that
can enforce the required types _and_ ensure that the correct client-server
protocol is used.

In its simplest guise, this technique simply employs the compiler to ensure
that our clients only communicate with us in well-known ways. Let's take a
look at this in action, revisiting the well-trodden _math server_ example
from our previous tutorials:

{% highlight haskell %}
module MathServer 
  ( -- client facing API
    MathServer()
  , add
    -- starting/spawning the server process
  , launchMathServer
  ) where

import .... -- elided

newtype MathServer = MathServer { mathServerPid :: ProcessId }
  deriving (Typeable)

-- other types/details elided

add :: MathServer -> Double -> Double -> Process Double
add MathServer{..} = call mathServerPid . Add

launchMathServer :: Process MathServer
launchMathServer = launch >>= return . MathServer
  where launch =
    let server = statelessProcess {
      apiHandlers = [ handleCall_ (\(Add x y) -> return (x + y)) ]
    , unhandledMessagePolicy = Drop
    }
    in spawnLocal $ start () (statelessInit Infinity) server >> return ()
{% endhighlight %}

What we've changed here is the _handle_ clients use to communicate with the
process, hiding the `ProcessId` behind a newtype and forcing client code to
use the `MathServer` handle to call our API functions. Since the `MathServer`
newtype wraps a `ProcessId`, it is `Serializable` and can be sent to remote
clients if needed.

------
> ![Warning: ][alert] Note that we _still_ cannot assume that no _info messages_
> will arrive in our mailbox, since it is _impossible_ to guarantee our `ProcessId`
> will remain private due to the presence of the [management][mgmt] and
> [tracing/debugging][dbg] APIs in distributed-process. Servers that use the
> distributed-process monitoring APIs, must also be prepared to deal with monitor
> signals (such as the ubiquitous `ProcessMonitorNotification`) arriving as _info
> messages_, since these are always dispatched directly to our mailbox via the
> node controller.
------

Another reason to use a _server handle_ like this, instead of a raw `ProcessId`,
is to ensure type compatibility between client and server, in cases where the
server has been written to generically deal with various types whilst the client
needs to reify its calls/casts over a specific type. To demonstrate this
approach, we'll consider the [`Registry`][1] module, which provides an enhanced
_process registry_ that provides name registration services and also behaves
like a per-process, global key-value store.

Each `Registry` server deals with specific types of keys and values. Allowing
clients to send and receive instructions pertaining to a registry server without
knowing the exact types the server was _spawned_ to handle, is a recipe for
disaster, since the client is very likely to block indefinitely if the expected
request types don't match up, since the server will ignore them.
We can alleviate this problem using phantom type parameters, storing only
the real `ProcessId` we need to communicate with the server, whilst utilising
the compiler to ensure the correct types are assumed at both ends.

{% highlight haskell %}
data Registry k v = Registry { registryPid :: ProcessId }
  deriving (Typeable, Generic, Show, Eq)
instance (Keyable k, Serializable v) => Binary (Registry k v) where
{% endhighlight %}

In order to start our registry, we need to know the specific `k` and `v` types,
but we do not real values of these, so we use scoped type variables to reify
them when creating the `Registry` handle:

{% highlight haskell %}
start :: forall k v. (Keyable k, Serializable v) => Process (Registry k v)
start = return . Registry =<< spawnLocal (run (undefined :: Registry k v))

run :: forall k v. (Keyable k, Serializable v) => Registry k v -> Process ()
run _ =
  MP.pserve () (const $ return $ InitOk initState Infinity) serverDefinition
  -- etc....
{% endhighlight %}

Having wrapped the `ProcessId` in a newtype that ensures the types with which
the server was initialised are respected by clients, we use the same approach
as earlier to force clients of our API to interact with the server not only
using the requisite call/cast protocol, but also providing the correct types
in the form of a valid handle.

{% highlight haskell %}
addProperty :: (Keyable k, Serializable v)
            => Registry k v -> k -> v -> Process RegisterKeyReply
addProperty reg k v = ....
{% endhighlight %}

So long as we only expose `Registry` newtype construction via our `start` API,
clients cannot forge a registry handle and both client and server can rely on
the compiler to have enforced the correct types for all our interactions.

------
> ![Info: ][info] Forcing users to interact with your process via an opaque
> handle is a good habbit to get into, as is hiding the `ProcessId` where
> possible. Use phantom types along with these _server handles_, to ensure
> clients do not send unexpected data to the server.
------

Of course, you might actually _need_ the server's `ProcessId` sometimes,
perhaps for monitoring, name registration or similar schemes that operate
explicitly on a `ProcessId`. It is also common to _need_ support for sending
info messages. Some APIs are built on "plain old messaging" via `send` and
therefore completely hiding your `ProcessId` becomes the right way to expose
an API to your clients, but the wrong way to expose your process to other APIs
it is utilising.

In these situations, the [`Resolvable`][rsbl] and [`Routable`][rtbl] typeclasses
are your friend. By providing a `Resolvable` instance, you can expose your
`ProcessId` to peers that really need it, whilst documenting (via the design
decision to only expose the `ProcessId` via a typeclass) the need to use the
handle in client code.

{% highlight haskell %}
instance Resolvable (Registry k v) where
  resolve = return . Just . registryPid
{% endhighlight %}

The [`Routable`][rtbl] typeclass provides a means to dispatch messages without
having to know the implementation details behind the scenes. This provides us
with a means for APIs that need to send messages directly to our process to do
so via the opaque handle, without us exposing the `ProcessId` to them directly.
(Of course, such APIs have to be written with [`Routable`][rtbl] in mind!)

There is a default (and fairly efficient) instance of [`Routable`][rtbl] for all
[`Resolvable`][rsbl] instances, so it is usually enough to implement the latter.
An explicit implementation for our `Registry` would look like this:

{% highlight haskell %}
instance Routable (Registry k v) where
  sendTo       reg msg = send (registryPid reg) msg
  unsafeSendTo reg msg = unsafeSend (registryPid reg) msg
{% endhighlight %}

Similar typeclasses are provided for the many occaisions when you need to link
to or kill a process without knowing its `ProcessId`:

{% highlight haskell %}
class Linkable a where
  -- | Create a /link/ with the supplied object.
  linkTo :: a -> Process ()

class Killable a where
  killProc :: a -> String -> Process ()
  exitProc :: (Serializable m) => a -> m -> Process ()
{% endhighlight %}

Again, there are default instances of both typeclasses for all [`Resolvable`][rsbl]
types, so it is enough to provide just that instance for your handles.

### Using Typed Channels

Typed Channels can be used in two ways via the managed process API, either as
inputs to the server or as a _reply channel_ for RPC style interactions that
offer an alternative to using `call`.

#### Reply Channels

When using the `call` API, the server can reply  with a datum that doesn't
match the type(s) the client expects. This will cause the client to either
deadlock or timeout, depending on which variant of `call` was used. This isn't
usually a problem, since the server author also writes the client facing API(s)
and can therefore carefully check that the correct types are being returned.
That's still potentially error prone however, and using a `SendPort` as a reply
channel can make it easier to spot potential type discrepancies.

The machinery behind _reply channels_ is very simple: We create a new channel
for the reply and pass the `SendPort` to the server along with our input message.
The server is responsible for sending its reply to the given `SendPort` and the
corresponding `ReceivePort` is returned so the caller can wait on it. For course,
if no corresponding handler is present in the server definition, there may be no
reply (and depending on the server's `unhandledMessagePolicy`, we may crash the
server).

------
> ![Warning: ][alert] Using typed _reply channels_ does not guarantee against
> type mismatches! The server might not recognise the message type or the type
> of the reply channel, in which case the message will be considered an _unhandled_
> input and dealt with accordingly.
------

Typed channels are better suited to handling deferred client-server RPC calls
than plain inter-process messaging too. The only non-blocking `call` API is based
on [`Async`][2] and its only failure mode is an `AsyncFailed` result containing
a corresponding `ExitReason`. The `callTimeout` API is equally limited, since
once its delay is exceeded (and the call times out), you cannot subsequently
retry listening for the message - the client is on its own at this point, and
has to deal with potentially stray (and un-ordered!) replies using the low
level `flushPendingCalls` API. By using a typed channel for replies, we can avoid
both these issues since after the RPC is initiated, the client can defer obtaining
a reply from the `ReceivePort` until it's ready, timeout waiting for the reply
**and** try again at a later time and even wait on the results of multiple RPC
calls (to one or _more_ servers) at the same by merging the ports.

If we wish to block and wait for a reply immediately (just as we would with `call`),
two blocking operations are provided to simplify the task, one of which returns an
`ExitReason` on failure, whilst the other crashes (with the given `ExitReason` of
course!). The implementation is precisely what you'd expect a blocking _call_ to
do, right up to monitoring the server for potential exit signals (so as not to
deadlock the client if the server dies before replying) - all of which is handled
by `awaitResponse` in the platform's `Primitives` module.

{% highlight haskell %}
syncSafeCallChan server msg = do
  rp <- callChan server msg
  awaitResponse server [ matchChan rp (return . Right) ]
{% endhighlight %}

This might sound like a vast improvement on the usual combination of a client
API that uses `call` and a corresponding `handleCall` in the process definition,
with the programmer left to ensure the types always match up. In reality, there
is a trade-off to be made however. Using the `handleCall` APIs means that our server
side code can use the fluent server API for state changes, immediate replies and
so on. None of these features will work with the corollary family of
`handleRpcChan` functions. Whether or not the difference is merely aesthetic, we
leave as a question for the reader to determine. The following example demonstrates
the use of reply channels:

{% highlight haskell %}
-- two versions of the same handler, one for calls, one for typed (reply) channels

data State
data Input
data Output

-- typeable and binary instances ommitted for brevity

-- client code

callDemo :: ProcessId -> Process Output
callDemo server = call server Input

chanDemo :: ProcessId -> Process Output
chanDemo server = syncCallChan server Input

-- server code (process definition ommitted for brevity)

callHandler :: Dispatcher State
callHandler = handleCall $ \state Input -> reply Output state

chanHandler :: Dispatcher State
chanHandler = handleRpcChan $ \state port Input -> replyChan port Output >> continue state
{% endhighlight %}

------
> ![Info: ][info] Using typed channels for replies is both flexible and efficient.
> The trade-off is that you must remember to send a reply from the server explicitly,
> whereas the `call` API forces you to decide how to respond (to the client) via the
> `ProcessReply` type which server-side call _handlers_ have to evaluate to.
------

#### Input (Control) Channels

An alternative input plane managed process servers; _Control Channels_ provide a
number of benefits above and beyond both the standard `call` and `cast` APIs and the
use of reply channels. These include efficiency - _typed channels_ are very lightweight
constructs in general! - and type safety, as well as giving the server the ability to
prioritise information sent on control channels over other traffic.

Using typed channels as inputs to your managed process is _the_ most efficient way
to enable client-server communication, particularly for intra-node traffic, due to
their internal use of STM (and in particular, its use during selective receives).
Control channels can provide an alternative to prioritised process definitions, since
their use of channels ensures that, providing the control channel handler(s) occur
in the process definition's `apiHandlers` list before the other dispatchers, any
messages received on those channels will be prioritised over other traffic. This is
the most efficient kind of prioritisation - not much use if you need to prioritise
_info messages_ of course, but very useful if _control messages_ need to be given
priority over other inputs.

------
> ![Warning: ][alert] Control channels are **not** compatible with prioritised
> process definitions! The type system does not prevent them from being declared
> though, since they _are_ represented by a `Dispatcher` and therefore deemded
> valid entries of the `apiHandlers` field. Upon startup, a prioritised process
> definition that contains control channel dispatchers in its `apiHandlers` will
> immediately exit with the reason `ExitOther "IllegalControlChannel"` though.
------

In order to use a typed channel as an input plane, it is necessary to _leak_ the
`SendPort` to your clients somehow. One way would be to `send` it on demand, but the
simplest approach is actually to initialise a handle with all the relevant send ports
and return this to the spawning process via a private channel, MVar or STM (or similar).
Because a `SendPort` is `Serializable`, forwarding them (or the handle they're
contained within) is no problem either.

Since typed channels are a one way street, there's no direct API support for RPC calls
when using them to send data to a server. The work-around for this remains simple,
type-safe and elegant though: we encode a reply channel into our command/request datum
so the server knows where (and with what type) to reply. This does increase the amount
of boilerplate code the client-facing API has to endure, but it's a small price to pay
for the efficiency and additional type safety provided.

First, we'll look at an example of a single control channel being used with the
`chanServe` API. This handles the messy details of passing the control channel back
to the calling process, at least to some extent. For this example, we'll examine the
[`Mailbox`][mailbox] module, since this combines a fire-and-forget control channel with
an opaque server handle.

{% highlight haskell %}
-- our handle is fairly simple
data Mailbox = Mailbox { pid   :: !ProcessId
                       , cchan :: !(ControlPort ControlMessage)
                       } deriving (Typeable, Generic, Eq)
instance Binary Mailbox where

instance Linkable Mailbox where
  linkTo = link . pid

instance Resolvable Mailbox where
  resolve = return . Just . pid

-- lots of details elided....

-- Starting the mailbox involves both spawning, and passing back the process id,
-- plus we need to get our hands on a control port for the control channel!

doStartMailbox :: Maybe SupervisorPid
               -> ProcessId
               -> BufferType
               -> Limit
               -> Process Mailbox
doStartMailbox mSp p b l = do
  bchan <- liftIO $ newBroadcastTChanIO
  rchan <- liftIO $ atomically $ dupTChan bchan
  spawnLocal (maybeLink mSp >> runMailbox bchan p b l) >>= \pid -> do
    cc <- liftIO $ atomically $ readTChan rchan
    return $ Mailbox pid cc  -- return our opaque handle!
  where
    maybeLink Nothing   = return ()
    maybeLink (Just p') = link p'

runMailbox :: TChan (ControlPort ControlMessage)
           -> ProcessId
           -> BufferType
           -> Limit
           -> Process ()
runMailbox tc pid buffT maxSz = do
  link pid
  tc' <- liftIO $ atomically $ dupTChan tc
  MP.chanServe (pid, buffT, maxSz) (mboxInit tc') (processDefinition pid tc)

mboxInit :: TChan (ControlPort ControlMessage)
         -> InitHandler (ProcessId, BufferType, Limit) State
mboxInit tc (pid, buffT, maxSz) = do
  cc <- liftIO $ atomically $ readTChan tc
  return $ InitOk (State Seq.empty $ defaultState buffT maxSz pid cc) Infinity

processDefinition :: ProcessId
                  -> TChan (ControlPort ControlMessage)
                  -> ControlChannel ControlMessage
                  -> Process (ProcessDefinition State)
processDefinition pid tc cc = do
  liftIO $ atomically $ writeTChan tc $ channelControlPort cc
  return $ defaultProcess { apiHandlers = [
                               handleControlChan     cc handleControlMessages
                             , Restricted.handleCall handleGetStats
                             ]
                          , infoHandlers = [ handleInfo handlePost
                                           , handleRaw  handleRawInputs ]
                          , unhandledMessagePolicy = DeadLetter pid
                          } :: Process (ProcessDefinition State)
{% endhighlight %}

Since the rest of the mailbox initialisation code is quite complex, we'll leave it
there for now. The important details to take away are the use of `chanServe`
and its requirement for a thunk that initialises the `ProcessDefinition`, so it can
perform IO - a pre-requisite to sharing the control channels with the spawning process,
which must use STM or something similar in order to share data with the newly spawned
server's initialisation code. In our case, we want to pass the control port from the
thunk passed to `chanServe` back to both the spawning process _and_ the init function
(which is normally de-coupled from the initialising thunk), which makes this a good
example of how to utilise a broadcast TChan (or TQueue) to share control plane
structures during initialisation.

------

Now we'll cook up another (contrived) example that uses multiple typed control channels,
demonstrating how to create control channels explicitly, how to obtain a `ControlPort`
for each one, one way of passing these back to the process spawning the server (so as
to fill in the opaque server handle) and how to utilise these in your client code,
complete with the use of typed reply channels. This code will not use `chanServe`,
since _that_ API only supports a single control channel - the original purpose behind
the control channel concept - and instead, we'll create the process loop ourselves,
using the exported low level `recvLoop` function.

{% highlight haskell %}

type NumRequests = Int

data EchoServer = EchoServer { echoRequests :: ControlPort String
                             , statRequests :: ControlPort NumRequests
                             , serverPid    :: ProcessId
                             }
  deriving (Typeable, Generic)
instance Binary EchoServer where
instance NFData EchoServer where

instance Resolvable EchoServer where
  resolve = return . Just . serverPid

instance Linkable EchoServer where
  linkTo = link . serverPid

-- The server takes a String and returns it verbatim

data EchoRequest = EchoReq !String !(SendPort String)
  deriving (Typeable, Generic)
instance Binary EchoRequest where
instance NFData EchoRequest where

data StatsRequest = StatsReq !(SendPort Int)
  deriving (Typeable, Generic)
instance Binary StatsRequest where
instance NFData StatsRequest where

-- client code

echo :: EchoServer -> String -> Process String
echo h s = do
  (sp, rp) <- newChan
  let req = EchoReq s sp
  sendControlMessage (echoRequests h) req
  receiveWait [ matchChan rp return ]

stats :: EchoServer -> Process NumRequests
stats h = do
  (sp, rp) <- newChan
  let req = StatsReq sp
  sendControlMessage (statRequests h) req
  receiveWait [ matchChan rp return ]

demo :: Process ()
demo = do
  server <- spawnEchoServer
  foobar <- echo server "foobar"
  foobar `shouldBe` equalTo "foobar"

  baz <- echo server "baz"
  baz `shouldBe` equalTo baz

  count <- stats server
  count `shouldBe` equalTo (2 :: NumRequests)

-- server code

spawnEchoServer :: Process EchoServer
spawnEchoServer = do
  (sp, rp) <- newChan
  pid <- spawnLocal $ runEchoServer sp
  (echoPort, statsPort) <- receiveChan rp
  return $ EchoServer echoPort statsPort pid

runEchoServer :: SendPort (ControlPort EchoRequest, ControlPort StatsRequest)
              -> Process ()
runEchoServer portsChan = do
  echoChan <- newControlChan
  echoPort <- channelControlPort echoChan
  statChan <- newControlChan
  statPort <- channelControlPort statChan
  sendChan portsChan (echoPort, statPort)
  runProcess (recvLoop $ echoServerDefinition echoChan statChan ) echoServerInit

echoServerInit :: InitHandler () NumRequests
echoServerInit = return $ InitOk (0 :: Int) Infinity

echoServerDefinition :: ControlChannel EchoRequest
                     -> ControlChannel StatsRequest
                     -> ProcessDefinition NumRequests
echoServerDefinition echoChan statChan =
  defaultProcess {
      apiHandlers = [ handleControlChan echoChan handleEcho
                    , handleControlChan statChan handleStats
                    ]
    }

handleEcho :: NumRequests -> EchoRequest -> Process (ProcessAction State)
handleEcho count (EchoReq req replyTo) = do
  replyChan replyTo req  -- echo back the string
  continue $ count + 1

handleStats :: NumRequests -> StatsRequest -> Process (ProcessAction State)
handleStats count (StatsReq replyTo) = do
  replyChan replyTo count
  continue count
{% endhighlight %}

Although not very useful, this is a working example. Note that the client must
deal with a `ControlPort` and not the complete `ControlChannel` itself. Also
note that the server is completely responsible for replying (explicitly) to
the client using the send ports supplied in the request data.

------
> ![Info: ][info] Combining control channels with opaque handles is another great
> way to enforce additional type safety, since the channels must be initialised by
> the server code before it can create handlers for them and the client code that
> passes data to them (via the `SendPort`) is bound to exactly the same type(s)!
> Furthermore, adding reply channels (in the form of a `SendPort`) to the request
> types ensures that the replies will be handled correctly as well! As a result,
> there can be no ambiguity about the types involved for _either_ side of the 
> client-server relationship and therefore no unhandled messages due to runtime
> type mismatches - the compiler will catch that sort of thing for us!
------

[1]: http://hackage.haskell.org/package/distributed-process-platform/Control-Distributed-Process-Platform-Service-Registry.html
[2]: http://hackage.haskell.org/package/distributed-process-platform/Control-Distributed-Process-Platform-Async.html
[3]: http://hackage.haskell.org/package/distributed-process-platform/Control-Distributed-Process-Platform-Service-SystemLog.html
[mgmt]: http://hackage.haskell.org/package/distributed-process/Control-Distributed-Process-Management.html
[dbg]: http://hackage.haskell.org/package/distributed-process/Control-Distributed-Process-Debug.html
[rtbl]: http://hackage.haskell.org/package/distributed-proces-platforms/Control-Distributed-Process-Platform.html#t:Routable
[rsbl]: http://hackage.haskell.org/package/distributed-process-platform/Control-Distributed-Process-Platform.html#t:Resolvable
[alert]: /img/alert.png
[info]: /img/info.png
[policy]: http://hackage.haskell.org/package/distributed-process-platform/Control-Distributed-Process-Platform-ManagedProcess.html#t:UnhandledMessagePolicy
[mailbox]: http://hackage.haskell.org/package/distributed-process-platform/Control-Distributed-Process-Platform-Execution-Mailbox.html

