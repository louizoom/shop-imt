"""Point d'entrée gunicorn : crée le schéma au démarrage, puis sert l'application."""
from . import bdd
from .web import app

bdd.initialiser()

__all__ = ["app"]
