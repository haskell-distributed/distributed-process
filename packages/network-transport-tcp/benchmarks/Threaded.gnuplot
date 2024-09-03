set xrange [0:100]
plot "JustPingC.data"         u 2:(1./100000.) smooth cumulative title "C", \
     "JustPingHaskellNT.data" u 2:(1./100000.) smooth cumulative title "Haskell", \
     "JustPingHaskell.data"   u 2:(1./100000.) smooth cumulative title "Haskell -threaded"
set terminal postscript color
set output "Threaded.ps"
plot "JustPingC.data"         u 2:(1./100000.) smooth cumulative title "C", \
     "JustPingHaskellNT.data" u 2:(1./100000.) smooth cumulative title "Haskell", \
     "JustPingHaskell.data"   u 2:(1./100000.) smooth cumulative title "Haskell -threaded"
