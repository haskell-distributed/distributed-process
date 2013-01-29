---
layout: wiki
title: New Backend and Transport Design
wiki: Outline
---

Outline
=======

This is a outline of the problem and a design for a new `distributed-process` (Cloud Haskell) implementation.

Compared to the initial implementation, the aim is not to change the main API but to give more flexibility in the network layer, both in the transport technology:

 * shared memory, 
 * IP,
 * HPC interconnects

and in configuration:

 * neighbour discovery/startup
 * network parameter tuning

The approach we take is to abstract over a network transport layer. That is, we define an interface between the upper layers of the distributed-process library (the `Process` monad and all that) and the network transport layer. We keep the interface to the upper layers essentially the same but are able to switch the transport layer.

### Use cases

 * networking for the `distributed-process` package
 * networked versions of DPH
 * other distributed/cluster programming use cases

Non-use cases:

 * general client/server networking
 * general internet services

In addition to `distributed-process`, it is hoped that an independent transport layer will be useful for other middleware and applications. It is not the intention however to be compatible and interoperable with existing protocols like HTTP. This transport system is for use cases where you control all the nodes involved. It is not intended for use cases where you need to interoperate with other independent components.

An good comparison is Erlang and use cases where people choose Erlang's native VM-to-VM network protocol rather than picking a standard protocol like HTTP.

----

### Network transports

There are "transports" that focus purely on transporting data. Examples are:

 * TCP/IP, UDP
 * InfiniBand/Verbs (or one of their other 10 protocols or so)
 * pipes (Unix/Win32)
 * NUMA transports (shared memory)
 * PCI transports 
 * Portals
 * CCI

The last two (Portals and CCI) are libraries that attempt to provide consistent semantics over multiple lower protocols. CCI appears particularly promising.

Then there are transports embedded in generally much larger libraries, and
layered on one or more of the above. Examples are:

 * MPI
 * ZeroMQ
 * ssh
 * SSL sockets
 * HTTP connections
 * RPC connections (many flavours) 

Generally this second group of transports have the following attributes:

* The semantics are richer.
* There is a bigger overhead (especially noticeable for low-latency HPC
  transports, less so for IP transports)
* There are large libraries of functionality available. Unless re-writing
  those libraries from scratch is desirable, it's nice to have access to
  all of it.
* The failure semantics are very different from that of the underlying low
  level transport.

Experience indicates that it is difficult to use a "fat" protocol in place of a thin one merely for the purpose of moving packets (due to the different semantics, and particularly failure semantics). If you use a fat one, you typically want to be using the richer semantics and/or library of additional routines.

### Terminology: Addresses and Endpoints

An address is a resource name. This is a value and has value semantics. In particular it can be serialised and deserialised.

An endpoint is a networking level object. That is, it is a stateful object with identity and it has reference semantics.

### Approach

We want to provide a common interface to multiple different transports. We only intend to provide relatively limited functionality for sending messages between nodes in a network. We are primarily targeting lower level transports like IP not the higher level transports with richer semantics like HTTP.

We want enough to allow code to be written against the interface to actually be reusable with multiple transports. We want to be able to take full advantage of the configuration/tuning parameters for each underlying transport so that we can maximise performance. These intentions tend to pull in opposite directions.

To give us some leeway, we do not require that our common interface covers all the functionality of each of the underlying transports. We are happy to divide functionality between a common interface and interfaces specific to each transport backend. We do however want to maximise the functionality covered by the common interface so that we can maximise the amount of code that can be reusable between multiple transports.

Looking at different transports, the area where they differ the most is in initialisation and initial configuration, addresses and per-connection performance parameters. Our approach to partitioning into common and per-backend interfaces is to put configuration, initialisation, initial neighbour creation/discovery and initial connection establishment into per-backend interfaces and to put everything else into the common interface. This enables us to write reusable code that works on the assumption that we already have connections to our neighbour nodes. From there we can create extra connections and send messages.

A particular challenge is the per-connection performance parameters. It is vital for performance to be able to set these, but they differ significantly between transports. Our proposed solution to this is described below in the detailed design.

----

### System outline

