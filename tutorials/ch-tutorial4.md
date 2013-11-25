---
layout: tutorial
sections: ['Introduction', 'Implementing the Client', 'Implementing the Server', 'Making use of Async', 'Wiring up Handlers', 'Putting it all together', 'Performance Considerations']
categories: tutorial
title: Managed Process Tutorial
---

### Introduction

The source code on which this tutorial is (loosely) based is kept on github,
and can be accessed [here][1]. Please note that this tutorial is
based on the stable (master) branch of distributed-process-platform.

### Managed Processes

The main idea behind a `ManagedProcess` is to separate the functional
and non-functional aspects of an actor. By functional, we mean whatever
application specific task the actor performs, and by non-functional
we mean the *concurrency* or, more precisely, handling of the process'
mailbox and its interaction with other actors (i.e., clients).

Another effect of the `ManagedProcess` API is to provide client code
with a typed (i.e., type specific) API for interacting with the process,
much as a `TypedChannel` does. We achieve this by writing and exporting
functions that operate on the types we want clients to see, and using
the API from `Control.Distributed.Process.Platform.ManagedProcess.Client`
to interact with the server.

Let's imagine we want to execute tasks on an arbitrary node, using a
mechanism much as we would with the `call` API from distributed-process.
As with `call`, we want the caller to block whilst the remote task is
executing, but we also want to put an upper bound on the number of
concurrent tasks. We will use `ManagedProcess` to implement a generic
task server with the following characteristics

* requests to enqueue a task are handled immediately
* callers however, are blocked until the task completes (or fails)
* an upper bound is placed on the number of concurrent running tasks

Once the upper bound is reached, tasks will be queued up for later
execution. Only when we drop below this limit will tasks be taken
from the backlog and executed.

`ManagedProcess` provides a basic protocol for *server-like* processes
such as this, based on the synchronous `call` and asynchronous `cast`
functions. We use these to determine client behaviour, and matching
*handler* functions are set up in the process itself, to process the
requests and (if required) replies. This style of programming will
already be familiar if you've used some combination of `send` in your
clients and the `receive [ match ... ]` family of functions to write
your servers. The primary difference here, is that the choice of when
to return to (potentially blocking on) the server's mailbox is taken
out of the programmer's hands, leaving the implementor to worry only
about the logic to be applied once a message of one type or another
is received.

### Implementing the client

Before we figure out the shape of our state, let's think about the types
we'll need to consume in the server process: the tasks we perform and the
maximum pool size.

{% highlight haskell %}
type PoolSize = Int
type SimpleTask a = Closure (Process a)
{% endhighlight %}

To submit a task, our clients will submit an action in the process
monad, wrapped in a `Closure` environment. We will use the `Addressable`
typeclass to allow clients to specify the server's location in whatever
manner suits them:

{% highlight haskell %}
-- enqueues the task in the pool and blocks
-- the caller until the task is complete
executeTask :: forall s a . (Addressable s, Serializable a)
            => s
            -> Closure (Process a)
            -> Process (Either String a)
executeTask sid t = call sid t
{% endhighlight %}

Although `call` is a synchronous protocol, communication with the
*server process* is out of band, both from the client and the server's
point of view. The server implementation chooses whether to reply to a
call request immediately, or defer its reply until a later stage (and
thus go back to receiving other messages in the meanwhile).

In terms of code, that's all there is to it for our client! Note that
the type signature we expose to our consumers is specific, and that
we do not expose them to either arbitrary messages arriving in their
mailbox or to exceptions being thrown in their thread. Instead we
return an `Either`. One very important thing about this approach is
that if the server replies with some other type (i.e., a type other
than `Either String a`) then our client will be blocked indefinitely!

There are several varieties of the `call` API that deal with error
handling in different ways. Consult the haddocks for more info about
these.

### Implementing the server

Back on the server, we write a function that takes our state and an
input message - in this case, the `Closure` we've been sent - and
have that update the process' state and possibility launch the task
if we have enough spare capacity.

