
# Run 100K ping-pongs, for one trial:
size  = 100000
trials = 1
# You can run "make run1 size=1000 trials=100" for example.


# Disable this to test installed packages only:
INCLUDES= -i../network-transport/src -i../network-transport-pipes/src 

# Enable for profiling 
# PROFILING=-prof -fprof-auto

ifeq ($(GHC),)
  GHC=ghc
endif

BENCHS= PingTCP.exe PingTCPTransport.exe PingPipes.exe SendTransport.exe

all: $(BENCHS)
$(BENCHS): %.exe: %.hs
	$(GHC) -O2 -rtsopts -threaded --make $(INCLUDES) $(PROFILING) $< -o $@

#-------------------------------------------------------------------------------
# Shorthands for running benchmarks:

run: run1 run2 run3 run4

run1: runBaseline
runBaseline:
	./PingTCP.exe server 8080 &
	sleep 1
	time ./PingTCP.exe client 0.0.0.0 8080 $(size) $(trials)
        # Kill the server:
	killall PingTCP.exe

run2: runTCP
runTCP:
	./PingTCPTransport.exe      server 0.0.0.0 8080 sourceAddr &
	sleep 1
        # Run 100K ping-pongs, for one trial:
	time ./PingTCPTransport.exe client 0.0.0.0 8081 sourceAddr $(size) $(trials)
        # Kill the server:
	killall PingTCPTransport.exe

run3: runPipes
runPipes:
	./PingPipes.exe server sourceAddr &
	sleep 1
	time ./PingPipes.exe client sourceAddr $(size) $(trials)
        # Kill the server:
	killall PingPipes.exe

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
