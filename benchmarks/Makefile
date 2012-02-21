

ifeq ($(GHC),)
  GHC=ghc
endif

all: pipes tcp transport
tcp:
	$(GHC) -O2 -threaded --make -i../network-transport/src PingTCP.hs -o PingTCP.exe 
transport:
	$(GHC) -O2 -threaded --make -i../network-transport/src PingTransport.hs -o PingTransport.exe 
pipes:
	$(GHC) -O2 -threaded --make -i../network-transport/src PingPipes.hs -o PingPipes.exe 

run: runBaseline runTransport
runBaseline:
	./PingTCP.exe server 8080 &
	sleep 1
	./PingTCP.exe client 0.0.0.0 8080 1000

runTransport:
	./PingTransport.exe server 0.0.0.0 8080 sourceAddr &
	sleep 1
	./PingTransport.exe client 0.0.0.0 8081 sourceAddr 1000

clean: 
	rm -f *.hi *.o *.exe
