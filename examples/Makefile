

ifeq ($(GHC),)
  GHC=ghc
endif

all:
	$(GHC) -threaded --make -i../network-transport/src DemoTransport.hs -o DemoTransport.exe -fforce-recomp


clean: 
	rm -f *.hi *.o DemoTransport.exe

