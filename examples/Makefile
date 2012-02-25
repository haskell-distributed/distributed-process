

ifeq ($(GHC),)
  GHC=ghc
endif

INCLUDES= -i../network-transport/src -i../network-transport-pipes/src -i../distributed-process/src 

EXMPLS= DemoTransport.exe DemoProcess.exe

all: $(EXMPLS)

$(EXMPLS): %.exe: %.hs
	$(GHC) -O2 -rtsopts -threaded --make $(INCLUDES) $< -o $@

# transport:
# 	$(GHC) -threaded --make -i../network-transport/src DemoTransport.hs -o DemoTransport.exe -fforce-recomp

clean: 
	rm -f *.hi *.o $(EXMPLS)