The following diagram shows dependencies between the various modules for the initial Cloud Haskell implementation. Arrows represent explicit module dependencies.

    +------------------------------+
    |        Application           |
    +------------------------------+
                  |
                  V
    +------------------------------+
    |        Cloud Haskell         |
    +------------------------------+
                  |
                  V
    +------------------------------+
    | Haskell network (IP) library |
    +------------------------------+

As the diagram indicates, the initial implementation is monolithic and uses a single specific transport (TCP/IP).

The next diagram shows the various modules that are envisaged in the new design. We partition the system into the Cloud Haskell layer and a separate network transport layer. Each of the two layers has backend packages for different transports.

{% highlight %}
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
{% endhighlight %}

We still expect applications to use the the Cloud Haskell layer directly. Additionally the application also depends on a specific Cloud Haskell backend, which provides functions to allow the initialisation of the transport layer using whatever topology might be appropriate to the application.

Complete applications will necessarily depend on a specific Cloud Haskell backend and would require (hopefully minor) code changes to switch backend. However libraries of reusable distributed algorithms could be written that depend only on the Cloud Haskell package.

Both the Cloud Haskell interface and implementation make use of the transport interface. This also serves as an interface for the transport implementations, which may for example, be based on some external library written in Haskell or C.

Typically a Cloud Haskell backend will depend on a single transport implementation. There may be several different Cloud Haskell backends that all make use of the same transport implementation but that differ in how they discover or create peers. For example one backend might be designed for discovering peers on a LAN by broadcasting, while another might create peers by firing up new VMs using some cloud system such as EC2. Both such backends could still use the same TCP transport implementation.

This example also illustrates somewhat the distinction between a transport implementation and a Cloud Haskell backend. The transport implementation is that one deals with the low level details of the network transport while the other makes use of a transport implementation to initialise a Cloud Haskell node. Part of the reason for the separation is that the network layer is intended to be reusable on its own without having to use the Cloud Haskell layer.


### Model overview

We will now focus on the transport layer.

Before describing the interfaces in detail we will give an overview of the networking model that our interfaces use. In particular we will focus on the common part of the interface rather than the per-backend parts.

Compared to traditional networking interfaces, like the venerable socket API, our model is a little different looking. The socket API has functionality for creating listening sockets and trying to establish connections to foreign addresses (which may or may not exist).

By contrast, our model is much more like a set of Unix processes connected via anonymous unix domain sockets (which are much like ordinary unix pipes). In particular, unix domain sockets can be created anonymously with two ends (see socketpair(2)) and either end may be passed between processes over existing sockets. Note that this arrangement only allows communication via existing connections: new sockets can be made and can be passed around, but only to processes that are already part of the network graph. It does not provide any method for making connections to processes not already connected into the network graph.

This anonymous unix domain socket model has the advantage of simplicity. There is no need for addresses: socket endpoints are simply created anonymously and passed between processes. Obviously this simplicity comes at the cost of not actually being able to establish new networks from scratch -- only to make new connections within existing networks. By putting the establishment of initial connections outside the common interface, we allow that aspect to be different for each network transport and network topology. We can write distributed algorithms that are reusable with multiple transports, on the assumption that the network peers are already known.

We hope this is a reasonable compromise, otherwise it is hard to include connection creation in the common interface since each transport has its own address spaces and parameters for new connections.

Our model is almost as simple as the anonymous unix domain socket model. We have to make it work with real networks, without the assistance of a shared OS. Unlike with unix domain sockets where both ends can be moved (and indeed shared) between processes, we differentiate the source and target endpoints and only allow the source endpoint to be moved around. Additionally, because we cannot actually move a stateful object like a source endpoint from one node to another, we re-introduce the notion of an address. However it is a severely limited notion of address: we cannot make new addresses within the common interface, only take the address of existing target endpoints. Those addresses can then be sent by value over existing links and used to create source endpoints. Thus every address created in this way uniquely identifies a target endpoint.

This model gives us something like many-to-one connections. The target endpoint cannot be "moved". The source endpoint can be "copied" and all copies can be used to send messages to the target endpoint.


### Connection kinds and behaviours

The above overview covers our primary kind of connection. Overall we provide four kinds of connection.

 1. many-to-one, reliable ordered delivery of arbitrary sized messages
 2. many-to-one, reliable unordered delivery of arbitrary sized messages
 3. many-to-one, unreliable delivery of messages with bounded size
 4. multicast one-to-many, unreliable delivery of messages with bounded size

