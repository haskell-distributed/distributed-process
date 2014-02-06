---
layout: tutorial
sections: ['Introduction', 'Managed Processes', 'A Basic Example', 'Building a Task Queue', 'Implementing the Client', 'Implementing the Server', 'Making use of Async', 'Wiring up Handlers', 'Putting it all together', 'Performance Considerations']
categories: tutorial
title: Managed Process Tutorial
---

### Introduction

The source code for this tutorial is based on the `BlockingQueue` module
from distributed-process-platform and can be accessed [here][1].
Please note that this tutorial is based on the stable (master) branch
of distributed-process-platform.

### Managed Processes

There are subtle bugs waiting in code that evaluated `send` and `receive`
directly. Forgetting to monitor the destination whilst waiting for a reply
and failing to match on the correct message types are the most common ones,
but others exist (such as badly formed `Binary` instances for user defined
data types).

The /Managed Process/ API handles _all_ sending and receiving of messages,
error handling and decoding problems on your behalf, leaving you to focus
on writing code that describes _what the server process does_ when it receives
messages, rather than how it receives them. The API also provides a set of
pre-defined client interactions, all of which have well defined semantics
and failure modes.

A managed process server definition is defined using record syntax, with
a list of `Dispatcher` types that describe how the server should handle
particular kinds of client interaction, for specific types. The fields
of the `ProcessDefinition` record also provide for error handling (in case
of either server code crashing _or_ exit signals dispatched to the server
process) and _cleanup_ code required to run on terminate/shutdown.

{% highlight haskell %}
myServer :: ProcessDefinition MyStateType
myServer = 
  ProcessDefinition { 
    apiHandlers = [
        -- a list of Dispatcher, derived from calling
        -- handleInfo or handleRaw with a suitable function, e.g.,
        handleCast myFunctionThatDoesNotReply
      , handleCall myFunctionThatDoesReply
      , handleRpcChan myFunctionThatRepliesViaTypedChannels
      ]
    , infoHandlers = [
        -- a list of DeferredDispatcher, derived from calling
        -- handleInfo or handleRaw with a suitable function, e.g.,
        handleInfo myFunctionThatHandlesOneSpecificNonCastNonCallMessageType
      , handleRaw  myFunctionThatHandlesRawMessages
      ]
    , exitHandlers = [
        -- a list of ExitSignalDispatcher, derived from calling
        -- handleExit with a suitable function, e.g.,
        handleExit myExitHandlingFunction
      ]
      -- what should I do just before stopping?
    , terminateHandler = myTerminateFunction
      -- what should I do about messages that cannot be handled?
    , unhandledMessagePolicy = Drop -- Terminate | (DeadLetter ProcessId)
    }

{% endhighlight %}

Client interactions with a managed process come in various flavours. It is
still possible to send an arbitrary message to a managed process, just as
you would a regular process. When defining a protocol between client and
server processes however, it is useful to define a specific set of types
that the server expects to receive from the client and possibly replies
that the server may send back. The `cast` and `call` mechanisms in the
/managed process/ API cater for this requirement specifically, allowing
the developer tighter control over the domain of input messages from
clients, whilst ensuring that client code handles errors (such as server
failures) consistently and those input messages are routed to a suitable
message handling function in the server process.

---------

### A Basic Example

