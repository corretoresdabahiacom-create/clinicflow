/** CPF nunca é persistido em claro: somente HMAC-SHA256 (chave no Worker) + máscara. */
export function normalizeCpf(input: string): string { return input.replace(/[.\-\s]/g, ''); }

export function isValidCpf(c: string): boolean {
  if (!/^\d{11}$/.test(c) || /^(\d)\1{10}$/.test(c)) return false;
  const dv = (len: number) => {
    let s = 0;
    for (let i = 0; i < len; i++) s += Number(c[i]) * (len + 1 - i);
    const r = (s * 10) % 11;
    return r === 10 ? 0 : r;
  };
  return dv(9) === Number(c[9]) && dv(10) === Number(c[10]);
}

export const maskCpf = (c: string) => `***.***.***-${c.slice(9)}`;

/** O escopo da organização entra na mensagem: o mesmo CPF gera hashes diferentes em tenants diferentes. */
export async function hashCpf(key: string, orgId: string, cpf: string): Promise<string> {
  const k = await crypto.subtle.importKey('raw', new TextEncoder().encode(key), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', k, new TextEncoder().encode(`${orgId}:${cpf}`));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, '0')).join('');
}
