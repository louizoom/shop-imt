// Effets sonores et visuels, sans fichier audio ni bibliothèque : les sons sont synthétisés par la
// Web Audio API, les confettis dessinés dans un canvas. Rien ne s'anime si l'utilisateur a demandé
// à réduire les animations.

type Son = "ajout" | "retrait" | "commande" | "expediee" | "livree" | "erreur";

const calme = () => matchMedia("(prefers-reduced-motion: reduce)").matches;
let audio: AudioContext | null = null;

function contexte() {
  if (!audio) {
    const AC = window.AudioContext ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
    if (!AC) return null;
    audio = new AC();
  }
  if (audio.state === "suspended") void audio.resume();
  return audio;
}
// Les navigateurs n'autorisent le son qu'après un geste : le premier clic débloque le contexte.
if (typeof window !== "undefined") addEventListener("pointerdown", contexte, { once: true });

// Une note de clochette : fondamentale + harmoniques, attaque nette, longue extinction
function cloche(ctx: AudioContext, freq: number, debut: number, duree: number, volume: number) {
  const sortie = ctx.createGain();
  sortie.gain.setValueAtTime(0, debut);
  sortie.gain.linearRampToValueAtTime(volume, debut + 0.008);
  sortie.gain.exponentialRampToValueAtTime(0.0001, debut + duree);
  sortie.connect(ctx.destination);
  for (const [mult, part] of [
    [1, 1],
    [2.76, 0.35],
    [5.4, 0.12],
  ] as const) {
    const osc = ctx.createOscillator();
    const g = ctx.createGain();
    osc.type = "sine";
    osc.frequency.value = freq * mult;
    g.gain.value = part;
    osc.connect(g).connect(sortie);
    osc.start(debut);
    osc.stop(debut + duree);
  }
}

function bip(ctx: AudioContext, de: number, a: number, debut: number, duree: number, volume: number, type: OscillatorType = "sine") {
  const osc = ctx.createOscillator();
  const g = ctx.createGain();
  osc.type = type;
  osc.frequency.setValueAtTime(de, debut);
  osc.frequency.exponentialRampToValueAtTime(a, debut + duree);
  g.gain.setValueAtTime(volume, debut);
  g.gain.exponentialRampToValueAtTime(0.0001, debut + duree);
  osc.connect(g).connect(ctx.destination);
  osc.start(debut);
  osc.stop(debut + duree);
}

const SONS: Record<Son, (ctx: AudioContext, t: number) => void> = {
  ajout: (ctx, t) => bip(ctx, 520, 880, t, 0.09, 0.08),
  retrait: (ctx, t) => bip(ctx, 600, 330, t, 0.09, 0.06),
  // « tin tinnnn » : deux clochettes, la seconde plus aiguë et tenue
  commande: (ctx, t) => {
    cloche(ctx, 1318.5, t, 0.5, 0.16);
    cloche(ctx, 1975.5, t + 0.14, 1.8, 0.18);
  },
  expediee: (ctx, t) => {
    bip(ctx, 300, 900, t, 0.25, 0.05, "triangle");
    cloche(ctx, 1568, t + 0.2, 0.9, 0.12);
  },
  // Petite fanfare montante pour l'arrivée du colis
  livree: (ctx, t) => [1046.5, 1318.5, 1568, 2093].forEach((f, i) => cloche(ctx, f, t + i * 0.11, i === 3 ? 2.2 : 0.6, 0.14)),
  erreur: (ctx, t) => {
    bip(ctx, 220, 180, t, 0.16, 0.07, "triangle");
    bip(ctx, 180, 140, t + 0.17, 0.2, 0.07, "triangle");
  },
};

export function son(nom: Son) {
  try {
    const ctx = contexte();
    if (ctx) SONS[nom](ctx, ctx.currentTime + 0.01);
  } catch {
    /* son indisponible : rien de grave */
  }
}

// Rebond court sur un élément (pastille du panier, barre de commande…)
export function rebond(element: Element | null | undefined) {
  if (!element || calme()) return;
  element.classList.remove("rebond");
  void (element as HTMLElement).offsetWidth; // relance l'animation CSS
  element.classList.add("rebond");
}

// Pluie de confettis aux couleurs de SHOP'IMT, depuis deux canons en bas de l'écran
export function confettis({ nombre = 180, duree = 3800 } = {}) {
  if (calme()) return;
  const canvas = document.createElement("canvas");
  canvas.className = "confettis";
  canvas.setAttribute("aria-hidden", "true");
  document.body.append(canvas);
  const ctx = canvas.getContext("2d");
  if (!ctx) return;
  const ratio = devicePixelRatio || 1;
  const taille = () => {
    canvas.width = innerWidth * ratio;
    canvas.height = innerHeight * ratio;
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  };
  taille();
  addEventListener("resize", taille);

  const couleurs = ["#00B8DE", "#14223C", "#FFC845", "#FF5A79", "#7BE0AD", "#ffffff"];
  const parts = Array.from({ length: nombre }, (_, i) => {
    const gauche = i % 2 === 0;
    const angle = (gauche ? -60 : -120) + (Math.random() - 0.5) * 50;
    const vitesse = 9 + Math.random() * 9;
    return {
      x: gauche ? innerWidth * 0.1 : innerWidth * 0.9,
      y: innerHeight + 10,
      vx: Math.cos((angle * Math.PI) / 180) * vitesse,
      vy: Math.sin((angle * Math.PI) / 180) * vitesse * 1.35,
      rot: Math.random() * Math.PI,
      vrot: (Math.random() - 0.5) * 0.3,
      l: 6 + Math.random() * 6,
      h: 4 + Math.random() * 4,
      rond: Math.random() < 0.25,
      couleur: couleurs[i % couleurs.length] ?? "#00B8DE",
      retard: Math.random() * 250,
    };
  });

  const debut = performance.now();
  function image(t: number) {
    const ecoule = t - debut;
    ctx!.clearRect(0, 0, innerWidth, innerHeight);
    ctx!.globalAlpha = Math.min(1, Math.max(0, (duree - ecoule) / 600));
    for (const p of parts) {
      if (ecoule < p.retard) continue;
      p.vy += 0.32;
      p.vx *= 0.985;
      p.vy *= 0.985;
      p.x += p.vx;
      p.y += p.vy;
      p.rot += p.vrot;
      ctx!.save();
      ctx!.translate(p.x, p.y);
      ctx!.rotate(p.rot);
      ctx!.fillStyle = p.couleur;
      if (p.rond) {
        ctx!.beginPath();
        ctx!.arc(0, 0, p.h / 1.4, 0, Math.PI * 2);
        ctx!.fill();
      } else ctx!.fillRect(-p.l / 2, -p.h / 2, p.l, p.h * Math.abs(Math.cos(p.rot * 2)) + 1);
      ctx!.restore();
    }
    if (ecoule < duree) requestAnimationFrame(image);
    else {
      removeEventListener("resize", taille);
      canvas.remove();
    }
  }
  requestAnimationFrame(image);
}
