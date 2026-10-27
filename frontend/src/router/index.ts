import { createRouter, createWebHistory, type RouteLocationRaw } from "vue-router";
import { estAdmin } from "@/lib/session";
import BoutiqueView from "@/views/BoutiqueView.vue";

// Routes du site. Le chemin est réécrit vers index.html par une CloudFront Function (viewer-request),
// donc /suivi/<id> ou /admin s'ouvrent directement depuis un e-mail ou un favori.
export const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: "/", name: "boutique", component: BoutiqueView },
    { path: "/suivi/:commande?", name: "suivi", component: () => import("@/views/SuiviView.vue"), props: true },
    { path: "/compte", name: "compte", component: () => import("@/views/CompteView.vue") },
    { path: "/admin", name: "admin", component: () => import("@/views/AdminView.vue"), meta: { admin: true } },
    { path: "/:inconnu(.*)*", redirect: "/" },
  ],
  scrollBehavior: () => ({ top: 0 }),
});

router.beforeEach((to): RouteLocationRaw | true => {
  // Anciens liens des e-mails : /?commande=<id>, /?compte, /?admin
  if (to.path === "/") {
    const { commande } = to.query;
    if (typeof commande === "string") return { name: "suivi", params: { commande } };
    if ("compte" in to.query) return { name: "compte" };
    if ("admin" in to.query) return { name: "admin" };
  }
  // Route protégée : groupe Cognito « admins » (l'API revérifie de toute façon, 403)
  if (to.meta.admin && !estAdmin.value) return { name: "compte" };
  return true;
});

export const versSuivi = (commande: string) => router.push({ name: "suivi", params: { commande } });

declare module "vue-router" {
  interface RouteMeta {
    admin?: boolean;
  }
}