Let's consider a simple _math server_ like the one in the main documentation
page. We could allow clients to send us `(ProcessId, Double, Double)` and
reply to the first tuple element with the sum of the second and third. But
what happens if our process is killed while the client is waiting for the
reply? (The client would deadlock). The client could always set up a monitor
and wait for the reply _or_ a monitor signal, and could even write that code
generically, but what if the code evaluating the client's utility function
`expect`s the wrong type? We could use a typed channel to alleviate that ill,
but that only helps with the client receiving messages, not the server. How
can we ensure that the server receives the correct type(s) as well? Creating
multiple typed channels (one for each kind of message we're expecting) and
then distributing those to all our clients seems like a kludge.

The `call` and `cast` APIs help us to avoid precisely this conundrum by
providing a uniform API for both the client _and_ the server to observe. Whilst
there is nothing to stop clients from sending messages directly to a managed
process, it is simple enough to prevent this as well (just by hiding its
`ProcessId`, either behind a newtype or some other opaque structure). The
author of the server is then able to force clients through API calls that
can enforce the required types _and_ ensure that the correct client-server
protocol is used. Here's a better example of that math server that does
just so:

----

{% highlight haskell %}
module MathServer 
  ( -- client facing API
    add
    -- starting/spawning the server process
  , launchMathServer
  ) where

import .... -- elided

-- We keep this data-type hidden from the outside world, and we ignore
-- messages sent to us that we do not recognise, so misbehaving clients
-- (who do not use our API) are basically ignored.
data Add = Add Double Double
  deriving (Typeable, Generic)
instance Binary Add where

-- client facing API

-- This is the only way clients can get a message through to us that
-- we will respond to, and since we control the type(s), there is no
-- risk of decoding errors on the server. The /call/ API ensures that
-- if the server does fail for some other reason however (such as being
-- killed by another process), the client will get an exit signal also.
--
add :: ProcessId -> Double -> Double -> Process Double
add sid = call sid . Add

-- server side code

launchMathServer :: Process ProcessId
launchMathServer =
  let server = statelessProcess {
      apiHandlers = [ handleCall_ (\(Add x y) -> return (x + y)) ]
    , unhandledMessagePolicy = Drop
    }
  in spawnLocal $ start () (statelessInit Infinity) server >> return ()
{% endhighlight %}


This style of programming will already be familiar if you've used some
combination of `send` in your clients and the `receive [ match ... ]`
family of functions to write your servers. The primary difference here,
is that the choice of when to return to (potentially blocking on) the
server's mailbox is taken out of the programmer's hands, leaving the
implementor to worry only about the logic to be applied once a message
of one type or another is received.

----

Of course, it would still be possible to write the server and client code
and encounter a type resolution failure, since `call` still takes an
arbitrary `Serializable` datum just like `send`. We can solve that for
the return type of the _remote_ call by sending a typed channel and
replying explicitly to it in our server side code. Whilst this doesn't
make the server code any prettier (since it has to reply to the channel
explicitly, rather than just evaluating to a result), it does the
likelihood of runtime errors somewhat.

{% highlight haskell %}
-- This is the only way clients can get a message through to us that
-- we will respond to, and since we control the type(s), there is no
-- risk of decoding errors on the server. The /call/ API ensures that
-- if the server does fail for some other reason however (such as being
-- killed by another process), the client will get an exit signal also.
--
add :: ProcessId -> Double -> Double -> Process Double
add sid = syncCallChan sid . Add

launchMathServer :: Process ProcessId
launchMathServer =
  let server = statelessProcess {
      apiHandlers = [ handleRpcChan_ (\chan (Add x y) -> sendChan chan (x + y)) ]
    , unhandledMessagePolicy = Drop
    }
  in spawnLocal $ start () (statelessInit Infinity) server >> return ()
{% endhighlight %}

Ensuring that only valid types are sent to the server is relatively simple,
given that we do not expose the client directly to `call` and write our own
wrapper functions. An additional level of isolation and safety is available
when using /control channels/, which will be covered in a subsequent tutorial.

Before we leave the math server behind, let's take a brief look at the `cast`
side of the client-server protocol. Unlike its synchronous cousin, `cast` does
not expect a reply at all - it is a fire and forget call, much like `send`,
but carries the same additional type information that a `call` does (about its
inputs) and is also routed to a `Dispatcher` in the `apiHandlers` field of the
process definition.

We will use cast with the existing `Add` type, to implement a function that
takes an /add request/ and prints the result instead of returning it. If we
were implementing this with `call` we would be a bit stuck, because there is
nothing to differentiate between two `Add` instances and the server would
choose the first valid (i.e., type safe) handler and ignore the others.

Note that because the client doesn't wait for a reply, if you execute this
function in a test/demo application, you'll need to block the main thread
for a while to wait for the server to receive the message and print out
the result.

{% highlight haskell %}

printSum :: ProcessId -> Double -> Double -> Process ()
printSum sid = cast sid . Add

launchMathServer :: Process ProcessId
launchMathServer =
  let server = statelessProcess {
      apiHandlers = [ handleRpcChan_ (\chan (Add x y) -> sendChan chan (x + y) >> continue_)
                    , handleCast_ (\(Add x y) -> liftIO $ putStrLn $ show (x + y) >> continue_) ]
    , unhandledMessagePolicy = Drop
    }
  in spawnLocal $ start () (statelessInit Infinity) server >> return ()
{% endhighlight %}


Of course this is a toy example - why defer simple computations like addition
and/or printing results to a separate process? Next, we'll build something a bit
more interesting and useful.

### Building a Task Queue

This section of the tutorial is based on a real module from the
distributed-process-platform library, called `BlockingQueue`.

Let's imagine we want to execute tasks on an arbitrary node, but want 
the caller to block whilst the remote task is executing. We also want
to put an upper bound on the number of concurrent tasks/callers that
the server will accept. Let's use `ManagedProcess` to implement a generic
task server like this, with the following characteristics

* requests to enqueue a task are handled immediately
* callers however, are blocked until the task completes (or fails)
* an upper bound is placed on the number of concurrent running tasks

Once the upper bound is reached, tasks will be queued up for execution.
Only when we drop below this limit will tasks be taken from the backlog
and executed.

Since we want the server to proceed with its work whilst the client is
blocked, the asynchronous `cast` API may sound like the ideal approach,
or we might use the asynchronous cousin of our typed-channel
handling API `callChan`. The `call` API however, offers exactly the
tools we need to keep the client blocked (waiting for a reply) whilst
the server is allowed to proceed with its work.

### Implementing the client

We'll start by thinking about the types we need to consume in the server
and client processes: the tasks we're being asked to perform.

To submit a task, our clients will submit an action in the process
monad, wrapped in a `Closure` environment. We will use the `Addressable`
typeclass to allow clients to specify the server's location in whatever
manner suits them: The type of a task will be `Closure (Process a)` and
the server will explicitly return an /either/ value with `Left String`
for errors and `Right a` for successful results.
 
{% highlight haskell %}
-- enqueues the task in the pool and blocks
-- the caller until the task is complete
executeTask :: forall s a . (Addressable s, Serializable a)
            => s
            -> Closure (Process a)
            -> Process (Either String a)
executeTask sid t = call sid t
{% endhighlight %}

Remember that in Cloud Haskell, the only way to communicate with a process
(apart from introducing scoped concurrency primitives like `MVar` or using
stm) is via its mailbox and typed channels. Also, all communication with
the process is asynchronous from the sender's perspective and synchronous
from the receiver's. Although `call` is a synchronous (RPC-like) protocol,
communication with the *server process* has to take place out of band.

The server implementation chooses to reply to each request and when handling
a `call`, can defer its reply until a later stage, thus going back to
receiving and processing other messages in the meantime. As far as the client
is concerned, it is simply waiting for a reply. Note that the `call` primitive
is implemented so that messages from other processes cannot interleave with
the server's response. This is very important, since another message of type
`Either String a` could theoretically arrive in our mailbox from somewhere
else whilst we're receiving, therefore `call` transparently tags the call
message and awaits a specific reply from the server (containing the same
tag). These tags are guaranteed to be unique across multiple nodes, since
they're based on a `MonitorRef`, which holds a `Identifier ProcessId` and
a node local monitor ref counter. All monitor creation is coordinated by
the caller's node controller (guaranteeing the uniqueness of the ref
counter for the lifetime of the node) and the references are not easily
forged (i.e., sent by mistake - this is not a security feature of any sort)
since the type is opaque.

