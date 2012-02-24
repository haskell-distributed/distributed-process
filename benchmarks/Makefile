
# Run 100K ping-pongs, for one trial:
pings  = 100000
trials = 1
# You can run "make run1 pings=1000 trials=100" for example.


# Disable this to test installed packages only:
INCLUDES= -i../network-transport/src -i../network-transport-pipes/src 

ifeq ($(GHC),)
  GHC=ghc
endif

all: pipes tcp baseline
baseline:
	$(GHC) -O2 -rtsopts -threaded --make $(INCLUDES) PingTCP.hs -o PingTCP.exe 
tcp:
	$(GHC) -O2 -rtsopts -threaded --make $(INCLUDES) PingTCPTransport.hs -o PingTCPTransport.exe 
pipes:
	$(GHC) -O2 -rtsopts -threaded --make $(INCLUDES) PingPipes.hs -o PingPipes.exe 

run: run1 run2

run1: runBaseline
runBaseline:
	./PingTCP.exe server 8080 &
	sleep 1
	time ./PingTCP.exe client 0.0.0.0 8080 $(pings) $(trials)
        # Kill the server:
	killall PingTCP.exe

run2: runTCP
runTCP:
	./PingTCPTransport.exe      server 0.0.0.0 8080 sourceAddr &
	sleep 1
        # Run 100K ping-pongs, for one trial:
	time ./PingTCPTransport.exe client 0.0.0.0 8081 sourceAddr $(pings) $(trials)
        # Kill the server:
	killall PingTCPTransport.exe

run3: runPipes
runPipes:
	./PingPipes.exe server sourceAddr &
	sleep 1
	time ./PingPipes.exe client sourceAddr $(pings) $(trials)
        # Kill the server:
	killall PingPipes.exe

clean: 
	rm -f *.hi *.o *.exe