The first one is the primary kind of connection, used in most circumstances while the other three are useful in more specialised cases. The first three are all ordinary point-to-point connections with varying degrees of reliability and ordering guarantee. We provide only datagram/message style connections, not stream style.

For our primary kind of connection, we stipulate that it provides reliable ordered delivery of arbitrary sized messages. More specifically:

 * Message/datagram (rather than stream oriented)
 * Arbitrary message size
 * Non-corruption, that is messages are delivered without modification and are
   delivered whole or not at all. 
 * Messages are delivered at most once
 * Messages are delivered in-order. Subsequent messages are not delivered
   until earlier ones are delivered. This only applies between messages sent
   between the same pair of source and target endpoints -- there is no
   ordering between messages sent from different source endpoints to the same
   target endpoint.
 * Somewhat-asynchronous send is permitted:
    * send is not synchronous, send completing does not imply successful
      delivery
    * send side buffering is permitted but not required
    * receive side buffering is permitted but not required
    * send may block (e.g. if too much data is in flight or destination buffers
      are full)
 * Mismatched send/receive is permitted.
      It is not an error to send without a thread at the other end already
      waiting in receive (but it may block).
                
These properties are based on what we can get with (or build on top of) tcp/ip, udp/ip, unix IPC, MPI and the CCI HPC transport. (In particular CCI emphasises the property that a node should be able to operate with receive buffer size that is independent of the number of connections/nodes it communicates with unlike tcp/ip which has a buffer per connection. Also, CCI allows unexpected receipt of small messages but requires pre-arrangement for large transfers so the receive side can prepare buffers).

For the reliable unordered connections the ordering requirement is dropped while all others are preserved.

For the unreliable connections (both point to point and multicast) the ordering, at-most-once and arbitrary message size requirements are dropped. All others are preserved. For these unreliable connections there may be an upper limit on message length and there is a way to discover that limit on a per-connection basis for established connections.

While transport implementations must guarantee the provision of the reliable ordered connection kind (and the unordered and unreliable variants can obviously be emulated at no extra cost in terms of the reliable ordered kind), transport implementations do not need to guarantee the provision of multicast connections. In many transports, including IP, the availability of multicast connections cannot be relied upon. Transport clients have to be prepared for the creation of multicast connections to fail. Since this is the case even for transports that can support multicast, we use the same mechanism for transports that have no multicast support at all.


### Blocking vs. non-blocking send and receive

For sending or receiving messages, one important design decision is how it interacts with Haskell lightweight threads. Almost all implementations are going to consist of a Haskell-thread blocking layer built on top of a non-blocking layer. We could choose to put the transport interface at the blocking or non-blocking layer. We have decided to go for a design that is blocking at the Haskell thread level. This makes the backend responsible for mapping blocking calls into something non-blocking at the OS thread level. That is, the backend must ensure that a blocking send/receive only blocks the Haskell thread, not all threads on that core. In the general situation we anticipate having many Haskell threads blocked on network IO while other Haskell threads continue doing computation. (In an IP backend we get this property for free because the existing network library implements the blocking behaviour using the IO manager.)


### Transport common interface

We start with a Transport. Creating a Transport is totally backend dependent. More on that later.

A Transport lets us create new connections. Our current implementation provides ordinary reliable many-to-one connections, plus the multicast one-to-many connections. It does not yet provide unordered or unreliable many-to-one connections, but these will closely follow the interface for the ordinary reliable many-to-one connections.

{% highlight haskell %}
data Transport = Transport
  { newConnectionWith :: Hints -> IO TargetEnd
  , newMulticastWith  :: Hints -> IO MulticastSourceEnd
  , deserialize       :: ByteString -> Maybe Address
  }
{% endhighlight %}

We will start with ordinary connections and look at multicast later. 

We will return later to the meaning of the hints. We have a helper function for the common case of default hints.

{% highlight haskell %}
newConnection :: Transport -> IO TargetEnd
newConnection transport = newConnectionWith transport defaultHints
{% endhighlight %}

