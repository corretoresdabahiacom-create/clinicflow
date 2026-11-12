import { useEffect, useRef } from 'react';

type TurnstileApi = {
  render(el: HTMLElement, o: { sitekey: string; callback: (t: string) => void; 'expired-callback': () => void; 'error-callback': () => void }): string;
  remove(id: string): void;
};
declare global { interface Window { turnstile?: TurnstileApi } }

export const TURNSTILE_SITE_KEY: string = import.meta.env.VITE_TURNSTILE_SITE_KEY ?? '';
let loading: Promise<void> | null = null;
function loadScript(): Promise<void> {
  if (window.turnstile) return Promise.resolve();
  loading ??= new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = 'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit';
    s.async = true; s.onload = () => resolve(); s.onerror = () => reject(new Error('turnstile'));
    document.head.appendChild(s);
  });
  return loading;
}

/** Desafio anti-abuso (T10). Sem VITE_TURNSTILE_SITE_KEY nada é renderizado e o servidor decide (fecha em hml/prod). */
export function Turnstile({ onToken, resetKey }: { onToken: (t: string) => void; resetKey: number }) {
  const box = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!TURNSTILE_SITE_KEY || !box.current) return;
    let id: string | null = null; let gone = false;
    onToken('');
    loadScript().then(() => {
      if (gone || !box.current || !window.turnstile) return;
      id = window.turnstile.render(box.current, {
        sitekey: TURNSTILE_SITE_KEY, callback: onToken, 'expired-callback': () => onToken(''), 'error-callback': () => onToken(''),
      });
    }).catch(() => onToken(''));
    return () => { gone = true; if (id && window.turnstile) window.turnstile.remove(id); };
  }, [resetKey, onToken]);
  return TURNSTILE_SITE_KEY ? <div ref={box} className="my-2" /> : null;
}
