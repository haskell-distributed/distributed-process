

[2012.02.22] {File for notes on results}
============================================================

Here's a run of the PingTCP benchmark on a 3.1 ghz Intel Westmere running RHEL 6.2:

     ./PingTCP.exe server 8080 &
     sleep 1
     server: creating TCP connection
     server: awaiting client connection
     ./PingTCP.exe client 0.0.0.0 8080 1000
     server: listening for pings
     warming up
     estimating clock resolution...
     mean is 1.963031 us (320001 iterations)
     found 38180 outliers among 319999 samples (11.9%)
       32741 (10.2%) low severe
       5439 (1.7%) high severe
     estimating cost of a clock call...
     mean is 43.17696 ns (15 iterations)
     found 2 outliers among 15 samples (13.3%)
       1 (6.7%) high mild
       1 (6.7%) high severe

     benchmarking PingTCP
     collecting 100 samples, 1 iterations each, in estimated 8.073997 s
     mean: 77.01177 ms, lb 76.92822 ms, ub 77.14009 ms, ci 0.950
     std dev: 526.1251 us, lb 366.2692 us, ub 803.1751 us, ci 0.950

(That was without -O2)

   -----

Running a C benchmark on the same machine it takes 5.6 seconds to do
200K ping pongs.

 => 28 us  avg latency for C

I got 72 us avg latency using PingTCP.  The named pipes backend took
19.8s and was using 100% CPU.  That's a 99 us latency.

Pipes with unix-bytestring take 11.0 seconds, but still use 100% CPU.

 =>  55 us latency for Pipes with unix-bytestring



[2012.02.24] {After Adam's strictness refactoring.}
============================================================

100K ping/pongs, 1 trial:

    PingTCP:           7.34s   >80%CPU 
    PingTCPTransport:  19s     ~60%CPU
    PingPipes:         6.36s   >=100%CPU

Timing instead using 100 trials of 1000 pingpongs via criterion gives
results consistent with the above.  Here are the mean latencies:

    PingTCP:           72 us
    PingTCPTransport:  191 us
    PingPipes:         65 us

