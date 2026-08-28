const crypto = require('crypto');

const JWT_SECRET = process.argv[2];
if (!JWT_SECRET) { console.error('Usage: node derive-key.cjs <JWT_SECRET>'); process.exit(1); }

// Derive EC seed (same as workflow Python script)
const ecSeed = crypto.createHmac('sha512', Buffer.from(JWT_SECRET))
  .update(Buffer.from('asymmetric_es256'))
  .digest()
  .subarray(0, 32);

// Derive kid
const kidBytes = crypto.createHmac('sha512', Buffer.from(JWT_SECRET))
  .update(Buffer.from('jwks_kid'))
  .digest()
  .subarray(0, 16);
const hex = kidBytes.toString('hex');
const kid = hex.replace(/(.{8})(.{4})(.{4})(.{4})(.{12})/, '$1-$2-$3-$4-$5');

// Create P-256 private key from the raw seed bytes using PKCS#8 DER encoding
// The seed IS the private key scalar (d value)
function createPrivateKeyFromSeed(seed) {
  const { createECDH } = crypto;
  const ecdh = createECDH('prime256v1');
  ecdh.setPrivateKey(seed);
  const pubKey = ecdh.getPublicKey(); // uncompressed: 04 || x(32) || y(32)
  
  // Build PKCS#8 DER structure for EC private key
  const x = pubKey.subarray(1, 33);
  const y = pubKey.subarray(33, 65);
  const d = seed;
  
  // ECPrivateKey structure
  const ecPrivKey = Buffer.concat([
    Buffer.from([0x02, 0x20]), // INTEGER (32 bytes)
    d,
    Buffer.from([0xa0, 0x0a]), // [0] OID
    Buffer.from([0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]), // P-256
    Buffer.from([0xa1, 0x43]), // [1] BIT STRING (public key)
    Buffer.from([0x03, 0x41, 0x00]), // BIT STRING header
    pubKey, // 65 bytes uncompressed
  ]);
  
  // PKCS#8 PrivateKeyInfo
  const pkcs8 = Buffer.concat([
    Buffer.from([0x30, 0x81, 0x87]), // SEQUENCE
    Buffer.from([0x02, 0x01, 0x00]), // INTEGER (version = 0)
    Buffer.from([0x30, 0x0e]), // SEQUENCE (algorithm)
    Buffer.from([0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]), // OID P-256
    Buffer.from([0x05, 0x00]), // NULL
    Buffer.from([0x04, 0x81, 0x75]), // OCTET STRING
    ecPrivKey,
  ]);
  
  return crypto.createPrivateKey({ key: pkcs8, format: 'der', type: 'pkcs8' });
}

function b64url(buf) {
  return Buffer.from(buf).toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}

function signES256(role) {
  const iat = 1700000000;
  const exp = iat + 315360000;
  const header = b64url(Buffer.from(JSON.stringify({ alg: 'ES256', typ: 'JWT', kid })));
  const body = b64url(Buffer.from(JSON.stringify({ role, iss: 'supabase', iat, exp })));
  
  const pk = createPrivateKeyFromSeed(ecSeed);
  const sig = crypto.createSign('SHA256').update(header + '.' + body).sign(pk, 'buffer');
  
  // DER encode the EC signature to raw r||s (64 bytes)
  // Parse DER SEQUENCE { INTEGER r, INTEGER s }
  const derSig = sig;
  let offset = 2; // skip SEQUENCE tag + length
  const rLen = derSig[offset + 1];
  const r = derSig.subarray(offset + 2, offset + 2 + rLen);
  offset = offset + 2 + rLen;
  const sLen = derSig[offset + 1];
  const s = derSig.subarray(offset + 2, offset + 2 + sLen);
  
  // Pad r and s to 32 bytes each
  const rPadded = Buffer.alloc(32); r.copy(rPadded, 32 - r.length);
  const sPadded = Buffer.alloc(32); s.copy(sPadded, 32 - s.length);
  
  return header + '.' + body + '.' + b64url(Buffer.concat([rPadded, sPadded]));
}

console.log('ANON_KEY=' + signES256('anon'));
console.log('SERVICE_ROLE_KEY=' + signES256('service_role'));
console.log('KID=' + kid);
