import { fileURLToPath, URL } from "node:url";
import vue from "@vitejs/plugin-vue";
import { defineConfig } from "vitest/config";

// En local (npm run dev), l'API et config.json sont pris sur un environnement déployé :
//   VITE_API=https://xxxx.cloudfront.net npm run dev
const api = process.env.VITE_API ?? "https://d1rpo2pqzpwl0x.cloudfront.net";
const proxy = Object.fromEntries(
  ["/produits", "/commandes", "/compte", "/admin", "/config.json"].map((chemin) => [chemin, { target: api, changeOrigin: true }]),
);

export default defineConfig({
  plugins: [vue()],
  resolve: { alias: { "@": fileURLToPath(new URL("./src", import.meta.url)) } },
  server: { proxy },
  build: { target: "es2022", sourcemap: false },
  test: { environment: "happy-dom" },
});