The `newConnection` action creates a new connection and gives us its `TargetEnd`. The `TargetEnd` is a stateful object representing one endpoint of the connection. For the corresponding source side, instead of creating a stateful `SourceEnd` endpoint, we can take the address of any `TargetEnd`:

{% highlight haskell %}
address :: TargetEnd -> Address
{% endhighlight %}

The reason for getting the address of the target rather than `newConnection` just giving us a `SourceEnd` is that usually we only want to create a `SourceEnd` on remote nodes not on the local node.

An `Address` represents an address of an existing endpoint. It can be serialised and copied to other nodes. On the remote node the Transport's `deserialize` function is is used to reconstruct the `Address` value. Once on the remote node, a `SourceEnd` can created that points to the `TargetEnd` identified by the `Address`.

{% highlight haskell %}
data Address = Address
  { connectWith :: SourceHints -> IO SourceEnd
  , serialize   :: ByteString
  }
{% endhighlight %}

Again, ignore the hints for now.

{% highlight haskell %}
connect :: Address -> IO SourceEnd
connect address = connectWith address defaultSourceHints
{% endhighlight %}

The `connect` action makes a stateful endpoint from the address. It is what really establishes a connection. After that the `SourceEnd` can be used to send messages which will be received at the `TargetEnd`.

The `SourceEnd` and `TargetEnd` are then relatively straightforward. They are both stateful endpoint objects representing corresponding ends of an established connection.

{% highlight haskell %}
newtype SourceEnd = SourceEnd
  { send :: [ByteString] -> IO ()
  }

newtype TargetEnd = TargetEnd
  { receive :: IO [ByteString]
  , address :: Address
  }
{% endhighlight %}

The `SourceEnd` sports a vectored send. That is, it allows sending a message stored in a discontiguous buffer (represented as a list of ByteString chunks). The `TargetEnd` has a vectored receive, though it is not vectored in the traditional way because it is the transport not the caller that handles the buffers and decides if it will receive the incoming message into a single contiguous buffer or a discontiguous buffer. Callers must always be prepared to handle discontiguous incoming messages or pay the cost of copying into a contiguous buffer.

The use of discontiguous buffers has performance advantages and with modern binary serialisation/deserialisation libraries their use is not problematic.

TODO: we have not yet covered closing connections, shutting down the transport and failure modes / exceptions.


### Unordered and unreliable connections

Though not currently implemented, these connection types follow the same pattern as the normal reliable ordered connection. The difference is just one of behaviour. The only difference is that the source end for unreliable connections lets one find out the maximum message length (i.e. the MTU).

The reason each of these are separate types is because they have different semantics and must not be accidentally confused. The reason we don't use a parameterised type is because typically the implementations will be different so this simplifies the implementation.

### Multicast connections

For the multicast connections, the address, source and target ends are analogous. The difference is that the address that is passed around is used to create a target endpoint so that multiple nodes can receive the messages sent from the source endpoint. It's sort of the dual of the ordinary many-to-one connections.

The `newMulticast` is the other way round compared to `newConnection`: it gives us a stateful `MulticastSourceEnd` from which we can obtain the address `MulticastAddress`.
    
{% highlight haskell %}
newMulticast :: Transport -> IO MulticastSourceEnd
newMulticast transport = newMulticastWith transport defaultHints

newtype MulticastSourceEnd = MulticastSourceEnd
  { multicastSend       :: [ByteString] -> IO ()
  , multicastAddress    :: MulticastAddress
  , multicastMaxMsgSize :: Int
  }

newtype MulticastAddress = MulticastAddress
  { multicastConnect :: IO MulticastTargetEnd
  }

newtype MulticastTargetEnd = MulticastTargetEnd
  { multicastReceive :: IO [ByteString]
  }
{% endhighlight %}

The multicast send has an implementation-defined upper bound on the message size which can be discovered on a per-connection basis.


### Creating a Transport via a transport backend

Creating a `Transport` object is completely backend-dependent. There is the opportunity to pass in a great deal of configuration data at this stage and to use types specific to the backend to do so (e.g. TCP parameters).

In the simplest case (e.g. a dummy in-memory transport) there might be nothing to configure:

{% highlight haskell %}
mkTransport :: IO Transport
{% endhighlight %}

For a TCP backend we might have:

