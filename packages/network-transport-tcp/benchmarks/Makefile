# The "Just Ping" tests measure ping latency with as little overhead as possible

NUMPINGS=100000
ROOT=../..
INCLUDES=-i${ROOT}/network-transport/src -i${ROOT}/network-transport-tcp/src

# Enable for profiling
# PROF_GHC=-prof -fprof-auto
# PROF_EXE=+RTS -pa -RTS

GCC=gcc 
GHC=ghc -rtsopts -XRankNTypes -XScopedTypeVariables -XDeriveDataTypeable -XCPP -XGeneralizedNewtypeDeriving -optP-include -optPcabal_macros.h

all: NewTransport.ps Indirection.ps Headers.ps

Threaded.ps: JustPingC.data JustPingHaskellNT.data JustPingHaskell.data
	gnuplot ./Threaded.gnuplot

NewTransport.ps: JustPingHaskell.data \
                 JustPingTransport.data
	gnuplot ./NewTransport.gnuplot								 

Indirection.ps: JustPingWithHeader.data \
                JustPingThroughChan.data \
                JustPingThroughMVar.data \
                JustPingTwoSocketPairs.data \
                JustPingTwoSocketPairsND.data \
								JustPingTransport.data
	gnuplot ./Indirection.gnuplot

Headers.ps: JustPingC.data \
            JustPingHaskellNT.data \
            JustPingHaskell.data \
            JustPingWithHeader.data \
            JustPingOneRecv.data \
            JustPingCacheHeader.data
	gnuplot ./Headers.gnuplot

JustPingC.exe: JustPingC.c
	$(GCC) -O2 -o JustPingC.exe JustPingC.c

JustPingHaskellNT.exe: JustPingHaskell.hs
	$(GHC) -O2 $(PROF_GHC) -o JustPingHaskellNT.exe JustPingHaskell.hs

JustPingTwoSocketPairsND.data: JustPingTwoSocketPairs.exe
	time ./$< $(NUMPINGS) --NoDelay $(PROF_EXE) 2>$@

%.data : %.exe
	time ./$< $(NUMPINGS) $(PROF_EXE) 2>$@

%.exe :: %.hs
	$(GHC) -O2 $(PROF_GHC) -threaded -o $@ --make $< $(INCLUDES)

.PHONY: clean
clean:
	rm -f *.data *.ps *.pdf *.o *.hi *.exe 

# vi:set noexpandtab:
