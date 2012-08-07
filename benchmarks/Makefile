
# Makefile for building and running benchmarks.
# Usage:
#    make all
#    make run

#--------------------------------------------------------------------------------
# Settings

# By default, run 100K ping-pongs, for one trial:
size  = 100000
trials = 1
# Alternatively, you can run "make run1 size=1000 trials=100", for example.

ifeq ($(GHC),)
  GHC=ghc
endif

BENCHS= PingPongTCP.exe PingPongTCPTransport.exe  
# PingPongPipes.exe SendTransport.exe

all: $(BENCHS)
$(BENCHS): %.exe: %.hs
	$(GHC) -O2 -rtsopts -threaded --make $(INCLUDES) $< -o $@

#-------------------------------------------------------------------------------
# Shorthands for running benchmarks:

run: run1 run2 
# Disabled: run3 run4

# Benchmark raw sockets without network-transport:
run1: runBaseline
runBaseline:
	./PingPongTCP.exe server 8080 &
	sleep 1
	time ./PingPongTCP.exe client 0.0.0.0 8080 $(size) $(trials)
        # Kill the server:
	killall PingPongTCP.exe

run2: runTCP
runTCP:
	./PingPongTCPTransport.exe      server 0.0.0.0 8080 sourceAddr.txt &
	sleep 1
        # Run 100K ping-pongs, for one trial:
	time ./PingPongTCPTransport.exe client 0.0.0.0 8081 sourceAddr.txt $(size) $(trials)
        # Kill the server:
#	killall PingPongTCPTransport.exe

run3: runPipes
runPipes:
	./PingPongPipes.exe server sourceAddr &
	sleep 1
	time ./PingPongPipes.exe client sourceAddr $(size) $(trials)
        # Kill the server:
	killall PingPongPipes.exe

# This benchmark measures throughput rather than latency
# Here 'size' means message size rather than number of pings:
run4: runTPT
runTPT:
	./SendTransport.exe server 0.0.0.0 8080 sourceAddr &
	sleep 1
	./SendTransport.exe client 0.0.0.0 8081 sourceAddr $(size)
	killall SendTransport.exe

# Run multiple sizes:
runTPTs:
	$(MAKE) runTPT size=1000
	$(MAKE) runTPT size=5000
	$(MAKE) runTPT size=10000
	$(MAKE) runTPT size=50000
	$(MAKE) runTPT size=100000

clean: 
	rm -f *.hi *.o *.exe
