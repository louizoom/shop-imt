// CloudFront Function (viewer-response) : langue du site choisie à la périphérie, sans Lambda.
// Première visite : lit Accept-Language et dépose le cookie « lang » (fr ou en), que le front lit
// au démarrage. Un choix manuel dans le site remplace ce cookie. Gratuit jusqu'à 2 M d'appels/mois.
function handler(event) {
  var request = event.request;
  var response = event.response;
  if (request.cookies.lang) {
    return response;
  }
  var accept = request.headers['accept-language'] ? request.headers['accept-language'].value.toLowerCase() : '';
  // La langue citée en premier l'emporte (« en-US,en;q=0.9,fr;q=0.8 » -> en) ; français par défaut
  var fr = accept.indexOf('fr');
  var en = accept.indexOf('en');
  var langue = en !== -1 && (fr === -1 || en < fr) ? 'en' : 'fr';
  response.cookies.lang = { value: langue, attributes: 'Path=/; Max-Age=31536000; SameSite=Lax; Secure' };
  return response;
}
