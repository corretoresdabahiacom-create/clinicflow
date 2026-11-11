import { defineConfig } from 'vitest/config';

// Testes unitários/API (rápidos, sem rede). O teste ponta a ponta (e2e/) roda à parte: npm run test:e2e.
export default defineConfig({ test: { include: ['tests/**/*.test.ts'] } });
