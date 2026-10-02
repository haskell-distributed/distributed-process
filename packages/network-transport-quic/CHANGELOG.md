Unreleased   Laurent P. René de Cotret <laurent.decotret@outlook.com> 0.2.0

* All the logical connections between two endpoints are now carried by a single QUIC connection (one stream
  each), rather than by one QUIC connection for each endpoint pairs. This has large performance implications:
  for multiple logical connections between two endpoints, `network-transport-quic` throughput increases by 50% over
  version 0.1.x, for a total of 3x throughput over `network-transport-quic`.
* Breaking change: A new `socketOptions` field to `QUICTransportConfig`, allowing the user to control the UDP socket
  underlying a connection.

2026-04-21  Laurent P. René de Cotret <laurent.decotret@outlook.com> 0.1.2

* Eliminated a rare race condition that allowed the transport to read messages before
  marking the connection as open, violating the interface expectations.
* Better handling of lost connections.
* Fixed rare race condition in establishing connections.

2026-01-01  Laurent P. René de Cotret <laurent.decotret@outlook.com> 0.1.1

* Documentation and packaging improvements.

2026-01-01  Laurent P. René de Cotret <laurent.decotret@outlook.com> 0.1.0

* Initial release.