{% highlight haskell %}
data Pool a = Pool a
{% endhighlight %}

I've called the state type `Pool` as we're providing a fixed size resource
pool from the consumer's perspective. We could think of this as a bounded
queue, latch or barrier of sorts, but that conflates the example a bit too
much. We parameterise the state by the type of data that can be returned
by submitted tasks.

The updated pool must store the task **and** the caller (so we can reply
once the task is complete). The `ManagedProcess.Server` API will provide us
with a `Recipient` value which can be used to reply to the caller at a later
time, so we'll make use of that here.

{% highlight haskell %}
acceptTask :: Serializable a
           => Pool a
           -> Recipient
           -> Closure (Process a)
           -> Process (Pool a)
{% endhighlight %}

For our example we will avoid using even vaguely exotic types to manage our
process' internal state, and stick to simple property lists. This is hardly
efficient, but that's fine for a test/demo.

{% highlight haskell %}
data Pool a = Pool {
    poolSize :: PoolSize
  , accepted :: [(Recipient, Closure (Process a))]
  } deriving (Typeable)
{% endhighlight %}

Given a pool of closures, we must now work out how to execute them
on the caller's behalf.

### Making use of Async

So **how** can we execute this `Closure (Process a)` without blocking the server
process itself? We will use the `Control.Distributed.Process.Platform.Async` API
to execute each task asynchronously and provide a means for waiting on the result.

In order to use the `Async` handle to get the result of the computation once it's
complete, we'll have to hang on to a reference. We also need a way to associate the
submitter with the handle, so we end up with one field for the active (running)
tasks and another for the queue of accepted (but inactive) ones, like so...

{% highlight haskell %}
data Pool a = Pool {
    poolSize :: PoolSize
  , active   :: [(Recipient, Async a)]
  , accepted :: [(Recipient, Closure (Process a))]
  } deriving (Typeable)
{% endhighlight %}

To turn that `Closure` environment into a thunk we can evaluate, we'll use the
built in `unClosure` function, and we'll pass the thunk to `async` and get back
a handle to the async task.

{% highlight haskell %}
proc <- unClosure task'
asyncHandle <- async proc
{% endhighlight %}

Of course, we decided not to block on each `Async` handle, and we can't sit
in a *loop* polling all the handles representing tasks we're running
(since no submissions would be handled whilst we're spinning waiting
for results). Instead we rely on monitors instead, so we must store a
`MonitorRef` in order to know which monitor signal relates to which
async task (and recipient).

{% highlight haskell %}
data Pool a = Pool {
    poolSize :: PoolSize
  , active   :: [(MonitorRef, Recipient, Async a)]
  , accepted :: [(Recipient, Closure (Process a))]
  } deriving (Typeable)
{% endhighlight %}

Finally we can implement the `acceptTask` function.

{% highlight haskell %}
acceptTask :: Serializable a
           => Pool a
           -> Recipient
           -> Closure (Process a)
           -> Process (Pool a)
