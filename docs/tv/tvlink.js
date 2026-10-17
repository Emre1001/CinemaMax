// CinemaMax „An Fernseher senden“: gleiches Verfahren wie lib/tv_link.dart.
// Schlüssel = HMAC-SHA256(Code, Zweck), Verschlüsselung = HMAC-SHA256 als Zähler-Schlüsselstrom,
// Echtheit = HMAC-SHA256 über Nonce + Chiffretext. Das Relay sieht nur Chiffretext.

export const RELAY = 'https://ntfy.sh';
const ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
const enc = new TextEncoder();
const subtle = globalThis.crypto.subtle;

/** „k7m2q-9xr4t“ → „K7M2Q9XR4T“, Verwechsler O/I/L/U korrigiert; null = ungültig. */
export function normalize(input) {
  const c = String(input).toUpperCase().replace(/[^0-9A-Z]/g, '')
    .replace(/O/g, '0').replace(/[IL]/g, '1').replace(/U/g, 'V');
  return c.length === 10 && [...c].every((x) => ALPHABET.includes(x)) ? c : null;
}

const hmacKey = (raw) => subtle.importKey('raw', raw, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
const hmac = async (key, data) => new Uint8Array(await subtle.sign('HMAC', key, data));
const b64 = (u8) => btoa(String.fromCharCode(...u8));
const unb64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
const concat = (...parts) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
};

export async function link(code) {
  const root = await hmacKey(enc.encode(code));
  const derive = (purpose) => hmac(root, enc.encode('cinemamax-link-v1/' + purpose));
  const [topicRaw, encRaw, macRaw] = await Promise.all([derive('topic'), derive('enc'), derive('mac')]);
  const encKey = await hmacKey(encRaw), macKey = await hmacKey(macRaw);
  const topic = 'cmx-' + [...topicRaw].map((b) => b.toString(16).padStart(2, '0')).join('').slice(0, 32);

  async function stream(nonce, length) {
    const out = new Uint8Array(length + 32);
    for (let i = 0, o = 0; o < length; i++, o += 32) {
      const ctr = new Uint8Array([(i >>> 24) & 255, (i >>> 16) & 255, (i >>> 8) & 255, i & 255]);
      out.set(await hmac(encKey, concat(nonce, ctr)), o);
    }
    return out.subarray(0, length);
  }

  async function seal(message) {
    const nonce = globalThis.crypto.getRandomValues(new Uint8Array(16));
    const plain = enc.encode(JSON.stringify(message));
    const ks = await stream(nonce, plain.length);
    const c = plain.map((b, i) => b ^ ks[i]);
    const tag = await hmac(macKey, concat(nonce, c));
    return JSON.stringify({ v: 1, n: b64(nonce), c: b64(c), t: b64(tag) });
  }

  async function open(body) {
    try {
      const j = JSON.parse(body);
      if (j.v !== 1) return null;
      const nonce = unb64(j.n), c = unb64(j.c), tag = unb64(j.t);
      const want = await hmac(macKey, concat(nonce, c));
      let diff = tag.length ^ want.length;
      for (let i = 0; i < want.length && i < tag.length; i++) diff |= tag[i] ^ want[i];
      if (diff) return null;
      const ks = await stream(nonce, c.length);
      return JSON.parse(new TextDecoder().decode(c.map((b, i) => b ^ ks[i])));
    } catch { return null; }
  }

  async function send(message) {
    const r = await fetch(`${RELAY}/${topic}`, { method: 'POST', body: await seal(message) });
    if (!r.ok) throw new Error('Relay: HTTP ' + r.status);
  }

  /** Ruft onMessage für jede entschlüsselte Nachricht ab jetzt; gibt eine Stopp-Funktion zurück. */
  function listen(onMessage) {
    const since = Math.floor(Date.now() / 1000) - 5;
    const es = new EventSource(`${RELAY}/${topic}/sse?since=${since}`);
    es.onmessage = async (e) => {
      try {
        const m = await open(JSON.parse(e.data).message);
        if (m) onMessage(m);
      } catch { /* Keepalive o. ä. */ }
    };
    return () => es.close();
  }

  return { code, topic, seal, open, send, listen };
}
