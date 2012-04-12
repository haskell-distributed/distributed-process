set title "Roundtrip (us)"
set yrange [0:300]
plot "JustPingHaskell.data" every 10::5 title "Haskell (TCP)", \
     "JustPingC.data" every 10::0 title "C"