acceptTask s@(Pool sz' runQueue taskQueue) from task' =
  let currentSz = length runQueue
  in case currentSz >= sz' of
    True  -> do
      return $ s { accepted = ((from, task'):taskQueue) }
    False -> do
      proc <- unClosure task'
      asyncHandle <- async proc
      ref <- monitorAsync asyncHandle
      taskEntry <- return (ref, from, asyncHandle)
      return s { active = (taskEntry:runQueue) }
{% endhighlight %}

If we're at capacity, we add the task (and caller) to the `accepted` queue,
otherwise we launch and monitor the task using `async` and stash the monitor
ref, caller ref and the async handle together in the `active` field. Prepending
to the list of active/running tasks is a somewhat arbitrary choice. One might
argue that heuristically, the younger a task is the less likely it is that it
will run for a long time. Either way, I've done this to avoid cluttering the
example with data structures, so we can focus on the `ManagedProcess` APIs.

Now we will write a function that handles the results. When a monitor signal
arrives, we lookup an async handle that we can use to obtain the result
and send it back to the caller. Because, even if we were running at capacity,
we've now seen a task complete (and therefore reduced the number of active tasks
by one), we will also pull off a pending task from the backlog (i.e., accepted),
if any exists, and execute it. As with the active task list, we're going to
take from the backlog in FIFO order, which is almost certainly not what you'd want
in a real application, but that's not the point of the example either.

The steps then, are

1. find the async handle for the monitor ref
2. pull the result out of it
3. send the result to the client
4. bump another task from the backlog (if there is one)
5. carry on

This chain then, looks like `wait h >>= respond c >> bump s t >>= continue`.

Item (3) requires special API support from `ManagedProcess`, because we're not
just sending *any* message back to the caller. We're replying to a specific `call`
that has taken place and is, from the client's perspective, still running.
The `ManagedProcess` API call for this is `replyTo`.

{% highlight haskell %}
taskComplete :: forall a . Serializable a
             => Pool a
             -> ProcessMonitorNotification
             -> Process (ProcessAction (Pool a))
taskComplete s@(Pool _ runQ _)
             (ProcessMonitorNotification ref _ _) =
  let worker = findWorker ref runQ in
  case worker of
    Just t@(_, c, h) -> wait h >>= respond c >> bump s t >>= continue
    Nothing          -> continue s
    where
      respond :: Recipient
              -> AsyncResult a
              -> Process ()
      respond c (AsyncDone       r) = replyTo c ((Right r) :: (Either String a))
      respond c (AsyncFailed     d) = replyTo c ((Left (show d)) :: (Either String a))
      respond c (AsyncLinkFailed d) = replyTo c ((Left (show d)) :: (Either String a))
      respond _      _              = die $ TerminateOther "IllegalState"

      bump :: Pool a -> (MonitorRef, Recipient, Async a) -> Process (Pool a)
      bump st@(Pool _ runQueue acc) worker =
        let runQ2  = deleteFromRunQueue worker runQueue in
        case acc of
          []           -> return st { active = runQ2 }
          ((tr,tc):ts) -> acceptTask (st { accepted = ts, active = runQ2 }) tr tc

findWorker :: MonitorRef
         -> [(MonitorRef, Recipient, Async a)]
         -> Maybe (MonitorRef, Recipient, Async a)
findWorker key = find (\(ref,_,_) -> ref == key)

deleteFromRunQueue :: (MonitorRef, Recipient, Async a)
                 -> [(MonitorRef, Recipient, Async a)]
                 -> [(MonitorRef, Recipient, Async a)]
deleteFromRunQueue c@(p, _, _) runQ = deleteBy (\_ (b, _, _) -> b == p) c runQ
{% endhighlight %}

That was pretty simple. We've dealt with mapping the `AsyncResult` to `Either` values,
which we *could* have left to the caller, but this makes the client facing API much
simpler to work with.

### Wiring up handlers

The `ProcessDefinition` takes a number of different kinds of handler. The only ones
_we_ care about are the call handler for submissions, and the handler that
deals with monitor signals.

Call and cast handlers live in the `apiHandlers` list of a `ProcessDefinition` and
must have the type `Dispatcher s` where `s` is the state type for the process. We
cannot construct a `Dispatcher` ourselves, but a range of functions in the
`ManagedProcess.Server` module exist to lift functions like the ones we've just
defined, to the correct type. The particular function we need is `handleCallFrom`,
which works with functions over the state, `Recipient` and call data/message.
All varieties of `handleCall` need to return a `ProcessReply`, which has the
following type:

{% highlight haskell %}
data ProcessReply s a =
    ProcessReply a (ProcessAction s)
  | NoReply (ProcessAction s)
{% endhighlight %}

There are also various utility functions in the API to construct a `ProcessAction`
and we make use of `noReply_` here, which constructs `NoReply` for us and
presets the `ProcessAction` to `ProcessContinue`, which goes back to receiving
messages from clients. We already have a function over our input domain, which
evaluates to a new state, so we end up with:

{% highlight haskell %}
storeTask :: Serializable a
          => Pool a
          -> Recipient
          -> Closure (Process a)
          -> Process (ProcessReply (Pool a) ())
storeTask s r c = acceptTask s r c >>= noReply_
{% endhighlight %}

In order to spell things out for the compiler, we need to put a type signature
in place at the call site too, so our final construct is

{% highlight haskell %}
handleCallFrom (\s f (p :: Closure (Process a)) -> storeTask s f p)
{% endhighlight %}

No such thing is required for `taskComplete`, as there's no ambiguity about its
type. Our process definition is finished, and here it is:

{% highlight haskell %}
poolServer :: forall a . (Serializable a) => ProcessDefinition (Pool a)
poolServer =
    defaultProcess {
        apiHandlers = [
          handleCallFrom (\s f (p :: Closure (Process a)) -> storeTask s f p)
        ]
      , infoHandlers = [
            handleInfo taskComplete
        ]
      } :: ProcessDefinition (Pool a)
{% endhighlight %}

Starting the pool is fairly simple and `ManagedProcess` has some utilities to help.
The `start` function takes an _initialising_ thunk, which must generate the initial
state and per-call timeout setting, and the process definition which we've already
encountered.

{% highlight haskell %}
simplePool :: forall a . (Serializable a)
              => PoolSize
              -> ProcessDefinition (Pool a)
              -> Process (Either (InitResult (Pool a)) TerminateReason)
simplePool sz server = start sz init' server
  where init' :: PoolSize -> Process (InitResult (Pool a))
        init' sz' = return $ InitOk (Pool sz' [] []) Infinity
{% endhighlight %}

### Putting it all together

Starting up a pool locally or on a remote node is just a matter of using `spawn`
or `spawnLocal` with `simplePool`. The second argument should add specificity to
the type of results the process definition operates on, e.g.,

{% highlight haskell %}
let s' = poolServer :: ProcessDefinition (Pool String)
in simplePool s s'
{% endhighlight %}

Defining tasks is as simple as making them remote-worthy:

{% highlight haskell %}
sampleTask :: (TimeInterval, String) -> Process String
sampleTask (t, s) = sleep t >> return s

$(remotable ['sampleTask])
{% endhighlight %}

And executing them is just as simple too. Given a pool which has been registered
locally as "mypool", we can simply call it directly:

{% highlight haskell %}
tsk <- return $ ($(mkClosure 'sampleTask) (seconds 2, "foobar"))
executeTask "mypool" tsk
{% endhighlight %}

In this tutorial, we've really just scratched the surface of the `ManagedProcess`
API. By handing over control of the client/server protocol to the framework, we
are able to focus on the code that matters, such as state transitions and decision
making, without getting bogged down (much) with the business of sending and
receiving messages, handling client/server failures and such like.

### Performance Considerations

We did not take much care over our choice of data structures. Might this have profound
consequences for clients? The LIFO nature of the pending backlog is surprising, but
we can change that quite easily by changing data structures. In fact, the code on which
this example is based uses `Data.Sequence` to provide both strictness and FIFO
execution ordering.

Perhaps more of a concern is the cost of using `Async` everywhere - remember
we used this in the *server* to handle concurrently executing tasks and obtaining
their results. The `Async` module is also used by `ManagedProcess` to handle the
`call` mechanism, and there *are* some overheads to using it. An invocation of
`async` will create two new processes: one to perform the calculation and another
to monitor the first and handle failure and/or cancellation. Spawning processes is
cheap, but not free as each process is a haskell thread, plus some additional book
keeping data.

The cost of spawning two processes for each computation/task might represent just that
bit too much overhead for some applications. In our next tutorial, we'll look at the
`Control.Distributed.Process.Platform.Task` API, which looks a lot like `Async` but
manages exit signals in a single thread and makes configurable task pools and task
supervision strategy part of its API.

[1]: https://github.com/haskell-distributed/distributed-process-platform/blob/master/tests/SimplePool.hs
