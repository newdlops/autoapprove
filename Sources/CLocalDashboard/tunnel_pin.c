#include "CLocalDashboard.h"
#include <CommonCrypto/CommonKeyDerivation.h>
int aa_derive_tunnel_pin(const void *pin, unsigned long length, const void *salt, void *digest) {
    if(!pin || length<6 || length>12 || !salt || !digest)return -1;
    return CCKeyDerivationPBKDF(kCCPBKDF2,pin,length,salt,16,kCCPRFHmacAlgSHA256,600000,digest,32);
}
