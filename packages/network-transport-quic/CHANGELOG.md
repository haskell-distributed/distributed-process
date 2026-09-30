2026-09-30  Laurent P. René de Cotret <laurent.decotret@outlook.com> 0.2.0

* Cleaned up the endpoint closing process, which required adding a new configuration to `QUICTransportConfig`.

2026-04-21  Laurent P. René de Cotret <laurent.decotret@outlook.com> 0.1.2

* Eliminated a rare race condition that allowed the transport to read messages before
  marking the connection as open, violating the interface expectations.
* Better handling of lost connections.
* Fixed rare race condition in establishing connections.

2026-01-01  Laurent P. René de Cotret <laurent.decotret@outlook.com> 0.1.1

* Documentation and packaging improvements.

2026-01-01  Laurent P. René de Cotret <laurent.decotret@outlook.com> 0.1.0

* Initial release.
