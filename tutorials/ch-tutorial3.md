---
layout: tutorial
categories: tutorial
sections: ['Message Ordering', 'Selective Receive', 'Advanced Mailbox Processing']
title: Getting to know Processes
---

### Message Ordering

We have already met the `send` primitive, which is used to deliver
a message to another process. Here's a review of what we've learned
about `send` thus far:

1. sending is asynchronous (i.e., it does not block the caller)
2. sending _never_ fails, regardless of the state of the recipient process
3. even if a message is received, there is **no** guarantee *when* it will arrive
4. there are **no** guarantees that the message will be received at all

Asynchronous sending buys us several benefits. Improved concurrency is
possible, because processes do not need to block and wait for acknowledgements
and error handling need not be implemented each time a message is sent.
Consider a stream of messages sent from one process to another. If the
stream consists of messages `a, b, c` and we have seen `c`, then we know for
certain that we will have already seen `a, b` (in that order), so long as the
messages were sent to us by the same process.

When two concurrent process exchange messages, Cloud Haskell guarantees that
messages will be delivered in FIFO order, if at all. No such guarantee exists
between N processes where N > 1, so if processes _A_ and _B_ are both
communicating (concurrently) with process _C_, the ordering guarantee will
only hold for each pair of interactions, i.e., between _A_ and _C_ and/or
_B_ and _C_ the ordering will be guaranteed, but not between _A_ and _B_
with regards messages sent to _C_.

Of course, we may not want to process received messages in the
precise order which they arrived. When this need arises, the platform
supplies a set of primitives of allow the caller to _selectively_ process
their mailbox.

### Selective Receive

Processes dequeue messages (from their mailbox) using the [`expect`][1]
and [`recieve`][2] family of primitives. Both take an optional timeout,
which leads to the expression evaluating to `Nothing` if no matching input
is found.

The [`expect`][1] primitive blocks until a message matching the expected type
(of the expression) is found in the process' mailbox. If such a message can be
found by scanning the mailbox, it is dequeued and given to the caller. If no
message (matching the expected type) can be found, the caller (i.e., the
calling thread) is blocked until a matching message is delivered to the mailbox.
Let's take a look at this in action:

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
      Nothing <- expectTimeout 100000 :: Process String
      say first
      send third ()
{% endhighlight %}

This program will print `"hello"`, then `Nothing` and finally `pid://...`.
The first `expect` - labelled "third" because of the order in which it is
due to be received - **will** succeed, since the parent process sends its
`ProcessId` after the string "hello", yet the listener blocks until it can dequeue
the `ProcessId` before "expecting" a string. The second `expect` (labelled "first")
also succeeds, demonstrating that the listener has selectively removed messages
from its mailbox based on their type rather than the order in which they arrived.
The third `expect` will timeout and evaluate to `Nothing`, because only one string
is ever sent to the listener and that has already been removed from the mailbox.
The removal of messages from the process' mailbox based on type is what makes this
program viable - without this "selective receiving", the program would block and
never complete.

By contrast, the [`recieve`][2] family of primitives take a list of `Match`
objects, each derived from evaluating a [`match`][3] style primitive. This
subject was covered briefly in the first tutorial. Matching on messages allows
us to separate the type(s) of messages we can handle from the type that the
whole `receive` expression evaluates to.

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
explicitly specifying its type. For example, let's consider the `relay` primitive
that ships with distributed-process. This utility function starts a process that
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
relay !pid = receiveWait [ matchAny (\m -> forward m pid) ] >> relay pid
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

Both primitives are generalised to any `Monad m`, so we're not limited to operating in
the `Process` monad. Of the two, `unwrapMessage` is the simpler, taking a raw `Message`
and evaluating to `Maybe a` before returning that value in the monad `m`. If the type
of the raw `Message` does not match our expectation, the result will be `Nothing`, otherwise
`Just a`. The approach `handleMessage` takes is a bit more flexible, taking a function
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
`a -> Process b` we can compose the two and make our proxy server quite simply. We must
not forward messages for which the predicate function evaluates to `Just False`, nor
can we sensibly forward messages which the predicate function is unable to evaluate due
to type incompatibility. This leaves us with the definition found in distributed-process:

{% highlight haskell %}
proxy pid proc = do
  receiveWait [
      matchAny (\m -> do
                   next <- handleMessage m proc
                   case next of
                     Just True  -> forward m pid
                     Just False -> return ()  -- explicitly ignored
                     Nothing    -> return ()) -- un-routable
    ]
  proxy pid proc
{% endhighlight %}

Beyond simple relays and proxies, the raw message handling capabilities available in
distributed-process can be utilised to develop highly generic message processing code.
All the richness of the distributed-process-platform APIs (such as `ManagedProcess`) which
will be discussed in later tutorials are, in fact, built upon these families of primitives.

[1]: hackage.haskell.org/package/distributed-process/docs/Control-Distributed-Process.html#v:receiveWait
[2]: hackage.haskell.org/package/distributed-process/docs/Control-Distributed-Process.html#v:expect
[3]: http://hackage.haskell.org/package/distributed-process-0.4.2/docs/Control-Distributed-Process.html#v:match
[4]: /static/semantics.pdf
