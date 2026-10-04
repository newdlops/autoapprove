Locally bundled browser terminal, no CDN requests.

@xterm/xterm 6.0.0 and @xterm/addon-fit 0.11.0
Upstream: https://github.com/xtermjs/xterm.js
Corresponding MIT licenses are included in this directory.

Local xterm.js patch: all four generated style elements copy
the per-response nonce from meta[name=autoapprove-style-nonce] before insertion.
This permits renderer styles without allowing inline scripts or unsafe-inline
styles in the app's Content-Security-Policy. No terminal/input/parser changes.
The DOM cell style writer uses CSSOM (style.cssText) instead of setAttribute.
When updating xterm, preserve and verify these four nonce assignments and the
CSSOM writer against the app's strict Content-Security-Policy.
