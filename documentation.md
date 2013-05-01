---
layout: documentation
title: Documentation
---

### Cloud Haskell Platform

This is the [*Cloud Haskell Platform*][1]. Cloud Haskell is a set of libraries
that bring Erlang-style concurrency and distribution to Haskell programs. This
project is an implementation of that distributed computing interface, where
processes communicate with one another through explicit message passing rather
than shared memory.

Originally described by the joint [Towards Haskell in the Cloud][12] paper,
Cloud Haskell has be re-written from the ground up and supports a rich and
growing number of features for

* building concurrent applications using asynchronous message passing
* building distributed computing applications
* building fault tolerant systems
* running Cloud Haskell nodes on various network transports
* working with several network transport implementations (and more in the pipeline)
* supporting *static* values (required for remote communication)

There is a recent
[presentation](http://sneezy.cs.nott.ac.uk/fun/2012-02/coutts-2012-02-28.pdf)
on Cloud Haskell and this reimplementation, which is worth reading in conjunction
with the documentation and wiki pages on this website..

Cloud Haskell comprises the following components, some of which are complete,
others experimental.

* [distributed-process][2]: Base concurrency and distribution support
* [distributed-process-platform][3]: The Cloud Haskell Platform - APIs
* [distributed-static][4]: Support for static values
* [rank1dynamic][5]: Like `Data.Dynamic` and `Data.Typeable` but supporting polymorphic values
* [network-transport][6]: Generic `Network.Transport` API
* [network-transport-tcp][7]: TCP realisation of `Network.Transport`
* [network-transport-inmemory][8]: In-memory realisation of `Network.Transport` (incomplete) 
* [network-transport-composed][9]: Compose two transports (very preliminary)
* [distributed-process-simplelocalnet][10]: Simple backend for local networks
* [distributed-process-azure][11]: Azure backend for Cloud Haskell (proof of concept)

One of Cloud Haskell's goals is to separate the transport layer from the
*process layer*, so that the transport backend is entirely independent:
it is envisaged that this interface might later be used by models
other than the Cloud Haskell paradigm, and that applications built
using Cloud Haskell might be easily configured to work with different
backend transports.

Abstracting over the transport layer allows different protocols for
message passing, including TCP/IP, UDP,
[MPI](http://en.wikipedia.org/wiki/Message_Passing_Interface), 
[CCI](http://www.olcf.ornl.gov/center-projects/common-communication-interface/),
ZeroMQ, SSH, MVars, Unix pipes, and more. Each of these transports would provide
its own implementation of the `Network.Transport` and provide a means of creating
new connections for use within `Control.Distributed.Process`. This separation means
that transports might be used for other purposes than Cloud Haskell.

The following diagram shows dependencies between the various subsystems,
in an application using Cloud Haskell, where arrows represent explicit
directional dependencies.

-----

    +------------------------------------------------------------+
    |                        Application                         |
    +------------------------------------------------------------+
                 |                               |
                 V                               V
    +-------------------------+   +------------------------------+
    |      Cloud Haskell      |<--|    Cloud Haskell Backend     |
    |  (distributed-process)  |   | (distributed-process-...)    |
    +-------------------------+   +------------------------------+
                 |           ______/             |
                 V           V                   V
    +-------------------------+   +------------------------------+
    |   Transport Interface   |<--|   Transport Implementation   |
    |   (network-transport)   |   |   (network-transport-...)    |
    +-------------------------+   +------------------------------+
                                                 |
                                                 V
                                  +------------------------------+
                                  | Haskell/C Transport Library  |
                                  +------------------------------+

-----

In this diagram, the various nodes roughly correspond to specific modules:

    Cloud Haskell                : Control.Distributed.Process
    Cloud Haskell                : Control.Distributed.Process.*
    Transport Interface          : Network.Transport
    Transport Implementation     : Network.Transport.*

An application is built using the primitives provided by the Cloud
Haskell layer, provided by `Control.Distributed.Process` module, which
provides abstractions such as nodes and processes.

The application also depends on a Cloud Haskell Backend, which
provides functions to allow the initialisation of the transport layer
using whatever topology might be appropriate to the application.

It is, of course, possible to create new Cloud Haskell nodes by
using a Network Transport Backend such as `Network.Transport.TCP`
directly.

The Cloud Haskell interface and backend, make use of the Transport
interface provided by the `Network.Transport` module.
This also serves as an interface for the `Network.Transport.*`
module, which provides a specific implementation for this transport,
and may, for example, be based on some external library written in 
Haskell or C.

### Network Transport Abstraction Layer

Cloud Haskell's generic [network-transport][6] API is entirely independent of
the concurrency and messaging passing capabilities of the *process layer*.
Cloud Haskell applications are built using the primitives provided by the
*process layer* (i.e., [distributed-process][2]), which provides abstractions
such as nodes and processes. Applications must also depend on a Cloud Haskell
Backend, which provides functions to allow the initialisation of the transport
layer using whatever topology might be appropriate to the application.

`Network.Transport` is a network abstraction layer geared towards specific
classes of applications, offering the following high level concepts:

* Nodes in the network are represented by `EndPoint`s. These are heavyweight stateful objects.
* Each `EndPoint` has an `EndPointAddress`.
* Connections can be established from one `EndPoint` to another using the `EndPointAddress` of the remote end.
* The `EndPointAddress` can be serialised and sent over the network, where as `EndPoint`s and connections cannot.
* Connections between `EndPoint`s are unidirectional and lightweight.
* Outgoing messages are sent via a `Connection` object that represents the sending end of the connection.
* Incoming messages for **all** of the incoming connections on an `EndPoint` are collected via a shared receive queue.
* In addition to incoming messages, `EndPoint`s are notified of other `Event`s such as new connections or broken connections.

This design was heavily influenced by the design of the Common Communication Interface ([CCI](http://www.olcf.ornl.gov/center-projects/common-communication-interface/)). Important design goals are:

* Connections should be lightweight: it should be no problem to create thousands of connections between endpoints.
* Error handling is explicit: every function declares as part of its type which errors it can return (no exceptions are thrown)
* Error handling is "abstract": errors that originate from implementation specific problems (such as "no more sockets" in the TCP implementation) get mapped to generic errors ("insufficient resources") at the Transport level.

For the purposes of most Cloud Haskell applications, it is sufficient to know
enough about the `Network.Transport` API to instantiate a backend with the
required configuration and pass the returned opaque handle to the `Node` API
in order to establish a new, connected, running node. More involved setups are,
of course, possible; The simplest use of the API is thus

{% highlight haskell %}
main :: IO
main = do
  Right transport <- createTransport "127.0.0.1" "10080" defaultTCPParameters
  node1 <- newLocalNode transport initRemoteTable
{% endhighlight %}

Here we can see that the application depends explicitly on the
`defaultTCPParameters` and `createTransport` functions from
`Network.Transport.TCP`, but little else. The application *can* make use
of other `Network.Transport` APIs if required, but for the most part this
is irrelevant and the application will interact with Cloud Haskell through
the *Process Layer* and *Platform*.

For more details about `Network.Transport` please see the [wiki page][20].

### Concurrency and Distribution

The *Process Layer* is where Cloud Haskell's support for concurrency and
distributed programming are exposed to application developers. This layer
deals explicitly with 

The core of Cloud Haskell's concurrency and distribution support resides in the
[distributed-process][2] library. As well as the APIs necessary for starting
nodes and forking processes on them, we find all the basic primitives required
to

* spawn processes locally and remotely
* send and receive messages, optionally using typed channels
* monitor and/or link to processes, channels and other nodes

Most of this is easy enough to follow in the haddock documentation and the
various tutorials. Here we focus on the essential *concepts* behind the
process layer.

A concurrent process is somewhat like a Haskell thread - in fact it is a
`forkIO` thread - but one that can send and receive messages through its
*process mailbox*. Each process can send messages asynchronously to other
processes, and can receive messages synchronously from its own mailbox.
The conceptual difference between threads and processes is that the latter
do not share state, but communicate only via message passing.

Code that is executed in this manner must run in the `Process` monad. Our
process will look like any other monad code, plus we provide and instance
of `MonadIO` for `Process`, so you can `liftIO` to make IO actions
available.

Processes reside on nodes, which in our implementation map directly to the
`Control.Distributed.Processes.Node` module. Given a configured
`Network.Transport` backend, starting a new node is fairly simple:

{% highlight haskell %}
newLocalNode :: Transport -> IO LocalNode
{% endhighlight %}

Once this function returns, the node will be *up and running* and able to
interact with other nodes and host processes. It is possible to start more
than one node in the same running program, though if you do this they will
continue to send messages to one another using the supplied `Network.Transport`
backend.

Given a new node, there are two primitives for starting a new process.

{% highlight haskell %}
forkProcess :: LocalNode -> Process () -> IO ProcessId
runProcess  :: LocalNode -> Process () -> IO ()
{% endhighlight %}

Once we've spawned some processes, they can communicate with one another
using the messaging primitives provided by [distributed-processes][2],
which are well documented in the haddocks.

### What is Serializable

Processes can send data if the type implements the `Serializable` typeclass,
which is done indirectly by implementing `Binary` and deriving `Typeable`.
Implementations are already provided for primitives and some commonly used
data structures. As programmers, we see the messages in nice high-level form
(e.g., `Int`, `String`, `Ping`, `Pong`, etc), however these data have to be
encoded in order to be sent over a communications channel.

Not all types are `Serializable`, for example concurrency primitives such as
`MVar` and `TVar` are meaningless outside the context of threads with a shared
memory. Cloud Haskell programs remain free to use these constructs within
processes or within processes on the same machine though. If you want to
pass data between processes using *ordinary* concurrency primitives such as
`STM` then you're free to do so. Processes spawned locally can share
types such as `TMVar` just as normal Haskell threads would.

### Typed Channels

Channels provides an alternative to message transmission with `send` and `expect`.
While `send` and `expect` allow  transmission of messages of any `Serializable`
type, channels require a uniform type. Channels work like a distributed equivalent
of Haskell's `Control.Concurrent.Chan`, however they have distinct ends: a single
receiving port and a corollary send port.

Channels provide a nice alternative to *bare send and receive*, which is a bit
*unHaskellish*, because the processes message queue has messages of multiple
types, and we have to do dynamic type checking.

We create channels with a call to `newChan`, and send/receive on them using the
`{send,receive}Chan` primitives:

{% highlight haskell %}
channelsDemo :: Process ()
channelsDemo = do
    (sp, rp) <- newChan :: Process (SendPort String, ReceivePort String)
    
    -- send on a channel
    spawnLocal $ sendChan sp "hello!"
    
    -- receive on a channel
    m <- receiveChan rp
    say $ show m
{% endhighlight %}

Channels are particularly useful when you are sending a message that needs a
response, because the code that receives the response knows exactly where it
came from - i.e., it knows that it came from the `SendPort` connected to
the `ReceivePort` on which it just received a response.

Channels can sometimes allows message types to be simplified, as passing a
`ProcessId` to reply to isn't required. Channels are not so useful when you
need to spawn a process and then send a bunch a messages to it and wait for
replies, because we can’t send the `ReceivePort`.

ReceivePorts can be merged, so you can listen on several simultaneously. In the
latest version of [distributed-process][2], you can listen for *regular* messages
and on multiple channels at the same time, using `matchChan` in the list of
allowed matches passed `receive`.

### Linking and monitoring

Processes can be linked to other processes, nodes or channels. Links are unidirectional,
and guarantee that once the linked object *dies*, the linked process will also be
terminated. Monitors do not cause the *listening* process to exit, but rather they
put a `ProcessMonitorNotification` into the process' mailbox. Linking and monitoring
are foundational tools for *supervising* processes, where a top level process manages
a set of children, starting, stopping and restarting them as necessary.

### Stopping Processes

Some processes, like the *outer* process in the previous example, will run until
they've completed and then return their value. This is just as we find with IO action,
and there is an instance of `MonadIO` for the `Process` monad, so you can `liftIO` if
you need to evaluate IO actions.

Because processes are implemented with `forkIO` we might be tempted to stop
them by throwing an asynchronous exception to the process, but this is almost
certainly the wrong thing to do. Instead we might send a kind of poison pill,
which the process *ought* to handle by shutting down gracefully. Unfortunately
because of the asynchronous nature of sending, this is no good because `send`
will not fail under any circumstances. In fact, because `send` doesn't block,
we therefore have no way to know if the recipient existed at the time we sent the
poison pill. Even if the recipient did exist, we still have no guarantee that
the message we sent actually arrived - the network connection between the nodes
could have broken, for example. Making this *shutdown* protocol synchronous is
no good either - how long would we wait for a reply? Indefinitely?

Exit signals come in two flavours - those that can
be caught and those that cannot. A call to
`exit :: (Serializable a) => ProcessId -> a -> Process ()` will dispatch an
exit signal to the specified process. These *signals* can be intercepted and
handled by the destination process however, so if you need to terminate the
process in a brutal way, you can use the `kill :: ProcessId -> String -> Process ()`
function, which sends an exit signal that cannot be handled.

------
#### __An important note about exit signals__

Exit signals in Cloud Haskell are unlike asynchronous exceptions in regular
haskell code. Whilst processes *can* use asynchronous exceptions - there's
nothing stoping this since the `Process` monad is an instance of `MonadIO` -
exceptions thrown are not bound by the same ordering guarantees as messages
delivered to a process. Link failures and exit signals *might* be implemented
using asynchronous exceptions - that is the case in the current
implementation - but these are implemented in such a fashion that if you
send a message and *then* an exit signal, the message is guaranteed to arrive
first.

You should avoid throwing your own exceptions in code where possible. Instead,
you should terminate yourself, or another process, using the built-in primitives
`exit`, `kill` and `die`.

{% highlight haskell %}
exit pid reason  -- force `pid` to exit - reason can be any `Serializable` message
kill pid reason  -- reason is a string - the *kill* signal cannot be caught
die reason       -- as 'exit' but kills *us*
{% endhighlight %}

The `exit` and `kill` primitives do essentially the same thing, but catching
the specific exception thrown by `kill` is impossible, making `kill` an
*untrappable exit signal*. Of course you could trap **all** exceptions, but
you already know that's a very bad idea right!?

The `exit` primitive is a little different. This provides support for trapping
exit signals in a generic way, so long as your *exit handler* is able to
recognise the underlying type of the 'exit reason'. This (reason for exiting)
is stored as a raw `Message`, so if your handler takes the appropriate type
as an input (and therefore the `Message` can be decoded and passed to the
handler) then the handler will run. This is pretty much the same approach as
exception handling using `Typeable`, except that we decide whether or not the
exception can be handled based on the type of `reason` instead of the type of
the exception itself.

Calling `die` will immediately raise an exit signal (i.e., `ProcessExitException`)
in the calling process.

----

### Rethinking the Task Layer

[Towards Haskell in the Cloud][12] describes a multi-layered architecture, in
which manipulation of concurrent processes and message passing between them
is managed in the *process layer*, whilst a higher level API described as the
*task layer* provides additional features such as

* automatic recovery from failures
* data centric processing model
* a promise (or *future*) abstraction, representing the result of a calculation that may or may not have yet completed

The [distributed-process-platform][18] library implements parts of the
*task layer*, but takes a very different approach to that described
in the original paper and implemented by the [remote][14] package. In particular,
we diverge from the original design and defer to many of the principles
defined by Erlang's [Open Telecom Platform][13], taking in some well established
Haskell concurrency design patterns alongside.

In fact, [distributed-process-platform][18] does not really consider the
*task layer* in great detail. We provide an API comparable to remote's
`Promise` in [Control.Distributed.Process.Platform.Async][17]. This API however,
is derived from Simon Marlow's [Control.Concurrent.Async][19] package, and is not
limited to blocking queries on `Async` handles in the same way. Instead our
[API][17] handles both blocking and non-blocking queries, polling
and working with lists of `Async` handles. We also eschew throwing exceptions
to indicate asynchronous task failures, instead handling *task* and connectivity
failures using monitors. Users of the API need only concern themselves with the
`AsyncResult`, which encodes the status and (possibly) outcome of the computation
simply.

------

{% highlight haskell %}
demoAsync :: Process ()
demoAsync = do
  -- spawning a new task is fairly easy - this one is linked
  -- so if the caller dies, the task is killed too
  hAsync :: Async String
  hAsync <- asyncLinked $ (expect >>= return) :: Process String

  -- there is a rich API of functions to query an async handle
  AsyncPending <- poll hAsync   -- not finished yet

  -- we can cancel the task if we want to
  -- cancel hAsync
  
  -- or cancel it and wait until it has exited
  -- cancelWait hAsync
  
  -- we can wait on the task and timeout if it's still busy
  Nothing <- waitTimeout (within 3 Seconds) hAsync
  
  -- or finally, we can block until the task is finished!
  asyncResult <- wait hAsync
  case asyncResult of
      (AsyncDone res) -> say (show res)  -- a finished task/result
      AsyncCancelled  -> say "it was cancelled!?"
      AsyncFailed (DiedException r) -> say $ "it failed: " ++ (show r)
{% endhighlight %}

------

Unlike remote's task layer, we do not exclude IO, allowing tasks to run in
the `Process` monad and execute arbitrary code. Providing a monadic wrapper
around `Async` that disallows side effects is relatively simple, and we
do not consider the presence of side effects a barrier to fault tolerance
and automated process restarts. Erlang does not forbid *IO* in its processes,
and yet that doesn't render supervision trees ineffective. They key is to
provide a rich enough API that statefull processes can recognise whether or
not they need to provide idempotent initialisation routines.

The utility of preventing side effects using the type system is, however, not
to be sniffed at. A substrate of the `ManagedProcess` API is under development
that provides a *safe process* abstraction in which side effect free computations
can be embedded, whilst reaping the benefits of the framework.

Work is also underway to provide abstractions for managing asynchronous tasks
at a higher level, focussing on workload distribution and load regulation.

The kinds of task that can be performed by the async implementations in
[distributed-process-platform][3] are limited only by their return type:
it **must** be `Serializable` - that much should've been obvious by now.
The type of asynchronous task definitions comes in two flavours, one for
local nodes which require no remote-table or static serialisation dictionary,
and another for tasks you wish to execute on remote nodes.

{% highlight haskell %}
-- | A task to be performed asynchronously.
data AsyncTask a =
    AsyncTask 
      {
        asyncTask :: Process a -- ^ the task to be performed
      }
  | AsyncRemoteTask 
      {
        asyncTaskDict :: Static (SerializableDict a)
          -- ^ the serializable dict required to spawn a remote process
      , asyncTaskNode :: NodeId
          -- ^ the node on which to spawn the asynchronous task
      , asyncTaskProc :: Closure (Process a)
          -- ^ the task to be performed, wrapped in a closure environment
      }
{% endhighlight %}

The API for `Async` is fairly rich, so reading the haddocks is suggested.

#### Managed Processes

Looking at *typed channels*, we noted that their insistence on a specific input
domain was more *haskell-ish* than working with bare send and receive primitives.
The `Async` sub-package also provides a type safe interface for receiving data,
although it is limited to running a computation and waiting for its result.

The [Control.Distributed.Processes.Platform.ManagedProcess][21] API provides a
number of different abstractions that can be used to achieve similar benefits
in your code. It works by introducing a standard protocol between your process
and the *world around*, which governs how to handle request/reply processing,
exit signals, timeouts, sleep/hibernation with `threadDelay` and even provides
hooks that terminating processes can use to clean up residual state.

The [API documentation][21] is quite extensive, so here we will simply point
out the obvious differences. A implemented implemented with `ManagedProcess`
can present a type safe API to its callers (and the server side code too!),
although that's not its primary benefit. For a very simplified example:

{% highlight haskell %}
add :: ProcessId -> Double -> Double -> Process Double
add sid x y = call sid (Add x y)

divide :: ProcessId -> Double -> Double
          -> Process (Either DivByZero Double)
divide sid x y = call sid (Divide x y )

launchMathServer :: Process ProcessId
launchMathServer =
  let server = statelessProcess {
      apiHandlers = [
          handleCall_   (\(Add    x y) -> return (x + y))
        , handleCallIf_ (input (\(Divide _ y) -> y /= 0)) handleDivide
        , handleCall_   (\(Divide _ _) -> divByZero)
        ]
    }
  in spawnLocal $ start () (statelessInit Infinity) server >> return ()
  where handleDivide :: Divide -> Process (Either DivByZero Double)
        handleDivide (Divide x y) = return $ Right $ x / y

        divByZero :: Process (Either DivByZero Double)
        divByZero = return $ Left DivByZero
{% endhighlight %}

Apart from the types and the imports, that is a complete definition. Whilst
it's not so obvious what's going on here, the key point is that the invocation
of `call` in the client facing API functions handles **all** of the relevant
waiting/blocking, converting the async result and so on. Note that the
*managed process* does not interact with its mailbox at all, but rather
just provides callback functions which take some state and either return a
new state and a reply, or just a new state. The process is *managed* in the
sense that its mailbox is under someone else's control.

More complex examples of the `ManagedProcess` API can be seen in the
[Managed Processes tutorial][22]. API documentation for HEAD is available
[here][21].

### Supervision Trees

TBC

### Process Groups

TBC

[1]: http://www.haskell.org/haskellwiki/Cloud_Haskell
[2]: https://github.com/haskell-distributed/distributed-process
[3]: https://github.com/haskell-distributed/distributed-process-platform
[4]: http://hackage.haskell.org/package/distributed-static
[5]: http://hackage.haskell.org/package/rank1dynamic
[6]: http://hackage.haskell.org/package/network-transport
[7]: http://hackage.haskell.org/package/network-transport-tcp
[8]: https://github.com/haskell-distributed/network-transport-inmemory
[9]: https://github.com/haskell-distributed/network-transport-composed
[10]: http://hackage.haskell.org/package/distributed-process-simplelocalnet
[11]: http://hackage.haskell.org/package/distributed-process-azure
[12]: http://research.microsoft.com/en-us/um/people/simonpj/papers/parallel/remote.pdf
[13]: http://en.wikipedia.org/wiki/Open_Telecom_Platform
[14]: http://hackage.haskell.org/package/remote
[15]: http://www.erlang.org/doc/design_principles/sup_princ.html
[16]: http://www.erlang.org/doc/man/supervisor.html
[17]: /static/doc/distributed-process-platform/Control-Distributed-Process-Platform-Async.html
[18]: https://github.com/haskell-distributed/distributed-process-platform
[19]: http://hackage.haskell.org/package/async
[20]: /wiki/networktransport.html
[21]: /static/doc/distributed-process-platform/Control-Distributed-Process-Platform-ManagedProcess.html
[22]: /tutorials/tutorial3.html