In terms of code for the client then, that's all there is to it!
Note that the type signature we expose to our consumers is specific, and that
we do not expose them to arbitrary messages arriving in their mailbox. Note
that if a `call` fails, a `ProcessExitException` will be thrown in the caller's
thread (since the implementation calls `die` if it detects that the server has
died before replying). Other variations of `call` exist that return a `Maybe` or
an `Either ExitReason a` instead of making the caller's process exit.

Note that if the server replies to this call with some other type (i.e., a type
other than `Either String a`) then our client will be blocked indefinitely!
We could alleviate this by using a typed channel as we saw previously with our
math server, but there's little point since we're in total charge of both the
client and the server's code.

### Implementing the server

To implement the server, we'll need to hang on to some internal state. As well as
knowing our queue's size limit, we will need to track the _active_ tasks we're
currently running. Each task will be submitted as a `Closure (Process a)` and we'll
need to spawn the task (asynchronously), handle the result (once the closure has
run to completion) and communicate the result (or failure) to the original caller.

This means our pool state will need to be parameterised by the result type it will
accept in its closures. So now we have the beginnings of our state type:

{% highlight haskell %}
data BlockingQueue a = BlockingQueue
{% endhighlight %}

### Making use of Async

So **how** can we execute this `Closure (Process a)` without blocking the server
process itself? We can use the `Control.Distributed.Process.Platform.Async` API
to execute each task asynchronously and provide a means for waiting on the result.

