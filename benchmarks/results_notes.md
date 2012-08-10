

[2012.08.07] {A new round of testing with the new API}
============================================================

Here's a run of the ping-pong benchmark on a 3.1 ghz Intel Westmere
running RHEL 6.2.  

    100K ping/pongs, 1 trial:
    PingTCP:           4.987     >90%CPU
    PingTCPTransport:  11.2s     ~65%CPU

That's with 3.9GB allocation and 99.2% productivity.

For reference, here are some old results from the previous incarnation
of network-transport back in February:

    100K ping/pongs, 1 trial:
	PingTCP:           7.34s   >80%CPU 
	PingTCPTransport:  19s     ~60%CPU
	PingPipes:         6.36s   >=100%CPU

    (Running a C benchmark on the same machine it takes 5.6 seconds to do
    200K ping pongs.  => 28 us  avg latency for C)
