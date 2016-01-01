---
layout: tutorial
categories: tutorial
sections: ['Message Ordering', 'Selective Receive', 'Advanced Mailbox Processing', 'Typed Channels', 'Process Lifetime', 'Monitoring And Linking', 'Getting Process Info','Monad Transformer Stacks' ]
title: 3. Getting to know Processes
---

### Message Ordering

We have already met the `send` primitive, used to deliver messages from one
process to another. Here's a review of what we've learned about `send` thus far:

1. sending is asynchronous (i.e., it does not block the caller)
2. sending _never_ fails, regardless of the state of the recipient process
3. even if a message is received, there is **no** guarantee *when* it will arrive
4. there are **no** guarantees that the message will be received at all

Asynchronous sending buys us several benefits. Improved concurrency is
possible, because processes need not block or wait for acknowledgements,
nor does error handling need to be implemented each time a message is sent.
Consider a stream of messages sent from one process to another. If the
stream consists of messages `a, b, c` and we have seen `c`, then we know for
certain that we will have already seen `a, b` (in that order), so long as the
messages were sent to us by the same peer process.

When two concurrent process exchange messages, Cloud Haskell guarantees that
messages will be delivered in FIFO order, if at all. No such guarantee exists
between N processes where N > 1, so if processes _A_ and _B_ are both
communicating (concurrently) with process _C_, the ordering guarantee will
only hold for each pair of interactions, i.e., between _A_ and _C_ and/or
_B_ and _C_ the ordering will be guaranteed, but not between _A_ and _B_
with regards messages sent to _C_.

Because the mailbox contains messages of varying types, when we `expect`
a message, we eschew the ordering because we're searching for a message
whose contents can be decoded to a specific type. Of course, we may _want_
to process messages in the precise order which they arrived. To achieve
this, we must defer the type checking that would normally cause a traversal
of the mailbox and extract the _raw_ message ourselves. This can be achieved
using `receive` and `matchAny`, as we will demonstrate later.

### Selective Receive

Processes dequeue messages (from their mailbox) using the [`expect`][1]
and [`receive`][2] family of primitives. Both take an optional timeout,
allowing the expression to evaluate to `Nothing` if no matching input
is found.

The [`expect`][1] primitive blocks until a message matching the expected type
(of the expression) is found in the process' mailbox. If a match is found by
scanning the mailbox, it is dequeued and returned, otherwise the caller
(i.e., the calling thread/process) is blocked until a message of the expected
type is delivered to the mailbox. Let's take a look at this in action:

{% highlight haskell %}
demo :: Process ()
demo = do
    listener <- spawnLocal listen
    send listener "hello"
    getSelfPid >>= send listener
    () <- expect
  where
    listen = do
      third <- expect :: Process ProcessId
      first <- expect :: Process String
      second <- expectTimeout 100000 :: Process String
      mapM_ (say . show) [first, second, third]
      send third ()
{% endhighlight %}

This program will print `"hello"`, then `Nothing` and finally `pid://...`.
The first `expect` - labelled "third" because of the order in which we
know it will arrive in our mailbox - **will** succeed, since the parent process
sends its `ProcessId` after the string "hello", yet the listener blocks until it
can dequeue the `ProcessId` before "expecting" a string. The second `expect`
(labelled "first") also succeeds, demonstrating that the listener has selectively
removed messages from its mailbox based on their type rather than the order in
which they arrived. The third `expect` will timeout and evaluate to `Nothing`,
because only one string is ever sent to the listener and that has already been
removed from the mailbox. The removal of messages from the process' mailbox based
on type is what makes this program viable - without this "selective receiving",
the program would block and never complete.

By contrast, the [`receive`][2] family of primitives take a list of `Match`
objects, each derived from evaluating a [`match`][3] style primitive. This
subject was covered briefly in the first tutorial. Matching on messages allows
us to separate the type(s) of messages we can handle from the type that the
whole `receive` expression evaluates to.

Consider the following snippet:

{% highlight haskell %}
usingReceive = do
  () <- receiveWait [
      match (\(s :: String) -> say s)
    , match (\(i :: Int)    -> say $ show i)
    ]
{% endhighlight %}