{% highlight haskell %}
mkTransport :: TCPConfig -> IO Transport

data TCPConfig = ...
{% endhighlight %}

This `TCPConfig` can contain arbitrary amounts of configuration data. Exactly what it contains is closely connected with how we should set per-connection parameters.


### Connection parameters and hints

As mentioned previously, a major design challenge with creating a common transport interface is how to set various parameters when creating new connections. Different transports have widely different parameters, for example the parameters for a TCP/IP socket have very little in common with a connection using shared memory or infiniband. Yet being able to set these parameters is vital for performance in some circumstances.

The traditional sockets API handles this issue by allowing each different kind of socket to have its own set of configuration parameters. This is fine but it does not really enable reusable code. Generic, transport-independent code would need to get such parameters from somewhere, and if connections used for different purposes needed different parameters then the problem would be worse.

With our design approach it is easy to pass backend-specific types and configuration parameters when a transport is initialised, but impossible to pass backend-specific types when creating connections later on.

This makes it easy to use a constant set of configuration parameters for every connection. For example for our example TCP backend above we could have:

{% highlight haskell %}
data TCPConfig = TCPConfig {
       socketConfiguration :: SocketOptions
     }
{% endhighlight %}

This has the advantage that it gives us full access to all the options using the native types of the underlying network library (`SocketOptions` type comes from the `network` library).

The drawback of this simple approach is that we cannot set different options for different connections. To optimise performance in some applications or networks we might want to use different options for different network addresses (e.g. local links vs longer distance links). Similarly we might want to use different options for connections that are used differently, e.g. using more memory or network resources for certain high bandwidth connections, or taking different tradeoffs on latency vs bandwidth due to different use characteristics.

Allowing different connection options depending on the source and destination addresses is reasonably straightforward:

{% highlight haskell %}
data TCPConfig = TCPConfig {
       socketConfiguration :: Ip.Address -> Ip.Address
                           -> SocketOptions
     }
{% endhighlight %}

We simply make the configuration be a function that returns the connection options but is allowed to vary depending on the IP addresses involved. Separately this could make use of configuration data such as a table of known nodes, perhaps passed in by a cluster job scheduler.

Having options vary depending on how the connection is to be used is more tricky. If we are to continue with this approach then it relies on the transport being able to identify how a client is using (or intends to use) each connection. Our proposed solution is that when each new connection is made, the client supplies a set of "hints". These are not backend specific, they are general indications of what the client wants, or how the client intends to use the connection. The backend can then interpret these hints and transform them into the real network-specific connection options:

{% highlight haskell %}
data TCPConfig = TCPConfig {
       socketConfiguration :: Hints -> Ip.Address -> Ip.Address
                           -> SocketOptions
     }
{% endhighlight %}

What exactly goes into the hints will have to be considered in consultation with networking experts and people implementing backends. In particular it might indicate if bandwidth or latency is more important (e.g. to help decide if NO_DELAY should be used), if the connection is to be heavily or lightly used (to help decide buffer size) etc.

Using this approach may require a slightly different way of thinking about network programming and tuning than normal. Instead of specifying exactly what you want when creating each connection, you instead have to say how you intend to use the connection and then trust the backend to do the right thing. As noted however, the backend can take a custom configuration function that can pick very specific connection options, so long as it has enough information to distinguish the different classes of connections it is interested in.

Middleware like Cloud Haskell faces this problem anyway. Because it is transport independent it cannot use network-specific connection options anyway, they would have to be passed in as configuration. The best that middleware can do is to provide what detail it can on how each connection is likely to be used (the information available to it is fairly limited).

The only place where we are in a position to fully exploit all the network-specific connection options is when we have a complete (or near complete) application, using a specific transport, and we know what kind of network environment/hardware it will be used on. At this point, the ideal thing would indeed be to pass in a (perhaps complex) configuration when the application is launched, rather than modify the app and the middleware to pass down network-specific connection options to each place where connections are established. 

So hopefully if this model works, it might be quite nice in allowing the configuration to be more-or-less separated from the main program, allowing reusable code and still allowing turning to the network environment.

A useful analogy perhaps is CSS. It allows medium-specific (screen, print, voice etc) configuration to be specified in detail but separately from the content/structure. It allows general/constant options to be specified easily but allows a fair degree of discrimination between different HTML elements and allows distinction based on class or id names.

