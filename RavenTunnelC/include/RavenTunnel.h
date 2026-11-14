// Raven Tunnel: the Go archive's C interface (built from g/ into .build-tunnel).
#ifndef RAVEN_TUNNEL_H
#define RAVEN_TUNNEL_H

/// Starts the tunnel from a wg-quick config; returns the loopback SOCKS5 port, or 0 with *err set.
int RavenTunnelStart(char *config, char *user, char *pass, char **err);
void RavenTunnelStop(void);
/// Unix time of the latest handshake with any peer, 0 if none yet.
long long RavenTunnelLastHandshake(void);
/// "endpoint|address" for a valid config, or NULL with *err set.
char *RavenTunnelDescribe(char *config, char **err);
void RavenTunnelFree(char *p);
/// NULL when the two-peer loopback test passes, else the failure.
char *RavenTunnelSelfTest(void);

#endif