In order to use an `Async` handle to get the result of the computation once it's
complete, we'll have to hang on to a reference. We also need a way to associate the
submitter with the handle, so we end up with one field for the active (running)
tasks and another for the queue of accepted (but inactive) ones, as expected.

Since we cannot wait on all these `Async` handles at once whilst we're supposed to
be accepting new messages from clients - actually, /async/ does provide an API for
multiplexing on async results, but that's no use here - instead we will monitor the
async tasks and pull the results when we receive their monitor signals. So for the
active tasks, we'll need to store a `MonitorRef` and a reference to the original
caller, plus the async handle itself. We'll use a simple association list for this
state, though we should probably use a more optimal data structure eventually.

For the tasks that we cannot execute immediately (i.e., when we reach the queue's
size limit), we hold the client ref and the closure, but no monitor ref. We'll
use a data structure that support FIFO ordering semantics for this, since that's
probably what clients will expect of something calling itself a "queue".

{% highlight haskell %}
data BlockingQueue a = BlockingQueue {
    poolSize :: SizeLimit
  , active   :: [(MonitorRef, CallRef (Either ExitReason a), Async a)]
  , accepted :: Seq (CallRef (Either ExitReason a), Closure (Process a))
  }
{% endhighlight %}

Our queue-like behaviour is fairly simple to define using `Data.Sequence`:

{% highlight haskell %}
enqueue :: Seq a -> a -> Seq a
enqueue s a = a <| s

dequeue :: Seq a -> Maybe (a, Seq a)
dequeue s = maybe Nothing (\(s' :> a) -> Just (a, s')) $ getR s

getR :: Seq a -> Maybe (ViewR a)
getR s =
  case (viewr s) of
    EmptyR -> Nothing
    a      -> Just a
{% endhighlight %}


Now, to turn that `Closure` environment into a thunk we can evaluate, we'll use the
built in `unClosure` function, and we'll pass the thunk to `async` and get back
a handle to the running async task, which we'll then need to monitor. We won't cover
the async API in detail here, except to point out that the call to `async` spawns a
new process to do the actual work and returns a handle that we can use to query for
the result.

{% highlight haskell %}
proc <- unClosure task'
asyncHandle <- async proc
ref <- monitorAsync asyncHandle
{% endhighlight %}

We can now implement the `acceptTask` function, which the server will use to handle
submitted tasks. The signature of our function must be compatible with the message
handling API from `ManagedProcess` that we're going to use it with - in this case
`handleCallFrom`. This variant of the `handleCall` family of functions is specifically
intended for use when the server is going to potentially delay its reply, rather than
replying immediately. It takes an expression that operates over our server's state, a
`CallRef` that uniquely identifies the caller and can be used to reply to them later
on and the message that was sent to the server - in this case, a `Closure (Process a)`.

All managed process handler functions must return either a `ProcessAction`, indicating
how the server should proceed, or a `ProcessReply`, which combines a `ProcessAction`
with a possible reply to one of the `call` derivatives. Since we're deferring our reply
until later, we will use `noReply_`, which creates a `ProcessAction` for us, telling
the server to continue receiving messages.

{% highlight haskell %}
storeTask :: Serializable a
          => BlockingQueue a
          -> CallRef (Either ExitReason a)
          -> Closure (Process a)
          -> Process (ProcessReply (Either ExitReason a) (BlockingQueue a))
storeTask s r c = acceptTask s r c >>= noReply_

acceptTask :: Serializable a
           => BlockingQueue a
           -> CallRef (Either ExitReason a)
           -> Closure (Process a)
           -> Process (BlockingQueue a)
