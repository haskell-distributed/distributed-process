

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

And here is my first attempt at running the SendTransport benchmark (TCP backend):

    ./SendTransport.exe client 0.0.0.0 8081 sourceAddr 1000
    mean: 38.10901 ms, lb 35.92353 ms, ub 39.30006 ms, ci 0.950
    std dev: 8.305210 ms, lb 4.935312 ms, ub 11.97144 ms, ci 0.950
    found 5 outliers among 100 samples (5.0%)
      5 (5.0%) low severe
    variance introduced by outliers: 94.703%
    variance is severely inflated by outliers

    ./SendTransport.exe client 0.0.0.0 8081 sourceAddr 5000
    mean: 32.87646 ms, lb 29.69947 ms, ub 35.62485 ms, ci 0.950
    std dev: 15.21419 ms, lb 12.39949 ms, ub 17.39441 ms, ci 0.950
    found 18 outliers among 100 samples (18.0%)
      18 (18.0%) low severe
    variance introduced by outliers: 98.928%
    variance is severely inflated by outliers

    ./SendTransport.exe client 0.0.0.0 8081 sourceAddr 10000
    mean: 32.87737 ms, lb 29.34305 ms, ub 35.62680 ms, ci 0.950
    std dev: 15.22060 ms, lb 12.40398 ms, ub 17.57401 ms, ci 0.950
    found 18 outliers among 100 samples (18.0%)
      18 (18.0%) low severe
    variance introduced by outliers: 98.929%
    variance is severely inflated by outliers

    ./SendTransport.exe client 0.0.0.0 8081 sourceAddr 50000
    mean: 1.351308 ms, lb 1.249680 ms, ub 1.548209 ms, ci 0.950
    std dev: 696.6768 us, lb 448.3538 us, ub 1.314057 ms, ci 0.950
    found 24 outliers among 100 samples (24.0%)
      3 (3.0%) high mild
      21 (21.0%) high severe
    variance introduced by outliers: 98.942%
    variance is severely inflated by outliers
    
    ./SendTransport.exe client 0.0.0.0 8081 sourceAddr 100000
    mean: 2.184967 ms, lb 2.030858 ms, ub 2.641543 ms, ci 0.950
    std dev: 1.235358 ms, lb 518.3995 us, ub 2.666540 ms, ci 0.950
    found 15 outliers among 100 samples (15.0%)
      4 (4.0%) low severe
      9 (9.0%) high severe
    variance introduced by outliers: 98.952%
    variance is severely inflated by outliers

This is quite odd.  so in addition to the high variance it would seem
that messages of size 50K or 100K are much FASTER to send than smaller
massages?
