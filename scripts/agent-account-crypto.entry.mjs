// Browser-only primitives; bundled locally so LAN HTTP needs no SubtleCrypto/CDN.
import {x25519} from '@noble/curves/ed25519.js';
import {hkdf} from '@noble/hashes/hkdf.js';
import {sha256} from '@noble/hashes/sha2.js';
import {chacha20poly1305} from '@noble/ciphers/chacha.js';
window.AutoApproveAccountCrypto={x25519,hkdf,sha256,chacha20poly1305};