acceptTask s@(BlockingQueue sz' runQueue taskQueue) from task' =
  let currentSz = length runQueue
  in case currentSz >= sz' of
    True  -> do
      return $ s { accepted = enqueue taskQueue (from, task') }
    False -> do
      proc <- unClosure task'
      asyncHandle <- async proc
      ref <- monitorAsync asyncHandle
      let taskEntry = (ref, from, asyncHandle)
      return s { active = (taskEntry:runQueue) }
{% endhighlight %}

If we're at capacity, we add the task (and caller) to the `accepted` queue,
otherwise we launch and monitor the task using `async` and stash the monitor
ref, caller ref and the async handle together in the `active` field.

Now we must write a function that handles the results of these closures. When
a monitor signal arrives in our mailbox, we need to lookup the async handle
associated with it so as to obtain the result and send it back to the caller.
Because, even if we were running at capacity, we've now seen a task complete
(and therefore reduced the number of active tasks by one), we will also pull
off a pending task from the backlog (i.e., accepted), if any exists, and execute
it.

The steps then, are

1. find the async handle for our monitor ref
2. obtain the result using the handle
3. send the result to the client
4. bump another task from the backlog (if there is one)
5. carry on

This chain then, looks like `wait >>= respond >> bump-next-task >>= continue`.

Item (3) requires special API support from `ManagedProcess`, because we're not
just sending *any* message back to the caller. We're replying to a specific `call`
that has taken place and is, from the client's perspective, still running.
The `ManagedProcess` API call for this is `replyTo`.

There is quite a bit of code in this next function, which we'll look at in detail.
Firstly, note that the signature is similar to the one we used for `storeTask`, but
returns just a `ProcessAction` instead of `ProcessReply`. This function will not be
wired up to a `call` (or even a `cast`), because the node controller will send the
monitor signal directly to our mailbox, not using the managed process APIs at all.
This kind of client interaction is called an _info call_ in the managed process API,
and since there's no expected reply, as with `cast`, we simply return a `ProcessAction`
telling the server what to do next - in this case, to `continue` reading from the
mailbox.

{% highlight haskell %}
taskComplete :: forall a . Serializable a
             => BlockingQueue a
             -> ProcessMonitorNotification
             -> Process (ProcessAction (BlockingQueue a))
taskComplete s@(BlockingQueue _ runQ _)
             (ProcessMonitorNotification ref _ _) =
  let worker = findWorker ref runQ in
  case worker of
    Just t@(_, c, h) -> wait h >>= respond c >> bump s t >>= continue
    Nothing          -> continue s

  where
    respond :: CallRef (Either ExitReason a)
            -> AsyncResult a
            -> Process ()
    respond c (AsyncDone       r) = replyTo c ((Right r) :: (Either ExitReason a))
    respond c (AsyncFailed     d) = replyTo c ((Left (ExitOther $ show d))  :: (Either ExitReason a))
    respond c (AsyncLinkFailed d) = replyTo c ((Left (ExitOther $ show d))  :: (Either ExitReason a))
    respond _ _                   = die $ ExitOther "IllegalState"

    bump :: BlockingQueue a
         -> (MonitorRef, CallRef (Either ExitReason a), Async a)
         -> Process (BlockingQueue a)
    bump st@(BlockingQueue _ runQueue acc) worker =
      let runQ2 = deleteFromRunQueue worker runQueue
          accQ  = dequeue acc in
      case accQ of
        Nothing            -> return st { active = runQ2 }
        Just ((tr,tc), ts) -> acceptTask (st { accepted = ts, active = runQ2 }) tr tc

findWorker :: MonitorRef
           -> [(MonitorRef, CallRef (Either ExitReason a), Async a)]
           -> Maybe (MonitorRef, CallRef (Either ExitReason a), Async a)
findWorker key = find (\(ref,_,_) -> ref == key)

deleteFromRunQueue :: (MonitorRef, CallRef (Either ExitReason a), Async a)
                   -> [(MonitorRef, CallRef (Either ExitReason a), Async a)]
                   -> [(MonitorRef, CallRef (Either ExitReason a), Async a)]
deleteFromRunQueue c@(p, _, _) runQ = deleteBy (\_ (b, _, _) -> b == p) c runQ
{% endhighlight %}

We've dealt with mapping the `AsyncResult` to `Either` values, which we *could* have
left to the caller, but this makes the client facing API much simpler to work with.
Note that our use of an association list for the active _run queue_ makes for an
O(n) search for our worker, but that can be optimised with a map or dictionary later.
Worse, we have to scan the list again when deleting the worker from the _run queue_,
but the same fix (using a Map) should alleviate that problem too. We leave that as
an exercise for the reader.

### Wiring up handlers

Call and cast handlers live in the `apiHandlers` list of our `ProcessDefinition`
and have the type `Dispatcher s` where `s` is the state type for the process. We
cannot construct a `Dispatcher` ourselves, but a range of functions in the
`ManagedProcess.Server` module exist to convert functions like the ones we've just
defined, to the correct type.

In order to spell things out for the compiler, we need to put a type signature
in place at the call site for `storeTask`, so our final construct for that
handler is thus:

{% highlight haskell %}
handleCallFrom (\s f (p :: Closure (Process a)) -> storeTask s f p)
{% endhighlight %}

No such thing is required for `taskComplete`, as there's no ambiguity about its
type. Our process definition is now finished, and here it is:

{% highlight haskell %}
defaultProcess {
    apiHandlers = [
            handleCallFrom (\s f (p :: Closure (Process a)) -> storeTask s f p)
          , handleCall poolStatsRequest
    ]
  , infoHandlers = [ handleInfo taskComplete ]
  }
{% endhighlight %}

Starting the server takes a bit of work: `ManagedProcess` provides several
utility functions to help with spawning and running processes. The `serve`
function takes an _initialising_ thunk (which has the type `InitHandler`)
that must generate the initial state and set up the server's receive timeout,
then the process definition which we've already encountered. For more details
about starting managed processes, see the haddocks.

{% highlight haskell %}
run :: forall a . (Serializable a)
         => Process (InitResult (BlockingQueue a))
         -> Process ()
run init' = ManagedProcess.serve () (\() -> init') poolServer
  where poolServer =
          defaultProcess {
              apiHandlers = [
                 handleCallFrom (\s f (p :: Closure (Process a)) -> storeTask s f p)
               , handleCall poolStatsRequest
               ]
            , infoHandlers = [ handleInfo taskComplete ]
            } :: ProcessDefinition (BlockingQueue a)

pool :: forall a . Serializable a
     => SizeLimit
     -> Process (InitResult (BlockingQueue a))
pool sz' = return $ InitOk (BlockingQueue sz' [] Seq.empty) Infinity
{% endhighlight %}

### Putting it all together

Defining tasks is as simple as making them remote-worthy:

{% highlight haskell %}
sampleTask :: (TimeInterval, String) -> Process String
sampleTask (t, s) = sleep t >> return s

$(remotable ['sampleTask])
{% endhighlight %}

And executing them is just as simple too.

{% highlight haskell %}
tsk <- return $ ($(mkClosure 'sampleTask) (seconds 2, "foobar"))
executeTask taskQueuePid tsk
{% endhighlight %}

Starting up the server itself locally or on a remote node, is just a matter of
combining `spawn` or `spawnLocal` with `start`. We can go a step further though,
and add a bit more type safety to our API by using an opaque handle to communicate
with the server. The advantage of this is that it right now it is possible for
a client to send a `Closure` to the server with a return type different from the
one the server is expecting! Since the server won't recognise that message, the
`unhandledMessagePolicy` will be applied, which by default crashes the server with
an exit reason referring to "unhandled inputs"!

By returning a handle to the server using a parameterised type, we can ensure that
only closures returning a matching type are sent. To do so, we use a phantom type
parameter and simply stash the real `ProcessId` in a newtype. We also need to be
able to pass this handle to the managed process `call` API, so we define an
instance of the `Resolvable` typeclass for it, which makes a (default) instance of
`Routable` available, which is exactly what `call` is expecting:

{% highlight haskell %}
newtype TaskQueue a = TaskQueue { unQueue :: ProcessId }

instance Resolvable (TaskQueue a) where
  resolve = return . unQueue
{% endhighlight %}

Finally, we write a `start` function that returns this handle and change the
signature of `executeTask` to match it:

{% highlight haskell %}
start :: forall a . (Serializable a)
      => SizeLimit
      -> Process (TaskQueue a)
start lim = spawnLocal (start $ pool lim) >>= return . TaskQueue

-- .......

executeTask :: (Serializable a)
            => TaskQueue a
            -> Closure (Process a)
            -> Process (Either ExitReason a)
executeTask sid t = call sid t
{% endhighlight %}

----------

In this tutorial, we've really just scratched the surface of the `ManagedProcess`
API. By handing over control of the client/server protocol to the framework, we
are able to focus on the code that matters, such as state transitions and decision
making, without getting bogged down (much) with the business of sending and
receiving messages, handling client/server failures and such like.

### Performance Considerations

We did not take much care over our choice of data structures. Might this have
profound consequences for clients? Perhaps more of a concern is the cost of
using `Async` everywhere - remember we used this in the *server* to handle
concurrently executing tasks and obtaining their results. An invocation of
`async` will create two new processes: one to perform the calculation and
another to monitor the first and handle failures and/or cancellation. Spawning
processes is cheap, but not free as each process is a haskell thread, plus some
additional book keeping data.

[1]: https://github.com/haskell-distributed/distributed-process-platform/blob/master/src/Control/Distributed/Process/Platform/Task/Queue/BlockingQueue.hs
