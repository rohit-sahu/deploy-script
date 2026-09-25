// Plain-JS TOTP helper for scripts/node/create-admin.mjs — mirrors the
// RFC 4226 (HOTP) / RFC 6238 (TOTP) implementation and AES-256-GCM
// "v1.<iv>.<authTag>.<ciphertext>" encrypted-secret format used by the
// actual app at runtime (src/lib/totp.ts in the rohit-sahu/portfolio repo
// this stack deploys — see docker-compose.yml's `web` build context). Keep
// both in sync if either changes: interoperable defaults only (SHA-1, 6
// digits, 30s period) — required for compatibility with Google
// Authenticator, which doesn't support SHA-256/512 or other digit counts.

import crypto from "node:crypto";

const DIGITS = 6;
const PERIOD_SECONDS = 30;
const ALGORITHM = "sha1";
const BASE32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

function base32Encode(buffer) {
  let bits = 0;
  let value = 0;
  let output = "";
  for (const byte of buffer) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      output += BASE32_ALPHABET[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) {
    output += BASE32_ALPHABET[(value << (5 - bits)) & 31];
  }
  return output;
}

function base32Decode(input) {
  const clean = input.toUpperCase().replace(/[\s=]+/g, "");
  let bits = 0;
  let value = 0;
  const bytes = [];
  for (const char of clean) {
    const idx = BASE32_ALPHABET.indexOf(char);
    if (idx === -1) continue;
    value = (value << 5) | idx;
    bits += 5;
    if (bits >= 8) {
      bytes.push((value >>> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return Buffer.from(bytes);
}

export function generateTotpSecret() {
  return base32Encode(crypto.randomBytes(20));
}

function hotp(secret, counter) {
  const counterBuffer = Buffer.alloc(8);
  counterBuffer.writeBigUInt64BE(counter);
  const hmac = crypto.createHmac(ALGORITHM, secret).update(counterBuffer).digest();
  const offset = hmac[hmac.length - 1] & 0xf;
  const binary =
    ((hmac[offset] & 0x7f) << 24) |
    ((hmac[offset + 1] & 0xff) << 16) |
    ((hmac[offset + 2] & 0xff) << 8) |
    (hmac[offset + 3] & 0xff);
  const otp = binary % 10 ** DIGITS;
  return otp.toString().padStart(DIGITS, "0");
}

function currentCounter(stepOffset = 0) {
  return BigInt(Math.floor(Date.now() / 1000 / PERIOD_SECONDS) + stepOffset);
}

// Used by create-admin.mjs's enrollment confirmation step (verify the
// user's live code matches before saving), with the same +/-1 step
// tolerance the server-side verifier uses.
export function verifyTotpToken(secretBase32, token, window = 1) {
  if (!/^\d{6}$/.test(token)) return false;
  const secret = base32Decode(secretBase32);
  const tokenBuffer = Buffer.from(token, "utf8");
  for (let errorWindow = -window; errorWindow <= window; errorWindow++) {
    const candidate = hotp(secret, currentCounter(errorWindow));
    const candidateBuffer = Buffer.from(candidate, "utf8");
    if (crypto.timingSafeEqual(candidateBuffer, tokenBuffer)) return true;
  }
  return false;
}

export function buildOtpAuthUrl(email, secretBase32, issuer) {
  const label = encodeURIComponent(`${issuer}:${email}`);
  const params = new URLSearchParams({
    secret: secretBase32,
    issuer,
    algorithm: "SHA1",
    digits: String(DIGITS),
    period: String(PERIOD_SECONDS),
  });
  return `otpauth://totp/${label}?${params.toString()}`;
}

const ENC_ALGORITHM = "aes-256-gcm";
const ENC_VERSION = "v1";

function getEncryptionKey() {
  const raw = process.env.ADMIN_SECRETS_KEY;
  if (!raw) {
    throw new Error(
      "ADMIN_SECRETS_KEY environment variable is not set — required to enable 2FA. " +
        "Generate one with: node -e \"console.log(require('crypto').randomBytes(32).toString('base64'))\" " +
        "then add it to .env.local/.env.prod before running this script again (npm run env:create also " +
        "generates one automatically for a fresh env file)."
    );
  }
  const key = Buffer.from(raw, "base64");
  if (key.length !== 32) {
    throw new Error("ADMIN_SECRETS_KEY must decode (base64) to exactly 32 bytes");
  }
  return key;
}

export function encryptTotpSecret(plainSecretBase32) {
  const key = getEncryptionKey();
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv(ENC_ALGORITHM, key, iv);
  const ciphertext = Buffer.concat([cipher.update(plainSecretBase32, "utf8"), cipher.final()]);
  const authTag = cipher.getAuthTag();
  return [ENC_VERSION, iv.toString("hex"), authTag.toString("hex"), ciphertext.toString("hex")].join(
    "."
  );
}
