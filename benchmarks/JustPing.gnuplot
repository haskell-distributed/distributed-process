set title "Roundtrip (us)"
set yrange [0:300]
plot "JustPingHaskell.data" every 100::50 title "Haskell (TCP)", \
     "JustPingC.data" every 100::0 title "C"