Following this analogy, it might prove useful in the most extreme cases to be able to give names/class/ids to connections in the hints, so that very detailed configurations could pick specific extra tweaks for specific connections or classes of connections.


### Cloud Haskell Usage

Given the Transport interface described above, the main Cloud Haskell implementation then needs to be rebuilt on top, providing the same API as now, except for the initialisation and peer discovery.

We were initially inclined to stipulate that the communication endpoints provided by our network transport be sufficiently lightweight that we could use one per cloud Haskell process (for each processes' input message queue) and one per cloud Haskell typed channel. The transport backend would then be responsible for doing any multiplexing necessary to give us lightweight endpoint resources. Unfortunately, when considering the design of the TCP/IP transport we could not find a sensible way to provide lightweight connection endpoints while at the same time avoiding "head of line" blocking and sensible buffering.

We therefore assume for the moment that transport connections are heavyweight resources and the Cloud Haskell implementation will have to take care of multiplexing messages between lightweight processes over these connections.

### Requirements for NodeID and ProcessId

A `ProcessId` serves two purposes, one is to communicate with a process directly and the other is to talk about that process to various service processes.

The main APIs involving a ProcessId are:

{% highlight haskell %}
getSelfPid :: ProcessM ProcessId
send  :: Serializable a => ProcessId -> a -> ProcessM ()
spawn :: NodeId -> Closure (ProcessM ()) -> ProcessM ProcessId
{% endhighlight %}

and linking and service requests:

{% highlight haskell %}
linkProcess    :: ProcessId -> ProcessM ()
monitorProcess :: ProcessId -> ProcessId -> MonitorAction -> ProcessM ()
nameQuery      :: NodeId -> String -> ProcessM (Maybe ProcessId)
{% endhighlight %}

A NodeId is used to enable us to talk to the service processes on a node.

The main APIs involving a `NodeId` are:

{% highlight haskell %}
getSelfNode :: ProcessM NodeId
spawn       :: NodeId -> Closure (ProcessM ()) -> ProcessM ProcessId
nameQuery   :: NodeId -> String -> ProcessM (Maybe ProcessId)
{% endhighlight %}


### NodeID and ProcessId representation

So for a ProcessId we need:

 * a communication endpoint to the process message queue so we can talk to the
   process itself 
 * the node id and an identifier for the process on that node so that we can
   talk to node services about that process

We define it as

{% highlight haskell %}
data ProcessId = ProcessId SourceEnd NodeId LocalProcessId
{% endhighlight %}

For a `NodeId` we need to be able to talk to the service processes on that node.

{% highlight haskell %}
data NodeId = NodeId SourceEnd
{% endhighlight %}

The single 'SourceEnd's is for talking to the basic service processes (ie the processes involved in implementing spawn and link/monitor). The service process Ids on each node are well known and need not be stored.

### Cloud Haskell channel representation

A cloud Haskell channel `SendPort` is similar to a `ProcessId` except that we do not need the `NodeId` because we do not need to talk about the process on the other end of the port.

{% highlight haskell %}
data SendPort a = SendPort SourceEnd
{% endhighlight %}

### Cloud Haskell backend initialisation and neighbour setup

In the first implementation, the initialisation was done using:

{% highlight haskell %}
remoteInit :: Maybe FilePath -> (String -> ProcessM ()) -> IO ()
{% endhighlight %}

This takes a configuration file (or uses an environment variable to find the same), an initial process, and it launches everything by reading the config, creating the local node and running the initial process. The initial process gets passed some role string obtained from the configuration file.

One of the slightly tricky issues with writing a program for a cluster is how to initialise everything in the first place: how to get each node talking to the appropriate neighbours.

The first cloud Haskell implementation provides:

{% highlight haskell %}
type PeerInfo = Map String [NodeId]
getPeers       :: ProcessM PeerInfo
findPeerByRole :: PeerInfo -> String -> [NodeId]
{% endhighlight %}

The implementation obtains this information using magic and configuration files.

Our new design moves this functionality out of the common interface entirely and into each Cloud Haskell backend. Consider for example the difference between neighbour setup in the following hypothetical Cloud Haskell backends:

 * A single-host multi-process model where we fork a number of OS processes (typically the number of CPU cores) and connect them by pipes. Here the neighbours are created at initialisation time and remain fixed thereafter.
 * A cluster backend that uses a cluster job scheduler to start a binary on each node and inform each one of a certain number of their peers (e.g. forming some hypercube topology).
 * A cloud backend that allows firing up VMs and starting new instances of the program on the new VMs. Here peers are not discovered but created, either at the start of the job or later to adjust for demand.
 * A backend providing something like the current approach where nodes are discovered by broadcasting on the LAN.

(As a side note: the latter three backends probably all use the same IP transport implementation, but they handle configuration and peer setup quite differently. The point being, there's more to a Cloud Haskell backend than a choice of transport implementation.)

We think that making an interface that covers all these cases would be end up rather clumsy. We believe it is simpler to have each of these backends provide their own way to initialise and discover/create peer nodes.

So in the new design, each application selects a Cloud Haskell backend by importing the backend and using an initialisation function from it.

Exactly how this is exposed has not been finalised. Internally we have an abstraction `LocalNode` which is a context object that knows about all the locally running processes on the node. We have:

{% highlight haskell %}
newLocalNode :: Transport -> IO LocalNode
runProcess   :: LocalNode -> Process () -> IO ()
{% endhighlight %}

and each backend will (at least internally) have a function something like:

{% highlight haskell %}
mkTransport :: {...config...} -> IO Transport
{% endhighlight %}

So the initialisation process is more or less

{% highlight haskell %}
init :: {...} -> Process () -> IO ()
init config initialProcess = do
  transport <- mkTransport config
  localnode <- newLocalNode transport
  runProcess localnode initialProcess
{% endhighlight %}

We could export all these things and have applications plug them together. 

Alternatively we might have each backend provide an initialisation that does it all in one go. For example the backend that forks multiple OS process might have an init like this:

{% highlight haskell %}
init :: Int -> ([NodeId] -> Process ()) -> IO ()
{% endhighlight %}

It takes a number of (OS) processes to fork and the initial (CH) process gets passes a corresponding number of remote `NodeId`s.

For the backend that deals with VMs in the cloud, it might have two initialisation functions, one for the master controller node and one for slave nodes.

{% highlight haskell %}
initMaster :: MasterConfig -> Process () -> IO ()
initSlave  :: SlaveConfig -> IO ()
{% endhighlight %}

Additionally it might have actions for firing up new VMs and running the program binary in slave mode on that VM:

{% highlight haskell %}
spawnVM    :: VmAccount -> IO VM
initOnVM   :: VM -> IO NodeId
shutdownVM :: VM -> IO ()
{% endhighlight %}

For example, supposing in our application's 'main' we call the IP backend and initialise a Transport object, representing the transport backend for cloud Haskell:

### Using multiple transports in the Cloud Haskell layer

There are contexts where it makes sense to use more than one `Transport` in a single distributed application. The most common example is likely to be a local transport, e.g. shared memory or pipes, for communication between nodes that share the same host, and a second transport using a network (IP or some HPC network). This is a very common setup with OpenMPI for example which allows the use of multiple "byte transfer layers" (BTLs) which correspond roughly to our notion of transport.

There are various challenges related to addressing. Assuming these can be solved, it should be considered how initialisation might be done when there are multiple transports / backends in use. We might want to have:

{% highlight haskell %}
newLocalNode :: [Transport] -> IO LocalNode
{% endhighlight %}

and expose it to the clients.

Alternatively, instead of allowing arbitrary stacks of transports, we might make each backend pick a fixed combination of transports. This is likely to work OK because the range of sensible combinations is not very large.


### Open issues

 * Is the configuration model sufficient and if so, the exact details of what goes into the connection hints. See the section above about connection parameters and hints.

 * If connection endpoints should be lightweight or heavyweight. We think leaving it as heavyweight is the way to go, but perhaps others can see a plausible design. See the section on the Cloud Haskell implementation built on Transport interface.

 * What style of initialisation API should be exposed to Cloud Haskell clients, and how this should be divided between the common interface and the backend interfaces. See the section on Cloud Haskell backend initialisation and neighbour setup.