Note that each of the matches in the list must evaluate to the same type,
as the type signature indicates: `receiveWait :: [Match b] -> Process b`.

The behaviour of `receiveWait` differs from `receiveTimeout` in that it
blocks forever (until a match is found in the process' mailbox), whereas the
variant taking a timeout will return `Nothing` unless a match is found within
the specified time interval. Note that as with `System.Timeout`, the only
guarantee we have about a timeout based function is that it will not
expire _before_ the given interval. Both functions scan the mailbox in FIFO
order, evaluating the list of `match` expressions in declarative
(i.e., insertion) order until one of the matches succeeds or the operation
times out.

### Advanced Mailbox Processing

There are times when it is desirable to take a message from our mailbox without
explicitly specifying its type. Not only is this a useful capability, it is the
_only_ way to process messages in the precise order they were received.

To see how this works in practise, let's consider the `relay` primitive that
ships with distributed-process. This utility function starts a process that
simply dequeues _any_ messages it receives and forwards them to some other process.
In order to dequeue messages regardless of their type, this code relies on the
`matchAny` primitive, which has the following type:

{% highlight haskell %}
matchAny :: forall b. (Message -> Process b) -> Match b
{% endhighlight %}

Since forwarding _raw messages_ (without decoding them first) is a common pattern
in Cloud Haskell programs, there is also a primitive to do that for us:

{% highlight haskell %}
forward :: Message -> ProcessId -> Process ()
{% endhighlight %}

Given these types, we can see that in order to combine `matchAny` with `forward`
we need to either _flip_ `forward` and apply the `ProcessId` (leaving us with
the required type `Message -> Process b`) or use a lambda - the actual implementation
does the latter and looks like this:

{% highlight haskell %}
relay :: ProcessId -> Process ()
relay !pid = forever' $ receiveWait [ matchAny (\m -> forward m pid) ]
{% endhighlight %}

This is pretty useful, but since `matchAny` operates on the raw `Message` type,
we're limited in what we can do with the messages we receive. In order to delve
_inside_ a message, we have to know its type. If we have an expression that operates
on a specific type, we can _attempt_ to decode the message to that type and examine
the result to see whether the decoding succeeds or not. There are two primitives
we can use to that effect: `unwrapMessage` and `handleMessage`. Their types look like
this:

{% highlight haskell %}
unwrapMessage :: forall m a. (Monad m, Serializable a) => Message -> m (Maybe a)

handleMessage :: forall m a b. (Monad m, Serializable a) => Message -> (a -> m b) -> m (Maybe b)
{% endhighlight %}

Of the two, `unwrapMessage` is the simpler, taking a raw `Message` and evaluating to
`Maybe a` before returning that value in the monad `m`. If the type of the raw `Message`
does not match our expectation, the result will be `Nothing`, otherwise `Just a`.

The approach `handleMessage` takes is a bit more flexible, taking a function
from `a -> m b` and returning `Just b` if the underlying message is of type `a` (hence the
operation can be executed and evaluate to `Maybe b`) or `Nothing` if the message's type
is incompatible with the handler function.

Let's look at `handleMessage` in action. Earlier on we looked at `relay` from
distributed-process and now we'll consider its sibling `proxy` - this takes a predicate,
evaluates some input of type `a` and returns `Process Bool`, allowing us to run arbitrary
`Process` code in order to decide whether or not the `a` is eligible to be forwarded to
the relay `ProcessId`. The type of `proxy` is thus:

{% highlight haskell %}
proxy :: Serializable a => ProcessId -> (a -> Process Bool) -> Process ()
{% endhighlight %}

Since `matchAny` operates on `(Message -> Process b)` and `handleMessage` operates on
`a -> Process b` we can compose these to make our proxy server. We must not forward 
messages for which the predicate function evaluates to `Just False`, nor can we sensibly
forward messages which the predicate function is unable to evaluate due to type 
incompatibility. This leaves us with the definition found in distributed-process:

{% highlight haskell %}
proxy pid proc = do
  receiveWait [
      matchAny (\m -> do
                   next <- handleMessage m proc
                   case next of
                     Just True  -> forward m pid
                     Just False -> return ()  -- explicitly ignored
                     Nothing    -> return ()) -- un-routable / cannot decode
    ]
  proxy pid proc
{% endhighlight %}

Beyond simple relays and proxies, the raw message handling capabilities available in
distributed-process can be utilised to develop highly generic message processing code.
All the richness of the distributed-process-platform APIs (such as `ManagedProcess`) which
will be discussed in later tutorials are, in fact, built upon these families of primitives.

### Typed Channels

While being able to send and receive any `Serializable` datum is very powerful, the burden
of decoding types correctly at runtime is levied on the programmer and there are runtime
overheads to be aware of (which will be covered in later tutorials). Fortunately,
distributed-provides provides a type safe alternative to `send` and `receive`, in the form
of _Typed Channels_. Represented by distinct ends, a `SendPort a` (which is `Serializable`)
and `ReceivePort a` (which is not), channels are a lightweight and useful abstraction that
provides a type safe interface for interacting with processes separately from their primary
mailbox.

Channels are created with `newChan :: Process (SendPort a, ReceivePort a)`, with
messages sent via `sendChan :: SendPort a -> a -> Process ()`. The `ReceivePort` can be
passed directly to `receiveChan`, or used in a `receive{Wait, Timeout}` call via the
`matchChan` primitive, so as to combine mailbox scans with channel reads.

### Process Lifetime

A process will continue executing until it has evaluated to some value, or is abruptly
terminated either by crashing (with an un-handled exception) or being instructed to
stop executing. Deliberate stop instructions take one of two forms: a `ProcessExitException`
or `ProcessKillException`. As the names suggest, these _signals_ are delivered in the form
of asynchronous exceptions, however you should not to rely on that fact! After all,
we cannot throw an exception to a thread that is executing in some other operating
system process or on a remote host! Instead, you should use the [`exit`][5] and [`kill`][6]
primitives from distributed-process, which not only ensure that remote target processes
are handled seamlessly, but also maintain a guarantee that if you send a message and
*then* an exit signal, the message will be delivered to the destination process (via its
local node controller) before the exception is thrown - note that this does not guarantee
that the destination process will have time to _do anything_ with the message before it
is terminated.

The `ProcessExitException` signal is sent from one process to another, indicating that the
receiver is being asked to terminate. A process can choose to tell itself to exit, and the
[`die`][7] primitive simplifies doing so without worrying about the expected type for the 
action. In fact, [`die`][7] has slightly different semantics from [`exit`][5], since the
latter involves sending an internal signal to the local node controller. A direct consequence
of this is that the _exit signal_ may not arrive immediately, since the _Node Controller_ could 
be busy processing other events. On the other hand, the [`die`][7] primitive throws a
`ProcessExitException` directly in the calling thread, thus terminating it without delay.
In practise, this means the following two functions could behave quite differently at
runtime:

{% highlight haskell %}

-- this will never print anything...
demo1 = die "Boom" >> expect >>= say
  
-- this /might/ print something before it exits
demo2 = do
  self <- getSelfPid
  exit self "Boom"
  expect >>= say 
{% endhighlight %}

The `ProcessExitException` type holds a _reason_ field, which is serialised as a raw `Message`.
This exception type is exported, so it is possible to catch these _exit signals_ and decide how
to respond to them. Catching _exit signals_ is done via a set of primitives in
distributed-process, and the use of them forms a key component of the various fault tolerance
strategies provided by distributed-process-platform.

A `ProcessKillException` is intended to be an _untrappable_ exit signal, so its type is
not exported and therefore you can __only__ handle it by catching all exceptions, which
as we all know is very bad practise. The [`kill`][6] primitive is intended to be a
_brutal_ means for terminating process - e.g., it is used to terminate supervised child
processes that haven't shutdown on request, or to terminate processes that don't require
any special cleanup code to run when exiting - although it does behave like [`exit`][5]
in so much as it is dispatched (to the target process) via the _Node Controller_.

### Monitoring and Linking

Processes can be linked to other processes (or nodes or channels). A link, which is
unidirectional, guarantees that once any object we have linked to *exits*, we will also
be terminated. A simple way to test this is to spawn a child process, link to it and then
terminate it, noting that we will subsequently die ourselves. Here's a simple example,
in which we link to a child process and then cause it to terminate (by sending it a message
of the type it is waiting for). Even though the child terminates "normally", our process
is also terminated since `link` will _link the lifetime of two processes together_ regardless
of exit reasons.

{% highlight haskell %}
demo = do
  pid <- spawnLocal $ receive >>= return
  link pid
  send pid ()
  () <- receive
{% endhighlight %}

The medium that link failures uses to signal exit conditions is the same as exit and kill
signals - asynchronous exceptions. Once again, it is a bad idea to rely on this (not least
because it might change in some future release) and the exception type (`ProcessLinkException`)
is not exported so as to prevent developers from abusing exception handling code in this
special case. Since link exit signals cannot be caught directly, if you find yourself wanting
to _trap_ a link failure, you probably want to use a monitor instead.

Whilst the built-in `link` primitive terminates the link-ee regardless of exit reason,
distributed-process-platform provides an alternate function `linkOnFailure`, which only
dispatches the `ProcessLinkException` if the link-ed process dies abnormally (i.e., with
some `DiedReason` other than `DiedNormal`).

Monitors on the other hand, do not cause the *listening* process to exit at all, instead
putting a `ProcessMonitorNotification` into the process' mailbox. This signal and its
constituent fields can be introspected in order to decide what action (if any) the receiver
can/should take in response to the monitored process' death. Let's take a look at how
monitors can be used to determine both when and _how_ a process has terminated. Tucked
away in distributed-process-platform, the `linkOnFailure` primitive works in exactly this
way, only terminating the caller if the subject terminates abnormally. Let's take a look...

{% highlight haskell %}
linkOnFailure them = do
  us <- getSelfPid
  tid <- liftIO $ myThreadId
  void $ spawnLocal $ do
    callerRef <- P.monitor us
    calleeRef <- P.monitor them
    reason <- receiveWait [
             matchIf (\(ProcessMonitorNotification mRef _ _) ->
                       mRef == callerRef) -- nothing left to do
                     (\_ -> return DiedNormal)
           , matchIf (\(ProcessMonitorNotification mRef' _ _) ->
                       mRef' == calleeRef)
                     (\(ProcessMonitorNotification _ _ r') -> return r')
         ]
    case reason of
      DiedNormal -> return ()
      _ -> liftIO $ throwTo tid (ProcessLinkException us reason)
{% endhighlight %}

As we can see, this code makes use of monitors to track both processes involved in the
link. In order to track _both_ processes and react to changes in their status, it is
necessary to spawn a third process which will do the monitoring. This doesn't happen
with the built-in link primitive, but is necessary in this case since the link handling
code resides outside the _Node Controller_.

The two matches passed to `receiveWait` both handle a `ProcessMonitorNotification`, and
the predicate passed to `matchIf` is used to determine whether the notification we're
receiving is for the process that called us, or the _linked to_ process. If the former
dies, we've nothing more to do, since links are unidirectional. If the latter dies
however, we must examine the `DiedReason` the `ProcessMonitorNotification` provides us
with, to determine whether the subject exited normally (i.e., with `DiedNormal`).
If the exit was _abnormal_, we throw a `ProcessLinkException` to the original caller,
which is exactly how an ordinary link would behave.

Linking and monitoring are foundational tools for *supervising* processes, where a top level
process manages a set of children, starting, stopping and restarting them as necessary.

Exit signals in Cloud Haskell then, are unlike asynchronous exceptions in other
haskell code. Whilst a process *can* use asynchronous exceptions - there's
nothing stoping this since the `Process` monad is an instance of `MonadIO` -
as we've seen, exceptions thrown are not bound by the same ordering guarantees
as messages delivered to a process. Link failures and exit signals *might* work
via asynchronous exceptions - that is the case in the current implementation - but
these are implemented in such a fashion that if you send a message and *then* an
exit signal, the message is guaranteed to arrive first.

You should avoid throwing your own exceptions in code where possible. Instead,
you should terminate yourself, or another process, using the built-in primitives
`exit`, `kill` and `die`.

### Getting Process Info

The `getProcessInfo` function provides a means for us to obtain information about a running
process. The `ProcessInfo` type it returns contains the local node id and a list of
registered names, monitors and links for the process. The call returns `Nothing` if the
process in question is not alive.

### Monad Transformer Stacks 

It is not generally necessary, but it may be convenient in your application to use a 
custom monad transformer stack with the Process monad at the bottom. For example, 
you may have decided that in various places in your application you will make calls to
a network database. You may create a data access module, and it will need configuration information available to it in
order to connect to the database server. A ReaderT can be a nice way to make 
configuration data available throughout an application without
schlepping it around by hand. 

This example is a bit contrived and over-simplified but 
illustrates the concept. Consider the `fetchUser` function below, it runs in the `AppProcess`
monad which provides the configuration settings required to connect to the database:

{% highlight haskell %}

import Data.ByteString (ByteString)
import Control.Monad.Reader

-- imagine we have some database library
import Database.Imaginary as DB

data AppConfig = AppConfig {dbHost :: String, dbUser :: String}

type AppProcess = ReaderT AppConfig Process

data User = User {userEmail :: String}

-- Perform a user lookup using our custom app context
fetchUser :: String -> AppProcess (Maybe User)
fetchUser email = do
  db <- openDB
  user <- liftIO $ DB.query db email
  closeDB db
  return user

openDB :: AppProcess DB.Connection
openDB = do
  AppConfig host user <- ask
  liftIO $ DB.connect host user

closeDB :: DB.Connection -> AppProcess ()
closeDB db = liftIO (DB.close db)
  
{% endhighlight %}

So this would mostly work but it is not complete. What happens if an exception
is thrown by the `query` function? Your open database handle may not be
closed. Typically we manage this with the [bracket][brkt] function.

In the base library, [bracket][brkt] is defined in Control.Exception with this signature:

{% highlight haskell %}

bracket :: IO a	       --^ computation to run first ("acquire resource")
        -> (a -> IO b) --^ computation to run last ("release resource")
        -> (a -> IO c) --^ computation to run in-between
	-> IO c	 

{% endhighlight %}

Great! We pass an IO action that acquires a resource; `bracket` passes that
resource to a function which takes the resource and runs another action.
We also provide a release function which `bracket` is guaranteed to run 
even if the primary action raises an exception. 


Unfortunately, we cannot directly use `bracket` in our 
`fetchUser` function: openDB (resource acquisition) runs in the `AppProcess`
monad. If our functions ran in IO, we could lift the entire bracket computation into
our monad transformer stack with liftIO; but we cannot do that for the computations
*passed* to bracket.

It is perfectly possible to write our own bracket; `distributed-process` does this
for the `Process` monad (which is itself a newtyped ReaderT stack). Here is how that is done:


{% highlight haskell %}
-- | Lift 'Control.Exception.bracket'
bracket :: Process a -> (a -> Process b) -> (a -> Process c) -> Process c
bracket before after thing =
  mask $ \restore -> do
    a <- before
    r <- restore (thing a) `onException` after a
    _ <- after a
    return r

mask :: ((forall a. Process a -> Process a) -> Process b) -> Process b
mask p = do
    lproc <- ask
    liftIO $ Ex.mask $ \restore ->
      runLocalProcess lproc (p (liftRestore restore))
  where
    liftRestore :: (forall a. IO a -> IO a)
                -> (forall a. Process a -> Process a)
    liftRestore restoreIO = \p2 -> do
      ourLocalProc <- ask
      liftIO $ restoreIO $ runLocalProcess ourLocalProc p2

-- | Lift 'Control.Exception.onException'
onException :: Process a -> Process b -> Process a
onException p what = p `catch` \e -> do _ <- what
                                        liftIO $ throwIO (e :: SomeException)
{% endhighlight %}

`distributed-process` needs to do this sort of thing to keep its dependency
list small, but do we really want to write this for every transformer stack
we use in our own applications? No! And we do not have to, thanks to 
the [monad-control][mctrl] and [lifted-base][lbase] libraries.

[monad-control][mctrl] provides several typeclasses and helper functions
that make it possible to fully generalize the wrapping/unwrapping required
to keep transformer effects stashed away while actions run in the base monad. Of
most concern to end users of this library are the typeclass [MonadBase][mb] and [MonadBaseControl][mbc].
How it works is beyond the scope of this tutorial, but there is an excellent and thorough
explanation written by Michael Snoyman which is available [here][mctrlt].

[lifted-base][lbase] takes advantage of these typeclasses to provide lifted versions of many functions
in the Haskell base library. For example, [Control.Exception.Lifted][lexc] has a definition of
bracket that looks like this:

{% highlight haskell %}

bracket :: MonadBaseControl IO m	 
        => m a	       --^ computation to run first ("acquire resource")
        -> (a -> m b)  --^ computation to run last ("release resource")
        -> (a -> m c)  --^ computation to run in-between
        -> m c	 

{% endhighlight %}

It is just the same as the version found in base, except it is generalized to work
with actions in any monad that implements [MonadBaseControl IO][mbc]. [monad-control][mctrl] defines
instances for the standard transformers, but that instance requires the base monad 
(in this case, `Process`) to also have an instance of these classes.

To address this the [distributed-process-monad-control][dpmc] package
provides orphan instances of the `Process` type for both [MonadBase IO][mb] and [MonadBaseControl IO][mbc].
After importing these, we can rewrite our `fetchUser` function to use the instance of bracket
provided by [lifted-base][lbase].

{% highlight haskell %}

-- ...
import Control.Distributed.Process.MonadBaseControl ()
import Control.Exception.Lifted as Lifted

-- ...

fetchUser :: String -> AppProcess (Maybe User)
fetchUser email =
  Lifted.bracket openDB
                 closeDB
          	 $ \db -> liftIO $ DB.query db email
          

{% endhighlight %}

[lifted-base][lbase] also provides conveniences like [MVar][lmvar] and other concurrency primitives that
operate in [MonadBase IO][mb]. One benefit here is that your code is not sprinkled with
liftIO; but [MonadBaseControl IO][mbc] also makes things like a lifted [withMVar][lmvar-with] possible - which is
really just a specialization of [bracket][lbrkt]. You will also find lots of other libraries on hackage which
use these instances - at present count there are more than 150 [packages using it][reverse].

One note of caution: This instance can enable use of functions such as `forkIO` (or, `fork` from lifted-base[lbase]) which compromise invariants in the `Process` monad and can lead to confusing and subtle issues. Always use the Cloud Haskell functions such as spawnLocal instead.


[1]: hackage.haskell.org/package/distributed-process/docs/Control-Distributed-Process.html#v:receiveWait
[2]: hackage.haskell.org/package/distributed-process/docs/Control-Distributed-Process.html#v:expect
[3]: http://hackage.haskell.org/package/distributed-process-0.4.2/docs/Control-Distributed-Process.html#v:match
[4]: /static/semantics.pdf
[5]: http://hackage.haskell.org/package/distributed-process-0.4.2/docs/Control-Distributed-Process.html#v:exit
[6]: http://hackage.haskell.org/package/distributed-process-0.4.2/docs/Control-Distributed-Process.html#v:kill
[7]: http://hackage.haskell.org/package/distributed-process-0.4.2/docs/Control-Distributed-Process.html#v:die
[brkt]: http://hackage.haskell.org/package/base-4.6.0.1/docs/Control-Exception.html#v:bracket
[mctrl]: http://hackage.haskell.org/package/monad-control
[mb]: http://hackage.haskell.org/package/transformers-base-0.4.2/docs/Control-Monad-Base.html#t:MonadBase
[mbc]: http://hackage.haskell.org/package/monad-control-0.3.3.0/docs/Control-Monad-Trans-Control.html#t:MonadBaseControl
[lmvar]: http://hackage.haskell.org/package/lifted-base-0.2.2.2/docs/Control-Concurrent-MVar-Lifted.html#t:MVar
[lmvar-with]: http://hackage.haskell.org/package/lifted-base-0.2.2.2/docs/Control-Concurrent-MVar-Lifted.html#v:withMVar
[lbrkt]: http://hackage.haskell.org/package/lifted-base-0.2.2.2/docs/Control-Exception-Lifted.html#v:bracket
[lbase]: http://hackage.haskell.org/package/lifted-base
[dpmc]: http://hackage.haskell.org/package/distributed-process-monad-control
[mctrlt]: http://www.yesodweb.com/book/monad-control
[reverse]: http://packdeps.haskellers.com/reverse/monad-control
[lexc]: http://hackage.haskell.org/package/lifted-base-0.2.2.2/docs/Control-Exception-Lifted.html
