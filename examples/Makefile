

ifeq ($(GHC),)
  GHC=ghc
endif

all:
	$(GHC) -threaded --make DemoTransport.hs -o DemoTransport.exe -fforce-recomp


clean: 
	rm -f *.hi *.o DemoTransport.exe

