Haskell Distributed Project
===========================

This repository holds an implementation of [Cloud Haskell][1] based on the work
of Jeff Epstein, Andrew Black, and Simon Peyton-Jones.

At present, this repository hosts two packages:

* distributed-process
* network-transport

For more detailed information about the interfaces provided by these packages,
please refer to the [distributed-process repository wiki][2].

Examples
--------

Examples of the transport layer at work can be found in the `/examples` folder.

### DemoTransport.hs

The `DemoTransport.hs` file contains a number of different functions named
`demo#`. These functions demonstrate the use of the `Network.Transport` module.

To try them out, launch `ghci`, including the appropriate sources:

    ghci -idistributed-process/src -inetwork-transport/src examples/DemoTransport.hs
        
The first demo, `demo0` yields the following output when run with the TCP transport:

    *DemoTransport> tcp >>= demo0
    logServer: [Chunk "hello 1" Empty]
    logServer: [Chunk "hello 2" Empty]
    logServer: [Chunk "hello 3" Empty]
    logServer: [Chunk "hello 4" Empty]
    logServer: [Chunk "hello 5" Empty]
    logServer: [Chunk "hello 6" Empty]
    logServer: [Chunk "hello 7" Empty]
    logServer: [Chunk "hello 8" Empty]
    logServer: [Chunk "hello 9" Empty]
    logServer: [Chunk "hello 10" Empty]

See the source code for more details.

### DemoProcess.hs

The `DemoProcess.hs` file shows a very basic example of how to use the
`Control.Distributed.Process` module in conjunction with `Network.Transport.TCP`.
This is demonstrated using the `demo1` function:

    ghci -idistributed-process/src -inetwork-transport/src examples/DemoProcess.hs

The output of the example is as follows:

    *DemoProcess> demo1
    "Starting node"
    "Starting process"
    1: jim1 says: hi there
    2: bob1 says: hi there
    3: jim1 says: bye
    4: bob1 says: bye

### DemoTCP.hs

The `DemoTCP.hs` file demonstrates how a master can be connected to slaves
using the transport layer over TCP.
This example should be compiled in the usual fashion:

    ghc --make -idistributed-process/src -inetwork-transport/src examples/DemoTCP.hs

After compiling, the following will initialize a new master that waits
for two clients to connect on the local machine:

    ./examples/DemoTCP 127.0.0.1 8080 sourceAddrFile 2

Following this, two slaves should be created that will connect to the master:

    ./examples/DemoTCP 127.0.0.1 8081 sourceAddrFile
    ./examples/DemoTCP 127.0.0.1 8082 sourceAddrFile

Once the connection is established, the slaves will provide the master
with their `SourceAddr`. The master then decodes this, and sends a message
back. After processing this message, the slaves respond to the master,
which then outputs some data.

Benchmarks
----------

The `Transport.TCP` backend uses `Network.ByteString.Lazy` as its underlying
protocol, so we produce a benchmark that compares it directly with this.
Furthermore, the `Data.Binary` package is used for converting values
to `ByteStrings` for transmission.

The benchmarking is performed on the client side using criterion:
the server must be set up before benching is performed.

### Ping

This benchmark measures how quickly a sequence of ping/pong messages
are sent between a server and client. Full details can be found in:

    ./benchmarks/PingTCP.hs
    ./benchmarks/PingTransport.hs

### Send

This benchmark measures how quickly a number of bytes can be sent from
a client to a server. Full details can be found in the following files:

    ./benchmarks/SendTCP.hs
    ./benchmarks/SendTransport.hs

[1]: http://research.microsoft.com/en-us/um/people/simonpj/papers/parallel/remote.pdf
[2]: https://github.com/haskell-distributed/distributed-process/wiki
